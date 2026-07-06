// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// WAL-aware derived-index durability (Path B) Phase 2 — the epoch-gate
// acceptance proofs (the "layer-8" reopen scenario as a gs test).
//
// The derived-index reload gate now compares the snapshot's durable
// `checkpoint_epoch` against `manifest.checkpoint_epoch` instead of
// `manifest.counter`. The epoch advances ONLY at checkpoint, NEVER by a
// WAL-tail recovery (proven by test_checkpoint_epoch.zig), so:
//
//   (A) NO-TAIL CLEAN REOPEN: a snapshot whose epoch matches AND whose
//       covered_lsn == the durable frontier is served directly (LOAD, no
//       rebuild). This is the fast warm-reopen the whole contract exists for.
//
//   (B) TAIL-PRESENT CRASH REOPEN: recovery replays a committed WAL tail and
//       bumps manifest.counter PAST the snapshot stamp — but the epoch is
//       UNCHANGED, so the gate no longer wrongly rejects on the counter. It
//       ACCEPTS the epoch (derived_index_tail_deferred is counted), LOADS the
//       snapshot, and RECONCILES the bounded tail-affected pages into it
//       (derived_index_reconciles; Phase 3) — NOT a full rebuild. The
//       reconciled index MUST reflect the tail (the reconcile == a rebuild;
//       proven exhaustively in test_index_tail_reconcile.zig).

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

/// Create `n` LABEL-labelled nodes (each with an int "score" property) in a
/// ring of `n` edges. Returns the node ids.
fn populate(eng: *GraphEngine, comptime n: usize) ![n]u64 {
    var nodes: [n]u64 = undefined;
    for (&nodes, 0..) |*node, i| {
        node.* = try eng.allocNode();
        try eng.putNode(node.*, emptyNode());
        try eng.addLabel(node.*, LABEL);
        var rec = (try eng.getNode(node.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "score", .{ .int = @intCast(i) });
        try eng.putNode(node.*, rec);
    }
    for (&nodes, 0..) |node, i| {
        _ = try eng.addEdge(node, nodes[(i + 1) % n], REL);
    }
    return nodes;
}

fn labelCount(eng: *GraphEngine) !usize {
    const ids = try eng.scanLabel(LABEL, testing.allocator);
    defer testing.allocator.free(ids);
    return ids.len;
}

test "Phase 2 A: no-tail clean reopen LOADS via the epoch gate (rebuild==0)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xA1} ** 16;
    const cfg = test_support.testConfig();

    const N = 12;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        _ = try populate(eng, N);
        // All four derived snapshots saved at epoch E, covered_lsn L; the WAL is
        // truncated to L, so a clean reopen has NO tail beyond the snapshot.
        try eng.checkpoint();
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // First derived access (a READ) hydrates via the counter-independent
        // epoch gate: epoch matches AND covered_lsn == last_checkpoint_lsn
        // (no tail) → LOAD.
        try testing.expectEqual(@as(usize, N), try labelCount(eng));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
        // Not a tail case — the deferral counter stays 0.
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_tail_deferred);
    }
}

test "Phase 3 B: crash-tail reopen — epoch MATCHES, snapshot LOADS, tail RECONCILES (not rebuild), never stale" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB2} ** 16;
    // sync_each_commit: the post-checkpoint WAL tail is fsynced and survives the
    // simulated crash for recovery to replay.
    const cfg = test_support.testConfig();

    const N = 12;
    var epoch_at_checkpoint: u64 = 0;
    var counter_at_checkpoint: u64 = 0;
    var tail_node: u64 = 0;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        _ = try populate(eng, N);
        try eng.checkpoint(); // snapshots @ (epoch E, covered_lsn L)
        epoch_at_checkpoint = eng.manifest.checkpoint_epoch;
        counter_at_checkpoint = eng.manifest.counter;

        // Committed WAL-tail mutation AFTER the snapshot save, WITHOUT a
        // checkpoint: a new LABEL-labelled node the snapshot does not reflect.
        tail_node = try eng.allocNode();
        try eng.putNode(tail_node, emptyNode());
        try eng.addLabel(tail_node, LABEL);
        var rec = (try eng.getNode(tail_node)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "score", .{ .int = 9999 });
        try eng.putNode(tail_node, rec);

        // SIMULATED CRASH: no checkpoint, no close — only the WAL tail survives.
        eng.deinit();
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Recovery replayed the tail: manifest.counter advanced past the snapshot
        // stamp, but checkpoint_epoch is UNCHANGED (the invariant the gate rests
        // on). Under the OLD counter gate this reopen rejected on the counter;
        // now the epoch MATCHES.
        try testing.expect(eng.manifest.counter > counter_at_checkpoint);
        try testing.expectEqual(epoch_at_checkpoint, eng.manifest.checkpoint_epoch);

        // First derived access hydrates. THE PHASE 3 ASSERTIONS:
        //  - the epoch matched (else the mismatch branch would return before the
        //    tail check) → derived_index_tail_deferred == 1;
        //  - covered_lsn < the replayed durable frontier → the snapshot LOADED
        //    and the bounded tail was RECONCILED into it (loads==1,
        //    reconciles==1), NOT a full rebuild (rebuilds==0).
        const count = try labelCount(eng);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_tail_deferred);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_reconciles);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);

        // CORRECTNESS (never serve stale): the reconcile reflects the committed
        // tail node — the label set is N+1 and includes tail_node.
        try testing.expectEqual(@as(usize, N + 1), count);
        const ids = try eng.scanLabel(LABEL, testing.allocator);
        defer testing.allocator.free(ids);
        var saw_tail = false;
        for (ids) |id| {
            if (id == tail_node) saw_tail = true;
        }
        try testing.expect(saw_tail);
    }
}

test {
    std.testing.refAllDecls(@This());
}
