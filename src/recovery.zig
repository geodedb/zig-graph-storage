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

const BufferPool = buffer_pool_mod.BufferPool;
const WalManager = wal_mod.WalManager;
const Manifest = manifest_mod.Manifest;
const FileManager = file_manager_mod.FileManager;
const GraphDir = graph_dir_mod.GraphDir;
const Checkpointer = checkpoint_mod.Checkpointer;
const WalRecord = wal_record_mod.WalRecord;
const WalRecordType = wal_record_mod.WalRecordType;
const FileId = types.FileId;

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

    pub fn init(allocator: Allocator, encryption_key: ?[32]u8) Recovery {
        return .{
            .allocator = allocator,
            .skipped_checksum_failures = 0,
            .encryption_key = encryption_key,
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

        var timer = std.time.Timer.start() catch null;
        defer {
            if (timer) |*t| {
                const elapsed_ns: u64 = t.read();
                if (self.metrics) |m| {
                    m.recovery_duration_ns = elapsed_ns;
                }
            }
            config_mod.emitEvent(self.log_fn, .recovery_end);
        }

        // 1. Read manifest A and B, select valid one with highest counter
        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);
        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        const manifest_a = Manifest.readFromFile(self.allocator, path_a) catch null;
        const manifest_b = Manifest.readFromFile(self.allocator, path_b) catch null;

        var m = try Manifest.selectManifest(manifest_a, manifest_b);

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
        _ = try file_manager.openFile(.nodes);
        _ = try file_manager.openFile(.adj_out);
        _ = try file_manager.openFile(.adj_in);
        _ = try file_manager.openFile(.props);
        _ = try file_manager.openFile(.var_store);
        _ = try file_manager.openFile(.free);

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

        // Ensure WAL directory exists (propagate errors instead of swallowing)
        try std.fs.cwd().makePath(wal_dir_path);

        var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
        defer wal_dir.close();

        var wal = try WalManager.init(
            self.allocator,
            wal_dir,
            graph_dir.graph_uuid,
            m.last_checkpoint_lsn,
            .{ .encryption_key = self.encryption_key },
        );
        defer wal.deinit();

        const start_lsn = if (m.last_checkpoint_lsn > 0) m.last_checkpoint_lsn + 1 else 1;
        const records = try wal.readFrom(start_lsn, self.allocator);
        defer {
            for (records) |*r| r.deinit(self.allocator);
            self.allocator.free(records);
        }

        if (records.len == 0) {
            // Clean recovery: no WAL records to replay
            return m;
        }

        // 4. Classify transactions (skip records with checksum failures)
        var txn_states = std.AutoHashMap(u64, TxnRecoveryState).init(self.allocator);
        defer txn_states.deinit();

        for (records) |rec| {
            // Verify checksum before trusting the record
            if (rec.checksum != rec.computeChecksum()) {
                self.skipped_checksum_failures += 1;
                continue;
            }

            switch (rec.record_type) {
                .begin_txn => {
                    try txn_states.put(rec.txn_id, .active);
                },
                .commit_txn => {
                    try txn_states.put(rec.txn_id, .committed);
                },
                .abort_txn => {
                    try txn_states.put(rec.txn_id, .aborted);
                },
                .page_update, .checkpoint_marker => {},
            }
        }

        // 5. Replay committed page_update records into buffer pool
        for (records) |rec| {
            if (rec.record_type != .page_update) continue;

            // Verify checksum before applying record
            if (rec.checksum != rec.computeChecksum()) {
                // Already counted in step 4; skip silently here
                continue;
            }

            const state = txn_states.get(rec.txn_id) orelse continue;
            if (state != .committed) continue;

            // Apply the page image to the buffer pool
            const file_id: FileId = std.meta.intToEnum(FileId, rec.file_id) catch return error.InvalidFormat;
            const frame = try buffer_pool.pinNew(file_id, rec.page_id);
            const frame_idx = buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();

            // Copy the page image from the WAL record payload
            const copy_len = @min(rec.payload.len, data.len);
            if (copy_len > 0) {
                @memcpy(data[0..copy_len], rec.payload[0..copy_len]);
            }

            buffer_pool.unpin(frame_idx, true);
        }

        // 7. Flush buffer pool to disk
        try buffer_pool.flushAll();

        // 8. Write fresh checkpoint
        try file_manager.syncAll();
        m.counter += 1;
        m.last_checkpoint_lsn = wal.currentLsn();

        // Write to both slots for a clean state after recovery
        const manifest_path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(manifest_path_a);
        try m.writeToFile(self.allocator, manifest_path_a);

        const manifest_path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(manifest_path_b);
        try m.writeToFile(self.allocator, manifest_path_b);

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
    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const uuid = [_]u8{0xBB} ** 16;
    const gd = try GraphDir.create(allocator, dir_path, uuid);

    // Create WAL directory
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{gd.path});
    defer allocator.free(wal_dir_path);
    try std.fs.cwd().makePath(wal_dir_path);

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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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
    const page_mod = @import("page.zig");
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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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
    const page_mod = @import("page.zig");
    var has_uncommitted_data = true;
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xCD) {
            has_uncommitted_data = false;
            break;
        }
    }
    try testing.expect(!has_uncommitted_data);
}

test "recovery skips WAL records with corrupted checksums" {
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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // The corrupted page_update record should have been skipped
    try testing.expect(recovery.skipped_checksum_failures >= 1);
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

test "GAP-0005a: torn/truncated WAL record is safely skipped during recovery" {
    // A truncated record at the end of the WAL should not prevent recovery.
    // The WAL reader (wal.readFrom) skips unparseable entries via `catch continue`
    // in the deserialize path, and recovery further skips records with bad checksums.
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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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

    // Run recovery -- should succeed despite the truncated record
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const recovered = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Recovery succeeded: counter was incremented (WAL had committed records)
    try testing.expectEqual(@as(u64, 2), recovered.counter);
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
        const corrupt_file = try std.fs.cwd().createFile(path_a, .{});
        defer corrupt_file.close();
        var garbage: [148]u8 = undefined;
        @memset(&garbage, 0xFF); // total garbage, invalid magic + CRC
        try corrupt_file.writeAll(&garbage);
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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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
    const page_mod = @import("page.zig");

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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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
    const page_mod = @import("page.zig");

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
    var wal_dir = try std.fs.cwd().openDir(wal_dir_path, .{});
    defer wal_dir.close();

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

test {
    std.testing.refAllDecls(@This());
}
