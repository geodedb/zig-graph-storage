// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

test "recovery: crash after both prepares with no commit → edge not visible after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x80} ** 16;

    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        const n_src = try eng.shards[0].allocNode();
        const n_dst = try eng.shards[5].allocNode();
        try eng.putNode(n_src, test_support.emptyNode(1));
        try eng.putNode(n_dst, test_support.emptyNode(1));
        try eng.addEdgeCrashAfterPrepares(n_src, n_dst, 1);
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(@as(u64, 0), try eng.edgeCount());
}

test "recovery: crash after source commit, before target commit → edge visible after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x81} ** 16;

    var n_src_saved: u64 = 0;
    var n_dst_saved: u64 = 0;
    var edge_saved: u64 = 0;
    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        n_src_saved = try eng.shards[0].allocNode();
        n_dst_saved = try eng.shards[5].allocNode();
        try eng.putNode(n_src_saved, test_support.emptyNode(1));
        try eng.putNode(n_dst_saved, test_support.emptyNode(1));
        edge_saved = try eng.addEdgeCrashAfterSourceCommit(n_src_saved, n_dst_saved, 1);
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const got = try eng.getEdge(edge_saved);
    try testing.expect(got != null);
    try testing.expectEqual(n_dst_saved, got.?.neighbor);
}
