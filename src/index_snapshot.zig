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

pub fn writeHeader(writer: anytype, magic: []const u8, checkpoint_counter: u64, item_count: u64) !void {
    if (magic.len != 8) return error.InvalidMagicLength;

    var u64_buf: [8]u8 = undefined;

    try writer.writeAll(magic);

    std.mem.writeInt(u64, &u64_buf, checkpoint_counter, .little);
    try writer.writeAll(&u64_buf);

    std.mem.writeInt(u64, &u64_buf, item_count, .little);
    try writer.writeAll(&u64_buf);
}

pub fn loadFile(allocator: Allocator, file: *std.fs.File, expected_magic: []const u8) !?LoadedSnapshot {
    if (expected_magic.len != 8) return error.InvalidMagicLength;

    const stat = try file.stat();
    if (stat.size == 0) return null;

    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < expected_magic.len + 16) return error.InvalidFormat;

    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);

    try file.seekTo(0);
    const bytes_read = try file.readAll(data);
    if (bytes_read != size) return error.UnexpectedEndOfFile;
    if (!std.mem.eql(u8, data[0..expected_magic.len], expected_magic)) {
        return error.InvalidFormat;
    }

    const checkpoint_counter = std.mem.readInt(u64, data[expected_magic.len..][0..8], .little);
    const item_count = std.mem.readInt(u64, data[expected_magic.len + 8 ..][0..8], .little);

    return .{
        .allocator = allocator,
        .data = data,
        .checkpoint_counter = checkpoint_counter,
        .item_count = item_count,
        .payload_offset = expected_magic.len + 16,
    };
}

test "writeHeader and loadFile round-trip checkpoint metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close();

    try writeHeader(&file, "GSTEST1\x00", 99, 7);
    try file.writeAll("payload");

    var loaded = (try loadFile(std.testing.allocator, &file, "GSTEST1\x00")).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 99), loaded.checkpoint_counter);
    try std.testing.expectEqual(@as(u64, 7), loaded.item_count);
    try std.testing.expectEqualStrings("payload", loaded.payload());
}
