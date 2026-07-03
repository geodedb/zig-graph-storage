// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Label WAL imaging across crash replay — regression guards for the
// incomplete-WAL-imaging family on the label paths.
//
// History: addLabelTxn used to log the label block under the RAW var-store
// REF (`head` is `first_page << 16`, NOT a page id), imaging a far-away /
// nonexistent page and leaving the REAL label-block pages out of the WAL;
// the remove path had the same shape. The durability train fixed both via
// `logVarChain` (image EVERY page of the chain the mutation produced) plus
// the node-page image. These tests pin that behavior against a crash for
// good — including MULTI-PAGE label chains, where imaging only the first
// chain page would silently truncate the label set on replay:
//
//   * add + remove in the crash window -> exact label set after replay
//     (present ones present, removed ones GONE — a stale older image of the
//     chain must not resurrect a removed label);
//   * removing the LAST label -> label_head durably zero;
//   * a label set spanning a MULTI-PAGE var chain, mutated in the crash
//     window, replays byte-exactly (adds visible, removals gone, count
//     right);
//   * the derived label index rebuilt from the replayed blocks agrees.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

/// One var page holds (4096 - 32 - 12) = 4052 data bytes; the label blob is
/// 2 + 4n bytes, so n >= 1014 spills into a second chain page. 1100 gives a
/// comfortably multi-page chain while staying fast.
const N_BIG_LABELS: u32 = 1100;

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

fn expectLabelSet(alloc: Allocator, eng: *GraphEngine, node_id: u64, expected: []const u32) !void {
    const rec = (try eng.getNode(node_id)) orelse return error.NodeInvisible;
    const labels = try eng.label_store.getLabels(rec.label_head, alloc);
    defer alloc.free(labels);

    const got = try alloc.dupe(u32, labels);
    defer alloc.free(got);
    const want = try alloc.dupe(u32, expected);
    defer alloc.free(want);
    std.mem.sort(u32, got, {}, std.sort.asc(u32));
    std.mem.sort(u32, want, {}, std.sort.asc(u32));

    if (!std.mem.eql(u32, got, want)) {
        std.debug.print(
            "label set mismatch on node {d} after crash replay: got {d} labels, want {d}\n",
            .{ node_id, got.len, want.len },
        );
        return error.LabelSetMismatch;
    }
    try testing.expectEqual(@as(u16, @intCast(expected.len)), rec.label_count);
}

test "labels: crash-window add + remove replays to the exact label set" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xA1} ** 16;
    const cfg = test_support.testConfig();

    var node_a: u64 = 0;
    var node_b: u64 = 0;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        node_a = try eng.allocNode();
        try eng.putNode(node_a, emptyNode());
        node_b = try eng.allocNode();
        try eng.putNode(node_b, emptyNode());
        try eng.checkpoint(); // labels below live ONLY in the WAL tail.

        // Crash window: adds AND a remove on A; B's only label is removed
        // (label_head must replay as durably ZERO — an older image of the
        // var page must not resurrect it).
        try eng.addLabel(node_a, 10);
        try eng.addLabel(node_a, 20);
        try eng.addLabel(node_a, 30);
        try eng.removeLabel(node_a, 20);
        try eng.addLabel(node_b, 7);
        try eng.removeLabel(node_b, 7);

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    try expectLabelSet(alloc, eng, node_a, &.{ 10, 30 });
    try expectLabelSet(alloc, eng, node_b, &.{});
    {
        const rec_b = (try eng.getNode(node_b)).?;
        try testing.expectEqual(@as(u64, 0), rec_b.label_head);
    }

    // Derived index rebuilt from the replayed durable blocks agrees.
    {
        const with_10 = try eng.scanLabel(10, alloc);
        defer alloc.free(with_10);
        try testing.expectEqualSlices(u64, &.{node_a}, with_10);
        const with_20 = try eng.scanLabel(20, alloc);
        defer alloc.free(with_20);
        try testing.expectEqual(@as(usize, 0), with_20.len);
        const with_7 = try eng.scanLabel(7, alloc);
        defer alloc.free(with_7);
        try testing.expectEqual(@as(usize, 0), with_7.len);
    }
}

test "labels: multi-page label chain mutated in the crash window replays exactly" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xA2} ** 16;
    var cfg = test_support.testConfig();
    // Room for the 2-page chain rewrite churn without eviction thrash.
    cfg.buffer_pool_pages = 256;

    var node_id: u64 = 0;
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(alloc);

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        node_id = try eng.allocNode();
        try eng.putNode(node_id, emptyNode());

        // Build a label set that spans a MULTI-PAGE var chain, then make it
        // durable: the crash window below must rewrite (and image) BOTH
        // chain pages, not just the head.
        var l: u32 = 1;
        while (l <= N_BIG_LABELS) : (l += 1) {
            try eng.addLabel(node_id, l);
            try expected.append(alloc, l);
        }
        {
            const rec = (try eng.getNode(node_id)).?;
            const head_page = gs.var_store.VarStore.refFirstPage(rec.label_head);
            const next = try eng.var_store.nextChainPage(head_page);
            try testing.expect(next != 0); // really multi-page
        }
        try eng.checkpoint();

        // Crash window: adds land in the SECOND chain page's byte range;
        // removals span BOTH pages (front, middle, back).
        try eng.addLabel(node_id, 5001);
        try eng.addLabel(node_id, 5002);
        try eng.addLabel(node_id, 5003);
        try expected.appendSlice(alloc, &.{ 5001, 5002, 5003 });
        for ([_]u32{ 1, 700, N_BIG_LABELS }) |victim| {
            try eng.removeLabel(node_id, victim);
            const idx = std.mem.indexOfScalar(u32, expected.items, victim).?;
            _ = expected.swapRemove(idx);
        }

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    try expectLabelSet(alloc, eng, node_id, expected.items);

    // Spot-check through the derived index too: an added-in-window label is
    // present, a removed-in-window label is gone.
    {
        const with_new = try eng.scanLabel(5002, alloc);
        defer alloc.free(with_new);
        try testing.expectEqualSlices(u64, &.{node_id}, with_new);
        const with_removed = try eng.scanLabel(700, alloc);
        defer alloc.free(with_removed);
        try testing.expectEqual(@as(usize, 0), with_removed.len);
    }
}
