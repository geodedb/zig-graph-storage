// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_record = @import("wal_record.zig");
const wal_segment = @import("wal_segment.zig");
const WalRecord = wal_record.WalRecord;
const WalSegment = wal_segment.WalSegment;
const SEGMENT_HEADER_SIZE = wal_segment.SEGMENT_HEADER_SIZE;

/// Manages multiple WAL segment files, handling record appending,
/// segment rolling, reading, and truncation.
pub const WalManager = struct {
    allocator: Allocator,
    wal_dir: std.fs.Dir,
    graph_uuid: [16]u8,
    current_segment: ?WalSegment,
    current_lsn: u64,
    segment_size_limit: u64,
    segment_counter: u64,

    /// Initialize the WAL manager. Creates the WAL directory if it does not exist.
    pub fn init(
        allocator: Allocator,
        base_dir: std.fs.Dir,
        wal_subdir: []const u8,
        graph_uuid: [16]u8,
        start_lsn: u64,
        segment_size_limit: u64,
    ) !WalManager {
        // Ensure the WAL directory exists
        base_dir.makeDir(wal_subdir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const wal_dir = try base_dir.openDir(wal_subdir, .{ .iterate = true });

        return WalManager{
            .allocator = allocator,
            .wal_dir = wal_dir,
            .graph_uuid = graph_uuid,
            .current_segment = null,
            .current_lsn = start_lsn,
            .segment_size_limit = segment_size_limit,
            .segment_counter = 0,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *WalManager) void {
        if (self.current_segment) |*seg| {
            seg.close();
            self.current_segment = null;
        }
        self.wal_dir.close();
    }

    /// Format a segment filename: seg_NNNNNN.wal
    fn segmentFilename(buf: *[20]u8, counter: u64) []const u8 {
        const result = std.fmt.bufPrint(buf, "seg_{d:0>6}.wal", .{counter}) catch unreachable;
        return result;
    }

    /// Ensure there is an active segment, creating one if necessary.
    fn ensureSegment(self: *WalManager) !void {
        if (self.current_segment != null) return;
        var buf: [20]u8 = undefined;
        const filename = segmentFilename(&buf, self.segment_counter);
        self.current_segment = try WalSegment.create(self.wal_dir, filename, self.segment_counter, self.graph_uuid);
    }

    /// Roll to a new segment if the current one exceeds the size limit.
    fn maybeRollSegment(self: *WalManager) !void {
        if (self.current_segment) |*seg| {
            if (seg.write_offset >= self.segment_size_limit) {
                seg.sync() catch {};
                seg.close();
                self.current_segment = null;
                self.segment_counter += 1;
            }
        }
    }

    /// Append a WAL record. Assigns LSN, computes checksum, serializes,
    /// and appends to the current segment. Rolls to a new segment if needed.
    /// Returns the assigned LSN.
    pub fn appendRecord(self: *WalManager, record: *WalRecord) !u64 {
        // Assign LSN
        self.current_lsn += 1;
        record.lsn = self.current_lsn;
        record.checksum = record.computeChecksum();

        const bytes = try record.serialize(self.allocator);
        defer self.allocator.free(bytes);

        try self.maybeRollSegment();
        try self.ensureSegment();

        try self.current_segment.?.append(bytes);

        return record.lsn;
    }

    /// Sync the current segment to disk.
    pub fn syncCurrentSegment(self: *WalManager) !void {
        if (self.current_segment) |*seg| {
            try seg.sync();
        }
    }

    /// Read all WAL records with LSN >= start_lsn by scanning all segment files.
    /// Caller owns the returned slice and each record's payload.
    pub fn readFrom(self: *WalManager, start_lsn: u64, allocator: Allocator) ![]WalRecord {
        var all_records: std.ArrayList(WalRecord) = .{};
        errdefer {
            for (all_records.items) |*r| r.deinit(allocator);
            all_records.deinit(allocator);
        }

        // Collect segment filenames
        var filenames: std.ArrayList([]u8) = .{};
        defer {
            for (filenames.items) |f| allocator.free(f);
            filenames.deinit(allocator);
        }

        var iter = self.wal_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "seg_")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
            const name_copy = try allocator.alloc(u8, entry.name.len);
            @memcpy(name_copy, entry.name);
            try filenames.append(allocator, name_copy);
        }

        // Sort by name to process segments in order
        std.mem.sort([]u8, filenames.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // Read records from each segment
        for (filenames.items) |filename| {
            var seg = WalSegment.open(self.wal_dir, filename) catch continue;
            defer seg.close();

            const records = try seg.readRecords(allocator, SEGMENT_HEADER_SIZE);
            defer allocator.free(records);

            for (records) |rec| {
                if (rec.lsn >= start_lsn) {
                    try all_records.append(allocator, rec);
                } else {
                    rec.deinit(allocator);
                }
            }
        }

        return all_records.toOwnedSlice(allocator);
    }

    /// Truncate WAL: remove segment files whose maximum LSN <= up_to_lsn.
    /// The current active segment is never removed.
    pub fn truncate(self: *WalManager, up_to_lsn: u64) !void {
        var filenames: std.ArrayList([]u8) = .{};
        defer {
            for (filenames.items) |f| self.allocator.free(f);
            filenames.deinit(self.allocator);
        }

        var iter = self.wal_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "seg_")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
            const name_copy = try self.allocator.alloc(u8, entry.name.len);
            @memcpy(name_copy, entry.name);
            try filenames.append(self.allocator, name_copy);
        }

        for (filenames.items) |filename| {
            // Don't remove the current active segment
            if (self.current_segment) |seg| {
                var current_buf: [20]u8 = undefined;
                const current_name = segmentFilename(&current_buf, seg.segment_id);
                if (std.mem.eql(u8, filename, current_name)) continue;
            }

            // Open segment, read records, check max LSN
            var seg = WalSegment.open(self.wal_dir, filename) catch continue;
            const records = seg.readRecords(self.allocator, SEGMENT_HEADER_SIZE) catch {
                seg.close();
                continue;
            };
            defer {
                for (records) |*r| r.deinit(self.allocator);
                self.allocator.free(records);
            }
            seg.close();

            if (records.len == 0) {
                // Empty segment (besides header) - safe to remove
                self.wal_dir.deleteFile(filename) catch {};
                continue;
            }

            // Find max LSN in this segment
            var max_lsn: u64 = 0;
            for (records) |r| {
                if (r.lsn > max_lsn) max_lsn = r.lsn;
            }

            if (max_lsn <= up_to_lsn) {
                self.wal_dir.deleteFile(filename) catch {};
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "append records, sync, read back" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xAA} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, "wal", uuid, 0, 1024 * 1024);
    defer mgr.deinit();

    // Append some records
    var rec1 = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    const lsn1 = try mgr.appendRecord(&rec1);
    try std.testing.expectEqual(@as(u64, 1), lsn1);

    const payload = "page content";
    var rec2 = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 2,
        .page_id = 42,
        .payload = payload,
        .checksum = 0,
    };
    const lsn2 = try mgr.appendRecord(&rec2);
    try std.testing.expectEqual(@as(u64, 2), lsn2);

    try mgr.syncCurrentSegment();

    // Read back all records
    const records = try mgr.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(@as(u64, 1), records[0].lsn);
    try std.testing.expectEqual(wal_record.WalRecordType.begin_txn, records[0].record_type);
    try std.testing.expectEqual(@as(u64, 2), records[1].lsn);
    try std.testing.expectEqualStrings(payload, records[1].payload);
}

test "segment rolling when size limit exceeded" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xBB} ** 16;

    // Very small segment limit to force rolling
    var mgr = try WalManager.init(allocator, tmp_dir.dir, "wal", uuid, 0, SEGMENT_HEADER_SIZE + 50);
    defer mgr.deinit();

    // Append several records - should roll segments
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        var rec = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .page_update,
            .file_id = 0,
            .page_id = i,
            .payload = "data",
            .checksum = 0,
        };
        _ = try mgr.appendRecord(&rec);
    }

    // Should have rolled to multiple segments
    try std.testing.expect(mgr.segment_counter > 0);

    // Read all records back
    const records = try mgr.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 5), records.len);
    for (records, 1..) |rec, expected_lsn| {
        try std.testing.expectEqual(@as(u64, expected_lsn), rec.lsn);
    }
}

test "readFrom with start_lsn filters correctly" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xCC} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, "wal", uuid, 0, 1024 * 1024);
    defer mgr.deinit();

    // Append 5 records (LSN 1-5)
    for (0..5) |_| {
        var rec = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .begin_txn,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        _ = try mgr.appendRecord(&rec);
    }

    try mgr.syncCurrentSegment();

    // Read from LSN 3 - should only get 3 records (LSN 3, 4, 5)
    const records = try mgr.readFrom(3, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 3), records.len);
    try std.testing.expectEqual(@as(u64, 3), records[0].lsn);
    try std.testing.expectEqual(@as(u64, 4), records[1].lsn);
    try std.testing.expectEqual(@as(u64, 5), records[2].lsn);
}

test "truncate removes old segments" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xDD} ** 16;

    // Small limit to create multiple segments
    var mgr = try WalManager.init(allocator, tmp_dir.dir, "wal", uuid, 0, SEGMENT_HEADER_SIZE + 50);
    defer mgr.deinit();

    // Append records to create multiple segments
    for (0..10) |_| {
        var rec = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .page_update,
            .file_id = 0,
            .page_id = 0,
            .payload = "data",
            .checksum = 0,
        };
        _ = try mgr.appendRecord(&rec);
    }

    try mgr.syncCurrentSegment();

    // Count segments before truncation
    var count_before: usize = 0;
    {
        var iter = mgr.wal_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wal")) {
                count_before += 1;
            }
        }
    }
    try std.testing.expect(count_before > 1);

    // Truncate up to LSN 5 - should remove segments with max LSN <= 5
    try mgr.truncate(5);

    // Count segments after truncation - should have fewer
    var count_after: usize = 0;
    {
        var iter = mgr.wal_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wal")) {
                count_after += 1;
            }
        }
    }
    try std.testing.expect(count_after < count_before);

    // All records with LSN > 5 should still be readable
    const records = try mgr.readFrom(6, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    // Should have records with LSN 6-10
    for (records) |rec| {
        try std.testing.expect(rec.lsn >= 6);
    }
    try std.testing.expectEqual(@as(usize, 5), records.len);
}

test {
    std.testing.refAllDecls(@This());
}
