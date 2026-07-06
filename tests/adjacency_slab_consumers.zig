// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP adjacency slab packing — PHASE 3 consumer sweep.
//
// P2 wired the slab WRITE path behind `adjacency_slab_packing` (default OFF)
// and proved enumeration + FanIn + one crash/harvest. P3 closes the remaining
// consumers that READ adjacency, each with a test that a slab-packed store is
// indistinguishable from a legacy one:
//
//   1. BACKUP / RESTORE — `backup.zig` copies the store files BYTE-FOR-BYTE
//      (`adj_out.store`, …); it never walks adjacency, so slab blocks round-
//      trip verbatim. A real `Backup.createBackup` -> `restoreBackup` of a
//      slab-packed graph must re-enumerate identically. (There is NO adjacency
//      iteration anywhere in the backup/export/copy path — verified by grep —
//      so "decode-or-image the head" cannot be mis-handled: the format inside
//      the file is irrelevant to a byte copy.)
//
//   2. DERIVED EDGE-INDEX REBUILD — the deferred edge-existence index is
//      rebuilt by SCANNING `adj_out` (the F1-guarded slab-aware `expand`). A
//      rebuild from a slab store must probe every edge as existing and agree
//      record-for-record with the authoritative out-enumeration.
//
//   3. FanIn-SOURCE REBUILD — `migrateColocateInEdges` rebuilds `adj_in_remote`
//      (the `FanInEdgeIterator` scatter source) from the slab `adj_out`. The
//      reverse enumeration after a full rebuild must equal the pre-rebuild set.
//
//   4. INTEGRITY / MAINTENANCE — `checkIntegrity` walks `adj_out.expand`
//      (F1-guarded) and compares the slab-walked edge count to the manifest;
//      the maintenance stats count PAGES only (no head decode). Both stay
//      consistent over a slab store.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const test_support = gs.test_support;
const shard_count = gs.shard_count;
const adj_store = gs.adj_store;
const graph_dir = gs.graph_dir;
const backup = gs.backup;

const PAGE_SIZE: u32 = 8192;
const REL: u32 = 11;

fn slabConfig() gs.GraphConfig {
    return .{
        .page_size = PAGE_SIZE,
        .buffer_pool_pages = 256,
        .data_dir = "data",
        .adjacency_slab_packing = true,
    };
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

/// Build a low-fanout slab graph on `eng` (spine i->i+1 + every-3rd skip
/// i->i+2). Returns the made edges; caller owns `made` and `nodes`.
fn buildLowFanout(
    alloc: Allocator,
    eng: anytype,
    nodes: []u64,
    made: *std.ArrayList(MadeEdge),
) !void {
    for (nodes) |*slot| {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        slot.* = n;
    }
    var e: usize = 0;
    var i: usize = 0;
    while (i + 1 < nodes.len) : (i += 1) {
        const pid = publicId(e);
        const id = try eng.addEdgeColocatedWithPublicId(nodes[i], nodes[i + 1], REL, pid);
        try made.append(alloc, .{ .edge_id = id, .from = nodes[i], .to = nodes[i + 1], .public_id = pid });
        e += 1;
    }
    i = 0;
    while (i + 2 < nodes.len) : (i += 1) {
        if (i % 3 != 0) continue;
        const pid = publicId(e);
        const id = try eng.addEdgeColocatedWithPublicId(nodes[i], nodes[i + 2], REL, pid);
        try made.append(alloc, .{ .edge_id = id, .from = nodes[i], .to = nodes[i + 2], .public_id = pid });
        e += 1;
    }
}

/// True when at least one node's out-chain is a tagged slab head — proof the
/// graph really contains slab blocks (so the consumer test is not vacuous).
fn anySlabOut(eng: anytype, nodes: []const u64) !bool {
    for (nodes) |n| {
        const rec = (try eng.getNode(n)).?;
        if (rec.out_head != 0 and adj_store.isSlabHead(rec.out_head)) return true;
    }
    return false;
}

// ============================================================================
// (1) BACKUP / RESTORE round-trip of a slab-packed graph.
// ============================================================================

test "P3 backup/restore: a slab-packed graph round-trips through Backup.createBackup + restoreBackup (byte copy, no adjacency walk) — enumeration parity" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const uuid = [_]u8{0xC1} ** 16;

    const src_root = try std.fmt.allocPrint(alloc, "{s}/src", .{td.path});
    defer alloc.free(src_root);
    const rst_root = try std.fmt.allocPrint(alloc, "{s}/rst", .{td.path});
    defer alloc.free(rst_root);
    try std.Io.Dir.cwd().createDirPath(io, src_root);
    try std.Io.Dir.cwd().createDirPath(io, rst_root);

    const NN: usize = 400;
    const nodes = try alloc.alloc(u64, NN);
    defer alloc.free(nodes);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);

    // Capture the graph dir's path RELATIVE to src_root (e.g. "/graphs/<hex>")
    // so the restore target mirrors the exact layout GraphEngine.open expects.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = 0;

    {
        var eng = try GraphEngine.create(alloc, src_root, uuid, slabConfig());
        errdefer eng.close() catch {};
        const gp = eng.graph_dir.path;
        @memcpy(path_buf[0..gp.len], gp);
        path_len = gp.len;

        try buildLowFanout(alloc, eng, nodes, &made);
        try testing.expect(try anySlabOut(eng, nodes)); // graph really has slab blocks

        try eng.checkpoint();
        eng.close() catch {};
    }

    // Backup the source graph dir (byte copy of adj_out.store etc.).
    const backup_path = try std.fmt.allocPrint(alloc, "{s}/graph.geob", .{td.path});
    defer alloc.free(backup_path);
    {
        var gd = try graph_dir.GraphDir.open(alloc, src_root, uuid);
        defer gd.deinit();
        var bk = backup.Backup.init(alloc);
        const r = try bk.createBackup(&gd, backup_path);
        try testing.expect(r.files_backed_up > 0);
    }

    // Restore into rst_root/<hex> and reopen from rst_root.
    const rel_suffix = path_buf[src_root.len..path_len]; // e.g. "/graphs/<hex>"
    const target = try std.fmt.allocPrint(alloc, "{s}{s}", .{ rst_root, rel_suffix });
    defer alloc.free(target);
    try std.Io.Dir.cwd().createDirPath(io, target); // restore populates an existing dir
    {
        var bk = backup.Backup.init(alloc);
        bk.setExpectedGraphUuid(uuid);
        bk.enableLegacyV1Restore(); // no encryption key => version-1 archive
        const rr = try bk.restoreBackupResult(backup_path, target);
        try testing.expect(rr.files_restored > 0);
    }

    var eng = try GraphEngine.open(alloc, rst_root, uuid, slabConfig());
    defer eng.close() catch {};

    var by_id = std.AutoHashMap(u64, usize).init(alloc);
    defer by_id.deinit();
    for (made.items, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);
    const seen = try alloc.alloc(bool, made.items.len);
    defer alloc.free(seen);
    @memset(seen, false);

    var fwd: usize = 0;
    for (nodes) |n| {
        var it = try eng.expandOutIter(n, null);
        defer it.deinit();
        while (try it.next()) |edge| {
            const idx = by_id.get(edge.edge_id) orelse return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]); // no duplicates
            seen[idx] = true;
            try testing.expectEqual(made.items[idx].from, n);
            try testing.expectEqual(made.items[idx].to, edge.neighbor);
            try testing.expectEqual(made.items[idx].public_id, edge.public_id);
            fwd += 1;
        }
    }
    try testing.expectEqual(made.items.len, fwd);
    for (seen) |b| try testing.expect(b);
    try testing.expectEqual(@as(u64, made.items.len), try eng.edgeCount());
}

// ============================================================================
// (2)+(3) DERIVED edge-index rebuild + FanIn-source rebuild from a slab store.
// ============================================================================

/// Drain the reverse (FanIn) enumeration into `seen` (indexed via `by_id`),
/// asserting the exact `made` set with no duplicates and matching sources.
fn assertReverseParity(
    eng: *ShardedGraphEngine,
    nodes: []const u64,
    made: []const MadeEdge,
    by_id: *const std.AutoHashMap(u64, usize),
    seen: []bool,
) !void {
    @memset(seen, false);
    var rev: usize = 0;
    for (nodes) |t| {
        var it = try eng.expandInIter(t, null);
        defer it.deinit();
        while (try it.next()) |edge| {
            const idx = by_id.get(edge.edge_id) orelse return error.UnknownEdgeEnumerated;
            if (seen[idx]) {
                std.debug.print("REVERSE DUPLICATE: edge_id {d} (made {d}->{d}) re-yielded at target {d} (neighbor {d})\n", .{ edge.edge_id, made[idx].from, made[idx].to, t, edge.neighbor });
                return error.ReverseDuplicate;
            }
            seen[idx] = true;
            try testing.expectEqual(made[idx].to, t);
            try testing.expectEqual(made[idx].from, edge.neighbor);
            rev += 1;
        }
    }
    try testing.expectEqual(made.len, rev);
    for (seen) |b| try testing.expect(b);
}

test "P3 derived rebuild: edge-existence index rebuilt from a slab adj_out probes every edge; FanIn source rebuild reproduces the identical reverse set" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC2} ** 16;

    var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, slabConfig());
    defer eng.close() catch {};

    const NN: usize = 600;
    const nodes = try alloc.alloc(u64, NN);
    defer alloc.free(nodes);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);
    try buildLowFanout(alloc, eng, nodes, &made);
    try testing.expect(try anySlabOut(eng, nodes));
    try eng.checkpoint();

    var by_id = std.AutoHashMap(u64, usize).init(alloc);
    defer by_id.deinit();
    for (made.items, 0..) |m, idx| try by_id.putNoClobber(m.edge_id, idx);
    const seen = try alloc.alloc(bool, made.items.len);
    defer alloc.free(seen);

    // Reverse (FanIn) parity BEFORE any rebuild — the reference set.
    try assertReverseParity(eng, nodes, made.items, &by_id, seen);

    // (2) EXISTENCE INDEX: the deferred edge-existence index (derived by
    // scanning the slab adj_out via the F1-guarded expand) probes every edge as
    // existing and holds exactly one record per edge — i.e. it decoded every
    // slab head correctly.
    var buf: [64]gs.EdgeId = undefined;
    for (made.items) |m| {
        const s = shard_count.shardOfNode(m.from);
        const cands = try eng.shards[s].probeEdge(m.from, REL, m.to, &buf);
        var found = false;
        for (cands) |c| {
            if (c == m.edge_id) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("edge_id {d} ({d}->{d}) missing from rebuilt existence index\n", .{ m.edge_id, m.from, m.to });
            return error.EdgeMissingFromRebuiltIndex;
        }
    }
    // The rebuilt existence index holds exactly one record per edge.
    var rec_total: usize = 0;
    for (eng.shards) |sh| rec_total += sh.edgeExistRecordCount();
    try testing.expectEqual(made.items.len, rec_total);

    // (3) FanIn-SOURCE REBUILD: rebuild adj_in_remote wholesale from the slab
    // adj_out. The reverse enumeration after the rebuild must equal the set
    // captured before it — a full rebuild from a slab store is identical.
    for (eng.shards) |sh| try sh.migrateColocateInEdges();
    try assertReverseParity(eng, nodes, made.items, &by_id, seen);

    // Forward parity + count unchanged by either rebuild.
    @memset(seen, false);
    var fwd: usize = 0;
    for (nodes) |n| {
        var it = try eng.expandOutIter(n, null);
        defer it.deinit();
        while (try it.next()) |edge| {
            const idx = by_id.get(edge.edge_id) orelse return error.UnknownEdgeEnumerated;
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            fwd += 1;
        }
    }
    try testing.expectEqual(made.items.len, fwd);
    try testing.expectEqual(@as(u64, made.items.len), try eng.edgeCount());
}

// ============================================================================
// (4) INTEGRITY / MAINTENANCE scan over a slab store.
// ============================================================================

test "P3 integrity: checkIntegrity walks the slab adj_out (F1-guarded) and the slab-walked edge count matches the manifest; storage stats are consistent" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xC3} ** 16;

    var eng = try ShardedGraphEngine.create(alloc, td.path, uuid, slabConfig());
    defer eng.close() catch {};

    const NN: usize = 500;
    const nodes = try alloc.alloc(u64, NN);
    defer alloc.free(nodes);
    var made: std.ArrayList(MadeEdge) = .empty;
    defer made.deinit(alloc);
    try buildLowFanout(alloc, eng, nodes, &made);
    try testing.expect(try anySlabOut(eng, nodes));
    try eng.checkpoint();

    // checkIntegrity re-walks every node's slab-packed out-chain via the
    // F1-guarded expand and compares to the manifest counters. total_errors
    // must be 0 and both consistency flags true across every shard — a slab
    // head that failed to decode (or a dangling head) would surface here as a
    // propagated iteration error or an edge-count mismatch.
    var integ_nodes: u64 = 0;
    var integ_edges_ok = true;
    for (eng.shards) |sh| {
        const rep = try sh.checkIntegrity();
        try testing.expectEqual(@as(u64, 0), rep.total_errors);
        try testing.expect(rep.node_count_consistent);
        try testing.expect(rep.edge_count_consistent);
        if (!rep.edge_count_consistent) integ_edges_ok = false;
        integ_nodes += @intFromBool(rep.node_count_consistent);
    }
    try testing.expect(integ_edges_ok);

    // Cross-check the whole-graph counts (the maintenance/stats path reads
    // manifest counters + page free-lists; it never decodes a head, so it is
    // format-agnostic — assert it agrees with the known graph).
    try testing.expectEqual(@as(u64, NN), try eng.nodeCount());
    try testing.expectEqual(@as(u64, made.items.len), try eng.edgeCount());
}

test {
    std.testing.refAllDecls(@This());
}
