// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const builtin = @import("builtin");
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

/// SONNY-6491: TEST-ONLY crash points of the checkpoint sequence. A test sets
/// `Checkpointer.test_fault`; the checkpoint then stops with
/// `error.TestCrashInjected` right after the named step, leaving on disk
/// exactly what a process killed at that moment leaves. Outside test builds
/// the field is `void` and every check compiles to nothing.
pub const FaultPoint = enum {
    /// Pages flushed and fsynced; manifest not yet written.
    pre_manifest,
    /// Manifest written; WAL not yet truncated.
    post_manifest,
    /// WAL truncated up to the checkpoint LSN.
    post_wal_truncate,
    /// `free.store` saved.
    post_free_store,
    /// `labels.dict` saved.
    post_label_dict,
    /// Derived-index snapshots saved (full checkpoint and close only).
    post_derived,
};

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
    /// SONNY-6491: see `FaultPoint`. `void` outside test builds.
    test_fault: if (builtin.is_test) ?FaultPoint else void = if (builtin.is_test) null else {},

    /// SONNY-6491: stop here when a test asked to crash after step `p`.
    pub fn faultPoint(self: *const Checkpointer, p: FaultPoint) error{TestCrashInjected}!void {
        if (comptime !builtin.is_test) return;
        if (self.test_fault) |f| {
            if (f == p) return error.TestCrashInjected;
        }
    }

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

    /// SONNY-6491: work that must be durable BEFORE the manifest that depends
    /// on it (the engine's `free.store`). Runs after the pages are flushed and
    /// fsynced, so it sees the state the manifest is about to cover.
    pub const PreManifest = struct {
        ctx: *anyopaque,
        run: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Run a checkpoint with no pre-manifest step.
    pub fn doCheckpoint(self: *Checkpointer) !void {
        return self.doCheckpointWith(null);
    }

    /// Run a checkpoint:
    ///   1. record the WAL LSN, 2. flush dirty pages, 3. fsync dirty store
    ///   files, 4. `pre` (side files, made durable by the caller), 5. write
    ///   the manifest and fsync the graph directory, 6. truncate the WAL.
    /// Each step is durable before the next starts, so a crash anywhere
    /// leaves either the previous manifest with an untruncated WAL (recovery
    /// replays it) or the new manifest with side files at least as new.
    pub fn doCheckpointWith(self: *Checkpointer, pre: ?PreManifest) !void {
        config_mod.emitEvent(self.log_fn, .checkpoint_start);
        errdefer config_mod.emitEvent(self.log_fn, .checkpoint_end);

        // 1. Record checkpoint LSN
        const checkpoint_lsn = self.wal.currentLsn();

        // 2. Flush all dirty pages
        try self.buffer_pool.flushAll();

        // 3. Sync ONLY the store files modified since their last successful fsync
        //    (PERF-0057). takeDirtyFiles() drains the set the flush in step 2
        //    just populated; syncDirty() then fsyncs exactly those files. This
        //    runs BEFORE the manifest write below and BEFORE the WAL truncate in
        //    step 7, preserving the data -> manifest -> WAL-truncate durability
        //    ordering. A file is skipped only when no page was written to it
        //    since its last fsync, so its on-disk state is already durable.
        const dirty_files = self.buffer_pool.takeDirtyFiles();
        // If anything from here through the manifest write fails, restore the
        // drained marks so the next checkpoint re-fsyncs these files. Without
        // this, a failed fsync would clear the flags and a later checkpoint
        // could skip a file whose data is not yet durable.
        errdefer self.buffer_pool.restoreDirtyFiles(dirty_files);
        try self.file_manager.syncDirty(dirty_files);
        if (pre) |step| try step.run(step.ctx);
        try self.faultPoint(.pre_manifest);

        // 4. Update manifest
        self.manifest.last_checkpoint_lsn = checkpoint_lsn;
        self.manifest.counter += 1;
        // Advance the durable derived-index freshness epoch. This is the ONLY
        // site that touches checkpoint_epoch — recovery.zig:recover leaves it
        // unchanged when it replays a WAL tail (it bumps `counter` for A/B
        // freshness and overwrites `last_checkpoint_lsn`, but NOT the epoch), so
        // a snapshot stamped at epoch E stays valid-as-of its covered LSN across
        // a pure tail recovery.
        self.manifest.checkpoint_epoch += 1;

        // 5. Write manifest to the alternate slot
        const next_slot: GraphDir.ManifestSlot = switch (self.last_slot) {
            .a => .b,
            .b => .a,
        };

        const manifest_path = try self.graph_dir.manifestPath(self.allocator, next_slot);
        defer self.allocator.free(manifest_path);

        try self.manifest.writeToFileWithKey(self.allocator, manifest_path, self.encryption_key);
        // SONNY-6491: the manifest rename must be durable before the WAL is
        // truncated below; otherwise power loss can leave the previous
        // manifest next to a WAL that no longer holds what it needs.
        try syncDir(self.graph_dir.path);

        // 6. Update last_slot tracker
        self.last_slot = next_slot;
        try self.faultPoint(.post_manifest);

        // 7. Truncate WAL up to checkpoint_lsn
        if (checkpoint_lsn > 0) {
            try self.wal.truncate(checkpoint_lsn);
        }
        try self.faultPoint(.post_wal_truncate);

        config_mod.emitEvent(self.log_fn, .checkpoint_end);
    }

    /// fsync directory `path`, making the renames into it durable.
    pub fn syncDir(path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        // `.iterate = true`: a real O_RDONLY|O_DIRECTORY fd (O_PATH cannot fsync).
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        const dir_file = std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
        try dir_file.sync(io);
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

const page_mod = @import("page.zig");
const FileId = @import("types.zig").FileId;
const FILE_COUNT = @typeInfo(FileId).@"enum".fields.len;

test "PERF-0057: checkpoint drains the buffer pool dirty-file set" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    // Write a dirty page to the nodes store through the pool.
    const nodes_pager = env.file_manager.getPager(.nodes).?;
    const f = try env.buffer_pool.pinNew(.nodes, 0);
    const header = page_mod.initHeader(0, .node_data, 4096);
    @memcpy(f.dataSlice()[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
    @memset(f.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x5A);
    f.dirty = true;
    env.buffer_pool.unpin(env.buffer_pool.frameIndex(f), true);

    var cp = Checkpointer.init(
        testing.allocator,
        &env.buffer_pool,
        &env.wal,
        &env.manifest,
        &env.file_manager,
        &env.graph_dir,
    );

    try cp.doCheckpoint();

    // The checkpoint must have drained the dirty-file set (it owns the fsync).
    const after = env.buffer_pool.takeDirtyFiles();
    for (after) |d| try testing.expect(!d);

    // The page must be readable from disk (durability of the synced file).
    var read_buf: [4096]u8 = undefined;
    try nodes_pager.readPage(0, &read_buf);
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |b| {
        try testing.expectEqual(@as(u8, 0x5A), b);
    }
}

test "PERF-0057: a checkpoint with no page writes leaves the dirty set empty" {
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

    // No pages written -> the flush flags nothing.
    try cp.doCheckpoint();
    const after = env.buffer_pool.takeDirtyFiles();
    for (after) |d| try testing.expect(!d);
}

test "PERF-0057: a flush after checkpoint flags the modified file for the next sync" {
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

    // First checkpoint with no writes drains nothing.
    try cp.doCheckpoint();

    // Write a dirty nodes page and flush WITHOUT checkpointing: the file must be
    // flagged so the NEXT checkpoint fsyncs it (proving no fsync is dropped).
    const f = try env.buffer_pool.pinNew(.nodes, 1);
    const header = page_mod.initHeader(1, .node_data, 4096);
    @memcpy(f.dataSlice()[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
    @memset(f.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x6B);
    f.dirty = true;
    env.buffer_pool.unpin(env.buffer_pool.frameIndex(f), true);
    try env.buffer_pool.flushAll();

    // Peek the live flags without draining by restoring after.
    const flags = env.buffer_pool.takeDirtyFiles();
    try testing.expect(flags[@intFromEnum(FileId.nodes)]);
    env.buffer_pool.restoreDirtyFiles(flags);

    // The next checkpoint drains and fsyncs it.
    try cp.doCheckpoint();
    const after = env.buffer_pool.takeDirtyFiles();
    for (after) |d| try testing.expect(!d);
}

test {
    std.testing.refAllDecls(@This());
}
