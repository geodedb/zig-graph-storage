// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP adjacency slab packing — PHASE 4 crash / WAL matrix (release gate).
//
// The slab writer is the hottest structure; every mutating window must recover
// with the live-head invariant intact — after a crash + WAL replay EVERY stored
// head references a LIVE run (never a half-migrated dangling head), no live edge
// is lost, and no committed id is re-issued. The crash model matches the rest of
// the suite: `deinit` WITHOUT checkpoint/close, so only the fsynced WAL tail
// survives; reopen replays it. Each test forces its window DETERMINISTICALLY
// (striped `id % SHARD_COUNT` routing lets us co-locate two sources in one shard
// so a grow relocates), PROVES the window fired (head moved / graduated), then
// crashes + reopens + asserts full parity both directions.
//
//   P4.1 RELOCATION  — a middle run grows -> relocates to a new slot; the old
//                      slot is tombstoned LAST. Reopen: stored head on a live
//                      run, siblings in the shared block intact, no lost edge.
//   P4.2 GRADUATION  — a chain outgrows a slab block -> migrates to a legacy
//                      chain; old slot tombstoned LAST. Reopen: head is the
//                      COMPLETE legacy chain (never a half-migrated dangle).
//   P4.3 TOMBSTONE   — slab remove (swap-with-last) + in-place prop update on a
//                      SHARED block. Reopen: mutation applied, head live, other
//                      slots intact.
//   P4.4 DEFERRED    — sync_mode=.deferred, a tail spanning relocation AND
//                      graduation. Reopen: replays, and the counter harvest
//                      heals ids that live only in replayed slab runs.
//   P4.5 MIXED       — some chains legacy (written slab-OFF), some slab (written
//                      slab-ON after a reopen). Crash + reopen: read-both parity.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const ShardedGraphEngine = gs.ShardedGraphEngine;
const test_support = gs.test_support;
const shard_count = gs.shard_count;
const adj_store = gs.adj_store;

const REL: u32 = 11;

fn slabConfig(page_size: u32) gs.GraphConfig {
    return .{
        .page_size = page_size,
        .buffer_pool_pages = 256,
        .data_dir = "data",
        .adjacency_slab_packing = true,
    };
}

fn legacyConfig(page_size: u32) gs.GraphConfig {
    return .{
        .page_size = page_size,
        .buffer_pool_pages = 256,
        .data_dir = "data",
        .adjacency_slab_packing = false,
    };
}

fn deferredSlabConfig(page_size: u32) gs.GraphConfig {
    var c = slabConfig(page_size);
    c.sync_mode = .deferred;
    return c;
}

fn publicId(i: usize) u64 {
    return 0xADAD_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

const MadeEdge = struct {
    edge_id: u64,
    from: u64,
    to: u64,
    public_id: u64,
};

/// Allocate nodes into `pool` until some shard holds `per_shard` of them, and
/// collect that shard's nodes into `group`. Striped routing (`id % SHARD_COUNT`)
/// guarantees the group's out-chains share one shard's adj_out fill block, so a
/// grow of an early source relocates deterministically.
fn allocSameShardGroup(
    alloc: Allocator,
    eng: *ShardedGraphEngine,
    per_shard: usize,
    pool: *std.ArrayList(u64),
    group: *std.ArrayList(u64),
) !void {
    var counts = [_]usize{0} ** shard_count.SHARD_COUNT;
    var target_shard: usize = 0;
    while (true) {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        try pool.append(alloc, n);
        const s = shard_count.shardOfNode(n);
        counts[s] += 1;
        if (counts[s] >= per_shard) {
            target_shard = s;
            break;
        }
    }
    for (pool.items) |n| {
        if (shard_count.shardOfNode(n) == target_shard) try group.append(alloc, n);
    }
}

/// Full enumeration parity BOTH directions over `nodes`: every `made` edge is
/// seen exactly once forward (out-chain walk) and once reverse (FanIn scatter),
/// with matching endpoints/public_id, and `edgeCount == made.len`. A dangling
/// head, a lost edge, or a resurrected edge fails here.
fn checkFullParity(
    alloc: Allocator,
    eng: *ShardedGraphEngine,
    nodes: []const u64,
    made: []const MadeEdge,
) !void {
    var by_id = std.AutoHashMap(u64, usize).init(alloc);
    defer by_id.deinit();
    for (made, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);

    const seen = try alloc.alloc(bool, made.len);
    defer alloc.free(seen);

    @memset(seen, false);
    var fwd: usize = 0;
    for (nodes) |n| {
        var it = try eng.expandOutIter(n, null);
        defer it.deinit();
        while (try it.next()) |edge| {
            const idx = by_id.get(edge.edge_id) orelse return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]); // no duplicate / resurrection
            seen[idx] = true;
            try testing.expectEqual(made[idx].from, n);
            try testing.expectEqual(made[idx].to, edge.neighbor);
            try testing.expectEqual(made[idx].public_id, edge.public_id);
            fwd += 1;
        }
    }
    try testing.expectEqual(made.len, fwd);
    for (seen) |b| try testing.expect(b); // no lost live edge

    @memset(seen, false);
    var rev: usize = 0;
    for (nodes) |t| {
        var it = try eng.expandInIter(t, null);
        defer it.deinit();
        while (try it.next()) |edge| {
            const idx = by_id.get(edge.edge_id) orelse return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            try testing.expectEqual(made[idx].to, t);
            try testing.expectEqual(made[idx].from, edge.neighbor);
            rev += 1;
        }
    }
    try testing.expectEqual(made.len, rev);
    for (seen) |b| try testing.expect(b);

    try testing.expectEqual(@as(u64, made.len), try eng.edgeCount());
}

// ============================================================================
// P4.1 RELOCATION window crash.
// ============================================================================

test "P4.1 relocation crash: a middle slab run that relocates recovers with the stored head on a live run; siblings intact; no lost edge" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xD1} ** 16;

    var pool: std.ArrayList(u64) = .empty;
    defer pool.deinit(alloc);
    var group: std.ArrayList(u64) = .empty;
    defer group.deinit(alloc);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);

    var relocations: usize = 0;
    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, slabConfig(8192));
        errdefer eng.deinit();

        // >=6 sources in ONE shard (their out-chains share a fill block) + extra
        // pool nodes for targets.
        try allocSameShardGroup(alloc, eng, 6, &pool, &group);
        for (0..24) |_| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try pool.append(alloc, n);
        }
        try eng.checkpoint(); // durable node baseline; edges live in the WAL tail

        const srcs = group.items[0..6];
        var first_head = try alloc.alloc(u64, srcs.len);
        defer alloc.free(first_head);

        // Pass 1: each source gets ONE out-edge -> distinct slots in the SHARED
        // shard fill block. After this, all but the last are MIDDLE runs.
        var e: usize = 0;
        for (srcs, 0..) |s, j| {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(s, pool.items[j], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = s, .to = pool.items[j], .public_id = pid });
            e += 1;
            const rec = (try eng.getNode(s)).?;
            try testing.expect(adj_store.isSlabHead(rec.out_head)); // packed
            first_head[j] = rec.out_head;
        }

        // Pass 2: grow each source -> a middle run must RELOCATE (head moves,
        // stays a slab head). The tail source may tail-grow in place.
        for (srcs, 0..) |s, j| {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(s, pool.items[j + 6], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = s, .to = pool.items[j + 6], .public_id = pid });
            e += 1;
            const rec = (try eng.getNode(s)).?;
            if (rec.out_head != first_head[j] and adj_store.isSlabHead(rec.out_head)) relocations += 1;
        }

        // The window must have fired (deterministically all-but-the-tail).
        try testing.expect(relocations >= 1);

        eng.deinit(); // SIMULATED CRASH — no checkpoint, no close.
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, slabConfig(8192));
    defer eng.close() catch {};
    try checkFullParity(alloc, eng, pool.items, made.items);
}

// ============================================================================
// P4.2 GRADUATION window crash.
// ============================================================================

test "P4.2 graduation crash: a chain that outgrows the slab migrates to a legacy chain; reopen recovers the COMPLETE legacy chain, never a half-migrated dangle" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xD2} ** 16;

    // Small page => a single chain graduates within a few hundred entries.
    const PAGE: u32 = 4096;

    var pool: std.ArrayList(u64) = .empty;
    defer pool.deinit(alloc);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);

    var hub: u64 = 0;
    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, slabConfig(PAGE));
        errdefer eng.deinit();

        // Hub (high fan-out, will graduate) + targets + a few low-fanout slab
        // chains that must survive the hub's graduation.
        hub = try eng.allocNode();
        try eng.putNode(hub, test_support.emptyNode(1));
        try pool.append(alloc, hub);
        for (0..320) |_| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try pool.append(alloc, n);
        }
        try eng.checkpoint();

        var e: usize = 0;
        // Low-fanout slab neighbours: pool[1] -> pool[2], pool[3] -> pool[4] ...
        var i: usize = 1;
        while (i + 1 < 40) : (i += 2) {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(pool.items[i], pool.items[i + 1], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = pool.items[i], .to = pool.items[i + 1], .public_id = pid });
            e += 1;
        }

        // Grow the hub until it GRADUATES (out_head stops being a slab head).
        var graduated = false;
        var k: usize = 40;
        while (k < pool.items.len) : (k += 1) {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(hub, pool.items[k], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = hub, .to = pool.items[k], .public_id = pid });
            e += 1;
            const rec = (try eng.getNode(hub)).?;
            if (!adj_store.isSlabHead(rec.out_head)) {
                graduated = true;
                // Keep growing a bit past graduation (legacy chain grows legacy).
                if (k > pool.items.len - 20) break;
            }
        }
        try testing.expect(graduated);
        const rec = (try eng.getNode(hub)).?;
        try testing.expect(!adj_store.isSlabHead(rec.out_head)); // final head is legacy

        eng.deinit(); // CRASH.
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, slabConfig(PAGE));
    defer eng.close() catch {};

    // The hub head must reference the COMPLETE legacy chain after replay.
    const rec = (try eng.getNode(hub)).?;
    try testing.expect(!adj_store.isSlabHead(rec.out_head));
    try checkFullParity(alloc, eng, pool.items, made.items);
}

// ============================================================================
// P4.3 TOMBSTONE window crash: slab remove + in-place prop update on a shared
// block.
// ============================================================================

test "P4.3 slab remove/update crash: a committed remove + in-place prop update on a shared block recover applied; head live; other slots intact" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xD3} ** 16;

    var pool: std.ArrayList(u64) = .empty;
    defer pool.deinit(alloc);
    var group: std.ArrayList(u64) = .empty;
    defer group.deinit(alloc);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);

    var removed_edge: u64 = 0;
    var removed_from: u64 = 0;
    var updated_edge: u64 = 0;
    var updated_from: u64 = 0;
    const NEW_PROP_VAL: i64 = 0x5151;

    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, slabConfig(8192));
        errdefer eng.deinit();

        try allocSameShardGroup(alloc, eng, 5, &pool, &group);
        for (0..30) |_| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try pool.append(alloc, n);
        }
        try eng.checkpoint();

        // Each of 5 same-shard sources gets 3 out-edges -> multi-entry runs
        // packed as distinct slots in the SHARED fill block.
        const srcs = group.items[0..5];
        var e: usize = 0;
        for (srcs) |s| {
            for (0..3) |t| {
                const pid = publicId(e);
                const target = pool.items[(e * 7 + t) % pool.items.len];
                const id = try eng.addEdgeColocatedWithPublicId(s, target, REL, pid);
                try made.append(alloc, .{ .edge_id = id, .from = s, .to = target, .public_id = pid });
                e += 1;
            }
        }

        // REMOVE one edge from source 0's run (swap-with-last, run shrinks, head
        // stays live). UPDATE a prop on an edge in source 2's run (in-place
        // rewrite). Both share the block with sources 1/3/4, which must survive.
        removed_from = srcs[0];
        removed_edge = made.items[0].edge_id; // first edge of source 0
        const removed_to = made.items[0].to;
        try eng.removeEdge(removed_from, removed_to, removed_edge);

        updated_from = srcs[2];
        updated_edge = made.items[6].edge_id; // first edge of source 2
        try eng.setEdgeProperty(updated_from, made.items[6].to, updated_edge, "w", .{ .int = NEW_PROP_VAL });

        eng.deinit(); // CRASH.
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, slabConfig(8192));
    defer eng.close() catch {};

    // Build the SURVIVING made set (drop the removed edge).
    var survivors: std.ArrayList(MadeEdge) = .empty;
    defer survivors.deinit(alloc);
    for (made.items) |m| {
        if (m.edge_id == removed_edge) continue;
        try survivors.append(alloc, m);
    }

    // The remove is applied (gone), every other slot intact, full parity.
    try checkFullParity(alloc, eng, pool.items, survivors.items);

    // The removed edge is truly absent from its source's out-chain.
    {
        var it = try eng.expandOutIter(removed_from, null);
        defer it.deinit();
        while (try it.next()) |edge| try testing.expect(edge.edge_id != removed_edge);
    }

    // The in-place prop update survived the crash.
    // `.int` owns no heap memory, so no free is needed for the returned value.
    const got = try eng.getEdgeProperty(updated_from, updated_edge, "w", alloc);
    try testing.expect(got != null);
    try testing.expectEqual(NEW_PROP_VAL, got.?.int);
}

// ============================================================================
// P4.4 DEFERRED-WAL tail (relocation + graduation) + counter harvest.
// ============================================================================

test "P4.4 deferred-WAL tail crash: a tail spanning relocation AND graduation replays with live heads; the harvest heals ids living only in replayed slab runs" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xD4} ** 16;
    const PAGE: u32 = 4096;

    var pool: std.ArrayList(u64) = .empty;
    defer pool.deinit(alloc);
    var group: std.ArrayList(u64) = .empty;
    defer group.deinit(alloc);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);

    var hub: u64 = 0;
    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, deferredSlabConfig(PAGE));
        errdefer eng.deinit();

        try allocSameShardGroup(alloc, eng, 6, &pool, &group);
        hub = try eng.allocNode();
        try eng.putNode(hub, test_support.emptyNode(1));
        try pool.append(alloc, hub);
        for (0..320) |_| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try pool.append(alloc, n);
        }
        try eng.checkpoint(); // baseline; ALL edges below live in the deferred WAL tail.

        var e: usize = 0;

        // (a) Relocation shape: 6 same-shard sources, one edge each then a grow.
        const srcs = group.items[0..6];
        for (srcs, 0..) |s, j| {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(s, pool.items[j], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = s, .to = pool.items[j], .public_id = pid });
            e += 1;
        }
        var relocations: usize = 0;
        for (srcs, 0..) |s, j| {
            const before = (try eng.getNode(s)).?.out_head;
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(s, pool.items[j + 6], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = s, .to = pool.items[j + 6], .public_id = pid });
            e += 1;
            const after = (try eng.getNode(s)).?.out_head;
            if (after != before and adj_store.isSlabHead(after)) relocations += 1;
        }
        try testing.expect(relocations >= 1);

        // (b) Graduation shape: grow the hub until it leaves the slab.
        var graduated = false;
        var k: usize = 20;
        while (k < pool.items.len) : (k += 1) {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(hub, pool.items[k], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = hub, .to = pool.items[k], .public_id = pid });
            e += 1;
            if (!adj_store.isSlabHead((try eng.getNode(hub)).?.out_head)) {
                graduated = true;
                break;
            }
        }
        try testing.expect(graduated);

        eng.deinit(); // CRASH (deferred: committed WAL bytes are in the OS cache).
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, deferredSlabConfig(PAGE));
    defer eng.close() catch {};

    // (1) Live heads: full parity after replaying the deferred tail.
    try checkFullParity(alloc, eng, pool.items, made.items);

    // (2) Harvest heal: ids that live ONLY in replayed slab runs (relocation +
    // graduation) lifted the manifest counters — aggressive post-reopen creates
    // never re-issue a crash-window id.
    var made_ids = std.AutoHashMap(u64, void).init(alloc);
    defer made_ids.deinit();
    for (made.items) |m| try made_ids.put(m.edge_id, {});
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        const id = try eng.addEdgeColocatedWithPublicId(group.items[0], pool.items[k % pool.items.len], REL, publicId(500000 + k));
        if (made_ids.contains(id)) {
            std.debug.print("post-crash addEdge RE-ISSUED slab-run edge id {d} — deferred harvest missed a relocated/graduated run\n", .{id});
            return error.EdgeSlotReissued;
        }
    }
}

// ============================================================================
// P4.5 MIXED legacy + slab store crash (read-both).
// ============================================================================

test "P4.5 mixed store crash: legacy chains (written slab-OFF) coexist with slab chains (written slab-ON); crash + reopen recovers both (read-both parity)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xD5} ** 16;

    var pool: std.ArrayList(u64) = .empty;
    defer pool.deinit(alloc);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);

    const N_LEGACY_SRC: usize = 60;
    var e: usize = 0;

    // Session 1: slab OFF -> legacy block chains. Durable via close.
    {
        var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, legacyConfig(8192));
        errdefer eng.deinit();
        for (0..200) |_| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try pool.append(alloc, n);
        }
        // Legacy low-fanout chains.
        for (0..N_LEGACY_SRC) |i| {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(pool.items[i], pool.items[i + 1], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = pool.items[i], .to = pool.items[i + 1], .public_id = pid });
            e += 1;
        }
        // Confirm these are LEGACY (not slab) heads.
        var any_legacy = false;
        for (0..N_LEGACY_SRC) |i| {
            const rec = (try eng.getNode(pool.items[i])).?;
            if (rec.out_head != 0 and !adj_store.isSlabHead(rec.out_head)) any_legacy = true;
        }
        try testing.expect(any_legacy);
        try eng.close(); // durable baseline.
    }

    // Session 2: reopen slab ON. New sources pack as SLAB; grow a legacy chain
    // (stays legacy — existing block chains are never retro-packed). Crash.
    {
        var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, slabConfig(8192));
        errdefer eng.deinit();

        // Grow some legacy chains (still legacy).
        for (0..N_LEGACY_SRC) |i| {
            if (i % 5 != 0) continue;
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(pool.items[i], pool.items[i + 2], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = pool.items[i], .to = pool.items[i + 2], .public_id = pid });
            e += 1;
            const rec = (try eng.getNode(pool.items[i])).?;
            try testing.expect(!adj_store.isSlabHead(rec.out_head)); // grew as legacy
        }

        // New slab chains from previously-unused sources.
        var any_slab = false;
        for (100..160) |i| {
            const pid = publicId(e);
            const id = try eng.addEdgeColocatedWithPublicId(pool.items[i], pool.items[i + 1], REL, pid);
            try made.append(alloc, .{ .edge_id = id, .from = pool.items[i], .to = pool.items[i + 1], .public_id = pid });
            e += 1;
            const rec = (try eng.getNode(pool.items[i])).?;
            if (adj_store.isSlabHead(rec.out_head)) any_slab = true;
        }
        try testing.expect(any_slab); // store now holds BOTH formats.

        eng.deinit(); // CRASH — session-2 edges live only in the WAL tail.
    }

    var eng = try ShardedGraphEngine.open(alloc, td.path, uuid, slabConfig(8192));
    defer eng.close() catch {};
    try checkFullParity(alloc, eng, pool.items, made.items);
}

test {
    std.testing.refAllDecls(@This());
}
