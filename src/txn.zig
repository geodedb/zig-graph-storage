// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_mod = @import("wal.zig");
const wal_record = @import("wal_record.zig");
const config_mod = @import("config.zig");
const WalManager = wal_mod.WalManager;
const WalRecord = wal_record.WalRecord;
const WalRecordType = wal_record.WalRecordType;
const SyncMode = config_mod.SyncMode;

/// State of a transaction.
pub const TxnState = enum {
    active,
    committed,
    aborted,
};

/// Tracks active transactions and coordinates WAL writes.
pub const TxnManager = struct {
    next_txn_id: u64,
    txn_id_mutex: std.Io.Mutex,
    active_txns: std.AutoHashMap(u64, TxnState),
    wal: *WalManager,
    allocator: Allocator,
    /// Commit durability policy. DEFAULT (`sync_each_commit`) fsyncs the WAL
    /// on every commit; `deferred` skips the per-commit fsync (relaxed
    /// durability — see `config.SyncMode`). Wired from `GraphConfig.sync_mode`
    /// at engine init.
    sync_mode: SyncMode = .sync_each_commit,

    /// Initialize the transaction manager. Defaults to `sync_each_commit`
    /// (per-commit fsync). Callers that opt into a relaxed policy should set
    /// `sync_mode` after init via `initWithSyncMode`.
    pub fn init(allocator: Allocator, wal: *WalManager, start_txn_id: u64) TxnManager {
        return initWithSyncMode(allocator, wal, start_txn_id, .sync_each_commit);
    }

    /// Initialize the transaction manager with an explicit commit sync policy.
    pub fn initWithSyncMode(
        allocator: Allocator,
        wal: *WalManager,
        start_txn_id: u64,
        sync_mode: SyncMode,
    ) TxnManager {
        return TxnManager{
            .next_txn_id = start_txn_id,
            .txn_id_mutex = std.Io.Mutex.init,
            .active_txns = std.AutoHashMap(u64, TxnState).init(allocator),
            .wal = wal,
            .allocator = allocator,
            .sync_mode = sync_mode,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *TxnManager) void {
        self.active_txns.deinit();
    }

    /// Begin a new transaction. Writes a BEGIN record to the WAL.
    /// Returns the new transaction ID.
    pub fn begin(self: *TxnManager) !u64 {
        self.txn_id_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const txn_id = self.next_txn_id;
        self.next_txn_id += 1;
        self.txn_id_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var rec = WalRecord{
            .lsn = 0,
            .txn_id = txn_id,
            .record_type = .begin_txn,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        _ = try self.wal.appendRecord(&rec);

        try self.active_txns.put(txn_id, .active);
        return txn_id;
    }

    /// Commit a transaction. Writes a COMMIT record to the WAL.
    ///
    /// Durability depends on `sync_mode`:
    ///   - `sync_each_commit` (DEFAULT): fsync the WAL before returning, so an
    ///     acknowledged commit is crash-durable when this returns
    ///     (NFR-SEC-003 — unchanged behavior).
    ///   - `deferred`: skip the per-commit fsync (relaxed durability). The
    ///     COMMIT record is appended but only reaches stable storage at the
    ///     next durability barrier (checkpoint / clean close); commits since
    ///     the last barrier may be lost on an unclean shutdown. See
    ///     `config.SyncMode.deferred`.
    pub fn commit(self: *TxnManager, txn_id: u64) !void {
        const state = self.active_txns.get(txn_id) orelse return error.TxnNotFound;
        if (state == .committed) return error.TxnAlreadyCommitted;
        if (state == .aborted) return error.TxnAlreadyAborted;

        var rec = WalRecord{
            .lsn = 0,
            .txn_id = txn_id,
            .record_type = .commit_txn,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        _ = try self.wal.appendRecord(&rec);
        switch (self.sync_mode) {
            .sync_each_commit => try self.wal.sync(),
            .deferred => {},
        }

        _ = self.active_txns.remove(txn_id);
    }

    /// Abort a transaction. Writes an ABORT record to the WAL.
    pub fn abort(self: *TxnManager, txn_id: u64) !void {
        const state = self.active_txns.get(txn_id) orelse return error.TxnNotFound;
        if (state == .committed) return error.TxnAlreadyCommitted;
        if (state == .aborted) return error.TxnAlreadyAborted;

        var rec = WalRecord{
            .lsn = 0,
            .txn_id = txn_id,
            .record_type = .abort_txn,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        _ = try self.wal.appendRecord(&rec);

        _ = self.active_txns.remove(txn_id);
    }

    /// Check if a transaction is currently active.
    pub fn isActive(self: *const TxnManager, txn_id: u64) bool {
        const state = self.active_txns.get(txn_id) orelse return false;
        return state == .active;
    }

    /// Log a page update for an active transaction.
    /// Returns the LSN assigned to this record.
    pub fn logPageUpdate(
        self: *TxnManager,
        txn_id: u64,
        file_id: u8,
        page_id: u64,
        page_data: []const u8,
    ) !u64 {
        const state = self.active_txns.get(txn_id) orelse return error.TxnNotFound;
        if (state != .active) return error.TxnAlreadyCommitted;

        var rec = WalRecord{
            .lsn = 0,
            .txn_id = txn_id,
            .record_type = .page_update,
            .file_id = file_id,
            .page_id = page_id,
            .payload = page_data,
            .checksum = 0,
        };
        return try self.wal.appendRecord(&rec);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

fn setupTestWal(allocator: Allocator, tmp_dir: *std.testing.TmpDir) !WalManager {
    const uuid = [_]u8{0xEE} ** 16;
    return try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
}

test "begin returns incrementing IDs" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var wal = try setupTestWal(allocator, &tmp_dir);
    defer wal.deinit();

    var txn_mgr = TxnManager.init(allocator, &wal, 1);
    defer txn_mgr.deinit();

    const id1 = try txn_mgr.begin();
    const id2 = try txn_mgr.begin();
    const id3 = try txn_mgr.begin();

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
}

test "commit writes COMMIT record" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var wal = try setupTestWal(allocator, &tmp_dir);
    defer wal.deinit();

    var txn_mgr = TxnManager.init(allocator, &wal, 1);
    defer txn_mgr.deinit();

    const txn_id = try txn_mgr.begin();
    try txn_mgr.commit(txn_id);

    // Read WAL to verify commit record was written
    const records = try wal.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(WalRecordType.begin_txn, records[0].record_type);
    try std.testing.expectEqual(WalRecordType.commit_txn, records[1].record_type);
    try std.testing.expectEqual(txn_id, records[1].txn_id);
}

test "abort writes ABORT record" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var wal = try setupTestWal(allocator, &tmp_dir);
    defer wal.deinit();

    var txn_mgr = TxnManager.init(allocator, &wal, 1);
    defer txn_mgr.deinit();

    const txn_id = try txn_mgr.begin();
    try txn_mgr.abort(txn_id);

    // Read WAL to verify abort record was written
    const records = try wal.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(WalRecordType.begin_txn, records[0].record_type);
    try std.testing.expectEqual(WalRecordType.abort_txn, records[1].record_type);
    try std.testing.expectEqual(txn_id, records[1].txn_id);
}

test "isActive returns true for active, false for committed/aborted" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var wal = try setupTestWal(allocator, &tmp_dir);
    defer wal.deinit();

    var txn_mgr = TxnManager.init(allocator, &wal, 1);
    defer txn_mgr.deinit();

    const txn1 = try txn_mgr.begin();
    const txn2 = try txn_mgr.begin();
    const txn3 = try txn_mgr.begin();

    // All active initially
    try std.testing.expect(txn_mgr.isActive(txn1));
    try std.testing.expect(txn_mgr.isActive(txn2));
    try std.testing.expect(txn_mgr.isActive(txn3));

    // Commit txn1
    try txn_mgr.commit(txn1);
    try std.testing.expect(!txn_mgr.isActive(txn1));
    try std.testing.expect(txn_mgr.isActive(txn2));

    // Abort txn2
    try txn_mgr.abort(txn2);
    try std.testing.expect(!txn_mgr.isActive(txn2));
    try std.testing.expect(txn_mgr.isActive(txn3));

    // Unknown txn
    try std.testing.expect(!txn_mgr.isActive(999));
}

test "logPageUpdate appends page_update record with correct txn_id" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var wal = try setupTestWal(allocator, &tmp_dir);
    defer wal.deinit();

    var txn_mgr = TxnManager.init(allocator, &wal, 1);
    defer txn_mgr.deinit();

    const txn_id = try txn_mgr.begin();
    const page_data = "page after-image data here";
    const lsn = try txn_mgr.logPageUpdate(txn_id, 3, 42, page_data);

    try std.testing.expect(lsn > 0);

    // Read WAL records and verify
    const records = try wal.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 2), records.len);
    // First record is BEGIN
    try std.testing.expectEqual(WalRecordType.begin_txn, records[0].record_type);
    // Second record is page_update
    try std.testing.expectEqual(WalRecordType.page_update, records[1].record_type);
    try std.testing.expectEqual(txn_id, records[1].txn_id);
    try std.testing.expectEqual(@as(u8, 3), records[1].file_id);
    try std.testing.expectEqual(@as(u64, 42), records[1].page_id);
    try std.testing.expectEqualStrings(page_data, records[1].payload);
}

test {
    std.testing.refAllDecls(@This());
}
