// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Edge co-location (Phase B) — MIGRATION of a pre-co-location (legacy) graph.
//
// A graph created by a PRE-co-location binary has its cross-shard in-edges in
// the OLD location (dst shard's `adj_in` / dst.in_head) and an EMPTY
// `adj_in_remote`, with NO `layout_version` stamp in the shard manifest. The
// new scatter `expandIn` reads ONLY `adj_in_remote`, so without migration those
// in-edges are silently lost on reverse traversal. `adj_out` (out-adjacency, on
// shard(src)) is layout-INDEPENDENT and complete in BOTH layouts — it is the
// authoritative rebuild source.
//
// The migration rule: if the shard-manifest `layout_version` is < 1, REBUILD
// `adj_in_remote` from `adj_out` on open (per shard, keyed by `to`), then stamp
// `layout_version = 1`. It must be IDEMPOTENT (a stamped v1 graph re-opens with
// NO re-migration) and CRASH-SAFE (a crash mid-migration re-runs cleanly with
// no duplicate in-edges).
//
// These tests simulate a legacy on-disk graph by creating a graph with the
// current binary, then (a) emptying `adj_in_remote` + `in_dir` on disk and
// (b) downgrading the shard manifest to a pre-co-location (no `layout_version`)
// form, leaving `adj_out` intact. Reopen must rebuild and serve the exact,
// complete reverse-traversal set.

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const shard_count = graph_storage.shard_count;
const shard_manifest = graph_storage.shard_manifest;

const REL_A: u32 = 1;
const REL_B: u32 = 2;

fn collectIn(eng: *ShardedGraphEngine, dst: u64, rel: ?u32, allocator: std.mem.Allocator) ![]graph_storage.edge.EdgeEntry {
    return eng.expandIn(dst, rel, allocator);
}

fn hasInEdge(eng: *ShardedGraphEngine, dst: u64, edge_id: u64, from: u64) !bool {
    var it = try eng.expandInIter(dst, null);
    defer it.deinit();
    while (try it.next()) |e| {
        if (e.edge_id == edge_id) {
            try testing.expectEqual(from, e.neighbor);
            return true;
        }
    }
    return false;
}

/// `<data_dir>/<graph_uuid_hex>` — the per-graph root that ShardedGraphEngine
/// derives internally. Caller owns the returned slice.
fn graphRoot(allocator: std.mem.Allocator, data_dir: []const u8, uuid: [16]u8) ![]u8 {
    const hex = graph_storage.sharded_engine.uuidHex(uuid);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, hex[0..] });
}

fn allocOnePerShard(eng: *ShardedGraphEngine, out: []u64) !void {
    for (out, 0..) |*slot, s| {
        const n = try eng.shards[s].allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        try testing.expectEqual(s, shard_count.shardOfNode(n));
        slot.* = n;
    }
}

const EdgeRec = struct { id: u64, from: u64, to: u64 };

/// Build a co-located graph with cross-endpoint edges into a few hot dsts whose
/// sources are spread across all shards. Returns the created edges via `edges`.
fn buildColocatedGraph(eng: *ShardedGraphEngine, nodes: []u64, edges: []EdgeRec) !void {
    try allocOnePerShard(eng, nodes);
    const N = shard_count.SHARD_COUNT;
    var e: usize = 0;
    const dsts = [_]usize{ 0, 5, 10 };
    for (dsts) |d| {
        const dst = nodes[d];
        for (0..N) |s| {
            if (s == d) continue; // keep cross-shard
            const id = try eng.addEdge(nodes[s], dst, REL_A);
            edges[e] = .{ .id = id, .from = nodes[s], .to = dst };
            e += 1;
        }
    }
    while (e < edges.len) : (e += 1) {
        const dst = nodes[0];
        const id = try eng.addEdge(nodes[(e % (N - 1)) + 1], dst, REL_B);
        edges[e] = .{ .id = id, .from = nodes[(e % (N - 1)) + 1], .to = dst };
    }
}

/// Write a PRE-co-location shard manifest JSON (NO `layout_version` field) so
/// the reopen path treats the graph as legacy (version 0). Mirrors the exact
/// JSON shape a pre-co-location binary wrote.
fn writeLegacyShardManifest(allocator: std.mem.Allocator, graph_root: []const u8, sm: shard_manifest.ShardManifest) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "{{\"version\":{d},\"shard_count\":{d},\"algorithm_hash\":{d},\"per_shard_uuids\":[", .{
        sm.version, sm.shard_count, sm.algorithm_hash,
    });
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (sm.per_shard_uuids, 0..) |uuid, i| {
        if (i != 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        for (uuid) |b| {
            var hex_buf: [2]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{b});
            try buf.appendSlice(allocator, &hex_buf);
        }
        try buf.appendSlice(allocator, "\"");
    }
    try buf.appendSlice(allocator, "]}");

    const path = try std.fmt.allocPrint(allocator, "{s}/shard_manifest.json", .{graph_root});
    defer allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
    try file.sync(io);
}

/// Simulate a legacy on-disk graph in `graph_root`: empty every shard's
/// `adj_in_remote.store` + `adj_in_dir.store` (truncate to 0) and delete the
/// `free.store` (so free space is rebuilt from the now-empty files → empty
/// adj_in_remote), then downgrade the shard manifest to the no-`layout_version`
/// form. `adj_out.store` is left intact (the authoritative rebuild source).
fn simulateLegacyLayout(allocator: std.mem.Allocator, graph_root: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read the existing (current-binary) shard manifest, then rewrite it WITHOUT
    // a layout_version field so reopen treats it as legacy (version 0).
    const sm = try shard_manifest.readFromDir(allocator, graph_root);
    try writeLegacyShardManifest(allocator, graph_root, sm);

    // Each shard lives in <graph_root>/graphs/<shard_uuid_hex>/. Empty its
    // in-index bodies + directory (truncate to 0) and TRUNCATE its free.store
    // to 0 (recovery opens free.store with `.open_existing`, so it must remain
    // present; a 0-byte free.store forces `rebuildFreeSpaceFromDisk`, which then
    // sees the emptied in-index files → an empty adj_in_remote). adj_out is left
    // intact — it is the authoritative rebuild source.
    const names = [_][]const u8{ "adj_in_remote.store", "adj_in_dir.store", "free.store" };
    for (sm.per_shard_uuids) |uuid| {
        const hex = graph_storage.sharded_engine.uuidHex(uuid);
        const shard_dir = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}", .{ graph_root, hex[0..] });
        defer allocator.free(shard_dir);

        for (names) |name| {
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shard_dir, name });
            defer allocator.free(p);
            // Truncate to 0 bytes (recreate empty). A missing file is fine.
            const f = std.Io.Dir.cwd().createFile(io, p, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) }) catch null;
            if (f) |ff| ff.close(io);
        }
    }
}

test "migration: legacy graph (empty adj_in_remote, version<1) rebuilds reverse-traversal on open" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB1} ** 16;

    const N = shard_count.SHARD_COUNT;
    var nodes: [N]u64 = undefined;
    var edges: [N * 3]EdgeRec = undefined;

    // 1. Create a co-located graph, then CLEAN-close so adj_out is durable.
    {
        var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
        try buildColocatedGraph(eng, &nodes, &edges);
        // Sanity: co-located reverse traversal works before we downgrade.
        for (edges) |er| try testing.expect(try hasInEdge(eng, er.to, er.id, er.from));
        try eng.close();
    }

    // 2. Simulate a pre-co-location on-disk graph: empty adj_in_remote + in_dir,
    //    downgrade the manifest (no layout_version). adj_out stays intact.
    const root1 = try graphRoot(testing.allocator, td.path, uuid);
    defer testing.allocator.free(root1);
    try simulateLegacyLayout(testing.allocator, root1);

    // 3. Reopen with the co-location build → migration must rebuild
    //    adj_in_remote from adj_out and serve the EXACT reverse-traversal set.
    var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    // edge_count is derived from adj_out (untouched) so it survives.
    try testing.expectEqual(@as(u64, edges.len), try eng.edgeCount());

    // Every edge resolvable via the REBUILT reverse traversal, with no dupes,
    // and forward traversal still correct.
    var seen_in = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen_in.deinit();
    for (edges) |er| {
        try testing.expect(try hasInEdge(eng, er.to, er.id, er.from));
        const gop = try seen_in.getOrPut(er.id);
        try testing.expect(!gop.found_existing);
    }

    // Exact in-edge set for each hot dst (count + membership), incl. cross-shard.
    for ([_]usize{ 0, 5, 10 }) |d| {
        const dst = nodes[d];
        var expected: usize = 0;
        for (edges) |er| {
            if (er.to == dst) expected += 1;
        }
        const in_edges = try collectIn(eng, dst, null, testing.allocator);
        defer testing.allocator.free(in_edges);
        try testing.expectEqual(expected, in_edges.len);
    }

    // A reverse hop from dst nodes[0] reaches exactly its sources (rel filter
    // honored after rebuild).
    const in0 = try collectIn(eng, nodes[0], REL_A, testing.allocator);
    defer testing.allocator.free(in0);
    for (in0) |e| try testing.expectEqual(REL_A, e.rel_type);
}

test "migration: idempotent — reopen of a stamped (v1) graph does NOT re-migrate" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB2} ** 16;

    const N = shard_count.SHARD_COUNT;
    var nodes: [N]u64 = undefined;
    var edges: [N * 3]EdgeRec = undefined;

    {
        var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
        try buildColocatedGraph(eng, &nodes, &edges);
        try eng.close();
    }
    // First reopen: a fresh (created-as-v1) graph must NOT double-insert.
    {
        var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
        defer eng.close() catch {};
        for ([_]usize{ 0, 5, 10 }) |d| {
            var expected: usize = 0;
            for (edges) |er| if (er.to == nodes[d]) {
                expected += 1;
            };
            const in_edges = try collectIn(eng, nodes[d], null, testing.allocator);
            defer testing.allocator.free(in_edges);
            try testing.expectEqual(expected, in_edges.len);
        }
    }
    // Second reopen: still exact (no accumulation across opens).
    {
        var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
        defer eng.close() catch {};
        for ([_]usize{ 0, 5, 10 }) |d| {
            var expected: usize = 0;
            for (edges) |er| if (er.to == nodes[d]) {
                expected += 1;
            };
            const in_edges = try collectIn(eng, nodes[d], null, testing.allocator);
            defer testing.allocator.free(in_edges);
            try testing.expectEqual(expected, in_edges.len);
        }
    }
}

test "migration: a freshly co-located graph opens with NO migration and is correct" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB3} ** 16;

    const N = shard_count.SHARD_COUNT;
    var nodes: [N]u64 = undefined;
    var edges: [N * 3]EdgeRec = undefined;

    {
        var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
        try buildColocatedGraph(eng, &nodes, &edges);
        try eng.close();
    }

    // The created manifest must already be stamped layout_version = 1.
    const root3 = try graphRoot(testing.allocator, td.path, uuid);
    defer testing.allocator.free(root3);
    const sm = try shard_manifest.readFromDir(testing.allocator, root3);
    try testing.expectEqual(@as(u32, 1), sm.layout_version);

    var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};
    for (edges) |er| {
        try testing.expect(try hasInEdge(eng, er.to, er.id, er.from));
    }
}

test "migration: crash mid-migration (drop + reopen) completes correctly, no dupes" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xB4} ** 16;

    const N = shard_count.SHARD_COUNT;
    var nodes: [N]u64 = undefined;
    var edges: [N * 3]EdgeRec = undefined;

    // Create + clean close a co-located graph.
    {
        var eng = try ShardedGraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
        try buildColocatedGraph(eng, &nodes, &edges);
        try eng.close();
    }
    // Downgrade to legacy.
    const root4 = try graphRoot(testing.allocator, td.path, uuid);
    defer testing.allocator.free(root4);
    try simulateLegacyLayout(testing.allocator, root4);

    // First reopen runs the migration but we simulate a CRASH by dropping the
    // engine (deinit, no clean close) right after open returns — the migration
    // has already written + checkpointed its pages, but to model a crash that
    // landed mid-stamp we re-downgrade ONLY the manifest version (leaving the
    // now-rebuilt adj_in_remote partially/fully on disk) and reopen again.
    {
        var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
        eng.deinit();
    }
    // Re-downgrade JUST the version stamp to force the migration to re-run over
    // an already-(re)built adj_in_remote — the idempotency/crash stress: a
    // second migration over non-empty in-index must NOT double-insert.
    {
        const sm = try shard_manifest.readFromDir(testing.allocator, root4);
        try writeLegacyShardManifest(testing.allocator, root4, sm);
    }

    var eng = try ShardedGraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    try testing.expectEqual(@as(u64, edges.len), try eng.edgeCount());
    var seen_in = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen_in.deinit();
    for (edges) |er| {
        try testing.expect(try hasInEdge(eng, er.to, er.id, er.from));
        const gop = try seen_in.getOrPut(er.id);
        try testing.expect(!gop.found_existing);
    }
    for ([_]usize{ 0, 5, 10 }) |d| {
        var expected: usize = 0;
        for (edges) |er| if (er.to == nodes[d]) {
            expected += 1;
        };
        const in_edges = try collectIn(eng, nodes[d], null, testing.allocator);
        defer testing.allocator.free(in_edges);
        try testing.expectEqual(expected, in_edges.len);
    }
}

test {
    std.testing.refAllDecls(@This());
}
