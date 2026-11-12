// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// WAL sequence anchor lost when a checkpoint empties the WAL (SONNY-6424).
//
// A full checkpoint records `manifest.last_checkpoint_lsn = L` and compacts the
// WAL up to L. When that empties the log, the wal library's `compact()`
// deletes the `graph.wal.ckpt` sidecar — the only place an EMPTY log keeps its
// sequence number. The sidecar is rewritten by a clean `WriteAheadLog.deinit`,
// but a process that exits without closing the engine (or is SIGKILLed) never
// gets there. The next open then numbered the inner log from 0 while recovery
// iterated that inner numbering and skipped everything <= L:
//
//   * fewer than L records written after the reopen  -> all of them skipped
//     by the next crash recovery (committed writes silently lost);
//   * more than L records                           -> only a torn tail
//     (begin records missing) replays, or recovery fails with DataCorruption.
//
// The repo's usual crash simulation (`eng.deinit()` without `close`) still runs
// `WriteAheadLog.deinit`, which REWRITES the sidecar with the in-memory
// sequence number and hides the defect. A real process exit runs no deinit, so
// `simulateProcessExit` below deletes the sidecar after `deinit` — restoring
// exactly the on-disk state a dead process leaves behind (compacted, empty WAL;
// no sidecar; manifest at L). Nothing else `deinit` does touches durable state.
//
// Tests:
//   * fewer post-reopen records than L: every committed write survives;
//   * more post-reopen records than L: no torn-tail replay / DataCorruption;
//   * repeated checkpoint / exit / write / crash cycles stay durable;
//   * upgrade: a store ALREADY in the bad state on disk (inner log renumbered
//     from 1 underneath last_checkpoint_lsn, written by an unfixed binary)
//     recovers every committed record.

const std = @import("std");
const gs = @import("graph_storage");
const wal_lib = @import("wal");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const WalRecord = gs.wal_record.WalRecord;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

/// Create `n` committed nodes, each carrying property "v" = `tag + i`.
fn writeNodes(eng: *GraphEngine, ids: []u64, tag: i64) !void {
    for (ids, 0..) |*id, i| {
        id.* = try eng.allocNode();
        try eng.putNode(id.*, emptyNode());
        var rec = (try eng.getNode(id.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "v", .{ .int = tag + @as(i64, @intCast(i)) });
        try eng.putNode(id.*, rec);
    }
}

fn expectNodes(alloc: Allocator, eng: *GraphEngine, ids: []const u64, tag: i64, what: []const u8) !void {
    for (ids, 0..) |id, i| {
        const rec = (try eng.getNode(id)) orelse {
            std.debug.print("{s}: committed node {d} (#{d}) LOST after crash recovery\n", .{ what, id, i });
            return error.CommittedNodeLost;
        };
        const v = (try eng.getProperty(rec.prop_head, "v", alloc)) orelse {
            std.debug.print("{s}: committed node {d} (#{d}) lost property 'v'\n", .{ what, id, i });
            return error.CommittedPropertyLost;
        };
        switch (v) {
            .int => |x| try testing.expectEqual(tag + @as(i64, @intCast(i)), x),
            else => return error.CommittedPropertyWrongType,
        }
    }
}

/// Large enough to overflow into a var-store chain (> one page's entry
/// budget at page_size 4096), so its pages are imaged ONLY by the txn that
/// writes it — later int-property writes never re-image them and cannot mask
/// a skipped record with a newer full-page image.
const BLOB_LEN: usize = 6000;

fn blobByte(i: usize) u8 {
    return @intCast((i * 31 + 7) % 251);
}

fn putBlob(alloc: Allocator, eng: *GraphEngine, id: u64) !void {
    const blob = try alloc.alloc(u8, BLOB_LEN);
    defer alloc.free(blob);
    for (blob, 0..) |*b, i| b.* = blobByte(i);
    var rec = (try eng.getNode(id)).?;
    rec.prop_head = try eng.putProperty(rec.prop_head, "blob", .{ .string = blob });
    try eng.putNode(id, rec);
}

fn expectBlob(alloc: Allocator, eng: *GraphEngine, id: u64) !void {
    const rec = (try eng.getNode(id)) orelse return error.CommittedNodeLost;
    const v = (try eng.getProperty(rec.prop_head, "blob", alloc)) orelse {
        std.debug.print("post-reopen overflow property on node {d} LOST after crash recovery\n", .{id});
        return error.CommittedPropertyLost;
    };
    defer gs.property.freeDecoded(alloc, v);
    switch (v) {
        .string => |s| {
            try testing.expectEqual(BLOB_LEN, s.len);
            for (s, 0..) |b, i| try testing.expectEqual(blobByte(i), b);
        },
        else => return error.CommittedPropertyWrongType,
    }
}

/// Owned copy of the engine's `<graph>/wal` directory path.
fn walDirPath(alloc: Allocator, eng: *GraphEngine) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/wal", .{eng.graph_dir.path});
}

/// Drop the engine the way a dead process does: no checkpoint, no close, and
/// no WAL sidecar rewrite (see the file header).
fn simulateProcessExit(alloc: Allocator, eng: *GraphEngine) !void {
    const wal_dir_path = try walDirPath(alloc, eng);
    defer alloc.free(wal_dir_path);
    eng.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, wal_dir_path, .{});
    defer dir.close(io);
    dir.deleteFile(io, "graph.wal.ckpt") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// The invariant whose violation is the defect: after open the WAL numbers
/// the next record ABOVE the durable checkpoint frontier.
fn expectAnchored(eng: *GraphEngine, what: []const u8) !void {
    const inner = eng.wal.currentLsn();
    const frontier = eng.manifest.last_checkpoint_lsn;
    if (inner < frontier) {
        std.debug.print("{s}: WAL numbering restarted below the checkpoint frontier (wal.currentLsn={d} < last_checkpoint_lsn={d})\n", .{ what, inner, frontier });
        return error.WalLsnAnchorLost;
    }
}

/// checkpoint (WAL empties) -> exit without close -> reopen -> write an
/// overflow property on a checkpointed node, then `after` committed nodes ->
/// crash -> reopen -> every committed write present.
fn runScenario(alloc: Allocator, n_before: usize, n_after: usize, uuid: [16]u8) !void {
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const cfg = test_support.testConfig();

    const before = try alloc.alloc(u64, n_before);
    defer alloc.free(before);
    const after = try alloc.alloc(u64, n_after);
    defer alloc.free(after);

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try writeNodes(eng, before, 1000);
        try eng.checkpoint();
        try testing.expect(eng.manifest.last_checkpoint_lsn > 0);
        try simulateProcessExit(alloc, eng);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try expectAnchored(eng, "reopen after checkpoint + process exit");
        try putBlob(alloc, eng, before[0]);
        try writeNodes(eng, after, 5000);
        try simulateProcessExit(alloc, eng);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectAnchored(eng, "crash recovery");
        try expectNodes(alloc, eng, before, 1000, "checkpointed");
        try expectNodes(alloc, eng, after, 5000, "post-reopen");
        try expectBlob(alloc, eng, before[0]);
    }
}

test "SONNY-6424: fewer post-reopen records than the checkpoint LSN all survive a crash" {
    // ~40 checkpointed nodes put last_checkpoint_lsn in the hundreds; 3 nodes
    // afterwards write a handful of records, all numbered <= L by an
    // un-anchored log and therefore all skipped by recovery.
    try runScenario(testing.allocator, 40, 3, [_]u8{0x64} ** 16);
}

test "SONNY-6424: more post-reopen records than the checkpoint LSN replay without a torn tail" {
    // A tiny checkpoint LSN and a long post-reopen tail: an un-anchored log
    // replays only the records numbered > L. The node pages are re-imaged by
    // later txns (masking the loss there), but the overflow chain written
    // first is imaged only by records numbered <= L and is lost.
    try runScenario(testing.allocator, 1, 40, [_]u8{0x65} ** 16);
}

test "SONNY-6424: repeated checkpoint / exit / write / crash cycles stay durable" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x66} ** 16;
    const cfg = test_support.testConfig();

    const rounds = 4;
    const per_round = 6;
    var ids: [rounds][per_round]u64 = undefined;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try writeNodes(eng, &ids[0], 0);
        try eng.checkpoint();
        try simulateProcessExit(alloc, eng);
    }
    for (1..rounds) |r| {
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            try expectAnchored(eng, "cycle reopen");
            try writeNodes(eng, &ids[r], @intCast(r * 100));
            try simulateProcessExit(alloc, eng);
        }
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            try expectAnchored(eng, "cycle crash recovery");
            for (0..r + 1) |k| try expectNodes(alloc, eng, &ids[k], @intCast(k * 100), "cycle");
            // Empty the WAL again and die without closing.
            try eng.checkpoint();
            try simulateProcessExit(alloc, eng);
        }
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    for (0..rounds) |k| try expectNodes(alloc, eng, &ids[k], @intCast(k * 100), "final");
}

/// Rewrite `<wal_dir>/graph.wal` so the inner log is numbered from 1 again
/// while every graph-storage record payload (and its own LSN) is kept
/// byte-for-byte — the exact on-disk shape an unfixed binary produced after
/// "checkpoint, exit without close, reopen, write". Records that only anchor
/// the sequence (checkpoint markers) are dropped, since an unfixed binary
/// never wrote them.
fn renumberInnerLogFromOne(alloc: Allocator, wal_dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, wal_dir_path, .{});
    defer dir.close(io);

    var payloads: std.ArrayList([]u8) = .empty;
    defer {
        for (payloads.items) |p| alloc.free(p);
        payloads.deinit(alloc);
    }
    {
        var log = try wal_lib.WriteAheadLog.init(alloc, dir, "graph.wal", .{ .manual_sync = true, .checkpoint = false });
        defer log.deinit();
        var it = try log.iterator(0);
        defer it.deinit();
        while (try it.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();
            const parsed = try WalRecord.deserialize(alloc, entry.payload);
            defer parsed.record.deinit(alloc);
            if (parsed.record.record_type == .checkpoint_marker) continue;
            try payloads.append(alloc, try alloc.dupe(u8, entry.payload));
        }
    }

    try dir.deleteFile(io, "graph.wal");
    dir.deleteFile(io, "graph.wal.ckpt") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var log = try wal_lib.WriteAheadLog.init(alloc, dir, "graph.wal", .{ .manual_sync = true, .checkpoint = false });
    defer log.deinit();
    for (payloads.items) |p| _ = try log.append(p);
    try log.sync();
    return payloads.items.len;
}

fn runUpgradeScenario(alloc: Allocator, n_before: usize, n_after: usize, uuid: [16]u8) !void {
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const cfg = test_support.testConfig();

    const before = try alloc.alloc(u64, n_before);
    defer alloc.free(before);
    const after = try alloc.alloc(u64, n_after);
    defer alloc.free(after);

    var checkpoint_lsn: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try writeNodes(eng, before, 1000);
        try eng.checkpoint();
        checkpoint_lsn = eng.manifest.last_checkpoint_lsn;
        try simulateProcessExit(alloc, eng);
    }
    var wal_dir_path: []u8 = undefined;
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        wal_dir_path = try walDirPath(alloc, eng);
        try writeNodes(eng, after, 5000);
        try simulateProcessExit(alloc, eng);
    }
    defer alloc.free(wal_dir_path);

    // Put the store into the bad on-disk state an unfixed binary left behind.
    const n_records = try renumberInnerLogFromOne(alloc, wal_dir_path);
    try testing.expect(n_records > 0);

    var more: [5]u64 = undefined;
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try expectAnchored(eng, "upgrade recovery");
        try testing.expect(eng.manifest.last_checkpoint_lsn >= checkpoint_lsn);
        try expectNodes(alloc, eng, before, 1000, "upgrade checkpointed");
        try expectNodes(alloc, eng, after, 5000, "upgrade post-reopen");
        // The healed store keeps working: new writes survive another crash.
        try writeNodes(eng, &more, 9000);
        try simulateProcessExit(alloc, eng);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectAnchored(eng, "post-upgrade crash recovery");
    try expectNodes(alloc, eng, before, 1000, "post-upgrade checkpointed");
    try expectNodes(alloc, eng, after, 5000, "post-upgrade bad-state");
    try expectNodes(alloc, eng, &more, 9000, "post-upgrade new writes");
}

test "SONNY-6424 upgrade: a store already renumbered below last_checkpoint_lsn recovers every committed record" {
    // Bad-state records all numbered <= L (an unfixed binary skipped them all).
    try runUpgradeScenario(testing.allocator, 40, 3, [_]u8{0x67} ** 16);
    // Bad-state records straddling L (an unfixed binary replayed a torn tail).
    try runUpgradeScenario(testing.allocator, 1, 40, [_]u8{0x68} ** 16);
}
