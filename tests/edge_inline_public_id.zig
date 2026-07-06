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

/// Sum the on-disk size of one store file (e.g. "props.store",
/// "adj_out.store", "adj_in_remote.store") across every shard under
/// `data_dir`. ShardedGraphEngine.create lays shards out as
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

fn totalPropsStoreBytes(allocator: Allocator, data_dir: []const u8, base_uuid: [16]u8) !u64 {
    return totalShardStoreBytes(allocator, data_dir, base_uuid, "props.store");
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

    // In-place prop_head update must keep the entry's public_id intact
    // (updateEdgePropHead now reports the mutated PageId for WAL imaging).
    try testing.expectEqual(@as(?u64, head), try store.updateEdgePropHead(head, 102, 42));
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
    _ = try store.removeEdge(head, 101);
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

// ============================================================================
// P2 — v2 write path.
//
// NEW adjacency blocks are created v2 (entry_format=1, 32 B entries) by every
// block-construction site; a caller-supplied public_id persists. Appends into
// an EXISTING v1 block obey the no-truncate rule:
//   * public_id == 0 (legacy callers): append the 24 B v1 record in place —
//     bit-for-bit today's behavior, no format churn.
//   * public_id != 0: NEVER truncate into a 24 B record and NEVER rewrite the
//     v1 block — allocate a fresh v2 block as the new head, linked to the old
//     chain. v1 blocks stay read-only-FORMAT forever.
// ============================================================================

/// Raw 16-byte EdgeBlockHeader image of an adjacency page — read WITHOUT
/// AdjStore's parser so tests can assert on-disk formats independently.
const RawBlockHeader = struct {
    next_block: u64,
    count: u16,
    entry_format: u8,
    payload_size: u16,
};

fn readRawBlockHeader(pool: *BufferPool, file_id: anytype, page_id: u64) !RawBlockHeader {
    const frame = try pool.pin(file_id, page_id);
    const idx = pool.frameIndex(frame);
    defer pool.unpin(idx, false);
    const data = frame.dataSlice();
    const off = PAGE_HEADER_SIZE;
    return .{
        .next_block = std.mem.readInt(u64, data[off..][0..8], .little),
        .count = std.mem.readInt(u16, data[off + 8 ..][0..2], .little),
        .entry_format = data[off + 11],
        .payload_size = std.mem.readInt(u16, data[off + 12 ..][0..2], .little),
    };
}

test "P2: fresh writer blocks are v2 — public_id round-trips through addEdge" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    // New chain through the production writer: the block is created v2, so
    // the caller-supplied public_id IS stored (this replaces the P1 pin that
    // fresh blocks were still v1).
    const head = try store.addEdge(0, .{
        .neighbor = 10,
        .edge_id = 1,
        .rel_type = 5,
        .prop_head = 0,
        .public_id = 77,
    });

    const bh = try readRawBlockHeader(&env.base.pool, .adj_out, head);
    try testing.expectEqual(@as(u8, 1), bh.entry_format);
    try testing.expectEqual(@as(u16, 1), bh.count);
    try testing.expectEqual(@as(u16, 32), bh.payload_size);

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u64, 1), got[0].edge_id);
    try testing.expectEqual(@as(u64, 77), got[0].public_id);
}

test "P2: no-truncate rule — real public_id + v1 tail => fresh v2 head, v1 block untouched" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    // Legacy v1 head block with plenty of free slots.
    const v1_raw = [_]RawEdge{
        .{ .neighbor = 10, .edge_id = 1, .rel_type = 5 },
        .{ .neighbor = 20, .edge_id = 2, .rel_type = 5 },
    };
    const v1_page = try writeRawBlock(&env.base.pool, &env.base.fsm, 0, &v1_raw, 0);

    // Append an edge CARRYING a real public_id: despite the free space, the
    // writer must NOT drop the id into a 24 B record and must NOT rewrite the
    // v1 block — it allocates a fresh v2 head chained to the v1 block.
    const new_head = try store.addEdge(v1_page, .{
        .neighbor = 30,
        .edge_id = 3,
        .rel_type = 5,
        .prop_head = 0,
        .public_id = 0x9001,
    });
    try testing.expect(new_head != v1_page);

    const new_bh = try readRawBlockHeader(&env.base.pool, .adj_out, new_head);
    try testing.expectEqual(@as(u8, 1), new_bh.entry_format);
    try testing.expectEqual(@as(u16, 1), new_bh.count);
    try testing.expectEqual(v1_page, new_bh.next_block);

    // The v1 block is read-only-FORMAT: still v1, still exactly 2 entries.
    const old_bh = try readRawBlockHeader(&env.base.pool, .adj_out, v1_page);
    try testing.expectEqual(@as(u8, 0), old_bh.entry_format);
    try testing.expectEqual(@as(u16, 2), old_bh.count);
    try testing.expectEqual(@as(u16, 48), old_bh.payload_size);

    // Mixed v1→v2 chain enumerates correctly: real id for new, 0 for old.
    const got = try drainChain(&store, new_head, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(u64, 3), got[0].edge_id);
    try testing.expectEqual(@as(u64, 0x9001), got[0].public_id);
    try testing.expectEqual(@as(u64, 0), got[1].public_id);
    try testing.expectEqual(@as(u64, 0), got[2].public_id);
    try testing.expectEqual(@as(u64, 3), try store.edgeCount(new_head));
}

test "P2: legacy exception — public_id==0 appends in place into a v1 tail (bit-for-bit legacy)" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    const v1_raw = [_]RawEdge{
        .{ .neighbor = 10, .edge_id = 1, .rel_type = 5 },
        .{ .neighbor = 20, .edge_id = 2, .rel_type = 5 },
    };
    const v1_page = try writeRawBlock(&env.base.pool, &env.base.fsm, 0, &v1_raw, 0);

    // Legacy caller (public_id == 0): append INTO the v1 block — same head,
    // still v1, count+1, 24 B stride. No block-format churn for legacy writers.
    const head = try store.addEdge(v1_page, .{
        .neighbor = 30,
        .edge_id = 3,
        .rel_type = 5,
        .prop_head = 0,
        .public_id = 0,
    });
    try testing.expectEqual(v1_page, head);

    const bh = try readRawBlockHeader(&env.base.pool, .adj_out, v1_page);
    try testing.expectEqual(@as(u8, 0), bh.entry_format);
    try testing.expectEqual(@as(u16, 3), bh.count);
    try testing.expectEqual(@as(u16, 72), bh.payload_size); // 3 * 24 B

    const got = try drainChain(&store, head, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    for (got) |g| try testing.expectEqual(@as(u64, 0), g.public_id);
}

test "P2: FULL v1 head + public_id==0 => overflow block is v2 (new blocks are always v2)" {
    var env = try AdjEnv.init();
    env.fixup();
    defer env.deinit();
    var store = env.store();

    // Hand-build a COMPLETELY FULL v1 block.
    const v1_cap = edge_mod.entriesPerBlock(ADJ_PAGE_SIZE, edge_mod.ENTRY_FORMAT_V1);
    const full = try testing.allocator.alloc(RawEdge, v1_cap);
    defer testing.allocator.free(full);
    for (full, 0..) |*e, i| {
        e.* = .{ .neighbor = i + 1, .edge_id = i + 1, .rel_type = 5 };
    }
    const v1_page = try writeRawBlock(&env.base.pool, &env.base.fsm, 0, full, 0);

    // Even a LEGACY append (public_id == 0) that overflows allocates a v2
    // block — only in-place v1 appends stay v1.
    const new_head = try store.addEdge(v1_page, .{
        .neighbor = 999,
        .edge_id = 9999,
        .rel_type = 5,
        .prop_head = 0,
        .public_id = 0,
    });
    try testing.expect(new_head != v1_page);
    const bh = try readRawBlockHeader(&env.base.pool, .adj_out, new_head);
    try testing.expectEqual(@as(u8, 1), bh.entry_format);
    try testing.expectEqual(v1_page, bh.next_block);
    try testing.expectEqual(@as(u64, v1_cap + 1), try store.edgeCount(new_head));
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

// ============================================================================
// P2 — engine-level scenario-2: the inline-id write path end to end.
// ============================================================================

const GraphEngine = gs.GraphEngine;

const S2_EDGES = 5000;
/// Nonzero, unique public ids — high tag keeps them disjoint from edge_ids.
fn s2PublicId(i: usize) u64 {
    return 0x5EA0_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

const S2Edge = struct {
    edge_id: u64,
    from: u64,
    to: u64,
    public_id: u64,
    seen: bool = false,
};

test "P2 scenario-2: addEdgeColocatedWithPublicId — zero props growth, <=40 B/edge adjacency per direction, exact parity both directions" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE2} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, baselineConfig());
    defer eng.close() catch {};

    // 2 sources + 2 sinks => 5000 edges pack into LONG chains (~2500 entries
    // per out chain), so block-fill amortizes and the bytes/edge measurement
    // reflects the true v2 record cost (32 B + block overhead), not
    // one-mostly-empty-page-per-node fragmentation.
    var froms: [2]u64 = undefined;
    var tos: [2]u64 = undefined;
    for (&froms) |*f| {
        f.* = try eng.allocNode();
        try eng.putNode(f.*, test_support.emptyNode(1));
    }
    for (&tos) |*t| {
        t.* = try eng.allocNode();
        try eng.putNode(t.*, test_support.emptyNode(1));
    }

    // Baseline sizes BEFORE any edge exists (growth isolates the edge cost
    // from fixed per-shard store overhead).
    try eng.checkpoint();
    const props_before = try totalShardStoreBytes(testing.allocator, td.path, uuid, "props.store");
    const out_before = try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_out.store");
    const in_before = try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_in_remote.store");

    const made = try testing.allocator.alloc(S2Edge, S2_EDGES);
    defer testing.allocator.free(made);

    // NO edge property is written — the public id goes INLINE.
    for (made, 0..) |*m, i| {
        const from = froms[i % 2];
        const to = tos[(i / 2) % 2];
        const pid = s2PublicId(i);
        const id = try eng.addEdgeColocatedWithPublicId(from, to, REL, pid);
        m.* = .{ .edge_id = id, .from = from, .to = to, .public_id = pid };
    }
    try eng.checkpoint();

    // ------------------------------------------------------------------
    // (b) props.store contains ZERO edge chains: byte-identical to the
    //     pre-edge state (compare with 8218.2 B/edge on the legacy path).
    // ------------------------------------------------------------------
    const props_after = try totalShardStoreBytes(testing.allocator, td.path, uuid, "props.store");
    try testing.expectEqual(props_before, props_after);

    // ------------------------------------------------------------------
    // (c) adjacency growth ≤ 40 B/edge amortized, PER DIRECTION (each edge
    //     writes one 32 B v2 record into adj_out and one into adj_in_remote;
    //     40 B allows block-header + partial-tail-block amortization).
    // ------------------------------------------------------------------
    const out_growth = (try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_out.store")) - out_before;
    const in_growth = (try totalShardStoreBytes(testing.allocator, td.path, uuid, "adj_in_remote.store")) - in_before;
    std.debug.print(
        "\n[GAP edge-inline-public-id P2] {d} edges: props growth = {d} B, adj_out growth = {d} B ({d:.1} B/edge), adj_in_remote growth = {d} B ({d:.1} B/edge)\n",
        .{
            S2_EDGES,
            props_after - props_before,
            out_growth,
            @as(f64, @floatFromInt(out_growth)) / @as(f64, @floatFromInt(S2_EDGES)),
            in_growth,
            @as(f64, @floatFromInt(in_growth)) / @as(f64, @floatFromInt(S2_EDGES)),
        },
    );
    try testing.expect(out_growth <= 40 * S2_EDGES);
    try testing.expect(in_growth <= 40 * S2_EDGES);

    // ------------------------------------------------------------------
    // (a) parity FORWARD: exact (from, to, rel_type, public_id) set, and no
    //     edge carries a property chain (prop_head == 0 everywhere).
    // ------------------------------------------------------------------
    var by_id = std.AutoHashMap(u64, usize).init(testing.allocator);
    defer by_id.deinit();
    for (made, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);

    var fwd: usize = 0;
    for (froms) |n| {
        var it = try eng.expandOutIter(n, null);
        defer it.deinit();
        while (try it.next()) |e| {
            const m = &made[by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated];
            try testing.expect(!m.seen);
            m.seen = true;
            try testing.expectEqual(m.from, n);
            try testing.expectEqual(m.to, e.neighbor);
            try testing.expectEqual(REL, e.rel_type);
            try testing.expectEqual(m.public_id, e.public_id);
            try testing.expectEqual(@as(u32, 0), e.prop_head);
            fwd += 1;
        }
    }
    try testing.expectEqual(@as(usize, S2_EDGES), fwd);
    for (made) |m| try testing.expect(m.seen);

    // ------------------------------------------------------------------
    // (a) parity REVERSE via FanInEdgeIterator: the adj_in_remote copy
    //     carries the exact public_id too.
    // ------------------------------------------------------------------
    for (made) |*m| m.seen = false;
    var rev: usize = 0;
    for (tos) |t| {
        var it = try eng.expandInIter(t, null);
        defer it.deinit();
        while (try it.next()) |e| {
            const m = &made[by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated];
            try testing.expect(!m.seen);
            m.seen = true;
            try testing.expectEqual(m.to, t);
            try testing.expectEqual(m.from, e.neighbor); // in-entry neighbor = source
            try testing.expectEqual(REL, e.rel_type);
            try testing.expectEqual(m.public_id, e.public_id);
            rev += 1;
        }
    }
    try testing.expectEqual(@as(usize, S2_EDGES), rev);
    for (made) |m| try testing.expect(m.seen);

    try testing.expectEqual(@as(u64, S2_EDGES), try eng.edgeCount());
}

test "P2 mixed chain: legacy-then-new edges on the SAME from-node — public_id 0 for old, real for new" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE3} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, baselineConfig());
    defer eng.close() catch {};

    const from = try eng.allocNode();
    try eng.putNode(from, test_support.emptyNode(1));
    var tos: [6]u64 = undefined;
    for (&tos) |*t| {
        t.* = try eng.allocNode();
        try eng.putNode(t.*, test_support.emptyNode(1));
    }

    // 3 LEGACY edges (addEdge — the public_id==0 delegate), then 3 NEW edges
    // carrying real ids, all fanning out from the SAME node.
    var legacy_ids: [3]u64 = undefined;
    var new_ids: [3]u64 = undefined;
    for (0..3) |i| legacy_ids[i] = try eng.addEdge(from, tos[i], REL);
    for (0..3) |i| new_ids[i] = try eng.addEdgeColocatedWithPublicId(from, tos[3 + i], REL, 0xF00D_0000 + @as(u64, @intCast(i)));

    var it = try eng.expandOutIter(from, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| : (n += 1) {
        var matched = false;
        for (legacy_ids) |lid| {
            if (e.edge_id == lid) {
                try testing.expectEqual(@as(u64, 0), e.public_id);
                matched = true;
            }
        }
        for (new_ids, 0..) |nid, i| {
            if (e.edge_id == nid) {
                try testing.expectEqual(0xF00D_0000 + @as(u64, @intCast(i)), e.public_id);
                matched = true;
            }
        }
        try testing.expect(matched);
    }
    try testing.expectEqual(@as(usize, 6), n);

    // Reverse direction: each sink sees its one edge with the right id.
    for (tos, 0..) |t, i| {
        var in_it = try eng.expandInIter(t, null);
        defer in_it.deinit();
        const e = (try in_it.next()).?;
        try testing.expectEqual(from, e.neighbor);
        if (i < 3) {
            try testing.expectEqual(@as(u64, 0), e.public_id);
        } else {
            try testing.expectEqual(0xF00D_0000 + @as(u64, @intCast(i - 3)), e.public_id);
        }
        try testing.expectEqual(@as(?edge_mod.EdgeEntry, null), try in_it.next());
    }
}

// ============================================================================
// P2 — crash safety: the v2 block allocation + chain link ride the existing
// page-image WAL redo. Established crash pattern (Lever B / edge_colocation):
// commit writes, then deinit() WITHOUT close()/checkpoint() — only the
// fsynced WAL survives; reopen must replay it.
// ============================================================================

test "P2 crash: fresh v2 block linked into a v1 chain replays via WAL page-image redo" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE4} ** 16;
    const cfg = test_support.testConfig(); // sync_each_commit => WAL tail survives the crash

    const pid: u64 = 0xCAFE_F00D_0000_0001;
    var node_a: u64 = 0;
    var node_b: u64 = 0;
    var node_c: u64 = 0;
    var legacy_edge: u64 = 0;
    var new_edge: u64 = 0;
    var v1_page: u64 = 0;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        node_a = try eng.allocNode();
        node_b = try eng.allocNode();
        node_c = try eng.allocNode();
        try eng.putNode(node_a, test_support.emptyNode(1));
        try eng.putNode(node_b, test_support.emptyNode(1));
        try eng.putNode(node_c, test_support.emptyNode(1));

        // One legacy edge — its fresh block is v2 (public_id 0). Rewrite that
        // block IN PLACE to v1 (drop the trailing 8 zero bytes per record):
        // this is byte-exactly what a pre-P2 legacy store looks like, without
        // hand-allocating pages behind the free-space manager's back.
        legacy_edge = try eng.addEdgeColocated(node_a, node_b, REL);
        v1_page = (try eng.getNode(node_a)).?.out_head;
        {
            const store = &eng.adj_out;
            const frame = try store.buffer_pool.pin(store.file_id, v1_page);
            const idx = store.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const off = PAGE_HEADER_SIZE;
            try testing.expectEqual(@as(u8, 1), data[off + 11]); // was created v2
            try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, data[off + 8 ..][0..2], .little));
            data[off + 11] = 0; // entry_format = v1
            std.mem.writeInt(u16, data[off + 12 ..][0..2], 24, .little); // payload = 1 * 24 B
            @memset(data[off + 16 + 24 ..][0..8], 0); // scrub the dead public_id bytes
            store.buffer_pool.unpin(idx, true);
        }
        // Make the legacy-shaped store DURABLE (checkpoint flushes the page
        // and truncates the WAL) — the crash window below starts clean.
        try eng.checkpoint();

        // The append under test: v1 head with free space + real public_id =>
        // AdjStore allocates a fresh v2 block and links it as the new head.
        // The new page image + node-record update are WAL-logged and fsynced
        // by the commit.
        new_edge = try eng.addEdgeColocatedWithPublicId(node_a, node_c, REL, pid);

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Chain shape after redo: v2 head (the new edge) -> v1 tail (legacy).
        const head = (try eng.getNode(node_a)).?.out_head;
        try testing.expect(head != v1_page);
        const head_bh = try readRawBlockHeader(eng.adj_out.buffer_pool, eng.adj_out.file_id, head);
        try testing.expectEqual(@as(u8, 1), head_bh.entry_format);
        try testing.expectEqual(@as(u16, 1), head_bh.count);
        try testing.expectEqual(v1_page, head_bh.next_block);
        const tail_bh = try readRawBlockHeader(eng.adj_out.buffer_pool, eng.adj_out.file_id, v1_page);
        try testing.expectEqual(@as(u8, 0), tail_bh.entry_format);
        try testing.expectEqual(@as(u16, 1), tail_bh.count);

        // Parity oracle: the exact edge set with exact public_ids.
        var it = try eng.expandOutIter(node_a, null);
        defer it.deinit();
        const e_new = (try it.next()).?; // head block first
        try testing.expectEqual(new_edge, e_new.edge_id);
        try testing.expectEqual(node_c, e_new.neighbor);
        try testing.expectEqual(pid, e_new.public_id);
        const e_old = (try it.next()).?;
        try testing.expectEqual(legacy_edge, e_old.edge_id);
        try testing.expectEqual(node_b, e_old.neighbor);
        try testing.expectEqual(@as(u64, 0), e_old.public_id);
        try testing.expectEqual(@as(?edge_mod.EdgeEntry, null), try it.next());

        // Reverse copy (adj_in_remote) recovered the inline id too.
        var in_it = try eng.expandInRemoteIter(node_c, null);
        defer in_it.deinit();
        const in_e = (try in_it.next()).?;
        try testing.expectEqual(new_edge, in_e.edge_id);
        try testing.expectEqual(node_a, in_e.neighbor);
        try testing.expectEqual(pid, in_e.public_id);
        try testing.expectEqual(@as(?edge_mod.EdgeEntry, null), try in_it.next());
    }
}

test "P2 crash: plain v2 appends (multi-block chain) replay with exact public_ids" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE5} ** 16;
    const cfg = baselineConfig(); // 8192 pages, sync_each_commit default

    // > entriesPerBlock(8192, v2) = 254, so the single out chain MUST spill
    // into a second freshly-allocated v2 block inside the crash window.
    const N: usize = 300;

    var from: u64 = 0;
    var tos: [2]u64 = undefined;
    var made: [N]S2Edge = undefined;

    {
        var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        from = try eng.allocNode();
        try eng.putNode(from, test_support.emptyNode(1));
        for (&tos) |*t| {
            t.* = try eng.allocNode();
            try eng.putNode(t.*, test_support.emptyNode(1));
        }
        // Durable baseline: nodes exist, zero edges.
        try eng.checkpoint();

        // Every edge write below lands ONLY in the fsynced WAL tail.
        for (&made, 0..) |*m, i| {
            const to = tos[i % 2];
            const pid = 0xB0B0_0000_0000_0000 | @as(u64, @intCast(i + 1));
            const id = try eng.addEdgeColocatedWithPublicId(from, to, REL, pid);
            m.* = .{ .edge_id = id, .from = from, .to = to, .public_id = pid };
        }

        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    {
        var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        var by_id = std.AutoHashMap(u64, usize).init(testing.allocator);
        defer by_id.deinit();
        for (made, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);

        // Forward: exact set + exact ids across the recovered 2-block chain.
        var fwd: usize = 0;
        {
            var it = try eng.expandOutIter(from, null);
            defer it.deinit();
            while (try it.next()) |e| {
                const m = &made[by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated];
                try testing.expect(!m.seen);
                m.seen = true;
                try testing.expectEqual(m.to, e.neighbor);
                try testing.expectEqual(m.public_id, e.public_id);
                try testing.expectEqual(@as(u32, 0), e.prop_head);
                fwd += 1;
            }
        }
        try testing.expectEqual(N, fwd);
        for (made) |m| try testing.expect(m.seen);

        // Reverse via FanInEdgeIterator.
        for (&made) |*m| m.seen = false;
        var rev: usize = 0;
        for (tos) |t| {
            var it = try eng.expandInIter(t, null);
            defer it.deinit();
            while (try it.next()) |e| {
                const m = &made[by_id.get(e.edge_id) orelse return error.UnknownEdgeEnumerated];
                try testing.expect(!m.seen);
                m.seen = true;
                try testing.expectEqual(m.to, t);
                try testing.expectEqual(m.from, e.neighbor);
                try testing.expectEqual(m.public_id, e.public_id);
                rev += 1;
            }
        }
        try testing.expectEqual(N, rev);

        // Count heal (GAP-ENT-0025): manifest.edge_count is re-derived from
        // the applied adjacency images during replay, so the crash-recovered
        // count now matches the adjacency parity proven above. (Historically
        // it stayed checkpoint-granular — 0 here — and was deliberately not
        // asserted.)
        try testing.expectEqual(@as(u64, @intCast(N)), try eng.edgeCount());
    }
}

// ============================================================================
// P3 — EdgeIndexEntry + edge-index snapshot + consumers.
//
// In-memory EdgeIndexEntry gains `public_id: u64`; every insert site carries
// it (add path from the API param, rebuild from the adjacency scan — v1
// blocks yield 0). The persisted edge-index snapshot record grows 32 B → 40 B
// under a NEW magic: the magic IS the format version, so an OLD (GSEIDX2,
// 32 B-record) snapshot file is version-REJECTED by the loader's magic check
// (error.InvalidFormat → tryLoadDerivedIndexes catch-false → clean rebuild
// from durable adjacency) and can NEVER be misparsed as 40 B records.
// GAP warm-reopen P1 later moved both edge snapshots into the SORTED mmap
// container (GSEIDX4 / GSXIDX2 — see sorted_index_snapshot.zig); the same
// version-reject rule carries over, which these tests now assert.
// ============================================================================

const OLD_EDGE_SNAPSHOT_MAGIC = "GSEIDX2\x00"; // pre-P3 (32 B records)
// The edge snapshots use the SORTED mmap container (sorted_index_snapshot.zig)
// under bumped magics. WAL-aware durability grew the header a second stamp
// field, bumping GSEIDX4 -> GSEIDX5 / GSXIDX2 -> GSXIDX3.
const NEW_EDGE_SNAPSHOT_MAGIC = "GSEIDX5\x00"; // sorted 40 B records
const NEW_EXIST_SNAPSHOT_MAGIC = "GSXIDX3\x00"; // sorted 28 B records
const SNAPSHOT_CRC = std.hash.crc.Crc32Iscsi;
/// LEGACY container header: magic(8) + checkpoint_counter(8) + item_count(8).
const SNAPSHOT_HEADER = 24;
/// Sorted-container header: magic(8) + checkpoint_epoch(8) + covered_lsn(8) +
/// record_count(8) + record_size(4) + block_size(4).
const SORTED_HEADER = gs.sorted_index_snapshot.HEADER_SIZE;

/// Total on-disk size of a sorted-container snapshot with `n` records of
/// `record_size` bytes: header + payload + per-block CRC dir + meta CRC.
fn sortedSnapshotSize(n: usize, record_size: usize) usize {
    const payload = n * record_size;
    const nblocks = if (payload == 0) 0 else (payload - 1) / gs.sorted_index_snapshot.DEFAULT_BLOCK_SIZE + 1;
    return SORTED_HEADER + payload + nblocks * 4 + 4;
}

fn ioT() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Read a whole file into a caller-owned buffer.
fn readFileBytes(allocator: Allocator, path: []const u8) ![]u8 {
    const io = ioT();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const buf = try allocator.alloc(u8, @intCast(st.size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    try testing.expectEqual(buf.len, n);
    return buf;
}

/// Overwrite a file with `bytes` (truncate).
fn writeFileBytes(path: []const u8, bytes: []const u8) !void {
    const io = ioT();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setLength(io, 0);
    try f.writePositionalAll(io, bytes, 0);
}

/// Downgrade a NEW-format (GSEIDX4 sorted-container, 40 B records) edges.idx
/// file on disk into a byte-exact OLD-format (GSEIDX2 legacy container, 32 B
/// records) snapshot: same counter, same item_count, public_id column
/// dropped, legacy whole-file CRC32 appended. This is exactly what a pre-P3
/// binary would have written for the same edge set.
fn downgradeEdgeSnapshotToV2(allocator: Allocator, path: []const u8) !void {
    const data = try readFileBytes(allocator, path);
    defer allocator.free(data);

    try testing.expect(data.len >= SORTED_HEADER + 4);
    try testing.expectEqualStrings(NEW_EDGE_SNAPSHOT_MAGIC, data[0..8]);
    // New sorted layout: epoch@8, covered_lsn@16, record_count@24, size@32.
    const item_count = std.mem.readInt(u64, data[24..32], .little);
    try testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, data[32..36], .little));
    try testing.expectEqual(sortedSnapshotSize(@intCast(item_count), 40), data.len);
    const payload = data[SORTED_HEADER..][0 .. item_count * 40];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    // Legacy (pre-P3) container header: magic(8) | counter(8) | item_count(8).
    // The value bytes are irrelevant to the test (the loader rejects on the old
    // magic before parsing), but write a well-formed old header anyway.
    try out.appendSlice(allocator, OLD_EDGE_SNAPSHOT_MAGIC);
    try out.appendSlice(allocator, data[8..16]); // reuse epoch bytes as legacy counter
    var ic_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ic_buf, item_count, .little);
    try out.appendSlice(allocator, &ic_buf);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const rec = payload[i * 40 ..][0..40];
        try out.appendSlice(allocator, rec[0..32]); // drop trailing public_id u64
    }
    const crc = SNAPSHOT_CRC.hash(out.items);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc, .little);
    try out.appendSlice(allocator, &crc_buf);

    try writeFileBytes(path, out.items);
}

/// getEdge must surface the exact public_id from the edge_index route.
fn expectEdgePid(eng: anytype, edge_id: u64, want_pid: u64) !void {
    const e = (try eng.getEdge(edge_id)) orelse return error.EdgeNotFound;
    try testing.expectEqual(edge_id, e.edge_id);
    try testing.expectEqual(want_pid, e.public_id);
}

test "P3: edge_index route (getEdge) agrees with adjacency routes (expandOut + FanIn) on public_id" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE6} ** 16;

    var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, baselineConfig());
    defer eng.close() catch {};

    const a = try eng.allocNode();
    const b = try eng.allocNode();
    const c = try eng.allocNode();
    try eng.putNode(a, test_support.emptyNode(1));
    try eng.putNode(b, test_support.emptyNode(1));
    try eng.putNode(c, test_support.emptyNode(1));

    const pid: u64 = 0x1D_0000_0000_0042;
    const new_edge = try eng.addEdgeColocatedWithPublicId(a, b, REL, pid);
    const legacy_edge = try eng.addEdge(a, c, REL); // public_id 0 delegate

    // Route 1: edge_index (getEdge).
    try expectEdgePid(eng, new_edge, pid);
    try expectEdgePid(eng, legacy_edge, 0);

    // Route 2: adjacency out-chain.
    var out_new: ?u64 = null;
    var out_legacy: ?u64 = null;
    {
        var it = try eng.expandOutIter(a, null);
        defer it.deinit();
        while (try it.next()) |e| {
            if (e.edge_id == new_edge) out_new = e.public_id;
            if (e.edge_id == legacy_edge) out_legacy = e.public_id;
        }
    }
    try testing.expectEqual(@as(?u64, pid), out_new);
    try testing.expectEqual(@as(?u64, 0), out_legacy);

    // Route 3: FanInEdgeIterator (adj_in_remote).
    {
        var it = try eng.expandInIter(b, null);
        defer it.deinit();
        const e = (try it.next()).?;
        try testing.expectEqual(new_edge, e.edge_id);
        try testing.expectEqual(pid, e.public_id);
        try testing.expectEqual(@as(?edge_mod.EdgeEntry, null), try it.next());
    }
}

const P3_N = 53; // deliberately odd; 3 legacy + 50 v2 below

fn p3Pid(i: usize) u64 {
    return 0x9D3_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

const P3Nodes = struct { a: u64, sinks: [4]u64 };

fn p3Nodes(eng: *GraphEngine) !P3Nodes {
    var n: P3Nodes = undefined;
    n.a = try eng.allocNode();
    try eng.putNode(n.a, test_support.emptyNode(1));
    for (&n.sinks) |*s| {
        s.* = try eng.allocNode();
        try eng.putNode(s.*, test_support.emptyNode(1));
    }
    return n;
}

/// 3 legacy edges + 50 v2-with-pid edges out of `n.a`
/// (index < 3 → legacy/pid 0, else pid p3Pid(i)).
fn p3Edges(eng: *GraphEngine, n: P3Nodes, ids: *[P3_N]u64) !void {
    for (ids, 0..) |*slot, i| {
        const to = n.sinks[i % n.sinks.len];
        slot.* = if (i < 3)
            try eng.addEdgeColocated(n.a, to, REL)
        else
            try eng.addEdgeColocatedWithPublicId(n.a, to, REL, p3Pid(i));
    }
}

fn p3Populate(eng: *GraphEngine, ids: *[P3_N]u64) !void {
    const n = try p3Nodes(eng);
    try p3Edges(eng, n, ids);
}

test "P3 snapshot round-trip: clean reopen LOADS the 40 B-record snapshot (no rebuild), ids intact" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE7} ** 16;
    const cfg = test_support.testConfig();

    var ids: [P3_N]u64 = undefined;
    var idx_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try p3Populate(eng, &ids);
        try eng.checkpoint(); // full checkpoint saves the derived snapshots
        idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(idx_path);

    // On-disk snapshot shape: sorted container — header + P3_N 40 B records
    // (sorted by edge_id) + block-CRC dir + meta CRC, new magic.
    {
        const data = try readFileBytes(testing.allocator, idx_path);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings(NEW_EDGE_SNAPSHOT_MAGIC, data[0..8]);
        // record_count@24, record_size@32 under the two-stamp sorted header.
        try testing.expectEqual(@as(u64, P3_N), std.mem.readInt(u64, data[24..32], .little));
        try testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, data[32..36], .little));
        try testing.expectEqual(sortedSnapshotSize(P3_N, 40), data.len);
        // Records are sorted by edge_id (the binary-search invariant).
        var prev: u64 = 0;
        var ri: usize = 0;
        while (ri < P3_N) : (ri += 1) {
            const id = std.mem.readInt(u64, data[SORTED_HEADER + ri * 40 ..][0..8], .little);
            try testing.expect(id > prev);
            prev = id;
        }
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Nothing hydrated at open (Phase A) — the getEdge below is the
        // first-access that runs the counter-gated LOAD.
        try testing.expectEqual(@as(u32, 0), eng.derived_materialize_runs);
        for (ids, 0..) |id, i| {
            try expectEdgePid(eng, id, if (i < 3) 0 else p3Pid(i));
        }
        // Clean restart: snapshot LOADED, not rebuilt.
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P3 old-format snapshot (GSEIDX2, 32 B records) → clean version-reject → rebuild recovers ids from adjacency" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE8} ** 16;
    const cfg = test_support.testConfig();

    var ids: [P3_N]u64 = undefined;
    var idx_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try p3Populate(eng, &ids);
        try eng.checkpoint();
        idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(idx_path);

    // Swap in the byte-exact pre-P3 snapshot a v0.2.23 binary would have
    // written: OLD magic, 32 B records, SAME (matching!) checkpoint counter —
    // so the ONLY thing standing between this file and a misparse is the
    // format gate, not the staleness counter.
    try downgradeEdgeSnapshotToV2(testing.allocator, idx_path);

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        for (ids, 0..) |id, i| {
            try expectEdgePid(eng, id, if (i < 3) 0 else p3Pid(i));
        }
        // The old-format file was REJECTED (never misparsed) and the whole
        // derived set was rebuilt from durable adjacency — v2 blocks carry the
        // ids, so they survive the version bump with zero loss.
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P3 crash between edge writes and checkpoint → recovery → getEdge ids exact (rebuild path)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE9} ** 16;
    const cfg = test_support.testConfig(); // sync_each_commit: WAL tail survives

    var ids: [P3_N]u64 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        // Durable baseline (nodes + clean empty edge snapshot). Node CREATION
        // must be durable here because manifest.next_node_id is checkpoint-
        // granular (recovery replays page images, it does not re-derive
        // manifest counters — pre-existing property, see the P2 crash note).
        const n = try p3Nodes(eng);
        try eng.checkpoint();
        // Every EDGE below lives ONLY in the fsynced WAL tail — the crash
        // window under test is "edge writes → crash → recovery".
        try p3Edges(eng, n, &ids);
        // SIMULATED CRASH: no checkpoint, no close.
        eng.deinit();
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        for (ids, 0..) |id, i| {
            try expectEdgePid(eng, id, if (i < 3) 0 else p3Pid(i));
        }
        // Crash restart: the pre-crash snapshot is stale (WAL replay advanced
        // the manifest counter), so the edge_index was REBUILT from the
        // WAL-recovered adjacency — ids exact.
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P3 mixed v1/v2 adjacency → rebuild → v1 edges surface id 0, v2 edges real ids" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xEA} ** 16;
    const cfg = test_support.testConfig();

    const pid: u64 = 0xCAFE_0000_0000_0077;
    var node_a: u64 = 0;
    var node_b: u64 = 0;
    var node_c: u64 = 0;
    var legacy_edge: u64 = 0;
    var new_edge: u64 = 0;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        node_a = try eng.allocNode();
        node_b = try eng.allocNode();
        node_c = try eng.allocNode();
        try eng.putNode(node_a, test_support.emptyNode(1));
        try eng.putNode(node_b, test_support.emptyNode(1));
        try eng.putNode(node_c, test_support.emptyNode(1));

        // Legacy edge, then rewrite its (v2-created) block IN PLACE to v1 —
        // byte-exactly a pre-P2 legacy store (same trick as the P2 crash test).
        legacy_edge = try eng.addEdgeColocated(node_a, node_b, REL);
        const v1_page = (try eng.getNode(node_a)).?.out_head;
        {
            const store = &eng.adj_out;
            const frame = try store.buffer_pool.pin(store.file_id, v1_page);
            const idx = store.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const off = PAGE_HEADER_SIZE;
            data[off + 11] = 0; // entry_format = v1
            std.mem.writeInt(u16, data[off + 12 ..][0..2], 24, .little);
            @memset(data[off + 16 + 24 ..][0..8], 0);
            store.buffer_pool.unpin(idx, true);
        }
        try eng.checkpoint();

        // New edge WITH a real id: no-truncate rule chains a fresh v2 head
        // block onto the v1 block — a mixed chain on ONE node.
        new_edge = try eng.addEdgeColocatedWithPublicId(node_a, node_c, REL, pid);

        // SIMULATED CRASH so the reopen is forced down the REBUILD path (the
        // point under test: rebuildEdgeIndex carrying public_id across a
        // mixed-format chain).
        eng.deinit();
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        try expectEdgePid(eng, legacy_edge, 0); // v1 block → id 0 (fallback class)
        try expectEdgePid(eng, new_edge, pid); // v2 block → exact id
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P3 existence index untouched: MERGE dedup (probeEdge) works on v2 edges, 28 B snapshot records" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xEB} ** 16;
    const cfg = test_support.testConfig();

    const pid: u64 = 0xD00D_0000_0000_0001;
    var from: u64 = 0;
    var to: u64 = 0;
    var edge: u64 = 0;
    var exist_path: []u8 = undefined;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        from = try eng.allocNode();
        to = try eng.allocNode();
        try eng.putNode(from, test_support.emptyNode(1));
        try eng.putNode(to, test_support.emptyNode(1));
        edge = try eng.addEdgeColocatedWithPublicId(from, to, REL, pid);

        // MERGE dedup probe finds the v2 edge (and nothing for other tuples).
        var buf: [4]u64 = undefined;
        const hits = try eng.probeEdge(from, REL, to, &buf);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(edge, hits[0]);
        const misses = try eng.probeEdge(from, REL + 1, to, &buf);
        try testing.expectEqual(@as(usize, 0), misses.len);

        try eng.checkpoint();
        exist_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges_exist.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(exist_path);

    // The existence snapshot record FIELDS are unchanged (28 B: from u64 +
    // to u64 + rel u32 + edge_id u64 — no prop_head/public_id); the sorted mmap
    // container carries them under the GSXIDX3 magic.
    {
        const data = try readFileBytes(testing.allocator, exist_path);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings(NEW_EXIST_SNAPSHOT_MAGIC, data[0..8]);
        // record_count@24, record_size@32 under the two-stamp sorted header.
        try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, data[24..32], .little));
        try testing.expectEqual(@as(u32, 28), std.mem.readInt(u32, data[32..36], .little));
        try testing.expectEqual(sortedSnapshotSize(1, 28), data.len);
    }

    // After a clean reopen (snapshot LOAD path) the probe still dedups.
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        var buf: [4]u64 = undefined;
        const hits = try eng.probeEdge(from, REL, to, &buf);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(edge, hits[0]);
        try expectEdgePid(eng, edge, pid);
    }
}

test {
    std.testing.refAllDecls(@This());
}
