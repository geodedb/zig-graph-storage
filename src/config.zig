// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub const LogLevel = enum { debug, info, warn, err };

/// Structured lifecycle event emitted through the config log_fn callback.
pub const StorageEvent = enum {
    checkpoint_start,
    checkpoint_end,
    recovery_start,
    recovery_end,
    backup_start,
    backup_end,

    /// Return a human-readable label for the event.
    pub fn label(self: StorageEvent) []const u8 {
        return switch (self) {
            .checkpoint_start => "checkpoint_start",
            .checkpoint_end => "checkpoint_end",
            .recovery_start => "recovery_start",
            .recovery_end => "recovery_end",
            .backup_start => "backup_start",
            .backup_end => "backup_end",
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

test {
    std.testing.refAllDecls(@This());
}
