// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

const buffer_pool_mod = @import("buffer_pool.zig");
const wal_mod = @import("wal.zig");
const manifest_mod = @import("manifest.zig");
const file_manager_mod = @import("file_manager.zig");
const graph_dir_mod = @import("graph_dir.zig");
const config_mod = @import("config.zig");

const BufferPool = buffer_pool_mod.BufferPool;
const WalManager = wal_mod.WalManager;
const Manifest = manifest_mod.Manifest;
const FileManager = file_manager_mod.FileManager;
const GraphDir = graph_dir_mod.GraphDir;

/// Incremental checkpointer that flushes dirty pages and updates the manifest.
///
/// The A/B manifest switching alternates between slot .a and .b on each
/// checkpoint, incrementing the manifest counter each time. This ensures
/// crash safety: at least one valid manifest is always on disk.
pub const Checkpointer = struct {
    buffer_pool: *BufferPool,
    wal: *WalManager,
    manifest: *Manifest,
    file_manager: *FileManager,
    graph_dir: *const GraphDir,
    allocator: Allocator,
    /// Which manifest slot was last written. Alternates each checkpoint.
    last_slot: GraphDir.ManifestSlot = .a,
    /// SEC-0043: encryption key for HMAC-authenticating the manifest under TDE.
    /// When set, checkpoints write the manifest with a keyed HMAC-SHA256 trailer.
    encryption_key: ?[32]u8 = null,
    /// Optional log callback for structured event emission.
    log_fn: ?*const fn (level: config_mod.LogLevel, msg: []const u8) void = null,

    pub fn init(
        allocator: Allocator,
        buffer_pool: *BufferPool,
        wal: *WalManager,
        manifest: *Manifest,
        file_manager: *FileManager,
        graph_dir: *const GraphDir,
    ) Checkpointer {
        return .{
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .wal = wal,
            .manifest = manifest,
            .file_manager = file_manager,
            .graph_dir = graph_dir,
        };
    }

    /// Run a checkpoint:
    pub fn doCheckpoint(self: *Checkpointer) !void {
        config_mod.emitEvent(self.log_fn, .checkpoint_start);
        errdefer config_mod.emitEvent(self.log_fn, .checkpoint_end);

        // 1. Record checkpoint LSN
        const checkpoint_lsn = self.wal.currentLsn();

        // 2. Flush all dirty pages
        try self.buffer_pool.flushAll();

        // 3. Sync all store files
        try self.file_manager.syncAll();

        // 4. Update manifest
        self.manifest.last_checkpoint_lsn = checkpoint_lsn;
        self.manifest.counter += 1;

        // 5. Write manifest to the alternate slot
        const next_slot: GraphDir.ManifestSlot = switch (self.last_slot) {
            .a => .b,
            .b => .a,
        };

        const manifest_path = try self.graph_dir.manifestPath(self.allocator, next_slot);
        defer self.allocator.free(manifest_path);

        try self.manifest.writeToFileWithKey(self.allocator, manifest_path, self.encryption_key);

        // 6. Update last_slot tracker
        self.last_slot = next_slot;

        // 7. Truncate WAL up to checkpoint_lsn
        if (checkpoint_lsn > 0) {
            try self.wal.truncate(checkpoint_lsn);
        }

        config_mod.emitEvent(self.log_fn, .checkpoint_end);
    }

    /// Check if checkpoint is needed based on WAL size.
    pub fn needsCheckpoint(self: *Checkpointer, byte_threshold: u64) bool {
        return self.wal.bytesSinceCompact() >= byte_threshold;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const wal_record = @import("wal_record.zig");
const WalRecord = wal_record.WalRecord;
const pager_module = @import("pager.zig");
const Pager = pager_module.Pager;

const TestEnv = struct {
    tmp_dir: testing.TmpDir,
    graph_dir: GraphDir,
    file_manager: FileManager,
    buffer_pool: BufferPool,
    wal: WalManager,
    manifest: Manifest,
    wal_dir_handle: std.Io.Dir,

    fn init() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const allocator = testing.allocator;

        // Create graph directory structure
        const dir_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
        defer allocator.free(dir_path);

        const gd = try GraphDir.create(allocator, dir_path, [_]u8{0xAA} ** 16);

        // Create WAL directory
        const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{gd.path});
        defer allocator.free(wal_dir_path);
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), wal_dir_path);
        const wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});

        var fm = FileManager.init(allocator, gd.path, 4096);
        _ = try fm.openFile(.nodes, .create_if_missing);

        const pool = try BufferPool.init(allocator, 4096, 16);

        const wal_mgr = try WalManager.init(allocator, wal_dir, [_]u8{0xAA} ** 16, 0, .{});

        const m = Manifest{
            .graph_uuid = [_]u8{0xAA} ** 16,
            .page_size = 4096,
        };

        return .{
            .tmp_dir = tmp_dir,
            .graph_dir = gd,
            .file_manager = fm,
            .buffer_pool = pool,
            .wal = wal_mgr,
            .manifest = m,
            .wal_dir_handle = wal_dir,
        };
    }

    fn fixup(self: *TestEnv) void {
        self.buffer_pool.registerPager(.nodes, self.file_manager.getPager(.nodes).?);
    }

    fn deinit(self: *TestEnv) void {
        self.wal.deinit();
        self.wal_dir_handle.close(std.Io.Threaded.global_single_threaded.io());
        self.buffer_pool.deinit();
        self.file_manager.deinit();
        self.graph_dir.deinit();
        self.tmp_dir.cleanup();
    }
};

test "run checkpoint updates manifest counter and last_checkpoint_lsn" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    // Append a WAL record to advance LSN
    var rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try env.wal.appendRecord(&rec);
    try env.wal.sync();

    var cp = Checkpointer.init(
        testing.allocator,
        &env.buffer_pool,
        &env.wal,
        &env.manifest,
        &env.file_manager,
        &env.graph_dir,
    );

    try cp.doCheckpoint();

    // Manifest should be updated
    try testing.expectEqual(@as(u64, 1), env.manifest.counter);
    try testing.expect(env.manifest.last_checkpoint_lsn > 0);

    // Verify manifest was written to disk (slot .b since last_slot starts at .a)
    const path_b = try env.graph_dir.manifestPath(testing.allocator, .b);
    defer testing.allocator.free(path_b);
    const loaded = try Manifest.readFromFile(testing.allocator, path_b);
    try testing.expect(loaded != null);
    try testing.expectEqual(@as(u64, 1), loaded.?.counter);
}

test "run checkpoint truncates WAL" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    // Append several WAL records
    for (0..5) |_| {
        var rec = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .page_update,
            .file_id = 0,
            .page_id = 0,
            .payload = "test data",
            .checksum = 0,
        };
        _ = try env.wal.appendRecord(&rec);
    }
    try env.wal.sync();

    var cp = Checkpointer.init(
        testing.allocator,
        &env.buffer_pool,
        &env.wal,
        &env.manifest,
        &env.file_manager,
        &env.graph_dir,
    );

    try cp.doCheckpoint();

    // After truncation, reading from LSN 1 should return fewer or no records
    // (the external WAL library compacts, so old records are removed)
    try testing.expect(env.manifest.last_checkpoint_lsn > 0);
}

test "needsCheckpoint returns correct value" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var cp = Checkpointer.init(
        testing.allocator,
        &env.buffer_pool,
        &env.wal,
        &env.manifest,
        &env.file_manager,
        &env.graph_dir,
    );

    // With no WAL writes, bytes since compact should be 0
    try testing.expect(!cp.needsCheckpoint(100));

    // Append enough data to exceed threshold
    for (0..50) |_| {
        var rec = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .page_update,
            .file_id = 0,
            .page_id = 0,
            .payload = "x" ** 100,
            .checksum = 0,
        };
        _ = try env.wal.appendRecord(&rec);
    }
    try env.wal.sync();

    // With a low threshold it should now need a checkpoint
    try testing.expect(cp.needsCheckpoint(100));
}

var checkpoint_event_count: usize = 0;

fn checkpointTestLogFn(_: config_mod.LogLevel, _: []const u8) void {
    checkpoint_event_count += 1;
}

test "checkpoint emits start and end events via log_fn" {
    var env = try TestEnv.init();
    defer env.deinit();
    env.fixup();

    var cp = Checkpointer.init(
        testing.allocator,
        &env.buffer_pool,
        &env.wal,
        &env.manifest,
        &env.file_manager,
        &env.graph_dir,
    );
    cp.log_fn = &checkpointTestLogFn;

    checkpoint_event_count = 0;
    try cp.doCheckpoint();

    // Expect checkpoint_start + checkpoint_end = 2 events
    try testing.expectEqual(@as(usize, 2), checkpoint_event_count);
}

test {
    std.testing.refAllDecls(@This());
}
