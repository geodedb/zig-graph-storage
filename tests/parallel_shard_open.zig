// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel shard-open recovery correctness + concurrency-gauge test.
//!
//! Builds a ShardedGraphEngine with data in EVERY shard (nodes spanning more
//! than one node-store page per shard, labels, properties, and cross-endpoint
//! edges), runs `checkpointLight()` (which advances the per-shard manifest
//! counter but leaves the derived-index snapshots STALE), then drops the engine
//! WITHOUT a full `checkpoint()`. The subsequent `open` therefore cannot
//! `tryLoadDerivedIndexes` cleanly and must run `rebuildDerivedIndexes` on every
//! shard — the exact restart-bottleneck path the parallel-open change targets.
//!
//! Correctness gate: post-reopen state (nodeCount / edgeCount / per-label
//! scanLabel set / getProperty / expandOut / expandIn / getEdge) must equal the
//! ground-truth captured at creation time. This is identical whether the open
//! loop is serial or parallel, so the same test guards both.
//!
//! Concurrency gate: `open_concurrency_gauge.maxObserved()` records the peak
//! number of shard-open workers running at once. On the SERIAL loop this is 1;
//! once `open` parallelizes it rises to min(SHARD_COUNT, cpu).

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const sharded_engine = graph_storage.sharded_engine;
const shard_count = graph_storage.shard_count;
const SHARD_COUNT = shard_count.SHARD_COUNT;

const NODES_PER_SHARD = 80; // > one node-store page per shard (forces real index work)
const LABEL_MOD = 3; // labels 1..LABEL_MOD, sprinkled across every shard

const NodeRef = struct {
    id: u64,
    prop_head: u64,
    label: u32,
};
const EdgeRef = struct {
    id: u64,
    from: u64,
    to: u64,
};

fn bigConfig() graph_storage.config.GraphConfig {
    var cfg = test_support.testConfig();
    // 1280 nodes + props + edges across 16 shards: give the per-shard pools
    // headroom (256 / 16 = 16 pages each) so the test exercises rebuild, not
    // eviction thrash.
    cfg.buffer_pool_pages = 256;
    return cfg;
}

fn nodeName(buf: []u8, global_id: usize) []const u8 {
    return std.fmt.bufPrint(buf, "n{d}", .{global_id}) catch unreachable;
}

fn expectedNameMatches(got: ?graph_storage.PropertyValue, global_id: usize) !void {
    try testing.expect(got != null);
    var buf: [32]u8 = undefined;
    const want = nodeName(&buf, global_id);
    try testing.expectEqualStrings(want, got.?.string);
}

fn freeProp(v: graph_storage.PropertyValue) void {
    switch (v) {
        .string => |s| testing.allocator.free(s),
        else => {},
    }
}

test "parallel-shard-open: rebuild-on-reopen state matches ground truth + gauge" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xA7} ** 16;

    var nodes: [SHARD_COUNT][NODES_PER_SHARD]NodeRef = undefined;
    // One cross-endpoint edge per shard: shard s -> shard (s+1)%SHARD_COUNT.
    var edges: [SHARD_COUNT]EdgeRef = undefined;

    // -------- creation phase: populate EVERY shard, capture ground truth ------
    {
        const eng = try ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            bigConfig(),
        );

        for (0..SHARD_COUNT) |s| {
            for (0..NODES_PER_SHARD) |i| {
                const global_id = s * NODES_PER_SHARD + i;
                // Allocate ON shard s so node + property chain co-locate there.
                const n = try eng.shards[s].allocNode();
                try testing.expectEqual(s, shard_count.shardOfNode(n));
                try eng.shards[s].putNode(n, test_support.emptyNode(1));

                var rec = (try eng.shards[s].getNode(n)).?;
                var name_buf: [32]u8 = undefined;
                const name = nodeName(&name_buf, global_id);
                rec.prop_head = try eng.shards[s].putProperty(rec.prop_head, "name", .{ .string = name });
                try eng.shards[s].putNode(n, rec);

                const label: u32 = @intCast((global_id % LABEL_MOD) + 1);
                try eng.addLabel(n, label);

                nodes[s][i] = .{ .id = n, .prop_head = rec.prop_head, .label = label };
            }
        }

        for (0..SHARD_COUNT) |s| {
            const from = nodes[s][0].id;
            const to = nodes[(s + 1) % SHARD_COUNT][0].id;
            const id = try eng.addEdge(from, to, 1);
            edges[s] = .{ .id = id, .from = from, .to = to };
        }

        try testing.expectEqual(@as(u64, SHARD_COUNT * NODES_PER_SHARD), try eng.nodeCount());
        try testing.expectEqual(@as(u64, SHARD_COUNT), try eng.edgeCount());

        // checkpointLight advances the manifest counter but leaves derived
        // snapshots stale; drop WITHOUT a full checkpoint so the next open MUST
        // rebuildDerivedIndexes on every shard.
        try eng.checkpointLight();
        eng.deinit();
    }

    // -------- reopen phase: forces per-shard rebuildDerivedIndexes -----------
    const eng = try ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        bigConfig(),
    );
    defer eng.close() catch {};

    // Counts.
    try testing.expectEqual(@as(u64, SHARD_COUNT * NODES_PER_SHARD), try eng.nodeCount());
    try testing.expectEqual(@as(u64, SHARD_COUNT), try eng.edgeCount());

    // Properties: every node's "name" survives the rebuild.
    for (0..SHARD_COUNT) |s| {
        for (0..NODES_PER_SHARD) |i| {
            const global_id = s * NODES_PER_SHARD + i;
            const ref = nodes[s][i];
            // Read through the owning shard: per-shard property heads are local
            // ids (not globally shard-striped), so route by construction shard.
            const got = try eng.shards[s].getProperty(ref.prop_head, "name", testing.allocator);
            defer if (got) |v| freeProp(v);
            try expectedNameMatches(got, global_id);
        }
    }

    // Labels: scanLabel must return the identical set vs ground truth.
    for (1..LABEL_MOD + 1) |label_usize| {
        const label: u32 = @intCast(label_usize);

        var want = std.AutoHashMap(u64, void).init(testing.allocator);
        defer want.deinit();
        for (0..SHARD_COUNT) |s| {
            for (0..NODES_PER_SHARD) |i| {
                if (nodes[s][i].label == label) try want.put(nodes[s][i].id, {});
            }
        }

        const got = try eng.scanLabel(label, testing.allocator);
        defer testing.allocator.free(got);

        try testing.expectEqual(want.count(), got.len);
        var seen = std.AutoHashMap(u64, void).init(testing.allocator);
        defer seen.deinit();
        for (got) |nid| {
            try testing.expect(want.contains(nid)); // no stray ids
            const gop = try seen.getOrPut(nid);
            try testing.expect(!gop.found_existing); // no duplicates
        }
        try testing.expectEqual(want.count(), seen.count()); // full coverage
    }

    // Edges: getEdge + both adjacency directions survive the rebuild.
    for (edges) |er| {
        const got = try eng.getEdge(er.id);
        try testing.expect(got != null);
        try testing.expectEqual(er.to, got.?.neighbor);
        try expectOutEdge(eng, er.from, er.id, er.to);
        try expectInEdge(eng, er.to, er.id, er.from);
    }

    // Concurrency gauge: the PARALLEL open peaks above 1 (a serial loop peaks
    // at exactly 1), bounded by min(SHARD_COUNT, cpu). The >= 2 floor is the
    // hard, scheduling-robust proof that the open loop is genuinely N-wide.
    // On a 1-vCPU machine the open degrades to serial (peak == 1); guard that
    // case so the test does not spuriously fail in constrained CI environments.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_bound: u32 = @intCast(@min(SHARD_COUNT, cpu_count));
    const peak = sharded_engine.open_concurrency_gauge.maxObserved();
    if (cpu_count >= 2) {
        try testing.expect(peak >= 2);
    } else {
        try testing.expect(peak >= 1);
    }
    try testing.expect(peak <= worker_bound);
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

// ============================================================================
// Task 3: concurrency hardening tests
// ============================================================================

// Partial-open failure: corrupt one shard's directory (FileNotFound) and
// a second shard's manifest files (NoManifest). Assert:
//   (a) all workers joined — proved by the fact that open() returned at all
//       (the join is unconditional before any result inspection);
//   (b) every successfully-opened shard was closed, with no memory leak —
//       verified by testing.allocator (GeneralPurposeAllocator) catching
//       any allocation that survives open() returning an error;
//   (c) the FIRST (lowest-index) error is surfaced — shard 5 (FileNotFound,
//       index 5) < shard 12 (NoManifest, index 12), so the return MUST be
//       error.FileNotFound; if the aggregation were buggy the test fails.
test "partial-open failure: corrupted shard → workers joined, shards closed, first error surfaced" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB1} ** 16;

    // -------- creation: populate all shards --------
    {
        const eng = try ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            bigConfig(),
        );
        for (0..SHARD_COUNT) |s| {
            const n = try eng.shards[s].allocNode();
            try eng.shards[s].putNode(n, test_support.emptyNode(1));
        }
        try eng.checkpointLight();
        eng.deinit();
    }

    // -------- corruption --------
    const io = std.Io.Threaded.global_single_threaded.io();

    // graph_root = td.path / uuid_hex
    const graph_uuid_hex = sharded_engine.uuidHex(uuid);
    const graph_root = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/{s}",
        .{ td.path, graph_uuid_hex[0..] },
    );
    defer testing.allocator.free(graph_root);

    // Shard 5: delete its entire directory → GraphDir.open returns FileNotFound.
    const shard5_uuid = graph_storage.shard_uuid.deriveShardUuid(uuid, 5);
    const shard5_hex = sharded_engine.uuidHex(shard5_uuid);
    const shard5_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/graphs/{s}",
        .{ graph_root, shard5_hex[0..] },
    );
    defer testing.allocator.free(shard5_dir);
    try std.Io.Dir.cwd().deleteTree(io, shard5_dir);

    // Shard 12: zero-out manifest.a AND create an empty manifest.b.
    // readFromFileWithKey catches any error (including InvalidData from a
    // 0-byte file) and returns null. selectManifest(null, null) = NoManifest.
    const shard12_uuid = graph_storage.shard_uuid.deriveShardUuid(uuid, 12);
    const shard12_hex = sharded_engine.uuidHex(shard12_uuid);
    for (&[_][]const u8{ "manifest.a", "manifest.b" }) |slot| {
        const mpath = try std.fmt.allocPrint(
            testing.allocator,
            "{s}/graphs/{s}/{s}",
            .{ graph_root, shard12_hex[0..], slot },
        );
        defer testing.allocator.free(mpath);
        const mf = try std.Io.Dir.cwd().createFile(
            io,
            mpath,
            .{ .truncate = true },
        );
        mf.close(io);
    }

    // -------- reopen: expect failure --------
    // Shard 5 fails with FileNotFound (dir absent).
    // Shard 12 fails with NoManifest (both manifests invalid).
    // All other 14 shards open successfully; the cleanup MUST close them.
    // The first-error aggregation loop returns err_slots[5] (lowest index with
    // an error). If it wrongly returned shard 12's error, expectError fails.
    try testing.expectError(
        error.FileNotFound,
        ShardedGraphEngine.open(testing.allocator, td.path, uuid, bigConfig()),
    );
}

// Repeat-reopen stress: close and reopen the same multi-shard graph 15 times,
// asserting identical node/edge/label state on every iteration. Shakes out
// races and non-determinism in the parallel open phase.
test "repeat-reopen: 15 opens produce identical state (race/nondeterminism shakeout)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB2} ** 16;

    // Two nodes per shard (all label 1) + one cross-endpoint edge per shard.
    var nodes: [SHARD_COUNT][2]u64 = undefined;

    {
        const eng = try ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            bigConfig(),
        );
        for (0..SHARD_COUNT) |s| {
            for (0..2) |i| {
                const n = try eng.shards[s].allocNode();
                try eng.shards[s].putNode(n, test_support.emptyNode(1));
                try eng.addLabel(n, 1);
                nodes[s][i] = n;
            }
        }
        // One cross-endpoint edge per shard for edge-index coverage.
        for (0..SHARD_COUNT) |s| {
            _ = try eng.addEdge(nodes[s][0], nodes[(s + 1) % SHARD_COUNT][0], 1);
        }
        // checkpointLight: advances manifest counter but leaves derived indexes
        // stale → every reopen MUST rebuildDerivedIndexes (the race-prone path).
        try eng.checkpointLight();
        eng.deinit();
    }

    // 15 close+reopen cycles; state must be identical on every iteration.
    for (0..15) |_| {
        const eng = try ShardedGraphEngine.open(
            testing.allocator,
            td.path,
            uuid,
            bigConfig(),
        );
        errdefer eng.deinit(); // safety net if assertions fail before close

        try testing.expectEqual(
            @as(u64, SHARD_COUNT * 2),
            try eng.nodeCount(),
        );
        try testing.expectEqual(
            @as(u64, SHARD_COUNT),
            try eng.edgeCount(),
        );

        const label_nodes = try eng.scanLabel(1, testing.allocator);
        defer testing.allocator.free(label_nodes);
        try testing.expectEqual(@as(usize, SHARD_COUNT * 2), label_nodes.len);

        try eng.close();
    }
}

// Registry tripwire: assert that `global_registry.register()` is NOT called
// during `ShardedGraphEngine.open`. The parallel-open safety argument relies
// on the global registry being read-only (lookup-only) during open; this test
// verifies that invariant holds by checking the registry entry count is
// unchanged before and after open.
//
// If a future code change accidentally calls register() during open, the
// assertion fires, surfacing the violation immediately.
test "registry tripwire: global_registry.register NOT called during parallel open" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB3} ** 16;

    {
        const eng = try ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            bigConfig(),
        );
        const n = try eng.shards[0].allocNode();
        try eng.shards[0].putNode(n, test_support.emptyNode(1));
        try eng.checkpointLight();
        eng.deinit();
    }

    // Snapshot the global index-kind registry's extension entry count before
    // open. Any call to register() during open would increase this count.
    const global_reg = graph_storage.index_catalog.globalRegistry();
    const reg_entries_before = global_reg.entries.items.len;

    const eng = try ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        bigConfig(),
    );
    defer eng.close() catch {};

    const reg_entries_after = global_reg.entries.items.len;

    // The count must be unchanged: global_registry is lookup-only during open.
    // A mutation (register() call) during open is a data-race hazard on
    // concurrent opens and breaks the read-only precondition documented in
    // ShardedGraphEngine.open.
    try testing.expectEqual(reg_entries_before, reg_entries_after);
}
