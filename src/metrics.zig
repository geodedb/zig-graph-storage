// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

/// Lightweight metrics for engine observability.
///
/// All fields are simple u64 counters with zero default values.
/// No heap allocations, no locking -- designed for a single-threaded engine.
pub const Metrics = struct {
    // Page I/O
    page_reads: u64 = 0,
    page_writes: u64 = 0,
    buffer_hits: u64 = 0,
    buffer_misses: u64 = 0,

    // WAL
    wal_appends: u64 = 0,
    wal_bytes_written: u64 = 0,

    // Transactions
    txn_begun: u64 = 0,
    txn_committed: u64 = 0,
    txn_aborted: u64 = 0,

    // Operations
    nodes_created: u64 = 0,
    nodes_deleted: u64 = 0,
    edges_created: u64 = 0,
    edges_removed: u64 = 0,
    properties_written: u64 = 0,
    properties_read: u64 = 0,

    // Checkpoint
    checkpoints_completed: u64 = 0,
    last_checkpoint_duration_ns: u64 = 0,

    // Recovery
    recovery_duration_ns: u64 = 0,

    // WAL segments
    wal_segment_count: u64 = 0, // TODO: wire in WalManager segment tracking

    // Storage health
    fragmentation_ratio: u64 = 0, // TODO: wire in FreeSpaceManager fragmentation tracking (fixed-point ×10000)
    index_rebuild_progress: u64 = 0, // TODO: wire in IndexCatalog rebuild progress (0–10000 for 0%–100%)

    /// Return the buffer pool hit rate as a fraction in [0.0, 1.0].
    /// Returns 1.0 when no buffer accesses have been recorded yet.
    pub fn bufferHitRate(self: *const Metrics) f64 {
        const total = self.buffer_hits + self.buffer_misses;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.buffer_hits)) / @as(f64, @floatFromInt(total));
    }

    /// Reset all counters to zero.
    pub fn reset(self: *Metrics) void {
        self.* = .{};
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "Metrics zero-initialized by default" {
    const m = Metrics{};
    try testing.expectEqual(@as(u64, 0), m.page_reads);
    try testing.expectEqual(@as(u64, 0), m.page_writes);
    try testing.expectEqual(@as(u64, 0), m.buffer_hits);
    try testing.expectEqual(@as(u64, 0), m.buffer_misses);
    try testing.expectEqual(@as(u64, 0), m.wal_appends);
    try testing.expectEqual(@as(u64, 0), m.wal_bytes_written);
    try testing.expectEqual(@as(u64, 0), m.txn_begun);
    try testing.expectEqual(@as(u64, 0), m.txn_committed);
    try testing.expectEqual(@as(u64, 0), m.txn_aborted);
    try testing.expectEqual(@as(u64, 0), m.nodes_created);
    try testing.expectEqual(@as(u64, 0), m.nodes_deleted);
    try testing.expectEqual(@as(u64, 0), m.edges_created);
    try testing.expectEqual(@as(u64, 0), m.edges_removed);
    try testing.expectEqual(@as(u64, 0), m.properties_written);
    try testing.expectEqual(@as(u64, 0), m.properties_read);
    try testing.expectEqual(@as(u64, 0), m.checkpoints_completed);
    try testing.expectEqual(@as(u64, 0), m.last_checkpoint_duration_ns);
    try testing.expectEqual(@as(u64, 0), m.recovery_duration_ns);
    try testing.expectEqual(@as(u64, 0), m.wal_segment_count);
    try testing.expectEqual(@as(u64, 0), m.fragmentation_ratio);
    try testing.expectEqual(@as(u64, 0), m.index_rebuild_progress);
}

test "bufferHitRate returns 1.0 when no accesses" {
    const m = Metrics{};
    try testing.expectEqual(@as(f64, 1.0), m.bufferHitRate());
}

test "bufferHitRate computes correctly" {
    var m = Metrics{};
    m.buffer_hits = 75;
    m.buffer_misses = 25;
    try testing.expectApproxEqAbs(@as(f64, 0.75), m.bufferHitRate(), 0.0001);
}

test "bufferHitRate returns 0.0 when all misses" {
    var m = Metrics{};
    m.buffer_hits = 0;
    m.buffer_misses = 10;
    try testing.expectApproxEqAbs(@as(f64, 0.0), m.bufferHitRate(), 0.0001);
}

test "reset clears all counters" {
    var m = Metrics{};
    m.page_reads = 100;
    m.page_writes = 50;
    m.buffer_hits = 80;
    m.buffer_misses = 20;
    m.txn_begun = 10;
    m.nodes_created = 5;
    m.edges_created = 3;
    m.checkpoints_completed = 2;
    m.last_checkpoint_duration_ns = 999;

    m.reset();

    try testing.expectEqual(@as(u64, 0), m.page_reads);
    try testing.expectEqual(@as(u64, 0), m.page_writes);
    try testing.expectEqual(@as(u64, 0), m.buffer_hits);
    try testing.expectEqual(@as(u64, 0), m.buffer_misses);
    try testing.expectEqual(@as(u64, 0), m.txn_begun);
    try testing.expectEqual(@as(u64, 0), m.nodes_created);
    try testing.expectEqual(@as(u64, 0), m.edges_created);
    try testing.expectEqual(@as(u64, 0), m.checkpoints_completed);
    try testing.expectEqual(@as(u64, 0), m.last_checkpoint_duration_ns);
}

test "increment counters" {
    var m = Metrics{};
    m.page_reads += 1;
    m.page_writes += 1;
    m.buffer_hits += 1;
    m.buffer_misses += 1;
    m.wal_appends += 1;
    m.wal_bytes_written += 42;
    m.txn_begun += 1;
    m.txn_committed += 1;
    m.txn_aborted += 1;
    m.nodes_created += 1;
    m.nodes_deleted += 1;
    m.edges_created += 1;
    m.edges_removed += 1;
    m.properties_written += 1;
    m.properties_read += 1;
    m.checkpoints_completed += 1;
    m.last_checkpoint_duration_ns = 12345;

    try testing.expectEqual(@as(u64, 1), m.page_reads);
    try testing.expectEqual(@as(u64, 1), m.page_writes);
    try testing.expectEqual(@as(u64, 42), m.wal_bytes_written);
    try testing.expectEqual(@as(u64, 12345), m.last_checkpoint_duration_ns);
}

test {
    std.testing.refAllDecls(@This());
}
