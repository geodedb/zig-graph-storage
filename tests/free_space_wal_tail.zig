// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP-ENT-0011 — free-space map restored from checkpoint ignores WAL-tail
// allocations replayed after a crash.
//
// Mechanism under test: a checkpoint persists the free-space bitmaps as of
// the checkpoint (engine_persist.saveFreeStore). On reopen after a crash,
// recovery replays the committed WAL tail and FLUSHES those page images —
// including pages that were allocated AFTER the checkpoint — but the open
// path then loads the CHECKPOINT-era bitmap (loadFreeStore), which still
// marks every post-checkpoint page FREE. Consequences:
//
//   1. Recovered nodes become INVISIBLE: NodeStore.getNode / scanNodes gate
//      on free_space.isAllocated(page), so a node page allocated in the
//      crash window reads as "not allocated" → getNode == null, scans
//      under-count.
//   2. DOUBLE ALLOCATION: FreeSpaceManager.allocPage hands a LIVE page
//      (holding replayed adjacency blocks / slab prop blobs / var overflow)
//      to the next writer, which pinNew-zeroes and overwrites it → silent
//      data corruption of previously COMMITTED data.
//
// The tests build one crash scenario that dirties EVERY allocPage-backed
// store type in the crash window (new node pages, v2 adjacency blocks that
// spill into a second block, slab fill pages, a legacy prop chain, var-store
// overflow), simulate the repo's established crash pattern (deinit WITHOUT
// close/checkpoint — only the fsynced WAL survives), and then assert:
//
//   * mechanism: every page allocated at crash time is ALLOCATED in the
//     post-recovery free-space map;
//   * acceptance: aggressive post-reopen allocation cannot reuse any live
//     page — full parity of ALL pre-crash data (nodes byte-visible, props
//     byte-compared, edge sets exact with exact public_ids, full scan count);
//   * double crash: a second crash BEFORE the next checkpoint must not
//     resurrect the stale checkpoint-era bitmap (recovery already advanced
//     last_checkpoint_lsn, so the second open takes the "clean" path).
//
// NOTE on id allocation post-reopen: manifest.next_node_id is
// checkpoint-granular (a KNOWN, separate gap — geode mitigates with
// time-based ids), so allocNode after a crash would re-issue crash-window
// ids and overwrite those nodes through the ID path, conflating the two
// gaps. The post-reopen write pressure therefore uses explicit high node
// ids, isolating the free-space mechanism.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const GraphConfig = gs.GraphConfig;
const FreeSpaceManager = gs.free_space.FreeSpaceManager;
const test_support = gs.test_support;

const REL: u32 = 7;

/// 200 crash-window nodes: at page_size 4096 a node page holds
/// (4096-32)/48 = 84 records, so ids ~6..~206 span TWO node pages that did
/// not exist at checkpoint time.
const N_CRASH: usize = 200;
/// > entriesPerBlock(4096, v2) = 126, so the source's out-chain MUST spill
/// into a second freshly-allocated v2 adjacency block in the crash window.
const N_EDGES: usize = 150;
const N_SINKS: usize = 4;
/// N_BIG values of BIG_LEN bytes on one node: the accumulated blob outgrows
/// the slab layout (~4 KB at page_size 4096) → slab→legacy migration → a
/// legacy prop chain WITH an overflow page, all inside the crash window.
const BIG_LEN: usize = 1200;
const N_BIG: usize = 4;
/// Label added to every 4th crash-window node — label blocks live in the
/// var store, so this dirties var-store pages in the crash window.
const CRASH_LABEL: u32 = 3;

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

fn fillBig(buf: []u8, salt: u8) void {
    for (buf, 0..) |*c, j| c.* = 'A' + @as(u8, @intCast((j + salt) % 23));
}

// ── Free-space snapshot (allocated page ids per store, pre-crash) ─────────

const Snapshot = struct {
    nodes: []u64,
    adj_out: []u64,
    adj_in: []u64,
    in_idx: []u64,
    in_dir: []u64,
    props: []u64,
    vars: []u64,

    fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.nodes);
        alloc.free(self.adj_out);
        alloc.free(self.adj_in);
        alloc.free(self.in_idx);
        alloc.free(self.in_dir);
        alloc.free(self.props);
        alloc.free(self.vars);
    }
};

fn allocatedPages(alloc: Allocator, fsm: *const FreeSpaceManager) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(alloc);
    var i: u64 = 1;
    while (i < fsm.total_pages) : (i += 1) {
        if (fsm.isAllocated(i)) try out.append(alloc, i);
    }
    return out.toOwnedSlice(alloc);
}

fn takeSnapshot(alloc: Allocator, eng: *GraphEngine) !Snapshot {
    return .{
        .nodes = try allocatedPages(alloc, &eng.free_space_nodes),
        .adj_out = try allocatedPages(alloc, &eng.free_space_adj_out),
        .adj_in = try allocatedPages(alloc, &eng.free_space_adj_in),
        .in_idx = try allocatedPages(alloc, &eng.free_space_in_idx),
        .in_dir = try allocatedPages(alloc, &eng.free_space_in_dir),
        .props = try allocatedPages(alloc, &eng.free_space_props),
        .vars = try allocatedPages(alloc, &eng.free_space_var),
    };
}

fn assertStoreAllocated(fsm: *const FreeSpaceManager, pages: []const u64, name: []const u8) !void {
    for (pages) |p| {
        if (!fsm.isAllocated(p)) {
            std.debug.print(
                "free-space WAL-tail gap: store '{s}' page {d} held committed pre-crash data but is FREE after recovery\n",
                .{ name, p },
            );
            return error.RecoveredPageMarkedFree;
        }
    }
}

fn assertSnapshotAllocated(eng: *GraphEngine, snap: *const Snapshot) !void {
    try assertStoreAllocated(&eng.free_space_nodes, snap.nodes, "nodes");
    try assertStoreAllocated(&eng.free_space_adj_out, snap.adj_out, "adj_out");
    try assertStoreAllocated(&eng.free_space_adj_in, snap.adj_in, "adj_in");
    try assertStoreAllocated(&eng.free_space_in_idx, snap.in_idx, "in_idx");
    try assertStoreAllocated(&eng.free_space_in_dir, snap.in_dir, "in_dir");
    try assertStoreAllocated(&eng.free_space_props, snap.props, "props");
    try assertStoreAllocated(&eng.free_space_var, snap.vars, "var");
}

// ── Crash scenario ─────────────────────────────────────────────────────────

const Scenario = struct {
    a: u64,
    b: u64,
    ab_pid: u64,
    crash_ids: [N_CRASH]u64,
    source: u64,
    sinks: [N_SINKS]u64,
    edge_sinks: [N_EDGES]u64,
    big_node: u64,
    max_id: u64,
    snap: Snapshot,

    fn deinit(self: *Scenario, alloc: Allocator) void {
        self.snap.deinit(alloc);
    }
};

fn edgePid(i: usize) u64 {
    return 0xF00D_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

/// Full checkpoint → allocate MORE nodes/edges/props dirtying several store
/// types (new node pages, slab fill pages, a v2 adjacency block spill, a
/// legacy prop chain + var overflow) → CRASH (deinit without close).
fn buildCrashScenario(alloc: Allocator, dir_path: []const u8, uuid: [16]u8, cfg: GraphConfig) !Scenario {
    var s: Scenario = undefined;

    const eng = try GraphEngine.create(alloc, dir_path, uuid, cfg);
    errdefer eng.close() catch {};

    // Durable baseline: two nodes, one colocated edge, one slab prop.
    s.a = try eng.allocNode();
    try eng.putNode(s.a, emptyNode());
    s.b = try eng.allocNode();
    try eng.putNode(s.b, emptyNode());
    s.ab_pid = 0xBEEF_0000_0000_0001;
    _ = try eng.addEdgeColocatedWithPublicId(s.a, s.b, REL, s.ab_pid);
    {
        var rec = (try eng.getNode(s.a)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "base", .{ .int = 42 });
        try eng.putNode(s.a, rec);
    }
    try eng.checkpoint(); // free.store now persisted as of HERE.

    // Crash window: every write below lands only in the fsynced WAL tail
    // (plus whatever the small buffer pool happens to flush by eviction).
    for (&s.crash_ids, 0..) |*id, i| {
        id.* = try eng.allocNode();
        try eng.putNode(id.*, emptyNode());
        var rec = (try eng.getNode(id.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "k", .{ .int = @intCast(i) });
        try eng.putNode(id.*, rec);
        // Label blocks live in the VAR store — dirty it in the crash window.
        if (i % 4 == 0) try eng.addLabel(id.*, CRASH_LABEL);
    }
    s.source = s.crash_ids[0];
    for (&s.sinks, 0..) |*t, j| t.* = s.crash_ids[1 + j];
    for (&s.edge_sinks, 0..) |*t, i| {
        t.* = s.sinks[i % N_SINKS];
        _ = try eng.addEdgeColocatedWithPublicId(s.source, t.*, REL, edgePid(i));
    }
    // Slab→legacy migration + overflow page: pile N_BIG large values onto one
    // node until the blob outgrows the slab layout mid-crash-window.
    s.big_node = s.crash_ids[N_CRASH - 1];
    {
        const big = try alloc.alloc(u8, BIG_LEN);
        defer alloc.free(big);
        var rec = (try eng.getNode(s.big_node)).?;
        var j: usize = 0;
        while (j < N_BIG) : (j += 1) {
            fillBig(big, @intCast(j));
            var kb: [8]u8 = undefined;
            const key = try std.fmt.bufPrint(&kb, "b{d}", .{j});
            rec.prop_head = try eng.putProperty(rec.prop_head, key, .{ .string = big });
        }
        try eng.putNode(s.big_node, rec);
    }
    s.max_id = s.crash_ids[N_CRASH - 1];

    // The in-memory bitmaps at this instant are the ground truth recovery
    // must reproduce: every op above auto-committed, so every allocated page
    // carries WAL-durable committed data.
    s.snap = try takeSnapshot(alloc, eng);
    errdefer s.snap.deinit(alloc);

    // SIMULATED CRASH: no checkpoint, no close.
    eng.deinit();
    return s;
}

// ── Post-reopen write pressure + parity oracle ─────────────────────────────

/// Allocate aggressively AFTER reopen: fresh high-id nodes (new node pages),
/// slab prop writes (fresh fill pages via allocPage), colocated v2 edges
/// (fresh adjacency blocks via allocPage), and one var-overflow blob. Under
/// the stale checkpoint-era bitmap, these allocations reuse the LIVE pages
/// recovered from the WAL tail and overwrite committed data.
fn hammerAllocations(alloc: Allocator, eng: *GraphEngine) !void {
    const base: u64 = 100_000;
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const id = base + i;
        try eng.putNode(id, emptyNode());
        var rec = (try eng.getNode(id)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "q", .{ .int = @intCast(i) });
        try eng.putNode(id, rec);
        // Var-store pressure: label blocks allocate var pages.
        if (i % 2 == 0) try eng.addLabel(id, 9);
    }
    i = 0;
    while (i < 40) : (i += 1) {
        _ = try eng.addEdgeColocatedWithPublicId(
            base + i,
            base + 40 + (i % 8),
            REL,
            0xA11C_0000_0000_0000 | @as(u64, @intCast(i + 1)),
        );
    }
    {
        const big = try alloc.alloc(u8, BIG_LEN);
        defer alloc.free(big);
        var rec = (try eng.getNode(base + 47)).?;
        i = 0;
        while (i < N_BIG) : (i += 1) {
            fillBig(big, @intCast(60 + i));
            var kb: [8]u8 = undefined;
            const key = try std.fmt.bufPrint(&kb, "h{d}", .{i});
            rec.prop_head = try eng.putProperty(rec.prop_head, key, .{ .string = big });
        }
        try eng.putNode(base + 47, rec);
    }
}

const ScanCtx = struct {
    live: usize = 0,
};

fn scanCount(ctx: *ScanCtx, id: gs.NodeId, rec: gs.node.NodeRec) void {
    _ = id;
    _ = rec;
    ctx.live += 1;
}

/// The strongest parity form: enumerate everything committed before the
/// crash and byte-compare it.
fn assertParity(alloc: Allocator, eng: *GraphEngine, s: *const Scenario) !void {
    // Baseline node + prop + edge (pre-checkpoint data).
    const ra = (try eng.getNode(s.a)) orelse return error.BaselineNodeInvisible;
    {
        const v = (try eng.getProperty(ra.prop_head, "base", alloc)) orelse
            return error.BaselinePropMissing;
        switch (v) {
            .int => |x| try testing.expectEqual(@as(i64, 42), x),
            else => return error.BaselinePropWrongType,
        }
    }
    {
        var it = try eng.expandOutIter(s.a, null);
        defer it.deinit();
        const e = (try it.next()) orelse return error.BaselineEdgeMissing;
        try testing.expectEqual(s.b, e.neighbor);
        try testing.expectEqual(s.ab_pid, e.public_id);
        try testing.expect((try it.next()) == null);
    }

    // Every crash-window node visible with its exact committed property.
    for (s.crash_ids, 0..) |id, i| {
        const rec = (try eng.getNode(id)) orelse {
            std.debug.print("crash-window node {d} (#{d}) invisible after recovery\n", .{ id, i });
            return error.RecoveredNodeInvisible;
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

    // Labels byte-visible (label blocks live on var-store pages).
    for (s.crash_ids, 0..) |id, i| {
        if (i % 4 != 0) continue;
        const rec = (try eng.getNode(id)) orelse return error.RecoveredNodeInvisible;
        const labels = try eng.label_store.getLabels(rec.label_head, alloc);
        defer alloc.free(labels);
        if (labels.len != 1 or labels[0] != CRASH_LABEL) {
            std.debug.print("crash-window node {d} (#{d}) lost label block: {any}\n", .{ id, i, labels });
            return error.RecoveredLabelMissing;
        }
    }

    // Big blobs byte-compared (slab→legacy migrated chain + overflow page).
    {
        const expected = try alloc.alloc(u8, BIG_LEN);
        defer alloc.free(expected);
        const rec = (try eng.getNode(s.big_node)) orelse return error.RecoveredNodeInvisible;
        var j: usize = 0;
        while (j < N_BIG) : (j += 1) {
            fillBig(expected, @intCast(j));
            var kb: [8]u8 = undefined;
            const key = try std.fmt.bufPrint(&kb, "b{d}", .{j});
            const v = (try eng.getProperty(rec.prop_head, key, alloc)) orelse
                return error.RecoveredBigPropMissing;
            switch (v) {
                .string => |str| {
                    defer alloc.free(str);
                    try testing.expectEqualSlices(u8, expected, str);
                },
                else => return error.RecoveredBigPropWrongType,
            }
        }
    }

    // Exact edge set of the crash-window source, exact public_ids, across
    // the recovered multi-block v2 chain.
    {
        const seen = try alloc.alloc(bool, N_EDGES);
        defer alloc.free(seen);
        @memset(seen, false);
        const src_rec = (try eng.getNode(s.source)) orelse return error.RecoveredNodeInvisible;
        _ = src_rec;
        var it = try eng.expandOutIter(s.source, null);
        defer it.deinit();
        var n: usize = 0;
        while (try it.next()) |e| {
            if ((e.public_id >> 32) != (edgePid(0) >> 32)) {
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
        for (seen) |sn| try testing.expect(sn);
    }

    // Full scan sees every committed node. Bound the scan explicitly
    // (manifest.next_node_id is checkpoint-granular — the separate id gap).
    {
        var ctx = ScanCtx{};
        try eng.node_store.scanNodes(s.max_id + 1, &ctx, scanCount);
        try testing.expectEqual(@as(usize, 2 + N_CRASH), ctx.live);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "crash restart mechanism: free-space map marks WAL-tail-recovered pages ALLOCATED" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xF5} ** 16;
    const cfg = test_support.testConfig(); // sync_each_commit => WAL tail survives

    var s = try buildCrashScenario(alloc, td.path, uuid, cfg);
    defer s.deinit(alloc);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Every page holding committed pre-crash data must be ALLOCATED in the
    // restored free-space map — otherwise allocPage can hand it out again.
    try assertSnapshotAllocated(eng, &s.snap);
}

test "crash restart acceptance: aggressive post-reopen allocation reuses no live page (full parity)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xF6} ** 16;
    const cfg = test_support.testConfig();

    var s = try buildCrashScenario(alloc, td.path, uuid, cfg);
    defer s.deinit(alloc);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    // Allocate aggressively first: if any recovered live page is still
    // marked free, these writes overwrite committed data...
    try hammerAllocations(alloc, eng);

    // ...which this full-parity oracle then catches.
    try assertParity(alloc, eng, &s);

    // And the new data must be intact too (no cross-clobbering).
    {
        const rec = (try eng.getNode(100_000)) orelse return error.NewNodeInvisible;
        const v = (try eng.getProperty(rec.prop_head, "q", alloc)) orelse return error.NewPropMissing;
        switch (v) {
            .int => |x| try testing.expectEqual(@as(i64, 0), x),
            else => return error.NewPropWrongType,
        }
    }
}

test "double crash: second crash before next checkpoint must not resurrect the stale bitmap" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xF7} ** 16;
    const cfg = test_support.testConfig();

    var s = try buildCrashScenario(alloc, td.path, uuid, cfg);
    defer s.deinit(alloc);

    // First reopen: recovery replays the WAL tail and advances
    // last_checkpoint_lsn — then crash AGAIN with no new writes and no
    // checkpoint. The second open sees an EMPTY WAL tail (the "clean" path),
    // so the on-disk free.store must have been made trustworthy by the
    // first reopen.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        eng.deinit(); // SECOND CRASH: no close, no checkpoint.
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    try assertSnapshotAllocated(eng, &s.snap);
    try hammerAllocations(alloc, eng);
    try assertParity(alloc, eng, &s);
}

// ── Sharded engine: same crash pattern through the production entry point ──

test "sharded crash restart: WAL-tail data survives post-reopen write pressure" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xF8} ** 16;
    var cfg = test_support.testConfig();
    cfg.buffer_pool_pages = 128;

    const n_nodes: usize = 100;
    const n_edges: usize = 150;

    var from: u64 = 0;
    var sink_a: u64 = 0;
    var sink_b: u64 = 0;
    var ids: [n_nodes]u64 = undefined;

    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        from = try eng.allocNode();
        try eng.putNode(from, emptyNode());
        sink_a = try eng.allocNode();
        try eng.putNode(sink_a, emptyNode());
        sink_b = try eng.allocNode();
        try eng.putNode(sink_b, emptyNode());
        try eng.checkpoint(); // durable baseline; free.store as of HERE.

        // Crash window: fresh node pages + slab props + 2-block v2 chain.
        for (&ids, 0..) |*id, i| {
            id.* = try eng.allocNode();
            try eng.putNode(id.*, emptyNode());
            var rec = (try eng.getNode(id.*)).?;
            rec.prop_head = try eng.putNodeProperty(id.*, rec.prop_head, "k", .{ .int = @intCast(i) });
            try eng.putNode(id.*, rec);
        }
        var i: usize = 0;
        while (i < n_edges) : (i += 1) {
            const to = if (i % 2 == 0) sink_a else sink_b;
            _ = try eng.addEdgeColocatedWithPublicId(from, to, REL, edgePid(i));
        }

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    {
        var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Post-reopen write pressure with explicit high ids (allocNode id
        // regression after crash is a separate, known gap).
        const base: u64 = 1_000_000;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const id = base + i;
            try eng.putNode(id, emptyNode());
            var rec = (try eng.getNode(id)).?;
            rec.prop_head = try eng.putNodeProperty(id, rec.prop_head, "q", .{ .int = @intCast(i) });
            try eng.putNode(id, rec);
        }
        i = 0;
        while (i < 48) : (i += 1) {
            _ = try eng.addEdgeColocatedWithPublicId(
                base + i,
                base + 48 + (i % 16),
                REL,
                0xA11C_0000_0000_0000 | @as(u64, @intCast(i + 1)),
            );
        }

        // Parity: every crash-window node + prop, exact edge set of `from`.
        for (ids, 0..) |id, k| {
            const rec = (try eng.getNode(id)) orelse {
                std.debug.print("sharded: crash-window node {d} (#{d}) invisible\n", .{ id, k });
                return error.RecoveredNodeInvisible;
            };
            const v = (try eng.getNodeProperty(id, rec.prop_head, "k", alloc)) orelse
                return error.RecoveredPropMissing;
            switch (v) {
                .int => |x| try testing.expectEqual(@as(i64, @intCast(k)), x),
                else => return error.RecoveredPropWrongType,
            }
        }
        const seen = try alloc.alloc(bool, n_edges);
        defer alloc.free(seen);
        @memset(seen, false);
        var it = try eng.expandOutIter(from, null);
        defer it.deinit();
        var n: usize = 0;
        while (try it.next()) |e| {
            if ((e.public_id >> 32) != (edgePid(0) >> 32)) return error.UnknownEdgeEnumerated;
            const idx: usize = @intCast((e.public_id & 0xFFFF_FFFF) - 1);
            if (idx >= n_edges) return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            const want = if (idx % 2 == 0) sink_a else sink_b;
            try testing.expectEqual(want, e.neighbor);
            n += 1;
        }
        try testing.expectEqual(n_edges, n);
        for (seen) |sn| try testing.expect(sn);
    }
}
