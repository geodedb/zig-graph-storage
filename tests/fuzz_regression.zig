// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const gs = @import("graph_storage");

const BufferPool = gs.buffer_pool.BufferPool;
const FreeSpaceManager = gs.free_space.FreeSpaceManager;
const Backup = gs.backup.Backup;
const BACKUP_MAGIC = gs.backup.BACKUP_MAGIC;
const BACKUP_VERSION = gs.backup.BACKUP_VERSION;
const Migration = gs.migration.Migration;
const PerGraphHeader = gs.migration.PerGraphHeader;
const serializePerGraphHeader = gs.migration.serializePerGraphHeader;
const PER_GRAPH_HEADER_SIZE = gs.migration.PER_GRAPH_HEADER_SIZE;

const Crc32 = std.hash.crc.Crc32Iscsi;

test "fuzz regression: free-space metadata with oversized page counts is rejected" {
    var pool = try BufferPool.init(std.testing.allocator, 4096, 4);
    defer pool.deinit();

    var free_space = try FreeSpaceManager.init(std.testing.allocator, &pool, .nodes);
    defer free_space.deinit();

    var buf: [24]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], std.math.maxInt(u64), .little);
    std.mem.writeInt(u64, buf[8..16], 0, .little);
    std.mem.writeInt(u64, buf[16..24], 1, .little);

    try std.testing.expectError(error.InvalidData, free_space.deserializeBounded(&buf, 128));
}

test "fuzz regression: migration rejects malformed per-graph headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var header_buf: [PER_GRAPH_HEADER_SIZE]u8 = undefined;
    serializePerGraphHeader(PerGraphHeader{
        .version = 1,
        .graph_uuid = [_]u8{0xAB} ** 16,
        .node_count = 10,
        .edge_count = 20,
    }, &header_buf);
    header_buf[0] = 'X';

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/legacy.dat", .{tmp_path});
    defer std.testing.allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(&header_buf);

    const migration = Migration.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidMagic, migration.validatePerGraphHeader(path));
}

test "fuzz regression: backup restore rejects path traversal filenames" {
    const allocator = std.testing.allocator;
    const malicious_name = "../../../etc/passwd";
    const file_data = "malicious content";

    const entry_size = 2 + malicious_name.len + 8 + file_data.len;
    const total_size = 26 + entry_size + 4;
    var buf: [total_size]u8 = undefined;

    @memcpy(buf[0..4], &BACKUP_MAGIC);
    @memcpy(buf[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, BACKUP_VERSION)));
    @memset(buf[6..22], 0x42);
    @memcpy(buf[22..26], &std.mem.toBytes(std.mem.nativeToLittle(u32, 1)));

    var pos: usize = 26;
    @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, @as(u16, malicious_name.len))));
    pos += 2;
    @memcpy(buf[pos..][0..malicious_name.len], malicious_name);
    pos += malicious_name.len;
    @memcpy(buf[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, file_data.len))));
    pos += 8;
    @memcpy(buf[pos..][0..file_data.len], file_data);
    pos += file_data.len;

    const crc = Crc32.hash(buf[0..pos]);
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, crc)));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/malicious.geob", .{tmp_path});
    defer allocator.free(backup_path);
    const restore_path = try std.fmt.allocPrint(allocator, "{s}/restored", .{tmp_path});
    defer allocator.free(restore_path);

    const file = try std.fs.cwd().createFile(backup_path, .{});
    defer file.close();
    try file.writeAll(&buf);

    var backup = Backup.init(allocator);
    try std.testing.expectError(error.InvalidBackupFilename, backup.restoreBackup(backup_path, restore_path));
}
