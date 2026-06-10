// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Same CRC used by the manifest (manifest.zig) for on-disk integrity.
const Crc32 = std.hash.crc.Crc32Iscsi;

/// Header bytes preceding the payload: checkpoint_counter(u64) + item_count(u64).
pub const HEADER_FIELDS_SIZE: usize = 16;

/// Trailing CRC32 appended after the payload (SEC-0051).
pub const CHECKSUM_SIZE: usize = 4;

pub const LoadedSnapshot = struct {
    allocator: Allocator,
    data: []u8,
    checkpoint_counter: u64,
    item_count: u64,
    payload_offset: usize,
    payload_size: usize,

    pub fn payload(self: *const LoadedSnapshot) []const u8 {
        return self.data[self.payload_offset..][0..self.payload_size];
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

/// SEC-0051: After the header + payload have been written, compute a CRC32 over
/// the entire on-disk region [0, payload_end) and append it as a 4-byte trailer.
/// `payload_end` is the byte offset immediately after the last payload byte
/// (i.e. magic.len + 16 + payload_size).
pub fn finalizeChecksum(allocator: Allocator, file: std.Io.File, payload_end: u64) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    const len: usize = std.math.cast(usize, payload_end) orelse return error.FileTooLarge;
    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);

    const bytes_read = try file.readPositionalAll(io, buf, 0);
    if (bytes_read != len) return error.UnexpectedEndOfFile;

    const crc = Crc32.hash(buf);
    var crc_buf: [CHECKSUM_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc, .little);
    try file.writePositionalAll(io, &crc_buf, payload_end);
}

pub fn loadFile(allocator: Allocator, file: *std.Io.File, expected_magic: []const u8) !?LoadedSnapshot {
    if (expected_magic.len != 8) return error.InvalidMagicLength;

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    if (stat.size == 0) return null;

    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE) return error.InvalidFormat;

    const io = std.Io.Threaded.global_single_threaded.io();
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);

    const bytes_read = try file.readPositionalAll(io, data, 0);
    if (bytes_read != size) return error.UnexpectedEndOfFile;

    if (!std.mem.eql(u8, data[0..expected_magic.len], expected_magic)) {
        return error.InvalidFormat;
    }

    // SEC-0051: verify trailing CRC32 over everything before the checksum.
    const stored_crc = std.mem.readInt(u32, data[size - CHECKSUM_SIZE ..][0..CHECKSUM_SIZE], .little);
    const computed_crc = Crc32.hash(data[0 .. size - CHECKSUM_SIZE]);
    if (stored_crc != computed_crc) return error.ChecksumMismatch;

    const payload_offset = expected_magic.len + HEADER_FIELDS_SIZE;
    return .{
        .allocator = allocator,
        .data = data,
        .checkpoint_counter = std.mem.readInt(u64, data[expected_magic.len..][0..8], .little),
        .item_count = std.mem.readInt(u64, data[expected_magic.len + 8 ..][0..8], .little),
        .payload_offset = payload_offset,
        .payload_size = size - payload_offset - CHECKSUM_SIZE,
    };
}

/// Read and validate the snapshot header, verify its CRC32, and bound the
/// declared `item_count` against the available payload.
///
/// SEC-0044/SEC-0048: `min_record_size` is the smallest number of payload bytes
/// a single declared item can consume. The loader rejects any snapshot whose
/// `item_count` exceeds `payload_size / min_record_size`, so a tiny crafted file
/// can never drive a multi-GB capacity reservation before the bytes exist on
/// disk. Pass `min_record_size == 0` only when the per-item minimum is genuinely
/// zero (no fixed-size records), which disables the count bound.
///
/// SEC-0051: the trailing CRC32 is verified here, so a corrupted snapshot
/// returns `error.ChecksumMismatch` (treated by callers as "snapshot invalid →
/// rebuild") rather than loading attacker-controlled data.
pub fn loadHeader(file: *std.Io.File, expected_magic: []const u8, min_record_size: usize) !?SnapshotHeader {
    if (expected_magic.len != 8) return error.InvalidMagicLength;

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    if (stat.size == 0) return null;

    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE) return error.InvalidFormat;

    const io = std.Io.Threaded.global_single_threaded.io();

    var header_buf: [24]u8 = undefined;
    const header_read = try file.readPositionalAll(io, &header_buf, 0);
    if (header_read != header_buf.len) return error.UnexpectedEndOfFile;
    if (!std.mem.eql(u8, header_buf[0..expected_magic.len], expected_magic)) {
        return error.InvalidFormat;
    }

    // SEC-0051: stream the whole file through the CRC and compare the trailer.
    var hasher = Crc32.init();
    var crc_buf: [4096]u8 = undefined;
    var consumed: usize = 0;
    const body_len = size - CHECKSUM_SIZE;
    while (consumed < body_len) {
        const want = @min(crc_buf.len, body_len - consumed);
        const n = try file.readPositionalAll(io, crc_buf[0..want], consumed);
        if (n != want) return error.UnexpectedEndOfFile;
        hasher.update(crc_buf[0..n]);
        consumed += n;
    }
    var trailer_buf: [CHECKSUM_SIZE]u8 = undefined;
    const trailer_read = try file.readPositionalAll(io, &trailer_buf, body_len);
    if (trailer_read != trailer_buf.len) return error.UnexpectedEndOfFile;
    const stored_crc = std.mem.readInt(u32, &trailer_buf, .little);
    if (stored_crc != hasher.final()) return error.ChecksumMismatch;

    const item_count = std.mem.readInt(u64, header_buf[expected_magic.len + 8 ..][0..8], .little);
    const payload_size = size - (expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE);

    // SEC-0044/SEC-0048: reject counts that cannot possibly be backed by bytes.
    if (min_record_size != 0) {
        const max_items = payload_size / min_record_size;
        if (item_count > max_items) return error.InvalidFormat;
    }

    return .{
        .checkpoint_counter = std.mem.readInt(u64, header_buf[expected_magic.len..][0..8], .little),
        .item_count = item_count,
        .payload_size = payload_size,
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

test "writeHeader + finalizeChecksum and loadFile round-trip checkpoint metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 99, 7);
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), "payload", write_offset);
    write_offset += "payload".len;
    try finalizeChecksum(std.testing.allocator, file, write_offset);

    var loaded = (try loadFile(std.testing.allocator, &file, "GSTEST1\x00")).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 99), loaded.checkpoint_counter);
    try std.testing.expectEqual(@as(u64, 7), loaded.item_count);
    try std.testing.expectEqualStrings("payload", loaded.payload());
}

test "loadHeader rejects an item_count too large for the payload (SEC-0044/0048)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    // Tiny payload (8 bytes) but a huge declared item_count.
    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 1, std.math.maxInt(u64));
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &[_]u8{0} ** 8, write_offset);
    write_offset += 8;
    try finalizeChecksum(std.testing.allocator, file, write_offset);

    // min_record_size of 8 → at most 1 item fits; maxInt(u64) must be rejected
    // *before* any reservation. std.testing.allocator would also catch a leak,
    // but the bound is checked prior to allocation.
    try std.testing.expectError(error.InvalidFormat, loadHeader(&file, "GSTEST1\x00", 8));
}

test "loadHeader rejects a corrupted payload byte (SEC-0051)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 5, 1);
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &[_]u8{0xAB} ** 8, write_offset);
    write_offset += 8;
    try finalizeChecksum(std.testing.allocator, file, write_offset);

    // Flip a single payload byte, keeping the checkpoint_counter header intact.
    var flip: [1]u8 = .{0x00};
    const payload_byte_offset: u64 = 8 + HEADER_FIELDS_SIZE; // magic + header fields
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &flip, payload_byte_offset);

    try std.testing.expectError(error.ChecksumMismatch, loadHeader(&file, "GSTEST1\x00", 8));
}
