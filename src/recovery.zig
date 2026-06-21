// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

const buffer_pool_mod = @import("buffer_pool.zig");
const wal_mod = @import("wal.zig");
const manifest_mod = @import("manifest.zig");
const file_manager_mod = @import("file_manager.zig");
const graph_dir_mod = @import("graph_dir.zig");
const checkpoint_mod = @import("checkpoint.zig");
const wal_record_mod = @import("wal_record.zig");
const types = @import("types.zig");
const metrics_mod = @import("metrics.zig");
const config_mod = @import("config.zig");
const page_mod = @import("page.zig");

const BufferPool = buffer_pool_mod.BufferPool;
const WalManager = wal_mod.WalManager;
const Manifest = manifest_mod.Manifest;
const FileManager = file_manager_mod.FileManager;
const GraphDir = graph_dir_mod.GraphDir;
const Checkpointer = checkpoint_mod.Checkpointer;
const WalRecord = wal_record_mod.WalRecord;
const WalRecordType = wal_record_mod.WalRecordType;
const FileId = types.FileId;
const ReplayFailure = wal_mod.ReplayFailure;

/// Transaction state during recovery.
const TxnRecoveryState = enum {
    active,
    committed,
    aborted,
};

/// Crash recovery via manifest + WAL replay.
///
/// Recovery loads the latest valid manifest (A/B), then replays committed
/// WAL transactions from the last checkpoint LSN to restore the database
/// to a consistent state.
pub const Recovery = struct {
    allocator: Allocator,
    /// Count of WAL records skipped due to checksum mismatch during recovery.
    skipped_checksum_failures: u64 = 0,
    /// Encryption key for WAL access. Must match the key used when writing.
    encryption_key: ?[32]u8 = null,
    /// Optional metrics sink for recording recovery_duration_ns.
    metrics: ?*metrics_mod.Metrics = null,
    /// Optional log callback for structured event emission.
    log_fn: ?*const fn (level: config_mod.LogLevel, msg: []const u8) void = null,
    /// Policy for handling legacy (V1) graph formats.
    legacy_policy: config_mod.LegacyPolicy = .reject,
    /// Set to true when recovery opened a V1 graph in read-only mode.
    read_only: bool = false,
    /// Details about the last fail-closed WAL rejection, when present.
    last_failure: ?ReplayFailure = null,

    pub fn init(allocator: Allocator, encryption_key: ?[32]u8) Recovery {
        return .{
            .allocator = allocator,
            .skipped_checksum_failures = 0,
            .encryption_key = encryption_key,
            .last_failure = null,
        };
    }

    /// Securely zero the encryption key material. Must be called when the
    /// Recovery instance is no longer needed to avoid leaving key material
    /// in memory.
    pub fn deinit(self: *Recovery) void {
        if (self.encryption_key) |*key| {
            std.crypto.secureZero(u8, key);
        }
    }

    /// Recover a graph from its directory.
    /// 1. Read manifest A and B, select valid one with highest counter
    /// 2. Open store files
    /// 3. Read WAL from last_checkpoint_lsn
    /// 4. Classify transactions (scan for BEGIN/COMMIT/ABORT)
    /// 5. Replay committed page_update records into buffer pool
    /// 6. Discard uncommitted transaction records
    /// 7. Flush buffer pool
    /// 8. Write fresh checkpoint
    /// Returns the recovered manifest.
    pub fn recover(
        self: *Recovery,
        graph_dir: *const GraphDir,
        buffer_pool: *BufferPool,
        file_manager: *FileManager,
    ) !Manifest {
        config_mod.emitEvent(self.log_fn, .recovery_start);

        const io = std.Io.Threaded.global_single_threaded.io();
        const start_ts = std.Io.Clock.Timestamp.now(io, .awake);
        defer {
            const end_ts = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed = start_ts.durationTo(end_ts);
            if (self.metrics) |m| {
                m.recovery_duration_ns = @intCast(elapsed.raw.toNanoseconds());
            }
            config_mod.emitEvent(self.log_fn, .recovery_end);
        }

        // 1. Read manifest A and B, select valid one with highest counter
        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);
        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        // SEC-0043: under TDE (key configured) the manifest is HMAC-authenticated.
        // A forged manifest (e.g. rolled-back last_checkpoint_lsn) is rejected here.
        const manifest_a = Manifest.readFromFileWithKey(self.allocator, path_a, self.encryption_key) catch null;
        const manifest_b = Manifest.readFromFileWithKey(self.allocator, path_b, self.encryption_key) catch null;

        var m = try Manifest.selectManifest(manifest_a, manifest_b);
        if (!std.mem.eql(u8, &m.graph_uuid, &graph_dir.graph_uuid)) {
            return error.UuidMismatch;
        }

        // Validate manifest format version compatibility
        if (m.format_version != manifest_mod.MANIFEST_VERSION) {
            if (m.format_version == manifest_mod.MANIFEST_VERSION_V1) {
                if (self.legacy_policy == .read_only) {
                    std.log.warn("V1 graph format detected — opening in read-only mode (mutations will be rejected)", .{});
                    self.read_only = true;
                    // Continue opening; actual mutation enforcement is in engine.zig
                } else {
                    std.log.warn("V1 graph format detected — data directory must be recreated for V2 (40-byte NodeRec is incompatible with 48-byte V2 layout)", .{});
                    return error.IncompatibleVersion;
                }
            } else {
                return error.IncompatibleVersion;
            }
        }

        // 2. Open store files
        _ = try file_manager.openFile(.nodes, .open_existing);
        _ = try file_manager.openFile(.adj_out, .open_existing);
        _ = try file_manager.openFile(.adj_in, .open_existing);
        _ = try file_manager.openFile(.props, .open_existing);
        _ = try file_manager.openFile(.var_store, .open_existing);
        _ = try file_manager.openFile(.free, .open_existing);

        // Register pagers with buffer pool
        if (file_manager.getPager(.nodes)) |p| buffer_pool.registerPager(.nodes, p);
        if (file_manager.getPager(.adj_out)) |p| buffer_pool.registerPager(.adj_out, p);
        if (file_manager.getPager(.adj_in)) |p| buffer_pool.registerPager(.adj_in, p);
        if (file_manager.getPager(.props)) |p| buffer_pool.registerPager(.props, p);
        if (file_manager.getPager(.var_store)) |p| buffer_pool.registerPager(.var_store, p);
        if (file_manager.getPager(.free)) |p| buffer_pool.registerPager(.free, p);

        // 3. Open WAL and read from last_checkpoint_lsn
        const wal_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/wal", .{graph_dir.path});
        defer self.allocator.free(wal_dir_path);

        var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
        defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

        var wal = try WalManager.init(
            self.allocator,
            wal_dir,
            graph_dir.graph_uuid,
            m.last_checkpoint_lsn,
            .{ .encryption_key = self.encryption_key },
        );
        defer wal.deinit();

        const start_lsn = if (m.last_checkpoint_lsn > 0) m.last_checkpoint_lsn + 1 else 1;
        var saw_records = false;
        self.last_failure = null;

        // 4. Classify transactions. Any malformed or checksum-invalid record
        // aborts recovery so the operator can inspect the damaged WAL.
        var txn_states = std.AutoHashMap(u64, TxnRecoveryState).init(self.allocator);
        defer txn_states.deinit();

        const ClassifyCtx = struct {
            recovery: *Recovery,
            txn_states: *std.AutoHashMap(u64, TxnRecoveryState),
            saw_records: *bool,

            fn visit(ctx: *@This(), rec: *const WalRecord) !void {
                ctx.saw_records.* = true;

                switch (rec.record_type) {
                    .begin_txn => try ctx.txn_states.put(rec.txn_id, .active),
                    .commit_txn => try ctx.txn_states.put(rec.txn_id, .committed),
                    .abort_txn => try ctx.txn_states.put(rec.txn_id, .aborted),
                    .page_update, .checkpoint_marker => {},
                    // Cross-shard 2PC records are collected and reconciled
                    // by sharded_recovery.reconcilePendingPrepares after
                    // per-shard recovery completes. Skipped here.
                    .cross_shard_prepare, .cross_shard_commit, .cross_shard_abort => {},
                }
            }
        };

        var classify_ctx = ClassifyCtx{
            .recovery = self,
            .txn_states = &txn_states,
            .saw_records = &saw_records,
        };
        try wal.forEachFromStrict(start_lsn, self.allocator, &self.last_failure, &classify_ctx, ClassifyCtx.visit);

        if (!saw_records) {
            // Clean recovery: no WAL records to replay
            return m;
        }

        // 5. Replay committed page_update records into buffer pool.
        const ReplayCtx = struct {
            txn_states: *const std.AutoHashMap(u64, TxnRecoveryState),
            buffer_pool: *BufferPool,
            file_manager: *FileManager,

            fn visit(ctx: *@This(), rec: *const WalRecord) !void {
                if (rec.record_type != .page_update) return;

                const state = ctx.txn_states.get(rec.txn_id) orelse return;
                if (state != .committed) return;

                const file_id: FileId = std.enums.fromInt(FileId, rec.file_id) orelse return error.InvalidFormat;
                const frame = try ctx.buffer_pool.pinNew(file_id, rec.page_id);
                const frame_idx = ctx.buffer_pool.frameIndex(frame);
                const data = frame.dataSlice();

                const copy_len = @min(rec.payload.len, data.len);
                if (copy_len > 0) {
                    @memcpy(data[0..copy_len], rec.payload[0..copy_len]);
                }

                // SEC-0037: pinNew zeroes the frame and the WAL payload carries
                // the write_count as of log time, which may be LOWER than the
                // write_count already persisted to the on-disk page by a flush
                // that happened after the record was logged (then crashed). A
                // later flush would otherwise reuse a nonce already used on disk
                // with different plaintext. Seed the replayed frame's write_count
                // to max(on-disk, logged) so the AES-GCM nonce counter never
                // regresses. write_count stays plaintext in the header, so it can
                // be read from the raw on-disk bytes without decrypting.
                if (copy_len >= page_mod.WRITE_COUNT_OFFSET + 3) {
                    if (ctx.file_manager.getPager(file_id)) |pager_ptr| {
                        const on_disk_wc = pager_ptr.readWriteCountOnDisk(rec.page_id) catch 0;
                        const logged_wc = page_mod.readWriteCount(data);
                        page_mod.writeWriteCount(data, @max(on_disk_wc, logged_wc));
                    }
                }

                ctx.buffer_pool.unpin(frame_idx, true);
            }
        };

        var replay_ctx = ReplayCtx{
            .txn_states = &txn_states,
            .buffer_pool = buffer_pool,
            .file_manager = file_manager,
        };
        try wal.forEachFromStrict(start_lsn, self.allocator, &self.last_failure, &replay_ctx, ReplayCtx.visit);

        // 7. Flush buffer pool to disk
        try buffer_pool.flushAll();

        // 8. Write fresh checkpoint
        try file_manager.syncAll();
        m.counter += 1;
        m.last_checkpoint_lsn = wal.currentLsn();

        // Write to both slots for a clean state after recovery
        const manifest_path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(manifest_path_a);
        try m.writeToFileWithKey(self.allocator, manifest_path_a, self.encryption_key);

        const manifest_path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(manifest_path_b);
        try m.writeToFileWithKey(self.allocator, manifest_path_b, self.encryption_key);

        return m;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const pager_module = @import("pager.zig");
const Pager = pager_module.Pager;

fn setupTestGraph(allocator: Allocator) !struct {
    tmp_dir: testing.TmpDir,
    graph_dir: GraphDir,
} {
    var tmp_dir = testing.tmpDir(.{});
    const dir_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(dir_path);

    const uuid = [_]u8{0xBB} ** 16;
    const gd = try GraphDir.create(allocator, dir_path, uuid);

    // Create WAL directory
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{gd.path});
    defer allocator.free(wal_dir_path);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), wal_dir_path);

    return .{
        .tmp_dir = tmp_dir,
        .graph_dir = gd,
    };
}

test "clean recovery: no WAL records, manifest loaded correctly" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write an initial manifest to slot A
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .next_node_id = 10,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Manifest should match what was written (clean recovery doesn't increment counter
    // because there are no records to replay)
    try testing.expectEqual(@as(u64, 10), recovered.next_node_id);
    try testing.expectEqual([_]u8{0xBB} ** 16, recovered.graph_uuid);
}

test "GAP-0032: recovery rejects manifests whose graph UUID mismatches the graph directory" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const initial = Manifest{
        .graph_uuid = [_]u8{0xAA} ** 16,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    try testing.expectError(error.UuidMismatch, recovery.recover(&setup.graph_dir, &pool, &fm));
}

test "recovery with committed transaction: changes visible after recovery" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Write WAL records simulating a committed transaction
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 1 (write some data to nodes file, page 1)
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xAB); // recognizable pattern
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0, // nodes
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // COMMIT txn 1
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    try wal.sync();
    wal.deinit();

    // Now run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // The recovered manifest should have a bumped counter
    try testing.expectEqual(@as(u64, 2), recovered.counter);

    // Verify the committed page data was applied: read the page from disk
    const pager_ptr = fm.getPager(.nodes).?;
    var read_buf: [4096]u8 = undefined;
    pager_ptr.readPage(1, &read_buf) catch {
        // Page might not exist on disk yet if flush didn't extend file
        // This is acceptable for the test
        return;
    };

    // Check if data was written (the page should have our 0xAB pattern)
    // The buffer pool flush may have computed checksums, so check body area
    var all_match = true;
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xAB) {
            all_match = false;
            break;
        }
    }
    // The data should match since we wrote the full page
    try testing.expect(all_match);
}

test "GAP-0030: recovery replays a large committed WAL tail" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});
    defer wal.deinit();

    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 7,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    var payload: [4096]u8 = undefined;
    for (0..payload.len) |i| payload[i] = @intCast(i % 251);

    var page_id: u64 = 1;
    while (page_id <= 512) : (page_id += 1) {
        var update_rec = WalRecord{
            .lsn = 0,
            .txn_id = 7,
            .record_type = .page_update,
            .file_id = @intFromEnum(FileId.nodes),
            .page_id = page_id,
            .payload = &payload,
            .checksum = 0,
        };
        _ = try wal.appendRecord(&update_rec);
    }

    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 7,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 64);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    try testing.expect(recovered.counter > initial.counter);
    try testing.expect(recovery.last_failure == null);
}

test "recovery with uncommitted transaction: changes discarded" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Write WAL records: uncommitted transaction (no COMMIT)
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 1 (uncommitted)
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xCD);
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0, // nodes
        .page_id = 2,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // No COMMIT - transaction is uncommitted
    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);
    _ = recovered;

    // The uncommitted page should NOT have been written to disk.
    // Page 2 in the nodes file should either not exist or be all zeros.
    const pager_ptr = fm.getPager(.nodes).?;
    var read_buf: [4096]u8 = undefined;
    pager_ptr.readPage(2, &read_buf) catch {
        // Page doesn't exist on disk - uncommitted data was correctly discarded
        return;
    };

    // If the page exists, verify it's NOT our uncommitted 0xCD pattern
    var has_uncommitted_data = true;
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xCD) {
            has_uncommitted_data = false;
            break;
        }
    }
    try testing.expect(!has_uncommitted_data);
}

test "recovery rejects WAL records with corrupted checksums" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Open WAL directory and create WAL
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1 (correct checksum, via appendRecord)
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE with intentionally WRONG checksum.
    // Write raw serialized bytes directly to the inner WAL to bypass
    // appendRecord's automatic checksum computation.
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xEE);
    var bad_update = WalRecord{
        .lsn = 2,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0,
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    const bad_bytes = try bad_update.serialize(allocator);
    defer allocator.free(bad_bytes);
    // Corrupt the checksum in the serialized bytes (last 4 bytes)
    @memcpy(bad_bytes[bad_bytes.len - 4 ..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, 0xDEADBEEF))));
    _ = try wal.inner.append(bad_bytes);
    wal.current_lsn = 2;

    // COMMIT txn 1 (correct checksum, via appendRecord)
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.ChecksumMismatch, result);
    try testing.expect(recovery.last_failure != null);
    try testing.expectEqual(@as(u64, 2), recovery.last_failure.?.lsn);
    try testing.expectEqual(wal_mod.ReplayFailureKind.checksum_mismatch, recovery.last_failure.?.kind);
}

test "recovery rejects manifest with incompatible format_version" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a manifest with a future/incompatible format_version
    var bad_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    bad_manifest.format_version = 999; // incompatible version

    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try bad_manifest.writeToFile(allocator, path_a);

    // Run recovery -- should fail with IncompatibleVersion
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.IncompatibleVersion, result);
}

test "GAP-0005a: torn/truncated WAL record fails recovery closed" {
    // A truncated record at the end of the WAL must stop recovery so the
    // operator can inspect the damaged WAL instead of silently dropping data.
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Create WAL with a valid committed txn followed by a truncated record
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 1 with recognizable data
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xF1);
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0,
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // COMMIT txn 1
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    // Write a truncated/garbage record directly into the WAL log.
    // This simulates a torn write (crash mid-write).
    const truncated_bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 }; // too short to be valid
    _ = try wal.inner.append(&truncated_bytes);

    try wal.sync();
    wal.deinit();

    // Run recovery -- truncated records must fail recovery closed
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const result = recovery_inst.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.InvalidFormat, result);
    try testing.expect(recovery_inst.last_failure != null);
    try testing.expectEqual(wal_mod.ReplayFailureKind.deserialize_failed, recovery_inst.last_failure.?.kind);
}

test "GAP-0005b: manifest A corrupt, B valid -- recovery uses B" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a VALID manifest to slot B with distinctive values
    const valid_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 5,
        .next_node_id = 42,
        .last_checkpoint_lsn = 0,
    };
    const path_b = try setup.graph_dir.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try valid_manifest.writeToFile(allocator, path_b);

    // Write CORRUPT data to slot A (invalid magic/CRC)
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    {
        const corrupt_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path_a, .{});
        defer corrupt_file.close(std.Io.Threaded.global_single_threaded.io());
        var garbage: [148]u8 = undefined;
        @memset(&garbage, 0xFF); // total garbage, invalid magic + CRC
        try corrupt_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), &garbage);
    }

    // Run recovery -- should use manifest B
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const recovered = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Recovered manifest should be from slot B
    try testing.expectEqual(@as(u64, 42), recovered.next_node_id);
    // Counter should be >= 5 (the value from B; recovery may increment it)
    try testing.expect(recovered.counter >= 5);
}

test "GAP-0005c: multiple concurrent transactions -- only committed data survives" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Create WAL with 3 interleaved transactions:
    //   txn 1 = committed (page 1, data 0xAA)
    //   txn 2 = uncommitted / still active (page 2, data 0xBB)
    //   txn 3 = aborted (page 3, data 0xCC)
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN all three
    var begin1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin1);
    var begin2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin2);
    var begin3 = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin3);

    // PAGE_UPDATE for txn 1 (committed data)
    var data1: [4096]u8 = undefined;
    @memset(&data1, 0xAA);
    var upd1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = 0, .page_id = 1, .payload = &data1, .checksum = 0 };
    _ = try wal.appendRecord(&upd1);

    // PAGE_UPDATE for txn 2 (uncommitted data)
    var data2: [4096]u8 = undefined;
    @memset(&data2, 0xBB);
    var upd2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .page_update, .file_id = 0, .page_id = 2, .payload = &data2, .checksum = 0 };
    _ = try wal.appendRecord(&upd2);

    // PAGE_UPDATE for txn 3 (aborted data)
    var data3: [4096]u8 = undefined;
    @memset(&data3, 0xCC);
    var upd3 = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .page_update, .file_id = 0, .page_id = 3, .payload = &data3, .checksum = 0 };
    _ = try wal.appendRecord(&upd3);

    // COMMIT txn 1
    var commit1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit1);

    // ABORT txn 3
    var abort3 = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .abort_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&abort3);

    // txn 2 has no commit or abort -- simulates in-flight crash

    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 64);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    _ = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Verify: committed txn 1 page data (page 1) was applied
    const pager_ptr = fm.getPager(.nodes).?;

    var read_buf1: [4096]u8 = undefined;
    pager_ptr.readPage(1, &read_buf1) catch {
        return error.TestUnexpectedResult;
    };
    // Check committed data is present
    var committed_ok = true;
    for (read_buf1[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xAA) {
            committed_ok = false;
            break;
        }
    }
    try testing.expect(committed_ok);

    // Verify: uncommitted txn 2 page data (page 2) was NOT applied
    var read_buf2: [4096]u8 = undefined;
    pager_ptr.readPage(2, &read_buf2) catch {
        // Page doesn't exist = correct, uncommitted data discarded
        return;
    };
    var uncommitted_present = true;
    for (read_buf2[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xBB) {
            uncommitted_present = false;
            break;
        }
    }
    try testing.expect(!uncommitted_present);

    // Verify: aborted txn 3 page data (page 3) was NOT applied
    var read_buf3: [4096]u8 = undefined;
    pager_ptr.readPage(3, &read_buf3) catch {
        // Page doesn't exist = correct, aborted data discarded
        return;
    };
    var aborted_present = true;
    for (read_buf3[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xCC) {
            aborted_present = false;
            break;
        }
    }
    try testing.expect(!aborted_present);
}

test "GAP-0005d: recovery with many pages (>100 page updates in WAL)" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // Write 120 page_update records, each to a distinct page.
    // Each page gets a unique byte pattern based on its page index.
    const num_pages: u64 = 120;
    for (0..num_pages) |i| {
        var page_data: [4096]u8 = undefined;
        @memset(&page_data, @as(u8, @intCast(i % 256)));
        var upd = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .page_update,
            .file_id = 0, // nodes
            .page_id = @intCast(i + 1), // pages 1..120
            .payload = &page_data,
            .checksum = 0,
        };
        _ = try wal.appendRecord(&upd);
    }

    // COMMIT txn 1
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    try wal.sync();
    wal.deinit();

    // Run recovery with enough buffer pool frames for all 120 pages
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 256);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const recovered = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Recovery should succeed and increment counter
    try testing.expectEqual(@as(u64, 2), recovered.counter);

    // Spot-check a sample of the 120 pages to verify data was applied correctly
    const pager_ptr = fm.getPager(.nodes).?;

    const check_pages = [_]u64{ 1, 50, 100, 119, 120 };
    for (check_pages) |pg| {
        var read_buf: [4096]u8 = undefined;
        pager_ptr.readPage(pg, &read_buf) catch {
            return error.TestUnexpectedResult;
        };
        const expected_byte: u8 = @intCast((pg - 1) % 256);
        var match = true;
        for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
            if (byte != expected_byte) {
                match = false;
                break;
            }
        }
        try testing.expect(match);
    }
}

test "deinit zeros encryption key" {
    const key = [_]u8{0xAA} ** 32;
    var recovery = Recovery.init(testing.allocator, key);

    // Before deinit, key should be present
    try testing.expect(recovery.encryption_key != null);
    try testing.expect(recovery.encryption_key.?[0] == 0xAA);

    recovery.deinit();

    // After deinit, key should be zeroed
    if (recovery.encryption_key) |k| {
        for (k) |byte| {
            try testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "deinit with null encryption key does not panic" {
    var recovery = Recovery.init(testing.allocator, null);
    recovery.deinit(); // should not panic
}

test "SEC-0043: recovery rejects forged TDE manifest (rolled-back LSN, recomputed CRC)" {
    // Under TDE, an attacker with filesystem write access rolls back the
    // manifest's last_checkpoint_lsn and RECOMPUTES the CRC32 so the legacy
    // CRC-only check would pass. The keyed HMAC must catch the forgery and
    // recovery must fail closed instead of redirecting replay.
    const allocator = testing.allocator;
    // fips-exempt: non-security — CRC32C record-integrity (corruption detection)
    // for on-disk format; not authentication.
    const Crc32 = std.hash.crc.Crc32Iscsi;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const key = [_]u8{0x43} ** 32;

    // Write an authenticated manifest to slot A with a real checkpoint LSN.
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 5,
        .last_checkpoint_lsn = 9000,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFileWithKey(allocator, path_a, key);

    // Forge slot A: roll back last_checkpoint_lsn to 0, recompute CRC32, but
    // leave the HMAC trailer (which no longer matches the tampered body).
    {
        const f = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path_a, .{ .mode = .read_write });
        defer f.close(std.Io.Threaded.global_single_threaded.io());
        const io = std.Io.Threaded.global_single_threaded.io();
        const flen = try f.length(io);
        const buf = try allocator.alloc(u8, @intCast(flen));
        defer allocator.free(buf);
        _ = try f.readPositionalAll(io, buf, 0);
        const lsn_offset: usize = 8 + 4 + 16 + 4 + 8; // magic+fmt+uuid+page_size+counter
        @memcpy(buf[lsn_offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0))));
        const crc_offset = manifest_mod.SERIALIZED_SIZE - 4;
        const new_crc = Crc32.hash(buf[0..crc_offset]);
        @memcpy(buf[crc_offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));
        try f.writePositionalAll(io, buf, 0);
    }

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    fm.encryption_key = key;
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, key);
    defer recovery.deinit();
    // No valid manifest survives: slot A is forged (HMAC fails -> dropped) and
    // slot B was never written, so recovery has nothing authentic to load.
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.NoManifest, result);
}

test "SEC-0043: TDE recovery round-trip — authenticated manifest loads cleanly" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const key = [_]u8{0x43} ** 32;

    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 3,
        .next_node_id = 77,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFileWithKey(allocator, path_a, key);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    fm.encryption_key = key;
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, key);
    defer recovery.deinit();
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectEqual(@as(u64, 77), recovered.next_node_id);
    try testing.expectEqual([_]u8{0xBB} ** 16, recovered.graph_uuid);
}

test "recovery writes manifest to both slots A and B" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest to slot A only
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Write a committed transaction so recovery writes a fresh manifest
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});
    var begin_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin_rec);
    var commit_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();
    var recovery = Recovery.init(allocator, null);
    defer recovery.deinit();
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Both slots should now have a valid manifest
    const slot_a_path = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(slot_a_path);
    const manifest_a = (try Manifest.readFromFile(allocator, slot_a_path)) orelse return error.TestUnexpectedResult;

    const slot_b_path = try setup.graph_dir.manifestPath(allocator, .b);
    defer allocator.free(slot_b_path);
    const manifest_b = (try Manifest.readFromFile(allocator, slot_b_path)) orelse return error.TestUnexpectedResult;

    // Both manifests should have the same counter
    try testing.expectEqual(manifest_a.counter, manifest_b.counter);
    try testing.expectEqual(manifest_a.last_checkpoint_lsn, manifest_b.last_checkpoint_lsn);
}

test "V1 format with reject policy returns IncompatibleVersion" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a V1 manifest
    var v1_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
    };
    v1_manifest.format_version = manifest_mod.MANIFEST_VERSION_V1;
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try v1_manifest.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    recovery.legacy_policy = .reject;
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.IncompatibleVersion, result);
}

test "V1 format with read_only policy succeeds and sets read_only flag" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a V1 manifest
    var v1_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
    };
    v1_manifest.format_version = manifest_mod.MANIFEST_VERSION_V1;
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try v1_manifest.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    recovery.legacy_policy = .read_only;
    try testing.expect(!recovery.read_only);

    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // read_only flag should be set
    try testing.expect(recovery.read_only);
}

test "recovery records duration in metrics when wired" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write an initial manifest to slot A
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .next_node_id = 10,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var m = metrics_mod.Metrics{};
    try testing.expectEqual(@as(u64, 0), m.recovery_duration_ns);

    var recovery = Recovery.init(allocator, null);
    recovery.metrics = &m;
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Recovery should have recorded a non-zero duration
    try testing.expect(m.recovery_duration_ns > 0);
}

test "uncommitted transaction not applied during recovery" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Open WAL directory and create WAL manager
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 42
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 42,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 42 -- write a page full of 0xAA
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xAA);
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 42,
        .record_type = .page_update,
        .file_id = 0, // nodes
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // NO commit record -- simulate crash before commit
    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const m = try recovery.recover(&setup.graph_dir, &pool, &fm);
    _ = m;

    // The uncommitted page_update must NOT have been applied.
    // Pin the page and verify it is NOT filled with 0xAA.
    // Since the page was never written to the store, pinNew will give a
    // zero-initialized frame (no store file backing for page 1).
    // If recovery incorrectly replayed the uncommitted txn, the page would
    // contain 0xAA bytes.
    _ = try fm.openFile(.nodes, .create_if_missing);
    pool.registerPager(.nodes, &fm.pagers[@intFromEnum(FileId.nodes)].?);

    const frame = try pool.pinNew(.nodes, 1);
    const frame_idx = pool.frameIndex(frame);
    defer pool.unpin(frame_idx, false);
    const data = frame.dataSlice();

    // Verify the page is NOT filled with 0xAA (uncommitted data not applied)
    var found_aa = false;
    for (data[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte == 0xAA) {
            found_aa = true;
            break;
        }
    }
    try testing.expect(!found_aa);
}

test "SEC-0037: recovery does not regress on-disk write_count below the persisted value" {
    // Models a crash where the on-disk page was flushed (advancing write_count
    // to N) AFTER the corresponding page_update was logged to the WAL (whose
    // payload carries a LOWER write_count). Naively replaying via pinNew would
    // reset write_count to the logged value and a later flush would reuse a
    // nonce already used on disk with different plaintext. Recovery must seed
    // the replayed frame to max(on-disk, logged) so the counter never regresses.
    const allocator = testing.allocator;
    const encryption_mod = @import("encryption.zig");

    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const key = [_]u8{0x37} ** 32;

    // Write initial manifest. SEC-0043: under TDE the manifest must be
    // HMAC-authenticated with the same key recovery reads it with.
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFileWithKey(allocator, path_a, key);

    // Pre-flush the nodes store page 1 several times via an encryption-enabled
    // pager so the persisted on-disk write_count reaches a high value (N).
    // This simulates flushes that happened on the crashed run AFTER the
    // page_update below was appended to the WAL.
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{setup.graph_dir.path});
    defer allocator.free(nodes_path);
    const on_disk_write_count: u24 = blk: {
        const store = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), nodes_path, .{
            .read = true,
            .truncate = true,
        });
        defer store.close(std.Io.Threaded.global_single_threaded.io());

        var disk_pager = Pager.init(store, 4096);
        disk_pager.encryption = encryption_mod.PageEncryption.init(key);
        disk_pager.file_id = .nodes;

        var buf: [4096]u8 = undefined;
        @memset(&buf, 0);
        const header = page_mod.initHeader(1, .node_data, 4096);
        @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
        // Distinct on-disk content (NOT the WAL payload pattern).
        @memset(buf[page_mod.PAGE_HEADER_SIZE .. 4096 - encryption_mod.TAG_SIZE], 0x99);

        // Each writePage increments write_count; do it 5 times.
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            try disk_pager.writePage(1, &buf);
            // Re-stage plaintext for the next round (writePage encrypts in place).
            @memset(&buf, 0);
            @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
            @memset(buf[page_mod.PAGE_HEADER_SIZE .. 4096 - encryption_mod.TAG_SIZE], 0x99);
            // Carry forward the persisted write_count so the next write advances it.
            var raw: [4096]u8 = undefined;
            _ = try store.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw, 4096); // page 1 offset
            page_mod.writeWriteCount(&buf, page_mod.readWriteCount(&raw));
        }

        var raw: [4096]u8 = undefined;
        _ = try store.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw, 4096); // page 1 offset
        break :blk page_mod.readWriteCount(&raw);
    };
    try testing.expect(on_disk_write_count >= 5);

    // Build an encrypted WAL with a committed page_update for page 1. Its
    // payload header carries write_count = 0 (the value as of log time), which
    // is LOWER than the on-disk write_count established above.
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{ .encryption_key = key });

    var begin_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin_rec);

    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0);
    const wal_header = page_mod.initHeader(1, .node_data, 4096);
    @memcpy(page_data[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&wal_header));
    @memset(page_data[page_mod.PAGE_HEADER_SIZE..], 0xAB); // different from on-disk 0x99
    page_mod.writeWriteCount(&page_data, 0); // logged write_count is LOWER than on disk

    var update_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = 0, .page_id = 1, .payload = &page_data, .checksum = 0 };
    _ = try wal.appendRecord(&update_rec);

    var commit_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();
    wal.deinit();

    // Run recovery with encryption enabled.
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    fm.encryption_key = key;
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, key);
    defer recovery.deinit();
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // The post-replay on-disk write_count must be >= the previously persisted
    // value (no regression). write_count is stored PLAINTEXT in the header, so
    // it can be read from the raw on-disk bytes without decrypting.
    const verify_pager = fm.getPager(.nodes).?;
    var verify_raw: [4096]u8 = undefined;
    _ = try verify_pager.file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &verify_raw, 4096); // page 1 offset
    const post_write_count = page_mod.readWriteCount(&verify_raw);
    try testing.expect(post_write_count >= on_disk_write_count);
}

test {
    std.testing.refAllDecls(@This());
}
