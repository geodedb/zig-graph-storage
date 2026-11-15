// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6616: what at-rest encryption (GraphConfig.encryption_key) still
// left after SONNY-6590.
//
//   1. Opening a store with another key failed with error.NoManifest: both
//      manifest slots fail their HMAC, each read is swallowed, and the
//      selection reports "no manifest", which tells an operator the store is
//      missing or empty. It now fails with error.EncryptionKeyMismatch.
//   2. side_file_crypto.Kind was a closed enum, so a consumer sealing its own
//      files with the side-file envelope had to borrow one of graph-storage's
//      kinds. Kinds 128..255 are now the consumer's (`Kind.consumer`).
//   3. edges.idx and edges_exist.idx hold one record per relationship
//      (edge id, source, target, relationship-type id; edges.idx also the
//      property-chain head and public id), in plaintext next to the encrypted
//      adjacency pages: the graph's complete topology. They are now sealed
//      under a key; a plaintext one (written by 0.4.17) or one that fails
//      authentication is rebuilt from the pages and saved sealed.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const GraphConfig = gs.GraphConfig;
const crypto = gs.side_file_crypto;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

// Test-only keys; never real keys.
const KEY: [32]u8 = [_]u8{0x61} ** 32;
const OTHER_KEY: [32]u8 = [_]u8{0x16} ** 32;

fn uuidFor(tag: u8) [16]u8 {
    return [_]u8{ 0x66, 0x16, tag } ++ [_]u8{0x61} ** 13;
}

fn configFor(key: ?[32]u8) GraphConfig {
    var cfg = test_support.testConfig();
    cfg.encryption_key = key;
    return cfg;
}

fn graphPath(alloc: Allocator, data_dir: []const u8, uuid: [16]u8) ![]u8 {
    const hex = gs.sharded_engine.uuidHex(uuid);
    return std.fmt.allocPrint(alloc, "{s}/graphs/{s}", .{ data_dir, &hex });
}

fn readFile(alloc: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    defer alloc.free(p);
    return std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(1 << 30));
}

fn writeFile(alloc: Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    defer alloc.free(p);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
}

/// True when any regular file under `root` contains `needle`.
fn anyFileHolds(alloc: Allocator, root: []const u8, needle: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const buf = try entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(1 << 30));
        defer alloc.free(buf);
        if (std.mem.indexOf(u8, buf, needle) != null) {
            std.debug.print("SONNY-6616: topology record in plaintext in {s}\n", .{entry.path});
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 1. wrong key
// ---------------------------------------------------------------------------

test "SONNY-6616: opening an encrypted store with another key fails with EncryptionKeyMismatch, not NoManifest" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(1);
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        const a = try eng.allocNode();
        try eng.putNode(a, test_support.emptyNode(1));
        try eng.checkpoint();
    }
    try testing.expectError(error.EncryptionKeyMismatch, GraphEngine.open(alloc, td.path, uuid, configFor(OTHER_KEY)));
    // The right key still opens it.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
        try eng.close();
    }
    // A store whose manifests are gone is still NoManifest, with any key.
    const gp = try graphPath(alloc, td.path, uuid);
    defer alloc.free(gp);
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |slot| {
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ gp, slot });
        defer alloc.free(p);
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    }
    try testing.expectError(error.NoManifest, GraphEngine.open(alloc, td.path, uuid, configFor(OTHER_KEY)));
}

test "SONNY-6616: a sharded store opened with another key fails with EncryptionKeyMismatch" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(2);
    {
        const eng = try ShardedGraphEngine.create(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        try eng.checkpoint();
    }
    try testing.expectError(error.EncryptionKeyMismatch, ShardedGraphEngine.open(alloc, td.path, uuid, configFor(OTHER_KEY)));
    const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, configFor(KEY));
    try eng.close();
}

test "SONNY-6616: one manifest slot that fails its HMAC is skipped as before when the other verifies" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(3);
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        try eng.checkpoint();
        try eng.checkpoint();
    }
    const gp = try graphPath(alloc, td.path, uuid);
    defer alloc.free(gp);
    // Flip the last HMAC byte of slot b only.
    const b = try readFile(alloc, gp, "manifest.b");
    defer alloc.free(b);
    b[b.len - 1] ^= 0x01;
    try writeFile(alloc, gp, "manifest.b", b);
    const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
    try eng.close();
}

// ---------------------------------------------------------------------------
// 2. consumer kinds
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 3. topology snapshots
// ---------------------------------------------------------------------------

const Topo = struct { a: u64, b: u64, rel: u32, edge: u64 };

/// Two nodes and a relationship; their edges_exist.idx record
/// (from, to, rel_type, edge_id) is the byte string the scan looks for.
fn workload(eng: *GraphEngine) !Topo {
    const rel = try eng.getOrAssignLabel("Zq6616Rel");
    // Distinctive ids: skip ahead so the record bytes are unlikely elsewhere.
    var a: u64 = 0;
    var b: u64 = 0;
    for (0..40) |i| {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        if (i == 37) a = n;
        if (i == 39) b = n;
    }
    const e = try eng.addEdge(a, b, rel);
    return .{ .a = a, .b = b, .rel = rel, .edge = e };
}

fn existRecord(t: Topo) [28]u8 {
    var r: [28]u8 = undefined;
    std.mem.writeInt(u64, r[0..8], t.a, .little);
    std.mem.writeInt(u64, r[8..16], t.b, .little);
    std.mem.writeInt(u32, r[16..20], t.rel, .little);
    std.mem.writeInt(u64, r[20..28], t.edge, .little);
    return r;
}

/// edges.idx record prefix: (edge_id, from, neighbor, rel_type).
fn edgeRecordPrefix(t: Topo) [28]u8 {
    var r: [28]u8 = undefined;
    std.mem.writeInt(u64, r[0..8], t.edge, .little);
    std.mem.writeInt(u64, r[8..16], t.a, .little);
    std.mem.writeInt(u64, r[16..24], t.b, .little);
    std.mem.writeInt(u32, r[24..28], t.rel, .little);
    return r;
}

fn expectTopologyHidden(alloc: Allocator, root: []const u8, gp: []const u8, t: Topo) !void {
    for ([_][]const u8{ "edges.idx", "edges_exist.idx" }) |name| {
        const bytes = try readFile(alloc, gp, name);
        defer alloc.free(bytes);
        if (!crypto.isSealed(bytes)) {
            std.debug.print("SONNY-6616: {s} is not sealed ({d} bytes)\n", .{ name, bytes.len });
            return error.TopologyNotSealed;
        }
    }
    try testing.expect(!try anyFileHolds(alloc, root, &existRecord(t)));
    try testing.expect(!try anyFileHolds(alloc, root, &edgeRecordPrefix(t)));
}

fn hasEdge(eng: *GraphEngine, from: u64, to: u64, rel: u32) !bool {
    var buf: [8]u64 = undefined;
    return (try eng.probeEdge(from, rel, to, &buf)).len != 0;
}

/// Both snapshots answer: edges_exist.idx (probe) and edges.idx (by id).
fn expectEdge(eng: *GraphEngine, t: Topo) !void {
    try eng.ensureDerivedHydrated();
    try testing.expect(try hasEdge(eng, t.a, t.b, t.rel));
    const e = (try eng.getEdge(t.edge)) orelse return error.EdgeMissing;
    _ = e;
}

test "SONNY-6616: under a key edges.idx and edges_exist.idx are sealed and reload without a rebuild" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(5);
    const gp = try graphPath(alloc, td.path, uuid);
    defer alloc.free(gp);

    var t: Topo = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        t = try workload(eng);
        try eng.checkpoint();
    }
    try expectTopologyHidden(alloc, td.path, gp, t);
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        try expectEdge(eng, t);
        try testing.expectEqual(@as(u64, 1), eng.metrics.derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.metrics.derived_index_rebuilds);
        // A checkpoint with nothing dirty restamps the sealed snapshots.
        try eng.checkpoint();
    }
    try expectTopologyHidden(alloc, td.path, gp, t);
    const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
    defer eng.close() catch {};
    try expectEdge(eng, t);
    try testing.expectEqual(@as(u64, 1), eng.metrics.derived_index_loads);
}

test "SONNY-6616: without a key the topology snapshots keep their mmap layout" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(6);
    const gp = try graphPath(alloc, td.path, uuid);
    defer alloc.free(gp);
    var t: Topo = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, configFor(null));
        defer eng.close() catch {};
        t = try workload(eng);
        try eng.checkpoint();
    }
    const bytes = try readFile(alloc, gp, "edges_exist.idx");
    defer alloc.free(bytes);
    try testing.expect(!crypto.isSealed(bytes));
    const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(null));
    defer eng.close() catch {};
    try expectEdge(eng, t);
    try testing.expectEqual(@as(u64, 1), eng.metrics.derived_index_loads);
}

test "SONNY-6616: a plaintext topology snapshot under a key (written by 0.4.17), or a modified sealed one, is rebuilt and saved sealed" {
    const alloc = testing.allocator;
    var td_plain = try test_support.TestDataDir.init(alloc);
    defer td_plain.deinit();
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(7);
    const gp = try graphPath(alloc, td.path, uuid);
    defer alloc.free(gp);
    const gp_plain = try graphPath(alloc, td_plain.path, uuid);
    defer alloc.free(gp_plain);

    var t: Topo = undefined;
    inline for (.{ false, true }) |keyed| {
        const eng = try GraphEngine.create(alloc, if (keyed) td.path else td_plain.path, uuid, configFor(if (keyed) KEY else null));
        defer eng.close() catch {};
        t = try workload(eng);
        try eng.checkpoint();
    }
    // What 0.4.17 left under a key: the plaintext layout.
    for ([_][]const u8{ "edges.idx", "edges_exist.idx" }) |name| {
        const bytes = try readFile(alloc, gp_plain, name);
        defer alloc.free(bytes);
        try writeFile(alloc, gp, name, bytes);
    }
    try testing.expect(try anyFileHolds(alloc, td.path, &existRecord(t)));
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        try expectEdge(eng, t);
        try testing.expectEqual(@as(u64, 0), eng.metrics.derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.metrics.derived_index_rebuilds);
        try eng.checkpoint();
    }
    try expectTopologyHidden(alloc, td.path, gp, t);

    // A modified sealed snapshot is rebuilt, not trusted.
    const sealed = try readFile(alloc, gp, "edges_exist.idx");
    defer alloc.free(sealed);
    sealed[crypto.HEADER_SIZE + 2] ^= 0x01;
    try writeFile(alloc, gp, "edges_exist.idx", sealed);
    const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
    defer eng.close() catch {};
    try expectEdge(eng, t);
    try testing.expectEqual(@as(u64, 1), eng.metrics.derived_index_rebuilds);
}

test "SONNY-6616: sealed topology snapshots survive a crash and recovery with no plaintext" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(8);
    const gp = try graphPath(alloc, td.path, uuid);
    defer alloc.free(gp);
    var t: Topo = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, configFor(KEY));
        errdefer eng.deinit();
        t = try workload(eng);
        try eng.checkpoint();
        _ = try eng.addEdge(t.b, t.a, t.rel);
        eng.deinit(); // crash: no close
    }
    try expectTopologyHidden(alloc, td.path, gp, t);
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
        defer eng.close() catch {};
        try expectEdge(eng, t);
        try testing.expect(try hasEdge(eng, t.b, t.a, t.rel));
    }
    try expectTopologyHidden(alloc, td.path, gp, t);
}
