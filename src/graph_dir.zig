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

        // Create directory (including parents)
        try std.fs.cwd().makePath(path);

        // Create empty store files
        for (file_manager.FILE_NAMES) |file_name| {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, file_name });
            defer allocator.free(file_path);

            const file = try std.fs.cwd().createFile(file_path, .{});
            file.close();
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
        var dir = try std.fs.cwd().openDir(path, .{});
        dir.close();

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
    pub fn delete(self: *const GraphDir) !void {
        try std.fs.cwd().deleteTree(self.path);
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

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x42);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Verify directory exists
    var dir = try std.fs.cwd().openDir(gd.path, .{});
    dir.close();

    // Verify store files exist
    for (file_manager.FILE_NAMES) |file_name| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gd.path, file_name });
        defer allocator.free(file_path);
        var file = try std.fs.cwd().openFile(file_path, .{});
        file.close();
    }
}

test "storePath returns correct paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
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

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
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

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x03);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    try gd.delete();

    // Verify directory no longer exists
    const result = std.fs.cwd().openDir(gd.path, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "formatUuidHex produces correct output" {
    const uuid = [16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    const hex = formatUuidHex(uuid);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &hex);
}

test {
    std.testing.refAllDecls(@This());
}
