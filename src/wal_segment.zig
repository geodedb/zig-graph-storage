// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_record = @import("wal_record.zig");
const WalRecord = wal_record.WalRecord;

/// Magic bytes identifying a WAL segment file.
pub const WAL_SEGMENT_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'W', 'A', 'L', '0', '1' };

/// WAL segment file format version.
pub const WAL_SEGMENT_VERSION: u32 = 1;

/// Segment header size: magic(8) + version(4) + segment_id(8) + graph_uuid(16) + reserved(28) = 64 bytes.
pub const SEGMENT_HEADER_SIZE: u64 = 64;

/// A single WAL segment file that stores WAL records sequentially.
pub const WalSegment = struct {
    file: std.fs.File,
    segment_id: u64,
    write_offset: u64,

    /// Create a new segment file at the given path.
    pub fn create(dir: std.fs.Dir, filename: []const u8, segment_id: u64, graph_uuid: [16]u8) !WalSegment {
        const file = try dir.createFile(filename, .{ .read = true });
        errdefer file.close();

        // Write header
        var header: [64]u8 = std.mem.zeroes([64]u8);

        // magic (8 bytes)
        @memcpy(header[0..8], &WAL_SEGMENT_MAGIC);

        // version (4 bytes, little-endian)
        @memcpy(header[8..12], &std.mem.toBytes(std.mem.nativeToLittle(u32, WAL_SEGMENT_VERSION)));

        // segment_id (8 bytes)
        @memcpy(header[12..20], &std.mem.toBytes(std.mem.nativeToLittle(u64, segment_id)));

        // graph_uuid (16 bytes)
        @memcpy(header[20..36], &graph_uuid);

        // reserved (28 bytes) - already zeroed

        try file.writeAll(&header);

        return WalSegment{
            .file = file,
            .segment_id = segment_id,
            .write_offset = SEGMENT_HEADER_SIZE,
        };
    }

    /// Open an existing segment file and validate its header.
    pub fn open(dir: std.fs.Dir, filename: []const u8) !WalSegment {
        const file = try dir.openFile(filename, .{ .mode = .read_write });
        errdefer file.close();

        // Read and validate header
        var header: [64]u8 = undefined;
        const bytes_read = try file.readAll(&header);
        if (bytes_read < 64) return error.InvalidFormat;

        // Validate magic
        if (!std.mem.eql(u8, header[0..8], &WAL_SEGMENT_MAGIC)) return error.InvalidMagic;

        // Read segment_id
        const segment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, header[12..20]));

        // Seek to end to determine write_offset
        const end_pos = try file.getEndPos();

        return WalSegment{
            .file = file,
            .segment_id = segment_id,
            .write_offset = end_pos,
        };
    }

    /// Append serialized record bytes to this segment.
    pub fn append(self: *WalSegment, record_bytes: []const u8) !void {
        try self.file.seekTo(self.write_offset);
        try self.file.writeAll(record_bytes);
        self.write_offset += record_bytes.len;
    }

    /// Sync segment file to disk (fsync).
    pub fn sync(self: *WalSegment) !void {
        try self.file.sync();
    }

    /// Close the segment file.
    pub fn close(self: *WalSegment) void {
        self.file.close();
    }

    /// Read all WAL records from this segment starting at the given offset.
    /// Caller owns the returned slice and each record's payload.
    pub fn readRecords(self: *WalSegment, allocator: Allocator, start_offset: u64) ![]WalRecord {
        const end_pos = try self.file.getEndPos();
        if (start_offset >= end_pos) return try allocator.alloc(WalRecord, 0);

        const data_len = end_pos - start_offset;
        const buf = try allocator.alloc(u8, data_len);
        defer allocator.free(buf);

        try self.file.seekTo(start_offset);
        const bytes_read = try self.file.readAll(buf);
        if (bytes_read == 0) return try allocator.alloc(WalRecord, 0);

        var records: std.ArrayList(WalRecord) = .{};
        errdefer {
            for (records.items) |*r| r.deinit(allocator);
            records.deinit(allocator);
        }

        var offset: usize = 0;
        while (offset < bytes_read) {
            const result = WalRecord.deserialize(allocator, buf[offset..bytes_read]) catch break;
            try records.append(allocator, result.record);
            offset += result.bytes_read;
        }

        return records.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "create and open segment round-trip" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

    // Create segment
    {
        var seg = try WalSegment.create(tmp_dir.dir, "seg_000000.wal", 0, uuid);
        defer seg.close();
        try std.testing.expectEqual(@as(u64, 0), seg.segment_id);
        try std.testing.expectEqual(SEGMENT_HEADER_SIZE, seg.write_offset);
    }

    // Open segment
    {
        var seg = try WalSegment.open(tmp_dir.dir, "seg_000000.wal");
        defer seg.close();
        try std.testing.expectEqual(@as(u64, 0), seg.segment_id);
        try std.testing.expectEqual(SEGMENT_HEADER_SIZE, seg.write_offset);
    }
}

test "append and read records from segment" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xAB} ** 16;

    var seg = try WalSegment.create(tmp_dir.dir, "seg_000001.wal", 1, uuid);
    defer seg.close();

    // Create and append two records
    const payload = "test data";
    var rec1 = WalRecord{
        .lsn = 1,
        .txn_id = 10,
        .record_type = .page_update,
        .file_id = 0,
        .page_id = 5,
        .payload = payload,
        .checksum = 0,
    };
    rec1.checksum = rec1.computeChecksum();

    var rec2 = WalRecord{
        .lsn = 2,
        .txn_id = 10,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    rec2.checksum = rec2.computeChecksum();

    const bytes1 = try rec1.serialize(allocator);
    defer allocator.free(bytes1);
    try seg.append(bytes1);

    const bytes2 = try rec2.serialize(allocator);
    defer allocator.free(bytes2);
    try seg.append(bytes2);

    try seg.sync();

    // Read all records back
    const records = try seg.readRecords(allocator, SEGMENT_HEADER_SIZE);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(@as(u64, 1), records[0].lsn);
    try std.testing.expectEqual(wal_record.WalRecordType.page_update, records[0].record_type);
    try std.testing.expectEqualStrings(payload, records[0].payload);
    try std.testing.expectEqual(@as(u64, 2), records[1].lsn);
    try std.testing.expectEqual(wal_record.WalRecordType.commit_txn, records[1].record_type);
}

test "open rejects file with invalid magic" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write a file with bad magic
    const file = try tmp_dir.dir.createFile("bad.wal", .{});
    var header: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(header[0..8], "BADMAGIC");
    try file.writeAll(&header);
    file.close();

    const result = WalSegment.open(tmp_dir.dir, "bad.wal");
    try std.testing.expectError(error.InvalidMagic, result);
}

test {
    std.testing.refAllDecls(@This());
}
