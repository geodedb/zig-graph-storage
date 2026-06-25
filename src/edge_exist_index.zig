// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Edge-EXISTENCE index (PHASE 3, edge-engine-direct).
//!
//! Maps `(from_node, rel_type, to_node)` -> the set of edge ids with that exact
//! tuple, so a MERGE-edge dedup probe is O(1) instead of O(out-degree). It is a
//! DERIVED index with the SAME crash-safety lifecycle as the engine's `edge_index`
//! (edge_id -> entry): mutated in lock-step with the edge in
//! `addEdgeTxn`/`addEdgeColocatedTxn`/recovery-reapply, snapshotted at checkpoint,
//! and REBUILT from the durable out-adjacency on recovery whenever the snapshot
//! is stale or absent. Because it is a pure function of the WAL-logged adjacency
//! (the source of truth), a crash mid-batch can never leave the index disagreeing
//! with adjacency — whatever adjacency the WAL restores determines the rebuilt
//! index exactly. That is the "never create a duplicate edge on crash/recovery"
//! guarantee, by construction.
//!
//! Structure: a fast-path `AutoHashMap(ExistKey, EdgeId)` for the overwhelmingly
//! common one-edge-per-tuple case (a single hashmap probe), plus a rarely-used
//! `overflow` multimap that holds the full id list only for tuples that carry
//! parallel edges (e.g. geode multi-tenant same `(a,R,b)`). A key is in EXACTLY
//! one of the two maps at any time. `probe` returns the COMPLETE candidate set so
//! a higher layer (geode tenant disambiguation) preserves EXACT MERGE semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;

/// Index key. `extern struct` for a stable, padding-free 24-byte layout so the
/// AutoHashMap hashes the bytes deterministically and the snapshot round-trips
/// the same field order.
pub const ExistKey = extern struct {
    from: u64,
    to: u64,
    rel_type: u32,
    _pad: u32 = 0,
};

comptime {
    if (@sizeOf(ExistKey) != 24) @compileError("ExistKey must be exactly 24 bytes");
}

pub const EdgeExistenceIndex = struct {
    allocator: Allocator,
    /// One edge id per tuple — the hot path.
    primary: std.AutoHashMapUnmanaged(ExistKey, EdgeId),
    /// Full id list per tuple, ONLY for tuples with >= 2 edges. A key here is
    /// never simultaneously in `primary`.
    overflow: std.AutoHashMapUnmanaged(ExistKey, std.ArrayListUnmanaged(EdgeId)),
    /// Behavioral O(1) proof: candidate ids walked on the most recent `probe`.
    /// For a one-edge tuple this is 1; it tracks bucket size for the matched
    /// key, NOT the parent's out-degree.
    last_probe_entries_examined: usize = 0,

    pub fn init(allocator: Allocator) EdgeExistenceIndex {
        return .{
            .allocator = allocator,
            .primary = .empty,
            .overflow = .empty,
            .last_probe_entries_examined = 0,
        };
    }

    pub fn deinit(self: *EdgeExistenceIndex) void {
        self.primary.deinit(self.allocator);
        var it = self.overflow.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.overflow.deinit(self.allocator);
    }

    /// Drop all entries (used before a full rebuild / snapshot reload).
    pub fn clear(self: *EdgeExistenceIndex) void {
        self.primary.clearRetainingCapacity();
        var it = self.overflow.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.overflow.clearRetainingCapacity();
    }

    /// Number of DISTINCT (from,rel,to) keys (primary + overflow).
    pub fn keyCount(self: *const EdgeExistenceIndex) usize {
        return self.primary.count() + self.overflow.count();
    }

    /// Total number of (key, edge_id) records — the snapshot item count. Equals
    /// the number of edges represented (each edge appears once).
    pub fn recordCount(self: *const EdgeExistenceIndex) usize {
        var n: usize = self.primary.count();
        var it = self.overflow.iterator();
        while (it.next()) |e| {
            n += e.value_ptr.items.len;
        }
        return n;
    }

    fn keyOf(from: NodeId, rel_type: u32, to: NodeId) ExistKey {
        return .{ .from = from, .to = to, .rel_type = rel_type };
    }

    /// Insert `(from,rel,to) -> edge_id`. Idempotent per edge_id: inserting the
    /// SAME edge_id twice for a key does not create a duplicate record (recovery
    /// re-apply safety). A second DISTINCT edge_id for an existing key promotes
    /// the key into the overflow multimap.
    pub fn put(self: *EdgeExistenceIndex, from: NodeId, rel_type: u32, to: NodeId, edge_id: EdgeId) !void {
        const key = keyOf(from, rel_type, to);

        // Already in overflow → append if not present.
        if (self.overflow.getPtr(key)) |list| {
            for (list.items) |id| if (id == edge_id) return;
            try list.append(self.allocator, edge_id);
            return;
        }

        // In primary?
        if (self.primary.get(key)) |existing| {
            if (existing == edge_id) return; // idempotent
            // Promote: move both ids into a new overflow list, drop from primary.
            var list: std.ArrayListUnmanaged(EdgeId) = .empty;
            errdefer list.deinit(self.allocator);
            try list.append(self.allocator, existing);
            try list.append(self.allocator, edge_id);
            try self.overflow.put(self.allocator, key, list);
            _ = self.primary.remove(key);
            return;
        }

        // New key → primary fast path.
        try self.primary.put(self.allocator, key, edge_id);
    }

    /// Remove `(from,rel,to) -> edge_id`. No-op if absent. Collapses an overflow
    /// list back into `primary` when it drops to a single id, and removes the key
    /// entirely when its last id is gone.
    pub fn remove(self: *EdgeExistenceIndex, from: NodeId, rel_type: u32, to: NodeId, edge_id: EdgeId) void {
        const key = keyOf(from, rel_type, to);

        if (self.primary.getPtr(key)) |existing_ptr| {
            if (existing_ptr.* == edge_id) {
                _ = self.primary.remove(key);
            }
            return;
        }

        if (self.overflow.getPtr(key)) |list| {
            var idx: ?usize = null;
            for (list.items, 0..) |id, i| {
                if (id == edge_id) {
                    idx = i;
                    break;
                }
            }
            if (idx) |i| {
                _ = list.swapRemove(i);
            }
            if (list.items.len == 1) {
                const remaining = list.items[0];
                list.deinit(self.allocator);
                _ = self.overflow.remove(key);
                // Reinstate the lone survivor on the fast path.
                self.primary.put(self.allocator, key, remaining) catch {
                    // OOM reinstating is non-fatal for correctness of the probe
                    // (the edge still exists in adjacency and will be found on a
                    // rebuild); but to keep the invariant we re-add to overflow.
                    var l: std.ArrayListUnmanaged(EdgeId) = .empty;
                    l.append(self.allocator, remaining) catch return;
                    self.overflow.put(self.allocator, key, l) catch l.deinit(self.allocator);
                };
            } else if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.overflow.remove(key);
            }
        }
    }

    /// Probe for the complete candidate edge-id set of `(from,rel,to)`. Copies
    /// into `out` (caller-owned). Returns the populated prefix slice. O(1) for
    /// the common one-edge tuple; O(bucket) for the rare parallel-edge tuple —
    /// independent of the source node's total out-degree either way. Sets
    /// `last_probe_entries_examined`.
    pub fn probe(self: *EdgeExistenceIndex, from: NodeId, rel_type: u32, to: NodeId, out: []EdgeId) []const EdgeId {
        const key = keyOf(from, rel_type, to);

        if (self.primary.get(key)) |id| {
            self.last_probe_entries_examined = 1;
            if (out.len == 0) return out[0..0];
            out[0] = id;
            return out[0..1];
        }

        if (self.overflow.getPtr(key)) |list| {
            const n = @min(list.items.len, out.len);
            self.last_probe_entries_examined = n;
            @memcpy(out[0..n], list.items[0..n]);
            return out[0..n];
        }

        self.last_probe_entries_examined = 0;
        return out[0..0];
    }

    /// Preallocate for an expected number of distinct keys (rebuild/load hint).
    pub fn ensureTotalCapacity(self: *EdgeExistenceIndex, n: u32) !void {
        try self.primary.ensureTotalCapacity(self.allocator, n);
    }

    /// Visit every (key, edge_id) record exactly once. Used by the snapshot
    /// writer. The callback receives the unpacked tuple fields + edge_id.
    pub fn forEachRecord(
        self: *const EdgeExistenceIndex,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), from: NodeId, rel_type: u32, to: NodeId, edge_id: EdgeId) anyerror!void,
    ) !void {
        var pit = self.primary.iterator();
        while (pit.next()) |e| {
            try f(ctx, e.key_ptr.from, e.key_ptr.rel_type, e.key_ptr.to, e.value_ptr.*);
        }
        var oit = self.overflow.iterator();
        while (oit.next()) |e| {
            for (e.value_ptr.items) |id| {
                try f(ctx, e.key_ptr.from, e.key_ptr.rel_type, e.key_ptr.to, id);
            }
        }
    }
};

// ============================================================================
// Unit tests (pure data-structure; the durability/recovery tests live in
// tests/test_edge_existence_index.zig against the real engine lifecycle).
// ============================================================================

test "ExistKey is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ExistKey));
}

test "put/probe single edge per tuple" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();

    try idx.put(1, 7, 2, 100);
    var buf: [8]EdgeId = undefined;
    const got = idx.probe(1, 7, 2, &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(EdgeId, 100), got[0]);
    try std.testing.expectEqual(@as(usize, 1), idx.last_probe_entries_examined);

    // Miss returns an empty slice and zero examined.
    try std.testing.expectEqual(@as(usize, 0), idx.probe(1, 7, 3, &buf).len);
    try std.testing.expectEqual(@as(usize, 0), idx.last_probe_entries_examined);
}

test "put is idempotent for the same edge_id" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.put(1, 7, 2, 100);
    try idx.put(1, 7, 2, 100); // same id again
    var buf: [8]EdgeId = undefined;
    try std.testing.expectEqual(@as(usize, 1), idx.probe(1, 7, 2, &buf).len);
    try std.testing.expectEqual(@as(usize, 1), idx.recordCount());
}

test "parallel edges promote to overflow and probe returns all" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.put(1, 7, 2, 100);
    try idx.put(1, 7, 2, 200);
    var buf: [8]EdgeId = undefined;
    const got = idx.probe(1, 7, 2, &buf);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(usize, 2), idx.recordCount());
    try std.testing.expectEqual(@as(usize, 1), idx.keyCount());
}

test "remove collapses overflow back to primary and clears empty keys" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.put(1, 7, 2, 100);
    try idx.put(1, 7, 2, 200);
    idx.remove(1, 7, 2, 100);
    var buf: [8]EdgeId = undefined;
    const got = idx.probe(1, 7, 2, &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(EdgeId, 200), got[0]);
    // Now back on the primary fast path.
    idx.remove(1, 7, 2, 200);
    try std.testing.expectEqual(@as(usize, 0), idx.probe(1, 7, 2, &buf).len);
    try std.testing.expectEqual(@as(usize, 0), idx.recordCount());
}

test {
    std.testing.refAllDecls(@This());
}
