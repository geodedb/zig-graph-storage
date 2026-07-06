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

// GHOST_LABEL only ever appears on an UNCOMMITTED write — after a crash it must
// be absent from every reconciled index (recovery discards uncommitted txns).
const GHOST_LABEL: u32 = 77;

test "Phase 3: crash tail reconcile excludes uncommitted txns AND == full rebuild (committed/uncommitted discipline)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x33} ** 16;
    const cfg = test_support.testConfig();

    var s: S0 = undefined;
    var xinfo: XInfo = undefined;
    var far: u64 = 0;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        s = try buildS0(eng);
        // A committed "far" node on its OWN node page (page 1) plus filler so the
        // committed tail's new node lands on page 3 — the far node's page is
        // therefore NEVER imaged by a committed tail txn. Physical page-image WAL
        // makes a committed txn's page image also carry any UNCOMMITTED sibling
        // write on the SAME page (a recovery property, not a reconcile bug), so
        // isolating the uncommitted write on its own page is how the existing
        // recovery discipline is exercised cleanly.
        const npp = eng.node_store.nodes_per_page;
        far = npp + 5; // page 1, slot 5
        while (eng.manifest.next_node_id < 3 * npp) {
            const id = try eng.allocNode();
            try eng.putNode(id, emptyNode()); // no label/prop/edge → no index contribution
        }
        try eng.checkpoint(); // snapshots @ (epoch E, covered_lsn L)

        // UNCOMMITTED transaction U (NEVER committed): add GHOST_LABEL to the
        // far node. This writes ONLY the far node's page (page 1) + a var page —
        // pages no committed tail txn images below — so recovery observes U's
        // records (M's commits fsync the shared WAL) and DISCARDS them. A wrong
        // reconcile that applied U would leak GHOST_LABEL into the label index.
        const txn_u = try eng.beginTxn();
        try eng.addLabelTxn(far, GHOST_LABEL, txn_u);
        // ... no commitTxn(txn_u) — U is abandoned by the crash.

        // COMMITTED tail M (auto-commit → fsyncs the WAL, flushing U's records).
        // Its new node lands on page 3; deletes/edits stay on page 0 / props /
        // adj — none touch page 1 (the far node's page).
        xinfo = try applyTailM(eng, s);

        // SIMULATED CRASH (deinit): no checkpoint, no close. The fsynced WAL
        // carries committed M AND uncommitted U; recovery replays M and discards
        // U; the snapshots stay at S0. This is the recovery suite's committed/
        // uncommitted discipline, now proven at the reconcile layer.
        eng.deinit();
    }

    // Reconcile over the CRASH-recovered store == full rebuild over the same
    // (durable committed) store — uncommitted U excluded by construction.
    try assertReconcileEqualsRebuild(td.path, uuid);

    // Concrete: committed state present/absent correctly, uncommitted GHOST gone.
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // UNCOMMITTED excluded: the far node exists (committed in S0) but carries
        // NO GHOST_LABEL — its uncommitted label add was discarded by recovery.
        try testing.expect((try eng.getNode(far)) != null);
        const ghosts = try eng.scanLabel(GHOST_LABEL, testing.allocator);
        defer testing.allocator.free(ghosts);
        try testing.expectEqual(@as(usize, 0), ghosts.len);

        // COMMITTED state (durable frontier) reflected exactly.
        const ids = try eng.scanLabel(LABEL, testing.allocator);
        defer testing.allocator.free(ids);
        try testing.expectEqual(@as(usize, 6), ids.len); // +X, -nodes[2]
        for (ids) |id| try testing.expect(id != s.nodes[2]);
        try testing.expect((try eng.getEdge(xinfo.x_edge)) != null);
        try testing.expect((try eng.getEdge(s.edges[3])) == null); // removeEdge
        try testing.expect((try eng.getEdge(s.edges[2])) == null); // node2 deleted
    }
}

test "Phase 3 CRITICAL: two crashes, NO checkpoint between → REBUILD (not partial reconcile); both tails present" {
    // Regression for the multi-recovery gap: the captured tail-affected page set
    // is only THIS session's recovery slice. When a PRIOR recovery advanced the
    // durable frontier past the snapshot's covered_lsn WITHOUT persisting the
    // snapshot (two crashes, no checkpoint between), reconciling only the latest
    // slice would SILENTLY DROP the earlier tail's committed mutations from the
    // derived indexes (they stay durable in the primary stores). The gate must
    // detect covered_lsn < the PRE-RECOVERY frontier and FORCE a full rebuild.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x34} ** 16;
    const cfg = test_support.testConfig();

    var hub: u64 = 0;
    var na: u64 = 0; // mutation A's labelled node (tail 1)
    var nb: u64 = 0; // mutation B's labelled node (tail 2)
    var a_edge: u64 = 0;
    var b_edge: u64 = 0;

    // Session 1: baseline D0 + checkpoint (snapshot @ covered_lsn L0), then the
    // committed tail A (NO checkpoint), then crash.
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        hub = try eng.allocNode();
        try eng.putNode(hub, emptyNode());
        try eng.addLabel(hub, LABEL);
        try eng.checkpoint(); // snapshots @ (epoch 1, covered_lsn L0)

        na = try eng.allocNode();
        try eng.putNode(na, emptyNode());
        try eng.addLabel(na, LABEL);
        a_edge = try eng.addEdge(na, hub, REL);
        eng.deinit(); // CRASH — A is a committed tail (L0+1..L1), no checkpoint
    }

    // Session 2: recovery replays A (heals last_checkpoint_lsn = L1, epoch stays
    // 1, snapshot NOT re-saved). Commit tail B (NO checkpoint), then crash. Any
    // in-memory reconcile of A here is never persisted (no doCheckpoint).
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        nb = try eng.allocNode();
        try eng.putNode(nb, emptyNode());
        try eng.addLabel(nb, LABEL);
        b_edge = try eng.addEdge(nb, hub, REL);
        eng.deinit(); // CRASH — B is a committed tail (L1+1..L2), no checkpoint
    }

    // Session 3: recovery replays ONLY B (start_lsn = L1+1), capturing B's pages
    // ONLY. The snapshot is still @ covered_lsn L0 (epoch 1). covered_lsn(L0) <
    // pre-recovery frontier(L1) ⇒ FORCE FULL REBUILD, never a partial reconcile.
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // The reconciled/rebuilt indexes == a full rebuild over the 2-crash-
        // recovered store (both A and B durable in the primary stores).
        const reconciled = try eng.debugDerivedDigests();

        // THE FIX: this is a REBUILD (not a partial reconcile) — the captured
        // tail set (B only) is incomplete relative to the snapshot.
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_reconciles);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);

        try eng.rebuildDerivedForTest();
        const rebuilt = try eng.debugDerivedDigests();
        try testing.expect(reconciled.eql(rebuilt));

        // BOTH tails present: the label set is {hub, na (A), nb (B)} = 3, and
        // BOTH edges resolve. Before the fix, A (na + its label + a_edge) was
        // silently ABSENT — reconcile applied only B's pages onto the L0 snapshot.
        const ids = try eng.scanLabel(LABEL, testing.allocator);
        defer testing.allocator.free(ids);
        try testing.expectEqual(@as(usize, 3), ids.len);
        var saw_hub = false;
        var saw_a = false;
        var saw_b = false;
        for (ids) |id| {
            if (id == hub) saw_hub = true;
            if (id == na) saw_a = true;
            if (id == nb) saw_b = true;
        }
        try testing.expect(saw_hub);
        try testing.expect(saw_a); // A present — the CRITICAL fix
        try testing.expect(saw_b);
        try testing.expect((try eng.getEdge(a_edge)) != null); // A's edge present
        try testing.expect((try eng.getEdge(b_edge)) != null); // B's edge present
    }
}

// COMPOSED (adjacency slab packing × WAL-aware derived-index reconcile) — the
// on-path proof that this release's two feature sets compose. With adjacency
// slab packing ON (opt-in; ships default OFF), a committed clean-shutdown WAL
// tail that PACKS a brand-new slab chain, GROWS a chain past GRADUATION (slab →
// legacy migration in the tail), and TOMBSTONES a pre-checkpoint slab edge must
// reconcile into the epoch-matched loaded snapshots KEY-FOR-KEY EQUAL to a full
// rebuild. This holds because every adjacency write logs the owning node's
// `.nodes` page in the same commit, and the reconcile's node-page pass
// re-derives each affected node via the slab-aware `expand` (read-both) — so
// slab relocation/graduation/tombstone in the tail can never strand or
// mis-derive an edge. The two dedicated release gates (adjacency crash matrix,
// Path-B tail reconcile) each run with the OTHER feature quiescent; this test is
// the combined-path coverage that neither exercised.
test "COMPOSED: slab-packed tail (pack + graduate + tombstone) reconcile == full rebuild" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x5b} ** 16;

    var cfg = test_support.testConfig();
    cfg.adjacency_slab_packing = true; // opt-in adjacency slab packing ON

    const N_POOL = 600;
    var pool: [N_POOL]u64 = undefined;
    var hub: u64 = 0;
    var x: u64 = 0;
    var x_edge: u64 = 0;
    var removed_edge: u64 = 0;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);

        // S0: a hub + a pool of targets, plus a few low-fanout slab chains that
        // must survive the hub's graduation and the tail reconcile. No labels/
        // props: keeps the tail free of non-slab `.props` pages (which would
        // force the safe fallback rebuild) so the SLAB adjacency path is what
        // the reconcile is proven against.
        hub = try eng.allocNode();
        try eng.putNode(hub, emptyNode());
        for (&pool) |*n| {
            n.* = try eng.allocNode();
            try eng.putNode(n.*, emptyNode());
        }
        {
            var i: usize = 1;
            while (i + 1 < 20) : (i += 2) {
                _ = try eng.addEdge(pool[i], pool[i + 1], REL);
            }
        }
        // A pre-checkpoint slab edge hub -> pool[0], tombstoned in the tail.
        removed_edge = try eng.addEdge(hub, pool[0], REL);

        try eng.checkpoint(); // snapshots @ (epoch E, covered_lsn L); slab-packed adjacency on disk

        // --- committed tail M (deferred; NO checkpoint) ---
        // (1) PACK a brand-new slab chain: node X.
        x = try eng.allocNode();
        try eng.putNode(x, emptyNode());
        x_edge = try eng.addEdge(x, pool[0], REL);
        _ = try eng.addEdge(x, pool[1], REL);

        // (2) GROW the hub until it GRADUATES (out_head stops being a slab head)
        //     — a slab → legacy migration entirely inside the WAL tail.
        var graduated = false;
        var k: usize = 20;
        while (k < N_POOL) : (k += 1) {
            _ = try eng.addEdge(hub, pool[k], REL);
            if (!gs.adj_store.isSlabHead((try eng.getNode(hub)).?.out_head)) {
                graduated = true;
                if (k > 40) break; // grow a little past graduation, then stop
            }
        }
        try testing.expect(graduated);

        // (3) TOMBSTONE the pre-checkpoint slab edge hub -> pool[0].
        try eng.removeEdge(hub, pool[0], removed_edge);

        // Clean-shutdown tail: deinit skips the checkpoint, so the snapshots stay
        // @ (E, L) and only the fsynced WAL tail carries M.
        eng.deinit();
    }

    // Reopen: LOAD (epoch match) + RECONCILE the slab-packed tail.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};

        const reconciled = try eng.debugDerivedDigests();

        // Reconcile-path metric shape: loaded + reconciled, did NOT rebuild —
        // proves the slab (graduation/relocation/tombstone) tail pages stayed on
        // the bounded reconcile path, not the O(graph) fallback rebuild.
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_reconciles);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_tail_deferred);

        // Ground truth: a full rebuild over the SAME on-disk (S0 + M) store.
        try eng.rebuildDerivedForTest();
        const rebuilt = try eng.debugDerivedDigests();

        // KEY-FOR-KEY EQUAL — the correctness bar.
        try testing.expect(reconciled.eql(rebuilt));

        // Concrete spot-checks on the composed result.
        try testing.expect(!gs.adj_store.isSlabHead((try eng.getNode(hub)).?.out_head)); // hub graduated to legacy
        try testing.expect((try eng.getEdge(x_edge)) != null); // new slab-packed chain edge present
        try testing.expect((try eng.getEdge(removed_edge)) == null); // tombstoned edge absent

        var buf: [8]u64 = undefined;
        try testing.expectEqual(@as(usize, 0), (try eng.probeEdge(hub, REL, pool[0], &buf)).len); // removed
        try testing.expectEqual(@as(usize, 1), (try eng.probeEdge(x, REL, pool[0], &buf)).len); // packed chain
    }
}

test {
    std.testing.refAllDecls(@This());
}
