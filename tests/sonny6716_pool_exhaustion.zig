// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6716: committed transactions must not exhaust the buffer pool.
//
// No-steal (SONNY-6648) keeps the pages of OPEN transactions off disk. A
// transaction that has committed holds nothing: its pages must be writable and
// therefore evictable. With a pool smaller than the store, a long run of small
// committed transactions must keep working; only ONE transaction that itself
// dirties more pages than the pool holds may fail, and then with a clear
// error that leaves the engine usable.
//
// Real stores, real eviction, no mocks.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;


fn cfgPool(pool: u32, deferred: bool) gs.GraphConfig {
    var cfg = test_support.testConfig();
    cfg.buffer_pool_auto_size = false;
    cfg.buffer_pool_pages = pool;
    if (deferred) cfg.sync_mode = .deferred;
    return cfg;
}

fn commitOne(eng: *GraphEngine, i: u64, pad: []const u8) !void {
    const txn = try eng.beginTxn();
    errdefer eng.abortTxn(txn) catch {};
    const id = try eng.allocNodeTxn(txn);
    try eng.putNodeTxn(id, test_support.emptyNode(i), txn);
    _ = try eng.putPropertyTxn(id, "pad", .{ .string = pad }, txn);
    const id2 = try eng.allocNodeTxn(txn);
    try eng.putNodeTxn(id2, test_support.emptyNode(i), txn);
    _ = try eng.putPropertyTxn(id2, "pad", .{ .string = pad }, txn);
    _ = try eng.addEdgeColocatedTxn(id, id2, 1, txn);
    try eng.commitTxn(txn);
}

fn run(pool: u32, deferred: bool) !void {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{ 0x67, 0x16 } ++ [_]u8{0x31} ** 14;
    const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfgPool(pool, deferred));
    defer eng.close() catch {};
    const pad = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(pad);
    @memset(pad, 'p');
    // 1500 committed one-node transactions: about 3 MB of pages, thirty
    // times the 96-page pool.
    var i: u64 = 0;
    while (i < 1500) : (i += 1) {
        commitOne(eng, i + 1, pad) catch |err| {
            std.debug.print("SONNY-6716: committed transaction #{d} failed: {s} (held frames {d})\n", .{ i, @errorName(err), eng.buffer_pool.heldFrameCount() });
            return err;
        };
    }
}

test "SONNY-6716: sequential committed transactions outgrow a small pool without BufferPoolFull (sync each commit)" {
    try run(8, false);
}

test "SONNY-6716: sequential committed transactions outgrow a small pool without BufferPoolFull (deferred sync)" {
    try run(8, true);
}

test "SONNY-6716: one transaction larger than the pool fails with BufferPoolFull and leaves frames for the caller's undo" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{ 0x67, 0x16 } ++ [_]u8{0x32} ** 14;
    const pool: u32 = 32;
    const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfgPool(pool, false));
    defer eng.close() catch {};
    const pad = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(pad);
    @memset(pad, 'p');

    const txn = try eng.beginTxn();
    var failed = false;
    var n: u64 = 0;
    while (n < 4000) : (n += 1) {
        const id = eng.allocNodeTxn(txn) catch |e| {
            try testing.expectEqual(error.BufferPoolFull, e);
            failed = true;
            break;
        };
        eng.putNodeTxn(id, test_support.emptyNode(n), txn) catch |e| {
            try testing.expectEqual(error.BufferPoolFull, e);
            failed = true;
            break;
        };
        _ = eng.putPropertyTxn(id, "pad", .{ .string = pad }, txn) catch |e| {
            try testing.expectEqual(error.BufferPoolFull, e);
            failed = true;
            break;
        };
    }
    // 4000 nodes of 1 KB are 4 MB: a 32-page (256 KB) pool cannot hold them.
    try testing.expect(failed);
    // The failure left the caller room to undo what the transaction did:
    // some frames are not held, and a thread replaying an undo may use them.
    try testing.expect(eng.buffer_pool.heldFrameCount() < pool);
    gs.buffer_pool.enterUndoReplay();
    defer gs.buffer_pool.leaveUndoReplay();
    const spare = try eng.beginTxn();
    _ = try eng.getNode(1);
    const id = try eng.allocNodeTxn(spare);
    try eng.putNodeTxn(id, test_support.emptyNode(1), spare);
    try eng.commitTxn(spare);
}
