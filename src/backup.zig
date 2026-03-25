// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Per-graph backup and restore at checkpoint boundaries.
//!
//! Backup file format:
//!   GEOB (4 bytes magic)
//!   version (2 bytes LE)
//!   graph_uuid (16 bytes)
//!   file_count (4 bytes LE)
//!   --- repeated for each file ---
//!   filename_len (2 bytes LE)
//!   filename (variable)
//!   file_size (8 bytes LE)
//!   file_data (file_size bytes)
//!   --- end ---
//!   CRC32 (4 bytes, over everything above)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;

const graph_dir_mod = @import("graph_dir.zig");
const GraphDir = graph_dir_mod.GraphDir;

pub const BACKUP_MAGIC: [4]u8 = .{ 'G', 'E', 'O', 'B' };
pub const BACKUP_VERSION: u16 = 1;

/// Files to include in a backup.
const BACKUP_FILES = [_][]const u8{
    "manifest.a",
    "manifest.b",
    "nodes.store",
    "adj_out.store",
    "adj_in.store",
    "props.store",
    "var.store",
    "free.store",
    "labels.dict",
};

/// Optional files that may or may not exist.
const OPTIONAL_BACKUP_FILES = [_][]const u8{
    "indexes/catalog.bin",
};

/// Result of a backup operation.
pub const BackupResult = struct {
    graph_uuid: [16]u8,
    files_backed_up: u32,
    total_bytes: u64,
};

/// Per-graph backup and restore.
pub const Backup = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Backup {
        return .{ .allocator = allocator };
    }

    /// Create a backup of a graph directory.
    /// The backup is a simple archive: header + file entries.
    pub fn createBackup(self: *Backup, graph_dir: *const GraphDir, output_path: []const u8) !BackupResult {
        const out_file = try std.fs.cwd().createFile(output_path, .{});
        defer out_file.close();

        var crc = Crc32.init();
        var total_bytes: u64 = 0;
        var files_backed_up: u32 = 0;

        // Collect files that exist
        const FileEntry = struct {
            name: []const u8,
            data: []const u8,
        };
        var entries: std.ArrayList(FileEntry) = .{};
        defer {
            for (entries.items) |entry| {
                self.allocator.free(entry.data);
            }
            entries.deinit(self.allocator);
        }

        // Try required files
        for (BACKUP_FILES) |name| {
            if (try self.readGraphFile(graph_dir.path, name)) |data| {
                try entries.append(self.allocator, .{ .name = name, .data = data });
            }
        }

        // Try optional files
        for (OPTIONAL_BACKUP_FILES) |name| {
            if (try self.readGraphFile(graph_dir.path, name)) |data| {
                try entries.append(self.allocator, .{ .name = name, .data = data });
            }
        }

        // Write header: magic(4) + version(2) + uuid(16) + file_count(4)
        var header: [26]u8 = undefined;
        @memcpy(header[0..4], &BACKUP_MAGIC);
        @memcpy(header[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, BACKUP_VERSION)));
        @memcpy(header[6..22], &graph_dir.graph_uuid);
        @memcpy(header[22..26], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(entries.items.len)))));

        try out_file.writeAll(&header);
        crc.update(&header);
        total_bytes += header.len;

        // Write each file entry
        for (entries.items) |entry| {
            // filename_len (2 bytes)
            var name_len_buf: [2]u8 = undefined;
            @memcpy(&name_len_buf, &std.mem.toBytes(std.mem.nativeToLittle(u16, @as(u16, @intCast(entry.name.len)))));
            try out_file.writeAll(&name_len_buf);
            crc.update(&name_len_buf);
            total_bytes += 2;

            // filename
            try out_file.writeAll(entry.name);
            crc.update(entry.name);
            total_bytes += entry.name.len;

            // file_size (8 bytes)
            var size_buf: [8]u8 = undefined;
            @memcpy(&size_buf, &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, @intCast(entry.data.len)))));
            try out_file.writeAll(&size_buf);
            crc.update(&size_buf);
            total_bytes += 8;

            // file_data
            try out_file.writeAll(entry.data);
            crc.update(entry.data);
            total_bytes += entry.data.len;

            files_backed_up += 1;
        }

        // Write CRC32
        var crc_buf: [4]u8 = undefined;
        @memcpy(&crc_buf, &std.mem.toBytes(std.mem.nativeToLittle(u32, crc.final())));
        try out_file.writeAll(&crc_buf);
        total_bytes += 4;

        return .{
            .graph_uuid = graph_dir.graph_uuid,
            .files_backed_up = files_backed_up,
            .total_bytes = total_bytes,
        };
    }

    /// Restore a backup to a target directory.
    pub fn restoreBackup(self: *Backup, backup_path: []const u8, target_dir: []const u8) !void {
        const data = try self.readFileAlloc(backup_path);
        defer self.allocator.free(data);

        if (data.len < 30) return error.InvalidData; // header(26) + crc(4) minimum

        // Validate magic
        if (!std.mem.eql(u8, data[0..4], &BACKUP_MAGIC)) return error.InvalidMagic;

        // Validate CRC
        const stored_crc = std.mem.littleToNative(u32, @bitCast(data[data.len - 4 ..][0..4].*));
        const computed_crc = Crc32.hash(data[0 .. data.len - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // Parse header
        var pos: usize = 4; // skip magic
        _ = readU16(data, pos); // version
        pos += 2;
        pos += 16; // uuid

        const file_count = readU32(data, pos);
        pos += 4;

        // Ensure target directory exists
        try std.fs.cwd().makePath(target_dir);

        // Extract files
        var i: u32 = 0;
        while (i < file_count) : (i += 1) {
            if (pos + 2 > data.len - 4) return error.InvalidData;
            const name_len = readU16(data, pos);
            pos += 2;

            if (pos + name_len > data.len - 4) return error.InvalidData;
            const name = data[pos..][0..name_len];
            pos += name_len;

            if (pos + 8 > data.len - 4) return error.InvalidData;
            const file_size = readU64(data, pos);
            pos += 8;

            if (pos + file_size > data.len - 4) return error.InvalidData;
            const file_data = data[pos..][0..file_size];
            pos += file_size;

            // Create subdirectories if needed
            if (std.mem.lastIndexOfScalar(u8, name, '/')) |sep| {
                const subdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ target_dir, name[0..sep] });
                defer self.allocator.free(subdir_path);
                try std.fs.cwd().makePath(subdir_path);
            }

            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ target_dir, name });
            defer self.allocator.free(file_path);

            const file = try std.fs.cwd().createFile(file_path, .{});
            defer file.close();
            try file.writeAll(file_data);
        }
    }

    /// Validate a backup file's integrity (check header and CRC, don't extract).
    pub fn validateBackup(self: *Backup, backup_path: []const u8) !bool {
        const data = self.readFileAlloc(backup_path) catch return false;
        defer self.allocator.free(data);

        if (data.len < 30) return false;

        // Check magic
        if (!std.mem.eql(u8, data[0..4], &BACKUP_MAGIC)) return false;

        // Check version
        const version = readU16(data, 4);
        if (version != BACKUP_VERSION) return false;

        // Check CRC
        const stored_crc = std.mem.littleToNative(u32, @bitCast(data[data.len - 4 ..][0..4].*));
        const computed_crc = Crc32.hash(data[0 .. data.len - 4]);
        return stored_crc == computed_crc;
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn readGraphFile(self: *Backup, graph_path: []const u8, name: []const u8) !?[]const u8 {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_path, name });
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            self.allocator.free(data);
            return error.InvalidData;
        }

        return data;
    }

    fn readFileAlloc(self: *Backup, path: []const u8) ![]u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            self.allocator.free(data);
            return error.InvalidData;
        }

        return data;
    }
};

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.littleToNative(u16, @bitCast(data[offset..][0..2].*));
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.littleToNative(u64, @bitCast(data[offset..][0..8].*));
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const file_manager = @import("file_manager.zig");

fn createTestGraphDir(allocator: Allocator) !struct { tmp_dir: testing.TmpDir, graph_dir: GraphDir } {
    var tmp_dir = testing.tmpDir(.{});
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x42);

    const gd = try GraphDir.create(allocator, tmp_path, uuid);
    return .{ .tmp_dir = tmp_dir, .graph_dir = gd };
}

test "createBackup produces file with correct magic" {
    const allocator = testing.allocator;

    var env = try createTestGraphDir(allocator);
    defer {
        env.graph_dir.deinit();
        env.tmp_dir.cleanup();
    }

    // Create output path
    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_path_base = try out_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(out_path_base);

    const out_path = try std.fmt.allocPrint(allocator, "{s}/backup.geob", .{out_path_base});
    defer allocator.free(out_path);

    var backup = Backup.init(allocator);
    const result = try backup.createBackup(&env.graph_dir, out_path);

    try testing.expect(result.files_backed_up > 0);
    try testing.expect(result.total_bytes > 0);

    // Verify magic bytes
    const file = try std.fs.cwd().openFile(out_path, .{});
    defer file.close();
    var magic: [4]u8 = undefined;
    _ = try file.readAll(&magic);
    try testing.expectEqual(BACKUP_MAGIC, magic);
}

test "restoreBackup restores files to new directory" {
    const allocator = testing.allocator;

    var env = try createTestGraphDir(allocator);
    defer {
        env.graph_dir.deinit();
        env.tmp_dir.cleanup();
    }

    // Write some data to a store file
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{env.graph_dir.path});
    defer allocator.free(nodes_path);
    {
        const f = try std.fs.cwd().openFile(nodes_path, .{ .mode = .write_only });
        defer f.close();
        try f.writeAll("test node data");
    }

    // Create backup
    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_path_base = try out_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(out_path_base);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup.geob", .{out_path_base});
    defer allocator.free(backup_path);

    var backup = Backup.init(allocator);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    // Restore to new directory
    const restore_path = try std.fmt.allocPrint(allocator, "{s}/restored", .{out_path_base});
    defer allocator.free(restore_path);

    try backup.restoreBackup(backup_path, restore_path);

    // Verify nodes.store was restored with correct content
    const restored_nodes = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{restore_path});
    defer allocator.free(restored_nodes);

    const file = try std.fs.cwd().openFile(restored_nodes, .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expectEqualStrings("test node data", buf[0..n]);
}

test "validateBackup returns true for valid backup" {
    const allocator = testing.allocator;

    var env = try createTestGraphDir(allocator);
    defer {
        env.graph_dir.deinit();
        env.tmp_dir.cleanup();
    }

    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_path_base = try out_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(out_path_base);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup.geob", .{out_path_base});
    defer allocator.free(backup_path);

    var backup = Backup.init(allocator);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    const valid = try backup.validateBackup(backup_path);
    try testing.expect(valid);
}

test "validateBackup returns false for corrupted file" {
    const allocator = testing.allocator;

    var env = try createTestGraphDir(allocator);
    defer {
        env.graph_dir.deinit();
        env.tmp_dir.cleanup();
    }

    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_path_base = try out_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(out_path_base);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup.geob", .{out_path_base});
    defer allocator.free(backup_path);

    var backup = Backup.init(allocator);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    // Corrupt the file
    {
        const file = try std.fs.cwd().openFile(backup_path, .{ .mode = .write_only });
        defer file.close();
        try file.seekTo(10);
        try file.writeAll("CORRUPT");
    }

    const valid = try backup.validateBackup(backup_path);
    try testing.expect(!valid);
}

test "validateBackup returns false for nonexistent file" {
    const allocator = testing.allocator;
    var backup = Backup.init(allocator);
    const valid = try backup.validateBackup("/tmp/nonexistent_backup_12345.geob");
    try testing.expect(!valid);
}

test {
    std.testing.refAllDecls(@This());
}
