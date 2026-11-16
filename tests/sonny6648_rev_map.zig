// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6648: node writes made before the derived indexes are hydrated must
// reach the reverse map (prop_head -> owner).
//
// After an open the derived indexes are hydrated lazily, on first use.
// `putNodeTxn` and `deleteNodeTxn` (and their undo) do not hydrate; they
// skipped the reverse map, assuming the hydration scan would see their
// result. But hydration usually LOADS the snapshot saved at the last
// checkpoint (or loads it and reconciles the pre-open WAL tail), which knows
// nothing of this session's writes: the map kept the old owner of a chain
// that had moved, and kept the chain of a deleted node. The tail resolution
// of the next crash recovery trusts the map (SONNY-6558 #3).
//
// Real stores, no mocks.

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

fn setProp(eng: *GraphEngine, id: u64, key: []const u8, v: i64) !void {
    var rec = (try eng.getNode(id)).?;
    const head = try eng.putProperty(rec.prop_head, key, .{ .int = v });
    if (head != rec.prop_head) {
        rec.prop_head = head;
        try eng.putNode(id, rec);
    }
}

const Store = struct { a: u64, b: u64, c: u64, head_a: u64, head_b: u64 };

/// a and b carry a property chain, c none. Fully checkpointed and closed,
/// so the next open loads a clean reverse-map snapshot.
fn build(alloc: Allocator, path: [:0]const u8, uuid: [16]u8, cfg: gs.GraphConfig) !Store {
    const eng = try GraphEngine.create(alloc, path, uuid, cfg);
    errdefer eng.deinit();
    var s: Store = undefined;
    inline for (.{ "a", "b", "c" }) |f| {
        const id = try eng.allocNode();
        try eng.putNode(id, test_support.emptyNode(1));
        @field(s, f) = id;
    }
    try setProp(eng, s.a, "k", 1);
    try setProp(eng, s.b, "k", 2);
    s.head_a = (try eng.getNode(s.a)).?.prop_head;
    s.head_b = (try eng.getNode(s.b)).?.prop_head;
    try testing.expect(s.head_a != 0 and s.head_b != 0 and s.head_a != s.head_b);
    try eng.checkpoint();
    try eng.close();
    return s;
}

/// a's chain moves to c, b is deleted. No write here hydrates.
fn moveAndDelete(eng: *GraphEngine, s: Store, txn: gs.TxnId) !void {
    var ra = (try eng.getNode(s.a)).?;
    ra.prop_head = 0;
    try eng.putNodeTxn(s.a, ra, txn);
    var rc = (try eng.getNode(s.c)).?;
    rc.prop_head = s.head_a;
    try eng.putNodeTxn(s.c, rc, txn);
    try eng.deleteNodeTxn(s.b, txn);
}

fn expectOwner(eng: *GraphEngine, head: u64, want: ?u64) !void {
    const got: ?u64 = if (eng.prop_rev_index.owner(head)) |o| switch (o) {
        .node => |n| n,
        .edge => return error.OwnedByEdge,
    } else null;
    if (got != want) {
        std.debug.print("reverse map: head {x} owned by {?d}, want {?d}\n", .{ head, got, want });
        return error.WrongOwner;
    }
}

fn expectMoved(eng: *GraphEngine, s: Store) !void {
    try expectOwner(eng, s.head_a, s.c);
    try expectOwner(eng, s.head_b, null);
}

fn expectOriginal(eng: *GraphEngine, s: Store) !void {
    try expectOwner(eng, s.head_a, s.a);
    try expectOwner(eng, s.head_b, s.b);
}

test "SONNY-6648: committed node writes before hydration reach the reverse map" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x21 } ++ [_]u8{0x31} ** 13;
    const cfg = test_support.testConfig();
    const s = try build(alloc, td.path, uuid, cfg);

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try testing.expect(!eng.derived_hydrated.load(.acquire));
        const txn = try eng.beginTxn();
        try moveAndDelete(eng, s, txn);
        try eng.commitTxn(txn);
        // The writes above did not hydrate: this is the case under test.
        try testing.expect(!eng.derived_hydrated.load(.acquire));
        try eng.ensureDerivedHydrated();
        try expectMoved(eng, s);
        try eng.close();
    }
    {
        // The corrected map was saved by the closing checkpoint.
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try eng.ensureDerivedHydrated();
        try expectMoved(eng, s);
    }
}

test "SONNY-6648: an aborted node write before hydration leaves the reverse map as it was" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x22 } ++ [_]u8{0x32} ** 13;
    const cfg = test_support.testConfig();
    const s = try build(alloc, td.path, uuid, cfg);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    const txn = try eng.beginTxn();
    try moveAndDelete(eng, s, txn);
    try eng.abortTxn(txn);
    try testing.expect(!eng.derived_hydrated.load(.acquire));
    try eng.ensureDerivedHydrated();
    try expectOriginal(eng, s);
}

test "SONNY-6648: node writes before hydration, then a crash: the reconciled map is right" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x23 } ++ [_]u8{0x33} ** 13;
    const cfg = test_support.testConfig();
    const s = try build(alloc, td.path, uuid, cfg);

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        const txn = try eng.beginTxn();
        try moveAndDelete(eng, s, txn);
        try eng.commitTxn(txn);
        try crash(eng, alloc);
    }
    {
        // The writes are in the replayed tail: the loaded snapshot is
        // reconciled from it.
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try eng.ensureDerivedHydrated();
        try expectMoved(eng, s);
    }
}

test "SONNY-6648: more pending node writes than are queued: hydration rescans the map" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x66, 0x48, 0x24 } ++ [_]u8{0x34} ** 13;
    const cfg = test_support.testConfig();
    const s = try build(alloc, td.path, uuid, cfg);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    eng.rev_map_pending_cap = 2; // three ops below: the queue overflows
    const txn = try eng.beginTxn();
    try moveAndDelete(eng, s, txn);
    try eng.commitTxn(txn);
    try testing.expect(!eng.derived_hydrated.load(.acquire));
    try eng.ensureDerivedHydrated();
    try expectMoved(eng, s);
}
