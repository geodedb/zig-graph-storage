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

// ============================================================================
// P1 — v2 EdgeEntry read path (block-granular read-both).
//
// EdgeBlockHeader's former `_reserved` byte (always written 0 by every block
// creation site since the format's birth) becomes `entry_format`:
//   0 = v1: 24 B entries (neighbor u64, edge_id u64, rel_type u32, prop_head u32)
//   1 = v2: 32 B entries (+ public_id u64)
// Readers parse BOTH formats per block; v1 entries surface `public_id = 0`.
// Writers are UNCHANGED in P1 (new blocks are still v1) — the tests below
// hand-construct raw v1/v2 block bytes independently of the production
// writer so they stay an oracle for it.
// ============================================================================

const edge_mod = gs.edge;
const AdjStore = gs.adj_store.AdjStore;
const BufferPool = gs.buffer_pool.BufferPool;
const FreeSpaceManager = gs.free_space.FreeSpaceManager;
const PAGE_HEADER_SIZE = edge_mod.PAGE_HEADER_SIZE;

const ADJ_PAGE_SIZE: u32 = 4096;

/// Raw edge tuple for hand-built blocks.
const RawEdge = struct {
    neighbor: u64,
    edge_id: u64,
    rel_type: u32,
    prop_head: u32 = 0,
    public_id: u64 = 0,
};

/// Hand-write one adjacency block page with raw bytes: EdgeBlockHeader at
/// PAGE_HEADER_SIZE, then `entries` at the format's stride. Deliberately does
/// NOT go through AdjStore's writer — this is the on-disk-format oracle.
/// Byte layout (little-endian, matching the extern-struct layout on x86-64):
///   +0  next_block  u64
///   +8  count       u16
///   +10 kind        u8
///   +11 entry_format u8   (0 = v1/24 B, 1 = v2/32 B)
///   +12 payload_size u16
///   +14 checksum    u16
fn writeRawBlock(
    pool: *BufferPool,
    fsm: *FreeSpaceManager,
    entry_format: u8,
    entries: []const RawEdge,
    next_block: u64,
) !u64 {
    const page_id = try fsm.allocPage();
    const frame = try pool.pinNew(.adj_out, page_id);
    const frame_idx = pool.frameIndex(frame);
    const data = frame.dataSlice();

    const esz: usize = if (entry_format == 1) 32 else 24;
    const off: usize = PAGE_HEADER_SIZE;
    std.mem.writeInt(u64, data[off..][0..8], next_block, .little);
    std.mem.writeInt(u16, data[off + 8 ..][0..2], @intCast(entries.len), .little);
    data[off + 10] = 0; // kind: mixed
    data[off + 11] = entry_format;
    std.mem.writeInt(u16, data[off + 12 ..][0..2], @intCast(entries.len * esz), .little);
    std.mem.writeInt(u16, data[off + 14 ..][0..2], 0, .little); // checksum (unused)

    var eoff: usize = off + 16;
    for (entries) |e| {
        std.mem.writeInt(u64, data[eoff..][0..8], e.neighbor, .little);
        std.mem.writeInt(u64, data[eoff + 8 ..][0..8], e.edge_id, .little);
        std.mem.writeInt(u32, data[eoff + 16 ..][0..4], e.rel_type, .little);
        std.mem.writeInt(u32, data[eoff + 20 ..][0..4], e.prop_head, .little);
        if (entry_format == 1) {
            std.mem.writeInt(u64, data[eoff + 24 ..][0..8], e.public_id, .little);
        }
        eoff += esz;
    }

    pool.unpin(frame_idx, true);
    return page_id;
}

/// Drain an AdjStore chain into a caller-owned slice.
fn drainChain(store: *AdjStore, head: u64, allocator: Allocator) ![]edge_mod.EdgeEntry {
    var it = store.expand(head, null);
    defer it.deinit();
    var list: std.ArrayList(edge_mod.EdgeEntry) = .empty;
    errdefer list.deinit(allocator);
    while (try it.next()) |e| try list.append(allocator, e);
    return list.toOwnedSlice(allocator);
}

const AdjEnv = struct {
    base: test_support.SingleStoreEnv,

    fn init() !AdjEnv {
        return .{ .base = try test_support.SingleStoreEnv.init(
            testing.allocator,
            .adj_out,
            "adj_out.store",
            ADJ_PAGE_SIZE,
            32,
        ) };
    }

    /// Must run AFTER the env struct has reached its final address.
    fn fixup(self: *AdjEnv) void {
        self.base.register();
    }

    fn store(self: *AdjEnv) AdjStore {
        return AdjStore.init(&self.base.pool, &self.base.fsm, .adj_out, ADJ_PAGE_SIZE);
    }

    fn deinit(self: *AdjEnv) void {
        self.base.deinit();
    }
};

test "P1: hand-built v1 block enumerates correctly with public_id=0" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    const raw = [_]RawEdge{
        .{ .neighbor = 10, .edge_id = 1, .rel_type = 5, .prop_head = 7 },
        .{ .neighbor = 20, .edge_id = 2, .rel_type = 5 },
        .{ .neighbor = 30, .edge_id = 3, .rel_type = 6 },
    };
    const head = try writeRawBlock(&env.base.pool, &env.base.fsm, 0, &raw, 0);

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    for (got, raw) |g, r| {
        try testing.expectEqual(r.neighbor, g.neighbor);
        try testing.expectEqual(r.edge_id, g.edge_id);
        try testing.expectEqual(r.rel_type, g.rel_type);
        try testing.expectEqual(r.prop_head, g.prop_head);
        // v1 blocks carry no public_id: readers must surface 0.
        try testing.expectEqual(@as(u64, 0), g.public_id);
    }
    try testing.expectEqual(@as(u64, 3), try store.edgeCount(head));
}

test "P1: hand-built v2 block enumerates correctly with stored public_ids" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    const raw = [_]RawEdge{
        .{ .neighbor = 11, .edge_id = 101, .rel_type = 5, .prop_head = 9, .public_id = 0xDEAD_BEEF_0000_0001 },
        .{ .neighbor = 22, .edge_id = 102, .rel_type = 5, .public_id = 0xDEAD_BEEF_0000_0002 },
        .{ .neighbor = 33, .edge_id = 103, .rel_type = 6, .public_id = std.math.maxInt(u64) },
    };
    const head = try writeRawBlock(&env.base.pool, &env.base.fsm, 1, &raw, 0);

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    for (got, raw) |g, r| {
        try testing.expectEqual(r.neighbor, g.neighbor);
        try testing.expectEqual(r.edge_id, g.edge_id);
        try testing.expectEqual(r.rel_type, g.rel_type);
        try testing.expectEqual(r.prop_head, g.prop_head);
        try testing.expectEqual(r.public_id, g.public_id);
    }
    try testing.expectEqual(@as(u64, 3), try store.edgeCount(head));

    // rel_type filtering still works on v2 blocks.
    var it = store.expand(head, 6);
    defer it.deinit();
    const only = (try it.next()).?;
    try testing.expectEqual(@as(u64, 103), only.edge_id);
    try testing.expectEqual(std.math.maxInt(u64), only.public_id);
    try testing.expectEqual(@as(?edge_mod.EdgeEntry, null), try it.next());
}

test "P1: mixed chain (v2 head -> v1 overflow) enumerates across the format boundary" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    // Old v1 block deeper in the chain (legacy data)...
    const v1_raw = [_]RawEdge{
        .{ .neighbor = 10, .edge_id = 1, .rel_type = 5 },
        .{ .neighbor = 20, .edge_id = 2, .rel_type = 5 },
        .{ .neighbor = 30, .edge_id = 3, .rel_type = 5 },
    };
    const v1_page = try writeRawBlock(&env.base.pool, &env.base.fsm, 0, &v1_raw, 0);

    // ...chained from a newer v2 head block (head-insert order).
    const v2_raw = [_]RawEdge{
        .{ .neighbor = 44, .edge_id = 204, .rel_type = 5, .public_id = 0xAA00_0000_0000_0004 },
        .{ .neighbor = 55, .edge_id = 205, .rel_type = 5, .public_id = 0xAA00_0000_0000_0005 },
    };
    const head = try writeRawBlock(&env.base.pool, &env.base.fsm, 1, &v2_raw, v1_page);

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);

    // Head block first (v2, ids surface), then the v1 tail (ids 0).
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqual(@as(u64, 204), got[0].edge_id);
    try testing.expectEqual(@as(u64, 0xAA00_0000_0000_0004), got[0].public_id);
    try testing.expectEqual(@as(u64, 205), got[1].edge_id);
    try testing.expectEqual(@as(u64, 0xAA00_0000_0000_0005), got[1].public_id);
    for (got[2..], v1_raw) |g, r| {
        try testing.expectEqual(r.edge_id, g.edge_id);
        try testing.expectEqual(r.neighbor, g.neighbor);
        try testing.expectEqual(@as(u64, 0), g.public_id);
    }
    try testing.expectEqual(@as(u64, 5), try store.edgeCount(head));
}

test "P1: updateEdgePropHead + removeEdge on a v2 block preserve public_ids" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    const raw = [_]RawEdge{
        .{ .neighbor = 11, .edge_id = 101, .rel_type = 5, .public_id = 0xB001 },
        .{ .neighbor = 22, .edge_id = 102, .rel_type = 5, .public_id = 0xB002 },
        .{ .neighbor = 33, .edge_id = 103, .rel_type = 5, .public_id = 0xB003 },
    };
    const head = try writeRawBlock(&env.base.pool, &env.base.fsm, 1, &raw, 0);

    // In-place prop_head update must keep the entry's public_id intact.
    try testing.expect(try store.updateEdgePropHead(head, 102, 42));
    {
        const got = try drainChain(&store, head, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 3), got.len);
        for (got) |g| {
            if (g.edge_id == 102) {
                try testing.expectEqual(@as(u32, 42), g.prop_head);
                try testing.expectEqual(@as(u64, 0xB002), g.public_id);
            }
        }
    }

    // Swap-remove of the FIRST entry moves the last entry (v2 stride) into
    // its slot — the mover's public_id must ride along.
    try store.removeEdge(head, 101);
    {
        const got = try drainChain(&store, head, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 2), got.len);
        for (got) |g| {
            switch (g.edge_id) {
                102 => try testing.expectEqual(@as(u64, 0xB002), g.public_id),
                103 => try testing.expectEqual(@as(u64, 0xB003), g.public_id),
                else => return error.UnexpectedEdge,
            }
        }
    }
}

test "P1: addEdge append into an existing v2 block writes the v2 stride (public_id round-trips)" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    const raw = [_]RawEdge{
        .{ .neighbor = 11, .edge_id = 101, .rel_type = 5, .public_id = 0xC001 },
    };
    const head = try writeRawBlock(&env.base.pool, &env.base.fsm, 1, &raw, 0);

    // Append through the production writer: the block is v2, so the entry is
    // written at the 32 B stride and its public_id persists.
    const new_head = try store.addEdge(head, .{
        .neighbor = 22,
        .edge_id = 102,
        .rel_type = 5,
        .prop_head = 0,
        .public_id = 0xC002,
    });
    try testing.expectEqual(head, new_head); // space in the head block

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(u64, 0xC001), got[0].public_id);
    try testing.expectEqual(@as(u64, 0xC002), got[1].public_id);
}

test "P1: writers unchanged — fresh blocks are still v1 and drop public_id (P2 flips this)" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    // New chain through the production writer: block is created v1 (the
    // legacy zero-init byte), so a caller-supplied public_id is NOT stored
    // yet. This pins P1's "read-both only" scope; the P2 write path replaces
    // this expectation with round-tripping.
    const head = try store.addEdge(0, .{
        .neighbor = 10,
        .edge_id = 1,
        .rel_type = 5,
        .prop_head = 0,
        .public_id = 77,
    });

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u64, 1), got[0].edge_id);
    try testing.expectEqual(@as(u64, 0), got[0].public_id);
}

test "P1: unknown entry_format is rejected as corruption, never misparsed" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    const raw = [_]RawEdge{
        .{ .neighbor = 10, .edge_id = 1, .rel_type = 5 },
    };
    const head = try writeRawBlock(&env.base.pool, &env.base.fsm, 2, &raw, 0);

    var it = store.expand(head, null);
    defer it.deinit();
    try testing.expectError(error.DataCorruption, it.next());
}

test {
    std.testing.refAllDecls(@This());
}
