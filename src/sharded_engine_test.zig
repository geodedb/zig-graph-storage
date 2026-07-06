// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const test_support = @import("testing_support.zig");
const config_mod = @import("config.zig");
const sharded_engine_mod = @import("sharded_engine.zig");
const engine_mod = @import("engine.zig");
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

test "addEdge across shards is single-shard and both adjacencies are readable" {
    // Edge co-location (Phase A): a cross-endpoint edge is a single-shard write
    // on shard(src); the incoming side is served by the FanInEdgeIterator
    // scatter over adj_in_remote. Both directions must still read back.
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

test "co-location: cross-endpoint edge write is single-shard (no cross_shard_commit)" {
    // Edge co-location (Phase A) UPDATE of the former "2PC commit durability"
    // test: a cross-endpoint edge `(src on shard 0)->(dst on shard 7)` is now a
    // SINGLE-shard write on shard(src)=0. So NEITHER shard logs a
    // cross_shard_commit (the 2PC path is unreachable from addEdge), and shard 7
    // — which previously took the dst-side in-adjacency write — does no edge
    // write at all. The edge is still correct in both directions (incoming via
    // the FanInEdgeIterator scatter).
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

    const edge_id = try eng.addEdge(n_src, n_dst, 1);

    // No shard logs a cross_shard_commit decision.
    for ([_]usize{ 0, 7 }) |s| {
        const records = try eng.shards[s].wal.readFrom(0, testing.allocator);
        defer {
            for (records) |*r| r.deinit(testing.allocator);
            testing.allocator.free(records);
        }
        for (records) |r| {
            try testing.expect(r.record_type != wal_record_mod.WalRecordType.cross_shard_commit);
            try testing.expect(r.record_type != wal_record_mod.WalRecordType.cross_shard_prepare);
        }
    }

    // The edge resolves both ways: out from src, in to dst (via scatter).
    var out_it = try eng.expandOutIter(n_src, null);
    defer out_it.deinit();
    var out_found = false;
    while (try out_it.next()) |e| {
        if (e.edge_id == edge_id) {
            try testing.expectEqual(n_dst, e.neighbor);
            out_found = true;
        }
    }
    try testing.expect(out_found);

    var in_it = try eng.expandInIter(n_dst, null);
    defer in_it.deinit();
    var in_found = false;
    while (try in_it.next()) |e| {
        if (e.edge_id == edge_id) {
            try testing.expectEqual(n_src, e.neighbor);
            in_found = true;
        }
    }
    try testing.expect(in_found);
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

test "ShardedGraphEngine.create propagates external_thread_pool to all shards" {
    const tp = @import("thread_pool");

    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();

    var caller_pool = try tp.ThreadPool.init(testing.allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 32,
        .max_threads = 4,
    });
    defer {
        caller_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        caller_pool.deinit();
    }

    var cfg = test_support.testConfig();
    cfg.external_thread_pool = &caller_pool;

    const uuid = [_]u8{0xAA} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        cfg,
    );
    defer eng.close() catch {};

    // Parent did not allocate its own pool.
    try testing.expect(eng.owned_shared_pool == null);
    try testing.expectEqual(&caller_pool, eng.shared_thread_pool);

    // Every sub-engine borrows the caller's pool — same pointer, no owned storage.
    for (0..shard_count_mod.SHARD_COUNT) |i| {
        try testing.expectEqual(&caller_pool, eng.shards[i].thread_pool);
        try testing.expect(eng.shards[i].owned_thread_pool == null);
    }
}

test "ShardedGraphEngine: 16 concurrent shard checkpoints complete on a 4-worker shared pool" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xBB} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Seed each shard with at least one dirty page so the per-shard
    // checkpoint actually has work to flush.
    for (0..shard_count_mod.SHARD_COUNT) |s| {
        const id = try eng.shards[s].allocNode();
        try eng.shards[s].putNode(id, test_support.emptyNode(1));
    }

    const Worker = struct {
        fn run(shard_eng: *engine_mod.GraphEngine, out_err: *?anyerror) void {
            shard_eng.checkpoint() catch |err| {
                out_err.* = err;
            };
        }
    };

    var thread_errs: [shard_count_mod.SHARD_COUNT]?anyerror = .{null} ** shard_count_mod.SHARD_COUNT;
    var threads: [shard_count_mod.SHARD_COUNT]std.Thread = undefined;

    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ eng.shards[i], &thread_errs[i] });
    }
    for (threads) |t| t.join();

    for (thread_errs) |maybe_err| {
        if (maybe_err) |err| {
            std.debug.print("shard checkpoint failed: {}\n", .{err});
            return error.ShardCheckpointFailed;
        }
    }
}

// ============================================================================
// PHASE G — crash-reopen exact-index reconcile: ShardedGraphEngine G1 aggregate.
// ============================================================================

test "PHASE G G1: ShardedGraphEngine tailAffectedNodeIds unions per-shard node ids and poisons on rebuild" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x51} ** 16;
    const cfg = test_support.testConfig();

    {
        // Session 1: empty graph, close (durable baseline).
        var eng = try sharded_engine_mod.ShardedGraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try eng.close();
    }

    const K = 6;
    var tail_ids: [K]u64 = undefined;
    {
        // Session 2: create K bare nodes (round-robined across distinct shards)
        // as the committed tail, then CRASH. Nothing pre-existed, so each
        // touched shard page holds only its own tail node.
        var eng = try sharded_engine_mod.ShardedGraphEngine.open(testing.allocator, td.path, uuid, cfg);
        for (&tail_ids) |*tid| {
            const id = try eng.allocNode();
            try eng.putNode(id, test_support.emptyNode(2));
            tid.* = id;
        }
        eng.deinit();
    }

    // Session 3: reopen (per-shard capture on).
    var eng = try sharded_engine_mod.ShardedGraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.deinit();

    // Aggregate G1: exactly the K tail ids, deduped + ascending across shards.
    {
        const got = try eng.tailAffectedNodeIds(testing.allocator);
        defer testing.allocator.free(got);
        std.mem.sort(u64, &tail_ids, {}, std.sort.asc(u64));
        try testing.expectEqualSlices(u64, &tail_ids, got);
    }

    // G2 per-shard access: the shard owning a tail node advanced its durable
    // frontier past its pre-recovery frontier (a tail replayed there).
    try testing.expectEqual(shard_count_mod.SHARD_COUNT, eng.shardCount());
    const owner = eng.shard(shard_count_mod.shardOfNode(tail_ids[0]));
    try testing.expect(owner.durableFrontierLsn() > owner.preRecoveryFrontierLsn());

    // Poison: if ANY shard needs a rebuild (its capture unavailable while a
    // tail was applied), the WHOLE aggregate is empty — never a partial set.
    try testing.expect(owner.tail_affected_pages != null);
    testing.allocator.free(owner.tail_affected_pages.?);
    owner.tail_affected_pages = null;
    const poisoned = try eng.tailAffectedNodeIds(testing.allocator);
    defer testing.allocator.free(poisoned);
    try testing.expectEqual(@as(usize, 0), poisoned.len);
}
