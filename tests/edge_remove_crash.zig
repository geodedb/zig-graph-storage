// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP-ENT-0032 — committed edge REMOVE resurrects on crash when the removed
// entry lives in a NON-HEAD adjacency block.
//
// Mechanism under test: `removeEdgeTxn` used to WAL-image only the chain-HEAD
// pages (`logPage(.adj_out, out_head)` / `logPage(.in_idx, in_head)`), but
// `AdjStore.removeEdge` walks the chain and mutates WHICHEVER block holds the
// entry (swap-with-last + count-- on a possibly non-head page). A committed
// delete whose entry lives in block >= 2 was never WAL-imaged — while OLDER
// WAL images of that same page (written back when it was the head and filling
// up) ARE replayed. On crash recovery the edge therefore RESURRECTS, with its
// old public_id (duplicate-public-id hazard for geode).
//
// Same class as the GAP-ENT-0011 label var-chain bonus fix (`logVarChain`):
// image every page the mutation actually touched.
//
// Scenario: one source, one sink, N_EDGES parallel v2 edges (32 B entries →
// entriesPerBlock(4096, v2) = 126 per block, so N_EDGES = 320 forces a
// 3-block chain in BOTH directions: out-adjacency of the source and
// co-located in-adjacency of the sink). Remove the FIRST edge (lives in the
// DEEPEST block — head-insert order) and the LAST edge (lives in the head
// block, guarding the pre-existing head coverage), commit, crash
// (deinit-without-close), reopen, and assert both edges STAY deleted in both
// directions while every other edge survives with its exact public_id.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const REL: u32 = 11;

/// > 2 * entriesPerBlock(4096, ENTRY_FORMAT_V2) = 252, so the chain spans
/// THREE v2 blocks and the earliest edges live two blocks below the head.
const N_EDGES: usize = 320;

const PID_BASE: u64 = 0xD00D_0000_0000_0000;

fn pid(i: usize) u64 {
    return PID_BASE | @as(u64, @intCast(i + 1));
}

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

/// Enumerate a direction and assert the exact surviving edge set:
/// every edge except `removed_a`/`removed_b` present exactly once with its
/// exact public_id and the right endpoint; the removed ones ABSENT.
fn assertSurvivors(
    alloc: Allocator,
    it: *gs.adj_store.AdjStore.AdjEdgeIterator,
    expect_endpoint: u64,
    removed_a: usize,
    removed_b: usize,
) !void {
    const seen = try alloc.alloc(bool, N_EDGES);
    defer alloc.free(seen);
    @memset(seen, false);

    var n: usize = 0;
    while (try it.next()) |e| {
        if ((e.public_id & ~@as(u64, 0xFFFF_FFFF)) != PID_BASE) {
            std.debug.print("unknown public_id {x} in chain\n", .{e.public_id});
            return error.UnknownEdgeEnumerated;
        }
        const idx: usize = @intCast((e.public_id & 0xFFFF_FFFF) - 1);
        if (idx >= N_EDGES) return error.UnknownEdgeEnumerated;
        if (idx == removed_a or idx == removed_b) {
            std.debug.print(
                "REMOVED committed edge #{d} (public_id {x}) resurrected after crash recovery\n",
                .{ idx, e.public_id },
            );
            return error.RemovedEdgeResurrected;
        }
        try testing.expect(!seen[idx]);
        seen[idx] = true;
        try testing.expectEqual(expect_endpoint, e.neighbor);
        n += 1;
    }
    try testing.expectEqual(N_EDGES - 2, n);
    for (seen, 0..) |sn, i| {
        if (i == removed_a or i == removed_b) {
            try testing.expect(!sn);
        } else if (!sn) {
            std.debug.print("surviving edge #{d} LOST after crash recovery\n", .{i});
            return error.SurvivingEdgeLost;
        }
    }
}

test "GAP-ENT-0032: committed edge remove in a non-head adjacency block stays deleted across a crash" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xE3} ** 16;
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
        // Durable baseline: manifest.next_node_id is checkpoint-granular (a
        // KNOWN, separate gap), and the post-crash derived-index rebuild scans
        // nodes bounded by it — checkpoint here so source/sink are inside the
        // scan bound and the getEdge (edge_index) asserts below are
        // meaningful. Every edge add AND both removes stay in the crash
        // window (WAL tail only).
        try eng.checkpoint();

        for (&edge_ids, 0..) |*id, i| {
            id.* = try eng.addEdgeColocatedWithPublicId(source, sink, REL, pid(i));
        }

        // Removed entry #0 sits in the DEEPEST block of both 3-block chains
        // (head-insert order: the oldest entries are furthest from the head);
        // removed entry #N-1 sits in the HEAD block (regression guard for the
        // already-covered head case). Both removes auto-commit.
        try eng.removeEdge(source, sink, edge_ids[0]);
        try eng.removeEdge(source, sink, edge_ids[N_EDGES - 1]);

        // SIMULATED CRASH: no checkpoint, no close — only the fsynced WAL
        // survives, so recovery replay is the sole authority for both chains.
        eng.deinit();
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Outgoing direction (source's out-adjacency chain).
    {
        var it = try eng.expandOutIter(source, null);
        defer it.deinit();
        try assertSurvivors(alloc, &it, sink, 0, N_EDGES - 1);
    }

    // Incoming direction (sink's co-located in-adjacency chain).
    {
        var it = try eng.expandInRemoteIter(sink, null);
        defer it.deinit();
        try assertSurvivors(alloc, &it, source, 0, N_EDGES - 1);
    }

    // Derived-index view agrees: the removed edges do not exist, a survivor
    // does (edge_index is rebuilt from the recovered adjacency on hydration,
    // so a resurrected durable entry would surface here too).
    try testing.expect((try eng.getEdge(edge_ids[0])) == null);
    try testing.expect((try eng.getEdge(edge_ids[N_EDGES - 1])) == null);
    const survivor = (try eng.getEdge(edge_ids[1])) orelse return error.SurvivingEdgeLost;
    try testing.expectEqual(pid(1), survivor.public_id);

    // Count parity via the durable chain itself.
    {
        const rec = (try eng.getNode(source)) orelse return error.NodeInvisible;
        try testing.expectEqual(@as(u64, N_EDGES - 2), try eng.adj_out.edgeCount(rec.out_head));
    }
}
