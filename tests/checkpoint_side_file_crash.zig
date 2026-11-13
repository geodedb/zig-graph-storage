// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Crash at every step of a checkpoint (SONNY-6491).
//
// A checkpoint persists, besides the pages, two side files the next clean open
// trusts: `free.store` (which pages are allocated) and `labels.dict` (label id
// <-> name; label assignment is not WAL-logged). When either becomes durable
// only AFTER the manifest that advances the checkpoint frontier, a crash in
// between leaves a manifest whose WAL tail is gone (or holds nothing past the
// frontier) next to the previous checkpoint's side files:
//
//   * free.store: pages allocated since its last save read as FREE, so the
//     next writer is handed a live page and overwrites committed data;
//   * labels.dict: names assigned since its last save are gone.
//
// Every test here: checkpoint A (side files current), commit B (new var-store
// pages via an overflow property, a new label name), checkpoint again and
// "crash" right after step P (`Checkpointer.test_fault`, test builds only),
// drop the engine the way a dead process does, reopen, then commit C (new
// allocations), close and reopen. A, B and C must all read back intact and
// B's label name must resolve. Matrix: P x {light, full, close} x
// {plaintext, TDE} x {GraphEngine, ShardedGraphEngine}.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const FaultPoint = gs.checkpoint.FaultPoint;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

const Kind = enum { light, full, close };

const BLOB_LEN: usize = 6000; // overflows into var-store pages

fn blobByte(tag: u64, i: usize) u8 {
    return @intCast((tag *% 131 +% i * 31 +% 7) % 251);
}

fn Ops(comptime E: type) type {
    const sharded = E == ShardedGraphEngine;
    return struct {
        fn create(alloc: Allocator, path: []const u8, uuid: [16]u8, cfg: gs.GraphConfig) !*E {
            return E.create(alloc, path, uuid, cfg);
        }
        fn open(alloc: Allocator, path: []const u8, uuid: [16]u8, cfg: gs.GraphConfig) !*E {
            return E.open(alloc, path, uuid, cfg);
        }

        fn engines(eng: *E) []const *GraphEngine {
            if (sharded) return &eng.shards;
            const one: *const [1]*GraphEngine = @ptrCast(&eng);
            return one;
        }

        fn setFault(eng: *E, p: ?FaultPoint) void {
            for (engines(eng)) |g| g.checkpointer.test_fault = p;
        }

        /// Owned copies of every engine's WAL directory path.
        fn walDirs(alloc: Allocator, eng: *E) ![][]u8 {
            const gs_list = engines(eng);
            const out = try alloc.alloc([]u8, gs_list.len);
            for (gs_list, 0..) |g, i| out[i] = try std.fmt.allocPrint(alloc, "{s}/wal", .{g.graph_dir.path});
            return out;
        }

        /// What a dead process leaves: no WAL sidecar rewrite (see
        /// tests/wal_lsn_anchor_crash.zig).
        fn dropSidecars(alloc: Allocator, dirs: [][]u8) !void {
            for (dirs) |d| {
                var dir = try std.Io.Dir.cwd().openDir(io, d, .{});
                defer dir.close(io);
                dir.deleteFile(io, "graph.wal.ckpt") catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                alloc.free(d);
            }
            alloc.free(dirs);
        }

        fn putProp(eng: *E, id: u64, head: u64, key: []const u8, val: gs.PropertyValue) !u64 {
            if (sharded) return eng.putNodeProperty(id, head, key, val);
            return eng.putProperty(head, key, val);
        }

        fn getProp(eng: *E, id: u64, head: u64, key: []const u8, alloc: Allocator) !?gs.PropertyValue {
            if (sharded) return eng.getNodeProperty(id, head, key, alloc);
            return eng.getProperty(head, key, alloc);
        }

        fn labelName(eng: *E, id: u64, label: gs.LabelId) ?[]const u8 {
            const g = if (sharded) eng.shards[gs.shard_count.shardOfNode(id)] else eng;
            return g.label_dict.getName(label);
        }

        /// Commit `ids.len` nodes, each with an overflow property tagged by
        /// its id and the label `label_name`.
        fn writeBatch(alloc: Allocator, eng: *E, ids: []u64, label_name: []const u8) !gs.LabelId {
            const label = try eng.getOrAssignLabel(label_name);
            const blob = try alloc.alloc(u8, BLOB_LEN);
            defer alloc.free(blob);
            for (ids) |*id| {
                id.* = try eng.allocNode();
                try eng.putNode(id.*, test_support.emptyNode(1));
                for (blob, 0..) |*b, i| b.* = blobByte(id.*, i);
                var rec = (try eng.getNode(id.*)).?;
                rec.prop_head = try putProp(eng, id.*, rec.prop_head, "blob", .{ .string = blob });
                try eng.putNode(id.*, rec);
                try eng.addLabel(id.*, label);
            }
            return label;
        }

        fn expectBatch(alloc: Allocator, eng: *E, ids: []const u64, label: gs.LabelId, label_name: []const u8, what: []const u8) !void {
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
                        for (s, 0..) |b, i| if (b != blobByte(id, i)) {
                            std.debug.print("{s}: node {d} property overwritten (page handed out again?)\n", .{ what, id });
                            return error.CommittedPropertyCorrupted;
                        };
                    },
                    else => return error.CommittedPropertyWrongType,
                }
                if (rec.label_count == 0) return error.CommittedLabelLost;
                const name = labelName(eng, id, label) orelse {
                    std.debug.print("{s}: label id {d} of node {d} has no name (labels.dict lost '{s}')\n", .{ what, label, id, label_name });
                    return error.LabelNameLost;
                };
                try testing.expectEqualStrings(label_name, name);
            }
        }
    };
}

fn config(tde: bool) gs.GraphConfig {
    var cfg = test_support.testConfig();
    if (tde) cfg.encryption_key = [_]u8{0x49} ** 32;
    return cfg;
}

fn checkpointKind(comptime E: type, eng: *E, kind: Kind) !void {
    switch (kind) {
        .light => try eng.checkpointLight(),
        .full => try eng.checkpoint(),
        .close => try eng.close(),
    }
}

fn runScenario(comptime E: type, kind: Kind, point: FaultPoint, tde: bool) !void {
    const O = Ops(E);
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{ 0x64, 0x91, @intFromEnum(kind), @intFromEnum(point), @intFromBool(tde) } ++ [_]u8{0x31} ** 11;
    const cfg = config(tde);
    const n = if (E == ShardedGraphEngine) 32 else 12;

    var a: [n]u64 = undefined;
    var b: [n]u64 = undefined;
    var c: [n]u64 = undefined;
    var la: gs.LabelId = 0;
    var lb: gs.LabelId = 0;
    {
        const eng = try O.create(alloc, td.path, uuid, cfg);
        la = try O.writeBatch(alloc, eng, &a, "A");
        try eng.checkpoint();
        lb = try O.writeBatch(alloc, eng, &b, "B");
        O.setFault(eng, point);
        const dirs = try O.walDirs(alloc, eng);
        if (checkpointKind(E, eng, kind)) |_| {
            // The fault point is not on this kind's path: a completed
            // checkpoint, then the process dies.
            if (kind != .close) eng.deinit();
        } else |err| {
            if (err != error.TestCrashInjected) return err;
            if (kind != .close) eng.deinit();
        }
        try O.dropSidecars(alloc, dirs);
    }
    {
        const eng = try O.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        try O.expectBatch(alloc, eng, &a, la, "A", "after crash");
        try O.expectBatch(alloc, eng, &b, lb, "B", "after crash");
        // B's name must still map to B's id (a lost name would be re-assigned).
        try testing.expectEqual(lb, try eng.getOrAssignLabel("B"));
        const lc = try O.writeBatch(alloc, eng, &c, "C");
        try O.expectBatch(alloc, eng, &a, la, "A", "after new writes");
        try O.expectBatch(alloc, eng, &b, lb, "B", "after new writes");
        try O.expectBatch(alloc, eng, &c, lc, "C", "after new writes");
        try eng.close();
    }
    {
        const eng = try O.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try O.expectBatch(alloc, eng, &a, la, "A", "after clean reopen");
        try O.expectBatch(alloc, eng, &b, lb, "B", "after clean reopen");
    }
}

fn runMatrix(comptime E: type, kind: Kind, tde: bool) !void {
    var failures: usize = 0;
    inline for (std.meta.fields(FaultPoint)) |f| {
        const point: FaultPoint = @enumFromInt(f.value);
        runScenario(E, kind, point, tde) catch |err| {
            std.debug.print("SONNY-6491 {s} {s} tde={} crash after {s}: {s}\n", .{ @typeName(E), @tagName(kind), tde, @tagName(point), @errorName(err) });
            failures += 1;
        };
    }
    if (failures != 0) return error.CheckpointCrashLosesData;
}

test "SONNY-6491: GraphEngine light checkpoint, crash at every step" {
    try runMatrix(GraphEngine, .light, false);
}
test "SONNY-6491: GraphEngine full checkpoint, crash at every step" {
    try runMatrix(GraphEngine, .full, false);
}
test "SONNY-6491: GraphEngine close, crash at every step" {
    try runMatrix(GraphEngine, .close, false);
}
test "SONNY-6491: GraphEngine TDE light checkpoint, crash at every step" {
    try runMatrix(GraphEngine, .light, true);
}
test "SONNY-6491: GraphEngine TDE full checkpoint, crash at every step" {
    try runMatrix(GraphEngine, .full, true);
}
test "SONNY-6491: GraphEngine TDE close, crash at every step" {
    try runMatrix(GraphEngine, .close, true);
}
test "SONNY-6491: ShardedGraphEngine light checkpoint, crash at every step" {
    try runMatrix(ShardedGraphEngine, .light, false);
}
test "SONNY-6491: ShardedGraphEngine full checkpoint, crash at every step" {
    try runMatrix(ShardedGraphEngine, .full, false);
}
test "SONNY-6491: ShardedGraphEngine close, crash at every step" {
    try runMatrix(ShardedGraphEngine, .close, false);
}
test "SONNY-6491: ShardedGraphEngine TDE full checkpoint, crash at every step" {
    try runMatrix(ShardedGraphEngine, .full, true);
}
