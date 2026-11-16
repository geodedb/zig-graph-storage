// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6558: residual defects found while fixing SONNY-6527/6529.
//
//   1. Deleting an already-deleted node decremented `node_count` again.
//   2. `removeEdgeTxn` removed only the co-located in-entry: an edge added
//      through the legacy `addEdgeTxn` kept its `adj_in` entry, and
//      `GraphEngine.expandIn` (which reads `adj_in`) still returned it.
//   8. The interface's iterator wrappers own the slice / concrete iterator
//      they are handed but leaked it (and, for a page-backed iterator, left
//      its page pinned) when boxing the state ran out of memory.
//
// Real stores, no mocks.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const GraphStorage = gs.GraphStorage;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

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

fn newNode(eng: anytype) !u64 {
    const id = try eng.allocNode();
    try eng.putNode(id, test_support.emptyNode(1));
    return id;
}

// ---------------------------------------------------------------------------
// 1. Double delete
// ---------------------------------------------------------------------------

test "SONNY-6558 #1: deleting a deleted node leaves node_count alone" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x01 } ++ [_]u8{0x11} ** 13;
    const cfg = test_support.testConfig();

    var keep: u64 = 0;
    var gone: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        keep = try newNode(eng);
        gone = try newNode(eng);
        try testing.expectEqual(@as(u64, 2), try eng.nodeCount());

        try eng.deleteNode(gone);
        try testing.expectEqual(@as(u64, 1), try eng.nodeCount());
        try eng.deleteNode(gone);
        try testing.expectEqual(@as(u64, 1), try eng.nodeCount());

        // Twice in one transaction, then abort: the node is back, counted once.
        const txn = try eng.beginTxn();
        try eng.deleteNodeTxn(keep, txn);
        try eng.deleteNodeTxn(keep, txn);
        try testing.expectEqual(@as(u64, 0), try eng.nodeCount());
        try eng.abortTxn(txn);
        try testing.expectEqual(@as(u64, 1), try eng.nodeCount());
        try testing.expect((try eng.getNode(keep)) != null);
        try eng.close();
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(u64, 1), try eng.nodeCount());
        try testing.expect((try eng.getNode(keep)) != null);
        try testing.expect((try eng.getNode(gone)) == null);
    }
}

test "SONNY-6558 #1: ShardedGraphEngine double delete leaves node_count alone" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x02 } ++ [_]u8{0x12} ** 13;
    const eng = try ShardedGraphEngine.create(alloc, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};
    const a = try newNode(eng);
    _ = try newNode(eng);
    try testing.expectEqual(@as(u64, 2), try eng.nodeCount());
    try eng.deleteNode(a);
    try eng.deleteNode(a);
    try testing.expectEqual(@as(u64, 1), try eng.nodeCount());
}

// ---------------------------------------------------------------------------
// 2. removeEdgeTxn and legacy adj_in entries
// ---------------------------------------------------------------------------

fn expectInEdges(alloc: Allocator, eng: *GraphEngine, node: u64, want: []const u64) !void {
    const got = try eng.expandIn(node, null, alloc);
    defer alloc.free(got);
    if (got.len != want.len) {
        std.debug.print("expandIn({d}) returned {d} edge(s), want {d}\n", .{ node, got.len, want.len });
        return error.InEdgesWrong;
    }
    for (want) |w| {
        var found = false;
        for (got) |e| found = found or e.edge_id == w;
        if (!found) return error.InEdgeMissing;
    }
}

test "SONNY-6558 #2: removing a legacy edge removes its adj_in entry (memory, abort, crash)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x03 } ++ [_]u8{0x13} ** 13;
    const cfg = test_support.testConfig();

    var a: u64 = 0;
    var b: u64 = 0;
    var kept: u64 = 0;
    var gone: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        a = try newNode(eng);
        b = try newNode(eng);
        kept = try eng.addEdge(a, b, 7);
        gone = try eng.addEdge(a, b, 7);
        try eng.checkpoint();
        try expectInEdges(alloc, eng, b, &.{ kept, gone });

        // Removed and aborted: the in-entry is back.
        const txn = try eng.beginTxn();
        try eng.removeEdgeTxn(a, b, gone, txn);
        try expectInEdges(alloc, eng, b, &.{kept});
        try eng.abortTxn(txn);
        try expectInEdges(alloc, eng, b, &.{ kept, gone });

        // Removed and committed.
        try eng.removeEdge(a, b, gone);
        try expectInEdges(alloc, eng, b, &.{kept});
        try testing.expectEqual(@as(u64, 1), try eng.edgeCount());
        try crash(eng, alloc);
    }
    {
        // The removal is in the replayed tail.
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectInEdges(alloc, eng, b, &.{kept});
        const out = try eng.expandOut(a, null, alloc);
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectEqual(kept, out[0].edge_id);
    }
}

// ---------------------------------------------------------------------------
// 3. Edge-property slab chains in the WAL tail
// ---------------------------------------------------------------------------

const Tail = enum {
    /// An existing edge's property changed in place: only its props page is
    /// imaged.
    edge_in_place,
    /// A new edge got a property: its chain is new, its adjacency pages are
    /// imaged.
    new_edge_chain,
    /// As `edge_in_place`, after a light checkpoint left the reverse-map
    /// snapshot's stamp behind: its edge entries are not trusted.
    edge_in_place_stale_snapshot,
};

fn setProp(eng: *GraphEngine, id: u64, key: []const u8, v: i64) !void {
    var rec = (try eng.getNode(id)).?;
    const head = try eng.putProperty(rec.prop_head, key, .{ .int = v });
    if (head != rec.prop_head) {
        rec.prop_head = head;
        try eng.putNode(id, rec);
    }
}

fn hasTailFile(eng: *GraphEngine, file: gs.FileId) bool {
    const pages = eng.tail_affected_pages orelse return false;
    for (pages) |p| if (p.file_id == file) return true;
    return false;
}

/// Returns the resolved node ids (owned) or null (full rebuild required).
fn resolveAfterCrash(alloc: Allocator, tail: Tail, ids: *[3]u64) !?[]u64 {
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x30, @intFromEnum(tail) } ++ [_]u8{0x33} ** 12;
    const cfg = test_support.testConfig();
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        for (ids) |*id| {
            id.* = try newNode(eng);
            try setProp(eng, id.*, "v", 1);
        }
        const e1 = try eng.addEdgeColocated(ids[0], ids[1], 1);
        try eng.setEdgeProperty(ids[0], ids[1], e1, "w", .{ .int = 1 });
        const e2 = try eng.addEdgeColocated(ids[1], ids[2], 1);
        try eng.setEdgeProperty(ids[1], ids[2], e2, "w", .{ .int = 1 });
        try eng.checkpoint(); // derived snapshots, reverse map included
        switch (tail) {
            .edge_in_place => {
                try eng.setEdgeProperty(ids[0], ids[1], e1, "w", .{ .int = 2 });
                try setProp(eng, ids[2], "v", 9); // a node changed in place too
            },
            .new_edge_chain => {
                const e3 = try eng.addEdgeColocated(ids[2], ids[0], 1);
                try eng.setEdgeProperty(ids[2], ids[0], e3, "w", .{ .int = 5 });
            },
            .edge_in_place_stale_snapshot => {
                try setProp(eng, ids[1], "v", 3);
                try eng.checkpointLight();
                try eng.setEdgeProperty(ids[0], ids[1], e1, "w", .{ .int = 2 });
            },
        }
        try crash(eng, alloc);
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    // Preconditions: the tail touched a props page; an in-place edge change
    // imaged no adjacency page (so only the snapshot can attribute it).
    try testing.expect(hasTailFile(eng, .props));
    if (tail != .new_edge_chain) try testing.expect(!hasTailFile(eng, .adj_out));
    return eng.tailAffectedNodeIds(alloc);
}

test "SONNY-6558 #3: an in-place edge-property change in the tail needs no full rebuild" {
    const alloc = testing.allocator;
    var ids: [3]u64 = undefined;
    const got = (try resolveAfterCrash(alloc, .edge_in_place, &ids)) orelse {
        std.debug.print("edge-property slab slot forced a full rebuild\n", .{});
        return error.FullRebuildForEdgeChain;
    };
    defer alloc.free(got);
    // The node changed in place in the same tail is still found.
    try testing.expect(std.mem.indexOfScalar(u64, got, ids[2]) != null);
}

test "SONNY-6558 #3: a new edge chain in the tail needs no full rebuild" {
    const alloc = testing.allocator;
    var ids: [3]u64 = undefined;
    const got = (try resolveAfterCrash(alloc, .new_edge_chain, &ids)) orelse {
        std.debug.print("new edge-property chain forced a full rebuild\n", .{});
        return error.FullRebuildForEdgeChain;
    };
    defer alloc.free(got);
    try testing.expect(std.mem.indexOfScalar(u64, got, ids[2]) != null);
}

test "SONNY-6558 #3: edge entries of a stale reverse-map snapshot are not trusted" {
    const alloc = testing.allocator;
    var ids: [3]u64 = undefined;
    const got = try resolveAfterCrash(alloc, .edge_in_place_stale_snapshot, &ids);
    defer if (got) |g| alloc.free(g);
    try testing.expect(got == null);
}

// ---------------------------------------------------------------------------
// 4. Abort undoes a write that replaced an overflow value
// ---------------------------------------------------------------------------

const BIG: usize = 6000; // spills into a var-store (overflow) chain

fn bigValue(buf: []u8, tag: u8) []const u8 {
    for (buf, 0..) |*b, i| b.* = @intCast((i * 7 + tag) % 251);
    return buf;
}

fn expectBig(alloc: Allocator, eng: *GraphEngine, id: u64, tag: u8) !void {
    var want: [BIG]u8 = undefined;
    const rec = (try eng.getNode(id)) orelse return error.NodeLost;
    const v = (try eng.getProperty(rec.prop_head, "blob", alloc)) orelse return error.OverflowValueLost;
    defer gs.property.freeDecoded(alloc, v);
    switch (v) {
        .string => |s| try testing.expectEqualSlices(u8, bigValue(&want, tag), s),
        else => return error.WrongType,
    }
}

test "SONNY-6558 #4: aborting a write that replaced an overflow value restores it (memory, crash)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x04 } ++ [_]u8{0x14} ** 13;
    const cfg = test_support.testConfig();
    var buf: [BIG]u8 = undefined;
    var id: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        id = try newNode(eng);
        var rec = (try eng.getNode(id)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "blob", .{ .string = bigValue(&buf, 1) });
        try eng.putNode(id, rec);
        try eng.checkpoint();

        // The overflow value replaced by an inline one, then by another
        // overflow value: both writes release the old chain.
        for ([_]bool{ true, false }) |inline_value| {
            const txn = try eng.beginTxn();
            const head = (try eng.getNode(id)).?.prop_head;
            if (inline_value) {
                _ = try eng.putPropertyTxn(head, "blob", .{ .int = 0 }, txn);
            } else {
                _ = try eng.putPropertyTxn(head, "blob", .{ .string = bigValue(&buf, 2) }, txn);
            }
            try eng.abortTxn(txn); // used to fail closed: AbortNotUndone
            try expectBig(alloc, eng, id, 1);
        }
        // Had a write freed the old chain, these would take its pages and
        // overwrite the value the restored stub points at.
        for (0..3) |i| {
            const other = try newNode(eng);
            var orec = (try eng.getNode(other)).?;
            orec.prop_head = try eng.putProperty(orec.prop_head, "blob", .{ .string = bigValue(&buf, @intCast(10 + i)) });
            try eng.putNode(other, orec);
        }
        try expectBig(alloc, eng, id, 1);
        // The abort's undo is durable: crash and replay it.
        try crash(eng, alloc);
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectBig(alloc, eng, id, 1);
        // A committed replacement still frees the old chain: its pages are
        // handed out again (the free count rises at commit, not before).
        const free_before = eng.free_space_var.freeCount();
        const txn = try eng.beginTxn();
        const head = (try eng.getNode(id)).?.prop_head;
        _ = try eng.putPropertyTxn(head, "blob", .{ .int = 7 }, txn);
        try testing.expectEqual(free_before, eng.free_space_var.freeCount());
        try eng.commitTxn(txn);
        try testing.expect(eng.free_space_var.freeCount() > free_before);
    }
}

// ---------------------------------------------------------------------------
// 7. Lost label names are reported beyond std.log
// ---------------------------------------------------------------------------

var warn_calls: usize = 0;

fn countWarn(level: gs.config.LogLevel, msg: []const u8) void {
    if (level == .warn and std.mem.indexOf(u8, msg, "labels.dict") != null) warn_calls += 1;
}

test "SONNY-6558 #7: label names missing from labels.dict are counted and sent to log_fn" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x07 } ++ [_]u8{0x17} ** 13;
    var cfg = test_support.testConfig();
    var dict: []u8 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        _ = try eng.getOrAssignLabel("A");
        _ = try eng.getOrAssignLabel("B");
        _ = try eng.getOrAssignLabel("C");
        dict = try std.fmt.allocPrint(alloc, "{s}/labels.dict", .{eng.graph_dir.path});
        try eng.close();
    }
    defer alloc.free(dict);
    // What a <= 0.4.13 crash between the manifest and labels.dict left:
    // a manifest counting names the dictionary does not hold.
    std.Io.Dir.cwd().deleteFile(io, dict) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    warn_calls = 0;
    cfg.log_fn = countWarn;
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(@as(u64, 3), eng.metrics.label_names_lost);
    try testing.expectEqual(@as(usize, 1), warn_calls);
}

// ---------------------------------------------------------------------------
// 8. Interface iterator wrappers on allocation failure
// ---------------------------------------------------------------------------

fn pinnedFrames(eng: *GraphEngine) u64 {
    var n: u64 = 0;
    for (eng.buffer_pool.frames) |*f| {
        const c = @atomicLoad(u32, &f.pin_count, .acquire);
        if (c != 0 and c != std.math.maxInt(u32)) n += c;
    }
    return n;
}

fn drainEdges(alloc: Allocator, st: GraphStorage, id: u64, zero_copy: bool) !void {
    var it = if (zero_copy) try st.expandOutIter(id, null, alloc) else try st.expandOut(id, null, alloc);
    defer it.deinit();
    while (try it.next()) |_| {}
}

fn openProps(alloc: Allocator, st: GraphStorage, head: u64) !void {
    var it = try st.getAllProperties(head, alloc);
    defer it.deinit();
}

fn scanNodes(alloc: Allocator, st: GraphStorage, label: gs.LabelId) !void {
    var it = try st.scanLabelIter(label, alloc);
    defer it.deinit();
    while (try it.next()) |_| {}
}

test "SONNY-6558 #8: interface iterator wrappers release what they own when boxing fails" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x58, 0x08 } ++ [_]u8{0x18} ** 13;
    const eng = try GraphEngine.create(alloc, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    const a = try newNode(eng);
    const b = try newNode(eng);
    _ = try eng.addEdge(a, b, 1);
    _ = try eng.addEdge(a, b, 2);
    var rec = (try eng.getNode(a)).?;
    rec.prop_head = try eng.putProperty(rec.prop_head, "k", .{ .int = 5 });
    try eng.putNode(a, rec);
    const label = try eng.getOrAssignLabel("L");
    try eng.addLabel(a, label);
    try eng.addLabel(b, label);

    const st = eng.storage();
    const before = pinnedFrames(eng);
    try std.testing.checkAllAllocationFailures(alloc, drainEdges, .{ st, a, false });
    try std.testing.checkAllAllocationFailures(alloc, drainEdges, .{ st, a, true });
    try std.testing.checkAllAllocationFailures(alloc, openProps, .{ st, rec.prop_head });
    try std.testing.checkAllAllocationFailures(alloc, scanNodes, .{ st, label });
    const after = pinnedFrames(eng);
    if (after != before) {
        std.debug.print("{d} page pin(s) leaked by failed iterator wraps\n", .{after - before});
        return error.PagePinLeaked;
    }
}
