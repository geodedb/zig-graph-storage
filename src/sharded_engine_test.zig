// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const test_support = @import("testing_support.zig");
const config_mod = @import("config.zig");
const sharded_engine_mod = @import("sharded_engine.zig");
const shard_count_mod = @import("shard_count.zig");
const shard_manifest_mod = @import("shard_manifest.zig");

test "ShardedGraphEngine.create writes shard_manifest.json and N shard dirs" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x11} ** 16;

    var eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const graph_root = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/{s}",
        .{ td.path, sharded_engine_mod.uuidHex(uuid)[0..] },
    );
    defer testing.allocator.free(graph_root);

    const loaded = try shard_manifest_mod.readFromDir(testing.allocator, graph_root);
    try testing.expectEqual(@as(u32, @intCast(shard_count_mod.SHARD_COUNT)), loaded.shard_count);

    for (0..shard_count_mod.SHARD_COUNT) |i| {
        for ((i + 1)..shard_count_mod.SHARD_COUNT) |j| {
            try testing.expect(!std.mem.eql(u8, &loaded.per_shard_uuids[i], &loaded.per_shard_uuids[j]));
        }
    }
}

test "ShardedGraphEngine.open re-reads an existing manifest and rebinds shards" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x22} ** 16;

    {
        var eng = try sharded_engine_mod.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        try eng.close();
    }

    var eng = try sharded_engine_mod.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(shard_count_mod.SHARD_COUNT, eng.shards.len);
}

test "ShardedGraphEngine.getNode routes by node id" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x33} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n = try eng.allocNode();
    try eng.putNode(n, test_support.emptyNode(1));

    const got = try eng.getNode(n);
    try testing.expect(got != null);

    // The node must live in the shard that shardOfNode(n) selects.
    const expected_shard = shard_count_mod.shardOfNode(n);
    const direct_got = try eng.shards[expected_shard].getNode(n);
    try testing.expect(direct_got != null);
}

test "ShardedGraphEngine.nodeCount sums per-shard counts" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x34} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    var created: u64 = 0;
    while (created < 100) : (created += 1) {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
    }

    try testing.expectEqual(@as(u64, 100), try eng.nodeCount());
}

test "ShardedGraphEngine.addEdge succeeds when source and target are co-located" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x40} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n1 = try eng.shards[0].allocNode();
    const n2 = try eng.shards[0].allocNode();
    try eng.putNode(n1, test_support.emptyNode(1));
    try eng.putNode(n2, test_support.emptyNode(1));

    const e = try eng.addEdge(n1, n2, 1);
    try testing.expect(e != 0);

    const got = try eng.getEdge(e);
    try testing.expect(got != null);
    try testing.expectEqual(n2, got.?.neighbor);
}

test "ShardedGraphEngine.addEdge returns CrossShardEdgeUnsupported across shards" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x41} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n_src = try eng.shards[0].allocNode();
    const n_dst = try eng.shards[3].allocNode();
    try eng.putNode(n_src, test_support.emptyNode(1));
    try eng.putNode(n_dst, test_support.emptyNode(1));

    try testing.expectError(error.CrossShardEdgeUnsupported, eng.addEdge(n_src, n_dst, 1));
}
