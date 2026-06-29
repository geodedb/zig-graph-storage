// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P4 Task A2/A3: ordered-index close() DURABILITY lifecycle.
//
// The value-ordered index is rebuilt only at the durability boundary (full
// checkpoint / close), NOT per write (online label/property hooks only mark the
// trees STALE). This suite proves the two close() durability bugs are fixed:
//
//   #1 (silent-wrong): close() with dirty writes but no explicit full checkpoint
//      must REBUILD the ordered tree before persisting the snapshot, otherwise it
//      saves an empty/stale tree stamped at manifest.counter that the next clean
//      open LOADS as fresh -> ORDER BY serves 0 rows (STAGE G).
//   #2 (registration lost): after a trailing LIGHT checkpoint, persistence_dirty
//      is false; close() must still refresh+persist the ordered tree so the next
//      open finds a snapshot and keeps the registration (STAGE H).
//
// Nodes are created the BENCH/executor way: putNode (prop_head==0) -> addLabel
// (online ordered hook sees no props, inserts nothing) -> putProperty afterwards
// (no online tree maintenance). So between writes and a rebuild the tree is empty.

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const NodeRec = graph_storage.node.NodeRec;
const NodeId = graph_storage.NodeId;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;

const LABEL: u32 = 7;
const KEY = "source_id";
const N: i64 = 64;

fn emptyNode() NodeRec {
    return graph_storage.test_support.emptyNode(1);
}

/// BENCH ORDER: node + label created BEFORE properties (prop_head==0 at addLabel
/// => online ordered hook misses), then property set in place. Mirrors the geode
/// adapter createNode + later setNodeProperty path.
fn addBenchNode(engine: *GraphEngine, value: i64) !NodeId {
    const nid = try engine.allocNode();
    var rec = emptyNode(); // prop_head = 0
    try engine.putNode(nid, rec); // node exists, no props
    try engine.addLabel(nid, LABEL); // prop_head==0 -> online hook no-op
    rec = (try engine.getNode(nid)) orelse return error.NodeMissing;
    rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = value });
    try engine.putNode(nid, rec); // putProperty does NOT maintain the ordered tree
    return nid;
}

/// Count rows the ordered ASC cursor would serve (the ORDER BY fast-path output).
fn cursorCount(engine: *GraphEngine) usize {
    var cursor = engine.openOrderedCursor(LABEL, KEY, .asc) orelse return 0;
    var n: usize = 0;
    while (cursor.next()) |_| n += 1;
    return n;
}

/// True iff the ASC cursor yields strictly increasing (order-preserving) keys,
/// i.e. ORDER BY would return rows in value order. Also returns the row count.
fn cursorInOrder(engine: *GraphEngine) struct { count: usize, ordered: bool } {
    var cursor = engine.openOrderedCursor(LABEL, KEY, .asc) orelse return .{ .count = 0, .ordered = true };
    var prev: ?[]const u8 = null;
    var buf: [256]u8 = undefined;
    var prev_len: usize = 0;
    var n: usize = 0;
    var ordered = true;
    while (cursor.next()) |entry| {
        if (prev) |p| {
            if (std.mem.order(u8, entry.key, p) != .gt) ordered = false;
        }
        // copy the (cursor-owned) key into a stable buffer for the next compare
        const len = @min(entry.key.len, buf.len);
        @memcpy(buf[0..len], entry.key[0..len]);
        prev_len = len;
        prev = buf[0..prev_len];
        n += 1;
    }
    return .{ .count = n, .ordered = ordered };
}

test "STAGE D + VALUE-DRIFT: writes mark stale, online tree stays empty" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xA2} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    try engine.createOrderedIndex(LABEL, KEY);
    try testing.expect(engine.orderedIndexFresh()); // empty tree @ 0 nodes is exact

    var i: i64 = 0;
    while (i < N) : (i += 1) _ = try addBenchNode(engine, i);

    // STAGE D: after N bench writes, NO checkpoint. The online hook missed, so
    // the tree is empty AND the freshness gate is false (planner must not serve).
    try testing.expect(!engine.orderedIndexFresh());
    try testing.expectEqual(@as(usize, 0), cursorCount(engine));

    // VALUE-DRIFT isolation: rebuild to make the tree fresh, then putProperty a
    // NEW value on an ALREADY-labelled node. The prop-write path must mark stale
    // (not only addLabel). This guards the A1 review note.
    try engine.rebuildOrderedIndex();
    try testing.expect(engine.orderedIndexFresh());

    const drift_nid = try engine.allocNode();
    var drift_rec = emptyNode();
    try engine.putNode(drift_nid, drift_rec);
    try engine.addLabel(drift_nid, LABEL);
    try engine.rebuildOrderedIndex(); // node now indexed (still prop_head==0 => not in tree)
    try testing.expect(engine.orderedIndexFresh());
    // Drift: write a NEW value in place on the already-labelled node.
    drift_rec = (try engine.getNode(drift_nid)) orelse return error.NodeMissing;
    drift_rec.prop_head = try engine.putProperty(drift_rec.prop_head, KEY, .{ .int = 999 });
    try engine.putNode(drift_nid, drift_rec);
    try testing.expect(!engine.orderedIndexFresh()); // prop-write marked stale
}

test "STAGE E + F: full checkpoint populates + persists; reopen LOADS fresh" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xA3} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        try engine.createOrderedIndex(LABEL, KEY);
        var i: i64 = 0;
        while (i < N) : (i += 1) _ = try addBenchNode(engine, i);

        // STAGE E: a FULL checkpoint rebuilds the tree before saving.
        try engine.checkpoint();
        try testing.expect(engine.orderedIndexFresh());
        try testing.expectEqual(@as(usize, @intCast(N)), cursorCount(engine));
    }

    // STAGE F: reopen after the full checkpoint -> clean snapshot LOAD.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expect(engine.hasOrderedIndex(LABEL, KEY));
        try testing.expect(engine.orderedIndexFresh());
        try testing.expectEqual(@as(usize, @intCast(N)), cursorCount(engine));
        const m = engine.getMetrics();
        try testing.expectEqual(@as(u64, 1), m.ordered_index_loads);
        try testing.expectEqual(@as(u64, 0), m.ordered_index_rebuilds);
    }
}

test "STAGE G: close() with dirty writes (no full checkpoint) -> reopen loads populated" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x67} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.createOrderedIndex(LABEL, KEY);
        var i: i64 = 0;
        while (i < N) : (i += 1) _ = try addBenchNode(engine, i);
        // close() with persistence_dirty == true, NO explicit full checkpoint.
        // BUG #1: without a rebuild-before-save, the persisted snapshot is empty.
        try engine.close();
    }
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expect(engine.hasOrderedIndex(LABEL, KEY));
        try testing.expect(engine.orderedIndexFresh());
        const res = cursorInOrder(engine);
        try testing.expectEqual(@as(usize, @intCast(N)), res.count); // FAILS pre-fix#1 (loads empty)
        try testing.expect(res.ordered); // ORDER-BY style: rows in value order
        const m = engine.getMetrics();
        try testing.expectEqual(@as(u64, 1), m.ordered_index_loads); // clean snapshot load
        try testing.expectEqual(@as(u64, 0), m.ordered_index_rebuilds);
    }
}

test "STAGE H: trailing LIGHT checkpoint then close() -> reopen keeps registration + populated" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x48} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.createOrderedIndex(LABEL, KEY);
        var i: i64 = 0;
        while (i < N) : (i += 1) _ = try addBenchNode(engine, i);
        // Ingest-style trailing LIGHT checkpoint: clears persistence_dirty, bumps
        // + persists manifest.counter, but saves no derived/ordered snapshot.
        try engine.checkpointLight();
        // close() now runs with persistence_dirty == false.
        // BUG #2: without an unconditional ordered refresh+save, no snapshot is
        // written and the registration is lost on reopen.
        try engine.close();
    }
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expect(engine.hasOrderedIndex(LABEL, KEY)); // FAILS pre-fix#2 (registration lost)
        try testing.expect(engine.orderedIndexFresh());
        try testing.expectEqual(@as(usize, @intCast(N)), cursorCount(engine));
        const m = engine.getMetrics();
        try testing.expectEqual(@as(u64, 1), m.ordered_index_loads); // snapshot stamp matched reopen counter
        try testing.expectEqual(@as(u64, 0), m.ordered_index_rebuilds);
    }
}

test "NO-DRIFT CLOSE: clean close skips rebuild but unconditional save stays durable" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x9D} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    // Populate + persist a fresh ordered snapshot (STAGE E equivalent).
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.createOrderedIndex(LABEL, KEY);
        var i: i64 = 0;
        while (i < N) : (i += 1) _ = try addBenchNode(engine, i);
        try engine.checkpoint();
        try engine.close();
    }

    // First reopen: clean snapshot LOAD; tree is fresh, NOT stale, no writes follow.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        try testing.expect(engine.hasOrderedIndex(LABEL, KEY));
        try testing.expect(engine.orderedIndexFresh());
        try testing.expect(!engine.ordered_index_stale);
        try testing.expectEqual(@as(usize, @intCast(N)), cursorCount(engine));
        // SECOND close WITHOUT any intervening writes: H3-P4 skips the rebuild
        // (stale == false) but the SAVE must still run unconditionally.
        try engine.close();
    }

    // Second reopen: the no-rebuild close's snapshot still LOADS cleanly.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expect(engine.hasOrderedIndex(LABEL, KEY)); // registration durable
        try testing.expect(engine.orderedIndexFresh());
        try testing.expect(!engine.ordered_index_stale);
        try testing.expectEqual(@as(usize, @intCast(N)), cursorCount(engine)); // tree still N
        const m = engine.getMetrics();
        try testing.expectEqual(@as(u64, 1), m.ordered_index_loads); // snapshot loaded, not rebuilt
        try testing.expectEqual(@as(u64, 0), m.ordered_index_rebuilds);
    }
}
