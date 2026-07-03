// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// WAL-recovery counter staleness — recovery replays committed WAL-tail page
// images but used to leave the manifest id counters (`next_node_id`,
// `next_edge_id`, `next_txn_id`) at their CHECKPOINT-era values.
// Consequences (the "KNOWN, separate id gap" noted in free_space_wal_tail.zig
// and edge_remove_crash.zig — closed here):
//
//   1. Scan INVISIBILITY: every scan bounded by `manifest.next_node_id`
//      (engine_integrity.getStorageStats, rebuildOrderedIndex, derived-index
//      rebuild scans) stops BEFORE the crash-window ids — committed, replayed
//      records never surface.
//   2. Slot RE-ISSUE: `allocNode`/`allocEdge` hand out the SAME ids again;
//      the subsequent putNode / edge-index insert silently OVERWRITES
//      committed, recovered records.
//
// The fix tracks the maximum node id / edge id observed in the committed
// page images recovery APPLIES (replay already visits every one of them —
// O(replayed bytes), no extra I/O) plus the maximum txn id seen in the WAL
// tail, and re-derives the manifest counters BEFORE recovery persists the
// advanced `last_checkpoint_lsn` to both manifest slots. Counters and LSN
// travel in the SAME atomic A/B manifest write, so no crash window can leave
// "advanced LSN + stale counters" on disk (the invariant the GAP free-space
// truncate-signal protects for the separate free.store file holds here for
// free).
//
// Tests:
//   * mechanism: reopened manifest counters cover every replayed id exactly;
//   * scan visibility: the PRODUCTION scan bound sees every committed node;
//   * acceptance: aggressive post-reopen allocNode/addEdge NEVER re-issues a
//     replayed slot — full byte-parity of all pre-crash data under write
//     pressure through the ID path (no explicit high ids);
//   * double crash: healed counters survive a second crash before the next
//     checkpoint (they were persisted by the first recovery);
//   * sharded: id healing preserves the shard stride/residue so allocNode
//     keeps routing ids to the right shard.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const GraphConfig = gs.GraphConfig;
const test_support = gs.test_support;

const REL: u32 = 5;

/// 200 crash-window nodes: at page_size 4096 a node page holds 84 records,
/// so the ids span THREE node pages, at least two of which did not exist at
/// checkpoint time.
const N_CRASH: usize = 200;
/// > entriesPerBlock(4096, v2) = 126 so the out-chain spills into a second
/// adjacency block inside the crash window.
const N_EDGES: usize = 150;
const N_SINKS: usize = 4;

const PID_BASE: u64 = 0xC0DE_0000_0000_0000;

fn pid(i: usize) u64 {
    return PID_BASE | @as(u64, @intCast(i + 1));
}

fn newPid(i: usize) u64 {
    return 0xAF7E_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

const Scenario = struct {
    baseline_a: u64,
    baseline_b: u64,
    crash_ids: [N_CRASH]u64,
    source: u64,
    sinks: [N_SINKS]u64,
    edge_ids: [N_EDGES]u64,
    edge_sinks: [N_EDGES]u64,
    max_node_id: u64,
    max_edge_id: u64,
    /// txn_manager.next_txn_id at the instant of the crash.
    txn_watermark: u64,
    /// manifest.next_node_id as of the CHECKPOINT (the stale value recovery
    /// used to keep).
    checkpoint_next_node_id: u64,
};

/// Checkpoint → allocate nodes+edges+props through the NORMAL id-allocation
/// path → crash (deinit without close). Everything after the checkpoint
/// lives only in the fsynced WAL tail.
fn buildCrashScenario(alloc: Allocator, dir_path: []const u8, uuid: [16]u8, cfg: GraphConfig) !Scenario {
    var s: Scenario = undefined;

    const eng = try GraphEngine.create(alloc, dir_path, uuid, cfg);
    errdefer eng.close() catch {};

    s.baseline_a = try eng.allocNode();
    try eng.putNode(s.baseline_a, emptyNode());
    s.baseline_b = try eng.allocNode();
    try eng.putNode(s.baseline_b, emptyNode());
    try eng.checkpoint(); // counters durable as of HERE.
    s.checkpoint_next_node_id = eng.manifest.next_node_id;

    // Crash window: normal allocNode/putNode/putProperty + colocated edges.
    for (&s.crash_ids, 0..) |*id, i| {
        id.* = try eng.allocNode();
        try eng.putNode(id.*, emptyNode());
        var rec = (try eng.getNode(id.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "k", .{ .int = @intCast(i) });
        try eng.putNode(id.*, rec);
    }
    s.source = s.crash_ids[0];
    for (&s.sinks, 0..) |*t, j| t.* = s.crash_ids[1 + j];
    s.max_edge_id = 0;
    for (0..N_EDGES) |i| {
        s.edge_sinks[i] = s.sinks[i % N_SINKS];
        s.edge_ids[i] = try eng.addEdgeColocatedWithPublicId(s.source, s.edge_sinks[i], REL, pid(i));
        s.max_edge_id = @max(s.max_edge_id, s.edge_ids[i]);
    }
    s.max_node_id = s.crash_ids[N_CRASH - 1];
    s.txn_watermark = eng.txn_manager.next_txn_id;

    // SIMULATED CRASH: no checkpoint, no close — only the WAL tail survives.
    eng.deinit();
    return s;
}

const ScanCtx = struct {
    live: usize = 0,
};

fn scanCount(ctx: *ScanCtx, id: gs.NodeId, rec: gs.node.NodeRec) void {
    _ = id;
    _ = rec;
    ctx.live += 1;
}

fn inSlice(hay: []const u64, needle: u64) bool {
    for (hay) |h| {
        if (h == needle) return true;
    }
    return false;
}

/// Byte-parity of everything committed before the crash: every crash-window
/// node visible with its exact property, exact edge set with exact
/// public_ids resolvable both by chain walk and by internal edge id.
fn assertParity(alloc: Allocator, eng: *GraphEngine, s: *const Scenario) !void {
    for (s.crash_ids, 0..) |id, i| {
        const rec = (try eng.getNode(id)) orelse {
            std.debug.print("crash-window node {d} (#{d}) invisible/overwritten after recovery\n", .{ id, i });
            return error.RecoveredNodeLost;
        };
        const v = (try eng.getProperty(rec.prop_head, "k", alloc)) orelse {
            std.debug.print("crash-window node {d} (#{d}) lost property 'k'\n", .{ id, i });
            return error.RecoveredPropMissing;
        };
        switch (v) {
            .int => |x| try testing.expectEqual(@as(i64, @intCast(i)), x),
            else => return error.RecoveredPropWrongType,
        }
    }

    // Exact out-chain of the crash-window source.
    {
        const seen = try alloc.alloc(bool, N_EDGES);
        defer alloc.free(seen);
        @memset(seen, false);
        var it = try eng.expandOutIter(s.source, null);
        defer it.deinit();
        var n: usize = 0;
        while (try it.next()) |e| {
            if ((e.public_id >> 32) != (pid(0) >> 32)) {
                std.debug.print("unknown public_id {x} in recovered chain\n", .{e.public_id});
                return error.UnknownEdgeEnumerated;
            }
            const idx: usize = @intCast((e.public_id & 0xFFFF_FFFF) - 1);
            if (idx >= N_EDGES) return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            try testing.expectEqual(s.edge_sinks[idx], e.neighbor);
            n += 1;
        }
        try testing.expectEqual(N_EDGES, n);
    }

    // Internal edge ids still resolve to the ORIGINAL edges (a re-issued
    // edge id would overwrite the edge_index entry).
    for (s.edge_ids, 0..) |eid, i| {
        const entry = (try eng.getEdge(eid)) orelse {
            std.debug.print("pre-crash edge id {d} (#{d}) lost from edge index\n", .{ eid, i });
            return error.RecoveredEdgeLost;
        };
        if (entry.public_id != pid(i)) {
            std.debug.print(
                "edge id {d} (#{d}) re-issued/overwritten: public_id {x} != expected {x}\n",
                .{ eid, i, entry.public_id, pid(i) },
            );
            return error.EdgeSlotReissued;
        }
    }
}

test "mechanism: recovery re-derives manifest id counters from the replayed WAL tail" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC1} ** 16;
    const cfg = test_support.testConfig();

    const s = try buildCrashScenario(alloc, td.path, uuid, cfg);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // The stale behavior kept the checkpoint-era value; the healed counters
    // must cover every replayed id EXACTLY (max observed + stride, stride=1
    // here — over-shoot wastes ids, under-shoot re-issues live slots).
    if (eng.manifest.next_node_id == s.checkpoint_next_node_id) {
        std.debug.print(
            "manifest.next_node_id stuck at checkpoint-era {d} (max replayed node id {d}) — replayed slots WILL be re-issued\n",
            .{ s.checkpoint_next_node_id, s.max_node_id },
        );
    }
    try testing.expectEqual(s.max_node_id + 1, eng.manifest.next_node_id);
    try testing.expectEqual(s.max_edge_id + 1, eng.manifest.next_edge_id);
    // Txn ids must never regress behind the WAL tail's highest txn.
    try testing.expect(eng.manifest.next_txn_id >= s.txn_watermark);
}

test "scan visibility: the production scan bound covers every committed replayed record" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC2} ** 16;
    const cfg = test_support.testConfig();

    const s = try buildCrashScenario(alloc, td.path, uuid, cfg);
    _ = s;

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // The REAL production bound (what getStorageStats / index rebuild scans
    // use) — NOT an explicit oracle bound.
    var ctx = ScanCtx{};
    try eng.node_store.scanNodes(eng.manifest.next_node_id, &ctx, scanCount);
    try testing.expectEqual(@as(usize, 2 + N_CRASH), ctx.live);
}

test "acceptance: aggressive post-reopen creates never re-issue a replayed slot (full parity)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC3} ** 16;
    const cfg = test_support.testConfig();

    const s = try buildCrashScenario(alloc, td.path, uuid, cfg);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Create aggressively through the NORMAL id path — more nodes than the
    // whole crash window, so any counter regression MUST collide.
    var new_ids: [2 * N_CRASH]u64 = undefined;
    for (&new_ids, 0..) |*id, i| {
        id.* = try eng.allocNode();
        if (inSlice(&s.crash_ids, id.*) or id.* == s.baseline_a or id.* == s.baseline_b) {
            std.debug.print("allocNode RE-ISSUED live id {d} after crash recovery\n", .{id.*});
            return error.NodeSlotReissued;
        }
        try eng.putNode(id.*, emptyNode());
        var rec = (try eng.getNode(id.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "n", .{ .int = @intCast(i) });
        try eng.putNode(id.*, rec);
    }

    // New edges through the normal edge-id path.
    var new_edge_ids: [64]u64 = undefined;
    for (&new_edge_ids, 0..) |*eid, i| {
        eid.* = try eng.addEdgeColocatedWithPublicId(new_ids[0], new_ids[1 + (i % 8)], REL, newPid(i));
        if (inSlice(&s.edge_ids, eid.*)) {
            std.debug.print("allocEdge RE-ISSUED live edge id {d} after crash recovery\n", .{eid.*});
            return error.EdgeSlotReissued;
        }
    }

    // Everything committed before the crash still byte-visible.
    try assertParity(alloc, eng, &s);

    // And the new writes are intact too (no cross-clobbering).
    {
        const rec = (try eng.getNode(new_ids[0])) orelse return error.NewNodeInvisible;
        const v = (try eng.getProperty(rec.prop_head, "n", alloc)) orelse return error.NewPropMissing;
        switch (v) {
            .int => |x| try testing.expectEqual(@as(i64, 0), x),
            else => return error.NewPropWrongType,
        }
    }
}

test "double crash: healed counters survive a second crash before the next checkpoint" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC4} ** 16;
    const cfg = test_support.testConfig();

    const s = try buildCrashScenario(alloc, td.path, uuid, cfg);

    // First reopen advances last_checkpoint_lsn; crash again immediately
    // (no writes, no checkpoint). The second open sees an EMPTY WAL tail —
    // the healed counters must have been persisted by the FIRST recovery.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        eng.deinit(); // SECOND CRASH.
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    try testing.expectEqual(s.max_node_id + 1, eng.manifest.next_node_id);
    try testing.expectEqual(s.max_edge_id + 1, eng.manifest.next_edge_id);

    var new_ids: [N_CRASH]u64 = undefined;
    for (&new_ids) |*id| {
        id.* = try eng.allocNode();
        if (inSlice(&s.crash_ids, id.*)) return error.NodeSlotReissued;
        try eng.putNode(id.*, emptyNode());
    }
    try assertParity(alloc, eng, &s);
}

test "sharded: counter healing preserves the shard id stride (no re-issue, ids keep routing)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC5} ** 16;
    var cfg = test_support.testConfig();
    cfg.buffer_pool_pages = 128;

    const n_nodes: usize = 96; // spread over all 16 shards
    var ids: [n_nodes]u64 = undefined;
    var from: u64 = 0;
    var sink: u64 = 0;
    var edge_ids: [64]u64 = undefined;

    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        from = try eng.allocNode();
        try eng.putNode(from, emptyNode());
        sink = try eng.allocNode();
        try eng.putNode(sink, emptyNode());
        try eng.checkpoint(); // durable counter baseline.

        for (&ids, 0..) |*id, i| {
            id.* = try eng.allocNode();
            try eng.putNode(id.*, emptyNode());
            var rec = (try eng.getNode(id.*)).?;
            rec.prop_head = try eng.putNodeProperty(id.*, rec.prop_head, "k", .{ .int = @intCast(i) });
            try eng.putNode(id.*, rec);
        }
        for (&edge_ids, 0..) |*eid, i| {
            eid.* = try eng.addEdgeColocatedWithPublicId(from, sink, REL, pid(i));
        }

        // SIMULATED CRASH.
        eng.deinit();
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Aggressive creates through the sharded id path: allocNode round-robins
    // the shards, so 2*n_nodes fresh ids cover every shard's counter.
    var new_ids: [2 * n_nodes]u64 = undefined;
    for (&new_ids) |*id| {
        id.* = try eng.allocNode();
        if (inSlice(&ids, id.*) or id.* == from or id.* == sink) {
            std.debug.print("sharded allocNode RE-ISSUED live id {d} after crash recovery\n", .{id.*});
            return error.NodeSlotReissued;
        }
        try eng.putNode(id.*, emptyNode());
    }
    var new_edge_ids: [32]u64 = undefined;
    for (&new_edge_ids, 0..) |*eid, i| {
        eid.* = try eng.addEdgeColocatedWithPublicId(new_ids[0], new_ids[1], REL, newPid(i));
        if (inSlice(&edge_ids, eid.*)) return error.EdgeSlotReissued;
    }

    // Parity: every crash-window node + prop still byte-visible (routing by
    // id residue must still hit the shard that owns the record).
    for (ids, 0..) |id, k| {
        const rec = (try eng.getNode(id)) orelse {
            std.debug.print("sharded crash-window node {d} (#{d}) invisible/overwritten\n", .{ id, k });
            return error.RecoveredNodeLost;
        };
        const v = (try eng.getNodeProperty(id, rec.prop_head, "k", alloc)) orelse
            return error.RecoveredPropMissing;
        switch (v) {
            .int => |x| try testing.expectEqual(@as(i64, @intCast(k)), x),
            else => return error.RecoveredPropWrongType,
        }
    }
    // Exact edge multiset of `from` (64 parallel edges to sink) plus its
    // internal-id view.
    {
        const seen = try alloc.alloc(bool, edge_ids.len);
        defer alloc.free(seen);
        @memset(seen, false);
        var it = try eng.expandOutIter(from, null);
        defer it.deinit();
        var n: usize = 0;
        while (try it.next()) |e| {
            if ((e.public_id >> 32) != (pid(0) >> 32)) return error.UnknownEdgeEnumerated;
            const idx: usize = @intCast((e.public_id & 0xFFFF_FFFF) - 1);
            if (idx >= edge_ids.len) return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            n += 1;
        }
        try testing.expectEqual(edge_ids.len, n);
    }
}
