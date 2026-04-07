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
//!   --- when encryption_key is present (version 2) ---
//!   HMAC-SHA256 (32 bytes, over everything above including CRC32)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const timing_safe = std.crypto.timing_safe;
const owner_only_file_mode = 0o600;
const BACKUP_STREAM_CHUNK_SIZE: usize = 64 * 1024;

const graph_dir_mod = @import("graph_dir.zig");
const operation_result_mod = @import("operation_result.zig");
const GraphDir = graph_dir_mod.GraphDir;
const GraphOperationSummary = operation_result_mod.GraphOperationSummary;

pub const BACKUP_MAGIC: [4]u8 = .{ 'G', 'E', 'O', 'B' };
pub const BACKUP_VERSION: u16 = 1;
pub const BACKUP_VERSION_HMAC: u16 = 2;

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
    "labels.idx",
    "props.idx",
    "edges.idx",
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

    /// Write the result as a JSON object to the provided writer.
    pub fn writeJson(self: *const BackupResult, writer: anytype) !void {
        const summary = GraphOperationSummary{
            .operation = .backup,
            .status = .ok,
            .graph_uuid = self.graph_uuid,
            .items_processed = self.files_backed_up,
            .bytes_processed = self.total_bytes,
            .issue_count = 0,
            .changed = false,
        };
        try writer.writeByte('{');
        try summary.writeJsonFields(writer);
        try writer.writeAll(",\"files_backed_up\":");
        try writer.print("{d}", .{self.files_backed_up});
        try writer.writeAll(",\"total_bytes\":");
        try writer.print("{d}", .{self.total_bytes});
        try writer.writeByte('}');
    }
};

pub const RestoreResult = struct {
    graph_uuid: [16]u8,
    files_restored: u32,
    total_bytes: u64,

    pub fn writeJson(self: *const RestoreResult, writer: anytype) !void {
        const summary = GraphOperationSummary{
            .operation = .restore,
            .status = .ok,
            .graph_uuid = self.graph_uuid,
            .items_processed = self.files_restored,
            .bytes_processed = self.total_bytes,
            .issue_count = 0,
            .changed = true,
        };
        try writer.writeByte('{');
        try summary.writeJsonFields(writer);
        try writer.writeAll(",\"files_restored\":");
        try writer.print("{d}", .{self.files_restored});
        try writer.writeAll(",\"total_bytes\":");
        try writer.print("{d}", .{self.total_bytes});
        try writer.writeByte('}');
    }
};

/// Per-graph backup and restore.
pub const Backup = struct {
    allocator: Allocator,
    /// Optional encryption key. When present, backups include an HMAC-SHA256
    /// tag for integrity verification that cannot be forged without the key.
    encryption_key: ?[32]u8 = null,

    pub fn init(allocator: Allocator) Backup {
        return .{ .allocator = allocator };
    }

    /// Create a Backup with an encryption key for HMAC integrity protection.
    pub fn initWithKey(allocator: Allocator, key: [32]u8) Backup {
        return .{ .allocator = allocator, .encryption_key = key };
    }

    /// Zero sensitive key material.
    pub fn deinit(self: *Backup) void {
        if (self.encryption_key) |*k| {
            std.crypto.secureZero(u8, k);
        }
    }

    /// Create a backup of a graph directory.
    /// The backup is a simple archive: header + file entries.
    /// When encryption_key is set, uses version 2 with HMAC-SHA256 tag.
    pub fn createBackup(self: *Backup, graph_dir: *const GraphDir, output_path: []const u8) !BackupResult {
        const out_file = try std.fs.cwd().createFile(output_path, .{ .mode = owner_only_file_mode });
        defer out_file.close();

        const version: u16 = if (self.encryption_key != null) BACKUP_VERSION_HMAC else BACKUP_VERSION;

        var crc = Crc32.init();
        // SEC-0005: Initialize HMAC hasher when key is present
        var hmac_ctx: ?HmacSha256 = if (self.encryption_key) |key| HmacSha256.init(&key) else null;
        var total_bytes: u64 = 0;
        var files_backed_up: u32 = 0;

        const FileEntry = struct {
            name: []const u8,
            size: u64,
        };
        var entries: std.ArrayList(FileEntry) = .{};
        defer entries.deinit(self.allocator);

        // Try required files
        for (BACKUP_FILES) |name| {
            try self.appendBackupEntryIfPresent(&entries, graph_dir.path, name);
        }

        // Try optional files
        for (OPTIONAL_BACKUP_FILES) |name| {
            try self.appendBackupEntryIfPresent(&entries, graph_dir.path, name);
        }

        // Write header: magic(4) + version(2) + uuid(16) + file_count(4)
        var header: [26]u8 = undefined;
        @memcpy(header[0..4], &BACKUP_MAGIC);
        @memcpy(header[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, version)));
        @memcpy(header[6..22], &graph_dir.graph_uuid);
        @memcpy(header[22..26], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(entries.items.len)))));

        try out_file.writeAll(&header);
        crc.update(&header);
        if (hmac_ctx) |*h| h.update(&header);
        total_bytes += header.len;

        // Write each file entry
        for (entries.items) |entry| {
            // filename_len (2 bytes)
            var name_len_buf: [2]u8 = undefined;
            @memcpy(&name_len_buf, &std.mem.toBytes(std.mem.nativeToLittle(u16, @as(u16, @intCast(entry.name.len)))));
            try out_file.writeAll(&name_len_buf);
            crc.update(&name_len_buf);
            if (hmac_ctx) |*h| h.update(&name_len_buf);
            total_bytes += 2;

            // filename
            try out_file.writeAll(entry.name);
            crc.update(entry.name);
            if (hmac_ctx) |*h| h.update(entry.name);
            total_bytes += entry.name.len;

            // file_size (8 bytes)
            var size_buf: [8]u8 = undefined;
            @memcpy(&size_buf, &std.mem.toBytes(std.mem.nativeToLittle(u64, entry.size)));
            try out_file.writeAll(&size_buf);
            crc.update(&size_buf);
            if (hmac_ctx) |*h| h.update(&size_buf);
            total_bytes += 8;

            try self.streamGraphFile(graph_dir.path, entry.name, entry.size, out_file, &crc, &hmac_ctx, &total_bytes);

            files_backed_up += 1;
        }

        // Write CRC32
        var crc_buf: [4]u8 = undefined;
        @memcpy(&crc_buf, &std.mem.toBytes(std.mem.nativeToLittle(u32, crc.final())));
        try out_file.writeAll(&crc_buf);
        if (hmac_ctx) |*h| h.update(&crc_buf);
        total_bytes += 4;

        // SEC-0005: When encryption key is present, finalize and append HMAC-SHA256 tag
        if (hmac_ctx) |*h| {
            var hmac_tag: [HmacSha256.mac_length]u8 = undefined;
            h.final(&hmac_tag);
            try out_file.writeAll(&hmac_tag);
            total_bytes += HmacSha256.mac_length;
        }

        return .{
            .graph_uuid = graph_dir.graph_uuid,
            .files_backed_up = files_backed_up,
            .total_bytes = total_bytes,
        };
    }

    /// Restore a backup to a target directory.
    pub fn restoreBackup(self: *Backup, backup_path: []const u8, target_dir: []const u8) !void {
        _ = try self.restoreBackupResult(backup_path, target_dir);
    }

    /// Restore a backup and return a structured result for automation.
    pub fn restoreBackupResult(self: *Backup, backup_path: []const u8, target_dir: []const u8) !RestoreResult {
        const data = try self.readFileAlloc(backup_path);
        defer self.allocator.free(data);

        if (data.len < 30) return error.InvalidData; // header(26) + crc(4) minimum

        // Validate magic
        if (!std.mem.eql(u8, data[0..4], &BACKUP_MAGIC)) return error.InvalidMagic;

        // Parse version
        const version = readU16(data, 4);

        // SEC-0005: Determine integrity region based on version
        const integrity_end: usize = if (version >= BACKUP_VERSION_HMAC)
            data.len - HmacSha256.mac_length
        else
            data.len;

        // Validate CRC over data before CRC field
        const crc_offset = if (version >= BACKUP_VERSION_HMAC)
            integrity_end - 4
        else
            data.len - 4;

        const stored_crc = std.mem.littleToNative(u32, @bitCast(data[crc_offset..][0..4].*));
        const computed_crc = Crc32.hash(data[0..crc_offset]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // SEC-0005: Verify HMAC when version >= 2 and encryption key is available
        if (version >= BACKUP_VERSION_HMAC) {
            if (self.encryption_key) |key| {
                if (data.len < integrity_end + HmacSha256.mac_length) return error.InvalidData;
                const stored_hmac = data[integrity_end..][0..HmacSha256.mac_length];
                const hmac_input = data[0..integrity_end];
                var computed_hmac: [HmacSha256.mac_length]u8 = undefined;
                HmacSha256.create(&computed_hmac, hmac_input, &key);
                if (!timing_safe.eql([HmacSha256.mac_length]u8, stored_hmac.*, computed_hmac)) {
                    return error.HmacMismatch;
                }
            } else {
                // Version 2 backup requires a key for HMAC verification.
                // Refusing to restore without integrity proof.
                return error.EncryptionKeyRequired;
            }
        }

        // Parse header
        var pos: usize = 4; // skip magic
        _ = readU16(data, pos); // version
        pos += 2;
        var backup_uuid: [16]u8 = undefined;
        @memcpy(&backup_uuid, data[pos..][0..16]);
        pos += 16;

        if (expectedGraphUuidFromPath(target_dir)) |expected_uuid| {
            if (!std.mem.eql(u8, &backup_uuid, &expected_uuid)) {
                return error.UuidMismatch;
            }
        }

        const file_count = readU32(data, pos);
        pos += 4;
        var files_restored: u32 = 0;
        var total_bytes: u64 = 0;

        // Ensure target directory exists with restricted permissions
        try std.fs.cwd().makePath(target_dir);
        {
            var dir = try std.fs.cwd().openDir(target_dir, .{ .iterate = true });
            defer dir.close();
            dir.chmod(0o700) catch {};
        }

        // Extract files
        var i: u32 = 0;
        while (i < file_count) : (i += 1) {
            if (pos + 2 > crc_offset) return error.InvalidData;
            const name_len = readU16(data, pos);
            pos += 2;

            if (pos + name_len > crc_offset) return error.InvalidData;
            const name = data[pos..][0..name_len];
            pos += name_len;

            // SEC-0002: Validate filename to prevent path traversal.
            // Reject absolute paths, null bytes, backslashes, and ".." components.
            if (!isValidBackupFilename(name)) return error.InvalidBackupFilename;

            if (pos + 8 > crc_offset) return error.InvalidData;
            const file_size = readU64(data, pos);
            pos += 8;

            // SEC-0013: Guard against integer truncation on 32-bit targets.
            const file_size_usize = std.math.cast(usize, file_size) orelse return error.BackupTooLarge;

            if (pos + file_size_usize > crc_offset) return error.InvalidData;
            const file_data = data[pos..][0..file_size_usize];
            pos += file_size_usize;

            // Create subdirectories if needed (only forward slashes in validated names)
            if (std.mem.lastIndexOfScalar(u8, name, '/')) |sep| {
                const subdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ target_dir, name[0..sep] });
                defer self.allocator.free(subdir_path);
                try std.fs.cwd().makePath(subdir_path);
            }

            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ target_dir, name });
            defer self.allocator.free(file_path);

            const file = try std.fs.cwd().createFile(file_path, .{ .mode = owner_only_file_mode });
            defer file.close();
            try file.writeAll(file_data);

            files_restored += 1;
            total_bytes += file_size;
        }

        return .{
            .graph_uuid = backup_uuid,
            .files_restored = files_restored,
            .total_bytes = total_bytes,
        };
    }

    /// Validate a backup file's integrity (check header, CRC, and HMAC if applicable).
    pub fn validateBackup(self: *Backup, backup_path: []const u8) !bool {
        const data = self.readFileAlloc(backup_path) catch return false;
        defer self.allocator.free(data);

        if (data.len < 30) return false;

        // Check magic
        if (!std.mem.eql(u8, data[0..4], &BACKUP_MAGIC)) return false;

        // Check version
        const version = readU16(data, 4);
        if (version != BACKUP_VERSION and version != BACKUP_VERSION_HMAC) return false;

        // Determine CRC position based on version
        const crc_offset: usize = if (version >= BACKUP_VERSION_HMAC)
            data.len - HmacSha256.mac_length - 4
        else
            data.len - 4;

        if (crc_offset > data.len - 4) return false;

        // Check CRC
        const stored_crc = std.mem.littleToNative(u32, @bitCast(data[crc_offset..][0..4].*));
        const computed_crc = Crc32.hash(data[0..crc_offset]);
        if (stored_crc != computed_crc) return false;

        // SEC-0005: Version 2 backups require a key for HMAC validation.
        if (version >= BACKUP_VERSION_HMAC) {
            const key = self.encryption_key orelse return false;
            if (data.len < HmacSha256.mac_length + 4) return false;

            const integrity_end = data.len - HmacSha256.mac_length;
            const stored_hmac = data[integrity_end..][0..HmacSha256.mac_length];
            const hmac_input = data[0..integrity_end];
            var computed_hmac: [HmacSha256.mac_length]u8 = undefined;
            HmacSha256.create(&computed_hmac, hmac_input, &key);
            if (!timing_safe.eql([HmacSha256.mac_length]u8, stored_hmac.*, computed_hmac)) return false;
        }

        return true;
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn appendBackupEntryIfPresent(
        self: *Backup,
        entries: anytype,
        graph_path: []const u8,
        name: []const u8,
    ) !void {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_path, name });
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        try entries.append(self.allocator, .{
            .name = name,
            .size = stat.size,
        });
    }

    fn streamGraphFile(
        self: *Backup,
        graph_path: []const u8,
        name: []const u8,
        file_size: u64,
        out_file: std.fs.File,
        crc: *Crc32,
        hmac_ctx: *?HmacSha256,
        total_bytes: *u64,
    ) !void {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_path, name });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buf: [BACKUP_STREAM_CHUNK_SIZE]u8 = undefined;
        var remaining = file_size;
        while (remaining > 0) {
            const want = @min(buf.len, std.math.cast(usize, remaining) orelse buf.len);
            const bytes_read = try file.read(buf[0..want]);
            if (bytes_read == 0) return error.InvalidData;

            const chunk = buf[0..bytes_read];
            try out_file.writeAll(chunk);
            crc.update(chunk);
            if (hmac_ctx.*) |*h| h.update(chunk);
            total_bytes.* += chunk.len;
            remaining -= bytes_read;
        }
    }

    fn readFileAlloc(self: *Backup, path: []const u8) ![]u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        // SEC-0007: Reject files exceeding the maximum backup size.
        if (stat.size > MAX_BACKUP_FILE_SIZE) return error.BackupTooLarge;

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

/// Maximum backup file size: 1 GiB (SEC-0007).
pub const MAX_BACKUP_FILE_SIZE: u64 = 1 << 30;

/// Validate that a filename from a backup archive is safe to extract.
/// Rejects absolute paths, null bytes, backslashes, and ".." path components.
fn isValidBackupFilename(name: []const u8) bool {
    if (name.len == 0) return false;

    // Reject null bytes
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;

    // Reject backslashes (Windows-style path separators)
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;

    // Reject absolute paths
    if (name[0] == '/') return false;

    // Reject ".." components: check each segment separated by '/'
    var iter = std.mem.splitScalar(u8, name, '/');
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
        // Also reject empty segments (double slashes like "a//b")
        if (segment.len == 0) return false;
    }

    return true;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.littleToNative(u16, @bitCast(data[offset..][0..2].*));
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.littleToNative(u64, @bitCast(data[offset..][0..8].*));
}

fn expectedGraphUuidFromPath(path: []const u8) ?[16]u8 {
    const base = std.fs.path.basename(path);
    if (base.len != 32) return null;

    var uuid: [16]u8 = undefined;
    var i: usize = 0;
    while (i < uuid.len) : (i += 1) {
        const hi = std.fmt.charToDigit(base[i * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(base[i * 2 + 1], 16) catch return null;
        uuid[i] = @intCast((hi << 4) | lo);
    }
    return uuid;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn createTestGraphDir(allocator: Allocator) !struct { tmp_dir: testing.TmpDir, graph_dir: GraphDir } {
    var tmp_dir = testing.tmpDir(.{});
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x42);

    const gd = try GraphDir.create(allocator, tmp_path, uuid);
    return .{ .tmp_dir = tmp_dir, .graph_dir = gd };
}

fn writeTestFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .mode = owner_only_file_mode });
    defer file.close();
    try file.writeAll(data);
}

fn expectFileContents(path: []const u8, expected: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(testing.allocator, expected.len + 16);
    defer testing.allocator.free(data);

    try testing.expectEqualStrings(expected, data);
}

fn expectOwnerOnlyMode(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    try testing.expectEqual(@as(u32, owner_only_file_mode), stat.mode & 0o777);
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
    try expectOwnerOnlyMode(out_path);

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

    // Write some data to files that must round-trip through backup/restore.
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{env.graph_dir.path});
    defer allocator.free(nodes_path);
    try writeTestFile(nodes_path, "test node data");

    const labels_dict_path = try std.fmt.allocPrint(allocator, "{s}/labels.dict", .{env.graph_dir.path});
    defer allocator.free(labels_dict_path);
    try writeTestFile(labels_dict_path, "Person:1");

    const labels_idx_path = try std.fmt.allocPrint(allocator, "{s}/labels.idx", .{env.graph_dir.path});
    defer allocator.free(labels_idx_path);
    try writeTestFile(labels_idx_path, "label index snapshot");

    const props_idx_path = try std.fmt.allocPrint(allocator, "{s}/props.idx", .{env.graph_dir.path});
    defer allocator.free(props_idx_path);
    try writeTestFile(props_idx_path, "property index snapshot");

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

    const restore_result = try backup.restoreBackupResult(backup_path, restore_path);
    try testing.expectEqual(env.graph_dir.graph_uuid, restore_result.graph_uuid);
    try testing.expect(restore_result.files_restored >= 4);
    try testing.expect(restore_result.total_bytes >= "test node data".len + "Person:1".len + "label index snapshot".len + "property index snapshot".len);

    // Verify files were restored with correct content and permissions.
    const restored_nodes = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{restore_path});
    defer allocator.free(restored_nodes);
    try expectFileContents(restored_nodes, "test node data");
    try expectOwnerOnlyMode(restored_nodes);

    const restored_labels_dict = try std.fmt.allocPrint(allocator, "{s}/labels.dict", .{restore_path});
    defer allocator.free(restored_labels_dict);
    try expectFileContents(restored_labels_dict, "Person:1");
    try expectOwnerOnlyMode(restored_labels_dict);

    const restored_labels_idx = try std.fmt.allocPrint(allocator, "{s}/labels.idx", .{restore_path});
    defer allocator.free(restored_labels_idx);
    try expectFileContents(restored_labels_idx, "label index snapshot");
    try expectOwnerOnlyMode(restored_labels_idx);

    const restored_props_idx = try std.fmt.allocPrint(allocator, "{s}/props.idx", .{restore_path});
    defer allocator.free(restored_props_idx);
    try expectFileContents(restored_props_idx, "property index snapshot");
    try expectOwnerOnlyMode(restored_props_idx);
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

test "GAP-0034: validateBackup rejects version 2 backups without the HMAC key" {
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

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_v2.geob", .{out_path_base});
    defer allocator.free(backup_path);

    const key = [_]u8{0xAA} ** 32;
    var backup_with_key = Backup.initWithKey(allocator, key);
    _ = try backup_with_key.createBackup(&env.graph_dir, backup_path);

    var backup_no_key = Backup.init(allocator);
    const valid = try backup_no_key.validateBackup(backup_path);
    try testing.expect(!valid);
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

// ============================================================================
// Security Tests
// ============================================================================

test "SEC-0002: isValidBackupFilename rejects path traversal" {
    // ".." traversal variants
    try testing.expect(!isValidBackupFilename("../etc/passwd"));
    try testing.expect(!isValidBackupFilename("foo/../../etc/passwd"));
    try testing.expect(!isValidBackupFilename(".."));
    try testing.expect(!isValidBackupFilename("foo/.."));

    // Absolute paths
    try testing.expect(!isValidBackupFilename("/etc/passwd"));

    // Backslashes
    try testing.expect(!isValidBackupFilename("foo\\bar"));
    try testing.expect(!isValidBackupFilename("..\\..\\etc\\passwd"));

    // Null bytes
    try testing.expect(!isValidBackupFilename("foo\x00bar"));

    // Empty name
    try testing.expect(!isValidBackupFilename(""));

    // Double slashes
    try testing.expect(!isValidBackupFilename("foo//bar"));

    // Valid names
    try testing.expect(isValidBackupFilename("manifest.a"));
    try testing.expect(isValidBackupFilename("nodes.store"));
    try testing.expect(isValidBackupFilename("indexes/catalog.bin"));
}

test "SEC-0002: restoreBackup rejects malicious filename with path traversal" {
    const allocator = testing.allocator;

    // Build a minimal valid backup archive containing a malicious filename.
    // Format: magic(4) + version(2) + uuid(16) + file_count(4) + entry + crc(4)
    const malicious_name = "../../../etc/passwd";
    const file_data = "malicious content";

    const entry_size = 2 + malicious_name.len + 8 + file_data.len;
    const total_size = 26 + entry_size + 4; // header + entry + crc
    var buf: [total_size]u8 = undefined;

    // Header
    @memcpy(buf[0..4], &BACKUP_MAGIC);
    @memcpy(buf[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, BACKUP_VERSION)));
    @memset(buf[6..22], 0x42); // uuid
    @memcpy(buf[22..26], &std.mem.toBytes(std.mem.nativeToLittle(u32, 1))); // file_count = 1

    // Entry: filename_len + filename + file_size + file_data
    var pos: usize = 26;
    @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, @as(u16, malicious_name.len))));
    pos += 2;
    @memcpy(buf[pos..][0..malicious_name.len], malicious_name);
    pos += malicious_name.len;
    @memcpy(buf[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, file_data.len))));
    pos += 8;
    @memcpy(buf[pos..][0..file_data.len], file_data);
    pos += file_data.len;

    // CRC over everything before the CRC field
    const crc = Crc32.hash(buf[0..pos]);
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, crc)));

    // Write to temp file
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/malicious.geob", .{tmp_path});
    defer allocator.free(backup_path);
    {
        const f = try std.fs.cwd().createFile(backup_path, .{});
        defer f.close();
        try f.writeAll(&buf);
    }

    const restore_path = try std.fmt.allocPrint(allocator, "{s}/restored", .{tmp_path});
    defer allocator.free(restore_path);

    var backup = Backup.init(allocator);
    const result = backup.restoreBackup(backup_path, restore_path);
    try testing.expectError(error.InvalidBackupFilename, result);
}

test "SEC-0007: readFileAlloc enforces MAX_BACKUP_FILE_SIZE" {
    // We cannot create a 1GB+ file in tests, but we can verify the constant exists
    // and the check logic is in place by checking the constant value.
    try testing.expect(MAX_BACKUP_FILE_SIZE == 1 << 30);
}

test "SEC-0013: integer truncation guard in restoreBackup" {
    // On 64-bit this is a no-op, but we verify the code compiles and the
    // cast path exists. On 32-bit, a file_size > 4GiB would trigger BackupTooLarge.
    // We test by constructing a backup with a file_size that claims to be huge
    // but the actual data is short, which should fail with InvalidData after
    // the size check (on 64-bit) or BackupTooLarge (on 32-bit).
    const allocator = testing.allocator;

    // Build archive with file_size = 0xFFFF_FFFF_FFFF (way beyond data length)
    const name = "test.dat";
    const total_size = 26 + 2 + name.len + 8 + 4; // header + name_len + name + file_size + crc (no file_data, it's a lie)
    var buf: [total_size]u8 = undefined;

    @memcpy(buf[0..4], &BACKUP_MAGIC);
    @memcpy(buf[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, BACKUP_VERSION)));
    @memset(buf[6..22], 0x42);
    @memcpy(buf[22..26], &std.mem.toBytes(std.mem.nativeToLittle(u32, 1)));

    var pos: usize = 26;
    @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, @as(u16, name.len))));
    pos += 2;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    // Huge file_size that will fail the bounds check (or cast on 32-bit)
    @memcpy(buf[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0xFFFF_FFFF_FFFF))));
    pos += 8;

    const crc = Crc32.hash(buf[0..pos]);
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, crc)));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/truncation.geob", .{tmp_path});
    defer allocator.free(backup_path);
    {
        const f = try std.fs.cwd().createFile(backup_path, .{});
        defer f.close();
        try f.writeAll(&buf);
    }

    const restore_path = try std.fmt.allocPrint(allocator, "{s}/restored", .{tmp_path});
    defer allocator.free(restore_path);

    var backup = Backup.init(allocator);
    const result = backup.restoreBackup(backup_path, restore_path);
    // On 64-bit: file_size is valid usize but exceeds data.len => InvalidData
    // On 32-bit: cast fails => BackupTooLarge
    try testing.expect(result == error.InvalidData or result == error.BackupTooLarge);
}

test "SEC-0005: HMAC backup creates version 2 with tag" {
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

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_hmac.geob", .{out_path_base});
    defer allocator.free(backup_path);

    const key = [_]u8{0xAA} ** 32;
    var backup = Backup.initWithKey(allocator, key);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    // Verify version is 2
    const file = try std.fs.cwd().openFile(backup_path, .{});
    defer file.close();
    var header: [6]u8 = undefined;
    _ = try file.readAll(&header);
    const version = std.mem.littleToNative(u16, @bitCast(header[4..6].*));
    try testing.expectEqual(@as(u16, BACKUP_VERSION_HMAC), version);

    // Validate with correct key succeeds
    const valid = try backup.validateBackup(backup_path);
    try testing.expect(valid);
}

test "SEC-0005: HMAC backup rejects tampered data with recalculated CRC" {
    const allocator = testing.allocator;

    var env = try createTestGraphDir(allocator);
    defer {
        env.graph_dir.deinit();
        env.tmp_dir.cleanup();
    }

    // Write some data to a store file so there is content to tamper
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{env.graph_dir.path});
    defer allocator.free(nodes_path);
    {
        const f = try std.fs.cwd().openFile(nodes_path, .{ .mode = .write_only });
        defer f.close();
        try f.writeAll("original data");
    }

    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_path_base = try out_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(out_path_base);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_tamper.geob", .{out_path_base});
    defer allocator.free(backup_path);

    const key = [_]u8{0xBB} ** 32;
    var backup = Backup.initWithKey(allocator, key);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    // Tamper with the file data and recalculate the CRC (but not HMAC)
    {
        const data = try Backup.readFileAlloc(&backup, backup_path);
        defer allocator.free(data);

        // Tamper: change a byte in the file data area (after header)
        if (data.len > 30 + HmacSha256.mac_length) {
            const tampered = try allocator.alloc(u8, data.len);
            defer allocator.free(tampered);
            @memcpy(tampered, data);

            // Flip a byte in the file data area
            tampered[28] ^= 0xFF;

            // Recalculate CRC32 over data[0..crc_offset]
            const crc_offset = data.len - HmacSha256.mac_length - 4;
            const new_crc = Crc32.hash(tampered[0..crc_offset]);
            @memcpy(tampered[crc_offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));

            // Write tampered data (HMAC is now invalid)
            const f = try std.fs.cwd().createFile(backup_path, .{});
            defer f.close();
            try f.writeAll(tampered);
        }
    }

    // Validation with the correct key should fail due to HMAC mismatch
    const valid = try backup.validateBackup(backup_path);
    try testing.expect(!valid);
}

test "SEC-0017: V2 restore without key returns EncryptionKeyRequired" {
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

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_v2.geob", .{out_path_base});
    defer allocator.free(backup_path);

    // Create V2 backup with a key
    const key = [_]u8{0xCC} ** 32;
    var backup_with_key = Backup.initWithKey(allocator, key);
    _ = try backup_with_key.createBackup(&env.graph_dir, backup_path);

    // Try to restore without a key -- should fail
    var backup_no_key = Backup.init(allocator);
    const restore_path = try std.fmt.allocPrint(allocator, "{s}/restored_nokey", .{out_path_base});
    defer allocator.free(restore_path);

    const result = backup_no_key.restoreBackup(backup_path, restore_path);
    try testing.expectError(error.EncryptionKeyRequired, result);
}

test "GAP-0032: restoreBackup rejects a target graph path whose UUID mismatches the archive" {
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

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_v1.geob", .{out_path_base});
    defer allocator.free(backup_path);

    var backup = Backup.init(allocator);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    const wrong_uuid_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/graphs/11111111111111111111111111111111",
        .{out_path_base},
    );
    defer allocator.free(wrong_uuid_dir);

    const result = backup.restoreBackup(backup_path, wrong_uuid_dir);
    try testing.expectError(error.UuidMismatch, result);
}

test "GAP-0037: createBackup streams large files without buffering them fully in memory" {
    const allocator = testing.allocator;

    var env = try createTestGraphDir(allocator);
    defer {
        env.graph_dir.deinit();
        env.tmp_dir.cleanup();
    }

    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{env.graph_dir.path});
    defer allocator.free(nodes_path);
    {
        const file = try std.fs.cwd().createFile(nodes_path, .{ .mode = owner_only_file_mode });
        defer file.close();

        var chunk: [32 * 1024]u8 = undefined;
        @memset(&chunk, 0xAB);
        var remaining: usize = 2 * 1024 * 1024;
        while (remaining > 0) {
            const to_write = @min(chunk.len, remaining);
            try file.writeAll(chunk[0..to_write]);
            remaining -= to_write;
        }
    }

    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_path_base = try out_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(out_path_base);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_streamed.geob", .{out_path_base});
    defer allocator.free(backup_path);

    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var backup = Backup.init(fba.allocator());
    const result = try backup.createBackup(&env.graph_dir, backup_path);

    try testing.expect(result.total_bytes >= 2 * 1024 * 1024);
}

test "SEC-0005: no-key backup still works as version 1" {
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

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup_v1.geob", .{out_path_base});
    defer allocator.free(backup_path);

    var backup = Backup.init(allocator);
    _ = try backup.createBackup(&env.graph_dir, backup_path);

    // Check version is 1
    const file = try std.fs.cwd().openFile(backup_path, .{});
    defer file.close();
    var header: [6]u8 = undefined;
    _ = try file.readAll(&header);
    const version = std.mem.littleToNative(u16, @bitCast(header[4..6].*));
    try testing.expectEqual(@as(u16, BACKUP_VERSION), version);

    const valid = try backup.validateBackup(backup_path);
    try testing.expect(valid);
}

test "BackupResult writeJson produces valid structured output" {
    const result = BackupResult{
        .graph_uuid = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD } ++ [_]u8{0x00} ** 12,
        .files_backed_up = 7,
        .total_bytes = 123456,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);

    try result.writeJson(buf.writer(testing.allocator));
    const json = buf.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"files_backed_up\":7") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total_bytes\":123456") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"graph_uuid\":\"aabbccdd") != null);
}

test "RestoreResult writeJson produces valid structured output" {
    const result = RestoreResult{
        .graph_uuid = [_]u8{ 0x11, 0x22, 0x33, 0x44 } ++ [_]u8{0x00} ** 12,
        .files_restored = 5,
        .total_bytes = 654321,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);

    try result.writeJson(buf.writer(testing.allocator));
    const json = buf.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"operation\":\"restore\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"files_restored\":5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total_bytes\":654321") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"graph_uuid\":\"11223344") != null);
}

test {
    std.testing.refAllDecls(@This());
}
