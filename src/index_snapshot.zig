// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const LoadedSnapshot = struct {
    allocator: Allocator,
    data: []u8,
    checkpoint_counter: u64,
    item_count: u64,
    payload_offset: usize,

    pub fn payload(self: *const LoadedSnapshot) []const u8 {
        return self.data[self.payload_offset..];
    }

    pub fn deinit(self: *LoadedSnapshot) void {
        self.allocator.free(self.data);
    }
};

pub const SnapshotHeader = struct {
    checkpoint_counter: u64,
    item_count: u64,
    payload_size: usize,
};

pub fn writeHeader(file: std.Io.File, offset: *u64, magic: []const u8, checkpoint_counter: u64, item_count: u64) !void {
    if (magic.len != 8) return error.InvalidMagicLength;
    const io = std.Io.Threaded.global_single_threaded.io();

    var u64_buf: [8]u8 = undefined;

    try file.writePositionalAll(io, magic, offset.*);
    offset.* += magic.len;

    std.mem.writeInt(u64, &u64_buf, checkpoint_counter, .little);
    try file.writePositionalAll(io, &u64_buf, offset.*);
    offset.* += 8;

    std.mem.writeInt(u64, &u64_buf, item_count, .little);
    try file.writePositionalAll(io, &u64_buf, offset.*);
    offset.* += 8;
}

pub fn loadFile(allocator: Allocator, file: *std.Io.File, expected_magic: []const u8) !?LoadedSnapshot {
    const header = (try loadHeader(file, expected_magic)) orelse return null;

    const total_size = expected_magic.len + 16 + header.payload_size;
    const data = try allocator.alloc(u8, total_size);
    errdefer allocator.free(data);

    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes_read = try file.readPositionalAll(io, data, 0);
    if (bytes_read != total_size) return error.UnexpectedEndOfFile;

    return .{
        .allocator = allocator,
        .data = data,
        .checkpoint_counter = header.checkpoint_counter,
        .item_count = header.item_count,
        .payload_offset = expected_magic.len + 16,
    };
}

pub fn loadHeader(file: *std.Io.File, expected_magic: []const u8) !?SnapshotHeader {
    if (expected_magic.len != 8) return error.InvalidMagicLength;

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    if (stat.size == 0) return null;

    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < expected_magic.len + 16) return error.InvalidFormat;

    const io = std.Io.Threaded.global_single_threaded.io();
    var header_buf: [24]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &header_buf, 0);
    if (bytes_read != header_buf.len) return error.UnexpectedEndOfFile;
    if (!std.mem.eql(u8, header_buf[0..expected_magic.len], expected_magic)) {
        return error.InvalidFormat;
    }

    return .{
        .checkpoint_counter = std.mem.readInt(u64, header_buf[expected_magic.len..][0..8], .little),
        .item_count = std.mem.readInt(u64, header_buf[expected_magic.len + 8 ..][0..8], .little),
        .payload_size = size - (expected_magic.len + 16),
    };
}

pub fn readBounded(file: *std.Io.File, offset: *u64, remaining: *usize, buf: []u8) !void {
    if (buf.len > remaining.*) return error.InvalidFormat;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes_read = try file.readPositionalAll(io, buf, offset.*);
    if (bytes_read != buf.len) return error.UnexpectedEndOfFile;
    offset.* += buf.len;
    remaining.* -= buf.len;
}

test "writeHeader and loadFile round-trip checkpoint metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 99, 7);
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), "payload", write_offset);

    var loaded = (try loadFile(std.testing.allocator, &file, "GSTEST1\x00")).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 99), loaded.checkpoint_counter);
    try std.testing.expectEqual(@as(u64, 7), loaded.item_count);
    try std.testing.expectEqualStrings("payload", loaded.payload());
}
