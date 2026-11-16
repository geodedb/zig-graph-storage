// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6659 (SONNY-2979): a full-page WAL image committed by one
// transaction carried the bytes of another transaction still open on the
// same page, and recovery restored them after a crash: an uncommitted write
// became durable.
//
// The WAL holds page after-images, so an image cannot leave another open
// transaction's record out. A page now has at most one open writer: a write
// (its page image) by a second open transaction fails with
// `error.WriteConflict` before anything is logged; that transaction cannot
// commit and its abort undoes it in memory. The caller serializes: end the
// first transaction, then retry. (Blocking would deadlock the engine's
// single writer; per-record redo would mean a logical WAL.)
//
// Every test crashes for real (no close, no checkpoint) with t1 open.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

fn crash(eng: *GraphEngine, alloc: Allocator) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/wal/graph.wal.ckpt", .{eng.graph_dir.path});
    defer alloc.free(p);
    eng.deinit();
    std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn present(eng: *GraphEngine, id: u64) !bool {
    return (try eng.getNode(id)) != null;
}

test "SONNY-6659: the SONNY-2979 probe: t2 cannot commit t1's open bytes; t1's node is gone after a crash" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x01 } ++ [_]u8{0x51} ** 13;
    const cfg = test_support.testConfig();

    var open_node: u64 = 0;
    var refused: u64 = 0;
    var kept: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        // A committed node on a second page, for t2 to write.
        const per_page: u64 = eng.node_store.nodes_per_page;
        var filler: u64 = 0;
        while (filler < per_page) : (filler += 1) _ = try eng.allocNode();
        const other = try eng.allocNode();
        try eng.putNode(other, test_support.emptyNode(1));
        try eng.checkpoint();

        const t1 = try eng.beginTxn(); // never committed, never aborted
        open_node = 1;
        try eng.putNodeTxn(open_node, test_support.emptyNode(1), t1);

        // t2 writes the same page: refused, nothing of it is logged.
        const t2 = try eng.beginTxn();
        refused = 2;
        try testing.expectEqual(eng.nodePageId(open_node), eng.nodePageId(refused));
        try testing.expectError(error.WriteConflict, eng.putNodeTxn(refused, test_support.emptyNode(1), t2));
        try testing.expectError(error.WriteConflict, eng.commitTxn(t2));
        try eng.abortTxn(t2);
        try testing.expect(!try present(eng, refused));
        try testing.expect(try present(eng, open_node)); // t1 still sees its write

        // t3 writes another page and commits while t1 is open: allowed.
        const t3 = try eng.beginTxn();
        kept = other;
        try eng.putNodeTxn(kept, test_support.emptyNode(0xC0), t3);
        try eng.commitTxn(t3);
        try testing.expect(eng.nodePageId(kept) != eng.nodePageId(open_node));
        try testing.expectEqual(@as(u64, 1), eng.metrics.write_conflicts);
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expect(!try present(eng, open_node));
    try testing.expect(!try present(eng, refused));
    try testing.expectEqual(@as(u64, 0xC0), (try eng.getNode(kept)).?.txn_stamp);
}

test "SONNY-6659: an auto-commit write to an open transaction's page is refused and leaves nothing behind" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x02 } ++ [_]u8{0x52} ** 13;
    const cfg = test_support.testConfig();

    var open_node: u64 = 0;
    var auto: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try eng.checkpoint();
        const t1 = try eng.beginTxn();
        open_node = try eng.allocNode();
        try eng.putNodeTxn(open_node, test_support.emptyNode(1), t1);
        auto = try eng.allocNode();
        try testing.expectError(error.WriteConflict, eng.putNode(auto, test_support.emptyNode(1)));
        try testing.expect(!try present(eng, auto));
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expect(!try present(eng, open_node));
    try testing.expect(!try present(eng, auto));
}

test "SONNY-6659: once the first writer ends, the page is free; both orders" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x03 } ++ [_]u8{0x53} ** 13;
    const cfg = test_support.testConfig();

    var a: u64 = 0;
    var b: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        a = try eng.allocNode();
        b = try eng.allocNode();
        // t2 writes first, t1 (began earlier) second: the second writer is refused.
        const t1 = try eng.beginTxn();
        const t2 = try eng.beginTxn();
        try eng.putNodeTxn(b, test_support.emptyNode(2), t2);
        try testing.expectError(error.WriteConflict, eng.putNodeTxn(a, test_support.emptyNode(1), t1));
        try testing.expectError(error.WriteConflict, eng.commitTxn(t1));
        try eng.abortTxn(t1);
        try eng.commitTxn(t2);
        // t2 ended: the page takes a new writer, which commits.
        const t3 = try eng.beginTxn();
        try eng.putNodeTxn(a, test_support.emptyNode(3), t3);
        try eng.commitTxn(t3);
        // And an open t4 on it is not carried by anything: crash with it open.
        const t4 = try eng.beginTxn();
        var r = (try eng.getNode(a)).?;
        r.txn_stamp = 0xBAD;
        try eng.putNodeTxn(a, r, t4);
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(@as(u64, 3), (try eng.getNode(a)).?.txn_stamp);
    try testing.expectEqual(@as(u64, 2), (try eng.getNode(b)).?.txn_stamp);
}

test "SONNY-6659: under eviction pressure (no-steal) t1's bytes stay off disk and out of t2's images" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x04 } ++ [_]u8{0x54} ** 13;
    var cfg = test_support.testConfig();
    cfg.buffer_pool_auto_size = false;
    cfg.buffer_pool_pages = 64;

    var open_node: u64 = 0;
    var first: u64 = 0;
    var per_page: u64 = 0;
    const pages: u64 = 100;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        per_page = eng.node_store.nodes_per_page;
        var made: u64 = 0;
        while (made < pages * per_page) {
            const t = try eng.beginTxn();
            const end = @min(pages * per_page, made + 10 * per_page);
            while (made < end) : (made += 1) {
                const id = try eng.allocNode();
                if (made == 0) first = id;
                try eng.putNodeTxn(id, test_support.emptyNode(1), t);
            }
            try eng.commitTxn(t);
        }
        try eng.checkpoint();
        const t1 = try eng.beginTxn();
        open_node = first;
        var r = (try eng.getNode(open_node)).?;
        r.txn_stamp = 0xBAD;
        try eng.putNodeTxn(open_node, r, t1);
        // t2 tries the same page, then commits work on 20 other pages (the
        // pool holds every page dirtied while t1 is open: no-steal).
        const t2 = try eng.beginTxn();
        try testing.expectError(error.WriteConflict, eng.putNodeTxn(first + 1, test_support.emptyNode(0xC0), t2));
        try eng.abortTxn(t2);
        var i: u64 = 1;
        while (i < 21) : (i += 10) {
            const t = try eng.beginTxn();
            var k = i;
            while (k < @min(21, i + 10)) : (k += 1) try eng.putNodeTxn(first + k * per_page, test_support.emptyNode(0xC0), t);
            try eng.commitTxn(t);
        }
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(@as(u64, 1), (try eng.getNode(open_node)).?.txn_stamp);
    try testing.expectEqual(@as(u64, 1), (try eng.getNode(first + 1)).?.txn_stamp);
    try testing.expectEqual(@as(u64, 0xC0), (try eng.getNode(first + per_page)).?.txn_stamp);
}

test "SONNY-6659: discard-abort config: t1 un-undoable, t2 refused on its page; crash; t1's bytes gone" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x05 } ++ [_]u8{0x55} ** 13;
    const cfg = test_support.testConfig();

    var a: u64 = 0;
    var b: u64 = 0;
    for ([_]bool{ false, true }) |abort_t1| {
        {
            const eng = if (!abort_t1)
                try GraphEngine.create(alloc, td.path, uuid, cfg)
            else
                try GraphEngine.open(alloc, td.path, uuid, cfg);
            errdefer eng.deinit();
            if (!abort_t1) {
                a = try eng.allocNode();
                try eng.putNode(a, test_support.emptyNode(1));
                b = try eng.allocNode();
                try eng.putNode(b, test_support.emptyNode(1));
                try eng.checkpoint();
            }
            const t1 = try eng.beginTxn();
            var r = (try eng.getNode(a)).?;
            r.txn_stamp = 0xBAD;
            try eng.putNodeTxn(a, r, t1);
            try eng.logPagePublic(t1, .nodes, eng.nodePageId(a)); // journal cannot undo t1
            const t2 = try eng.beginTxn();
            try testing.expectError(error.WriteConflict, eng.putNodeTxn(b, test_support.emptyNode(0xC0), t2));
            try eng.abortTxn(t2);
            if (abort_t1) {
                // Overlapped by t2: no discard, fails closed; its bytes are never written.
                try testing.expectError(error.AbortNotUndone, eng.abortTxn(t1));
            }
            try crash(eng, alloc);
        }
        {
            const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
            defer eng.close() catch {};
            try testing.expectEqual(@as(u64, 1), (try eng.getNode(a)).?.txn_stamp);
            try testing.expectEqual(@as(u64, 1), (try eng.getNode(b)).?.txn_stamp);
        }
    }
}

test "SONNY-6659: discard-abort of t1 after t2 committed on another page keeps t2" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x06 } ++ [_]u8{0x56} ** 13;
    const cfg = test_support.testConfig();

    var a: u64 = 0;
    var far: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        a = try eng.allocNode();
        try eng.putNode(a, test_support.emptyNode(1));
        var k: u64 = 0;
        while (k < eng.node_store.nodes_per_page) : (k += 1) _ = try eng.allocNode();
        far = try eng.allocNode();
        try eng.putNode(far, test_support.emptyNode(1));
        try eng.checkpoint();
        // t1 alone (no overlap): un-undoable, discarded.
        const t1 = try eng.beginTxn();
        var r = (try eng.getNode(a)).?;
        r.txn_stamp = 0xBAD;
        try eng.putNodeTxn(a, r, t1);
        try eng.logPagePublic(t1, .nodes, eng.nodePageId(a));
        try eng.abortTxn(t1);
        try testing.expectEqual(@as(u64, 1), eng.metrics.txn_aborts_discarded);
        // Then a committed write on another page, and a crash.
        const t2 = try eng.beginTxn();
        try eng.putNodeTxn(far, test_support.emptyNode(0xC0), t2);
        try eng.commitTxn(t2);
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(@as(u64, 1), (try eng.getNode(a)).?.txn_stamp);
    try testing.expectEqual(@as(u64, 0xC0), (try eng.getNode(far)).?.txn_stamp);
}

test "SONNY-6659: while a refused writer's bytes are on the page, the first writer cannot image it either" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x59, 0x07 } ++ [_]u8{0x57} ** 13;
    const cfg = test_support.testConfig();

    var a: u64 = 0;
    var b: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        a = try eng.allocNode();
        try eng.putNode(a, test_support.emptyNode(1));
        b = try eng.allocNode();
        try eng.putNode(b, test_support.emptyNode(1));
        try eng.checkpoint();
        const t1 = try eng.beginTxn();
        try eng.putNodeTxn(a, test_support.emptyNode(0xA1), t1);
        const t2 = try eng.beginTxn();
        try testing.expectError(error.WriteConflict, eng.putNodeTxn(b, test_support.emptyNode(0xBAD), t2));
        // t2's bytes (b = 0xBAD) are on the page, unlogged: t1 may not image it now.
        try testing.expectError(error.WriteConflict, eng.putNodeTxn(a, test_support.emptyNode(0xA2), t1));
        try testing.expectError(error.WriteConflict, eng.commitTxn(t1));
        try eng.abortTxn(t2);
        try eng.abortTxn(t1);
        try testing.expectEqual(@as(u64, 1), (try eng.getNode(a)).?.txn_stamp);
        try testing.expectEqual(@as(u64, 1), (try eng.getNode(b)).?.txn_stamp);
        // The page is free again.
        const t3 = try eng.beginTxn();
        try eng.putNodeTxn(a, test_support.emptyNode(3), t3);
        try eng.commitTxn(t3);
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(@as(u64, 3), (try eng.getNode(a)).?.txn_stamp);
    try testing.expectEqual(@as(u64, 1), (try eng.getNode(b)).?.txn_stamp);
}
