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
const snapshot = @import("sorted_index_snapshot.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;

/// GAP warm-reopen P1: on-disk sorted-record size — from u64 | to u64 |
/// rel_type u32 | edge_id u64 (same field order as GSXIDX1, but SORTED by
/// (from, to, rel_type, edge_id) under the GSXIDX2 magic).
pub const RECORD_SIZE: u32 = 28;

/// One (key, edge_id) record — the tombstone key and base decode target.
pub const ExistRecord = struct {
    from: u64,
    to: u64,
    rel_type: u32,
    edge_id: u64,
};

pub fn encodeRecord(buf: []u8, rec: ExistRecord) void {
    std.debug.assert(buf.len == RECORD_SIZE);
    std.mem.writeInt(u64, buf[0..8], rec.from, .little);
    std.mem.writeInt(u64, buf[8..16], rec.to, .little);
    std.mem.writeInt(u32, buf[16..20], rec.rel_type, .little);
    std.mem.writeInt(u64, buf[20..28], rec.edge_id, .little);
}

fn decodeRecord(rec: []const u8) ExistRecord {
    return .{
        .from = std.mem.readInt(u64, rec[0..8], .little),
        .to = std.mem.readInt(u64, rec[8..16], .little),
        .rel_type = std.mem.readInt(u32, rec[16..20], .little),
        .edge_id = std.mem.readInt(u64, rec[20..28], .little),
    };
}

fn recordOrder(a: ExistRecord, b: ExistRecord) std.math.Order {
    if (a.from != b.from) return std.math.order(a.from, b.from);
    if (a.to != b.to) return std.math.order(a.to, b.to);
    if (a.rel_type != b.rel_type) return std.math.order(a.rel_type, b.rel_type);
    return std.math.order(a.edge_id, b.edge_id);
}

pub fn recordLess(a: []const u8, b: []const u8) bool {
    return recordOrder(decodeRecord(a), decodeRecord(b)) == .lt;
}

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
    /// key, NOT the parent's out-degree. Since P1 (review M3, semantics
    /// note): in mmap-backed mode this counts overlay candidates PLUS the
    /// full contiguous base run for the key INCLUDING tombstoned records —
    /// still O(candidates-for-key), never O(out-degree).
    last_probe_entries_examined: usize = 0,

    /// GAP warm-reopen P1: immutable mmap'd sorted snapshot base (adopted at
    /// the counter-gated load instead of a record-by-record hashmap build).
    /// Null in resident mode (fresh create / rebuild-from-adjacency). The
    /// merged view is overlay(primary+overflow) ⊕ base ⊖ tombstones; a record
    /// is LIVE in exactly ONE place at a time (put/remove keep the invariant),
    /// so probes never see duplicates.
    /// UNMAP ORDERING (GAP-ENT-0018 UAF class): only `clear`/`deinit` unmap,
    /// and they run with no concurrent reader (hydration latch / teardown).
    base: ?snapshot.Loaded = null,
    /// Overlay deletions of base-resident records. A record here is DEAD; it
    /// is never simultaneously in the overlay (put resurrects the tombstone
    /// instead of inserting).
    tombstones: std.AutoHashMapUnmanaged(ExistRecord, void) = .empty,

    pub fn init(allocator: Allocator) EdgeExistenceIndex {
        return .{
            .allocator = allocator,
            .primary = .empty,
            .overflow = .empty,
            .last_probe_entries_examined = 0,
            .base = null,
            .tombstones = .empty,
        };
    }

    pub fn deinit(self: *EdgeExistenceIndex) void {
        self.primary.deinit(self.allocator);
        var it = self.overflow.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.overflow.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
        if (self.base) |*b| b.deinit();
        self.base = null;
    }

    /// Drop all entries INCLUDING the mmap base (used before a full rebuild /
    /// snapshot reload — no concurrent readers by contract, see `base` doc).
    pub fn clear(self: *EdgeExistenceIndex) void {
        self.primary.clearRetainingCapacity();
        var it = self.overflow.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.overflow.clearRetainingCapacity();
        self.tombstones.clearRetainingCapacity();
        if (self.base) |*b| b.deinit();
        self.base = null;
    }

    /// Adopt a loaded sorted snapshot as the immutable base (takes ownership
    /// ON SUCCESS; on error the caller still owns `loaded` and must deinit
    /// it). The index MUST be empty.
    /// M6 (P1 review): real errors, not Debug-only asserts — a double adopt
    /// in ReleaseFast would leak a mapping.
    pub fn adoptBase(
        self: *EdgeExistenceIndex,
        loaded: snapshot.Loaded,
    ) error{ BaseAlreadyAdopted, IndexNotEmpty }!void {
        if (self.base != null) return error.BaseAlreadyAdopted;
        if (self.primary.count() != 0 or self.overflow.count() != 0 or self.tombstones.count() != 0) {
            return error.IndexNotEmpty;
        }
        self.base = loaded;
    }

    /// Number of DISTINCT (from,rel,to) keys in the OVERLAY (primary +
    /// overflow). NOTE: intentionally overlay-only — no production caller
    /// needs a base-aware distinct-key count (the snapshot header uses
    /// `recordCount`), and computing one would scan the base.
    pub fn keyCount(self: *const EdgeExistenceIndex) usize {
        return self.primary.count() + self.overflow.count();
    }

    /// Total number of LIVE (key, edge_id) records — the snapshot item count.
    /// Equals the number of edges represented (each edge appears once):
    /// overlay records + base records − tombstones (tombstones only ever
    /// reference live base records, so the subtraction is exact).
    pub fn recordCount(self: *const EdgeExistenceIndex) usize {
        var n: usize = self.primary.count();
        var it = self.overflow.iterator();
        while (it.next()) |e| {
            n += e.value_ptr.items.len;
        }
        if (self.base) |b| {
            // M2 (P1 review): a failed cast must be a hard stop, not `orelse
            // 0` — subtracting tombstones from 0 would underflow usize. The
            // loader already rejects such files (FileTooLarge on 32-bit
            // targets), so this is unreachable in practice.
            const base_records = std.math.cast(usize, b.record_count) orelse
                @panic("edge-existence snapshot record_count exceeds usize");
            n += base_records - self.tombstones.count();
        }
        return n;
    }

    // ------------------------------------------------------------------
    // Base (mmap sorted snapshot) helpers.
    // ------------------------------------------------------------------

    /// First base index whose record is >= `key` (records sorted by
    /// (from, to, rel_type, edge_id)).
    fn baseLowerBound(self: *EdgeExistenceIndex, key: ExistRecord) !u64 {
        const b = if (self.base) |*ptr| ptr else return 0;
        var lo: u64 = 0;
        var hi: u64 = b.record_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = decodeRecord(try b.recordAt(mid));
            if (recordOrder(rec, key) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Exact-record membership probe against the base.
    fn baseHasRecord(self: *EdgeExistenceIndex, rec: ExistRecord) !bool {
        const b = if (self.base) |*ptr| ptr else return false;
        const i = try self.baseLowerBound(rec);
        if (i >= b.record_count) return false;
        return recordOrder(decodeRecord(try b.recordAt(i)), rec) == .eq;
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

        // GAP warm-reopen P1: the base is consulted FIRST so a record lives in
        // exactly one place. A tombstoned base record is resurrected in place
        // (tombstone dropped); a live base record makes the put an idempotent
        // no-op — identical semantics to the resident-mode re-put of the same
        // (key, edge_id).
        if (self.base != null) {
            const rec = ExistRecord{ .from = from, .to = to, .rel_type = rel_type, .edge_id = edge_id };
            if (self.tombstones.remove(rec)) return;
            if (try self.baseHasRecord(rec)) return;
        }

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
    /// entirely when its last id is gone. Erroring since P1: a base probe can
    /// surface lazy corruption detection (error.ChecksumMismatch).
    pub fn remove(self: *EdgeExistenceIndex, from: NodeId, rel_type: u32, to: NodeId, edge_id: EdgeId) !void {
        const key = keyOf(from, rel_type, to);

        // GAP warm-reopen P1: a base-resident record is deleted by tombstone
        // (the mmap base is immutable). Already-tombstoned = already dead.
        if (self.base != null) {
            const rec = ExistRecord{ .from = from, .to = to, .rel_type = rel_type, .edge_id = edge_id };
            if (self.tombstones.contains(rec)) return;
            if (try self.baseHasRecord(rec)) {
                try self.tombstones.put(self.allocator, rec, {});
                return;
            }
        }

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
    pub fn probe(self: *EdgeExistenceIndex, from: NodeId, rel_type: u32, to: NodeId, out: []EdgeId) ![]const EdgeId {
        const key = keyOf(from, rel_type, to);
        var n: usize = 0;
        var examined: usize = 0;

        if (self.primary.get(key)) |id| {
            examined += 1;
            if (out.len > n) {
                out[n] = id;
                n += 1;
            }
        } else if (self.overflow.getPtr(key)) |list| {
            const take = @min(list.items.len, out.len - n);
            examined += take;
            @memcpy(out[n..][0..take], list.items[0..take]);
            n += take;
        }

        // GAP warm-reopen P1: merge the base run for this key (contiguous in
        // the sorted records), skipping tombstoned ids. A live record is in
        // exactly ONE of overlay/base (put keeps the invariant), so no dedup
        // is needed. Cost stays O(candidates for THIS key) — independent of
        // the parent's out-degree, exactly as before.
        if (self.base) |*b| {
            var i = try self.baseLowerBound(.{ .from = from, .to = to, .rel_type = rel_type, .edge_id = 0 });
            while (i < b.record_count) : (i += 1) {
                const rec = decodeRecord(try b.recordAt(i));
                if (rec.from != from or rec.to != to or rec.rel_type != rel_type) break;
                examined += 1;
                if (self.tombstones.contains(rec)) continue;
                if (out.len > n) {
                    out[n] = rec.edge_id;
                    n += 1;
                }
            }
        }

        self.last_probe_entries_examined = examined;
        return out[0..n];
    }

    /// Preallocate for an expected number of distinct keys (rebuild/load hint).
    pub fn ensureTotalCapacity(self: *EdgeExistenceIndex, n: u32) !void {
        try self.primary.ensureTotalCapacity(self.allocator, n);
    }

    /// Visit every LIVE (key, edge_id) record exactly once (overlay, then
    /// base minus tombstones — a record is live in exactly one of the two, so
    /// no shadow check is needed). Used by the snapshot writer; iterating the
    /// base verifies every block (deferred full-payload integrity check).
    pub fn forEachRecord(
        self: *EdgeExistenceIndex,
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
        if (self.base) |*b| {
            // M4 (P1 review): sequential full-payload scan — lift the
            // load-time MADV_RANDOM for its duration (see EdgeIndexMap).
            b.adviseSequential();
            defer b.adviseRandom();
            var i: u64 = 0;
            while (i < b.record_count) : (i += 1) {
                const rec = decodeRecord(try b.recordAt(i));
                if (self.tombstones.contains(rec)) continue;
                try f(ctx, rec.from, rec.rel_type, rec.to, rec.edge_id);
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
    const got = try idx.probe(1, 7, 2, &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(EdgeId, 100), got[0]);
    try std.testing.expectEqual(@as(usize, 1), idx.last_probe_entries_examined);

    // Miss returns an empty slice and zero examined.
    try std.testing.expectEqual(@as(usize, 0), (try idx.probe(1, 7, 3, &buf)).len);
    try std.testing.expectEqual(@as(usize, 0), idx.last_probe_entries_examined);
}

test "put is idempotent for the same edge_id" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.put(1, 7, 2, 100);
    try idx.put(1, 7, 2, 100); // same id again
    var buf: [8]EdgeId = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try idx.probe(1, 7, 2, &buf)).len);
    try std.testing.expectEqual(@as(usize, 1), idx.recordCount());
}

test "parallel edges promote to overflow and probe returns all" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.put(1, 7, 2, 100);
    try idx.put(1, 7, 2, 200);
    var buf: [8]EdgeId = undefined;
    const got = try idx.probe(1, 7, 2, &buf);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(usize, 2), idx.recordCount());
    try std.testing.expectEqual(@as(usize, 1), idx.keyCount());
}

test "remove collapses overflow back to primary and clears empty keys" {
    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.put(1, 7, 2, 100);
    try idx.put(1, 7, 2, 200);
    try idx.remove(1, 7, 2, 100);
    var buf: [8]EdgeId = undefined;
    const got = try idx.probe(1, 7, 2, &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(EdgeId, 200), got[0]);
    // Now back on the primary fast path.
    try idx.remove(1, 7, 2, 200);
    try std.testing.expectEqual(@as(usize, 0), (try idx.probe(1, 7, 2, &buf)).len);
    try std.testing.expectEqual(@as(usize, 0), idx.recordCount());
}

// ---------------------------------------------------------------------------
// GAP warm-reopen P1: mmap-base mode tests.
// ---------------------------------------------------------------------------

const TEST_BASE_MAGIC = "GSTXIDX2"; // test-local; production magic in engine_index.zig

fn writeExistBase(tmp: *std.testing.TmpDir, name: []const u8, recs: []const ExistRecord) !std.Io.File {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try tmp.dir.createFile(io, name, .{ .read = true });
    const payload = try std.testing.allocator.alloc(u8, recs.len * RECORD_SIZE);
    defer std.testing.allocator.free(payload);
    for (recs, 0..) |r, i| {
        encodeRecord(payload[i * RECORD_SIZE ..][0..RECORD_SIZE], r);
    }
    snapshot.sortRecords(payload, RECORD_SIZE, recordLess);
    try snapshot.write(std.testing.allocator, file, TEST_BASE_MAGIC, 3, 0, RECORD_SIZE, payload);
    return file;
}

test "base mode: probe merges base run, put is idempotent vs base, remove tombstones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const recs = [_]ExistRecord{
        .{ .from = 1, .to = 2, .rel_type = 7, .edge_id = 100 },
        .{ .from = 1, .to = 2, .rel_type = 7, .edge_id = 200 }, // parallel edge
        .{ .from = 1, .to = 3, .rel_type = 7, .edge_id = 300 },
        .{ .from = 4, .to = 2, .rel_type = 9, .edge_id = 400 },
    };
    var file = try writeExistBase(&tmp, "exist.bin", &recs);
    defer file.close(io);

    var idx = EdgeExistenceIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.adoptBase((try snapshot.load(std.testing.allocator, &file, TEST_BASE_MAGIC, RECORD_SIZE)).?);
    try std.testing.expectEqual(@as(usize, 4), idx.recordCount());

    var buf: [8]EdgeId = undefined;
    // Parallel-edge tuple: complete candidate set from the base run.
    {
        const got = try idx.probe(1, 7, 2, &buf);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqual(@as(EdgeId, 100), got[0]);
        try std.testing.expectEqual(@as(EdgeId, 200), got[1]);
    }
    // Miss.
    try std.testing.expectEqual(@as(usize, 0), (try idx.probe(1, 8, 2, &buf)).len);

    // Idempotent re-put of a base-resident record: no duplicate.
    try idx.put(1, 7, 2, 100);
    try std.testing.expectEqual(@as(usize, 4), idx.recordCount());
    try std.testing.expectEqual(@as(usize, 2), (try idx.probe(1, 7, 2, &buf)).len);

    // New parallel edge on a base key goes to the overlay; probe merges both.
    try idx.put(1, 7, 2, 500);
    {
        const got = try idx.probe(1, 7, 2, &buf);
        try std.testing.expectEqual(@as(usize, 3), got.len);
        try std.testing.expectEqual(@as(usize, 5), idx.recordCount());
    }

    // Remove a base record → tombstone hides it; remove is idempotent.
    try idx.remove(1, 7, 2, 100);
    try idx.remove(1, 7, 2, 100);
    {
        const got = try idx.probe(1, 7, 2, &buf);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqual(@as(EdgeId, 500), got[0]); // overlay first
        try std.testing.expectEqual(@as(EdgeId, 200), got[1]);
        try std.testing.expectEqual(@as(usize, 4), idx.recordCount());
    }

    // Re-add after tombstone → resurrects the base record (tombstone drop).
    try idx.put(1, 7, 2, 100);
    try std.testing.expectEqual(@as(usize, 3), (try idx.probe(1, 7, 2, &buf)).len);
    try std.testing.expectEqual(@as(usize, 5), idx.recordCount());

    // Remove the overlay-resident id.
    try idx.remove(1, 7, 2, 500);
    {
        const got = try idx.probe(1, 7, 2, &buf);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqual(@as(usize, 4), idx.recordCount());
    }
}

test "base mode parity oracle: randomized put/remove/probe vs reference multimap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const a = std.testing.allocator;

    // Base: every (from in 0..8, to in 0..8, rel in {1,2}) with one edge, plus
    // parallels on rel 1 for from==to.
    var base_recs: std.ArrayList(ExistRecord) = .empty;
    defer base_recs.deinit(a);
    var f: u64 = 0;
    var next_id: u64 = 1;
    while (f < 8) : (f += 1) {
        var to: u64 = 0;
        while (to < 8) : (to += 1) {
            for ([_]u32{ 1, 2 }) |rel| {
                try base_recs.append(a, .{ .from = f, .to = to, .rel_type = rel, .edge_id = next_id });
                next_id += 1;
                if (f == to and rel == 1) {
                    try base_recs.append(a, .{ .from = f, .to = to, .rel_type = rel, .edge_id = next_id });
                    next_id += 1;
                }
            }
        }
    }
    var file = try writeExistBase(&tmp, "exist.bin", base_recs.items);
    defer file.close(io);

    var idx = EdgeExistenceIndex.init(a);
    defer idx.deinit();
    try idx.adoptBase((try snapshot.load(a, &file, TEST_BASE_MAGIC, RECORD_SIZE)).?);

    // Reference: hashmap of record -> void (the live record set).
    var ref = std.AutoHashMap(ExistRecord, void).init(a);
    defer ref.deinit();
    for (base_recs.items) |r| try ref.put(r, {});

    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();
    var op: usize = 0;
    while (op < 20_000) : (op += 1) {
        const rec = ExistRecord{
            .from = rnd.uintLessThan(u64, 8),
            .to = rnd.uintLessThan(u64, 8),
            .rel_type = 1 + rnd.uintLessThan(u32, 2),
            // Bounded id universe so a single key's candidate set always fits
            // the 64-slot probe buffer below (base contributes ≤ 2 more).
            .edge_id = 1 + rnd.uintLessThan(u64, 40),
        };
        switch (rnd.uintLessThan(u8, 3)) {
            0 => {
                try idx.put(rec.from, rec.rel_type, rec.to, rec.edge_id);
                try ref.put(rec, {});
            },
            1 => {
                try idx.remove(rec.from, rec.rel_type, rec.to, rec.edge_id);
                _ = ref.remove(rec);
            },
            else => {
                // Probe parity: same id SET for the key.
                var buf: [64]EdgeId = undefined;
                const got = try idx.probe(rec.from, rec.rel_type, rec.to, &buf);
                var want: usize = 0;
                var got_matched: usize = 0;
                var rit = ref.keyIterator();
                while (rit.next()) |k| {
                    if (k.from == rec.from and k.to == rec.to and k.rel_type == rec.rel_type) {
                        want += 1;
                        for (got) |id| {
                            if (id == k.edge_id) {
                                got_matched += 1;
                                break;
                            }
                        }
                    }
                }
                try std.testing.expectEqual(want, got.len);
                try std.testing.expectEqual(want, got_matched);
            },
        }
        if (op % 2048 == 0) try std.testing.expectEqual(@as(usize, ref.count()), idx.recordCount());
    }
    try std.testing.expectEqual(@as(usize, ref.count()), idx.recordCount());

    // Full-set parity via forEachRecord (exactly-once, exact membership).
    const Ctx = struct { ref: *std.AutoHashMap(ExistRecord, void), seen: *std.AutoHashMap(ExistRecord, void) };
    var seen = std.AutoHashMap(ExistRecord, void).init(a);
    defer seen.deinit();
    var ctx = Ctx{ .ref = &ref, .seen = &seen };
    try idx.forEachRecord(&ctx, struct {
        fn cb(c: *Ctx, from: NodeId, rel_type: u32, to: NodeId, edge_id: EdgeId) anyerror!void {
            const r = ExistRecord{ .from = from, .to = to, .rel_type = rel_type, .edge_id = edge_id };
            try std.testing.expect(c.ref.contains(r));
            try std.testing.expect(!c.seen.contains(r)); // exactly-once
            try c.seen.put(r, {});
        }
    }.cb);
    try std.testing.expectEqual(ref.count(), seen.count());
}

test {
    std.testing.refAllDecls(@This());
}
