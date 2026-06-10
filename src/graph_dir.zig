// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const file_manager = @import("file_manager.zig");

const Allocator = std.mem.Allocator;
const FileId = types.FileId;

pub const GraphDir = struct {
    allocator: Allocator,
    path: []const u8, // owned path to graph directory
    graph_uuid: [16]u8,

    pub const ManifestSlot = enum { a, b };

    /// Create a new graph directory at data_dir/graphs/<uuid_hex>/
    /// Creates the directory and empty store files.
    pub fn create(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) !GraphDir {
        const uuid_hex = formatUuidHex(graph_uuid);
        const path = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}", .{ data_dir, uuid_hex });
        errdefer allocator.free(path);

        // Create directory (including parents) and restrict to owner-only access
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
        const io = std.Io.Threaded.global_single_threaded.io();
        {
            var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            defer dir.close(io);
            dir.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {};
        }

        // Create empty store files.
        // SEC-0052: resolve_beneath prevents symlink / TOCTOU traversal out of
        // the graph directory.  exclusive = true is appropriate here because
        // these are brand-new files that must not already exist.
        for (file_manager.FILE_NAMES) |file_name| {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, file_name });
            defer allocator.free(file_path);

            const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
                .permissions = std.Io.File.Permissions.fromMode(0o600),
                .exclusive = true,
                .resolve_beneath = true,
            });
            file.close(io);
        }

        return .{
            .allocator = allocator,
            .path = path,
            .graph_uuid = graph_uuid,
        };
    }

    /// Open an existing graph directory.
    pub fn open(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) !GraphDir {
        const uuid_hex = formatUuidHex(graph_uuid);
        const path = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}", .{ data_dir, uuid_hex });
        errdefer allocator.free(path);

        // Verify the directory exists
        var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), path, .{});
        dir.close(std.Io.Threaded.global_single_threaded.io());

        return .{
            .allocator = allocator,
            .path = path,
            .graph_uuid = graph_uuid,
        };
    }

    /// Get the path to a store file.
    pub fn storePath(self: *const GraphDir, allocator: Allocator, file_id: FileId) ![]u8 {
        const idx = @intFromEnum(file_id);
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.path, file_manager.FILE_NAMES[idx] });
    }

    /// Get path to manifest.a or manifest.b
    pub fn manifestPath(self: *const GraphDir, allocator: Allocator, slot: ManifestSlot) ![]u8 {
        const suffix: []const u8 = switch (slot) {
            .a => "manifest.a",
            .b => "manifest.b",
        };
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.path, suffix });
    }

    /// Delete the graph directory and all contents.
    ///
    /// SEC-0008: Security contract -- `data_dir` (provided at create/open time) MUST
    /// be a trusted, application-controlled path. This method calls `deleteTree` on
    /// `<data_dir>/graphs/<uuid_hex>`. If `data_dir` is user-influenced without
    /// validation, an attacker could cause deletion of arbitrary directories.
    ///
    /// Callers MUST ensure:
    ///   - `data_dir` is not derived from untrusted user input, OR
    ///   - `data_dir` has been validated against an allowlist before use.
    ///
    /// The path is further constrained by the `graphs/<uuid_hex>` suffix, which
    /// limits the blast radius even if `data_dir` is partially user-controlled.
    pub fn delete(self: *const GraphDir) !void {
        // Validate that the path contains the expected graphs/<uuid> structure
        // before performing the destructive deleteTree operation.
        if (!self.hasExpectedPathStructure()) return error.InvalidGraphPath;
        try std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), self.path);
    }

    /// Verify the path contains the expected /graphs/<32-hex-chars> suffix.
    fn hasExpectedPathStructure(self: *const GraphDir) bool {
        const path = self.path;
        // Find the last occurrence of "/graphs/"
        const marker = "/graphs/";
        const idx = std.mem.lastIndexOf(u8, path, marker) orelse return false;
        const after = path[idx + marker.len ..];
        // After "/graphs/" we expect exactly 32 hex characters (the UUID)
        if (after.len != 32) return false;
        for (after) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }

    pub fn deinit(self: *GraphDir) void {
        self.allocator.free(self.path);
    }
};

/// Format a 16-byte UUID as lowercase hex (32 chars, no dashes).
fn formatUuidHex(uuid: [16]u8) [32]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [32]u8 = undefined;
    for (uuid, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    return result;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "create graph dir, verify directory exists on disk" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x42);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Verify directory exists
    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), gd.path, .{});
    dir.close(std.Io.Threaded.global_single_threaded.io());

    // Verify store files exist
    for (file_manager.FILE_NAMES) |file_name| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gd.path, file_name });
        defer allocator.free(file_path);
        var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
        file.close(std.Io.Threaded.global_single_threaded.io());
    }
}

test "storePath returns correct paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x01);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    const nodes_path = try gd.storePath(allocator, .nodes);
    defer allocator.free(nodes_path);

    try std.testing.expect(std.mem.endsWith(u8, nodes_path, "nodes.store"));

    const adj_path = try gd.storePath(allocator, .adj_out);
    defer allocator.free(adj_path);

    try std.testing.expect(std.mem.endsWith(u8, adj_path, "adj_out.store"));
}

test "manifestPath returns correct paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x02);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try std.testing.expect(std.mem.endsWith(u8, path_a, "manifest.a"));

    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try std.testing.expect(std.mem.endsWith(u8, path_b, "manifest.b"));
}

test "delete removes directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x03);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    try gd.delete();

    // Verify directory no longer exists
    const result = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), gd.path, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "formatUuidHex produces correct output" {
    const uuid = [16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    const hex = formatUuidHex(uuid);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &hex);
}

test "created store files have mode 0o600 and directory has mode 0o700" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xEE);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Verify directory has 0o700
    {
        var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), gd.path, .{});
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        const stat = try dir.stat(std.Io.Threaded.global_single_threaded.io());
        const perm = stat.permissions.toMode() & 0o7777;
        try std.testing.expectEqual(@as(u32, 0o700), perm);
    }

    // Verify each store file has 0o600
    for (file_manager.FILE_NAMES) |file_name| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gd.path, file_name });
        defer allocator.free(file_path);

        const stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
        const perm = stat.permissions.toMode() & 0o7777;
        try std.testing.expectEqual(@as(u32, 0o600), perm);
    }
}

test {
    std.testing.refAllDecls(@This());
}
