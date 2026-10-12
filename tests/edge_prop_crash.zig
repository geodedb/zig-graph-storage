// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Edge-property prop_head WAL under-logging — committed setEdgeProperty is
// LOST on crash replay.
//
// Mechanism under test: `setEdgeProperty` rewrites the edge's prop_head
// IN-PLACE inside whichever adjacency block holds the entry — possibly a
// NON-HEAD block of BOTH chains (out-adjacency of the source and the
// co-located in-adjacency of the destination) — via
// `AdjStore.updateEdgePropHead`. Those in-place page mutations were NEVER
// WAL-imaged (the property pages themselves were, under a separate
// auto-commit txn inside putPropertyLegacy). On crash recovery the property
// chain replays but nothing references it: the adjacency entry's prop_head
// replays as its OLD value (0 for a first property; stale for an update
// that relocated the chain) from either the checkpoint image or an OLDER
// WAL image of the same block. The committed property silently vanishes.
// Same under-logging class as the edge-remove non-head fix: image exactly
// the page(s) the mutation touched, in the SAME txn as the property write.
//
// Scenario: one source, one sink, N_EDGES parallel v2 edges (126 entries
// per 4096-byte v2 block, so 320 edges force a 3-block chain in BOTH
// directions). Set a property on the FIRST edge (deepest block, head-insert
// order) and the LAST edge (head block), commit, crash, reopen:
//   * the property must be readable through the edge-property API;
//   * BOTH directions' entries must carry a live prop_head;
//   * every other edge survives untouched with its exact public_id.
// Two variants: chain durable at checkpoint (the ONLY tail records for the
// mutated block would be the missing images), and chain built inside the
// crash window (OLDER same-tail images of the block must not resurrect the
// pre-property prop_head).

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const REL: u32 = 13;

/// > 2 * entriesPerBlock(4096, v2) = 252 -> 3-block chains both directions.
const N_EDGES: usize = 320;

const PID_BASE: u64 = 0xE0DE_0000_0000_0000;

fn pid(i: usize) u64 {
    return PID_BASE | @as(u64, @intCast(i + 1));
}

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

fn expectEdgePropInt(eng: *GraphEngine, alloc: Allocator, from: u64, edge_id: u64, key: []const u8, want: i64, what: []const u8) !void {
    const v = (try eng.getEdgeProperty(from, edge_id, key, alloc)) orelse {
        std.debug.print("committed edge property '{s}' LOST after crash replay ({s})\n", .{ key, what });
        return error.EdgePropertyLost;
    };
    switch (v) {
        .int => |x| try testing.expectEqual(want, x),
        else => return error.EdgePropertyWrongType,
    }
}

/// Find the in-direction entry for `public_id` in the sink's co-located
/// in-adjacency and return its prop_head.
fn inChainPropHead(eng: *GraphEngine, sink: u64, public_id: u64) !u64 {
    var it = try eng.expandInRemoteIter(sink, null);
    defer it.deinit();
    while (try it.next()) |e| {
        if (e.public_id == public_id) return e.prop_head;
    }
    return error.EdgeMissingFromInChain;
}

fn assertScenario(eng: *GraphEngine, alloc: Allocator, source: u64, sink: u64, edge_ids: *const [N_EDGES]u64, what: []const u8) !void {
    // The committed properties are readable through the edge-property API
    // (deep block edge and head block edge).
    try expectEdgePropInt(eng, alloc, source, edge_ids[0], "w", 41, what);
    try expectEdgePropInt(eng, alloc, source, edge_ids[N_EDGES - 1], "w", 42, what);

    // BOTH directions carry a durable prop_head for the mutated edges, and
    // the referenced chain is readable.
    inline for (.{ 0, N_EDGES - 1 }, .{ 41, 42 }) |idx, want| {
        const ph = try inChainPropHead(eng, sink, pid(idx));
        if (ph == 0) {
            std.debug.print("in-direction prop_head for edge #{d} replayed as 0 ({s})\n", .{ idx, what });
            return error.InChainPropHeadLost;
        }
        const v = (try eng.getProperty(@as(u64, ph), "w", alloc)) orelse
            return error.InChainPropUnreadable;
        switch (v) {
            .int => |x| try testing.expectEqual(@as(i64, want), x),
            else => return error.EdgePropertyWrongType,
        }
    }

    // Collateral guard: every edge still present exactly once with its
    // exact public_id in both directions.
    inline for (.{ true, false }) |out_dir| {
        const seen = try alloc.alloc(bool, N_EDGES);
        defer alloc.free(seen);
        @memset(seen, false);
        var it = if (out_dir)
            try eng.expandOutIter(source, null)
        else
            try eng.expandInRemoteIter(sink, null);
        defer it.deinit();
        var n: usize = 0;
        while (try it.next()) |e| {
            if ((e.public_id >> 32) != (PID_BASE >> 32)) return error.UnknownEdgeEnumerated;
            const idx: usize = @intCast((e.public_id & 0xFFFF_FFFF) - 1);
            if (idx >= N_EDGES) return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            n += 1;
        }
        try testing.expectEqual(N_EDGES, n);
    }
}

test "edge prop_head: committed setEdgeProperty on a checkpoint-era non-head block survives a crash" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xE7} ** 16;
    const cfg = test_support.testConfig();

    var source: u64 = 0;
    var sink: u64 = 0;
    var edge_ids: [N_EDGES]u64 = undefined;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        source = try eng.allocNode();
        try eng.putNode(source, emptyNode());
        sink = try eng.allocNode();
        try eng.putNode(sink, emptyNode());
        for (&edge_ids, 0..) |*id, i| {
            id.* = try eng.addEdgeColocatedWithPublicId(source, sink, REL, pid(i));
        }
        // The 3-block chains are DURABLE here: after this checkpoint the
        // only WAL-tail records touching the mutated blocks would be the
        // images setEdgeProperty logs — if it logs none, replay keeps the
        // checkpoint-era prop_head (0) and the property vanishes.
        try eng.checkpoint();

        // Crash window: first property on the DEEPEST-block edge and on the
        // HEAD-block edge. Both auto-commit.
        try eng.setEdgeProperty(source, sink, edge_ids[0], "w", .{ .int = 41 });
        try eng.setEdgeProperty(source, sink, edge_ids[N_EDGES - 1], "w", .{ .int = 42 });

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try assertScenario(eng, alloc, source, sink, &edge_ids, "checkpoint-era chain");
}

test "edge prop_head: setEdgeProperty in the same WAL tail as the edge adds is not undone by older images" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xE8} ** 16;
    const cfg = test_support.testConfig();

    var source: u64 = 0;
    var sink: u64 = 0;
    var edge_ids: [N_EDGES]u64 = undefined;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        source = try eng.allocNode();
        try eng.putNode(source, emptyNode());
        sink = try eng.allocNode();
        try eng.putNode(sink, emptyNode());
        try eng.checkpoint();

        // Crash window: the edge adds AND the property writes share the WAL
        // tail. The adds imaged the adjacency blocks with prop_head=0; the
        // property write must image them AGAIN (later LSN) or replay
        // resurrects the pre-property entry.
        for (&edge_ids, 0..) |*id, i| {
            id.* = try eng.addEdgeColocatedWithPublicId(source, sink, REL, pid(i));
        }
        try eng.setEdgeProperty(source, sink, edge_ids[0], "w", .{ .int = 41 });
        try eng.setEdgeProperty(source, sink, edge_ids[N_EDGES - 1], "w", .{ .int = 42 });

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try assertScenario(eng, alloc, source, sink, &edge_ids, "same-tail chain");
}
