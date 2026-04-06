// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_lib = @import("wal");
const wal_record = @import("wal_record.zig");
const WalRecord = wal_record.WalRecord;

/// Configuration for the WAL manager.
pub const WalConfig = struct {
    encryption_key: ?[32]u8 = null,
};

/// Manages WAL record persistence by delegating append-only storage to the
/// external wal library (gitlab.com/devnw/zig/wal). This module provides the
/// graph-storage-specific serialization layer (WalRecord types with
/// serialize/deserialize/checksum) on top of the library's crash-safe log.
pub const WalManager = struct {
    allocator: Allocator,
    inner: wal_lib.WriteAheadLog,
    current_lsn: u64,

    /// Initialize the WAL manager. Delegates segment management to the external
    /// wal library.
    ///
    /// `wal_dir` — open directory handle where the WAL file will live.
    /// `graph_uuid` — unused for now (reserved for multi-graph partitioning).
    /// `start_lsn` — the LSN to begin numbering from.
    /// `config` — optional encryption key and other settings.
    pub fn init(
        allocator: Allocator,
        wal_dir: std.fs.Dir,
        graph_uuid: [16]u8,
        start_lsn: u64,
        config: WalConfig,
    ) !WalManager {
        _ = graph_uuid;

        const inner = try wal_lib.WriteAheadLog.init(allocator, wal_dir, "graph.wal", .{
            .encryption_key = config.encryption_key,
            .manual_sync = true,
            .checkpoint = true,
        });

        return WalManager{
            .allocator = allocator,
            .inner = inner,
            .current_lsn = start_lsn,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *WalManager) void {
        self.inner.deinit();
    }

    /// Maximum record size that can be serialized on the stack.
    /// Records larger than this fall back to heap allocation.
    const STACK_BUF_SIZE: usize = 16 * 1024; // 16 KiB

    /// Append a WAL record. Assigns LSN, serializes with inline checksum
    /// computation (single pass), and delegates to the external library
    /// for persistence. Returns the assigned LSN.
    pub fn appendRecord(self: *WalManager, record: *WalRecord) !u64 {
        self.current_lsn += 1;
        record.lsn = self.current_lsn;

        const needed = record.serializedSize();

        if (needed <= STACK_BUF_SIZE) {
            // Fast path: use stack buffer, no heap allocation
            var buf: [STACK_BUF_SIZE]u8 = undefined;
            const n = try record.serializeInto(&buf);
            return try self.inner.append(buf[0..n]);
        } else {
            // Fallback: heap-allocate for very large payloads
            const buf = try self.allocator.alloc(u8, needed);
            defer self.allocator.free(buf);
            const n = try record.serializeInto(buf);
            return try self.inner.append(buf[0..n]);
        }
    }

    /// Sync the WAL to disk (fsync).
    pub fn sync(self: *WalManager) !void {
        try self.inner.sync();
    }

    /// Read all WAL records with LSN >= start_lsn by iterating over the
    /// external library's log. Caller owns the returned slice and each
    /// record's payload.
    pub fn readFrom(self: *WalManager, start_lsn: u64, allocator: Allocator) ![]WalRecord {
        var all_records: std.ArrayList(WalRecord) = .{};
        errdefer {
            for (all_records.items) |*r| r.deinit(allocator);
            all_records.deinit(allocator);
        }

        // The external library's iterator(lsn) is exclusive of the given LSN,
        // so subtract 1 to make our readFrom inclusive of start_lsn.
        const iter_from = if (start_lsn > 0) start_lsn - 1 else 0;
        var iter = try self.inner.iterator(iter_from);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch continue;

            if (result.record.lsn >= start_lsn) {
                try all_records.append(allocator, result.record);
            } else {
                result.record.deinit(allocator);
            }
        }

        return all_records.toOwnedSlice(allocator);
    }

    /// Truncate WAL: compact entries up to the given LSN.
    pub fn truncate(self: *WalManager, up_to_lsn: u64) !void {
        try self.inner.compact(up_to_lsn);
    }

    /// Current LSN (read-only accessor).
    pub fn currentLsn(self: *WalManager) u64 {
        return self.inner.currentLsn();
    }

    /// Bytes written since last compaction.
    pub fn bytesSinceCompact(self: *WalManager) u64 {
        return self.inner.bytesSinceCompact();
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

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
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
    try std.testing.expect(lsn1 > 0);

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
    try std.testing.expect(lsn2 > lsn1);

    try mgr.sync();

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

test "readFrom with start_lsn filters correctly" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xCC} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
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

    try mgr.sync();

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

test "truncate compacts old entries" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xDD} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
    defer mgr.deinit();

    // Append 10 records
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

    try mgr.sync();

    // Truncate up to LSN 5
    try mgr.truncate(5);

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
