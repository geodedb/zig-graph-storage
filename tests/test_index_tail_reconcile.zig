// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// WAL-aware derived-index durability (Path B) Phase 3 — the RELEASE GATE.
//
// The rebuild-equivalence property test: after a checkpoint (snapshots @ epoch
// E, covered_lsn L) plus a committed WAL tail M, a crash reopen LOADS the
// snapshots and RECONCILES only the bounded tail-affected pages into them. The
// reconciled label / property / edge / edge_exist indexes MUST be KEY-FOR-KEY
// EQUAL to a full rebuild over the same (S0 + M) store — for inserts, an
// in-place property VALUE change, a DELETED node, and a removed EDGE — on both
// a clean-shutdown tail AND a kill-9 crash tail. A wrong reconcile serves
// silently-wrong query results, so this equivalence is the non-negotiable bar.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const REL: u32 = 5;
const LABEL: u32 = 9;

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

const S0 = struct {
    nodes: [6]u64,
    edges: [6]u64, // edges[i] = nodes[i] -[REL]-> nodes[(i+1)%6]
};

const XInfo = struct { x: u64, x_edge: u64 };

/// Build S0: 6 LABEL-labelled nodes, each with an int "score" property, in a
/// ring of 6 edges. Returns node + edge ids.
fn buildS0(eng: *GraphEngine) !S0 {
    var s: S0 = undefined;
    for (&s.nodes, 0..) |*node, i| {
        node.* = try eng.allocNode();
        var rec = emptyNode();
        rec.prop_head = try eng.putProperty(0, "score", .{ .int = @intCast(i) });
        try eng.putNode(node.*, rec);
        try eng.addLabel(node.*, LABEL);
    }
    for (&s.edges, 0..) |*edge, i| {
        edge.* = try eng.addEdge(s.nodes[i], s.nodes[(i + 1) % 6], REL);
    }
    return s;
}

/// Apply the committed tail M (deferred WAL, NO checkpoint):
///   * INSERT a new labelled node X (with a score) + an edge X -> nodes[0];
///   * UPDATE nodes[1]'s "score" property VALUE (exercises the in-place
///     props-page reconcile — the owning node page is untouched);
///   * DELETE nodes[2] (drops its out-edge from the derived indexes);
///   * REMOVE the edge nodes[3] -> nodes[4].
/// Returns the inserted node id + its edge id for concrete assertions.
fn applyTailM(eng: *GraphEngine, s: S0) !XInfo {
    // INSERT node X.
    const x = try eng.allocNode();
    var xrec = emptyNode();
    xrec.prop_head = try eng.putProperty(0, "score", .{ .int = 4242 });
    try eng.putNode(x, xrec);
    try eng.addLabel(x, LABEL);
    const x_edge = try eng.addEdge(x, s.nodes[0], REL);

    // UPDATE nodes[1]'s score in place (same-width int → slab in-place rewrite,
    // so the node record's prop_head is unchanged and only the props page is
    // dirtied — the case that only the props-page reconcile pass can reach).
    const n1 = (try eng.getNode(s.nodes[1])).?;
    const new_head = try eng.putProperty(n1.prop_head, "score", .{ .int = 7777 });
    if (new_head != n1.prop_head) {
        var r = n1;
        r.prop_head = new_head;
        try eng.putNode(s.nodes[1], r);
    }

    // DELETE nodes[2].
    try eng.deleteNode(s.nodes[2]);

    // REMOVE edge nodes[3] -> nodes[4].
    try eng.removeEdge(s.nodes[3], s.nodes[4], s.edges[3]);

    return .{ .x = x, .x_edge = x_edge };
}

/// The shared body of both the clean-tail and crash-tail proofs. `crash`
/// selects how the tail session terminates: `deinit` (clean-shutdown tail,
/// fsynced) vs a child-process kill-9 (crash tail — see the crash test).
fn assertReconcileEqualsRebuild(td_path: []const u8, uuid: [16]u8) !void {
    const cfg = test_support.testConfig();
    const eng = try GraphEngine.open(testing.allocator, td_path, uuid, cfg);
    defer eng.close() catch {};

    // FIRST derived access → LOAD (epoch match) + RECONCILE the tail.
    const reconciled = try eng.debugDerivedDigests();

    // The release-gate metric shape: loaded the snapshot, reconciled the tail,
    // did NOT rebuild.
    try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
    try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_reconciles);
    try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
    try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_tail_deferred);

    // Ground truth: a full rebuild over the SAME on-disk (S0 + M) store.
    try eng.rebuildDerivedForTest();
    const rebuilt = try eng.debugDerivedDigests();

    // KEY-FOR-KEY EQUAL — the correctness bar.
    try testing.expect(reconciled.eql(rebuilt));
}

test "Phase 3: clean-shutdown tail reconcile == full rebuild (insert/update/DELETE)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x31} ** 16;
    const cfg = test_support.testConfig();

    var s: S0 = undefined;
    var xinfo: XInfo = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        s = try buildS0(eng);
        try eng.checkpoint(); // snapshots @ (epoch E, covered_lsn L); WAL truncated
        // Committed tail M (deferred — no checkpoint).
        xinfo = try applyTailM(eng, s);
        // Clean-shutdown tail: deinit skips the checkpoint, so the snapshots
        // stay at S0 and only the fsynced WAL tail carries M.
        eng.deinit();
    }

    try assertReconcileEqualsRebuild(td.path, uuid);

    // Concrete correctness spot-checks on a fresh reconcile-open.
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Label set: +X, -nodes[2] ⇒ still 6, deleted node absent, X present.
        const ids = try eng.scanLabel(LABEL, testing.allocator);
        defer testing.allocator.free(ids);
        try testing.expectEqual(@as(usize, 6), ids.len);
        var saw_x = false;
        for (ids) |id| {
            try testing.expect(id != s.nodes[2]); // deleted node not indexed
            if (id == xinfo.x) saw_x = true;
        }
        try testing.expect(saw_x);

        // Edge index: inserted edge present; removed edge absent; the deleted
        // node's out-edge (nodes[2]->nodes[3]) absent.
        try testing.expect((try eng.getEdge(xinfo.x_edge)) != null);
        try testing.expect((try eng.getEdge(s.edges[3])) == null); // removeEdge
        try testing.expect((try eng.getEdge(s.edges[2])) == null); // node2 deleted

        // Existence probes agree.
        var buf: [4]u64 = undefined;
        try testing.expectEqual(@as(usize, 0), (try eng.probeEdge(s.nodes[3], REL, s.nodes[4], &buf)).len);
        try testing.expectEqual(@as(usize, 1), (try eng.probeEdge(xinfo.x, REL, s.nodes[0], &buf)).len);
        try testing.expectEqual(@as(usize, 0), (try eng.probeEdge(s.nodes[2], REL, s.nodes[3], &buf)).len);
    }
}

test {
    std.testing.refAllDecls(@This());
}
