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

/// Edge co-location (Phase B): the on-disk EDGE-ADJACENCY layout version,
/// distinct from `SHARD_MANIFEST_VERSION` (the manifest FORMAT version).
///
///   0 (or absent) = LEGACY: cross-shard in-edges live on the dst shard
///                   (`dst.adj_in` / `dst.in_head`); `adj_in_remote` is empty.
///   1             = CO-LOCATED: every edge's in-adjacency lives on shard(src)
///                   in `adj_in_remote`, keyed by `to` via `in_head_dir`.
///
/// A pre-co-location manifest has NO `layout_version` field; `readFromDir`
/// parses that as 0. A graph whose `layout_version` is < CURRENT migrates its
/// `adj_in_remote` from `adj_out` on open, then stamps CURRENT (see
/// `sharded_engine`/`sharded_migration`).
pub const CURRENT_LAYOUT_VERSION: u32 = 1;

pub const ShardManifest = struct {
    version: u32,
    shard_count: u32,
    algorithm_hash: u64,
    per_shard_uuids: [shard_count_mod.SHARD_COUNT][16]u8,
    /// Edge-adjacency layout version. Absent in a legacy manifest → 0. Fresh
    /// graphs are created at `CURRENT_LAYOUT_VERSION`.
    layout_version: u32 = 0,
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

    // Edge co-location (Phase B): the edge-adjacency layout version. Always
    // written by this build; a legacy manifest omits it (read back as 0).
    try buf.appendSlice(allocator, ",\"layout_version\":");
    const layout_version_str = try std.fmt.allocPrint(allocator, "{d}", .{manifest.layout_version});
    defer allocator.free(layout_version_str);
    try buf.appendSlice(allocator, layout_version_str);

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

    if (parsed.value != .object) return error.InvalidShardManifest;
    const root = parsed.value.object;

    const version_node = root.get("version") orelse return error.InvalidShardManifest;
    if (version_node != .integer) return error.InvalidShardManifest;
    if (version_node.integer < 0 or version_node.integer > std.math.maxInt(u32))
        return error.InvalidShardManifest;
    const version = @as(u32, @intCast(version_node.integer));

    const shard_count_node = root.get("shard_count") orelse return error.InvalidShardManifest;
    if (shard_count_node != .integer) return error.InvalidShardManifest;
    if (shard_count_node.integer < 0 or shard_count_node.integer > std.math.maxInt(u32))
        return error.InvalidShardManifest;
    const shard_count = @as(u32, @intCast(shard_count_node.integer));

    // Handle algorithm_hash which may be parsed as number_string for large values
    const ah_value = root.get("algorithm_hash") orelse return error.InvalidShardManifest;
    const algorithm_hash: u64 = if (ah_value == .integer) blk: {
        if (ah_value.integer < 0) return error.InvalidShardManifest;
        break :blk @as(u64, @intCast(ah_value.integer));
    } else if (ah_value == .number_string)
        std.fmt.parseInt(u64, ah_value.number_string, 10) catch return error.InvalidShardManifest
    else
        return error.InvalidShardManifest;

    // Edge co-location (Phase B): the layout_version field is OPTIONAL for
    // backward compatibility. A pre-co-location manifest has no such key →
    // legacy layout 0 (migrate on open). A present value must be a non-negative
    // integer within u32.
    const layout_version: u32 = if (root.get("layout_version")) |lv| blk: {
        if (lv != .integer) return error.InvalidShardManifest;
        if (lv.integer < 0 or lv.integer > std.math.maxInt(u32)) return error.InvalidShardManifest;
        break :blk @as(u32, @intCast(lv.integer));
    } else 0;

    if (version != SHARD_MANIFEST_VERSION) return error.ShardManifestVersionMismatch;
    if (shard_count != shard_count_mod.SHARD_COUNT) return error.ShardCountMismatch;
    if (algorithm_hash != SHARD_ALGORITHM_HASH) return error.ShardAlgorithmMismatch;

    const uuids_node = root.get("per_shard_uuids") orelse return error.InvalidShardManifest;
    if (uuids_node != .array) return error.InvalidShardManifest;
    const arr = uuids_node.array;
    if (arr.items.len != shard_count_mod.SHARD_COUNT) return error.ShardCountMismatch;

    var per_shard: [shard_count_mod.SHARD_COUNT][16]u8 = undefined;
    for (arr.items, 0..) |item, i| {
        if (item != .string) return error.InvalidShardManifest;
        const hex = item.string;
        if (hex.len != 32) return error.InvalidShardUuid;
        var out: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidShardManifest;
        per_shard[i] = out;
    }

    return .{
        .version = version,
        .shard_count = shard_count,
        .algorithm_hash = algorithm_hash,
        .per_shard_uuids = per_shard,
        .layout_version = layout_version,
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

/// Write raw bytes to `<dir>/shard_manifest.json` using the same Io API
/// used by writeToDir, so malformed-JSON regression tests can inject
/// arbitrary content without going through the normal serialisation path.
fn writeRawManifest(dir_path: []const u8, content: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ dir_path, FILE_NAME });
    defer std.testing.allocator.free(file_path);
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "readFromDir rejects non-object root: integer literal" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try writeRawManifest(path, "5");
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects non-object root: array" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try writeRawManifest(path, "[]");
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects missing version key" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try writeRawManifest(path, "{\"shard_count\":16,\"algorithm_hash\":1,\"per_shard_uuids\":[]}");
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects string-typed version" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try writeRawManifest(path, "{\"version\":\"x\",\"shard_count\":16,\"algorithm_hash\":1,\"per_shard_uuids\":[]}");
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects negative version" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try writeRawManifest(path, "{\"version\":-1,\"shard_count\":16,\"algorithm_hash\":1,\"per_shard_uuids\":[]}");
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects version > maxInt(u32)" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try writeRawManifest(path, "{\"version\":4294967296,\"shard_count\":16,\"algorithm_hash\":1,\"per_shard_uuids\":[]}");
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects per_shard_uuids not an array" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":1,\"shard_count\":16,\"algorithm_hash\":{d},\"per_shard_uuids\":\"bad\"}}",
        .{sm.SHARD_ALGORITHM_HASH},
    );
    defer std.testing.allocator.free(payload);
    try writeRawManifest(path, payload);
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}

test "readFromDir rejects non-string element in per_shard_uuids" {
    const sm = @import("shard_manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    // Provide exactly 16 elements; the last one is an integer (42) instead of
    // a hex string so the per-element type guard fires rather than the
    // length check.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const header = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":1,\"shard_count\":16,\"algorithm_hash\":{d},\"per_shard_uuids\":[",
        .{sm.SHARD_ALGORITHM_HASH},
    );
    defer std.testing.allocator.free(header);
    try buf.appendSlice(std.testing.allocator, header);
    const valid_uuid = "\"00000000000000000000000000000000\",";
    for (0..15) |_| try buf.appendSlice(std.testing.allocator, valid_uuid);
    try buf.appendSlice(std.testing.allocator, "42]}");
    try writeRawManifest(path, buf.items);
    try std.testing.expectError(error.InvalidShardManifest, sm.readFromDir(std.testing.allocator, path));
}
