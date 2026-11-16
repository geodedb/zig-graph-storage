// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6657 (SONNY-6558 #4): abort a transaction the record-level undo
// journal cannot undo by DISCARDING its pages and REDOING the committed state.
//
// Before, such an abort (a caller-imaged page, a change to a legacy property
// chain that existed before the transaction, a journal past 1,048,576
// records, an inverse that failed) failed closed: `error.AbortNotUndone`, and
// every later write, commit and checkpoint refused until the store was
// reopened. Since SONNY-6648 an open transaction's pages are held in the
// buffer pool, never on disk. So the state before the transaction is what
// crash recovery would rebuild: the store files plus the committed WAL page
// images after the checkpoint frontier. The abort now drops the held pages,
// puts back the latest committed image of each (or lets the page reload from
// disk), restores the counters and in-memory store state, rebuilds the
// derived indexes and writes the ABORT record. Allowed only when no other
// transaction was open at any time during this one (a held page could carry
// the other's bytes); otherwise it still fails closed.
//
// Real stores and real eviction (a 64-frame pool), no mocks.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

const BASE: u64 = 1;
const OPEN: u64 = 0xBAD;
const DONE: u64 = 0xC0;
const PAGES: u64 = 100;

fn cfgSmallPool() gs.GraphConfig {
    var cfg = test_support.testConfig();
    cfg.buffer_pool_auto_size = false;
    cfg.buffer_pool_pages = 64;
    return cfg;
}

fn crash(eng: *GraphEngine, alloc: Allocator) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/wal/graph.wal.ckpt", .{eng.graph_dir.path});
    defer alloc.free(p);
    eng.deinit();
    std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const Seed = struct {
    first: u64,
    per_page: u64,
    fn onPage(self: Seed, i: u64) u64 {
        return self.first + i * self.per_page;
    }
};

fn seed(eng: *GraphEngine) !Seed {
    const per_page: u64 = eng.node_store.nodes_per_page;
    const count = PAGES * per_page;
    var first: u64 = 0;
    var made: u64 = 0;
    while (made < count) {
        const txn = try eng.beginTxn();
        const end = @min(count, made + 10 * per_page);
        while (made < end) : (made += 1) {
            const id = try eng.allocNode();
            if (made == 0) first = id;
            try eng.putNodeTxn(id, test_support.emptyNode(BASE), txn);
        }
        try eng.commitTxn(txn);
    }
    try eng.checkpoint();
    return .{ .first = first, .per_page = per_page };
}

fn cyclePool(eng: *GraphEngine, s: Seed) !void {
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        var i: u64 = 0;
        while (i < PAGES) : (i += 1) _ = try eng.getNode(s.onPage(i));
    }
}

fn expectStamp(eng: *GraphEngine, id: u64, want: u64) !void {
    const rec = (try eng.getNode(id)) orelse {
        std.debug.print("node {d} missing, want stamp {x}\n", .{ id, want });
        return error.NodeMissing;
    };
    if (rec.txn_stamp != want) {
        std.debug.print("node {d} has stamp {x}, want {x}\n", .{ id, rec.txn_stamp, want });
        return error.WrongStamp;
    }
}

fn put(eng: *GraphEngine, id: u64, stamp: u64, txn: gs.TxnId) !void {
    try eng.putNodeTxn(id, test_support.emptyNode(stamp), txn);
}

const Scene = struct {
    s: Seed,
    created: u64,
    nodes: u64,
    next_id: u64,
};

/// A committed write that is only in the WAL tail (page 1, DONE), then a
/// transaction that changes pages 1, 50 and 99, creates a node, and images
/// a page itself (so its journal cannot undo it); every other page evicted.
fn openUndoableScene(eng: *GraphEngine, s: Seed) !struct { txn: gs.TxnId, scene: Scene } {
    const c = try eng.beginTxn();
    try put(eng, s.onPage(1) + 1, DONE, c);
    try eng.commitTxn(c);
    const nodes = try eng.nodeCount();
    const next_id = eng.manifest.next_node_id;

    const txn = try eng.beginTxn();
    try put(eng, s.onPage(1), OPEN, txn);
    try put(eng, s.onPage(1) + 1, OPEN, txn);
    try put(eng, s.onPage(50), OPEN, txn);
    const created = try eng.allocNode();
    try put(eng, created, OPEN, txn);
    try put(eng, s.onPage(PAGES - 1), OPEN, txn);
    try eng.logPagePublic(txn, .nodes, eng.nodePageId(s.onPage(50)));
    try cyclePool(eng, s);
    return .{ .txn = txn, .scene = .{ .s = s, .created = created, .nodes = nodes, .next_id = next_id } };
}

fn expectBefore(eng: *GraphEngine, sc: Scene) !void {
    try expectStamp(eng, sc.s.onPage(1), BASE);
    try expectStamp(eng, sc.s.onPage(1) + 1, DONE); // committed, WAL tail only
    try expectStamp(eng, sc.s.onPage(50), BASE);
    try expectStamp(eng, sc.s.onPage(PAGES - 1), BASE);
    try expectStamp(eng, sc.s.onPage(2), BASE);
    try testing.expect((try eng.getNode(sc.created)) == null);
    try testing.expectEqual(sc.nodes, try eng.nodeCount());
}

// ---------------------------------------------------------------------------
// Discard and redo
// ---------------------------------------------------------------------------

test "SONNY-6657: an abort the journal cannot undo discards and redoes; the engine keeps working" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x57, 0x01 } ++ [_]u8{0x41} ** 13;
    const cfg = cfgSmallPool();

    var sc: Scene = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        const s = try seed(eng);
        const o = try openUndoableScene(eng, s);
        sc = o.scene;
        try eng.abortTxn(o.txn);
        try testing.expectEqual(@as(u64, 1), eng.metrics.txn_aborts_discarded);
        try expectBefore(eng, sc);
        // Not poisoned: writes, commits and checkpoints work.
        const t = try eng.beginTxn();
        try put(eng, s.onPage(2), DONE, t);
        try eng.commitTxn(t);
        try eng.checkpoint();
        try testing.expectEqual(@as(u64, 0), eng.metrics.checkpoints_deferred);
        try cyclePool(eng, s);
        try expectStamp(eng, s.onPage(1), BASE);
        try expectStamp(eng, s.onPage(50), BASE);
        try expectStamp(eng, s.onPage(2), DONE);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, sc.s.onPage(1), BASE);
        try expectStamp(eng, sc.s.onPage(1) + 1, DONE);
        try expectStamp(eng, sc.s.onPage(50), BASE);
        try expectStamp(eng, sc.s.onPage(2), DONE);
        try testing.expect((try eng.getNode(sc.created)) == null);
    }
}

test "SONNY-6657: discard-abort survives a crash and a clean reopen" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x57, 0x02 } ++ [_]u8{0x42} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    for ([_]bool{ true, false }) |do_crash| {
        var sc: Scene = undefined;
        {
            const eng = if (do_crash)
                try GraphEngine.create(alloc, td.path, uuid, cfg)
            else
                try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            if (do_crash) s = try seed(eng);
            if (!do_crash) {
                // Reset the committed marker of the first round.
                const t = try eng.beginTxn();
                try put(eng, s.onPage(1) + 1, BASE, t);
                try eng.commitTxn(t);
            }
            const o = try openUndoableScene(eng, s);
            sc = o.scene;
            try eng.abortTxn(o.txn);
            if (do_crash) try crash(eng, alloc) else try eng.close();
        }
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            defer eng.close() catch {};
            try expectBefore(eng, sc);
        }
    }
}

test "SONNY-6657: a crash at each step of a discard-abort leaves the state before the transaction" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x57, 0x03 } ++ [_]u8{0x43} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        s = try seed(eng);
        try eng.close();
    }
    inline for (std.meta.fields(GraphEngine.DiscardStep)) |f| {
        var sc: Scene = undefined;
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            // Undo the committed marker of the previous round.
            const t = try eng.beginTxn();
            try put(eng, s.onPage(1) + 1, BASE, t);
            try eng.commitTxn(t);
            const o = try openUndoableScene(eng, s);
            sc = o.scene;
            eng.test_discard_crash_at = @field(GraphEngine.DiscardStep, f.name);
            try testing.expectError(error.TestCrashInjected, eng.abortTxn(o.txn));
            try cyclePool(eng, s);
            try crash(eng, alloc);
        }
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            defer eng.close() catch {};
            expectBefore(eng, sc) catch |err| {
                std.debug.print("crash at {s}\n", .{f.name});
                return err;
            };
        }
    }
}

test "SONNY-6657: a legacy property chain changed by an aborted transaction is back" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x57, 0x04 } ++ [_]u8{0x44} ** 13;
    const cfg = test_support.testConfig();

    var id: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        id = try eng.allocNode();
        try eng.putNode(id, test_support.emptyNode(BASE));
        var rec = (try eng.getNode(id)).?;
        rec.prop_head = try eng.putPropertyLegacy(0, "k", .{ .int = 1 });
        try eng.putNode(id, rec);

        const txn = try eng.beginTxn();
        const head = try eng.putPropertyLegacyTxn(rec.prop_head, "k", .{ .int = 2 }, txn);
        if (head != rec.prop_head) {
            var r2 = rec;
            r2.prop_head = head;
            try eng.putNodeTxn(id, r2, txn);
        }
        try eng.abortTxn(txn); // used to fail closed (property_on_existing_chain)
        try testing.expectEqual(@as(u64, 1), eng.metrics.txn_aborts_discarded);
        try expectProp(eng, id, 1);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectProp(eng, id, 1);
    }
}

fn expectProp(eng: *GraphEngine, id: u64, want: i64) !void {
    const rec = (try eng.getNode(id)).?;
    const v = (try eng.getProperty(rec.prop_head, "k", testing.allocator)) orelse return error.PropertyMissing;
    try testing.expectEqual(want, v.int);
}

// ---------------------------------------------------------------------------
// Single-open-transaction rule
// ---------------------------------------------------------------------------

test "SONNY-6657: with another transaction open meanwhile, the abort still fails closed" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x57, 0x05 } ++ [_]u8{0x45} ** 13;
    const cfg = test_support.testConfig();

    const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
    defer eng.deinit();
    const a = try eng.allocNode();
    try eng.putNode(a, test_support.emptyNode(BASE));
    const txn = try eng.beginTxn();
    try put(eng, a, OPEN, txn);
    try eng.logPagePublic(txn, .nodes, eng.nodePageId(a));
    // Another transaction began (and ended) while this one was open.
    const other = try eng.beginTxn();
    try eng.commitTxn(other);
    try testing.expectError(error.AbortNotUndone, eng.abortTxn(txn));
    try testing.expectEqual(@as(u64, 0), eng.metrics.txn_aborts_discarded);
}
