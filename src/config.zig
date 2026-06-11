// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const tp = @import("thread_pool");

pub const LogLevel = enum { debug, info, warn, err };

/// Structured lifecycle event emitted through the config log_fn callback.
pub const StorageEvent = enum {
    checkpoint_start,
    checkpoint_end,
    recovery_start,
    recovery_end,
    backup_start,
    backup_end,
    migration_start,
    migration_end,
    verify_start,
    verify_end,
    index_build_start,
    index_build_end,

    /// Return a human-readable label for the event.
    pub fn label(self: StorageEvent) []const u8 {
        return switch (self) {
            .checkpoint_start => "checkpoint_start",
            .checkpoint_end => "checkpoint_end",
            .recovery_start => "recovery_start",
            .recovery_end => "recovery_end",
            .backup_start => "backup_start",
            .backup_end => "backup_end",
            .migration_start => "migration_start",
            .migration_end => "migration_end",
            .verify_start => "verify_start",
            .verify_end => "verify_end",
            .index_build_start => "index_build_start",
            .index_build_end => "index_build_end",
        };
    }
};

/// Helper to emit a storage event through the log callback if present.
pub fn emitEvent(
    log_fn: ?*const fn (level: LogLevel, msg: []const u8) void,
    event: StorageEvent,
) void {
    if (log_fn) |f| {
        f(.info, event.label());
    }
}

/// Policy for handling V1 (legacy) graph format during recovery.
pub const LegacyPolicy = enum {
    /// Reject V1 format with IncompatibleVersion error (default).
    reject,
    /// Open V1 format in read-only mode. Mutations are not permitted.
    read_only,
};

/// Durability policy for committing a transaction's WAL records.
///
/// Controls whether each commit issues its own `fsync` of the WAL. The
/// DEFAULT (`sync_each_commit`) preserves the strong per-commit durability
/// contract (NFR-SEC-003): once `commit` returns, the COMMIT record is on
/// stable storage and the transaction survives a crash. The alternate mode
/// is OPT-IN and trades durability for throughput; it must be chosen
/// explicitly and its weaker guarantee is documented below.
pub const SyncMode = enum {
    /// DEFAULT. fsync the WAL on every commit. An acknowledged commit (one
    /// for which `commit` has returned) is guaranteed durable across a crash
    /// before its caller continues. This is the historical, unchanged
    /// behavior and the only mode that satisfies NFR-SEC-003 by itself.
    sync_each_commit,

    /// RELAXED DURABILITY — OPT-IN ONLY. The COMMIT record is appended to the
    /// WAL but the per-commit `fsync` is skipped. Acknowledged commits live
    /// only in the OS page cache until the next durability barrier and MAY BE
    /// LOST if the process or machine crashes before one occurs.
    ///
    /// A commit becomes durable when any of the following runs successfully:
    ///   - an explicit `checkpoint()` (flushes and fsyncs the modified data
    ///     pages to their store files, independent of the WAL), or
    ///   - a clean `close()` (which checkpoints when there are pending
    ///     writes), or
    ///   - an automatic checkpoint triggered by the configured byte/time
    ///     thresholds.
    ///
    /// Choose this only for bulk-load / replayable-ingest workloads that
    /// checkpoint (or cleanly close) before treating data as durable, and
    /// that can tolerate losing the most recent un-checkpointed commits on
    /// an unclean shutdown. Throughput improves because fsync no longer
    /// dominates write wall time (see PERF-0045).
    deferred,
};

pub const GraphConfig = struct {
    page_size: u32 = 8192,
    buffer_pool_pages: u32 = 1024,
    /// When true (default), `GraphEngine.open()` will auto-size the buffer pool
    /// based on the manifest's total page counts. The pool will be at least
    /// `buffer_pool_pages` but may grow up to 65536 pages (512 MB at 8 KB pages).
    buffer_pool_auto_size: bool = true,
    wal_segment_size: u64 = 16 * 1024 * 1024,
    checkpoint_byte_threshold: u64 = 16 * 1024 * 1024,
    checkpoint_time_threshold_ms: u64 = 60_000,
    encryption_key: ?[32]u8 = null,
    data_dir: []const u8 = "data",
    log_fn: ?*const fn (level: LogLevel, msg: []const u8) void = null,
    /// Policy for handling legacy (V1) graph formats during recovery.
    legacy_policy: LegacyPolicy = .reject,
    /// Durability policy for transaction commits. DEFAULT
    /// (`sync_each_commit`) fsyncs the WAL on every commit so an
    /// acknowledged commit is crash-durable before the caller continues
    /// (NFR-SEC-003). The `deferred` mode is opt-in and explicitly relaxes
    /// this guarantee for throughput — see `SyncMode` for the exact
    /// semantics and the durability barriers that make deferred commits
    /// durable. Wired into the per-shard `TxnManager` at open/create time.
    sync_mode: SyncMode = .sync_each_commit,
    /// Bootstrap paths may create missing on-disk artifacts. Steady-state
    /// open/recovery flows must leave this disabled so damage fails closed.
    allow_create_missing_artifacts: bool = false,
    /// Shard index (0..SHARD_COUNT-1) for striped id allocation. When
    /// non-null, `allocNode` returns `k*SHARD_COUNT + base_shard_index`
    /// and `addEdge` bumps edge ids by `SHARD_COUNT`. `null` preserves
    /// the classic single-engine behaviour (++1 stride).
    base_shard_index: ?usize = null,
    /// Optional caller-owned ThreadPool. When non-null, the engine borrows
    /// this pool for parallel buffer-pool flushes instead of creating its
    /// own. The engine never calls `pool.deinit()` or `pool.shutdown()` on
    /// a borrowed pool — the caller's lifetime must outlive every engine
    /// that borrows it. Used by ShardedGraphEngine (one pool / sharded
    /// graph) and by long-lived servers (one pool / process). When null
    /// (default), each engine creates and owns a pool of
    /// `default_owned_pool_max_threads` workers (4 — see engine.zig).
    external_thread_pool: ?*tp.ThreadPool = null,

    /// Compute the effective buffer pool size, applying auto-sizing when enabled.
    ///
    /// When `buffer_pool_auto_size` is true, the returned value is:
    ///   max(buffer_pool_pages, clamp(total_manifest_pages, 1024, 65536))
    /// When false, returns `buffer_pool_pages` unchanged.
    pub fn effectiveBufferPoolPages(self: *const GraphConfig, manifest_total_pages: u64) u32 {
        if (!self.buffer_pool_auto_size) {
            return self.buffer_pool_pages;
        }
        const clamped: u32 = @intCast(@min(@max(manifest_total_pages, 1024), 65536));
        return @max(self.buffer_pool_pages, clamped);
    }

    /// Securely zero the encryption key if present. Should be called during
    /// engine shutdown to prevent key material from lingering in memory.
    pub fn zeroKey(self: *GraphConfig) void {
        if (self.encryption_key) |*key| {
            std.crypto.secureZero(u8, key);
            self.encryption_key = null;
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "default config values" {
    const cfg = GraphConfig{};
    try std.testing.expectEqual(@as(u32, 8192), cfg.page_size);
    try std.testing.expectEqual(@as(u32, 1024), cfg.buffer_pool_pages);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), cfg.wal_segment_size);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), cfg.checkpoint_byte_threshold);
    try std.testing.expectEqual(@as(u64, 60_000), cfg.checkpoint_time_threshold_ms);
    try std.testing.expectEqual(@as(?[32]u8, null), cfg.encryption_key);
    try std.testing.expectEqualStrings("data", cfg.data_dir);
    try std.testing.expectEqual(@as(?*const fn (level: LogLevel, msg: []const u8) void, null), cfg.log_fn);
}

test "external_thread_pool defaults to null" {
    const cfg = GraphConfig{};
    try std.testing.expectEqual(@as(?*tp.ThreadPool, null), cfg.external_thread_pool);
}

test "config with custom values" {
    var key: [32]u8 = undefined;
    @memset(&key, 0xAB);

    const cfg = GraphConfig{
        .page_size = 4096,
        .buffer_pool_pages = 2048,
        .wal_segment_size = 32 * 1024 * 1024,
        .checkpoint_byte_threshold = 64 * 1024 * 1024,
        .checkpoint_time_threshold_ms = 120_000,
        .encryption_key = key,
        .data_dir = "/tmp/graph",
        .log_fn = null,
    };

    try std.testing.expectEqual(@as(u32, 4096), cfg.page_size);
    try std.testing.expectEqual(@as(u32, 2048), cfg.buffer_pool_pages);
    try std.testing.expectEqual(@as(u64, 32 * 1024 * 1024), cfg.wal_segment_size);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), cfg.checkpoint_byte_threshold);
    try std.testing.expectEqual(@as(u64, 120_000), cfg.checkpoint_time_threshold_ms);
    try std.testing.expectEqual(@as(u8, 0xAB), cfg.encryption_key.?[0]);
    try std.testing.expectEqualStrings("/tmp/graph", cfg.data_dir);
}

test "zeroKey zeros encryption key and sets to null" {
    var cfg = GraphConfig{
        .encryption_key = [_]u8{0xBB} ** 32,
    };

    // Key should be present before zeroKey
    try std.testing.expect(cfg.encryption_key != null);

    cfg.zeroKey();

    // After zeroKey, encryption_key must be null
    try std.testing.expectEqual(@as(?[32]u8, null), cfg.encryption_key);
}

test "buffer_pool_auto_size defaults to true" {
    const cfg = GraphConfig{};
    try std.testing.expect(cfg.buffer_pool_auto_size);
}

test "effectiveBufferPoolPages auto-sizes from manifest pages" {
    const cfg = GraphConfig{
        .buffer_pool_pages = 1024,
        .buffer_pool_auto_size = true,
    };

    // When manifest has fewer pages than minimum (1024), clamp to 1024
    try std.testing.expectEqual(@as(u32, 1024), cfg.effectiveBufferPoolPages(500));

    // When manifest has more pages than configured, use manifest total
    try std.testing.expectEqual(@as(u32, 4096), cfg.effectiveBufferPoolPages(4096));

    // When manifest pages exceed max (65536), clamp to 65536
    try std.testing.expectEqual(@as(u32, 65536), cfg.effectiveBufferPoolPages(100_000));

    // When configured is larger than recommended, use configured
    const big_cfg = GraphConfig{
        .buffer_pool_pages = 8192,
        .buffer_pool_auto_size = true,
    };
    try std.testing.expectEqual(@as(u32, 8192), big_cfg.effectiveBufferPoolPages(2000));
}

test "effectiveBufferPoolPages disabled returns configured value" {
    const cfg = GraphConfig{
        .buffer_pool_pages = 512,
        .buffer_pool_auto_size = false,
    };
    // Even with large manifest, returns configured value
    try std.testing.expectEqual(@as(u32, 512), cfg.effectiveBufferPoolPages(50000));
}

test "zeroKey is safe to call when no key is set" {
    var cfg = GraphConfig{};
    try std.testing.expectEqual(@as(?[32]u8, null), cfg.encryption_key);

    // Should not panic
    cfg.zeroKey();

    try std.testing.expectEqual(@as(?[32]u8, null), cfg.encryption_key);
}

test "StorageEvent labels are distinct and non-empty" {
    const events = [_]StorageEvent{
        .checkpoint_start,
        .checkpoint_end,
        .recovery_start,
        .recovery_end,
        .backup_start,
        .backup_end,
        .migration_start,
        .migration_end,
        .verify_start,
        .verify_end,
        .index_build_start,
        .index_build_end,
    };
    for (events) |ev| {
        try std.testing.expect(ev.label().len > 0);
    }
}

var test_event_count: usize = 0;

fn testLogFn(_: LogLevel, _: []const u8) void {
    test_event_count += 1;
}

test "emitEvent invokes log_fn callback" {
    test_event_count = 0;
    const log: *const fn (level: LogLevel, msg: []const u8) void = &testLogFn;
    emitEvent(log, .checkpoint_start);
    emitEvent(log, .checkpoint_end);
    try std.testing.expectEqual(@as(usize, 2), test_event_count);
}

test "emitEvent is safe with null log_fn" {
    // Should not panic
    emitEvent(null, .recovery_start);
}

var test_event_labels: [16][]const u8 = undefined;
var test_event_label_count: usize = 0;

fn testLabelLogFn(_: LogLevel, msg: []const u8) void {
    if (test_event_label_count < test_event_labels.len) {
        test_event_labels[test_event_label_count] = msg;
        test_event_label_count += 1;
    }
}

test "NFR-OBS-002: new lifecycle event variants have correct labels" {
    try std.testing.expectEqualStrings("migration_start", StorageEvent.migration_start.label());
    try std.testing.expectEqualStrings("migration_end", StorageEvent.migration_end.label());
    try std.testing.expectEqualStrings("verify_start", StorageEvent.verify_start.label());
    try std.testing.expectEqualStrings("verify_end", StorageEvent.verify_end.label());
    try std.testing.expectEqualStrings("index_build_start", StorageEvent.index_build_start.label());
    try std.testing.expectEqualStrings("index_build_end", StorageEvent.index_build_end.label());
}

test "NFR-OBS-002: emitEvent delivers new lifecycle events in order" {
    test_event_label_count = 0;
    const log: *const fn (level: LogLevel, msg: []const u8) void = &testLabelLogFn;
    emitEvent(log, .migration_start);
    emitEvent(log, .migration_end);
    emitEvent(log, .verify_start);
    emitEvent(log, .verify_end);
    emitEvent(log, .index_build_start);
    emitEvent(log, .index_build_end);
    try std.testing.expectEqual(@as(usize, 6), test_event_label_count);
    try std.testing.expectEqualStrings("migration_start", test_event_labels[0]);
    try std.testing.expectEqualStrings("migration_end", test_event_labels[1]);
    try std.testing.expectEqualStrings("verify_start", test_event_labels[2]);
    try std.testing.expectEqualStrings("verify_end", test_event_labels[3]);
    try std.testing.expectEqualStrings("index_build_start", test_event_labels[4]);
    try std.testing.expectEqualStrings("index_build_end", test_event_labels[5]);
}

test {
    std.testing.refAllDecls(@This());
}
