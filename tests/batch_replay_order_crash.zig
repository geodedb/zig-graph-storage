// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Recovery replays page images in log order, not LSN order (SONNY-6473).
//
// `TxnManager.begin` opens the WalManager's single record batch (GAP-0900) for
// the first transaction that asks. Its page images are numbered when they are
// made (`WalManager.appendRecord` assigns the LSN, then serializes the page
// into the batch arena) but reach the log only at that transaction's commit.
// A second transaction on the same TxnManager that begins while the batch is
// open writes its records straight through. When both image the same page,
// the log holds the NEWER image (higher LSN) first and the OLDER image of the
// batched transaction after it. Recovery applied images in log order, so the
// older image won and a committed write was lost after a crash.
//
// geode reproduced this with a real server (SONNY-2978: START TRANSACTION;
// CREATE x64; MATCH (n) REMOVE n.p; COMMIT; SIGKILL brought p back on every
// node). These tests drive the same interleaving through the public engine
// API and crash the engine the way a dead process does.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

/// Drop the engine the way a dead process does: no checkpoint, no close, and
/// no WAL sidecar rewrite (see tests/wal_lsn_anchor_crash.zig).
fn simulateProcessExit(alloc: Allocator, eng: *GraphEngine) !void {
    const wal_dir_path = try std.fmt.allocPrint(alloc, "{s}/wal", .{eng.graph_dir.path});
    defer alloc.free(wal_dir_path);
    eng.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, wal_dir_path, .{});
    defer dir.close(io);
    dir.deleteFile(io, "graph.wal.ckpt") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn setInt(eng: *GraphEngine, id: u64, key: []const u8, v: i64) !void {
    var rec = (try eng.getNode(id)).?;
    rec.prop_head = try eng.putProperty(rec.prop_head, key, .{ .int = v });
    try eng.putNode(id, rec);
}

fn expectInt(alloc: Allocator, eng: *GraphEngine, id: u64, key: []const u8, want: ?i64, what: []const u8) !void {
    const rec = (try eng.getNode(id)) orelse {
        std.debug.print("{s}: committed node {d} LOST after crash recovery\n", .{ what, id });
        return error.CommittedNodeLost;
    };
    const got = try eng.getProperty(rec.prop_head, key, alloc);
    if (want) |w| {
        const v = got orelse {
            std.debug.print("{s}: node {d} lost committed property '{s}' (want {d})\n", .{ what, id, key, w });
            return error.CommittedPropertyLost;
        };
        switch (v) {
            .int => |x| if (x != w) {
                std.debug.print("{s}: node {d} '{s}' = {d} after recovery, committed value is {d} (an older page image won)\n", .{ what, id, key, x, w });
                return error.OlderImageReplayed;
            },
            else => return error.CommittedPropertyWrongType,
        }
    } else if (got != null) {
        std.debug.print("{s}: node {d} property '{s}' was removed by a committed txn but came back after recovery\n", .{ what, id, key });
        return error.RemovedPropertyResurrected;
    }
}

test "SONNY-6473: a committed write survives when an older overlapping batched txn commits after it" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x73} ** 16;
    const cfg = test_support.testConfig();

    var x: u64 = 0;
    var y: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();

        x = try eng.allocNode();
        try eng.putNode(x, test_support.emptyNode(1));
        try setInt(eng, x, "v", 1);
        try eng.checkpoint();

        // Txn A begins first and takes the WAL batch. Its node-page image
        // (X still heading the v = 1 chain) is numbered now, written at commit.
        const a = try eng.beginTxn();
        y = try eng.allocNode();
        try eng.putNodeTxn(y, test_support.emptyNode(2), a);

        // An auto-commit write on the same node page while A is open: X now
        // heads a fresh property chain with v = 2. Its node-page image (new
        // head, plus A's Y) is numbered and written after A's.
        var xr = (try eng.getNode(x)).?;
        xr.prop_head = try eng.putProperty(0, "v", .{ .int = 2 });
        try eng.putNode(x, xr);

        // A commits last, so its older image lands after the newer one.
        try eng.commitTxn(a);

        try expectInt(alloc, eng, x, "v", 2, "before crash");
        try simulateProcessExit(alloc, eng);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectInt(alloc, eng, x, "v", 2, "crash recovery");
        try testing.expect((try eng.getNode(y)) != null);
    }
}

test "SONNY-6473: geode SONNY-2978 shape — batched creates, overlapping removal, commit, crash" {
    // START TRANSACTION; CREATE x N; (removal of p on every created node runs
    // as separate auto-commit writes while the creating txn is open); COMMIT;
    // SIGKILL. Every removal is committed and must stay removed.
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x74} ** 16;
    const cfg = test_support.testConfig();

    const n = 64;
    var ids: [n]u64 = undefined;
    var heads: [n]u64 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();

        const t = try eng.beginTxn();
        for (&ids, &heads) |*id, *head| {
            id.* = try eng.allocNode();
            var rec = test_support.emptyNode(3);
            rec.prop_head = try eng.putPropertyTxn(0, "p", .{ .int = 7 }, t);
            head.* = rec.prop_head;
            try eng.putNodeTxn(id.*, rec, t);
        }
        // Removal: point each node at an empty property chain, committed
        // immediately on its own txn.
        for (ids) |id| {
            var rec = (try eng.getNode(id)).?;
            rec.prop_head = 0;
            try eng.putNode(id, rec);
        }
        try eng.commitTxn(t);

        for (ids) |id| try expectInt(alloc, eng, id, "p", null, "before crash");
        try simulateProcessExit(alloc, eng);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        var resurrected: usize = 0;
        for (ids) |id| {
            expectInt(alloc, eng, id, "p", null, "crash recovery") catch |err| switch (err) {
                error.RemovedPropertyResurrected => resurrected += 1,
                else => return err,
            };
        }
        if (resurrected != 0) {
            std.debug.print("crash recovery: {d}/{d} committed removals undone\n", .{ resurrected, n });
            return error.RemovedPropertyResurrected;
        }
    }
}
