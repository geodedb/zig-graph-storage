// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const NodeRec = graph_storage.node.NodeRec;
const shard_count = graph_storage.shard_count;
const wal_record = graph_storage.wal_record;

test "full CRUD + cross-shard edges + reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC1} ** 16;

    {
        var eng = try ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );

        var ids: [100]u64 = undefined;
        for (&ids) |*slot| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try eng.addLabel(n, 1);
            slot.* = n;
        }

        for (0..50) |i| {
            _ = try eng.addEdge(ids[i], ids[i + 50], 1);
        }

        try testing.expectEqual(@as(u64, 100), try eng.nodeCount());
        try testing.expectEqual(@as(u64, 50), try eng.edgeCount());

        try eng.checkpoint();
        try eng.close();
    }

    var eng = try ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(@as(u64, 100), try eng.nodeCount());
    try testing.expectEqual(@as(u64, 50), try eng.edgeCount());

    const label_nodes = try eng.scanLabel(1, testing.allocator);
    defer testing.allocator.free(label_nodes);
    try testing.expectEqual(@as(usize, 100), label_nodes.len);
}

test "co-location: many cross-endpoint edges stay correct (single-shard write) and recover" {
    // Edge co-location (Phase A) UPDATE: cross-endpoint edge writes are no longer
    // 2PC — every edge is a SINGLE-shard write on shard(from), so there are NO
    // cross_shard_commit records (the old `shardHasCommit` assertion is removed;
    // crossShardAddEdge is present-but-unreachable). We assert the parallelism /
    // single-shard path does NOT change observable outcomes:
    //   * each edge id is unique and routed to its source shard
    //   * both the source out-adjacency and target in-adjacency are present
    //     (the latter via the FanInEdgeIterator scatter over adj_in_remote)
    //   * after close + reopen, every edge is still present and counts are
    //     unchanged — the in-index restored by physical page-image redo.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC3} ** 16;

    const N = shard_count.SHARD_COUNT;
    // One node per shard, so node i lives on shard i.
    var nodes: [N]u64 = undefined;

    const EdgeRec = struct { id: u64, from: u64, to: u64, s_from: usize, s_to: usize };
    // For each ordered pair of distinct shards (s_from, s_to) we create one
    // cross-shard edge: N*(N-1) cross-shard edges total.
    var edges: [N * (N - 1)]EdgeRec = undefined;

    {
        var eng = try ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );

        for (0..N) |s| {
            const n = try eng.shards[s].allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            nodes[s] = n;
            // Sanity: the node really is on shard s.
            try testing.expectEqual(s, shard_count.shardOfNode(n));
        }

        var e: usize = 0;
        for (0..N) |s_from| {
            for (0..N) |s_to| {
                if (s_from == s_to) continue;
                const id = try eng.addEdge(nodes[s_from], nodes[s_to], 1);
                try testing.expect(id != 0);
                // The edge id must route to the SOURCE shard.
                try testing.expectEqual(s_from, shard_count.shardOfNode(id));
                edges[e] = .{
                    .id = id,
                    .from = nodes[s_from],
                    .to = nodes[s_to],
                    .s_from = s_from,
                    .s_to = s_to,
                };
                e += 1;
            }
        }
        try testing.expectEqual(edges.len, e);

        // Edge ids must be unique across the whole run (no parallel double-alloc).
        var seen = std.AutoHashMap(u64, void).init(testing.allocator);
        defer seen.deinit();
        for (edges) |er| {
            const gop = try seen.getOrPut(er.id);
            try testing.expect(!gop.found_existing);
        }

        try testing.expectEqual(@as(u64, N), try eng.nodeCount());
        try testing.expectEqual(@as(u64, edges.len), try eng.edgeCount());

        // Every edge must be readable via BOTH adjacency directions (the
        // incoming side now via the scatter-gather over adj_in_remote).
        for (edges) |er| {
            try expectOutEdge(eng, er.from, er.id, er.to);
            try expectInEdge(eng, er.to, er.id, er.from);
        }

        // Co-location: edge writes are single-shard, so NO shard logs a
        // cross_shard_commit decision record (the 2PC path is unreachable).
        for (0..N) |s| {
            try testing.expect(!try shardHasCommit(eng, s));
        }

        try eng.checkpoint();
        try eng.close();
    }

    // Reopen: this runs per-shard recovery + cross-shard reconciliation. The
    // already-committed edges must survive unchanged.
    var eng = try ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(@as(u64, N), try eng.nodeCount());
    try testing.expectEqual(@as(u64, edges.len), try eng.edgeCount());

    for (edges) |er| {
        const got = try eng.getEdge(er.id);
        try testing.expect(got != null);
        try testing.expectEqual(er.to, got.?.neighbor);
        try expectOutEdge(eng, er.from, er.id, er.to);
        try expectInEdge(eng, er.to, er.id, er.from);
    }
}

fn expectOutEdge(eng: *ShardedGraphEngine, from: u64, edge_id: u64, to: u64) !void {
    var it = try eng.expandOutIter(from, null);
    defer it.deinit();
    while (try it.next()) |entry| {
        if (entry.edge_id == edge_id) {
            try testing.expectEqual(to, entry.neighbor);
            return;
        }
    }
    return error.OutEdgeMissing;
}

fn expectInEdge(eng: *ShardedGraphEngine, to: u64, edge_id: u64, from: u64) !void {
    var it = try eng.expandInIter(to, null);
    defer it.deinit();
    while (try it.next()) |entry| {
        if (entry.edge_id == edge_id) {
            try testing.expectEqual(from, entry.neighbor);
            return;
        }
    }
    return error.InEdgeMissing;
}

fn shardHasCommit(eng: *ShardedGraphEngine, shard: usize) !bool {
    const records = try eng.shards[shard].wal.readFrom(0, testing.allocator);
    defer {
        for (records) |*r| r.deinit(testing.allocator);
        testing.allocator.free(records);
    }
    for (records) |r| {
        if (r.record_type == wal_record.WalRecordType.cross_shard_commit) return true;
    }
    return false;
}

test "concurrent writers across shards make forward progress (smoke)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC2} ** 16;
    var eng = try ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const Worker = struct {
        engine: *ShardedGraphEngine,
        shard_idx: usize,
        n: usize,

        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) {
                const id = ctx.engine.shards[ctx.shard_idx].allocNode() catch return;
                ctx.engine.shards[ctx.shard_idx].putNode(id, test_support.emptyNode(1)) catch return;
            }
        }
    };

    var workers: [4]Worker = undefined;
    for (&workers, 0..) |*w, i| w.* = .{ .engine = eng, .shard_idx = i, .n = 100 };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u64, 400), try eng.nodeCount());
}
