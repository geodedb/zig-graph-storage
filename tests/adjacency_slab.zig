// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP adjacency slab packing (kill block-per-chain bloat).
//
// P0 (BASELINE scenario — must stay green through ALL phases):
//
//   Today every adjacency chain (out_head / in_head / in_head_dir-keyed)
//   starts with allocPage() = one whole ≥8 KB block, even when the chain
//   holds 1-2 entries (24-64 B live data). Low-fanout graphs (taxonomies:
//   one parent, few children) therefore pay ~99.6 % waste per block —
//   measured 16,488 B/edge at 50 k chained edges (gs v0.2.24 P6 smoke),
//   ~130-150 G of adjacency at 14.27 M nodes / 13.8 M edges.
//
//   1. Parity ORACLE: full edge enumeration returns the EXACT
//      (from, to, rel_type, public_id) set in BOTH directions — forward via
//      expandOutIter (single-shard chain walk) and reverse via
//      FanInEdgeIterator (the SHARD_COUNT-way adj_in_remote scatter). This
//      is the reference every later phase (slab read path, slab writer,
//      graduation) must keep green.
//
//   2. Baseline cost LOCK-IN: (adj_out + adj_in_remote) growth per edge
//      > 4096 B — documents the current block-per-chain bloat that slab
//      packing removes. Legacy chains must KEEP working (read-both is
//      permanent), so this scenario is never deleted, only complemented by
//      the slab scenarios (P1+).
//
// Low-fanout shape: a node spine chained i -> i+1 plus a sprinkle of
// i -> i+2 skip edges, so every out-chain and every in-chain holds 1-2
// entries — the exact shape that maximises block-per-chain waste.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const ShardedGraphEngine = gs.ShardedGraphEngine;
const test_support = gs.test_support;
const shard_count = gs.shard_count;
const shard_uuid = gs.shard_uuid;
const sharded_engine = gs.sharded_engine;

/// Production-shaped page size (default GraphConfig.page_size). The baseline
/// assertion (bytes/edge > 4096) is only meaningful at the real page size.
const PAGE_SIZE: u32 = 8192;

const REL: u32 = 11;

/// 4500 spine edges (i -> i+1) + 500 skip edges (i -> i+2) = 5000 edges over
/// 4502 nodes; every (node, direction) chain holds 1-2 entries.
const N_SPINE = 4500;
const N_SKIP = 500;
const N_EDGES = N_SPINE + N_SKIP;
const N_NODES = N_SPINE + 2;

fn baselineConfig() gs.GraphConfig {
    return .{
        .page_size = PAGE_SIZE,
        .buffer_pool_pages = 256,
        .data_dir = "data",
    };
}

/// Nonzero, unique public ids — high tag keeps them disjoint from edge_ids.
fn publicId(i: usize) u64 {
    return 0xADAD_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

const MadeEdge = struct {
    edge_id: u64,
    from: u64,
    to: u64,
    public_id: u64,
    seen: bool = false,
};

/// Sum the on-disk size of one store file (e.g. "adj_out.store",
/// "adj_in_remote.store") across every shard under `data_dir`.
/// ShardedGraphEngine.create lays shards out as
/// `data_dir/<parent-uuid-hex>/graphs/<derived-shard-uuid-hex>/<file_name>`.
fn totalShardStoreBytes(allocator: Allocator, data_dir: []const u8, base_uuid: [16]u8, file_name: []const u8) !u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const parent_hex = sharded_engine.uuidHex(base_uuid);
    var total: u64 = 0;
    for (0..shard_count.SHARD_COUNT) |s| {
        const suuid = shard_uuid.deriveShardUuid(base_uuid, s);
        const hex = sharded_engine.uuidHex(suuid);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}/graphs/{s}/{s}", .{ data_dir, parent_hex, hex, file_name });
        defer allocator.free(path);
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue, // store not created yet => 0 bytes
            else => return err,
        };
        total += st.size;
    }
    return total;
}

test "GAP adjacency-slab P0 baseline: low-fanout chains pay a whole block per chain (bytes/edge lock-in) + enumeration parity both directions" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xA8} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, baselineConfig());
    defer eng.close() catch {};

    // Node spine.
    const nodes = try testing.allocator.alloc(u64, N_NODES);
    defer testing.allocator.free(nodes);
    for (nodes) |*slot| {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        slot.* = n;
    }

    // Baseline adjacency sizes BEFORE any edge exists (growth isolates the
    // edge cost from fixed per-shard store overhead).
    try eng.checkpoint();
    const out_before = try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_out.store");
    const in_before = try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_in_remote.store");

    // Low-fanout edges through the co-located inline-public-id write path —
    // the same surface geode's adapter uses since GAP-ENT-0024.
    const made = try testing.allocator.alloc(MadeEdge, N_EDGES);
    defer testing.allocator.free(made);

    for (0..N_SPINE) |i| {
        const pid = publicId(i);
        const id = try eng.addEdgeColocatedWithPublicId(nodes[i], nodes[i + 1], REL, pid);
        made[i] = .{ .edge_id = id, .from = nodes[i], .to = nodes[i + 1], .public_id = pid };
    }
    for (0..N_SKIP) |i| {
        const pid = publicId(N_SPINE + i);
        const id = try eng.addEdgeColocatedWithPublicId(nodes[i], nodes[i + 2], REL, pid);
        made[N_SPINE + i] = .{ .edge_id = id, .from = nodes[i], .to = nodes[i + 2], .public_id = pid };
    }

    // Flush everything so on-disk store sizes reflect all allocations.
    try eng.checkpoint();

    // ------------------------------------------------------------------
    // (b) Baseline cost lock-in: ~one ≥8 KB block per (chain, direction).
    //     4500 out-chains + ~5000 (src-shard, dst)-keyed in-chains for 5000
    //     edges => ~15.5 KB/edge measured (16,488 B/edge at the 50 k P6
    //     smoke). Slab packing (P2+) targets ≤ 64 B/edge amortized.
    // ------------------------------------------------------------------
    const out_growth = (try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_out.store")) - out_before;
    const in_growth = (try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_in_remote.store")) - in_before;
    const adj_growth = out_growth + in_growth;
    const bytes_per_edge = @as(f64, @floatFromInt(adj_growth)) / @as(f64, @floatFromInt(N_EDGES));
    std.debug.print(
        "\n[GAP adjacency-slab P0] {d} low-fanout edges: adj_out growth = {d} B, adj_in_remote growth = {d} B => {d:.1} adjacency bytes/edge (page_size {d})\n",
        .{ N_EDGES, out_growth, in_growth, bytes_per_edge, PAGE_SIZE },
    );
    // Documents today's bloat: a 1-2 entry chain (24-64 B live data) costs a
    // whole ≥8 KB block per direction. This legacy scenario keeps paying
    // blocks forever (read-both is permanent) and must stay green.
    try testing.expect(bytes_per_edge > 4096.0);

    // ------------------------------------------------------------------
    // (a) Parity oracle FORWARD: exact (from, to, rel_type, public_id) set
    //     via the single-shard out-chain walk.
    // ------------------------------------------------------------------
    var by_id = std.AutoHashMap(u64, usize).init(testing.allocator);
    defer by_id.deinit();
    for (made, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);

    var fwd: usize = 0;
    for (nodes) |n| {
        var it = try eng.expandOutIter(n, null);
        defer it.deinit();
        while (try it.next()) |e| {
            const m = &made[by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated];
            try testing.expect(!m.seen); // no duplicates
            m.seen = true;
            try testing.expectEqual(m.from, n);
            try testing.expectEqual(m.to, e.neighbor);
            try testing.expectEqual(REL, e.rel_type);
            try testing.expectEqual(m.public_id, e.public_id);
            fwd += 1;
        }
    }
    try testing.expectEqual(@as(usize, N_EDGES), fwd);
    for (made) |m| try testing.expect(m.seen);

    // ------------------------------------------------------------------
    // (a) Parity oracle REVERSE via FanInEdgeIterator: the fragmented
    //     adj_in_remote copies union to the exact same set (in-entry
    //     neighbor = source), with exact public_ids.
    // ------------------------------------------------------------------
    for (made) |*m| m.seen = false;
    var rev: usize = 0;
    for (nodes) |t| {
        var it = try eng.expandInIter(t, null);
        defer it.deinit();
        while (try it.next()) |e| {
            const m = &made[by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated];
            try testing.expect(!m.seen);
            m.seen = true;
            try testing.expectEqual(m.to, t);
            try testing.expectEqual(m.from, e.neighbor);
            try testing.expectEqual(REL, e.rel_type);
            try testing.expectEqual(m.public_id, e.public_id);
            rev += 1;
        }
    }
    try testing.expectEqual(@as(usize, N_EDGES), rev);
    for (made) |m| try testing.expect(m.seen);

    try testing.expectEqual(@as(u64, N_EDGES), try eng.edgeCount());
}
