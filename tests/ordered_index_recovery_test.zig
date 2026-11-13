// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P1 Task 3: crash-safe engine integration of the value-ordered index.
//
// Mirrors tests/leverb_clean_restart.zig. The value-ordered index follows the
// SAME crash-safety discipline as the derived indexes (Lever B):
//
//   Test A (clean restart LOADS): write labelled+propertied nodes through an
//   ordered index, run a light checkpoint then a FULL checkpoint (clean), then
//   reopen. The snapshot counter == manifest.counter, so open LOADS the trees
//   (ordered_index_loads == 1, no rebuild) and the ASC/DESC cursor walk is
//   correct.
//
//   Test B (crash restart REBUILDS): write through the ordered index, FULL
//   checkpoint (saves a valid snapshot), commit an extra node AFTER the
//   snapshot, then `deinit` (crash — no checkpoint/close). Recovery replays the
//   fsynced WAL tail and bumps manifest.counter, so the snapshot is stale-by-
//   counter; the load gate REJECTS it and forces a rebuild from the durable
//   graph (ordered_index_rebuilds == 1). Proves the counter gate was not
//   weakened, and that the rebuilt index holds the committed post-checkpoint
//   node: a committed write must survive the crash (SONNY-6424/6438).

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const GraphConfig = graph_storage.GraphConfig;
const NodeRec = graph_storage.node.NodeRec;
const NodeId = graph_storage.NodeId;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;
const ordered_encoding = graph_storage.ordered_encoding;
const index_snapshot = graph_storage.index_snapshot;
const SNAPSHOT_MAGIC = graph_storage.ordered_property_index.SNAPSHOT_MAGIC;
const SNAPSHOT_FILE_NAME = graph_storage.ordered_property_index.SNAPSHOT_FILE_NAME;
const io = std.Io.Threaded.global_single_threaded.io();

const LABEL: u32 = 11;
const KEY = "score";

fn emptyNode() NodeRec {
    return graph_storage.test_support.emptyNode(1);
}

/// Write `n` nodes each carrying LABEL and an int property KEY = value, where
/// value = i*7 mod 1000 (a scrambled order so the ASC walk is a real sort, not
/// the insertion order). The property is set BEFORE the label is added, so the
/// incremental add-label hook indexes the final value. A LIGHT checkpoint runs
/// every 500 inserts (the bulk-ingest cadence). Returns the values inserted.
fn bulkLoad(engine: *GraphEngine, n: usize, out_values: *std.ArrayList(i64)) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const value: i64 = @intCast((i * 7) % 1000 + 1); // 1..1000, scrambled
        const nid = try engine.allocNode();
        var rec = emptyNode();
        // Set the property FIRST so the value is present when the label is added.
        rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = value });
        try engine.putNode(nid, rec);
        // Adding the label triggers the incremental ordered-index insert.
        try engine.addLabel(nid, LABEL);
        try out_values.append(testing.allocator, value);

        if (i % 500 == 499) try engine.checkpointLight();
    }
}

/// Assert the ordered cursor (ASC) yields exactly `expected` sorted ascending,
/// and the DESC cursor yields the exact reverse.
fn verifyOrder(engine: *GraphEngine, expected: []const i64) !void {
    const sorted = try testing.allocator.dupe(i64, expected);
    defer testing.allocator.free(sorted);
    std.mem.sort(i64, sorted, {}, std.sort.asc(i64));

    // ASC.
    {
        var cursor = engine.openOrderedCursor(LABEL, KEY, .asc) orelse return error.NoOrderedIndex;
        var got: std.ArrayList(i64) = .empty;
        defer got.deinit(testing.allocator);
        while (cursor.next()) |entry| {
            var d = try ordered_encoding.decode(testing.allocator, entry.key);
            defer d.deinit(testing.allocator);
            try got.append(testing.allocator, d.value.int);
        }
        try testing.expectEqualSlices(i64, sorted, got.items);
    }

    // DESC == exact reverse.
    {
        var cursor = engine.openOrderedCursor(LABEL, KEY, .desc) orelse return error.NoOrderedIndex;
        var got: std.ArrayList(i64) = .empty;
        defer got.deinit(testing.allocator);
        while (cursor.next()) |entry| {
            var d = try ordered_encoding.decode(testing.allocator, entry.key);
            defer d.deinit(testing.allocator);
            try got.append(testing.allocator, d.value.int);
        }
        const rev = try testing.allocator.dupe(i64, sorted);
        defer testing.allocator.free(rev);
        std.mem.reverse(i64, rev);
        try testing.expectEqualSlices(i64, rev, got.items);
    }
}

test "Test A: clean restart LOADS the ordered index (no rebuild)" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xC1} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;
    cfg.buffer_pool_pages = 64;

    const N: usize = 1500; // multiple of 500 -> last op is a light checkpoint

    var values: std.ArrayList(i64) = .empty;
    defer values.deinit(testing.allocator);

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        try engine.createOrderedIndex(LABEL, KEY);
        try bulkLoad(engine, N, &values);

        // FULL checkpoint = clean-shutdown model. Must persist the dirty ordered
        // snapshot even though the trailing light checkpoint left
        // persistence_dirty=false (derived_pending now includes ordered_index_dirty).
        const before = engine.getMetrics().ordered_index_saves;
        try engine.checkpoint();
        try testing.expect(engine.getMetrics().ordered_index_saves > before);
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Core assertion: the clean restart LOADED the ordered snapshot
        // (O(snapshot)) and did NOT rebuild from the O(graph) scan.
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().ordered_index_rebuilds);

        try verifyOrder(engine, values.items);
    }
}

test "Test B: crash restart REBUILDS the ordered index (stale snapshot rejected)" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xC2} ** 16;
    // sync_each_commit so the post-snapshot writes are fsynced and replayed.
    var cfg = graph_storage.test_support.testConfig();
    cfg.buffer_pool_pages = 64;

    const N: usize = 1000; // multiple of 500

    var values: std.ArrayList(i64) = .empty;
    defer values.deinit(testing.allocator);

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        try engine.createOrderedIndex(LABEL, KEY);
        try bulkLoad(engine, N, &values);

        // FULL checkpoint: saves a VALID ordered snapshot at the current
        // manifest.counter. A clean restart from HERE would load it.
        const saves_before = engine.getMetrics().ordered_index_saves;
        try engine.checkpoint();
        try testing.expect(engine.getMetrics().ordered_index_saves > saves_before);

        // Commit an extra labelled+propertied node AFTER the snapshot.
        // sync_each_commit fsyncs it to the WAL so recovery replays it and bumps
        // manifest.counter PAST the snapshot stamp — that bump is what forces the
        // rebuild. The commit returned, so the node is durable: the rebuilt
        // index must contain it. (This test used to leave it out of `values`,
        // encoding the SONNY-6424 loss of post-checkpoint commits as expected.)
        const extra_value: i64 = 12345;
        const nid = try engine.allocNode();
        var rec = emptyNode();
        rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = extra_value });
        try engine.putNode(nid, rec);
        try engine.addLabel(nid, LABEL);
        try values.append(testing.allocator, extra_value);

        // SIMULATED CRASH: no checkpoint(), no close() — abandon the engine.
        engine.deinit();
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Crash-safety proof: the rebuild was FORCED and the stale snapshot was
        // NOT loaded. ordered_index_rebuilds == 1 only if recovery saw the
        // post-snapshot WAL tail and bumped manifest.counter past the snapshot
        // stamp — i.e. the counter gate rejected the stale ordered snapshot.
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().ordered_index_loads);

        // The rebuilt index reflects the durable graph — the checkpointed set
        // plus the committed post-checkpoint node — in order.
        try verifyOrder(engine, values.items);
    }
}

// ============================================================================
// GAP-0050: ordered index on the Path B (checkpoint_epoch, covered_lsn) reload
// contract. The tests below tamper ONLY the persisted snapshot's stamp header
// (leaving the durable graph pages intact) to exercise each gate condition
// deterministically, then assert reopen REBUILDS and ORDER BY stays correct.
// ============================================================================

/// Assert the ASC cursor is sorted non-decreasing and DESC is its exact reverse
/// — the "sort order correct" property, robust to which exact node set the
/// (rebuilt) index contains.
fn verifySortedConsistent(engine: *GraphEngine) !void {
    var asc: std.ArrayList(i64) = .empty;
    defer asc.deinit(testing.allocator);
    {
        var cursor = engine.openOrderedCursor(LABEL, KEY, .asc) orelse return error.NoOrderedIndex;
        var prev: ?i64 = null;
        while (cursor.next()) |entry| {
            var d = try ordered_encoding.decode(testing.allocator, entry.key);
            defer d.deinit(testing.allocator);
            if (prev) |p| try testing.expect(d.value.int >= p);
            prev = d.value.int;
            try asc.append(testing.allocator, d.value.int);
        }
    }
    var desc: std.ArrayList(i64) = .empty;
    defer desc.deinit(testing.allocator);
    {
        var cursor = engine.openOrderedCursor(LABEL, KEY, .desc) orelse return error.NoOrderedIndex;
        while (cursor.next()) |entry| {
            var d = try ordered_encoding.decode(testing.allocator, entry.key);
            defer d.deinit(testing.allocator);
            try desc.append(testing.allocator, d.value.int);
        }
    }
    const rev = try testing.allocator.dupe(i64, asc.items);
    defer testing.allocator.free(rev);
    std.mem.reverse(i64, rev);
    try testing.expectEqualSlices(i64, rev, desc.items);
}

/// The persisted ordered snapshot's current header.
fn snapshotHeader(gdir: []const u8) !index_snapshot.SnapshotHeader {
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ gdir, SNAPSHOT_FILE_NAME });
    defer testing.allocator.free(snap_path);
    var file = try std.Io.Dir.cwd().openFile(io, snap_path, .{});
    defer file.close(io);
    return (try index_snapshot.loadHeader(&file, SNAPSHOT_MAGIC, 0)) orelse error.NoSnapshot;
}

/// Restamp the persisted ordered snapshot at `<gdir>/ordered_propidx.snap` to
/// `(new_epoch, new_covered)` (valid CRC, via index_snapshot.restampStamps) so
/// the next reopen sees a specific Path B gate mismatch. The graph pages are
/// left untouched, so a forced rebuild reproduces the durable checkpointed set.
fn restampSnapshot(gdir: []const u8, new_epoch: u64, new_covered: u64) !void {
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ gdir, SNAPSHOT_FILE_NAME });
    defer testing.allocator.free(snap_path);
    var file = try std.Io.Dir.cwd().openFile(io, snap_path, .{ .mode = .read_write });
    defer file.close(io);
    try testing.expect(try index_snapshot.restampStamps(&file, SNAPSHOT_MAGIC, new_epoch, new_covered));
}

/// create + register + bulk-load + full checkpoint; returns the graph dir path
/// (caller frees) with a clean, loadable snapshot on disk.
fn buildCleanSnapshot(uuid: [16]u8, cfg: GraphConfig, n: usize, values: *std.ArrayList(i64), td_path: []const u8) ![]u8 {
    const engine = try GraphEngine.create(testing.allocator, td_path, uuid, cfg);
    defer engine.close() catch {};
    try engine.createOrderedIndex(LABEL, KEY);
    try bulkLoad(engine, n, values);
    try engine.checkpoint(); // clean, loadable snapshot at (epoch, covered==frontier)
    return testing.allocator.dupe(u8, engine.graph_dir.path);
}

test "Test D1: a committed WAL tail (covered_lsn < frontier) REBUILDS (safe)" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xD1} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;
    cfg.buffer_pool_pages = 64;

    var values: std.ArrayList(i64) = .empty;
    defer values.deinit(testing.allocator);

    const gdir = try buildCleanSnapshot(uuid, cfg, 300, &values, td.path);
    defer testing.allocator.free(gdir);

    // Simulate a committed tail past the snapshot: keep the epoch current but
    // drop covered_lsn below the durable frontier (the graph pages are intact).
    const hdr = try snapshotHeader(gdir);
    try testing.expect(hdr.covered_lsn > 0); // a real, non-zero durable frontier
    try restampSnapshot(gdir, hdr.checkpoint_epoch, hdr.covered_lsn - 1);

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        // Epoch matches but covered_lsn (< frontier) signals a tail -> REBUILD.
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().ordered_index_loads);
        // ORDER BY correct: rebuild reflects the durable checkpointed graph.
        try verifyOrder(engine, values.items);
    }
}

test "Test D2: an epoch mismatch (checkpoint ran after the snapshot) REBUILDS" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xD2} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;
    cfg.buffer_pool_pages = 64;

    var values: std.ArrayList(i64) = .empty;
    defer values.deinit(testing.allocator);

    const gdir = try buildCleanSnapshot(uuid, cfg, 300, &values, td.path);
    defer testing.allocator.free(gdir);

    // Bump the snapshot epoch past the manifest's, keeping covered_lsn intact:
    // models a checkpoint that advanced the epoch without re-saving this index.
    const hdr = try snapshotHeader(gdir);
    try restampSnapshot(gdir, hdr.checkpoint_epoch + 1, hdr.covered_lsn);

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().ordered_index_loads);
        try verifyOrder(engine, values.items);
    }
}

test "Test B2: crash restart REBUILDS and the ORDER BY sort stays correct" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xB2} ** 16;
    var cfg = graph_storage.test_support.testConfig(); // sync_each_commit default
    cfg.buffer_pool_pages = 64;

    const N: usize = 1000;
    var values: std.ArrayList(i64) = .empty;
    defer values.deinit(testing.allocator);

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.createOrderedIndex(LABEL, KEY);
        try bulkLoad(engine, N, &values);
        try engine.checkpoint();

        // Commit an extra labelled+propertied node AFTER the snapshot (fsynced).
        const nid = try engine.allocNode();
        var rec = emptyNode();
        rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = 777 });
        try engine.putNode(nid, rec);
        try engine.addLabel(nid, LABEL);
        try values.append(testing.allocator, 777);

        engine.deinit(); // CRASH: no checkpoint/close.
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        // The committed tail advanced the durable frontier past covered_lsn, so
        // the ordered snapshot is REBUILT (never loaded stale).
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().ordered_index_loads);
        // Paramount property: the rebuilt index yields a CORRECT sort (ASC
        // ascending, DESC its exact reverse) — never a stale/mis-ordered
        // result — over the exact committed set, incl. the post-checkpoint 777.
        try verifySortedConsistent(engine);
        try verifyOrder(engine, values.items);
    }
}
