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

    // ------------------------------------------------------------------
    // GAP-0900: per-transaction WAL record batching.
    //
    // When a caller opens a batch (`beginBatch`) the page-update records
    // produced while applying that ONE transaction are serialized into
    // owned buffers and collected here instead of being written one
    // syscall at a time. `flushBatch` writes the whole collection with a
    // SINGLE `inner.appendBatch` — byte-identical on-disk output to N
    // `inner.append` calls, same LSN scheme — right before the commit
    // record + fsync decision. This drops the writev syscall count from
    // O(pages) to O(1) per coordinator batch. Every record still reaches
    // the OS page cache before its txn's commit record (the buffer never
    // survives the commit/abort boundary).
    //
    // Buffering is scoped to a single txn id (`batch_txn_id`). Records for
    // any OTHER txn — or any caller that never opened a batch — fall
    // straight through to the per-record `inner.append` path.
    //
    // SONNY-6473: batching DOES change the log when transactions overlap. A
    // batched record is numbered (and its page image taken) in
    // `appendRecord`, but written only at flush; a record of another txn
    // appended meanwhile is numbered later and written earlier. The log is
    // then not in LSN order, and an older image of a page can follow a
    // newer one. Recovery therefore applies, per (file, page), only the
    // highest-LSN committed image (recovery.zig, `applied_lsn`); it must
    // never rely on log order between transactions.
    /// True while a batch is open and collecting records for `batch_txn_id`.
    batch_active: bool = false,
    /// The txn id whose page-update records are collected into the arena.
    batch_txn_id: u64 = 0,
    /// Contiguous byte arena holding all serialized records of the open
    /// batch back-to-back. Retained (capacity kept) across batches so steady
    /// state incurs no per-record heap allocation — matching the per-record
    /// stack-buffer fast path's allocation profile (PERF-0055).
    batch_arena: std.ArrayList(u8) = .empty,
    /// (offset, len) of each record within `batch_arena`. Resolved into the
    /// `[]const []const u8` that `inner.appendBatch` needs at flush time.
    /// Retained across batches alongside the arena.
    batch_spans: std.ArrayList(Span) = .empty,
    /// Scratch slice array materialized at flush time from `batch_spans` +
    /// `batch_arena` and handed to `inner.appendBatch`. Retained across
    /// batches to avoid a per-flush allocation. Held separately from the
    /// arena because the arena pointer can only be resolved once it has
    /// stopped growing (i.e. at flush, not during collection).
    batch_ptrs: std.ArrayList([]const u8) = .empty,
    /// SONNY-6622: checkpoint compactions the wal library refused (the log no
    /// longer validates: `WalCorrupted`, `WalAuthFailed`,
    /// `WalEncryptionMismatch`). The log keeps its records and stays usable;
    /// the next open reports the damage.
    compactions_refused: u64 = 0,

    const Span = struct { off: usize, len: usize };

    /// Initialize the WAL manager. Delegates segment management to the external
    /// wal library.
    ///
    /// `wal_dir` — open directory handle where the WAL file will live.
    /// `graph_uuid` — unused for now (reserved for multi-graph partitioning).
    /// `start_lsn` — the durable checkpoint frontier
    ///   (`manifest.last_checkpoint_lsn`); the next record is numbered above it.
    /// `config` — optional encryption key and other settings.
    ///
    /// SONNY-6424: an empty inner log keeps its sequence number only in the
    /// wal library's `graph.wal.ckpt` sidecar, which `compact()` deletes and
    /// only a clean `deinit` rewrites. After a checkpoint empties the log and
    /// the process exits without closing, the inner log reopens at 0, below
    /// `start_lsn`. Re-anchor it here with a durable `checkpoint_marker` record
    /// at exactly `start_lsn`, so every later record is numbered above the
    /// frontier and the anchor survives the next crash without the sidecar.
    pub fn init(
        allocator: Allocator,
        wal_dir: std.Io.Dir,
        graph_uuid: [16]u8,
        start_lsn: u64,
        config: WalConfig,
    ) !WalManager {
        try ensureGraphIdentity(wal_dir, graph_uuid, config.create_identity_if_missing);

        // SONNY-6622: wal 0.1.24 refuses, and leaves untouched, a log it
        // cannot decode instead of truncating it. Records of the other key
        // mode or that authenticate under no record's key mean the store's
        // WAL was written under another key (or without one): the same
        // refusal as a manifest that fails its HMAC. WalCorrupted (a bad
        // record with valid records after it) passes through as itself.
        var inner = wal_lib.WriteAheadLog.init(allocator, wal_dir, "graph.wal", .{
            .encryption_key = config.encryption_key,
            .manual_sync = true,
            .checkpoint = true,
        }) catch |err| switch (err) {
            error.WalAuthFailed, error.WalEncryptionMismatch => return error.EncryptionKeyMismatch,
            else => return err,
        };
        errdefer inner.deinit();

        if (inner.currentLsn() < start_lsn) {
            try appendLsnAnchor(&inner, start_lsn);
        }

        return WalManager{
            .allocator = allocator,
            .inner = inner,
            .current_lsn = @max(start_lsn, inner.currentLsn()),
        };
    }

    /// Append and fsync a payload-free `checkpoint_marker` record numbered
    /// `lsn` (SONNY-6424). Recovery never replays it: it carries no page image
    /// and sits at the checkpoint frontier, which recovery starts after.
    fn appendLsnAnchor(inner: *wal_lib.WriteAheadLog, lsn: u64) !void {
        var anchor = WalRecord{
            .lsn = lsn,
            .txn_id = 0,
            .record_type = .checkpoint_marker,
            .file_id = 0,
            .page_id = 0,
            .payload = &.{},
            .checksum = 0,
        };
        var buf: [64]u8 = undefined; // header + checksum, no payload
        const n = try anchor.serializeInto(&buf);
        _ = try inner.appendWithLsn(lsn, buf[0..n]);
        try inner.sync();
    }

    /// SONNY-6424: whether a record read back from the inner log lies after
    /// the checkpoint frontier `start_lsn`. Either numbering placing it there
    /// is enough. The inner LSN alone is not: a store written by a binary
    /// without the anchor above can hold post-checkpoint records whose inner
    /// LSN restarted from 1, while their graph-storage LSN (seeded from the
    /// frontier) is still above it. The record's own LSN alone is not either:
    /// a record buffered in a batch is numbered before an interleaved direct
    /// append but written after it.
    fn isAtOrAfter(inner_lsn: u64, record_lsn: u64, start_lsn: u64) bool {
        return inner_lsn >= start_lsn or record_lsn >= start_lsn;
    }

    /// Clean up resources.
    pub fn deinit(self: *WalManager) void {
        // Drop any records buffered but never flushed (e.g. a batch left
        // open at shutdown). These were NEVER written to the log, so this
        // is consistent with abort semantics — no durability is lost.
        self.batch_arena.deinit(self.allocator);
        self.batch_spans.deinit(self.allocator);
        self.batch_ptrs.deinit(self.allocator);
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

        // GAP-0900: when a batch is open for THIS record's txn, serialize
        // into an owned buffer and collect it instead of issuing a syscall.
        // The LSN is assigned above exactly as in the per-record path, so
        // ordering/contiguity are preserved; `flushBatch` later writes the
        // whole collection via `inner.appendBatch`. Any record for a
        // different txn — or when no batch is open — takes the immediate
        // write path below.
        if (self.batch_active and record.txn_id == self.batch_txn_id) {
            const off = self.batch_arena.items.len;
            // Grow the arena in place (capacity retained across batches), then
            // serialize directly into the freshly appended region. No per-record
            // heap allocation once the arena has warmed to steady-state size.
            try self.batch_arena.resize(self.allocator, off + needed);
            const n = try record.serializeInto(self.batch_arena.items[off..][0..needed]);
            try self.batch_spans.append(self.allocator, .{ .off = off, .len = n });
            return self.current_lsn;
        }

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

    /// GAP-0900: open a WAL record batch scoped to `txn_id`. While open,
    /// `appendRecord` calls for `txn_id` collect serialized records instead
    /// of writing each one; `flushBatch` writes them all in one syscall.
    ///
    /// Callers MUST pair this with exactly one `flushBatch` (success path)
    /// or `abortBatch` (rollback) before the transaction is acknowledged —
    /// records buffered here are NOT durable until flushed. Returns
    /// `error.BatchAlreadyOpen` if a batch is already active (no nesting).
    pub fn beginBatch(self: *WalManager, txn_id: u64) !void {
        if (self.batch_active) return error.BatchAlreadyOpen;
        std.debug.assert(self.batch_spans.items.len == 0);
        self.batch_active = true;
        self.batch_txn_id = txn_id;
    }

    /// GAP-0900: write all records collected since `beginBatch` with a
    /// single `inner.appendBatch`, then close the batch. The on-disk bytes
    /// and the inner log's LSN advancement are identical to having issued
    /// one `inner.append` per record. Idempotent for an empty batch (just
    /// closes it). After this returns every record has reached the OS page
    /// cache. The records keep the LSNs assigned when they were collected, so
    /// they can follow records with higher LSNs in the log (see the GAP-0900
    /// note on the struct, SONNY-6473).
    ///
    /// On a write error the records are dropped and the batch is closed
    /// (the inner log already truncated any partial write, SEC-0030); the
    /// error propagates so the caller aborts the transaction.
    pub fn flushBatch(self: *WalManager) !void {
        if (!self.batch_active) return;
        defer self.closeBatch();
        const n_records = self.batch_spans.items.len;
        if (n_records == 0) return;

        const base = self.batch_arena.items;

        // Single-record batch: a one-element appendBatch buys nothing (no
        // syscall amortisation) and is heavier than a plain append (the
        // batch path allocates an LSN array + a coalescing buffer). Route it
        // through the per-record append so the common single-page auto-commit
        // txn keeps its lean allocation profile (PERF-0055). On-disk output
        // is identical either way.
        if (n_records == 1) {
            const s = self.batch_spans.items[0];
            _ = try self.inner.append(base[s.off..][0..s.len]);
            return;
        }

        // Multi-record batch: materialize the slice array now that the arena
        // has stopped growing (its base pointer is stable) and write all
        // records in one syscall. appendBatch produces byte-identical on-disk
        // records, in span order, to N sequential appends.
        self.batch_ptrs.clearRetainingCapacity();
        try self.batch_ptrs.ensureTotalCapacity(self.allocator, n_records);
        for (self.batch_spans.items) |s| {
            self.batch_ptrs.appendAssumeCapacity(base[s.off..][0..s.len]);
        }
        _ = try self.inner.appendBatch(self.batch_ptrs.items);
    }

    /// GAP-0900: flush the batch only if it is owned by `txn_id`. A no-op
    /// when no batch is open or the open batch belongs to a different txn
    /// (that txn used the per-record path). Lets callers commit a txn
    /// without disturbing an unrelated concurrent batch.
    pub fn flushBatchFor(self: *WalManager, txn_id: u64) !void {
        if (!self.batch_active or self.batch_txn_id != txn_id) return;
        try self.flushBatch();
    }

    /// GAP-0900: discard all records collected since `beginBatch` WITHOUT
    /// writing them, then close the batch. Used on transaction abort so a
    /// rolled-back txn leaves no page-update records in the log.
    pub fn abortBatch(self: *WalManager) void {
        if (!self.batch_active) return;
        self.closeBatch();
    }

    /// GAP-0900: abort the batch only if it is owned by `txn_id`. A no-op
    /// otherwise (see `flushBatchFor`).
    pub fn abortBatchFor(self: *WalManager, txn_id: u64) void {
        if (!self.batch_active or self.batch_txn_id != txn_id) return;
        self.closeBatch();
    }

    /// Reset batch state, retaining arena/span/ptr capacity for reuse. Internal.
    fn closeBatch(self: *WalManager) void {
        self.batch_arena.clearRetainingCapacity();
        self.batch_spans.clearRetainingCapacity();
        self.batch_ptrs.clearRetainingCapacity();
        self.batch_active = false;
        self.batch_txn_id = 0;
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

        // Scan the whole inner log: whether a record is at or after start_lsn
        // depends on both numberings (see isAtOrAfter, SONNY-6424).
        var iter = try self.inner.iterator(0);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch continue;

            if (isAtOrAfter(entry.lsn, result.record.lsn, start_lsn)) {
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
        var iter = try self.inner.iterator(0); // see isAtOrAfter (SONNY-6424)
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch continue;
            defer result.record.deinit(allocator);

            if (isAtOrAfter(entry.lsn, result.record.lsn, start_lsn)) {
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

        // Scan the whole inner log; see isAtOrAfter (SONNY-6424). Records
        // before start_lsn are only validated as far as needed to place them.
        var iter = try self.inner.iterator(0);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch {
                // An undecodable record whose inner LSN is before the
                // frontier was never visited before this scan started at 0.
                if (entry.lsn < start_lsn) continue;
                failure.* = .{
                    .lsn = entry.lsn,
                    .kind = .deserialize_failed,
                };
                return error.InvalidFormat;
            };
            defer result.record.deinit(allocator);

            if (!isAtOrAfter(entry.lsn, result.record.lsn, start_lsn)) continue;

            if (result.record.checksum != result.record.computeChecksum()) {
                failure.* = .{
                    .lsn = result.record.lsn,
                    .kind = .checksum_mismatch,
                };
                return error.ChecksumMismatch;
            }

            try callback(ctx, &result.record);
        }
    }

    /// What the whole log holds, for recovery's truncation decision
    /// (SONNY-6599).
    pub const Contents = struct {
        /// Records in the inner log, at any LSN.
        records: u64 = 0,
        /// A record that does not decode as a graph-storage record.
        undecodable: bool = false,
        /// A cross-shard 2PC record. `sharded_recovery` reads these from LSN 0
        /// AFTER every shard has recovered, so they must outlive recovery.
        cross_shard: bool = false,
    };

    /// Scan the whole inner log once (every LSN) and summarise it.
    pub fn contents(self: *WalManager, allocator: Allocator) !Contents {
        var out = Contents{};
        var iter = try self.inner.iterator(0);
        defer iter.deinit();
        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();
            out.records += 1;
            const result = WalRecord.deserialize(allocator, entry.payload) catch {
                out.undecodable = true;
                continue;
            };
            defer result.record.deinit(allocator);
            switch (result.record.record_type) {
                .cross_shard_prepare, .cross_shard_commit, .cross_shard_abort => out.cross_shard = true,
                else => {},
            }
        }
        return out;
    }

    /// Truncate WAL: compact entries up to the given LSN.
    ///
    /// SONNY-6622: wal 0.1.24 validates the whole log before it compacts and
    /// refuses (file untouched, handle reopened) when a record no longer
    /// validates. That is not fatal to the checkpoint that asked: every
    /// record up to `up_to_lsn` is already in the pages and the manifest,
    /// the log keeps them (recovery skips them), and later appends work. The
    /// refusal is counted (`compactions_refused`) and logged; the next open
    /// reports the damage. Any other error is returned.
    pub fn truncate(self: *WalManager, up_to_lsn: u64) !void {
        self.inner.compact(up_to_lsn) catch |err| switch (err) {
            error.WalCorrupted, error.WalAuthFailed, error.WalEncryptionMismatch => {
                self.compactions_refused += 1;
                std.log.warn("graph-storage: WAL compaction up to LSN {d} refused ({s}); the WAL keeps its records and stays usable, the next open reports the damage (SONNY-6622)", .{ up_to_lsn, @errorName(err) });
            },
            else => return err,
        };
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

test "SONNY-6424: init re-anchors an emptied log whose sidecar was lost" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const uuid = [_]u8{0xDE} ** 16;

    // Fill, then compact everything away: the log is empty at LSN 10.
    {
        var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
        defer mgr.deinit();
        for (0..10) |_| {
            var rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = 0, .page_id = 0, .payload = "data", .checksum = 0 };
            _ = try mgr.appendRecord(&rec);
        }
        try mgr.sync();
        try mgr.truncate(10);
    }
    // A process that died instead of closing left no sidecar.
    tmp_dir.dir.deleteFile(io, "graph.wal.ckpt") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 10, .{});
        defer mgr.deinit();
        try std.testing.expectEqual(@as(u64, 10), mgr.currentLsn());
        var rec = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .page_update, .file_id = 0, .page_id = 0, .payload = "after", .checksum = 0 };
        try std.testing.expectEqual(@as(u64, 11), try mgr.appendRecord(&rec));
        try mgr.sync();
    }
    // Die again: the anchor record keeps the numbering without the sidecar.
    try tmp_dir.dir.deleteFile(io, "graph.wal.ckpt");

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 10, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u64, 11), mgr.currentLsn());
    const records = try mgr.readFrom(11, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(@as(u64, 11), records[0].lsn);
    try std.testing.expectEqualStrings("after", records[0].payload);
}

test "SONNY-6424: records renumbered below the frontier are still read when their own LSN is after it" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const uuid = [_]u8{0xDF} ** 16;

    // What a binary without the anchor wrote after reopening an emptied log
    // at frontier 50: inner LSNs 1..3, graph-storage LSNs 51..53.
    {
        var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
        defer mgr.deinit();
        mgr.current_lsn = 50;
        for (0..3) |_| {
            var rec = WalRecord{ .lsn = 0, .txn_id = 7, .record_type = .page_update, .file_id = 0, .page_id = 0, .payload = "tail", .checksum = 0 };
            _ = try mgr.appendRecord(&rec);
        }
        try mgr.sync();
        try std.testing.expectEqual(@as(u64, 3), mgr.currentLsn());
    }

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 50, .{});
    defer mgr.deinit();
    var failure: ?ReplayFailure = null;
    const Ctx = struct {
        lsns: [8]u64 = undefined,
        n: usize = 0,
        fn visit(ctx: *@This(), rec: *const WalRecord) !void {
            ctx.lsns[ctx.n] = rec.lsn;
            ctx.n += 1;
        }
    };
    var ctx = Ctx{};
    try mgr.forEachFromStrict(51, allocator, &failure, &ctx, Ctx.visit);
    // The three tail records; the anchor written at 50 is not after the frontier.
    try std.testing.expectEqual(@as(usize, 3), ctx.n);
    try std.testing.expectEqualSlices(u64, &.{ 51, 52, 53 }, ctx.lsns[0..3]);
    try std.testing.expectEqual(@as(u64, 50), mgr.currentLsn());
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

test "GAP-0900: batched records recover identically and in order after reopen" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0x91} ** 16;

    // --- Write phase: one begin, a multi-record batch, one commit ---
    {
        var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
        defer mgr.deinit();

        var begin = WalRecord{
            .lsn = 0,
            .txn_id = 7,
            .record_type = .begin_txn,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        _ = try mgr.appendRecord(&begin);

        // Open the batch for txn 7 and append several page updates. They are
        // buffered (not yet on disk) until flushBatch.
        try mgr.beginBatch(7);
        const payloads = [_][]const u8{
            "page-update-A",
            "page-update-B-longer-content",
            "C",
            "page-update-D",
        };
        for (payloads, 0..) |p, i| {
            var rec = WalRecord{
                .lsn = 0,
                .txn_id = 7,
                .record_type = .page_update,
                .file_id = 2,
                .page_id = 100 + i,
                .payload = p,
                .checksum = 0,
            };
            _ = try mgr.appendRecord(&rec);
        }

        // Records must NOT be visible before flush (buffered in memory only).
        const pre = try mgr.readFrom(1, allocator);
        defer {
            for (pre) |*r| r.deinit(allocator);
            allocator.free(pre);
        }
        try std.testing.expectEqual(@as(usize, 1), pre.len); // only begin_txn

        // Flush the batch (single appendBatch), then commit.
        try mgr.flushBatch();
        var commit = WalRecord{
            .lsn = 0,
            .txn_id = 7,
            .record_type = .commit_txn,
            .file_id = 0,
            .page_id = 0,
            .payload = &[_]u8{},
            .checksum = 0,
        };
        _ = try mgr.appendRecord(&commit);
        try mgr.sync();
    }

    // --- Recovery phase: reopen and verify every record survives intact ---
    {
        var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
        defer mgr.deinit();

        var failure: ?ReplayFailure = null;
        const Ctx = struct {
            recs: std.ArrayList(WalRecord) = .empty,
            alloc: Allocator,
            fn visit(self: *@This(), rec: *const WalRecord) !void {
                // Validate checksum integrity of every recovered record.
                try std.testing.expectEqual(rec.checksum, rec.computeChecksum());
                try self.recs.append(self.alloc, .{
                    .lsn = rec.lsn,
                    .txn_id = rec.txn_id,
                    .record_type = rec.record_type,
                    .file_id = rec.file_id,
                    .page_id = rec.page_id,
                    .payload = try self.alloc.dupe(u8, rec.payload),
                    .checksum = rec.checksum,
                });
            }
        };
        var ctx = Ctx{ .alloc = allocator };
        defer {
            for (ctx.recs.items) |*r| allocator.free(@constCast(r.payload));
            ctx.recs.deinit(allocator);
        }

        try mgr.forEachFromStrict(0, allocator, &failure, &ctx, Ctx.visit);
        try std.testing.expect(failure == null);

        // begin + 4 page_update + commit = 6 records, contiguous LSN 1..6.
        try std.testing.expectEqual(@as(usize, 6), ctx.recs.items.len);
        try std.testing.expectEqual(wal_record.WalRecordType.begin_txn, ctx.recs.items[0].record_type);
        try std.testing.expectEqual(wal_record.WalRecordType.commit_txn, ctx.recs.items[5].record_type);
        for (ctx.recs.items, 0..) |r, i| {
            try std.testing.expectEqual(@as(u64, i + 1), r.lsn);
        }
        const expect = [_][]const u8{
            "page-update-A",
            "page-update-B-longer-content",
            "C",
            "page-update-D",
        };
        for (expect, 0..) |p, i| {
            const r = ctx.recs.items[i + 1];
            try std.testing.expectEqual(wal_record.WalRecordType.page_update, r.record_type);
            try std.testing.expectEqual(@as(u64, 100 + i), r.page_id);
            try std.testing.expectEqualStrings(p, r.payload);
        }
    }
}

test "GAP-0900: batched flush is byte-identical to per-record append" {
    const allocator = std.testing.allocator;

    // Path A: per-record appends.
    var dir_a = std.testing.tmpDir(.{});
    defer dir_a.cleanup();
    // Path B: batched flush.
    var dir_b = std.testing.tmpDir(.{});
    defer dir_b.cleanup();

    const uuid = [_]u8{0x92} ** 16;
    const payloads = [_][]const u8{ "alpha", "bravo-payload", "c", "delta-delta-delta", "echo" };

    {
        var a = try WalManager.init(allocator, dir_a.dir, uuid, 0, .{});
        defer a.deinit();
        for (payloads, 0..) |p, i| {
            var rec = WalRecord{
                .lsn = 0,
                .txn_id = 3,
                .record_type = .page_update,
                .file_id = 1,
                .page_id = i,
                .payload = p,
                .checksum = 0,
            };
            _ = try a.appendRecord(&rec);
        }
        try a.sync();
    }
    {
        var b = try WalManager.init(allocator, dir_b.dir, uuid, 0, .{});
        defer b.deinit();
        try b.beginBatch(3);
        for (payloads, 0..) |p, i| {
            var rec = WalRecord{
                .lsn = 0,
                .txn_id = 3,
                .record_type = .page_update,
                .file_id = 1,
                .page_id = i,
                .payload = p,
                .checksum = 0,
            };
            _ = try b.appendRecord(&rec);
        }
        try b.flushBatch();
        try b.sync();
    }

    // The raw on-disk WAL files must be byte-for-byte identical.
    const bytes_a = try readWholeFile(allocator, dir_a.dir, "graph.wal");
    defer allocator.free(bytes_a);
    const bytes_b = try readWholeFile(allocator, dir_b.dir, "graph.wal");
    defer allocator.free(bytes_b);
    try std.testing.expectEqualSlices(u8, bytes_a, bytes_b);
}

/// TEST-ONLY: read an entire file from `dir` into a freshly allocated buffer.
fn readWholeFile(allocator: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

test "GAP-0900: aborted batch leaves no page-update records in the log" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0x93} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
    defer mgr.deinit();

    var begin = WalRecord{
        .lsn = 0,
        .txn_id = 9,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try mgr.appendRecord(&begin);

    try mgr.beginBatch(9);
    for (0..3) |i| {
        var rec = WalRecord{
            .lsn = 0,
            .txn_id = 9,
            .record_type = .page_update,
            .file_id = 1,
            .page_id = i,
            .payload = "discarded",
            .checksum = 0,
        };
        _ = try mgr.appendRecord(&rec);
    }
    // Abort: buffered records must be dropped, never written.
    mgr.abortBatch();
    try mgr.sync();

    const records = try mgr.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }
    // Only the begin_txn record was actually written.
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(wal_record.WalRecordType.begin_txn, records[0].record_type);
}

test "GAP-0900: records for a non-batched txn fall through to immediate write" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0x94} ** 16;
    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
    defer mgr.deinit();

    // Open a batch for txn 1, but append a record for txn 2 — it must NOT be
    // buffered (different txn) and must be immediately visible.
    try mgr.beginBatch(1);
    var other = WalRecord{
        .lsn = 0,
        .txn_id = 2,
        .record_type = .page_update,
        .file_id = 1,
        .page_id = 5,
        .payload = "other-txn",
        .checksum = 0,
    };
    _ = try mgr.appendRecord(&other);

    const seen = try mgr.readFrom(1, allocator);
    defer {
        for (seen) |*r| r.deinit(allocator);
        allocator.free(seen);
    }
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqual(@as(u64, 2), seen[0].txn_id);

    mgr.abortBatch();
}

test {
    std.testing.refAllDecls(@This());
}
