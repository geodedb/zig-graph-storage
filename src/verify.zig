// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

const page_mod = @import("page.zig");
const manifest_mod = @import("manifest.zig");
const graph_dir_mod = @import("graph_dir.zig");
const file_manager_mod = @import("file_manager.zig");
const integrity_mod = @import("integrity.zig");
const types = @import("types.zig");

const Manifest = manifest_mod.Manifest;
const GraphDir = graph_dir_mod.GraphDir;
const Integrity = integrity_mod.Integrity;
const FileId = types.FileId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

pub const VerifyResult = struct {
    total_pages_checked: u64 = 0,
    corrupted_pages: u64 = 0,
    manifest_valid: bool = false,
    errors: std.ArrayList([]const u8) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) VerifyResult {
        return .{
            .allocator = allocator,
        };
    }

    pub fn isClean(self: *const VerifyResult) bool {
        return self.corrupted_pages == 0 and self.manifest_valid;
    }

    pub fn addError(self: *VerifyResult, msg: []const u8) !void {
        try self.errors.append(self.allocator, msg);
    }

    /// Write the result as a JSON object to the provided writer.
    pub fn writeJson(self: *const VerifyResult, writer: anytype) !void {
        try writer.print(
            "{{\"total_pages_checked\":{d},\"corrupted_pages\":{d},\"manifest_valid\":{},\"is_clean\":{},\"error_count\":{d}}}",
            .{
                self.total_pages_checked,
                self.corrupted_pages,
                self.manifest_valid,
                self.isClean(),
                self.errors.items.len,
            },
        );
    }

    pub fn deinit(self: *VerifyResult) void {
        for (self.errors.items) |msg| {
            self.allocator.free(msg);
        }
        self.errors.deinit(self.allocator);
    }
};

pub const VerifyTool = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VerifyTool {
        return .{ .allocator = allocator };
    }

    /// Verify a graph's integrity by checking:
    /// 1. Manifest A/B validity
    /// 2. All page checksums in each store file
    /// 3. Graph UUID consistency
    pub fn verifyGraph(self: *VerifyTool, graph_dir: *const GraphDir, page_size: u32) !VerifyResult {
        var result = VerifyResult.init(self.allocator);
        errdefer result.deinit();

        // 1. Verify manifests
        try self.verifyManifests(graph_dir, &result);

        // 2. Verify all store files
        const file_ids = [_]FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .free };
        for (file_ids) |file_id| {
            try self.verifyStoreFile(graph_dir, file_id, page_size, &result);
        }

        return result;
    }

    fn verifyManifests(self: *VerifyTool, graph_dir: *const GraphDir, result: *VerifyResult) !void {
        var any_valid = false;

        // Check manifest A
        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);

        if (Manifest.readFromFile(self.allocator, path_a) catch null) |m| {
            if (Integrity.verifyManifest(&m, self.allocator)) {
                any_valid = true;
            } else {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.a: checksum invalid", .{});
                try result.addError(msg);
            }
        }

        // Check manifest B
        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        if (Manifest.readFromFile(self.allocator, path_b) catch null) |m| {
            if (Integrity.verifyManifest(&m, self.allocator)) {
                any_valid = true;
            } else {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.b: checksum invalid", .{});
                try result.addError(msg);
            }
        }

        result.manifest_valid = any_valid;
        if (!any_valid) {
            const msg = try std.fmt.allocPrint(self.allocator, "no valid manifest found", .{});
            try result.addError(msg);
        }
    }

    fn verifyStoreFile(
        self: *VerifyTool,
        graph_dir: *const GraphDir,
        file_id: FileId,
        page_size: u32,
        result: *VerifyResult,
    ) !void {
        const store_path = try graph_dir.storePath(self.allocator, file_id);
        defer self.allocator.free(store_path);

        const file = std.fs.cwd().openFile(store_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return;

        const page_count = stat.size / page_size;
        const buf = try self.allocator.alloc(u8, page_size);
        defer self.allocator.free(buf);

        var page_idx: u64 = 0;
        while (page_idx < page_count) : (page_idx += 1) {
            const offset = page_idx * @as(u64, page_size);
            const bytes_read = try file.preadAll(buf, offset);

            if (bytes_read < page_size) break;

            result.total_pages_checked += 1;

            if (!Integrity.verifyPage(buf)) {
                result.corrupted_pages += 1;
                const file_name = file_manager_mod.FILE_NAMES[@intFromEnum(file_id)];
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}: page {d} checksum mismatch",
                    .{ file_name, page_idx },
                );
                try result.addError(msg);
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "clean graph passes verification" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x55);

    // Create graph directory with store files
    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Write a valid manifest to slot A
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);

    // Write a valid page to nodes.store
    const page_size: u32 = 4096;
    const store_path = try gd.storePath(allocator, .nodes);
    defer allocator.free(store_path);

    const store_file = try std.fs.cwd().createFile(store_path, .{
        .read = true,
        .truncate = true,
    });
    defer store_file.close();

    var page_buf: [4096]u8 = undefined;
    @memset(&page_buf, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(page_buf[0..PAGE_HEADER_SIZE], header_bytes);
    @memset(page_buf[PAGE_HEADER_SIZE..], 0xAA);

    // Compute and store checksum
    const checksum = page_mod.computeChecksum(page_buf[PAGE_HEADER_SIZE..]);
    std.mem.writeInt(u32, page_buf[16..20], checksum, .little);

    try store_file.pwriteAll(&page_buf, 0);

    // Verify
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, page_size);
    defer result.deinit();

    try testing.expect(result.isClean());
    try testing.expect(result.manifest_valid);
    try testing.expectEqual(@as(u64, 0), result.corrupted_pages);
    try testing.expect(result.total_pages_checked >= 1);
}

test "corrupted page detected" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x66);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Write valid manifest
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);

    // Write a valid page then corrupt it
    const page_size: u32 = 4096;
    const store_path = try gd.storePath(allocator, .nodes);
    defer allocator.free(store_path);

    const store_file = try std.fs.cwd().createFile(store_path, .{
        .read = true,
        .truncate = true,
    });
    defer store_file.close();

    var page_buf: [4096]u8 = undefined;
    @memset(&page_buf, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(page_buf[0..PAGE_HEADER_SIZE], header_bytes);
    @memset(page_buf[PAGE_HEADER_SIZE..], 0xBB);

    // Compute and store correct checksum first
    const checksum = page_mod.computeChecksum(page_buf[PAGE_HEADER_SIZE..]);
    std.mem.writeInt(u32, page_buf[16..20], checksum, .little);

    // Now corrupt a body byte AFTER computing checksum
    page_buf[PAGE_HEADER_SIZE + 50] = 0xFF;

    try store_file.pwriteAll(&page_buf, 0);

    // Verify — should detect corruption
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, page_size);
    defer result.deinit();

    try testing.expect(!result.isClean());
    try testing.expectEqual(@as(u64, 1), result.corrupted_pages);
    try testing.expect(result.errors.items.len >= 1);
}

test "empty graph with manifest passes" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x77);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Write valid manifest, no pages in store files
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);

    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(result.isClean());
    try testing.expectEqual(@as(u64, 0), result.total_pages_checked);
}

test "no manifest fails verification" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x88);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // No manifest written — just empty store files
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(!result.isClean());
    try testing.expect(!result.manifest_valid);
}

test "VerifyResult writeJson produces valid structured output" {
    const allocator = testing.allocator;
    var result = VerifyResult.init(allocator);
    defer result.deinit();

    result.total_pages_checked = 42;
    result.corrupted_pages = 0;
    result.manifest_valid = true;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try result.writeJson(buf.writer(allocator));
    const json = buf.items;

    // Verify key fields present
    try testing.expect(std.mem.indexOf(u8, json, "\"total_pages_checked\":42") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"corrupted_pages\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"manifest_valid\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_clean\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error_count\":0") != null);
}

test "VerifyResult writeJson reports unclean state" {
    const allocator = testing.allocator;
    var result = VerifyResult.init(allocator);
    defer result.deinit();

    result.total_pages_checked = 10;
    result.corrupted_pages = 2;
    result.manifest_valid = false;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try result.writeJson(buf.writer(allocator));
    const json = buf.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"is_clean\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"corrupted_pages\":2") != null);
}

test {
    std.testing.refAllDecls(@This());
}
