// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// checkpoint_epoch invariant — the core of the WAL-aware derived-index
// durability contract (Path B, Task 1.2).
//
// `manifest.checkpoint_epoch` is the durable freshness token a persisted
// derived-index snapshot stamps. Unlike `manifest.counter` (bumped by BOTH
// checkpoint and recovery, for A/B slot freshness) and
// `manifest.last_checkpoint_lsn` (overwritten by recovery when it replays a
// tail), the epoch must advance ONLY at `checkpoint.zig:doCheckpoint` and stay
// UNCHANGED across a pure WAL-tail recovery. A snapshot taken at epoch E is
// therefore still valid-as-of its covered LSN after a crash reopen that only
// replayed committed tail records — which is what lets index-served reads stay
// fast after a crash instead of paying an O(graph) rebuild.
//
// This test is the invariant the whole contract rests on: it does NOT change
// any index behavior yet (Phases 2/3), it only proves the epoch's advance and
// recovery-invariance semantics on the manifest.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const test_support = gs.test_support;

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

test "checkpoint_epoch advances only at checkpoint, never across a WAL-tail recovery" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xE1} ** 16;
    const cfg = test_support.testConfig();

    var counter_after_checkpoint: u64 = 0;

    // (1) Create + checkpoint: epoch 0 -> 1.
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        try testing.expectEqual(@as(u64, 0), eng.manifest.checkpoint_epoch);

        const a = try eng.allocNode();
        try eng.putNode(a, emptyNode());
        try eng.checkpoint(); // epoch advances here, and ONLY here.
        try testing.expectEqual(@as(u64, 1), eng.manifest.checkpoint_epoch);
        counter_after_checkpoint = eng.manifest.counter;

        // (2) Committed WAL records WITHOUT a checkpoint: a deferred tail that
        //     lives only in the fsynced WAL until the next checkpoint.
        const b = try eng.allocNode();
        try eng.putNode(b, emptyNode());
        const c = try eng.allocNode();
        try eng.putNode(c, emptyNode());

        // SIMULATED CRASH: no checkpoint, no close — only the WAL tail survives.
        eng.deinit();
    }

    // (3) Reopen: recovery replays the committed tail. `counter` advances (A/B
    //     freshness bump at the replay path) but `checkpoint_epoch` must NOT —
    //     the snapshot stamped at epoch 1 is still valid after this recovery.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};

        if (eng.manifest.checkpoint_epoch != 1) {
            std.debug.print(
                "recovery MUTATED checkpoint_epoch: expected 1 (unchanged from checkpoint), got {d}\n",
                .{eng.manifest.checkpoint_epoch},
            );
        }
        try testing.expect(eng.manifest.counter > counter_after_checkpoint); // recovery advanced counter
        try testing.expectEqual(@as(u64, 1), eng.manifest.checkpoint_epoch); // recovery left epoch alone

        // (4) A fresh, non-empty checkpoint advances the epoch again: 1 -> 2.
        //     (A checkpoint with nothing dirty is a genuine no-op that does not
        //     touch the epoch, so dirty the engine with a real write first.)
        const d = try eng.allocNode();
        try eng.putNode(d, emptyNode());
        try eng.checkpoint();
        try testing.expectEqual(@as(u64, 2), eng.manifest.checkpoint_epoch);
    }
}
