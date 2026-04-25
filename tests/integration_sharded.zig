// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const NodeRec = graph_storage.node.NodeRec;

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
