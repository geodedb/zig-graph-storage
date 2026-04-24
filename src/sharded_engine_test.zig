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
