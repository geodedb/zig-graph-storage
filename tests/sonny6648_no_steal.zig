// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6648 (SONNY-6558 #5): the bytes of a transaction that has not ended
// must never reach the store files.
//
// The engine writes pages in place in the buffer pool and logs page
// after-images; recovery redoes committed transactions only and has no undo.
// So a page holding an open transaction's bytes that reached disk stayed
// there after a crash. Three paths wrote such pages:
//   - eviction of a dirty frame (steal),
//   - a checkpoint (or light checkpoint) during the transaction, which
//     flushed every dirty frame and moved the recovery frontier past it,
//   - close() with the transaction still open, which checkpointed.
// A crash in the middle of an abort is the same case: the inverses are not
// committed yet. Under `sync_mode = .deferred` a committed page could also
// reach disk before its COMMIT record was synced (atomicity).
//
// Real stores and real eviction (a 64-frame pool), no mocks. A crash is the
// process dying: the engine is torn down with no checkpoint and no close.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

const BASE: u64 = 1; // txn_stamp of the committed baseline
const OPEN: u64 = 0xBAD; // txn_stamp written by a transaction that never commits
const DONE: u64 = 0xC0; // txn_stamp written by a transaction that commits

/// Node pages created by `seed`; more than the pool holds, so reading one
/// node of each evicts every unpinned frame.
const PAGES: u64 = 100;

fn cfgSmallPool() gs.GraphConfig {
    var cfg = test_support.testConfig();
    cfg.buffer_pool_auto_size = false;
    cfg.buffer_pool_pages = 64;
    return cfg;
}

/// Simulated process death: no checkpoint, no close, no sidecar rewrite.
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
    count: u64,
    per_page: u64,

    /// The first node of node page `i` of the seeded range.
    fn onPage(self: Seed, i: u64) u64 {
        return self.first + i * self.per_page;
    }
};

/// Commit `PAGES` pages of nodes stamped `BASE` (in transactions of 10
/// pages, each fits the pool) and checkpoint them.
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
    return .{ .first = first, .count = count, .per_page = per_page };
}

/// Read one node of every seeded page twice: every frame not held is evicted.
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

// ---------------------------------------------------------------------------
// Eviction
// ---------------------------------------------------------------------------

test "SONNY-6648: eviction does not write an open transaction's pages (crash before commit)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x01 } ++ [_]u8{0x21} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const txn = try eng.beginTxn();
        try put(eng, s.onPage(0), OPEN, txn);
        try put(eng, s.onPage(PAGES - 1), OPEN, txn);
        const writes_before = eng.metrics.page_writes;
        try cyclePool(eng, s);
        // The pool did evict (the reads above went to disk) ...
        try testing.expect(eng.metrics.buffer_misses > 2 * PAGES - 2);
        // ... but wrote none of the transaction's pages.
        try testing.expectEqual(writes_before, eng.metrics.page_writes);
        // The transaction still sees its own writes.
        try expectStamp(eng, s.onPage(0), OPEN);
        try expectStamp(eng, s.onPage(PAGES - 1), OPEN);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, s.onPage(0), BASE);
        try expectStamp(eng, s.onPage(PAGES - 1), BASE);
        try expectStamp(eng, s.onPage(1), BASE);
    }
}

test "SONNY-6648: after commit the pages are evictable again and survive a crash" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x02 } ++ [_]u8{0x22} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const txn = try eng.beginTxn();
        try put(eng, s.onPage(0), DONE, txn);
        try eng.commitTxn(txn);
        const writes_before = eng.metrics.page_writes;
        try cyclePool(eng, s);
        // Committed: the page is written back when it is evicted.
        try testing.expect(eng.metrics.page_writes > writes_before);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, s.onPage(0), DONE);
    }
}

// ---------------------------------------------------------------------------
// Checkpoint and close during an open transaction
// ---------------------------------------------------------------------------

test "SONNY-6648: a checkpoint during an open transaction does not make its writes durable" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x03 } ++ [_]u8{0x23} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    for ([_]bool{ true, false }) |light| {
        {
            const eng = if (light)
                try GraphEngine.create(alloc, td.path, uuid, cfg)
            else
                try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            if (light) s = try seed(eng);
            // A commit before, and one during, the open transaction: both
            // must survive; the open transaction's write must not.
            const c1 = try eng.beginTxn();
            try put(eng, s.onPage(1), DONE, c1);
            try eng.commitTxn(c1);

            const txn = try eng.beginTxn();
            try put(eng, s.onPage(0), OPEN, txn);
            try put(eng, s.onPage(2), OPEN, txn);

            const deferred_before = eng.metrics.checkpoints_deferred;
            if (light) try eng.checkpointLight() else try eng.checkpoint();
            try testing.expectEqual(deferred_before + 1, eng.metrics.checkpoints_deferred);
            try cyclePool(eng, s);
            try crash(eng, alloc);
        }
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            try expectStamp(eng, s.onPage(0), BASE);
            try expectStamp(eng, s.onPage(1), DONE);
            try expectStamp(eng, s.onPage(2), BASE);
            // Reset page 1 for the next round, durably.
            const t = try eng.beginTxn();
            try put(eng, s.onPage(1), BASE, t);
            try eng.commitTxn(t);
            try eng.close();
        }
    }
}

test "SONNY-6648: the checkpoint deferred by an open transaction runs after it ends" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x04 } ++ [_]u8{0x24} ** 13;
    const cfg = cfgSmallPool();

    const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    const s = try seed(eng);
    const txn = try eng.beginTxn();
    try put(eng, s.onPage(0), DONE, txn);
    const lsn_before = eng.manifest.last_checkpoint_lsn;
    try eng.checkpoint();
    try testing.expectEqual(lsn_before, eng.manifest.last_checkpoint_lsn);
    try eng.commitTxn(txn);
    try eng.checkpoint();
    try testing.expect(eng.manifest.last_checkpoint_lsn > lsn_before);
    try testing.expect(!eng.isPersistenceDirty());
}

test "SONNY-6648: close with an open transaction rolls it back and keeps committed writes" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x05 } ++ [_]u8{0x25} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const c = try eng.beginTxn();
        try put(eng, s.onPage(1), DONE, c);
        try eng.commitTxn(c);
        const txn = try eng.beginTxn();
        try put(eng, s.onPage(0), OPEN, txn);
        try eng.close();
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, s.onPage(0), BASE);
        try expectStamp(eng, s.onPage(1), DONE);
    }
}

// ---------------------------------------------------------------------------
// Abort
// ---------------------------------------------------------------------------

test "SONNY-6648: a crash after each inverse of an abort leaves the state before the transaction" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x06 } ++ [_]u8{0x26} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        s = try seed(eng);
        try eng.close();
    }
    // The transaction records 4 inverses (3 updates, 1 create).
    var stop: usize = 0;
    var created: u64 = 0;
    while (stop <= 4) : (stop += 1) {
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            const txn = try eng.beginTxn();
            try put(eng, s.onPage(0), OPEN, txn);
            try put(eng, s.onPage(PAGES / 2), OPEN, txn);
            created = try eng.allocNode();
            try put(eng, created, OPEN, txn);
            try put(eng, s.onPage(PAGES - 1), OPEN, txn);
            try cyclePool(eng, s);
            eng.test_abort_crash_after = stop;
            if (stop < 4) {
                try testing.expectError(error.TestCrashInjected, eng.abortTxn(txn));
            } else {
                // Every inverse applied, COMMIT not yet written.
                try testing.expectError(error.TestCrashInjected, eng.abortTxn(txn));
            }
            try cyclePool(eng, s);
            try crash(eng, alloc);
        }
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            defer eng.close() catch {};
            try expectStamp(eng, s.onPage(0), BASE);
            try expectStamp(eng, s.onPage(PAGES / 2), BASE);
            try expectStamp(eng, s.onPage(PAGES - 1), BASE);
            try testing.expect((try eng.getNode(created)) == null);
        }
    }
}

test "SONNY-6648: a completed abort followed by a crash leaves the state before the transaction" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x07 } ++ [_]u8{0x27} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const txn = try eng.beginTxn();
        try put(eng, s.onPage(0), OPEN, txn);
        try put(eng, s.onPage(PAGES - 1), OPEN, txn);
        try cyclePool(eng, s);
        try eng.abortTxn(txn);
        try expectStamp(eng, s.onPage(0), BASE);
        try cyclePool(eng, s);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, s.onPage(0), BASE);
        try expectStamp(eng, s.onPage(PAGES - 1), BASE);
    }
}

test "SONNY-6648: an abort that cannot be undone keeps its pages off disk" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x08 } ++ [_]u8{0x28} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const txn = try eng.beginTxn();
        try put(eng, s.onPage(0), OPEN, txn);
        // A caller-imaged page: the engine cannot undo the transaction.
        try eng.logPagePublic(txn, .nodes, eng.nodePageId(s.onPage(0)));
        // SONNY-6657: with another transaction open meanwhile the abort
        // cannot discard the pages instead; it fails closed.
        const other = try eng.beginTxn();
        try eng.commitTxn(other);
        try testing.expectError(error.AbortNotUndone, eng.abortTxn(txn));
        // Reads keep working and evict everything else; the page stays.
        const writes_before = eng.metrics.page_writes;
        try cyclePool(eng, s);
        try testing.expectEqual(writes_before, eng.metrics.page_writes);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, s.onPage(0), BASE);
    }
}

// ---------------------------------------------------------------------------
// A transaction larger than the pool
// ---------------------------------------------------------------------------

test "SONNY-6648: a transaction that outgrows the pool fails cleanly; abort restores it" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x09 } ++ [_]u8{0x29} ** 13;
    const cfg = cfgSmallPool();

    var s: Seed = undefined;
    var reached: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const txn = try eng.beginTxn();
        const failed: ?anyerror = blk: {
            var i: u64 = 0;
            while (i < PAGES) : (i += 1) {
                put(eng, s.onPage(i), OPEN, txn) catch |err| break :blk err;
                reached = i + 1;
            }
            break :blk null;
        };
        try testing.expectEqual(@as(?anyerror, error.BufferPoolFull), failed);
        try testing.expect(reached > 0 and reached < PAGES);
        try eng.abortTxn(txn);
        var i: u64 = 0;
        while (i < reached) : (i += 1) try expectStamp(eng, s.onPage(i), BASE);
        // The engine keeps working: a later transaction commits.
        const c = try eng.beginTxn();
        try put(eng, s.onPage(PAGES - 1), DONE, c);
        try eng.commitTxn(c);
        try cyclePool(eng, s);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        var i: u64 = 0;
        while (i < reached) : (i += 1) try expectStamp(eng, s.onPage(i), BASE);
        try expectStamp(eng, s.onPage(PAGES - 1), DONE);
    }
}

// ---------------------------------------------------------------------------
// Deferred commit sync
// ---------------------------------------------------------------------------

test "SONNY-6648: under deferred sync a committed page is evicted only after the WAL is synced" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x0A } ++ [_]u8{0x2A} ** 13;
    var cfg = cfgSmallPool();
    cfg.sync_mode = .deferred;

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        // A bulk load: committed transactions of 10 pages each until every
        // seeded page was written, more pages than the pool holds. Their
        // COMMIT records are not synced (deferred), so their pages may not be
        // written back until the WAL is; once the pool is full of them,
        // eviction syncs the WAL and then writes them.
        const syncs_before = eng.metrics.evict_wal_syncs;
        const writes_before = eng.metrics.page_writes;
        var i: u64 = 0;
        while (i < PAGES) {
            const txn = try eng.beginTxn();
            const end = @min(PAGES, i + 10);
            while (i < end) : (i += 1) try put(eng, s.onPage(i), DONE, txn);
            try eng.commitTxn(txn);
        }
        try testing.expect(eng.metrics.evict_wal_syncs > syncs_before);
        try testing.expect(eng.metrics.page_writes > writes_before);
        // Far fewer syncs than commits: one per pool-full of committed pages.
        try testing.expect(eng.metrics.evict_wal_syncs - syncs_before < PAGES / 10);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        var i: u64 = 0;
        while (i < PAGES) : (i += 1) try expectStamp(eng, s.onPage(i), DONE);
    }
}

test "SONNY-6648: under deferred sync a checkpoint after commit makes the commit durable" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x0B } ++ [_]u8{0x2B} ** 13;
    var cfg = cfgSmallPool();
    cfg.sync_mode = .deferred;

    var s: Seed = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        s = try seed(eng);
        const txn = try eng.beginTxn();
        try put(eng, s.onPage(0), DONE, txn);
        try eng.commitTxn(txn);
        try eng.checkpoint();
        try testing.expectEqual(@as(u64, 0), eng.metrics.checkpoints_deferred);
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectStamp(eng, s.onPage(0), DONE);
    }
}

// ---------------------------------------------------------------------------
// Sharded engine
// ---------------------------------------------------------------------------

test "SONNY-6648: ShardedGraphEngine light checkpoint during an open shard transaction" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x0C } ++ [_]u8{0x2C} ** 13;
    const cfg = cfgSmallPool();

    var a: u64 = 0;
    {
        const eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        a = try eng.allocNode();
        try eng.putNode(a, test_support.emptyNode(BASE));
        try eng.checkpoint();
        // A statement transaction on the node's shard (as geode opens them).
        const shard = eng.shards[gs.shard_count.shardOfNode(a)];
        const txn = try shard.beginTxn();
        try shard.putNodeTxn(a, test_support.emptyNode(OPEN), txn);
        try eng.checkpointLight();
        try testing.expectEqual(@as(u64, 1), shard.metrics.checkpoints_deferred);
        // Crash every shard.
        for (eng.shards) |sh| {
            const p = try std.fmt.allocPrint(alloc, "{s}/wal/graph.wal.ckpt", .{sh.graph_dir.path});
            defer alloc.free(p);
            std.Io.Dir.cwd().deleteFile(io, p) catch {};
        }
        eng.deinit();
    }
    {
        const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        const rec = (try eng.getNode(a)) orelse return error.NodeMissing;
        try testing.expectEqual(BASE, rec.txn_stamp);
    }
}
