// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Recovery drains the WAL it replayed (SONNY-6599).
//
// A crash leaves a committed WAL tail. Recovery replays it into the pages,
// flushes and fsyncs them and writes both manifests with
// `last_checkpoint_lsn` past every replayed record, so every record in the
// file is now below the frontier and never replayed again. graph_storage
// <= 0.4.21 left the file in place, and the engine opens clean
// (`persistence_dirty == false`), so a shard nothing writes to after the
// restart kept its whole replayed tail through every light checkpoint and
// through `close` (geode `test-sonny6595-wal-drain`).
//
// Recovery now truncates the WAL to the advanced frontier once the manifests
// and the directory entries that name them are durable. Truncating before
// that would lose data: a power loss could bring back the previous manifest
// next to a WAL that no longer holds the tail it needs. The fault matrix
// below stops recovery after each durable step (`gs.recovery.test_fault`,
// test builds only), leaves the store as a dead process would, and checks
// that the next open loses nothing and drains the WAL.
//
// Matrix: {GraphEngine, ShardedGraphEngine} x {plaintext, TDE}.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

/// Overflows into var-store pages, so the tail images several store files.
const BLOB_LEN: usize = 6000;

fn blobByte(tag: u64, i: usize) u8 {
    return @intCast((tag *% 131 +% i * 31 +% 7) % 251);
}

fn config(tde: bool) gs.GraphConfig {
    var cfg = test_support.testConfig();
    if (tde) cfg.encryption_key = [_]u8{0x59} ** 32;
    return cfg;
}

fn Ops(comptime E: type) type {
    const sharded = E == ShardedGraphEngine;
    return struct {
        pub const n_nodes: usize = if (sharded) 40 else 12;

        /// Every underlying GraphEngine (one WAL each).
        fn engines(eng: *const *E) []const *GraphEngine {
            if (sharded) return &eng.*.shards;
            const one: *const [1]*GraphEngine = eng;
            return one;
        }

        fn putProp(eng: *E, id: u64, head: u64, key: []const u8, val: gs.PropertyValue) !u64 {
            if (sharded) return eng.putNodeProperty(id, head, key, val);
            return eng.putProperty(head, key, val);
        }

        fn getProp(eng: *E, id: u64, head: u64, key: []const u8, alloc: Allocator) !?gs.PropertyValue {
            if (sharded) return eng.getNodeProperty(id, head, key, alloc);
            return eng.getProperty(head, key, alloc);
        }

        fn writeBatch(alloc: Allocator, eng: *E, ids: []u64) !void {
            const blob = try alloc.alloc(u8, BLOB_LEN);
            defer alloc.free(blob);
            for (ids) |*id| {
                id.* = try eng.allocNode();
                try eng.putNode(id.*, test_support.emptyNode(1));
                for (blob, 0..) |*b, i| b.* = blobByte(id.*, i);
                var rec = (try eng.getNode(id.*)).?;
                rec.prop_head = try putProp(eng, id.*, rec.prop_head, "blob", .{ .string = blob });
                try eng.putNode(id.*, rec);
            }
        }

        fn expectBatch(alloc: Allocator, eng: *E, ids: []const u64, what: []const u8) !void {
            for (ids) |id| {
                const rec = (try eng.getNode(id)) orelse {
                    std.debug.print("{s}: committed node {d} not found\n", .{ what, id });
                    return error.CommittedNodeLost;
                };
                const v = (try getProp(eng, id, rec.prop_head, "blob", alloc)) orelse {
                    std.debug.print("{s}: node {d} lost its committed property\n", .{ what, id });
                    return error.CommittedPropertyLost;
                };
                defer gs.property.freeDecoded(alloc, v);
                switch (v) {
                    .string => |s| {
                        if (s.len != BLOB_LEN) return error.CommittedPropertyCorrupted;
                        for (s, 0..) |b, i| if (b != blobByte(id, i)) return error.CommittedPropertyCorrupted;
                    },
                    else => return error.CommittedPropertyWrongType,
                }
            }
        }

        /// Owned copies of every engine's graph directory path.
        fn graphDirs(alloc: Allocator, eng: *E) ![][]u8 {
            const list = engines(&eng);
            const out = try alloc.alloc([]u8, list.len);
            for (list, 0..) |g, i| out[i] = try alloc.dupe(u8, g.graph_dir.path);
            return out;
        }
    };
}

fn freeDirs(alloc: Allocator, dirs: [][]u8) void {
    for (dirs) |d| alloc.free(d);
    alloc.free(dirs);
}

/// What a dead process leaves: `deinit` rewrote the wal library's sidecar,
/// a killed process does not (see tests/wal_lsn_anchor_crash.zig).
fn dropSidecars(dirs: []const []const u8) !void {
    for (dirs) |d| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/wal/graph.wal.ckpt", .{d});
        std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

/// Total `graph.wal` bytes across `dirs`; `per` (when given) gets each size.
fn walBytes(dirs: []const []const u8) !u64 {
    var total: u64 = 0;
    for (dirs) |d| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/wal/graph.wal", .{d});
        const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        total += st.size;
    }
    return total;
}

/// Create, checkpoint, write a committed batch and die without a checkpoint:
/// the store holds a committed WAL tail. Returns the graph directories.
fn crashWithTail(comptime E: type, alloc: Allocator, path: []const u8, uuid: [16]u8, cfg: gs.GraphConfig, ids: []u64) ![][]u8 {
    const O = Ops(E);
    const eng = try E.create(alloc, path, uuid, cfg);
    try eng.checkpoint();
    try O.writeBatch(alloc, eng, ids);
    const dirs = try O.graphDirs(alloc, eng);
    errdefer freeDirs(alloc, dirs);
    eng.deinit();
    try dropSidecars(dirs);
    return dirs;
}

/// The reproduction: after a crash restart with no write, `open` alone must
/// leave no WAL bytes, and so must `close`.
fn runDrainOnOpen(comptime E: type, tde: bool) !void {
    const O = Ops(E);
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x65, 0x99, @intFromBool(E == ShardedGraphEngine), @intFromBool(tde) } ++ [_]u8{0x41} ** 12;
    const cfg = config(tde);

    var a: [O.n_nodes]u64 = undefined;
    const dirs = try crashWithTail(E, alloc, td.path, uuid, cfg, &a);
    defer freeDirs(alloc, dirs);
    const tail = try walBytes(dirs);
    try testing.expect(tail > 0);

    {
        const eng = try E.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        const after_open = try walBytes(dirs);
        if (after_open != 0) {
            std.debug.print("SONNY-6599 {s} tde={}: {d} WAL bytes of a {d}-byte replayed tail survive recovery\n", .{ @typeName(E), tde, after_open, tail });
            return error.ReplayedWalNotTruncated;
        }
        try O.expectBatch(alloc, eng, &a, "after recovery");
        try eng.close();
    }
    try testing.expectEqual(@as(u64, 0), try walBytes(dirs));

    // Writes after the drained open are numbered above the frontier and
    // survive another crash (the emptied log has no sidecar after a kill).
    var b: [O.n_nodes]u64 = undefined;
    {
        const eng = try E.open(alloc, td.path, uuid, cfg);
        try O.writeBatch(alloc, eng, &b);
        eng.deinit();
        try dropSidecars(dirs);
    }
    {
        const eng = try E.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(u64, 0), try walBytes(dirs));
        try O.expectBatch(alloc, eng, &a, "second crash, batch A");
        try O.expectBatch(alloc, eng, &b, "second crash, batch B");
    }
}

test "SONNY-6599: GraphEngine recovery truncates the replayed WAL" {
    try runDrainOnOpen(GraphEngine, false);
}
test "SONNY-6599: GraphEngine TDE recovery truncates the replayed WAL" {
    try runDrainOnOpen(GraphEngine, true);
}
test "SONNY-6599: ShardedGraphEngine recovery truncates every shard's replayed WAL" {
    try runDrainOnOpen(ShardedGraphEngine, false);
}
test "SONNY-6599: ShardedGraphEngine TDE recovery truncates every shard's replayed WAL" {
    try runDrainOnOpen(ShardedGraphEngine, true);
}
