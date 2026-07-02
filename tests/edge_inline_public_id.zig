// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP-ENT-0024 — inline public edge id (kill one-page-per-edge).
//
// P0 (this file, BASELINE scenario — must stay green through ALL phases):
//
//   Today geode persists the public edge id by writing a
//   `__geode_internal_edge_id` property on EVERY edge through the canonical
//   edge-property write path (ShardedGraphEngine.setEdgeProperty →
//   engine_edge_props.setEdgeProperty → putPropertyLegacy + prop_head
//   backpatch into both adjacency copies + edge index). putPropertyLegacy
//   allocates a whole ≥page_size props page for the FIRST property of each
//   edge, so a 16-hex-char id burns a full page per edge (~8,350 B/edge
//   measured at 13.8 M edges ≈ ~113 GB).
//
//   1. Parity ORACLE: full edge enumeration returns the EXACT
//      (from, to, rel_type) set, with the id property readable per edge.
//      This is the reference every later phase (inline-id write path,
//      v2 blocks, snapshot bump) must keep green.
//
//   2. Baseline cost LOCK-IN: props.store bytes/edge > 4096 — documents the
//      current one-page-per-edge bloat that the inline public_id removes.
//      The legacy property path must KEEP working (read-both is permanent),
//      so this scenario is never deleted, only complemented by the
//      inline-id scenario (P2+).

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const ShardedGraphEngine = gs.ShardedGraphEngine;
const test_support = gs.test_support;
const shard_count = gs.shard_count;
const shard_uuid = gs.shard_uuid;
const sharded_engine = gs.sharded_engine;

/// The exact property key geode writes today for every edge.
const EDGE_ID_KEY = "__geode_internal_edge_id";

/// Production-shaped page size (default GraphConfig.page_size). The baseline
/// assertion (bytes/edge > 4096) is only meaningful at the real page size.
const PAGE_SIZE: u32 = 8192;

const N_NODES = 100;
const N_EDGES = 5000;
const REL: u32 = 7;

fn baselineConfig() gs.GraphConfig {
    return .{
        .page_size = PAGE_SIZE,
        .buffer_pool_pages = 256,
        .data_dir = "data",
    };
}

/// 16-hex-char public edge id string — mirrors geode's formatting of the
/// minted u64 public id today.
fn edgeIdHex(id: u64, buf: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{id}) catch unreachable;
}

const MadeEdge = struct {
    edge_id: u64,
    from: u64,
    to: u64,
    seen: bool = false,
};

/// Sum the on-disk size of every shard's props.store under `data_dir`.
/// ShardedGraphEngine.create lays shards out as
/// `data_dir/<parent-uuid-hex>/graphs/<derived-shard-uuid-hex>/props.store`.
fn totalPropsStoreBytes(allocator: Allocator, data_dir: []const u8, base_uuid: [16]u8) !u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const parent_hex = sharded_engine.uuidHex(base_uuid);
    var total: u64 = 0;
    for (0..shard_count.SHARD_COUNT) |s| {
        const suuid = shard_uuid.deriveShardUuid(base_uuid, s);
        const hex = sharded_engine.uuidHex(suuid);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}/graphs/{s}/props.store", .{ data_dir, parent_hex, hex });
        defer allocator.free(path);
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        total += st.size;
    }
    return total;
}

test "GAP edge-inline-public-id P0 baseline: legacy id-property parity oracle + one-page-per-edge cost lock-in" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE0} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, baselineConfig());
    defer eng.close() catch {};

    // Pre-create the endpoint nodes.
    var nodes: [N_NODES]u64 = undefined;
    for (&nodes) |*slot| {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        slot.* = n;
    }

    // Create N_EDGES edges. ShardedGraphEngine.addEdge delegates to the
    // co-located single-shard write path (GraphEngine.addEdgeColocated on
    // shard(from)) — the same surface geode's adapter uses.
    const made = try testing.allocator.alloc(MadeEdge, N_EDGES);
    defer testing.allocator.free(made);

    for (made, 0..) |*m, i| {
        const from = nodes[i % N_NODES];
        const to = nodes[(i * 7 + 3) % N_NODES];
        const id = try eng.addEdge(from, to, REL);
        m.* = .{ .edge_id = id, .from = from, .to = to };

        // Mirror geode today: persist the public id as a LEGACY property via
        // the canonical edge-property write path. setEdgeProperty internally
        // calls putPropertyLegacy and stores the returned prop_head back into
        // both adjacency copies + the edge index — the real geode-facing
        // surface (raw putPropertyLegacy would skip the backpatch).
        var buf: [16]u8 = undefined;
        const hex = edgeIdHex(id, &buf);
        try eng.setEdgeProperty(from, to, id, EDGE_ID_KEY, .{ .string = hex });
    }

    // Flush everything so on-disk props.store sizes reflect all allocations.
    try eng.checkpoint();

    // ------------------------------------------------------------------
    // (b) Baseline cost lock-in: ≈ one ≥8 KB props page per edge.
    // ------------------------------------------------------------------
    const props_bytes = try totalPropsStoreBytes(testing.allocator, td.path, uuid);
    const bytes_per_edge = @as(f64, @floatFromInt(props_bytes)) / @as(f64, @floatFromInt(N_EDGES));
    std.debug.print(
        "\n[GAP edge-inline-public-id P0] props.store total = {d} B over {d} edges => {d:.1} props-store bytes/edge (page_size {d})\n",
        .{ props_bytes, N_EDGES, bytes_per_edge, PAGE_SIZE },
    );
    // Documents today's bloat: a 16-char id property costs (at least) more
    // than half a production page per edge. Inline public_id (P2+) drives the
    // props cost for property-less edges to ZERO; this legacy scenario keeps
    // paying pages forever (read-both is permanent) and must stay green.
    try testing.expect(bytes_per_edge > 4096.0);

    // ------------------------------------------------------------------
    // (a) Parity oracle: exact (from, to, rel_type) set with readable id.
    // ------------------------------------------------------------------
    var by_id = std.AutoHashMap(u64, usize).init(testing.allocator);
    defer by_id.deinit();
    for (made, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var enumerated: usize = 0;
    for (nodes) |n| {
        var it = try eng.expandOutIter(n, null);
        defer it.deinit();
        while (try it.next()) |e| {
            const idx = by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated;
            const m = &made[idx];
            try testing.expect(!m.seen); // no duplicates
            m.seen = true;
            try testing.expectEqual(m.from, n);
            try testing.expectEqual(m.to, e.neighbor);
            try testing.expectEqual(REL, e.rel_type);

            // The id property is readable per edge and round-trips exactly.
            var buf: [16]u8 = undefined;
            const want_hex = edgeIdHex(e.edge_id, &buf);
            const got = try eng.getEdgeProperty(m.from, e.edge_id, EDGE_ID_KEY, arena.allocator());
            try testing.expect(got != null);
            try testing.expectEqualStrings(want_hex, got.?.string);

            enumerated += 1;
        }
    }
    // Exact set: every created edge enumerated exactly once, nothing extra.
    try testing.expectEqual(@as(usize, N_EDGES), enumerated);
    for (made) |m| try testing.expect(m.seen);
}

test {
    std.testing.refAllDecls(@This());
}
