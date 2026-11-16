// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! PHASE G (reverse map) — a persisted `prop_head -> node_id` index so a
//! crash-reopen exact-index reconcile (geode's prop_exact.idx) can resolve the
//! WAL tail's PROPS-page slots to their OWNING nodes without an O(graph) scan.
//!
//! WHY. A node's property blob lives in a SLAB props page shared by many nodes;
//! the blob stores no owner back-reference, and an IN-PLACE value change (or a
//! bulk-ingest checkpoint-boundary fill page) touches a props page whose owning
//! node is NOT on any tail nodes page. Without this map those slots are
//! unresolvable and force a full rebuild. This map inverts `node.prop_head` so a
//! tail props-slot's `prop_head` resolves to its node.
//!
//! MAINTENANCE (no write amplification — no extra disk writes). The map is a
//! DERIVED index: built by the hydration node scan, kept current in-memory on
//! the record-write path (`putNode`/`deleteNode`, where the node id is known),
//! persisted with the other derived-index snapshots (epoch + covered_lsn
//! stamped, CRC'd), and reconciled from the bounded nodes-page tail after a
//! crash (a value change does NOT move `prop_head`, so only inserts/deletes/
//! relocations touch the map — exactly the nodes-page tail set).
//!
//! NODE prop chains map to their node. SONNY-6558: EDGE prop chains are
//! recorded too, tagged (`EDGE_TAG`), so the tail resolution can tell a slab
//! slot that belongs to an edge (no node owns it: skip) from one it cannot
//! attribute (rebuild). `get` returns node owners only. A `prop_head == 0`
//! (no chain) is never recorded.

const std = @import("std");
const types = @import("types.zig");
const index_snapshot = @import("index_snapshot.zig");

const Allocator = std.mem.Allocator;
const NodeId = types.NodeId;

/// Magic (exactly 8 bytes) for the reverse-map snapshot. Distinct from every
/// other derived-index magic so a foreign/old file is cleanly rejected.
/// SONNY-6558: version 2 adds tagged edge-chain entries; a binary that only
/// knows version 1 rejects the file and rebuilds from a scan instead of
/// reading an edge entry as a node id. Version 1 files are still read.
pub const SNAPSHOT_MAGIC = "GSRVIX2\x00";
pub const SNAPSHOT_MAGIC_V1 = "GSRVIX1\x00";

/// SONNY-6558: set on the stored value of an edge-chain entry (value =
/// `EDGE_TAG | edge_id`). Node and edge ids stay far below 2^63.
pub const EDGE_TAG: u64 = @as(u64, 1) << 63;

/// Who owns a recorded chain.
pub const Owner = union(enum) { node: NodeId, edge: u64 };

/// On-disk file name under the graph directory (by-path, like the ordered
/// index — no FileId / buffer-pool registration; the snapshot is written
/// directly and is fully rebuildable from the node store).
pub const SNAPSHOT_FILE_NAME = "prop_rev.idx";

/// Smallest bytes a single record consumes on disk: prop_head(u64) + node_id(u64).
const RECORD_SIZE: usize = 16;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const owner_only_file_mode = 0o600;

pub const PropRevIndex = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged(u64, NodeId) = .empty,

    pub fn init(allocator: Allocator) PropRevIndex {
        return .{ .allocator = allocator, .map = .empty };
    }

    pub fn deinit(self: *PropRevIndex) void {
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *PropRevIndex) void {
        self.map.clearRetainingCapacity();
    }

    pub fn count(self: *const PropRevIndex) usize {
        return self.map.count();
    }

    /// Record `prop_head -> node_id`. A `prop_head == 0` (node with no property
    /// chain) is never recorded. Overwrites any existing mapping for the head —
    /// on slab-slot reuse this replaces a stale (relocated) owner with the
    /// current one, which is exactly the rebuild result.
    pub fn put(self: *PropRevIndex, prop_head: u64, node_id: NodeId) !void {
        if (prop_head == 0) return;
        try self.map.put(self.allocator, prop_head, node_id);
    }

    /// Drop the mapping for `prop_head` (node deleted / relocated away). No-op
    /// when absent or `prop_head == 0`.
    pub fn remove(self: *PropRevIndex, prop_head: u64) void {
        if (prop_head == 0) return;
        _ = self.map.remove(prop_head);
    }

    /// The node that currently owns `prop_head`, or null when unknown or
    /// owned by an edge.
    pub fn get(self: *const PropRevIndex, prop_head: u64) ?NodeId {
        const v = self.map.get(prop_head) orelse return null;
        if (v & EDGE_TAG != 0) return null;
        return v;
    }

    /// SONNY-6558: the recorded owner of `prop_head`, node or edge.
    pub fn owner(self: *const PropRevIndex, prop_head: u64) ?Owner {
        const v = self.map.get(prop_head) orelse return null;
        if (v & EDGE_TAG != 0) return .{ .edge = v & ~EDGE_TAG };
        return .{ .node = v };
    }

    /// SONNY-6558: record edge `edge_id`'s property chain `prop_head`.
    /// Overwrites any mapping for the head (slab-slot reuse).
    pub fn putEdge(self: *PropRevIndex, prop_head: u64, edge_id: u64) !void {
        if (prop_head == 0) return;
        try self.map.put(self.allocator, prop_head, edge_id | EDGE_TAG);
    }

    /// SONNY-6558: drop `prop_head` when it is recorded as edge `edge_id`'s
    /// chain (the edge was removed or its chain moved). A head another owner
    /// has taken since is left alone.
    pub fn removeEdge(self: *PropRevIndex, prop_head: u64, edge_id: u64) void {
        if (prop_head == 0) return;
        const v = self.map.get(prop_head) orelse return;
        if (v == (edge_id | EDGE_TAG)) _ = self.map.remove(prop_head);
    }

    fn snapshotPath(allocator: Allocator, dir_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, SNAPSHOT_FILE_NAME });
    }

    /// Persist the map to `<dir_path>/prop_rev.idx`, stamped with the derived
    /// `(checkpoint_epoch, covered_lsn)` (same contract as the other derived
    /// snapshots). A no-op map leaves a valid empty snapshot so a clean restart
    /// still loads cleanly.
    pub fn saveToFile(self: *PropRevIndex, dir_path: []const u8, checkpoint_epoch: u64, covered_lsn: u64) !void {
        const path = try snapshotPath(self.allocator, dir_path);
        defer self.allocator.free(path);

        var w = index_snapshot.SnapshotWriter.init(self.allocator);
        defer w.deinit();

        try w.writeHeader(SNAPSHOT_MAGIC, checkpoint_epoch, covered_lsn, self.map.count());
        var it = self.map.iterator();
        while (it.next()) |e| {
            try w.writeU64(e.key_ptr.*); // prop_head
            try w.writeU64(e.value_ptr.*); // node_id, or EDGE_TAG | edge_id
        }

        const file = try std.Io.Dir.cwd().createFile(io(), path, .{
            .read = true,
            .truncate = true,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });
        defer file.close(io());
        try w.finalize(file);
    }

    /// Load `<dir_path>/prop_rev.idx`, replacing the in-memory map. Returns the
    /// embedded `(epoch, covered_lsn)` stamp, or null when the file is absent /
    /// empty (fresh graph / never checkpointed) so the caller rebuilds.
    pub fn loadFromFile(self: *PropRevIndex, dir_path: []const u8) !?index_snapshot.Stamp {
        const path = try snapshotPath(self.allocator, dir_path);
        defer self.allocator.free(path);

        var loaded = (loadWithMagic(self.allocator, path, SNAPSHOT_MAGIC) catch |err| switch (err) {
            // Not version 2: a version 1 file (node entries only) is read as is.
            error.InvalidFormat => try loadWithMagic(self.allocator, path, SNAPSHOT_MAGIC_V1),
            else => return err,
        }) orelse return null;
        defer loaded.deinit();

        self.map.clearRetainingCapacity();
        errdefer self.map.clearRetainingCapacity();

        try self.map.ensureTotalCapacity(self.allocator, @intCast(loaded.item_count));
        var r = index_snapshot.SnapshotReader.init(loaded.payload());
        var i: u64 = 0;
        while (i < loaded.item_count) : (i += 1) {
            const prop_head = try r.readU64();
            const node_id = try r.readU64();
            self.map.putAssumeCapacity(prop_head, node_id);
        }
        if (r.remaining() != 0) return error.InvalidFormat;
        return .{ .epoch = loaded.checkpoint_epoch, .covered_lsn = loaded.covered_lsn };
    }

    fn loadWithMagic(allocator: Allocator, path: []const u8, magic: []const u8) !?index_snapshot.LoadedSnapshot {
        var file = std.Io.Dir.cwd().openFile(io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io());
        return index_snapshot.loadPayload(allocator, &file, magic, RECORD_SIZE);
    }

    /// Cheap header-only re-stamp of a CLEAN (unchanged) snapshot to the new
    /// `(epoch, covered_lsn)` — mirrors the other derived indexes so a partial
    /// checkpoint does not epoch-invalidate the untouched map. Returns false
    /// (untouched) for a missing / foreign / empty file.
    pub fn restampFile(self: *PropRevIndex, dir_path: []const u8, new_epoch: u64, new_covered_lsn: u64) !bool {
        const path = try snapshotPath(self.allocator, dir_path);
        defer self.allocator.free(path);
        var file = std.Io.Dir.cwd().openFile(io(), path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(io());
        if (try index_snapshot.restampStamps(&file, SNAPSHOT_MAGIC, new_epoch, new_covered_lsn)) return true;
        return index_snapshot.restampStamps(&file, SNAPSHOT_MAGIC_V1, new_epoch, new_covered_lsn);
    }
};

test "PropRevIndex put/get/remove" {
    const testing = std.testing;
    var idx = PropRevIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.put(100, 7);
    try idx.put(200, 9);
    try idx.put(0, 5); // prop_head 0 is never recorded
    try testing.expectEqual(@as(?NodeId, 7), idx.get(100));
    try testing.expectEqual(@as(?NodeId, 9), idx.get(200));
    try testing.expectEqual(@as(?NodeId, null), idx.get(0));
    try testing.expectEqual(@as(usize, 2), idx.count());

    // Overwrite (slab-slot reuse / relocation-into-head) replaces the owner.
    try idx.put(100, 42);
    try testing.expectEqual(@as(?NodeId, 42), idx.get(100));

    idx.remove(200);
    try testing.expectEqual(@as(?NodeId, null), idx.get(200));
    try testing.expectEqual(@as(usize, 1), idx.count());
}

test "SONNY-6558: PropRevIndex edge entries are tagged, round-trip, and never read as nodes" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var idx = PropRevIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.put(0x8000_0000_0000_0001, 3);
    try idx.putEdge(0x8000_0000_0000_0002, 77);
    try testing.expectEqual(@as(?NodeId, null), idx.get(0x8000_0000_0000_0002));
    try testing.expectEqual(Owner{ .edge = 77 }, idx.owner(0x8000_0000_0000_0002).?);
    try testing.expectEqual(Owner{ .node = 3 }, idx.owner(0x8000_0000_0000_0001).?);

    // removeEdge only drops the head while that edge still owns it.
    idx.removeEdge(0x8000_0000_0000_0001, 3);
    try testing.expectEqual(@as(?NodeId, 3), idx.get(0x8000_0000_0000_0001));
    idx.removeEdge(0x8000_0000_0000_0002, 78);
    try testing.expect(idx.owner(0x8000_0000_0000_0002) != null);

    try idx.saveToFile(dir_path, 4, 40);
    var loaded = PropRevIndex.init(testing.allocator);
    defer loaded.deinit();
    _ = (try loaded.loadFromFile(dir_path)).?;
    try testing.expectEqual(Owner{ .edge = 77 }, loaded.owner(0x8000_0000_0000_0002).?);
    try testing.expectEqual(@as(?NodeId, 3), loaded.get(0x8000_0000_0000_0001));
    loaded.removeEdge(0x8000_0000_0000_0002, 77);
    try testing.expectEqual(@as(?Owner, null), loaded.owner(0x8000_0000_0000_0002));
}

test "SONNY-6558: PropRevIndex still reads and restamps a version 1 snapshot" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    // A file written by graph_storage <= 0.4.21.
    {
        var w = index_snapshot.SnapshotWriter.init(testing.allocator);
        defer w.deinit();
        try w.writeHeader(SNAPSHOT_MAGIC_V1, 5, 50, 1);
        try w.writeU64(0x8000_0000_0000_0009);
        try w.writeU64(12);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, SNAPSHOT_FILE_NAME });
        defer testing.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(io(), path, .{ .read = true, .truncate = true });
        defer file.close(io());
        try w.finalize(file);
    }
    var idx = PropRevIndex.init(testing.allocator);
    defer idx.deinit();
    const stamp = (try idx.loadFromFile(dir_path)).?;
    try testing.expectEqual(@as(u64, 50), stamp.covered_lsn);
    try testing.expectEqual(@as(?NodeId, 12), idx.get(0x8000_0000_0000_0009));
    try testing.expect(try idx.restampFile(dir_path, 6, 60));
    const again = (try idx.loadFromFile(dir_path)).?;
    try testing.expectEqual(@as(u64, 60), again.covered_lsn);
}

test "PropRevIndex save/load round-trip preserves entries and (epoch, covered_lsn) stamp" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var idx = PropRevIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.put(0x8000_0000_0000_0001, 3);
    try idx.put(0x8000_0000_0000_0002, 5);
    try idx.put(0x8000_0000_0000_0003, 8);
    try idx.saveToFile(dir_path, 42, 0xDEAD_BEEF);

    var loaded = PropRevIndex.init(testing.allocator);
    defer loaded.deinit();
    const stamp = (try loaded.loadFromFile(dir_path)).?;
    try testing.expectEqual(@as(u64, 42), stamp.epoch);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), stamp.covered_lsn);
    try testing.expectEqual(@as(usize, 3), loaded.count());
    try testing.expectEqual(@as(?NodeId, 3), loaded.get(0x8000_0000_0000_0001));
    try testing.expectEqual(@as(?NodeId, 5), loaded.get(0x8000_0000_0000_0002));
    try testing.expectEqual(@as(?NodeId, 8), loaded.get(0x8000_0000_0000_0003));
}

test "PropRevIndex loadFromFile returns null when the snapshot is absent" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var idx = PropRevIndex.init(testing.allocator);
    defer idx.deinit();
    try testing.expectEqual(@as(?index_snapshot.Stamp, null), try idx.loadFromFile(dir_path));
}

test "PropRevIndex restampFile advances the stamp without touching entries" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var idx = PropRevIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.put(0x8000_0000_0000_0010, 11);
    try idx.saveToFile(dir_path, 1, 100);

    try testing.expect(try idx.restampFile(dir_path, 2, 200));

    var loaded = PropRevIndex.init(testing.allocator);
    defer loaded.deinit();
    const stamp = (try loaded.loadFromFile(dir_path)).?;
    try testing.expectEqual(@as(u64, 2), stamp.epoch);
    try testing.expectEqual(@as(u64, 200), stamp.covered_lsn);
    try testing.expectEqual(@as(?NodeId, 11), loaded.get(0x8000_0000_0000_0010));
}
