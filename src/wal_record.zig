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

    /// Total serialized size for this record.
    pub fn serializedSize(self: *const WalRecord) usize {
        return HEADER_SIZE + self.payload.len + CHECKSUM_SIZE;
    }

    /// Serialize the record into a caller-provided buffer, computing the
    /// CRC32C checksum inline in a single pass over the data.
    ///
    /// Returns the number of bytes written and updates `self.checksum`
    /// with the computed value. The buffer must be at least
    /// `serializedSize()` bytes long.
    pub fn serializeInto(self: *WalRecord, buf: []u8) error{BufferTooSmall}!usize {
        const total_size = self.serializedSize();
        if (buf.len < total_size) return error.BufferTooSmall;

        var hasher = std.hash.crc.Crc32Iscsi.init();
        var offset: usize = 0;

        // lsn (8 bytes, little-endian)
        const lsn_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, self.lsn));
        @memcpy(buf[offset..][0..8], &lsn_bytes);
        hasher.update(&lsn_bytes);
        offset += 8;

        // txn_id (8 bytes)
        const txn_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, self.txn_id));
        @memcpy(buf[offset..][0..8], &txn_bytes);
        hasher.update(&txn_bytes);
        offset += 8;

        // record_type (1 byte)
        buf[offset] = @intFromEnum(self.record_type);
        hasher.update(&[_]u8{buf[offset]});
        offset += 1;

        // file_id (1 byte)
        buf[offset] = self.file_id;
        hasher.update(&[_]u8{buf[offset]});
        offset += 1;

        // page_id (8 bytes)
        const page_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, self.page_id));
        @memcpy(buf[offset..][0..8], &page_bytes);
        hasher.update(&page_bytes);
        offset += 8;

        // payload_len (4 bytes)
        const payload_len: u32 = @intCast(self.payload.len);
        const plen_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, payload_len));
        @memcpy(buf[offset..][0..4], &plen_bytes);
        hasher.update(&plen_bytes);
        offset += 4;

        // payload
        if (self.payload.len > 0) {
            @memcpy(buf[offset..][0..self.payload.len], self.payload);
            hasher.update(self.payload);
            offset += self.payload.len;
        }

        // Finalize checksum and write it
        self.checksum = hasher.final();
        @memcpy(buf[offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, self.checksum)));
        offset += CHECKSUM_SIZE;

        return offset;
    }

    /// Serialize the record to a newly allocated byte buffer.
    /// Convenience wrapper around `serializeInto` that allocates the buffer.
    pub fn serialize(self: *WalRecord, allocator: Allocator) ![]u8 {
        const total_size = self.serializedSize();
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        _ = self.serializeInto(buf) catch unreachable;
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

test "serializeInto writes into caller buffer and computes checksum inline" {
    const allocator = std.testing.allocator;
    const payload_data = "inline checksum test";

    var record = WalRecord{
        .lsn = 99,
        .txn_id = 12,
        .record_type = .page_update,
        .file_id = 5,
        .page_id = 200,
        .payload = payload_data,
        .checksum = 0,
    };

    // serializeInto should compute checksum as part of serialization
    var buf: [256]u8 = undefined;
    const n = try record.serializeInto(&buf);

    // checksum should have been set by serializeInto
    try std.testing.expect(record.checksum != 0);

    // The checksum should match what computeChecksum produces
    const expected_checksum = record.computeChecksum();
    try std.testing.expectEqual(expected_checksum, record.checksum);

    // Deserialize and verify round-trip
    const result = try WalRecord.deserialize(allocator, buf[0..n]);
    defer result.record.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 99), result.record.lsn);
    try std.testing.expectEqual(@as(u64, 12), result.record.txn_id);
    try std.testing.expectEqual(WalRecordType.page_update, result.record.record_type);
    try std.testing.expectEqual(@as(u8, 5), result.record.file_id);
    try std.testing.expectEqual(@as(u64, 200), result.record.page_id);
    try std.testing.expectEqualStrings(payload_data, result.record.payload);
    try std.testing.expectEqual(record.checksum, result.record.checksum);
    try std.testing.expectEqual(n, result.bytes_read);
}

test "serializeInto returns BufferTooSmall on undersized buffer" {
    var record = WalRecord{
        .lsn = 1,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };

    var tiny_buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, record.serializeInto(&tiny_buf));
}

test "serialize convenience wrapper matches serializeInto output" {
    const allocator = std.testing.allocator;
    const payload_data = "consistency check";

    var record1 = WalRecord{
        .lsn = 50,
        .txn_id = 3,
        .record_type = .page_update,
        .file_id = 1,
        .page_id = 77,
        .payload = payload_data,
        .checksum = 0,
    };

    var record2 = record1;

    // Use serializeInto
    var buf: [256]u8 = undefined;
    const n = try record1.serializeInto(&buf);

    // Use serialize (convenience wrapper)
    const heap_buf = try record2.serialize(allocator);
    defer allocator.free(heap_buf);

    // Both should produce identical output
    try std.testing.expectEqualSlices(u8, buf[0..n], heap_buf);
    try std.testing.expectEqual(record1.checksum, record2.checksum);
}

test {
    std.testing.refAllDecls(@This());
}
