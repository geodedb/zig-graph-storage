// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Label dictionaries across shards (SONNY-6524).
//
// Every shard of a ShardedGraphEngine keeps its own `labels.dict`; shard 0
// chooses the id of a new name and the other shards record the same pair.
// A new name is made durable (file fsync, rename, directory fsync) before its
// id is returned (SONNY-6491). This file checks:
//
//   * a failed durable write leaves the name unassigned in memory, so the
//     retry writes it (GraphEngine and every shard of a ShardedGraphEngine);
//   * the broadcast to shards 1..N-1 does not run on the caller's thread
//     alone;
//   * a crash part-way through a broadcast reopens with every shard agreeing
//     with shard 0;
//   * a store whose shard dictionaries were split (geode's old ORDER BY path
//     named a label in shard 0's dictionary only, so the next name got an id
//     one lower on shards 1..N-1) is repaired at open where no record on the
//     disagreeing shard uses an id whose meaning would change, and refused
//     with `error.LabelDictionaryDiverged` where one does.
//
// Write failures are real: a directory named `labels.dict.tmp` in a shard's
// graph directory makes the temp-file create fail (EISDIR, also as root),
// and `Checkpointer.test_fault = .post_label_dict` stops a save after the
// rename and before the directory fsync. Crashes are simulated the way the
// other crash tests do it: drop the engine without closing it and delete
// the WAL sidecars a dead process would not have rewritten.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const LabelDictionary = gs.label_dict.LabelDictionary;
const LabelId = gs.LabelId;
const SHARD_COUNT = gs.sharded_engine.SHARD_COUNT;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();
const Crc32 = std.hash.crc.Crc32Iscsi;

fn uuidFor(tag: u8) [16]u8 {
    return [_]u8{ 0x65, 0x24, tag } ++ [_]u8{0x24} ** 13;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn dictPath(alloc: Allocator, graph_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/labels.dict", .{graph_path});
}

/// Make the next `labels.dict` save in `graph_path` fail: the temp file it
/// creates is a directory.
fn blockDictWrites(alloc: Allocator, graph_path: []const u8) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/labels.dict.tmp", .{graph_path});
    defer alloc.free(p);
    try std.Io.Dir.cwd().createDir(io, p, .default_dir);
}

fn unblockDictWrites(alloc: Allocator, graph_path: []const u8) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/labels.dict.tmp", .{graph_path});
    defer alloc.free(p);
    try std.Io.Dir.cwd().deleteDir(io, p);
}

/// What `labels.dict` in `graph_path` holds on disk right now.
fn loadDiskDict(alloc: Allocator, graph_path: []const u8) !LabelDictionary {
    const p = try dictPath(alloc, graph_path);
    defer alloc.free(p);
    var d = LabelDictionary.init(alloc);
    errdefer d.deinit();
    try d.loadFromFile(p);
    return d;
}

const Entry = struct { name: []const u8, id: u32 };

/// Write a `labels.dict` holding exactly `entries` (any ids) in the on-disk
/// format: count u32 | (name_len u32, name, id u32)* | CRC32C u32.
fn writeDiskDict(alloc: Allocator, graph_path: []const u8, entries: []const Entry) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var w4: [4]u8 = undefined;
    std.mem.writeInt(u32, &w4, @intCast(entries.len), .little);
    try buf.appendSlice(alloc, &w4);
    for (entries) |e| {
        std.mem.writeInt(u32, &w4, @intCast(e.name.len), .little);
        try buf.appendSlice(alloc, &w4);
        try buf.appendSlice(alloc, e.name);
        std.mem.writeInt(u32, &w4, e.id, .little);
        try buf.appendSlice(alloc, &w4);
    }
    std.mem.writeInt(u32, &w4, Crc32.hash(buf.items), .little);
    try buf.appendSlice(alloc, &w4);

    const p = try dictPath(alloc, graph_path);
    defer alloc.free(p);
    const f = try std.Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, buf.items);
    try f.sync(io);
}

fn expectSameDict(what: []const u8, shard: usize, want: *const LabelDictionary, got: *const LabelDictionary) !void {
    var it = want.name_to_id.iterator();
    while (it.next()) |e| {
        const have = got.getId(e.key_ptr.*);
        if (have == null or have.? != e.value_ptr.*) {
            std.debug.print("{s}: shard {d} maps '{s}' to {?d}, shard 0 to {d}\n", .{ what, shard, e.key_ptr.*, have, e.value_ptr.* });
            return error.ShardLabelDictionaryDisagrees;
        }
    }
    if (got.count() != want.count()) {
        std.debug.print("{s}: shard {d} holds {d} names, shard 0 {d}\n", .{ what, shard, got.count(), want.count() });
        return error.ShardLabelDictionaryDisagrees;
    }
}

/// Every shard's dictionary, in memory and on disk, equals shard 0's.
fn expectShardsAgree(alloc: Allocator, eng: *ShardedGraphEngine, what: []const u8) !void {
    const d0 = &eng.shards[0].label_dict;
    for (eng.shards, 0..) |g, k| {
        try expectSameDict(what, k, d0, &g.label_dict);
        var disk = try loadDiskDict(alloc, g.graph_dir.path);
        defer disk.deinit();
        try expectSameDict(what, k, d0, &disk);
    }
}

/// Owned copies of every shard's graph directory and WAL directory.
const ShardPaths = struct {
    graph: [SHARD_COUNT][]u8,
    wal: [SHARD_COUNT][]u8,

    fn of(alloc: Allocator, eng: *ShardedGraphEngine) !ShardPaths {
        var out: ShardPaths = undefined;
        for (eng.shards, 0..) |g, k| {
            out.graph[k] = try alloc.dupe(u8, g.graph_dir.path);
            out.wal[k] = try std.fmt.allocPrint(alloc, "{s}/wal", .{g.graph_dir.path});
        }
        return out;
    }

    fn deinit(self: *ShardPaths, alloc: Allocator) void {
        for (self.graph) |p| alloc.free(p);
        for (self.wal) |p| alloc.free(p);
    }
};

/// What a dead process leaves: no WAL sidecar rewrite (see
/// tests/wal_lsn_anchor_crash.zig).
fn dropSidecars(paths: *const ShardPaths) !void {
    for (paths.wal) |d| {
        var dir = try std.Io.Dir.cwd().openDir(io, d, .{});
        defer dir.close(io);
        dir.deleteFile(io, "graph.wal.ckpt") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

/// A node on shard `shard` carrying `label`.
fn nodeOnShard(eng: *ShardedGraphEngine, shard: usize, label: LabelId) !gs.NodeId {
    const id = try eng.shards[shard].allocNode();
    try testing.expectEqual(shard, gs.shard_count.shardOfNode(id));
    try eng.putNode(id, test_support.emptyNode(1));
    try eng.addLabel(id, label);
    return id;
}

// ---------------------------------------------------------------------------
// Item 2: a failed durable write is undone in memory
// ---------------------------------------------------------------------------

test "SONNY-6524: GraphEngine: a failed labels.dict write leaves the name unassigned, so the retry persists it" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const eng = try GraphEngine.create(alloc, td.path, uuidFor(1), test_support.testConfig());
    defer eng.close() catch {};

    _ = try eng.getOrAssignLabel("A");

    try blockDictWrites(alloc, eng.graph_dir.path);
    if (eng.getOrAssignLabel("X")) |_| {
        return error.BlockedWriteSucceeded;
    } else |_| {}
    try unblockDictWrites(alloc, eng.graph_dir.path);

    // The failed statement must not leave the name behind in memory: a later
    // statement that found it there would never write it.
    try testing.expectEqual(@as(?u32, null), eng.label_dict.getId("X"));

    const x = try eng.getOrAssignLabel("X");
    var disk = try loadDiskDict(alloc, eng.graph_dir.path);
    defer disk.deinit();
    try testing.expectEqual(@as(?u32, x), disk.getId("X"));
}

test "SONNY-6524: GraphEngine: a save that fails after the rename is undone in memory too" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const eng = try GraphEngine.create(alloc, td.path, uuidFor(2), test_support.testConfig());
    defer eng.close() catch {};

    const a = try eng.getOrAssignLabel("A");

    eng.checkpointer.test_fault = .post_label_dict; // fail before the directory fsync
    try testing.expectError(error.TestCrashInjected, eng.getOrAssignLabel("X"));
    eng.checkpointer.test_fault = null;

    try testing.expectEqual(@as(?u32, null), eng.label_dict.getId("X"));
    // The id X did not get is the next one handed out, and the file written
    // for it does not keep X.
    const y = try eng.getOrAssignLabel("Y");
    try testing.expectEqual(a + 1, y);
    var disk = try loadDiskDict(alloc, eng.graph_dir.path);
    defer disk.deinit();
    try testing.expectEqual(@as(?u32, null), disk.getId("X"));
    try testing.expectEqual(@as(?u32, y), disk.getId("Y"));
}

test "SONNY-6524: ShardedGraphEngine: a failed write on one shard is completed by the retry" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const eng = try ShardedGraphEngine.create(alloc, td.path, uuidFor(3), test_support.testConfig());
    defer eng.close() catch {};

    _ = try eng.getOrAssignLabel("A");

    try blockDictWrites(alloc, eng.shards[7].graph_dir.path);
    if (eng.getOrAssignLabel("X")) |_| {
        return error.BlockedWriteSucceeded;
    } else |_| {}
    try unblockDictWrites(alloc, eng.shards[7].graph_dir.path);

    const x = try eng.getOrAssignLabel("X");
    try testing.expectEqual(@as(?u32, x), eng.shards[0].label_dict.getId("X"));
    try expectShardsAgree(alloc, eng, "after retry");
}

test "SONNY-6524: ShardedGraphEngine: after a failed broadcast the next new name has one id on every shard" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const eng = try ShardedGraphEngine.create(alloc, td.path, uuidFor(4), test_support.testConfig());
    defer eng.close() catch {};

    _ = try eng.getOrAssignLabel("A");

    try blockDictWrites(alloc, eng.shards[7].graph_dir.path);
    if (eng.getOrAssignLabel("X")) |_| {
        return error.BlockedWriteSucceeded;
    } else |_| {}
    try unblockDictWrites(alloc, eng.shards[7].graph_dir.path);

    // X is not retried. Z must still get shard 0's id on shard 7.
    const z = try eng.getOrAssignLabel("Z");
    for (eng.shards, 0..) |g, k| {
        const have = g.label_dict.getId("Z");
        if (have == null or have.? != z) {
            std.debug.print("shard {d} maps Z to {?d}, shard 0 to {d}\n", .{ k, have, z });
            return error.ShardLabelDictionaryDisagrees;
        }
        var disk = try loadDiskDict(alloc, g.graph_dir.path);
        defer disk.deinit();
        try testing.expectEqual(@as(?u32, z), disk.getId("Z"));
    }
}

// ---------------------------------------------------------------------------
// Item 1: the broadcast to shards 1..N-1 runs in parallel
// ---------------------------------------------------------------------------

test "SONNY-6524: ShardedGraphEngine: a new name is written to shards 1..N-1 off the caller's thread" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const eng = try ShardedGraphEngine.create(alloc, td.path, uuidFor(5), test_support.testConfig());
    defer eng.close() catch {};

    gs.sharded_engine.label_broadcast_stats.reset();
    const a = try eng.getOrAssignLabel("A");
    const off = gs.sharded_engine.label_broadcast_stats.offCallerThread();
    if (off == 0) {
        std.debug.print("all {d} shard writes of a new name ran on the caller's thread, one after another\n", .{SHARD_COUNT - 1});
        return error.LabelBroadcastIsSerial;
    }
    try expectShardsAgree(alloc, eng, "after a parallel broadcast");

    // An existing name writes nothing and needs no worker.
    gs.sharded_engine.label_broadcast_stats.reset();
    try testing.expectEqual(a, try eng.getOrAssignLabel("A"));
    try testing.expectEqual(@as(u32, 0), gs.sharded_engine.label_broadcast_stats.offCallerThread());
}

// ---------------------------------------------------------------------------
// Crash part-way through a broadcast
// ---------------------------------------------------------------------------

test "SONNY-6524: ShardedGraphEngine: a crash part-way through a broadcast reopens with every shard agreeing" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(6);
    const cfg = test_support.testConfig();

    var paths: ShardPaths = undefined;
    var x_id: ?u32 = null;
    var a: LabelId = 0;
    var node: gs.NodeId = 0;
    {
        const eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        paths = try ShardPaths.of(alloc, eng);
        a = try eng.getOrAssignLabel("A");
        node = try nodeOnShard(eng, 12, a);
        try eng.checkpoint();
        // Shards 9..15 cannot write; shard 0 and some others can.
        for (9..SHARD_COUNT) |k| try blockDictWrites(alloc, paths.graph[k]);
        if (eng.getOrAssignLabel("X")) |_| {
            return error.BlockedWriteSucceeded;
        } else |_| {}
        x_id = eng.shards[0].label_dict.getId("X");
        eng.deinit(); // the process dies
        try dropSidecars(&paths);
    }
    defer paths.deinit(alloc);
    for (9..SHARD_COUNT) |k| try unblockDictWrites(alloc, paths.graph[k]);

    {
        const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectShardsAgree(alloc, eng, "after a crash mid-broadcast");
        if (x_id) |x| try testing.expectEqual(@as(?u32, x), eng.shards[0].label_dict.getId("X"));
        const rec = (try eng.getNode(node)).?;
        try testing.expect(rec.label_count == 1);
        try testing.expectEqualStrings("A", eng.shards[12].label_dict.getName(a).?);
        // The store keeps working: X (or a fresh name) gets one id everywhere.
        _ = try eng.getOrAssignLabel("X");
        _ = try eng.getOrAssignLabel("W");
        try expectShardsAgree(alloc, eng, "after new names");
    }
}

test "SONNY-6524: ShardedGraphEngine: a crash after shard 0's rename, before its directory fsync, reopens with every shard agreeing" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(7);
    const cfg = test_support.testConfig();

    var paths: ShardPaths = undefined;
    {
        const eng = try ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        paths = try ShardPaths.of(alloc, eng);
        _ = try eng.getOrAssignLabel("A");
        eng.shards[0].checkpointer.test_fault = .post_label_dict;
        try testing.expectError(error.TestCrashInjected, eng.getOrAssignLabel("X"));
        eng.deinit();
        try dropSidecars(&paths);
    }
    defer paths.deinit(alloc);
    {
        const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectShardsAgree(alloc, eng, "after a crash in shard 0's save");
    }
}

// ---------------------------------------------------------------------------
// Item 3: split stores at open
// ---------------------------------------------------------------------------

/// Build a sharded store holding names A, X, Y (ids 0, 1, 2 on every shard),
/// a node labelled A on shard 3 and a node labelled Y on shard 5, plus
/// whatever `extra` adds; close it cleanly. Returns the shard directories.
fn buildStore(
    alloc: Allocator,
    data_dir: []const u8,
    uuid: [16]u8,
    comptime extra: fn (*ShardedGraphEngine) anyerror!void,
) !ShardPaths {
    const eng = try ShardedGraphEngine.create(alloc, data_dir, uuid, test_support.testConfig());
    errdefer eng.deinit();
    try testing.expectEqual(@as(LabelId, 0), try eng.getOrAssignLabel("A"));
    try testing.expectEqual(@as(LabelId, 1), try eng.getOrAssignLabel("X"));
    try testing.expectEqual(@as(LabelId, 2), try eng.getOrAssignLabel("Y"));
    _ = try nodeOnShard(eng, 3, 0);
    _ = try nodeOnShard(eng, 5, 2);
    try extra(eng);
    const paths = try ShardPaths.of(alloc, eng);
    try eng.close();
    return paths;
}

fn noExtra(_: *ShardedGraphEngine) anyerror!void {}

fn xNodeOnShard5(eng: *ShardedGraphEngine) anyerror!void {
    _ = try nodeOnShard(eng, 5, 1);
}

fn xEdgeFromShard5(eng: *ShardedGraphEngine) anyerror!void {
    const from = try nodeOnShard(eng, 5, 0);
    const to = try nodeOnShard(eng, 6, 0);
    _ = try eng.addEdge(from, to, 1);
}

/// Geode's old ORDER BY path: X was named in shard 0's dictionary only, so
/// the next name, Y, got id 1 on shards 1..N-1 and id 2 on shard 0.
fn splitLikeOrderBy(alloc: Allocator, paths: *const ShardPaths) !void {
    for (1..SHARD_COUNT) |k| try writeDiskDict(alloc, paths.graph[k], &.{
        .{ .name = "A", .id = 0 },
        .{ .name = "Y", .id = 1 },
    });
}

test "SONNY-6524: open repairs shards missing names that shard 0 has" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(8);
    var paths = try buildStore(alloc, td.path, uuid, noExtra);
    defer paths.deinit(alloc);

    // Shards 1..15 miss a suffix; shard 4 misses one in the middle; shard 9
    // has no names at all.
    for (1..SHARD_COUNT) |k| try writeDiskDict(alloc, paths.graph[k], &.{.{ .name = "A", .id = 0 }});
    try writeDiskDict(alloc, paths.graph[4], &.{ .{ .name = "A", .id = 0 }, .{ .name = "Y", .id = 2 } });
    try writeDiskDict(alloc, paths.graph[9], &.{});

    const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};
    try expectShardsAgree(alloc, eng, "after open");
    try testing.expectEqualStrings("Y", eng.shards[5].label_dict.getName(2).?);
    try testing.expectEqual(@as(LabelId, 3), try eng.getOrAssignLabel("Q"));
    try expectShardsAgree(alloc, eng, "after a new name");
}

test "SONNY-6524: open repairs a split whose disagreeing ids no record on that shard uses" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(9);
    var paths = try buildStore(alloc, td.path, uuid, noExtra);
    defer paths.deinit(alloc);
    try splitLikeOrderBy(alloc, &paths);

    const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};
    try expectShardsAgree(alloc, eng, "after open");
    try testing.expectEqual(@as(LabelId, 2), try eng.getOrAssignLabel("Y"));
    try testing.expectEqual(@as(LabelId, 3), try eng.getOrAssignLabel("Q"));
    try expectShardsAgree(alloc, eng, "after a new name");
}

fn expectRefusedUntouched(alloc: Allocator, td: *const test_support.TestDataDir, uuid: [16]u8, paths: *const ShardPaths) !void {
    if (ShardedGraphEngine.open(alloc, td.path, uuid, test_support.testConfig())) |eng| {
        eng.close() catch {};
        std.debug.print("a store whose shard 5 maps label id 1 to 'Y' (shard 0: 'X') while shard 5 has records with id 1 opened\n", .{});
        return error.DivergedStoreOpened;
    } else |err| {
        try testing.expectEqual(error.LabelDictionaryDiverged, err);
    }
    // Refused before anything was rewritten.
    for (1..SHARD_COUNT) |k| {
        var disk = try loadDiskDict(alloc, paths.graph[k]);
        defer disk.deinit();
        try testing.expectEqual(@as(u32, 2), disk.count());
        try testing.expectEqual(@as(?u32, 1), disk.getId("Y"));
    }
}

test "SONNY-6524: open refuses a split whose disagreeing id a node on that shard carries" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(10);
    var paths = try buildStore(alloc, td.path, uuid, xNodeOnShard5);
    defer paths.deinit(alloc);
    try splitLikeOrderBy(alloc, &paths);
    try expectRefusedUntouched(alloc, &td, uuid, &paths);
}

test "SONNY-6524: open refuses a split whose disagreeing id an edge on that shard carries" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(11);
    var paths = try buildStore(alloc, td.path, uuid, xEdgeFromShard5);
    defer paths.deinit(alloc);
    try splitLikeOrderBy(alloc, &paths);
    try expectRefusedUntouched(alloc, &td, uuid, &paths);
}
