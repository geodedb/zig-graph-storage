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

/// PERF-0052: in-memory snapshot serializer.
///
/// Producers append the magic, header, and payload into a single growable
/// buffer; `finalize` computes the CRC32 over everything accumulated, appends
/// the 4-byte trailer (SEC-0051), and flushes the whole snapshot to disk with a
/// single `writePositionalAll`. This collapses the previous per-field positional
/// write loop (~5 syscalls per entry) into one buffered pass while keeping the
/// on-disk layout (magic | counter | item_count | payload | crc32) byte-identical.
pub const SnapshotWriter = struct {
    buf: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SnapshotWriter {
        return .{ .buf = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *SnapshotWriter) void {
        self.buf.deinit(self.allocator);
    }

    /// Append the 8-byte magic and the 16-byte header (checkpoint_counter,
    /// item_count). Mirrors `writeHeader`'s on-disk byte order exactly.
    pub fn writeHeader(self: *SnapshotWriter, magic: []const u8, checkpoint_counter: u64, item_count: u64) !void {
        if (magic.len != 8) return error.InvalidMagicLength;
        try self.buf.appendSlice(self.allocator, magic);
        var u64_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &u64_buf, checkpoint_counter, .little);
        try self.buf.appendSlice(self.allocator, &u64_buf);
        std.mem.writeInt(u64, &u64_buf, item_count, .little);
        try self.buf.appendSlice(self.allocator, &u64_buf);
    }

    pub fn writeU16(self: *SnapshotWriter, value: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, value, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU32(self: *SnapshotWriter, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU64(self: *SnapshotWriter, value: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeBytes(self: *SnapshotWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// SEC-0051: append the CRC32 trailer over the accumulated bytes and flush
    /// the entire snapshot to `file` with a single positional write.
    pub fn finalize(self: *SnapshotWriter, file: std.Io.File) !void {
        const crc = Crc32.hash(self.buf.items);
        var crc_buf: [CHECKSUM_SIZE]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, crc, .little);
        try self.buf.appendSlice(self.allocator, &crc_buf);

        const io = std.Io.Threaded.global_single_threaded.io();
        try file.setLength(io, 0);
        try file.writePositionalAll(io, self.buf.items, 0);
    }
};

/// PERF-0052: in-memory snapshot deserializer.
///
/// `loadHeader` already validated the magic, verified the CRC32 (SEC-0051), and
/// bounded `item_count` against the payload (SEC-0044/0048). This reader walks
/// the already-resident payload slice instead of issuing one positional read per
/// field, preserving the same byte-level bounds checks via `remaining`.
pub const SnapshotReader = struct {
    payload: []const u8,
    pos: usize = 0,

    pub fn init(payload: []const u8) SnapshotReader {
        return .{ .payload = payload, .pos = 0 };
    }

    /// Bytes still unread in the payload. Mirrors the `remaining` counter the
    /// per-chain/per-label bound checks consult before reserving capacity.
    pub fn remaining(self: *const SnapshotReader) usize {
        return self.payload.len - self.pos;
    }

    fn take(self: *SnapshotReader, n: usize) ![]const u8 {
        if (n > self.remaining()) return error.InvalidFormat;
        const slice = self.payload[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    pub fn readU16(self: *SnapshotReader) !u16 {
        const s = try self.take(2);
        return std.mem.readInt(u16, s[0..2], .little);
    }

    pub fn readU32(self: *SnapshotReader) !u32 {
        const s = try self.take(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    pub fn readU64(self: *SnapshotReader) !u64 {
        const s = try self.take(8);
        return std.mem.readInt(u64, s[0..8], .little);
    }

    /// Borrow `n` payload bytes without copying. The slice aliases the loaded
    /// snapshot buffer and is only valid while that buffer lives.
    pub fn readBytes(self: *SnapshotReader, n: usize) ![]const u8 {
        return self.take(n);
    }
};

/// Read, validate, and return the full snapshot as an in-memory buffer.
///
/// PERF-0052: combines the validation `loadHeader` performs (magic check, CRC32
/// verification per SEC-0051, and the `item_count` vs `payload_size` bound per
/// SEC-0044/0048) with a single whole-file read, so callers can deserialize
/// entries from memory instead of issuing per-field positional reads. The
/// returned `LoadedSnapshot` owns `data`; callers must `deinit` it.
pub fn loadPayload(allocator: Allocator, file: *std.Io.File, expected_magic: []const u8, min_record_size: usize) !?LoadedSnapshot {
    const loaded = (try loadFile(allocator, file, expected_magic)) orelse return null;
    errdefer {
        var l = loaded;
        l.deinit();
    }

    // SEC-0044/SEC-0048: reject counts that cannot possibly be backed by bytes,
    // exactly as loadHeader does, before any caller reservation.
    if (min_record_size != 0) {
        const max_items = loaded.payload_size / min_record_size;
        if (loaded.item_count > max_items) return error.InvalidFormat;
    }

    return loaded;
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

test "PERF-0052: SnapshotWriter output is byte-identical to writeHeader+finalizeChecksum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Legacy per-field path.
    var legacy = try tmp.dir.createFile(io, "legacy.bin", .{ .read = true, .truncate = true });
    defer legacy.close(io);
    var write_offset: u64 = 0;
    try writeHeader(legacy, &write_offset, "GSTEST1\x00", 0xDEAD, 2);
    try legacy.writePositionalAll(io, &[_]u8{ 1, 2, 3, 4, 5 }, write_offset);
    write_offset += 5;
    try finalizeChecksum(std.testing.allocator, legacy, write_offset);

    // Buffered writer path with the same logical content.
    var buffered = try tmp.dir.createFile(io, "buffered.bin", .{ .read = true, .truncate = true });
    defer buffered.close(io);
    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 0xDEAD, 2);
    try w.writeBytes(&[_]u8{ 1, 2, 3, 4, 5 });
    try w.finalize(buffered);

    const legacy_stat = try legacy.stat(io);
    const buffered_stat = try buffered.stat(io);
    try std.testing.expectEqual(legacy_stat.size, buffered_stat.size);

    const len: usize = @intCast(legacy_stat.size);
    const a = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(b);
    _ = try legacy.readPositionalAll(io, a, 0);
    _ = try buffered.readPositionalAll(io, b, 0);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "PERF-0052: loadPayload round-trips and SnapshotReader honors bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);

    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 42, 1);
    try w.writeU64(0x1122334455667788);
    try w.writeU32(0xAABBCCDD);
    try w.writeU16(0xBEEF);
    try w.finalize(file);

    var loaded = (try loadPayload(std.testing.allocator, &file, "GSTEST1\x00", 0)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 42), loaded.checkpoint_counter);
    try std.testing.expectEqual(@as(u64, 1), loaded.item_count);

    var r = SnapshotReader.init(loaded.payload());
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), try r.readU64());
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), try r.readU32());
    try std.testing.expectEqual(@as(u16, 0xBEEF), try r.readU16());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // Past-the-end read is rejected as malformed, not a positional EOF.
    try std.testing.expectError(error.InvalidFormat, r.readU16());
}

test "PERF-0052: loadPayload enforces the count bound (SEC-0044/0048)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);

    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 1, std.math.maxInt(u64));
    try w.writeBytes(&[_]u8{0} ** 8);
    try w.finalize(file);

    // min_record_size of 8 → at most 1 item fits; maxInt(u64) must be rejected.
    try std.testing.expectError(error.InvalidFormat, loadPayload(std.testing.allocator, &file, "GSTEST1\x00", 8));
}

test "PERF-0052: loadPayload rejects a corrupted payload byte (SEC-0051)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);

    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 5, 1);
    try w.writeBytes(&[_]u8{0xAB} ** 8);
    try w.finalize(file);

    var flip: [1]u8 = .{0x00};
    const payload_byte_offset: u64 = 8 + HEADER_FIELDS_SIZE;
    try file.writePositionalAll(io, &flip, payload_byte_offset);

    try std.testing.expectError(error.ChecksumMismatch, loadPayload(std.testing.allocator, &file, "GSTEST1\x00", 8));
}
