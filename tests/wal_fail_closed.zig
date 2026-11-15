// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6622: the graph WAL is never truncated or rewritten because it was
// opened in the wrong key mode, under the wrong key, or found damaged.
//
//   1. `VerifyTool` (the offline integrity check) opened `wal/graph.wal`
//      through `WalManager.init` without the at-rest key it was given and
//      through a modifying open: on wal <= 0.1.23 the encrypted records read
//      as a torn tail and the WAL was truncated to nothing - an integrity
//      check that wiped every un-checkpointed commit. It now validates a
//      private copy under the key and never opens the store's WAL for write.
//   2. A WAL that does not decode under the key (another key's records, or
//      plaintext records in an encrypted store) refuses the open with
//      `error.EncryptionKeyMismatch` (wal 0.1.24 `WalAuthFailed` /
//      `WalEncryptionMismatch`), and the WAL is left as it was.
//   3. A checkpoint whose WAL compaction is refused (the log was damaged
//      after it was opened: wal 0.1.24 `WalCorrupted`) still completes; the
//      WAL keeps its records and the engine keeps working.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const GraphDir = gs.graph_dir.GraphDir;
const VerifyTool = gs.verify.VerifyTool;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

// Test-only keys; never real keys.
const KEY: [32]u8 = [_]u8{0x62} ** 32;
const OTHER_KEY: [32]u8 = [_]u8{0x26} ** 32;

fn uuidFor(tag: u8) [16]u8 {
    return [_]u8{ 0x66, 0x22, tag } ++ [_]u8{0x62} ** 13;
}

fn configFor(key: ?[32]u8) GraphConfig {
    var cfg = test_support.testConfig();
    cfg.encryption_key = key;
    return cfg;
}

fn walPath(alloc: Allocator, data_dir: []const u8, uuid: [16]u8) ![]u8 {
    const hex = gs.sharded_engine.uuidHex(uuid);
    return std.fmt.allocPrint(alloc, "{s}/graphs/{s}/wal/graph.wal", .{ data_dir, &hex });
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// A store whose last commits are only in the WAL (the process died before
/// a checkpoint): `n` nodes after the checkpoint.
fn crashedStore(alloc: Allocator, data_dir: []const u8, uuid: [16]u8, key: ?[32]u8, n: usize) !void {
    const eng = try GraphEngine.create(alloc, data_dir, uuid, configFor(key));
    errdefer eng.deinit();
    try eng.checkpoint();
    for (0..n) |_| {
        const id = try eng.allocNode();
        try eng.putNode(id, test_support.emptyNode(1));
    }
    eng.deinit(); // crash: no close, no checkpoint
}

fn walArtifact(result: *const gs.verify.VerifyResult) ?gs.verify.VerifyArtifact {
    for (result.artifacts.items) |a| {
        if (std.mem.eql(u8, a.name, "wal/graph.wal")) return a;
    }
    return null;
}

// ---------------------------------------------------------------------------
// 1. verify
// ---------------------------------------------------------------------------

test "SONNY-6622: VerifyTool checks an encrypted WAL under the key and leaves it byte for byte as it was" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(1);
    try crashedStore(alloc, td.path, uuid, KEY, 16);

    const wp = try walPath(alloc, td.path, uuid);
    defer alloc.free(wp);
    const before = try readFile(alloc, wp);
    defer alloc.free(before);
    try testing.expect(before.len > 0);

    var gd = try GraphDir.open(alloc, td.path, uuid);
    defer gd.deinit();
    var vt = VerifyTool.init(alloc);
    vt.encryption_key = KEY;
    var result = try vt.verifyGraph(&gd, configFor(KEY).page_size);
    defer result.deinit();

    const after = try readFile(alloc, wp);
    defer alloc.free(after);
    if (!std.mem.eql(u8, before, after)) {
        std.debug.print("SONNY-6622: verify changed wal/graph.wal: {d} bytes -> {d}\n", .{ before.len, after.len });
        return error.VerifyModifiedWal;
    }
    const art = walArtifact(&result) orelse return error.NoWalArtifact;
    for (result.errors.items) |e| std.debug.print("SONNY-6622: verify error: {s}\n", .{e});
    try testing.expect(art.status == .ok);
    try testing.expect(art.items_checked >= 16);

    // The records are still there: the store recovers every node.
    const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
    defer eng.close() catch {};
    try testing.expectEqual(@as(u64, 16), try eng.nodeCount());
}

test "SONNY-6622: VerifyTool without the key reports an encrypted WAL it cannot read and leaves it as it was" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(2);
    try crashedStore(alloc, td.path, uuid, KEY, 8);
    const wp = try walPath(alloc, td.path, uuid);
    defer alloc.free(wp);
    const before = try readFile(alloc, wp);
    defer alloc.free(before);

    for ([_]?[32]u8{ null, OTHER_KEY }) |key| {
        var gd = try GraphDir.open(alloc, td.path, uuid);
        defer gd.deinit();
        var vt = VerifyTool.init(alloc);
        vt.encryption_key = key;
        var result = try vt.verifyGraph(&gd, configFor(KEY).page_size);
        defer result.deinit();
        const art = walArtifact(&result) orelse return error.NoWalArtifact;
        try testing.expect(art.status != .ok);
        const after = try readFile(alloc, wp);
        defer alloc.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

// ---------------------------------------------------------------------------
// 2. a WAL that does not decode under the key
// ---------------------------------------------------------------------------

test "SONNY-6622: a WAL of another key, or a plaintext WAL in an encrypted store, refuses the open with EncryptionKeyMismatch and is kept" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    var td_other = try test_support.TestDataDir.init(alloc);
    defer td_other.deinit();
    const uuid = uuidFor(3);
    try crashedStore(alloc, td.path, uuid, KEY, 4);
    const wp = try walPath(alloc, td.path, uuid);
    defer alloc.free(wp);
    const own = try readFile(alloc, wp);
    defer alloc.free(own);

    inline for (.{ OTHER_KEY, null }) |foreign_key| {
        // The same graph written under another key, or without one.
        {
            var tdf = try test_support.TestDataDir.init(alloc);
            defer tdf.deinit();
            try crashedStore(alloc, tdf.path, uuid, foreign_key, 4);
            const fwp = try walPath(alloc, tdf.path, uuid);
            defer alloc.free(fwp);
            const foreign = try readFile(alloc, fwp);
            defer alloc.free(foreign);
            try writeFile(wp, foreign);
        }
        const planted = try readFile(alloc, wp);
        defer alloc.free(planted);
        try testing.expectError(error.EncryptionKeyMismatch, GraphEngine.open(alloc, td.path, uuid, configFor(KEY)));
        const after = try readFile(alloc, wp);
        defer alloc.free(after);
        try testing.expectEqualSlices(u8, planted, after);
    }
    // Its own WAL back: it opens.
    try writeFile(wp, own);
    const eng = try GraphEngine.open(alloc, td.path, uuid, configFor(KEY));
    try eng.close();
}
