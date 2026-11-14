// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6529: cost of the source node-page image on a head-moving edge
// property set.
//
// Each round creates a store with one source and EDGES co-located edges,
// takes a full checkpoint, then gives every edge its first property (the
// property chain head moves from 0, so both adjacency copies are rewritten)
// in deferred sync, one transaction per edge, the way geode's adapter does
// it. Three variants, each on a fresh store:
//
//   lib           GraphEngine.setEdgeProperty (images the adjacency pages)
//   adj-only      consumer path, images the adjacency pages only
//   +node-image   consumer path that also images the source's node page,
//                 as setEdgeProperty did before SONNY-6529 and geode's
//                 publishEdgePropHead still does
//
// Reports median ns per set and WAL bytes per set over ROUNDS rounds.
//
// Usage: zig build bench-edge-prop-set [-- <data dir on a real disk>]

const std = @import("std");
const gs = @import("graph_storage");

const EDGES: usize = 2000;
const ROUNDS: usize = 7;
const REL: u32 = 3;

const Variant = enum { lib, adj_only, node_image };

fn nanoNow() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn emptyNode() gs.node.NodeRec {
    return .{ .out_head = 0, .in_head = 0, .prop_head = 0, .label_head = 0, .label_count = 0, .flags = 0, ._pad = .{ 0, 0, 0, 0 }, .txn_stamp = 1 };
}

fn consumerSet(eng: *gs.GraphEngine, from: u64, to: u64, edge_id: u64, value: i64, node_image: bool) !void {
    const entry = (try eng.getEdge(edge_id)) orelse return error.EdgeNotFound;
    const from_rec = (try eng.getNode(from)) orelse return error.NodeNotFound;
    const txn = try eng.beginTxn();
    errdefer eng.abortTxn(txn) catch {};
    const new_head = try eng.putPropertyTxn(entry.prop_head, "w", .{ .int = value }, txn);
    if (new_head != entry.prop_head) {
        if (try eng.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head)) |page| {
            try eng.logPagePublic(txn, .adj_out, page);
            if (node_image) try eng.logPagePublic(txn, .nodes, from / eng.node_store.nodes_per_page);
        }
        const in_head = try eng.in_head_dir.getHead(to);
        if (try eng.adj_in_remote.updateEdgePropHead(in_head, edge_id, new_head)) |page|
            try eng.logPagePublic(txn, .in_idx, page);
        try eng.edge_index.updatePropHead(edge_id, new_head);
        eng.edge_index_dirty = true;
    }
    try eng.commitTxn(txn);
}

const Sample = struct { ns_per_set: u64, wal_bytes_per_set: u64 };

fn runOnce(allocator: std.mem.Allocator, root: []const u8, round: usize, v: Variant) !Sample {
    const io = std.Io.Threaded.global_single_threaded.io();
    var path_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "{s}/edge_prop_set_{d}_{d}_{s}", .{ root, nanoNow(), round, @tagName(v) });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var cfg = gs.GraphConfig{};
    cfg.sync_mode = .deferred;
    const eng = try gs.GraphEngine.create(allocator, dir, [_]u8{0x29} ** 16, cfg);
    defer eng.close() catch {};

    const source = try eng.allocNode();
    try eng.putNode(source, emptyNode());
    const sink = try eng.allocNode();
    try eng.putNode(sink, emptyNode());
    const ids = try allocator.alloc(u64, EDGES);
    defer allocator.free(ids);
    for (ids, 0..) |*id, i| id.* = try eng.addEdgeColocatedWithPublicId(source, sink, REL, 0x6529_0000 + i + 1);
    try eng.checkpoint();

    const wal_before = eng.wal.bytesSinceCompact();
    const start = nanoNow();
    for (ids, 0..) |id, i| {
        const value: i64 = @intCast(i);
        switch (v) {
            .lib => try eng.setEdgeProperty(source, sink, id, "w", .{ .int = value }),
            .adj_only => try consumerSet(eng, source, sink, id, value, false),
            .node_image => try consumerSet(eng, source, sink, id, value, true),
        }
    }
    const elapsed: u64 = @intCast(nanoNow() - start);
    const wal_bytes = eng.wal.bytesSinceCompact() - wal_before;
    return .{ .ns_per_set = elapsed / EDGES, .wal_bytes_per_set = wal_bytes / EDGES };
}

fn median(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    var args = init.args.iterate();
    _ = args.next();
    const root = args.next() orelse "/tmp";

    std.debug.print("edge-prop-set: {d} edges, first property each, deferred sync, {d} rounds, data under {s}\n", .{ EDGES, ROUNDS, root });
    inline for (.{ Variant.lib, Variant.adj_only, Variant.node_image }) |v| {
        var ns: [ROUNDS]u64 = undefined;
        var wb: [ROUNDS]u64 = undefined;
        for (0..ROUNDS) |r| {
            const s = try runOnce(allocator, root, r, v);
            ns[r] = s.ns_per_set;
            wb[r] = s.wal_bytes_per_set;
        }
        std.debug.print("  {s:<11} median {d:>7} ns/set  {d:>6} WAL bytes/set\n", .{ @tagName(v), median(&ns), median(&wb) });
    }
}
