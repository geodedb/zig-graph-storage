// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! GAP warm-reopen P1: the engine's edge_id -> EdgeIndexEntry map, with an
//! optional immutable MMAP BASE (sorted_index_snapshot) under an in-memory
//! OVERLAY — the geode IdMap `adoptSnapshotAsBase` concept replicated for gs.
//!
//! Resident mode (no base): the overlay hashmap holds everything — byte-for-
//! byte the legacy `std.AutoHashMap(EdgeId, EdgeIndexEntry)` behavior (fresh
//! create, rebuild-from-adjacency, counter-stale reopen).
//!
//! mmap-backed mode (after `adoptBase`): the sorted snapshot serves lookups
//! IN PLACE via binary search (zero-deserialization page-in); the overlay
//! holds only post-open mutations and `tombstones` hides base records that
//! were removed. Merged view = overlay ⊕ base ⊖ tombstones, overlay first.
//!
//! Threading contract: UNCHANGED from the hashmap it replaces — external
//! serialization required for mutation; concurrent pure readers are safe
//! (base block verification uses atomics; see sorted_index_snapshot.zig).
//!
//! UNMAP ORDERING (GAP-ENT-0018 UAF class): `clearAndFree`/`deinit` unmap the
//! base. They are only called where no concurrent reader can exist: under the
//! engine's derived-hydration latch (rebuild / failed-load paths) and at
//! engine teardown. Never unmap under a live reader.

const std = @import("std");

const types = @import("types.zig");
const snapshot = @import("sorted_index_snapshot.zig");

const Allocator = std.mem.Allocator;
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;

/// In-memory edge-index value. (Moved here from engine.zig, which re-exports
/// it, so this file does not import engine.zig.)
pub const EdgeIndexEntry = struct {
    from: NodeId,
    neighbor: NodeId,
    rel_type: u32,
    prop_head: u32,
    /// GAP-ENT-0024 P3: inline 64-bit public edge id, mirrored from the
    /// durable adjacency record (edge.zig EdgeEntry.public_id). 0 = unknown/
    /// absent (legacy edges / v1 blocks) — callers fall back to the legacy
    /// `__geode_internal_edge_id` property read. Deliberately NO default
    /// value: every insert site must state the id it carries, so a new
    /// insert site cannot silently drop ids.
    public_id: u64,
};

/// On-disk record: edge_id u64 | from u64 | neighbor u64 | rel_type u32 |
/// prop_head u32 | public_id u64 — same field order as the GSEIDX3 records,
/// but SORTED by edge_id under the GSEIDX4 magic.
pub const RECORD_SIZE: u32 = 40;

pub fn encodeRecord(buf: []u8, edge_id: EdgeId, e: EdgeIndexEntry) void {
    std.debug.assert(buf.len == RECORD_SIZE);
    std.mem.writeInt(u64, buf[0..8], edge_id, .little);
    std.mem.writeInt(u64, buf[8..16], e.from, .little);
    std.mem.writeInt(u64, buf[16..24], e.neighbor, .little);
    std.mem.writeInt(u32, buf[24..28], e.rel_type, .little);
    std.mem.writeInt(u32, buf[28..32], e.prop_head, .little);
    std.mem.writeInt(u64, buf[32..40], e.public_id, .little);
}

fn decodeEntry(rec: []const u8) EdgeIndexEntry {
    return .{
        .from = std.mem.readInt(u64, rec[8..16], .little),
        .neighbor = std.mem.readInt(u64, rec[16..24], .little),
        .rel_type = std.mem.readInt(u32, rec[24..28], .little),
        .prop_head = std.mem.readInt(u32, rec[28..32], .little),
        .public_id = std.mem.readInt(u64, rec[32..40], .little),
    };
}

fn recordEdgeId(rec: []const u8) EdgeId {
    return std.mem.readInt(u64, rec[0..8], .little);
}

pub fn recordLess(a: []const u8, b: []const u8) bool {
    return recordEdgeId(a) < recordEdgeId(b);
}

pub const EdgeIndexMap = struct {
    allocator: Allocator,
    /// Post-open mutations (and everything, in resident mode). An entry here
    /// SHADOWS any base record with the same edge_id.
    overlay: std.AutoHashMap(EdgeId, EdgeIndexEntry),
    /// Deleted base-resident edge ids (hides the base record). An id may be
    /// in BOTH tombstones and overlay (deleted then re-added): overlay wins.
    tombstones: std.AutoHashMap(EdgeId, void),
    /// Immutable mmap'd sorted snapshot; null in resident mode.
    base: ?snapshot.Loaded,
    /// Live entries in the merged view — kept exact so `count()` stays O(1).
    live_count: usize,

    pub fn init(allocator: Allocator) EdgeIndexMap {
        return .{
            .allocator = allocator,
            .overlay = std.AutoHashMap(EdgeId, EdgeIndexEntry).init(allocator),
            .tombstones = std.AutoHashMap(EdgeId, void).init(allocator),
            .base = null,
            .live_count = 0,
        };
    }

    pub fn deinit(self: *EdgeIndexMap) void {
        self.overlay.deinit();
        self.tombstones.deinit();
        if (self.base) |*b| b.deinit();
        self.base = null;
    }

    /// Adopt a loaded sorted snapshot as the immutable base (takes ownership;
    /// deinit/clearAndFree unmaps it). The map MUST be empty — this is the
    /// counter-gated load path's O(1) replacement for the record-by-record
    /// hashmap build.
    pub fn adoptBase(self: *EdgeIndexMap, loaded: snapshot.Loaded) void {
        std.debug.assert(self.overlay.count() == 0);
        std.debug.assert(self.tombstones.count() == 0);
        std.debug.assert(self.base == null);
        self.base = loaded;
        self.live_count = std.math.cast(usize, loaded.record_count) orelse
            @panic("edge index snapshot record_count exceeds usize");
    }

    /// Drop everything, INCLUDING the mmap base. Only call with no live
    /// readers (hydration latch / teardown — see file-header note).
    pub fn clearAndFree(self: *EdgeIndexMap) void {
        self.overlay.clearAndFree();
        self.tombstones.clearAndFree();
        if (self.base) |*b| b.deinit();
        self.base = null;
        self.live_count = 0;
    }

    pub fn ensureTotalCapacity(self: *EdgeIndexMap, n: u32) !void {
        try self.overlay.ensureTotalCapacity(n);
    }

    /// Live entry count of the merged view. O(1).
    pub fn count(self: *const EdgeIndexMap) usize {
        return self.live_count;
    }

    /// Binary search the base for `edge_id`. error.ChecksumMismatch = lazily
    /// detected media corruption of the touched block (see failure model).
    fn baseGet(self: *EdgeIndexMap, edge_id: EdgeId) !?EdgeIndexEntry {
        if (self.base) |*b| {
            var lo: u64 = 0;
            var hi: u64 = b.record_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = try b.recordAt(mid);
                const rid = recordEdgeId(rec);
                if (rid == edge_id) return decodeEntry(rec);
                if (rid < edge_id) lo = mid + 1 else hi = mid;
            }
        }
        return null;
    }

    /// Merged lookup: overlay ⊕ base ⊖ tombstones.
    pub fn get(self: *EdgeIndexMap, edge_id: EdgeId) !?EdgeIndexEntry {
        if (self.overlay.get(edge_id)) |e| return e;
        if (self.tombstones.contains(edge_id)) return null;
        return self.baseGet(edge_id);
    }

    pub fn contains(self: *EdgeIndexMap, edge_id: EdgeId) !bool {
        return (try self.get(edge_id)) != null;
    }

    /// Insert or update. Base records are never modified — an update shadows
    /// via the overlay; a delete-then-re-add leaves the tombstone in place
    /// (overlay wins) so the base record stays dead if the overlay entry is
    /// removed again later.
    pub fn put(self: *EdgeIndexMap, edge_id: EdgeId, entry: EdgeIndexEntry) !void {
        const was_live = try self.contains(edge_id);
        try self.overlay.put(edge_id, entry);
        if (!was_live) self.live_count += 1;
    }

    /// Remove (idempotent). Overlay entry is dropped AND a base record with
    /// the same id is tombstoned, so neither view resurrects the edge.
    pub fn remove(self: *EdgeIndexMap, edge_id: EdgeId) !void {
        const in_overlay = self.overlay.remove(edge_id);
        var was_live = in_overlay;
        if (!self.tombstones.contains(edge_id) and (try self.baseGet(edge_id)) != null) {
            try self.tombstones.put(edge_id, {});
            was_live = true;
        }
        if (was_live) {
            std.debug.assert(self.live_count > 0);
            self.live_count -= 1;
        }
    }

    /// In-place prop_head refresh (the old `getPtr(id).?.prop_head = x` site).
    /// No-op when the edge is absent. A base-resident entry is copied into the
    /// overlay with the new head (copy-on-write) — the base is immutable.
    pub fn updatePropHead(self: *EdgeIndexMap, edge_id: EdgeId, new_head: u32) !void {
        if (self.overlay.getPtr(edge_id)) |p| {
            p.prop_head = new_head;
            return;
        }
        if (self.tombstones.contains(edge_id)) return;
        if (try self.baseGet(edge_id)) |e| {
            var copy = e;
            copy.prop_head = new_head;
            // Shadowing an existing live base record: live_count unchanged.
            try self.overlay.put(edge_id, copy);
        }
    }

    /// Visit every LIVE entry exactly once (overlay first, then base records
    /// not shadowed/tombstoned). Used by the checkpoint saver to serialize the
    /// merged view; iterating the base verifies every block (this doubles as
    /// the deferred full-payload integrity check).
    pub fn forEachLive(
        self: *EdgeIndexMap,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), EdgeId, EdgeIndexEntry) anyerror!void,
    ) !void {
        var it = self.overlay.iterator();
        while (it.next()) |e| {
            try f(ctx, e.key_ptr.*, e.value_ptr.*);
        }
        if (self.base) |*b| {
            var i: u64 = 0;
            while (i < b.record_count) : (i += 1) {
                const rec = try b.recordAt(i);
                const id = recordEdgeId(rec);
                if (self.overlay.contains(id) or self.tombstones.contains(id)) continue;
                try f(ctx, id, decodeEntry(rec));
            }
        }
    }
};

// ============================================================================
// Unit tests (pure data structure; engine lifecycle tests live in
// tests/mmap_index_snapshot.zig).
// ============================================================================

const t = std.testing;

const TEST_MAGIC = "GSTEIDX4"; // test-local; production magic lives in engine_index.zig

fn testEntry(seed: u64) EdgeIndexEntry {
    return .{
        .from = seed * 3 + 1,
        .neighbor = seed * 5 + 2,
        .rel_type = @intCast(seed % 97),
        .prop_head = @intCast(seed % 1013),
        .public_id = seed ^ 0xABCD_EF01,
    };
}

fn writeBaseSnapshot(tmp: *std.testing.TmpDir, name: []const u8, ids: []const u64) !std.Io.File {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try tmp.dir.createFile(io, name, .{ .read = true });
    const payload = try t.allocator.alloc(u8, ids.len * RECORD_SIZE);
    defer t.allocator.free(payload);
    for (ids, 0..) |id, i| {
        encodeRecord(payload[i * RECORD_SIZE ..][0..RECORD_SIZE], id, testEntry(id));
    }
    snapshot.sortRecords(payload, RECORD_SIZE, recordLess);
    try snapshot.write(t.allocator, file, TEST_MAGIC, 7, RECORD_SIZE, payload);
    return file;
}

test "resident mode matches plain hashmap semantics (put/get/remove/count)" {
    var m = EdgeIndexMap.init(t.allocator);
    defer m.deinit();

    try m.put(10, testEntry(10));
    try m.put(20, testEntry(20));
    try m.put(10, testEntry(11)); // update, not a new entry
    try t.expectEqual(@as(usize, 2), m.count());
    try t.expectEqual(testEntry(11), (try m.get(10)).?);
    try m.remove(10);
    try m.remove(10); // idempotent
    try t.expectEqual(@as(usize, 1), m.count());
    try t.expectEqual(@as(?EdgeIndexEntry, null), try m.get(10));
    try t.expect(try m.contains(20));
}

test "mmap base: lookups served from the mapped file; overlay/tombstones shadow it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const ids = [_]u64{ 5, 1, 9, 3, 7 }; // written sorted by the helper
    var file = try writeBaseSnapshot(&tmp, "base.bin", &ids);
    defer file.close(io);

    var m = EdgeIndexMap.init(t.allocator);
    defer m.deinit();
    m.adoptBase((try snapshot.load(t.allocator, &file, TEST_MAGIC, RECORD_SIZE)).?);

    try t.expectEqual(@as(usize, 5), m.count());
    for (ids) |id| {
        try t.expectEqual(testEntry(id), (try m.get(id)).?);
    }
    try t.expectEqual(@as(?EdgeIndexEntry, null), try m.get(4));

    // Update a base record → overlay shadows, count unchanged.
    try m.put(3, testEntry(300));
    try t.expectEqual(testEntry(300), (try m.get(3)).?);
    try t.expectEqual(@as(usize, 5), m.count());

    // Delete a base record → tombstone hides it.
    try m.remove(9);
    try t.expectEqual(@as(?EdgeIndexEntry, null), try m.get(9));
    try t.expectEqual(@as(usize, 4), m.count());

    // Re-add after delete → live again (overlay wins over tombstone).
    try m.put(9, testEntry(900));
    try t.expectEqual(testEntry(900), (try m.get(9)).?);
    try t.expectEqual(@as(usize, 5), m.count());
    // ...and deleting the re-add kills it again (tombstone still guards base).
    try m.remove(9);
    try t.expectEqual(@as(?EdgeIndexEntry, null), try m.get(9));
    try t.expectEqual(@as(usize, 4), m.count());

    // updatePropHead copy-on-write for a base record.
    try m.updatePropHead(7, 4242);
    try t.expectEqual(@as(u32, 4242), (try m.get(7)).?.prop_head);
    try t.expectEqual(@as(usize, 4), m.count());
    // ...and for an absent id it is a no-op.
    try m.updatePropHead(4, 1);
    try t.expectEqual(@as(?EdgeIndexEntry, null), try m.get(4));
}

test "forEachLive yields exactly the merged view" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const ids = [_]u64{ 2, 4, 6, 8 };
    var file = try writeBaseSnapshot(&tmp, "base.bin", &ids);
    defer file.close(io);

    var m = EdgeIndexMap.init(t.allocator);
    defer m.deinit();
    m.adoptBase((try snapshot.load(t.allocator, &file, TEST_MAGIC, RECORD_SIZE)).?);

    try m.remove(4); // tombstoned base record
    try m.put(6, testEntry(600)); // shadowed base record
    try m.put(10, testEntry(10)); // overlay-only record

    var seen = std.AutoHashMap(u64, EdgeIndexEntry).init(t.allocator);
    defer seen.deinit();
    const Ctx = struct { seen: *std.AutoHashMap(u64, EdgeIndexEntry) };
    var ctx = Ctx{ .seen = &seen };
    try m.forEachLive(&ctx, struct {
        fn f(c: *Ctx, id: EdgeId, e: EdgeIndexEntry) anyerror!void {
            try t.expect(!c.seen.contains(id)); // exactly-once
            try c.seen.put(id, e);
        }
    }.f);

    try t.expectEqual(@as(usize, 4), seen.count());
    try t.expectEqual(testEntry(2), seen.get(2).?);
    try t.expectEqual(@as(?EdgeIndexEntry, null), seen.get(4));
    try t.expectEqual(testEntry(600), seen.get(6).?);
    try t.expectEqual(testEntry(8), seen.get(8).?);
    try t.expectEqual(testEntry(10), seen.get(10).?);
    try t.expectEqual(m.count(), seen.count());
}

test "parity oracle: randomized workload vs reference hashmap (incl. deletes/tombstones)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Base = even ids 0..2000 (1001 records, forces multi-step binary search).
    var base_ids: [1001]u64 = undefined;
    for (&base_ids, 0..) |*p, i| p.* = @as(u64, i) * 2;
    var file = try writeBaseSnapshot(&tmp, "base.bin", &base_ids);
    defer file.close(io);

    var m = EdgeIndexMap.init(t.allocator);
    defer m.deinit();
    m.adoptBase((try snapshot.load(t.allocator, &file, TEST_MAGIC, RECORD_SIZE)).?);

    var ref = std.AutoHashMap(u64, EdgeIndexEntry).init(t.allocator);
    defer ref.deinit();
    for (base_ids) |id| try ref.put(id, testEntry(id));

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var op: usize = 0;
    while (op < 20_000) : (op += 1) {
        const id = rnd.uintLessThan(u64, 2100); // hits base, overlay and misses
        switch (rnd.uintLessThan(u8, 4)) {
            0 => { // put
                const e = testEntry(id +% @as(u64, op));
                try m.put(id, e);
                try ref.put(id, e);
            },
            1 => { // remove
                try m.remove(id);
                _ = ref.remove(id);
            },
            2 => { // updatePropHead
                const nh: u32 = rnd.int(u32);
                try m.updatePropHead(id, nh);
                if (ref.getPtr(id)) |p| p.prop_head = nh;
            },
            else => { // point lookup parity
                try t.expectEqual(ref.get(id), try m.get(id));
            },
        }
        if (op % 1024 == 0) try t.expectEqual(@as(usize, ref.count()), m.count());
    }

    // Full-view parity at the end.
    try t.expectEqual(@as(usize, ref.count()), m.count());
    var checked: usize = 0;
    const Ctx = struct { ref: *std.AutoHashMap(u64, EdgeIndexEntry), n: *usize };
    var n: usize = 0;
    var ctx = Ctx{ .ref = &ref, .n = &n };
    try m.forEachLive(&ctx, struct {
        fn f(c: *Ctx, id: EdgeId, e: EdgeIndexEntry) anyerror!void {
            try t.expectEqual(c.ref.get(id).?, e);
            c.n.* += 1;
        }
    }.f);
    checked = n;
    try t.expectEqual(@as(usize, ref.count()), checked);
}
