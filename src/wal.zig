// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const wal_lib = @import("wal");
const wal_record = @import("wal_record.zig");
const WalRecord = wal_record.WalRecord;
const GRAPH_IDENTITY_FILE = "graph.uuid";

/// Configuration for the WAL manager.
pub const WalConfig = struct {
    encryption_key: ?[32]u8 = null,
    create_identity_if_missing: bool = true,
};

pub const ReplayFailureKind = enum {
    deserialize_failed,
    checksum_mismatch,
};

pub const ReplayFailure = struct {
    artifact: []const u8 = "wal/graph.wal",
    lsn: u64,
    kind: ReplayFailureKind,
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
        wal_dir: std.Io.Dir,
        graph_uuid: [16]u8,
        start_lsn: u64,
        config: WalConfig,
    ) !WalManager {
        try ensureGraphIdentity(wal_dir, graph_uuid, config.create_identity_if_missing);

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

    /// TEST-ONLY: append already-serialized record bytes verbatim, bypassing
    /// the checksum recomputation that `appendRecord` performs. This exists so
    /// tests can inject malformed / forged WAL records (e.g. a record whose
    /// stored checksum does not match its contents) to exercise the strict,
    /// fail-closed recovery path. Returns the assigned inner-log LSN.
    pub fn appendRawForTest(self: *WalManager, bytes: []const u8) !u64 {
        if (!builtin.is_test) return error.TestOnly;
        self.current_lsn += 1;
        return try self.inner.append(bytes);
    }

    /// Read all WAL records with LSN >= start_lsn by iterating over the
    /// external library's log. Caller owns the returned slice and each
    /// record's payload.
    pub fn readFrom(self: *WalManager, start_lsn: u64, allocator: Allocator) ![]WalRecord {
        var all_records: std.ArrayList(WalRecord) = .empty;
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

    /// Stream WAL records with LSN >= start_lsn through `callback`.
    /// Each deserialized record is deinitialized before the next record is read,
    /// keeping replay memory bounded by one record at a time.
    pub fn forEachFrom(
        self: *WalManager,
        start_lsn: u64,
        allocator: Allocator,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), *const WalRecord) anyerror!void,
    ) !void {
        const iter_from = if (start_lsn > 0) start_lsn - 1 else 0;
        var iter = try self.inner.iterator(iter_from);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch continue;
            defer result.record.deinit(allocator);

            if (result.record.lsn >= start_lsn) {
                try callback(ctx, &result.record);
            }
        }
    }

    /// Strict WAL streaming variant used by recovery and verify.
    /// Returns an error when a deserialized record fails its payload checksum or
    /// cannot be decoded, and reports the offending LSN through `failure`.
    pub fn forEachFromStrict(
        self: *WalManager,
        start_lsn: u64,
        allocator: Allocator,
        failure: *?ReplayFailure,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), *const WalRecord) anyerror!void,
    ) !void {
        failure.* = null;

        const iter_from = if (start_lsn > 0) start_lsn - 1 else 0;
        var iter = try self.inner.iterator(iter_from);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch {
                failure.* = .{
                    .lsn = entry.lsn,
                    .kind = .deserialize_failed,
                };
                return error.InvalidFormat;
            };
            defer result.record.deinit(allocator);

            if (result.record.checksum != result.record.computeChecksum()) {
                failure.* = .{
                    .lsn = result.record.lsn,
                    .kind = .checksum_mismatch,
                };
                return error.ChecksumMismatch;
            }

            if (result.record.lsn >= start_lsn) {
                try callback(ctx, &result.record);
            }
        }
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

fn ensureGraphIdentity(wal_dir: std.Io.Dir, graph_uuid: [16]u8, create_if_missing: bool) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = wal_dir.openFile(io, GRAPH_IDENTITY_FILE, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => if (!create_if_missing) {
            return error.FileNotFound;
        } else blk: {
            const new_file = try wal_dir.createFile(io, GRAPH_IDENTITY_FILE, .{ .read = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
            break :blk new_file;
        },
        else => return err,
    };
    defer file.close(io);

    var stored_uuid: [16]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &stored_uuid, 0);
    if (bytes_read == 0) {
        try file.writePositionalAll(io, &graph_uuid, 0);
        try file.sync(io);
        return;
    }
    if (bytes_read != stored_uuid.len) return error.InvalidData;
    if (!std.mem.eql(u8, &stored_uuid, &graph_uuid)) return error.UuidMismatch;
}

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

test "GAP-0032: init rejects a WAL directory bound to a different graph UUID" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid_a = [_]u8{0xAA} ** 16;
    const uuid_b = [_]u8{0xBB} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid_a, 0, .{});
    mgr.deinit();

    try std.testing.expectError(error.UuidMismatch, WalManager.init(allocator, tmp_dir.dir, uuid_b, 0, .{}));
}

test "forEachFrom streams records in order" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xEE} ** 16;
    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
    defer mgr.deinit();

    for (0..4) |i| {
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

    const Ctx = struct {
        count: usize = 0,
        last_lsn: u64 = 0,

        fn visit(self: *@This(), rec: *const WalRecord) !void {
            self.count += 1;
            try std.testing.expect(rec.lsn > self.last_lsn);
            self.last_lsn = rec.lsn;
        }
    };

    var ctx = Ctx{};
    try mgr.forEachFrom(2, allocator, &ctx, Ctx.visit);
    try std.testing.expectEqual(@as(usize, 3), ctx.count);
    try std.testing.expectEqual(@as(u64, 4), ctx.last_lsn);
}

test {
    std.testing.refAllDecls(@This());
}
