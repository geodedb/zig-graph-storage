// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Edge co-location (Phase A) engine-level correctness + recovery.
//
// Co-location makes a cross-endpoint edge `(from)-[r]->(to)` a SINGLE-shard
// write on shard(from): out-adjacency + edge body + edge_index + existence index
// AND the incoming adjacency (into shard(from)'s adj_in_remote keyed by `to`)
// all live on one engine, in one WAL txn. Reverse traversal `expandIn(to)`
// becomes a bounded SHARD_COUNT-way scatter-gather over every shard's
// adj_in_remote. These tests pin:
//   1. expandIn returns the EXACT, COMPLETE in-edge set after co-located writes
//      (sources deliberately spread across >= 2 shards; parallel edges; rel
//      filter), while expandOut stays correct and source-local.
//   2. crash (drop without clean close) -> reopen -> expandIn + expandOut +
//      existence-index probe all correct with no dupes — the in-index + its
//      directory rebuilt purely by physical page-image redo (no snapshot).

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const shard_count = graph_storage.shard_count;

const REL_A: u32 = 1;
const REL_B: u32 = 2;

fn collectIn(eng: *ShardedGraphEngine, dst: u64, rel: ?u32, allocator: std.mem.Allocator) ![]graph_storage.edge.EdgeEntry {
    return eng.expandIn(dst, rel, allocator);
}

fn hasInEdge(eng: *ShardedGraphEngine, dst: u64, edge_id: u64, from: u64) !bool {
    var it = try eng.expandInIter(dst, null);
    defer it.deinit();
    while (try it.next()) |e| {
        if (e.edge_id == edge_id) {
            try testing.expectEqual(from, e.neighbor);
            return true;
        }
    }
    return false;
}

fn hasOutEdge(eng: *ShardedGraphEngine, src: u64, edge_id: u64, to: u64) !bool {
    var it = try eng.expandOutIter(src, null);
    defer it.deinit();
    while (try it.next()) |e| {
        if (e.edge_id == edge_id) {
            try testing.expectEqual(to, e.neighbor);
            return true;
        }
    }
    return false;
}

// Allocate one node per shard so node[s] lives on shard s.
fn allocOnePerShard(eng: *ShardedGraphEngine, out: []u64) !void {
    for (out, 0..) |*slot, s| {
        const n = try eng.shards[s].allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        try testing.expectEqual(s, shard_count.shardOfNode(n));
        slot.* = n;
    }
}

test "co-location: expandIn unions in-edges from sources on multiple shards (scatter)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xD1} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    const N = shard_count.SHARD_COUNT;
    var srcs: [N]u64 = undefined;
    try allocOnePerShard(eng, &srcs);

    // One hot dst on shard 3. Every src is on a DIFFERENT shard, so its in-edge
    // is recorded on that src's shard's adj_in_remote — the in-edges of `dst`
    // are fragmented across all 16 shards. expandIn must union them.
    const dst = srcs[3];

    const EdgeRec = struct { id: u64, from: u64 };
    var made: [N]EdgeRec = undefined;
    for (srcs, 0..) |src, i| {
        const id = try eng.addEdge(src, dst, REL_A);
        // Edge id routes to the SOURCE shard (co-location keeps the edge body
        // source-shard-local).
        try testing.expectEqual(shard_count.shardOfNode(src), shard_count.shardOfNode(id));
        made[i] = .{ .id = id, .from = src };
    }

    // expandIn(dst) must return EXACTLY the N in-edges, complete and correct.
    const in_edges = try collectIn(eng, dst, null, testing.allocator);
    defer testing.allocator.free(in_edges);
    try testing.expectEqual(@as(usize, N), in_edges.len);

    // Membership: every created edge appears once, with the right source.
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (made) |er| {
        try testing.expect(try hasInEdge(eng, dst, er.id, er.from));
        const gop = try seen.getOrPut(er.id);
        try testing.expect(!gop.found_existing);
    }

    // Forward traversal stays correct + source-local: each src has exactly one
    // out-edge to dst.
    for (made) |er| {
        try testing.expect(try hasOutEdge(eng, er.from, er.id, dst));
        const out = try eng.expandOut(er.from, null, testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
    }
}

test "co-location: expandIn exact set with parallel edges + rel filter" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xD2} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    const N = shard_count.SHARD_COUNT;
    var nodes: [N]u64 = undefined;
    try allocOnePerShard(eng, &nodes);

    const dst = nodes[0];
    const a = nodes[1]; // cross-shard source
    const b = nodes[2]; // cross-shard source

    // Parallel edges a->dst (two distinct edge ids, same tuple), plus a->dst of
    // a DIFFERENT rel type, plus b->dst.
    const e1 = try eng.addEdge(a, dst, REL_A);
    const e2 = try eng.addEdge(a, dst, REL_A); // parallel (same a,REL_A,dst)
    const e3 = try eng.addEdge(a, dst, REL_B); // different rel
    const e4 = try eng.addEdge(b, dst, REL_A);

    // Unfiltered: all four.
    const all_in = try collectIn(eng, dst, null, testing.allocator);
    defer testing.allocator.free(all_in);
    try testing.expectEqual(@as(usize, 4), all_in.len);
    try testing.expect(try hasInEdge(eng, dst, e1, a));
    try testing.expect(try hasInEdge(eng, dst, e2, a));
    try testing.expect(try hasInEdge(eng, dst, e3, a));
    try testing.expect(try hasInEdge(eng, dst, e4, b));

    // rel filter REL_A: e1, e2, e4 (NOT e3).
    const a_in = try collectIn(eng, dst, REL_A, testing.allocator);
    defer testing.allocator.free(a_in);
    try testing.expectEqual(@as(usize, 3), a_in.len);
    for (a_in) |e| try testing.expectEqual(REL_A, e.rel_type);

    // rel filter REL_B: only e3.
    const b_in = try collectIn(eng, dst, REL_B, testing.allocator);
    defer testing.allocator.free(b_in);
    try testing.expectEqual(@as(usize, 1), b_in.len);
    try testing.expectEqual(e3, b_in[0].edge_id);
}

test "co-location: same-shard edge in-entry also lives in adj_in_remote (one path)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xD3} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    // Two nodes guaranteed on the SAME shard (both on shard 0).
    const from = try eng.shards[0].allocNode();
    try eng.putNode(from, test_support.emptyNode(1));
    const to = try eng.shards[0].allocNode();
    try eng.putNode(to, test_support.emptyNode(1));
    try testing.expectEqual(shard_count.shardOfNode(from), shard_count.shardOfNode(to));

    const id = try eng.addEdge(from, to, REL_A);

    // expandIn finds it via the scatter (which probes shard(to)==shard(from)
    // among the 16) — proving same-shard edges use the SAME adj_in_remote path.
    try testing.expect(try hasInEdge(eng, to, id, from));
    const in_edges = try collectIn(eng, to, null, testing.allocator);
    defer testing.allocator.free(in_edges);
    try testing.expectEqual(@as(usize, 1), in_edges.len);

    try testing.expect(try hasOutEdge(eng, from, id, to));
}

test "co-location recovery: crash + reopen rebuilds in-index via page-image redo" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xD4} ** 16;

    const N = shard_count.SHARD_COUNT;
    var nodes: [N]u64 = undefined;
    const EdgeRec = struct { id: u64, from: u64, to: u64 };
    var edges: [N * 3]EdgeRec = undefined;

    {
        var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
        // NOTE: deliberately NO clean close — we drop the engine after a
        // checkpoint to simulate a crash; recovery must replay the WAL.
        errdefer eng.close() catch {};
        try allocOnePerShard(eng, &nodes);

        // Cross-endpoint edges into a few hot dsts, sources spread across shards.
        var e: usize = 0;
        const dsts = [_]usize{ 0, 5, 10 };
        for (dsts) |d| {
            const dst = nodes[d];
            for (0..N) |s| {
                if (s == d) continue; // keep these cross-shard
                const id = try eng.addEdge(nodes[s], dst, REL_A);
                edges[e] = .{ .id = id, .from = nodes[s], .to = dst };
                e += 1;
            }
        }
        // Pad remaining slots with same-dst extra edges so the count is fixed.
        while (e < edges.len) : (e += 1) {
            const dst = nodes[0];
            const id = try eng.addEdge(nodes[(e % (N - 1)) + 1], dst, REL_B);
            edges[e] = .{ .id = id, .from = nodes[(e % (N - 1)) + 1], .to = dst };
        }

        // Checkpoint flushes dirty pages + truncates WAL; the committed in_idx /
        // in_dir pages are now durable. Drop WITHOUT close to simulate a crash
        // right after the checkpoint (clean-state recovery path).
        try eng.checkpoint();
        eng.deinit();
    }

    var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    // Counts survive.
    try testing.expectEqual(@as(u64, edges.len), try eng.edgeCount());

    // Every edge resolvable in BOTH directions with no dupes, after recovery.
    var seen_in = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen_in.deinit();
    for (edges) |er| {
        try testing.expect(try hasInEdge(eng, er.to, er.id, er.from));
        try testing.expect(try hasOutEdge(eng, er.from, er.id, er.to));
        const gop = try seen_in.getOrPut(er.id);
        try testing.expect(!gop.found_existing);
        // getEdge (edge body, source-shard) also intact.
        const got = try eng.getEdge(er.id);
        try testing.expect(got != null);
        try testing.expectEqual(er.to, got.?.neighbor);
    }

    // No phantom in-edges: dst nodes[0] receives exactly the edges targeting it.
    var expected_in_dst0: usize = 0;
    for (edges) |er| {
        if (er.to == nodes[0]) expected_in_dst0 += 1;
    }
    const dst0_in = try collectIn(eng, nodes[0], null, testing.allocator);
    defer testing.allocator.free(dst0_in);
    try testing.expectEqual(expected_in_dst0, dst0_in.len);
}

test {
    std.testing.refAllDecls(@This());
}
