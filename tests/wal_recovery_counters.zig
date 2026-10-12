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

test "0025: recovery re-derives manifest node/edge counts from the replayed WAL tail" {
    // Count heal (the stats sibling of the id-counter heal above):
    // `manifest.node_count`/`edge_count` used to stay checkpoint-stale after
    // crash recovery. Scenario: durable baseline (3 nodes, 1 edge) →
    // checkpoint → crash window (creates, edge adds, one node DELETE, one
    // edge REMOVE) → crash → reopen. The healed counts must equal what a
    // clean shutdown would have persisted. The pool is sized so nothing is
    // eviction-flushed inside the crash window: the on-disk before-images
    // recovery diffs against are exactly checkpoint-era — the case the heal
    // is exact for (see the precision note in recovery.zig).
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC7} ** 16;
    var cfg = test_support.testConfig();
    cfg.buffer_pool_pages = 512;

    const n_new: usize = 100; // ids span TWO node pages (npp = 84 @ 4096)
    const m_new: usize = 40;

    var expected_nodes: u64 = 0;
    var expected_edges: u64 = 0;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        const a = try eng.allocNode();
        try eng.putNode(a, emptyNode());
        const b = try eng.allocNode();
        try eng.putNode(b, emptyNode());
        const c = try eng.allocNode();
        try eng.putNode(c, emptyNode());
        const e0 = try eng.addEdgeColocatedWithPublicId(a, b, REL, pid(999));
        try eng.checkpoint(); // counts durable as of HERE: 3 nodes, 1 edge.
        try testing.expectEqual(@as(u64, 3), eng.manifest.node_count);
        try testing.expectEqual(@as(u64, 1), eng.manifest.edge_count);

        // Crash window: creates on an existing AND a fresh node page, edge
        // adds into an existing adjacency block, one delete of a
        // checkpoint-era node, one remove of a checkpoint-era edge.
        for (0..n_new) |_| {
            const id = try eng.allocNode();
            try eng.putNode(id, emptyNode());
        }
        for (0..m_new) |i| {
            _ = try eng.addEdgeColocatedWithPublicId(a, b, REL, pid(i));
        }
        try eng.deleteNode(c);
        try eng.removeEdge(a, b, e0);

        expected_nodes = 3 + n_new - 1;
        expected_edges = 1 + m_new - 1;
        try testing.expectEqual(expected_nodes, eng.manifest.node_count);
        try testing.expectEqual(expected_edges, eng.manifest.edge_count);

        // SIMULATED CRASH: everything after the checkpoint lives only in the
        // fsynced WAL tail.
        eng.deinit();
    }

    // First reopen: replay must heal the counts.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        const got_nodes = eng.manifest.node_count;
        const got_edges = eng.manifest.edge_count;
        eng.deinit(); // SECOND CRASH, immediately (empty tail follows).
        if (got_nodes == 3 and expected_nodes != 3) {
            std.debug.print(
                "manifest.node_count stuck at checkpoint-era 3 (expected {d}) — counts not healed by replay\n",
                .{expected_nodes},
            );
        }
        try testing.expectEqual(expected_nodes, got_nodes);
        try testing.expectEqual(expected_edges, got_edges);
    }

    // Second reopen sees an EMPTY WAL tail: the healed counts must have been
    // persisted by the FIRST recovery (they ride the same atomic A/B manifest
    // write as the advanced checkpoint LSN).
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(expected_nodes, eng.manifest.node_count);
    try testing.expectEqual(expected_edges, eng.manifest.edge_count);
    try testing.expectEqual(expected_nodes, try eng.nodeCount());
    try testing.expectEqual(expected_edges, try eng.edgeCount());
}

/// Append a checksummed WAL record to a shard engine's WAL and fsync it —
/// simulates a record a LEGACY (pre-co-location) binary wrote to this shard's
/// WAL tail before crashing.
fn appendShardRecord(
    eng: *GraphEngine,
    record_type: gs.wal_record.WalRecordType,
    txn_id: u64,
    file_id: u8,
    page_id: u64,
    payload: []const u8,
) !void {
    var rec = gs.wal_record.WalRecord{
        .lsn = 0,
        .txn_id = txn_id,
        .record_type = record_type,
        .file_id = file_id,
        .page_id = page_id,
        .payload = payload,
        .checksum = 0,
    };
    rec.checksum = rec.computeChecksum();
    _ = try eng.wal.appendRecord(&rec);
    try eng.wal.sync();
}

test "I1: foreign-residue ids in a legacy replayed image never poison a shard's healed counters" {
    // A LEGACY pre-co-location sharded graph's WAL tail can carry target-side
    // `.adj_in` images whose edge ids were allocated on the SOURCE shard — a
    // different residue class mod SHARD_COUNT. If such an id is the harvest
    // max, the heal would set next_edge_id into the FOREIGN residue class
    // forever after, and `shardOfNode(edge_id)` routing makes every edge
    // subsequently created on this shard invisible to getEdge (silent
    // misrouting). Same invariant for node ids (symmetry guard).
    //
    // Hand-craft such a tail on shard 0: one committed txn carrying
    //   * an `.adj_in` block image with TWO edge ids — one in shard 0's
    //     residue class (must be harvested) and a HIGHER foreign-residue one
    //     (must be skipped);
    //   * a `.nodes` page image with TWO non-empty slots — one in-class,
    //     one foreign-residue and higher (skipped).
    // After recovery both healed counters must sit exactly one stride above
    // the IN-CLASS maxima, stay in shard 0's residue class, and fresh
    // node/edge creates must keep routing.
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC6} ** 16;
    const cfg = test_support.testConfig();

    const stride: u64 = @intCast(gs.shard_count.SHARD_COUNT);
    const page_size: usize = cfg.page_size;

    var from0: u64 = 0;
    var sink0: u64 = 0;
    var base_next_edge: u64 = 0;
    var base_next_node: u64 = 0;

    // In-class edge id (residue 0, above the baseline counter) and a HIGHER
    // foreign-residue one (residue 3) — the poison candidate.
    const own_edge_id: u64 = stride * 600; // 9600, ≡ 0 (mod 16)
    const foreign_edge_id: u64 = stride * 4096 + 3; // 65539, ≡ 3 (mod 16)

    // Node page 100 at npp=84 holds ids 8400..8483. 8400 ≡ 0 (in-class),
    // 8407 ≡ 7 (foreign, higher).
    const node_page: u64 = 100;
    const npp: u64 = gs.node.nodesPerPage(cfg.page_size);
    const own_node_id: u64 = node_page * npp; // 8400
    const foreign_node_slot: u64 = 7;
    const foreign_node_id: u64 = own_node_id + foreign_node_slot; // 8407
    try testing.expectEqual(@as(u64, 0), own_node_id % stride);
    try testing.expectEqual(@as(u64, 7), foreign_node_id % stride);

    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        from0 = try eng.shards[0].allocNode();
        try eng.putNode(from0, emptyNode());
        sink0 = try eng.shards[0].allocNode();
        try eng.putNode(sink0, emptyNode());
        try eng.checkpoint(); // durable counter baseline; tail below is legacy-crafted.
        base_next_edge = eng.shards[0].manifest.next_edge_id;
        base_next_node = eng.shards[0].manifest.next_node_id;
        try testing.expect(own_edge_id > base_next_edge);
        try testing.expect(own_node_id > base_next_node);

        // Crafted `.adj_in` block image: v2 block, two entries.
        const adj_img = try alloc.alloc(u8, page_size);
        defer alloc.free(adj_img);
        @memset(adj_img, 0);
        const hdr_off = gs.page.PAGE_HEADER_SIZE;
        const bh = gs.edge.EdgeBlockHeader{
            .next_block = 0,
            .count = 2,
            .kind = 0,
            .entry_format = gs.edge.ENTRY_FORMAT_V2,
            .payload_size = 0,
            .checksum = 0,
        };
        @memcpy(adj_img[hdr_off..][0..@sizeOf(gs.edge.EdgeBlockHeader)], std.mem.asBytes(&bh));
        const entries_off = hdr_off + @sizeOf(gs.edge.EdgeBlockHeader);
        const e_own = gs.edge.EdgeEntry{
            .neighbor = sink0,
            .edge_id = own_edge_id,
            .rel_type = REL,
            .prop_head = 0,
            .public_id = 0,
        };
        const e_foreign = gs.edge.EdgeEntry{
            .neighbor = from0,
            .edge_id = foreign_edge_id,
            .rel_type = REL,
            .prop_head = 0,
            .public_id = 0,
        };
        // EdgeEntry is the in-memory form (prop_head widened to u64), not the
        // wire record: serialize through encodeEntry, as the engine does.
        const v2 = gs.edge.ENTRY_SIZE_V2;
        gs.edge.encodeEntry(adj_img[entries_off..][0..v2], e_own, gs.edge.ENTRY_FORMAT_V2);
        gs.edge.encodeEntry(adj_img[entries_off + v2 ..][0..v2], e_foreign, gs.edge.ENTRY_FORMAT_V2);

        // Crafted `.nodes` page image: slot 0 (id 8400, in-class) and slot 7
        // (id 8407, foreign) non-empty (any nonzero byte in the 48-byte rec).
        const node_img = try alloc.alloc(u8, page_size);
        defer alloc.free(node_img);
        @memset(node_img, 0);
        const body_off = gs.node.PAGE_HEADER_SIZE;
        node_img[body_off] = 1; // slot 0 non-empty
        node_img[body_off + @as(usize, @intCast(foreign_node_slot)) * @sizeOf(gs.node.NodeRec)] = 1; // slot 7 non-empty

        // One committed legacy txn in shard 0's WAL tail.
        const txn_id: u64 = 0x5001;
        try appendShardRecord(eng.shards[0], .begin_txn, txn_id, 0, 0, &.{});
        try appendShardRecord(eng.shards[0], .page_update, txn_id, @intFromEnum(gs.types.FileId.adj_in), 60, adj_img);
        try appendShardRecord(eng.shards[0], .page_update, txn_id, @intFromEnum(gs.types.FileId.nodes), node_page, node_img);
        try appendShardRecord(eng.shards[0], .commit_txn, txn_id, 0, 0, &.{});

        // SIMULATED CRASH.
        eng.deinit();
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Healed counters: exactly one stride above the IN-CLASS maxima, still in
    // shard 0's residue class. A foreign-residue heal poisons the class
    // permanently (every future edge on this shard misroutes).
    if (eng.shards[0].manifest.next_edge_id % stride != 0) {
        std.debug.print(
            "shard 0 next_edge_id {d} left residue class 0 (≡ {d} mod {d}) — healed from a foreign-residue legacy id\n",
            .{ eng.shards[0].manifest.next_edge_id, eng.shards[0].manifest.next_edge_id % stride, stride },
        );
    }
    try testing.expectEqual(own_edge_id + stride, eng.shards[0].manifest.next_edge_id);
    try testing.expectEqual(@as(u64, 0), eng.shards[0].manifest.next_edge_id % stride);
    try testing.expectEqual(own_node_id + stride, eng.shards[0].manifest.next_node_id);
    try testing.expectEqual(@as(u64, 0), eng.shards[0].manifest.next_node_id % stride);

    // New edges must keep routing: a foreign-residue counter would mint an id
    // whose shardOfNode routes getEdge to the WRONG shard (null here).
    const eid = try eng.addEdgeColocatedWithPublicId(from0, sink0, REL, newPid(0));
    try testing.expectEqual(@as(u64, 0), eid % stride);
    const got = (try eng.getEdge(eid)) orelse {
        std.debug.print("new edge id {d} (≡ {d} mod {d}) misrouted — getEdge cannot see it\n", .{ eid, eid % stride, stride });
        return error.NewEdgeMisrouted;
    };
    try testing.expectEqual(newPid(0), got.public_id);

    // Same for nodes.
    const nid = try eng.shards[0].allocNode();
    try testing.expectEqual(@as(u64, 0), nid % stride);
    try eng.putNode(nid, emptyNode());
    _ = (try eng.getNode(nid)) orelse return error.NewNodeMisrouted;
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

test "adjacency slab: an edge id living ONLY in a replayed slab-block image is healed (never re-issued)" {
    // GAP adjacency slab packing P1 hard requirement: the recovery counter
    // harvest must learn SLAB adjacency images (entry_format = 2 — many small
    // chains' v2-entry runs behind a backward-growing slot directory) in the
    // SAME phase that introduces the layout. Without it, `entry_format >
    // ENTRY_FORMAT_V2` silently skips the image, the healed next_edge_id
    // stays below an id committed in a slab run, and the next allocEdge
    // RE-ISSUES that id — the exact counter-staleness class this suite
    // closed for chain blocks, reintroduced for slab chains.
    //
    // Hand-craft shard 0's WAL tail with one committed slab image:
    //   * slot 0: live run carrying the in-class maximum edge id;
    //   * slot 1: live run with a HIGHER foreign-residue id (residue guard
    //     must skip it — I1);
    //   * slot 2: tombstoned;
    //   * slot 3: malformed (run overruns the directory) — skipped without
    //     aborting slot 0's harvest.
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC7} ** 16;
    const cfg = test_support.testConfig();

    const stride: u64 = @intCast(gs.shard_count.SHARD_COUNT);
    const page_size: usize = cfg.page_size;

    var from0: u64 = 0;
    var sink0: u64 = 0;

    const slab_max_edge_id: u64 = stride * 800; // ≡ 0 (mod 16), in-class
    const foreign_edge_id: u64 = stride * 5000 + 3; // higher, ≡ 3 — skipped

    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        from0 = try eng.shards[0].allocNode();
        try eng.putNode(from0, emptyNode());
        sink0 = try eng.shards[0].allocNode();
        try eng.putNode(sink0, emptyNode());
        try eng.checkpoint(); // durable counter baseline; the tail below is crafted.
        try testing.expect(slab_max_edge_id > eng.shards[0].manifest.next_edge_id);

        // Crafted SLAB `.adj_out` block image.
        const img = try alloc.alloc(u8, page_size);
        defer alloc.free(img);
        @memset(img, 0);
        const hdr_off = gs.page.PAGE_HEADER_SIZE;
        const bh = gs.edge.EdgeBlockHeader{
            .next_block = 0, // slab blocks are never chained
            .count = 4, // slot-directory size
            .kind = 0,
            .entry_format = gs.edge.ENTRY_FORMAT_SLAB,
            .payload_size = 0,
            .checksum = 0,
        };
        @memcpy(img[hdr_off..][0..@sizeOf(gs.edge.EdgeBlockHeader)], std.mem.asBytes(&bh));

        const esz = gs.edge.ENTRY_SIZE_V2;
        // Slot 0: live run, one v2 entry carrying the in-class max.
        const run0: u32 = gs.edge.SLAB_RUNS_OFFSET;
        const e_own = gs.edge.EdgeEntry{
            .neighbor = sink0,
            .edge_id = slab_max_edge_id,
            .rel_type = REL,
            .prop_head = 0,
            .public_id = 0,
        };
        gs.edge.encodeEntry(img[run0..][0..esz], e_own, gs.edge.ENTRY_FORMAT_SLAB);
        gs.edge.writeSlabSlot(img, 0, 0, .{ .offset = run0, .entry_count = 1 });
        // Slot 1: higher foreign-residue id — the residue guard must skip it.
        const run1: u32 = run0 + esz;
        const e_foreign = gs.edge.EdgeEntry{
            .neighbor = from0,
            .edge_id = foreign_edge_id,
            .rel_type = REL,
            .prop_head = 0,
            .public_id = 0,
        };
        gs.edge.encodeEntry(img[run1..][0..esz], e_foreign, gs.edge.ENTRY_FORMAT_SLAB);
        gs.edge.writeSlabSlot(img, 0, 1, .{ .offset = run1, .entry_count = 1 });
        // Slot 2: tombstone.
        gs.edge.writeSlabSlot(img, 0, 2, .{ .offset = gs.edge.SLAB_SLOT_TOMBSTONE, .entry_count = 0 });
        // Slot 3: malformed — run overruns the slot directory.
        gs.edge.writeSlabSlot(img, 0, 3, .{ .offset = run0, .entry_count = 60000 });

        // One committed txn carrying the slab image in shard 0's WAL tail.
        const txn_id: u64 = 0x51AB;
        try appendShardRecord(eng.shards[0], .begin_txn, txn_id, 0, 0, &.{});
        try appendShardRecord(eng.shards[0], .page_update, txn_id, @intFromEnum(gs.types.FileId.adj_out), 60, img);
        try appendShardRecord(eng.shards[0], .commit_txn, txn_id, 0, 0, &.{});

        // SIMULATED CRASH.
        eng.deinit();
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Healed counter: exactly one stride above the slab run's in-class max,
    // still in shard 0's residue class.
    try testing.expectEqual(slab_max_edge_id + stride, eng.shards[0].manifest.next_edge_id);
    try testing.expectEqual(@as(u64, 0), eng.shards[0].manifest.next_edge_id % stride);

    // No re-issue: the next edge minted lands ABOVE the slab id and routes.
    const eid = try eng.addEdgeColocatedWithPublicId(from0, sink0, REL, newPid(100));
    try testing.expect(eid > slab_max_edge_id);
    try testing.expectEqual(@as(u64, 0), eid % stride);
    const got = (try eng.getEdge(eid)) orelse return error.NewEdgeMisrouted;
    try testing.expectEqual(newPid(100), got.public_id);
}
