// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

/// WAL record types for the write-ahead log.
pub const WalRecordType = enum(u8) {
    page_update = 1,
    begin_txn = 2,
    commit_txn = 3,
    abort_txn = 4,
    checkpoint_marker = 5,
};

/// Header size: lsn(8) + txn_id(8) + record_type(1) + file_id(1) + page_id(8) + payload_len(4) = 30 bytes
/// Trailer: checksum(4)
/// Total overhead: 34 bytes
const HEADER_SIZE: usize = 30;
const CHECKSUM_SIZE: usize = 4;
const MIN_RECORD_SIZE: usize = HEADER_SIZE + CHECKSUM_SIZE;

/// A WAL record representing a single logged operation.
///
/// Format (serialized):
///   lsn(8) + txn_id(8) + record_type(1) + file_id(1) + page_id(8) + payload_len(4) + payload + checksum(4)
pub const WalRecord = struct {
    lsn: u64,
    txn_id: u64,
    record_type: WalRecordType,
    file_id: u8,
    page_id: u64,
    payload: []const u8,
    checksum: u32,

    /// Serialize the record to a newly allocated byte buffer.
    pub fn serialize(self: *const WalRecord, allocator: Allocator) ![]u8 {
        const total_size = HEADER_SIZE + self.payload.len + CHECKSUM_SIZE;
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);

        var offset: usize = 0;

        // lsn (8 bytes, little-endian)
        @memcpy(buf[offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, self.lsn)));
        offset += 8;

        // txn_id (8 bytes)
        @memcpy(buf[offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, self.txn_id)));
        offset += 8;

        // record_type (1 byte)
        buf[offset] = @intFromEnum(self.record_type);
        offset += 1;

        // file_id (1 byte)
        buf[offset] = self.file_id;
        offset += 1;

        // page_id (8 bytes)
        @memcpy(buf[offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, self.page_id)));
        offset += 8;

        // payload_len (4 bytes)
        const payload_len: u32 = @intCast(self.payload.len);
        @memcpy(buf[offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, payload_len)));
        offset += 4;

        // payload
        if (self.payload.len > 0) {
            @memcpy(buf[offset..][0..self.payload.len], self.payload);
            offset += self.payload.len;
        }

        // checksum (4 bytes)
        @memcpy(buf[offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, self.checksum)));

        return buf;
    }

    /// Deserialize a WalRecord from a byte buffer.
    /// Returns the deserialized record and the total number of bytes consumed.
    /// The payload is copied into a new allocation owned by the caller.
    pub fn deserialize(allocator: Allocator, data: []const u8) !struct { record: WalRecord, bytes_read: usize } {
        if (data.len < MIN_RECORD_SIZE) return error.InvalidFormat;

        var offset: usize = 0;

        const lsn = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, data[offset..][0..8]));
        offset += 8;

        const txn_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, data[offset..][0..8]));
        offset += 8;

        const record_type_byte = data[offset];
        const record_type = std.meta.intToEnum(WalRecordType, record_type_byte) catch return error.InvalidFormat;
        offset += 1;

        const file_id = data[offset];
        offset += 1;

        const page_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, data[offset..][0..8]));
        offset += 8;

        const payload_len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[offset..][0..4]));
        offset += 4;

        if (data.len < offset + payload_len + CHECKSUM_SIZE) return error.InvalidFormat;

        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);
        if (payload_len > 0) {
            @memcpy(payload, data[offset..][0..payload_len]);
        }
        offset += payload_len;

        const checksum = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[offset..][0..4]));
        offset += CHECKSUM_SIZE;

        return .{
            .record = WalRecord{
                .lsn = lsn,
                .txn_id = txn_id,
                .record_type = record_type,
                .file_id = file_id,
                .page_id = page_id,
                .payload = payload,
                .checksum = checksum,
            },
            .bytes_read = offset,
        };
    }

    /// Compute CRC32C checksum over all fields except the checksum itself.
    /// The checksum covers: lsn + txn_id + record_type + file_id + page_id + payload_len + payload.
    pub fn computeChecksum(self: *const WalRecord) u32 {
        var hasher = std.hash.crc.Crc32Iscsi.init();
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.lsn)));
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.txn_id)));
        hasher.update(&[_]u8{@intFromEnum(self.record_type)});
        hasher.update(&[_]u8{self.file_id});
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.page_id)));
        const payload_len: u32 = @intCast(self.payload.len);
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, payload_len)));
        if (self.payload.len > 0) {
            hasher.update(self.payload);
        }
        return hasher.final();
    }

    /// Free the payload allocated during deserialization.
    pub fn deinit(self: *const WalRecord, allocator: Allocator) void {
        if (self.payload.len > 0) {
            allocator.free(self.payload);
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "serialize/deserialize round-trip for page_update record" {
    const allocator = std.testing.allocator;
    const payload_data = "hello page data";

    var record = WalRecord{
        .lsn = 42,
        .txn_id = 7,
        .record_type = .page_update,
        .file_id = 3,
        .page_id = 100,
        .payload = payload_data,
        .checksum = 0,
    };
    record.checksum = record.computeChecksum();

    const bytes = try record.serialize(allocator);
    defer allocator.free(bytes);

    const result = try WalRecord.deserialize(allocator, bytes);
    defer result.record.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), result.record.lsn);
    try std.testing.expectEqual(@as(u64, 7), result.record.txn_id);
    try std.testing.expectEqual(WalRecordType.page_update, result.record.record_type);
    try std.testing.expectEqual(@as(u8, 3), result.record.file_id);
    try std.testing.expectEqual(@as(u64, 100), result.record.page_id);
    try std.testing.expectEqualStrings(payload_data, result.record.payload);
    try std.testing.expectEqual(record.checksum, result.record.checksum);
    try std.testing.expectEqual(bytes.len, result.bytes_read);
}

test "serialize/deserialize round-trip for begin/commit/abort (empty payload)" {
    const allocator = std.testing.allocator;

    const record_types = [_]WalRecordType{ .begin_txn, .commit_txn, .abort_txn, .checkpoint_marker };

    for (record_types) |rt| {
        var record = WalRecord{
            .lsn = 10,
            .txn_id = 5,
            .record_type = rt,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        record.checksum = record.computeChecksum();

        const bytes = try record.serialize(allocator);
        defer allocator.free(bytes);

        const result = try WalRecord.deserialize(allocator, bytes);
        defer result.record.deinit(allocator);

        try std.testing.expectEqual(@as(u64, 10), result.record.lsn);
        try std.testing.expectEqual(rt, result.record.record_type);
        try std.testing.expectEqual(@as(usize, 0), result.record.payload.len);
        try std.testing.expectEqual(record.checksum, result.record.checksum);
        try std.testing.expectEqual(@as(usize, MIN_RECORD_SIZE), result.bytes_read);
    }
}

test "checksum validation detects corruption" {
    const allocator = std.testing.allocator;
    const payload_data = "important data";

    var record = WalRecord{
        .lsn = 1,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0,
        .page_id = 50,
        .payload = payload_data,
        .checksum = 0,
    };
    record.checksum = record.computeChecksum();

    const bytes = try record.serialize(allocator);
    defer allocator.free(bytes);

    // Corrupt one byte in the payload area
    bytes[HEADER_SIZE + 2] ^= 0xFF;

    const result = try WalRecord.deserialize(allocator, bytes);
    defer result.record.deinit(allocator);

    // The stored checksum should no longer match the computed checksum
    const recomputed = result.record.computeChecksum();
    try std.testing.expect(result.record.checksum != recomputed);
}

test "multiple records serialized consecutively can be deserialized back" {
    const allocator = std.testing.allocator;

    // Build 3 records with varying payloads
    var records: [3]WalRecord = undefined;
    const payloads = [_][]const u8{ "first", "", "third payload here" };

    for (0..3) |i| {
        records[i] = WalRecord{
            .lsn = @intCast(i + 1),
            .txn_id = 100,
            .record_type = if (i == 1) .commit_txn else .page_update,
            .file_id = @intCast(i),
            .page_id = @as(u64, @intCast(i)) * 10,
            .payload = payloads[i],
            .checksum = 0,
        };
        records[i].checksum = records[i].computeChecksum();
    }

    // Serialize all into one contiguous buffer
    var parts: [3][]u8 = undefined;
    var total_len: usize = 0;
    for (0..3) |i| {
        parts[i] = try records[i].serialize(allocator);
        total_len += parts[i].len;
    }
    defer for (&parts) |p| allocator.free(p);

    const combined = try allocator.alloc(u8, total_len);
    defer allocator.free(combined);
    var offset: usize = 0;
    for (&parts) |p| {
        @memcpy(combined[offset..][0..p.len], p);
        offset += p.len;
    }

    // Deserialize all records back
    var read_offset: usize = 0;
    for (0..3) |i| {
        const result = try WalRecord.deserialize(allocator, combined[read_offset..]);
        defer result.record.deinit(allocator);

        try std.testing.expectEqual(records[i].lsn, result.record.lsn);
        try std.testing.expectEqual(records[i].record_type, result.record.record_type);
        try std.testing.expectEqual(records[i].file_id, result.record.file_id);
        try std.testing.expectEqual(records[i].page_id, result.record.page_id);
        try std.testing.expectEqualSlices(u8, records[i].payload, result.record.payload);
        try std.testing.expectEqual(records[i].checksum, result.record.checksum);

        read_offset += result.bytes_read;
    }

    try std.testing.expectEqual(total_len, read_offset);
}

test {
    std.testing.refAllDecls(@This());
}
