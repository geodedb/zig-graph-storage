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
    // GAP-0900 L2: count of full derived-index saves performed by checkpoints.
    // A "light" checkpoint (save_derived=false) skips the O(graph) derived-index
    // save and does NOT bump this counter; a full checkpoint does. Tests assert
    // this stays flat across light checkpoints to prove the bounded path.
    derived_index_saves: u64 = 0,

    // Derived-index restore path taken on the LAST open(), wired in engine.open
    // AFTER the metrics reset so it survives. Exactly one of these is 1 per open
    // of an existing graph. derived_index_loads=1 means the persisted snapshots
    // matched the manifest counter and were loaded in O(snapshot) (Lever B clean
    // restart); derived_index_rebuilds=1 means they were stale/absent and the
    // O(graph) rebuildDerivedIndexes ran (crash restart, or first open). These
    // distinguish load-vs-rebuild, which index_rebuild_progress cannot (it is
    // unconditionally set to 10000 by wireMetricsCounters on every open).
    derived_index_loads: u64 = 0,
    derived_index_rebuilds: u64 = 0,

    // WAL-aware durability (Path B): counts opens where the derived-index
    // snapshots matched the manifest checkpoint_epoch (so the epoch gate would
    // have accepted them) BUT a committed WAL tail existed beyond their
    // covered_lsn. In Phase 2 this case is routed to a full rebuild for
    // correctness (never serve stale); Phase 3 replaces the rebuild with a
    // bounded tail reconcile. A non-zero value here on a crash reopen proves
    // the epoch gate no longer wrongly rejects on the recovery-bumped counter —
    // it accepted the epoch and deferred solely because of the tail.
    derived_index_tail_deferred: u64 = 0,

    // GAP warm-reopen P2: number of CLEAN derived-index snapshots whose
    // persisted checkpoint_counter was cheaply re-stamped (header-only
    // update, payload untouched) to the new manifest.counter by a FULL
    // checkpoint, so a partially-dirty session (e.g. edges-only) does not
    // counter-invalidate the untouched snapshots and force an O(graph)
    // rebuild on the next open. A DIRTY index is saved, never restamped.
    derived_index_restamps: u64 = 0,

    // H3-P1: per-(label,key) ordered-index restore path taken on the LAST open(),
    // wired in engine.open AFTER the metrics reset (same discipline as the
    // derived counters). At most one is 1 per open of a graph that HAS a
    // registered ordered index: ordered_index_loads=1 means the snapshot counter
    // matched manifest.counter and the trees were loaded (clean restart);
    // ordered_index_rebuilds=1 means the snapshot was stale/absent and the trees
    // were rebuilt from a live scan (crash restart). ordered_index_saves counts
    // full-checkpoint snapshot saves (light checkpoints skip it).
    ordered_index_loads: u64 = 0,
    ordered_index_rebuilds: u64 = 0,
    ordered_index_saves: u64 = 0,
    // H3-P1 checkpoint-refresh: counts FULL-checkpoint ordered-index rebuilds
    // from a live scan that correct in-place property-value drift (the engine
    // has no node-aware property-write hook). Mirrors engine_property_index's
    // refreshLive cadence. A LIGHT checkpoint NEVER bumps this (it stays
    // O(dirty)); tests assert it flat across light checkpoints.
    ordered_index_refreshes: u64 = 0,

    // Recovery
    recovery_duration_ns: u64 = 0,

    // WAL segments (wired in engine.wireMetricsCounters)
    wal_segment_count: u64 = 0,

    // Storage health (wired in engine.wireMetricsCounters and engine_index.rebuildDerivedIndexes)
    fragmentation_ratio: u64 = 0, // fixed-point x10000
    index_rebuild_progress: u64 = 0, // 0-10000 for 0%-100%

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
