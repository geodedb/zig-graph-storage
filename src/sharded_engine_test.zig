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
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
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
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
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
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
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

test "addEdge across shards commits via 2PC and both adjacencies are readable" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x70} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n_src = try eng.shards[0].allocNode();
    const n_dst = try eng.shards[5].allocNode();
    try eng.putNode(n_src, test_support.emptyNode(1));
    try eng.putNode(n_dst, test_support.emptyNode(1));

    const e = try eng.addEdge(n_src, n_dst, 9);
    try testing.expect(e != 0);

    var out_iter = try eng.expandOutIter(n_src, null);
    defer out_iter.deinit();
    var saw_out = false;
    while (try out_iter.next()) |entry| {
        if (entry.edge_id == e) {
            saw_out = true;
            try testing.expectEqual(n_dst, entry.neighbor);
        }
    }
    try testing.expect(saw_out);

    var in_iter = try eng.expandInIter(n_dst, null);
    defer in_iter.deinit();
    var saw_in = false;
    while (try in_iter.next()) |entry| {
        if (entry.edge_id == e) {
            saw_in = true;
            try testing.expectEqual(n_src, entry.neighbor);
        }
    }
    try testing.expect(saw_in);
}

test "ShardedGraphEngine.addLabel + scanLabel round-trips" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x50} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n1 = try eng.allocNode();
    const n2 = try eng.allocNode();
    try eng.putNode(n1, test_support.emptyNode(1));
    try eng.putNode(n2, test_support.emptyNode(1));
    try eng.addLabel(n1, 7);
    try eng.addLabel(n2, 7);

    const nodes = try eng.scanLabel(7, testing.allocator);
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 2), nodes.len);
}

test "ShardedGraphEngine.putProperty + getProperty round-trips on one shard" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x51} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n = try eng.allocNode();
    try eng.putNode(n, test_support.emptyNode(1));

    var rec = (try eng.getNode(n)).?;
    const new_head = try eng.putProperty(rec.prop_head, "name", .{ .string = "alice" });
    rec.prop_head = new_head;
    try eng.putNode(n, rec);

    const got = try eng.getProperty(new_head, "name", testing.allocator);
    try testing.expect(got != null);
    defer if (got) |v| switch (v) {
        .string => |s| testing.allocator.free(s),
        else => {},
    };
    try testing.expectEqualStrings("alice", got.?.string);
}

test "ShardedGraphEngine.beginTxn encodes shard + commit routes back" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x52} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const txn = try eng.beginTxn();
    try eng.commitTxn(txn);

    const txn2 = try eng.beginTxn();
    try eng.abortTxn(txn2);
}

test "ShardedGraphEngine.storage() exposes GraphStorage vtable" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x60} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const gs = eng.storage();
    const n = try gs.allocNode();
    try gs.putNode(n, test_support.emptyNode(1));
    try gs.addLabel(n, 42);
    const nodes = try gs.scanLabel(42, testing.allocator);
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqual(n, nodes[0]);
}

test "FanOutNodeIterator touches every shard that has matching nodes" {
    const NodeIdT = @import("types.zig").NodeId;
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x62} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    // One labelled node per shard, deterministically routed.
    var shard_nodes: [shard_count_mod.SHARD_COUNT]NodeIdT = undefined;
    for (0..shard_count_mod.SHARD_COUNT) |s| {
        const n = try eng.shards[s].allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        try eng.addLabel(n, 7);
        shard_nodes[s] = n;
    }

    var it = try eng.scanLabelIter(7);
    defer it.deinit();

    var seen = std.AutoHashMap(NodeIdT, void).init(testing.allocator);
    defer seen.deinit();
    while (try it.next()) |nid| try seen.put(nid, {});

    try testing.expectEqual(@as(usize, shard_count_mod.SHARD_COUNT), seen.count());
    for (shard_nodes) |n| try testing.expect(seen.contains(n));
}

test "cross-shard commit blocks until both shards' WAL commit records are durable" {
    const wal_record_mod = @import("wal_record.zig");
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x90} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n_src = try eng.shards[0].allocNode();
    const n_dst = try eng.shards[7].allocNode();
    try eng.putNode(n_src, test_support.emptyNode(1));
    try eng.putNode(n_dst, test_support.emptyNode(1));

    _ = try eng.addEdge(n_src, n_dst, 1);

    for ([_]usize{ 0, 7 }) |s| {
        const records = try eng.shards[s].wal.readFrom(0, testing.allocator);
        defer {
            for (records) |*r| r.deinit(testing.allocator);
            testing.allocator.free(records);
        }
        var found = false;
        for (records) |r| {
            if (r.record_type == wal_record_mod.WalRecordType.cross_shard_commit) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "ShardedGraphEngine creates one shared pool across all shards" {
    const tp = @import("thread_pool");

    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0x99} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Parent owns its pool (no external pool was injected).
    try testing.expect(eng.owned_shared_pool != null);

    // Every sub-engine borrows the parent's pool — same pointer.
    const shared: *tp.ThreadPool = eng.shared_thread_pool;
    try testing.expectEqual(&eng.owned_shared_pool.?, shared);
    for (0..shard_count_mod.SHARD_COUNT) |i| {
        try testing.expectEqual(shared, eng.shards[i].thread_pool);
        try testing.expect(eng.shards[i].owned_thread_pool == null);
    }
}
