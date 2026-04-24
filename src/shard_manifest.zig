// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Top-level per-graph manifest recording the shard-count, the
//! shard-routing algorithm version hash (so a mismatched build is
//! detected at open), and the per-shard derived UUIDs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const shard_count_mod = @import("shard_count.zig");

pub const SHARD_MANIFEST_VERSION: u32 = 1;

/// Stable 64-bit fingerprint of the shard-routing algorithm. Bumped
/// whenever the routing function semantics change.
pub const SHARD_ALGORITHM_HASH: u64 = 0x5350_4C49_544D_3601;

pub const ShardManifest = struct {
    version: u32,
    shard_count: u32,
    algorithm_hash: u64,
    per_shard_uuids: [shard_count_mod.SHARD_COUNT][16]u8,
};

const FILE_NAME = "shard_manifest.json";

pub fn writeToDir(allocator: Allocator, dir_path: []const u8, manifest: ShardManifest) !void {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, FILE_NAME });
    defer allocator.free(file_path);

    // Build JSON string in one go using allocPrint with careful formatting
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"version\":");

    // Use a helper to append formatted numbers
    const version_str = try std.fmt.allocPrint(allocator, "{d}", .{manifest.version});
    defer allocator.free(version_str);
    try buf.appendSlice(allocator, version_str);

    try buf.appendSlice(allocator, ",\"shard_count\":");
    const shard_count_str = try std.fmt.allocPrint(allocator, "{d}", .{manifest.shard_count});
    defer allocator.free(shard_count_str);
    try buf.appendSlice(allocator, shard_count_str);

    try buf.appendSlice(allocator, ",\"algorithm_hash\":");
    const algorithm_hash_str = try std.fmt.allocPrint(allocator, "{d}", .{manifest.algorithm_hash});
    defer allocator.free(algorithm_hash_str);
    try buf.appendSlice(allocator, algorithm_hash_str);

    try buf.appendSlice(allocator, ",\"per_shard_uuids\":[");

    for (manifest.per_shard_uuids, 0..) |uuid, i| {
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

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(io);
    try file.writePositionalAll(io, buf.items, 0);
    try file.sync(io);
}

pub fn readFromDir(allocator: Allocator, dir_path: []const u8) !ShardManifest {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, FILE_NAME });
    defer allocator.free(file_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    const bytes = try allocator.alloc(u8, file_len);
    defer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const version = @as(u32, @intCast(root.get("version").?.integer));
    const shard_count = @as(u32, @intCast(root.get("shard_count").?.integer));

    // Handle algorithm_hash which may be parsed as number_string for large values
    const ah_value = root.get("algorithm_hash").?;
    const algorithm_hash = if (ah_value == .integer)
        @as(u64, @intCast(ah_value.integer))
    else if (ah_value == .number_string)
        try std.fmt.parseInt(u64, ah_value.number_string, 10)
    else
        return error.InvalidAlgorithmHash;

    if (version != SHARD_MANIFEST_VERSION) return error.ShardManifestVersionMismatch;
    if (shard_count != shard_count_mod.SHARD_COUNT) return error.ShardCountMismatch;
    if (algorithm_hash != SHARD_ALGORITHM_HASH) return error.ShardAlgorithmMismatch;

    const arr = root.get("per_shard_uuids").?.array;
    if (arr.items.len != shard_count_mod.SHARD_COUNT) return error.ShardCountMismatch;

    var per_shard: [shard_count_mod.SHARD_COUNT][16]u8 = undefined;
    for (arr.items, 0..) |item, i| {
        const hex = item.string;
        if (hex.len != 32) return error.InvalidShardUuid;
        var out: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&out, hex);
        per_shard[i] = out;
    }

    return .{
        .version = version,
        .shard_count = shard_count,
        .algorithm_hash = algorithm_hash,
        .per_shard_uuids = per_shard,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "ShardManifest round-trip via writeToDir / readFromDir" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var per_shard: [16][16]u8 = undefined;
    for (&per_shard, 0..) |*u, i| u.* = .{@as(u8, @intCast(i))} ** 16;

    const original = sm.ShardManifest{
        .version = sm.SHARD_MANIFEST_VERSION,
        .shard_count = 16,
        .algorithm_hash = sm.SHARD_ALGORITHM_HASH,
        .per_shard_uuids = per_shard,
    };
    try sm.writeToDir(std.testing.allocator, path, original);

    const loaded = try sm.readFromDir(std.testing.allocator, path);
    try std.testing.expectEqual(original.version, loaded.version);
    try std.testing.expectEqual(original.shard_count, loaded.shard_count);
    try std.testing.expectEqual(original.algorithm_hash, loaded.algorithm_hash);
    for (0..16) |i| {
        try std.testing.expectEqualSlices(u8, &original.per_shard_uuids[i], &loaded.per_shard_uuids[i]);
    }
}

test "readFromDir rejects wrong algorithm_hash" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var per_shard: [16][16]u8 = undefined;
    for (&per_shard) |*u| u.* = .{0} ** 16;

    const bad = sm.ShardManifest{
        .version = sm.SHARD_MANIFEST_VERSION,
        .shard_count = 16,
        .algorithm_hash = 0xDEADBEEFDEADBEEF,
        .per_shard_uuids = per_shard,
    };
    try sm.writeToDir(std.testing.allocator, path, bad);
    try std.testing.expectError(error.ShardAlgorithmMismatch, sm.readFromDir(std.testing.allocator, path));
}
