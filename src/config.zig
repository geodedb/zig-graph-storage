// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub const LogLevel = enum { debug, info, warn, err };

pub const GraphConfig = struct {
    page_size: u32 = 8192,
    buffer_pool_pages: u32 = 1024,
    wal_segment_size: u64 = 16 * 1024 * 1024,
    checkpoint_byte_threshold: u64 = 16 * 1024 * 1024,
    checkpoint_time_threshold_ms: u64 = 60_000,
    encryption_key: ?[32]u8 = null,
    data_dir: []const u8 = "data",
    log_fn: ?*const fn (level: LogLevel, msg: []const u8) void = null,
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

test {
    std.testing.refAllDecls(@This());
}
