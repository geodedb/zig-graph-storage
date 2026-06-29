// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # Per-(label,key) ordered property index (H3-P1 Task 2)
//!
//! Owns one byte-key `OrderedBTree` per REGISTERED `(label_id, property_key)`
//! pair. `insert` runs the H3-P0 `encodeOrdered` encoder, so a tree's natural
//! byte order IS the engine's ORDER BY order — an ASC cursor walks values
//! ascending and a DESC cursor walks them descending, with no per-key
//! comparator (P2 will k-way-merge these cursors across shards).
//!
//! ## Registration gates everything
//!
//! Only REGISTERED pairs are maintained. `insert`/`remove` are no-ops for an
//! unregistered `(label,key)`, and `openCursor` returns null. This keeps the
//! common "no ordered index declared" case zero-cost on the engine's mutation
//! hot paths. Values that `orderable()` rejects (decimal, ext, NaN float) are
//! silently skipped (the planner falls back to the heap for those columns).
//!
//! ## Crash-safe persistence (Lever B discipline)
//!
//! `saveToFile` stamps the snapshot with the engine's `manifest.counter`;
//! `loadFromFile` returns that counter so the engine can gate load-vs-rebuild:
//! load only when `snapshot.counter == manifest.counter` (clean restart), else
//! REBUILD from a live scan (crash restart). The snapshot also records the
//! REGISTERED pair set, so even on a counter mismatch the engine knows which
//! `(label,key)` trees to rebuild — registration is durable from the last full
//! checkpoint, the trees are not trusted across a crash.
//!
//! On-disk framing (one file `ordered_propidx.snap` under the graph dir) reuses
//! `index_snapshot` (magic | counter | item_count | payload | CRC32):
//!   item_count = number of registered indexes
//!   per index: [u32 label_id][u32 key_len][key bytes][u64 blob_len][tree blob]
//! where the tree blob is `OrderedBTree.serialize` output.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const ordered_encoding = @import("ordered_encoding.zig");
const ordered_btree = @import("ordered_btree.zig");
const index_snapshot = @import("index_snapshot.zig");

const LabelId = types.LabelId;
const NodeId = types.NodeId;
const PropertyValue = types.PropertyValue;
const OrderedBTree = ordered_btree.OrderedBTree;

/// Snapshot file name under the graph directory.
pub const SNAPSHOT_FILE_NAME = "ordered_propidx.snap";
/// 8-byte snapshot magic (index_snapshot requires exactly 8 bytes). Bumped
/// 1 -> 2 when the per-index framing gained the eligibility flag + value-order
/// class (an old GSORDIX1 snapshot is then cleanly rejected by the magic check
/// and rebuilt from a live scan rather than silently misparsed).
pub const SNAPSHOT_MAGIC = "GSORDIX2";
const owner_only_file_mode = 0o600;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const OrderedPropertyIndex = struct {
    const Self = @This();

    allocator: Allocator,
    /// One entry per REGISTERED (label_id, property_key). Order is insertion
    /// order; the snapshot preserves it. Pointers into this list are stable only
    /// between mutations of the list (register/load), never across them.
    entries: std.ArrayList(Entry),

    /// Cursor walk direction. ASC walks values ascending (the tree's natural
    /// byte order); DESC walks them descending (the exact reverse).
    pub const Direction = enum { asc, desc };

    /// The encoder's order-class of a value, used to decide ORDER BY index
    /// eligibility (see `isEligible`). `int` and `float` are SEPARATE classes
    /// on purpose: the H3-P0 encoder type-separates them (int TYPE_RANK 0x20 <
    /// float 0x30) whereas the engine ORDER BY coerces BOTH to f64 and unifies
    /// them, so a column mixing int and float would be MIS-ordered by the index
    /// relative to the engine. `boolean`/`null_v` are tracked so a column
    /// containing them can be flagged ineligible: the engine drops bool/null
    /// from ORDER BY entirely, so an index scan would surface rows the engine
    /// omits. Persisted as the `u8` tag in the snapshot (0 == "no class yet").
    pub const ValueOrderClass = enum(u8) {
        int = 1,
        float = 2,
        string = 3,
        boolean = 4,
        null_v = 5,

        /// The order-class for `value`, or null for values with no defined
        /// encoder order (decimal, ext — these are also `!orderable`).
        fn fromValue(value: PropertyValue) ?ValueOrderClass {
            return switch (value) {
                .int => .int,
                .float => .float,
                .string => .string,
                .bool => .boolean,
                .null => .null_v,
                .decimal, .ext => null,
            };
        }
    };

    pub const Entry = struct {
        label_id: LabelId,
        /// Owned copy of the property key.
        property_key: []u8,
        tree: OrderedBTree,

        /// Whether ORDER BY for this (label,key) can be SAFELY served from the
        /// ordered index with full engine parity (no missing / mis-ordered
        /// rows). True until a value is seen that breaks parity (see the rule in
        /// `applyEligibility`). Once false, stays false until a rebuild/refresh
        /// (`clearTrees`) recomputes it from the live values. Recomputed, never
        /// trusted-across-crash beyond what the snapshot records.
        eligible: bool = true,
        /// The single order-class established by the first orderable, indexable
        /// value seen; a later value of a different class flips `eligible` false.
        /// Null until the first such value (or after a `clearTrees` reset).
        value_class: ?ValueOrderClass = null,

        fn deinit(self: *Entry, allocator: Allocator) void {
            self.tree.deinit();
            allocator.free(self.property_key);
        }
    };

    /// A direction-aware cursor over one registered tree. `next()` returns
    /// entries in the requested order until exhausted.
    pub const Cursor = struct {
        inner: OrderedBTree.Cursor,
        dir: Direction,

        pub fn next(self: *Cursor) ?OrderedBTree.Entry {
            return switch (self.dir) {
                .asc => self.inner.next(),
                .desc => self.inner.prev(),
            };
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Number of registered (label,key) indexes.
    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Find the entry for `(label_id, key)`, if registered. The pointer is valid
    /// only until the next register/load mutation of `entries`.
    pub fn find(self: *Self, label_id: LabelId, key: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.label_id == label_id and std.mem.eql(u8, e.property_key, key)) return e;
        }
        return null;
    }

    pub fn isRegistered(self: *Self, label_id: LabelId, key: []const u8) bool {
        return self.find(label_id, key) != null;
    }

    /// Whether any registered index exists for `label_id` (fast gate for the
    /// engine's per-node maintenance hooks).
    pub fn hasLabel(self: *const Self, label_id: LabelId) bool {
        for (self.entries.items) |e| {
            if (e.label_id == label_id) return true;
        }
        return false;
    }

    /// Register an ordered index on `(label_id, key)` with an empty tree.
    /// Idempotent: a no-op if already registered.
    pub fn registerIndex(self: *Self, label_id: LabelId, key: []const u8) !void {
        if (self.find(label_id, key) != null) return;
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.entries.append(self.allocator, .{
            .label_id = label_id,
            .property_key = key_copy,
            .tree = OrderedBTree.init(self.allocator),
        });
    }

    /// Number of keys in the registered (label,key) tree, or null if not
    /// registered.
    pub fn treeLen(self: *Self, label_id: LabelId, key: []const u8) ?usize {
        const e = self.find(label_id, key) orelse return null;
        return e.tree.len();
    }

    /// Index `value` for `node_id` under `(label_id, key)`. No-op when the pair
    /// is not registered or `value` is not orderable (decimal/ext/NaN). Updates
    /// the per-(label,key) ORDER BY eligibility flag for EVERY value seen
    /// (including the skipped not-orderable ones — those flip it false).
    pub fn insert(self: *Self, label_id: LabelId, key: []const u8, value: PropertyValue, node_id: NodeId) !void {
        const e = self.find(label_id, key) orelse return;
        applyEligibility(e, value);
        if (!ordered_encoding.orderable(value)) return;
        const encoded = try ordered_encoding.encodeOrdered(self.allocator, value, node_id);
        defer self.allocator.free(encoded);
        try e.tree.insert(encoded, node_id);
    }

    /// Fold one observed `value` into the entry's ORDER BY eligibility.
    ///
    /// The rule matches the H3-P0 encoder's correctness contract against the
    /// engine's `entryLess` ORDER BY order. A (label,key) is `eligible` iff
    /// EVERY value seen is index-servable with engine parity, i.e.:
    ///   * NO not-orderable value (decimal / ext / NaN float) — `orderable()`
    ///     rejects these, so they would be SKIPPED (missing rows). Ineligible.
    ///   * NO bool / null value — the engine drops bool & null from ORDER BY
    ///     entirely, so an index scan would surface rows the engine omits.
    ///     Ineligible.
    ///   * a SINGLE order-class across all values (homogeneous int, OR
    ///     homogeneous float, OR homogeneous string). int+float mixing is the
    ///     known-unsafe case (encoder type-separates; engine f64-unifies). We
    ///     require one class outright: numeric-vs-string mixing is in fact
    ///     engine-consistent (numeric TYPE_RANK < string), but requiring a
    ///     single class is strictly conservative — a false negative only costs
    ///     a heap fallback, never correctness — and it is what the `?ValueOrder
    ///     Class` single discriminant can represent precisely.
    ///
    /// Once `eligible` is false it stays false until a `clearTrees` reset
    /// (rebuild/refresh), which recomputes it from the live values.
    fn applyEligibility(e: *Entry, value: PropertyValue) void {
        const cls = ValueOrderClass.fromValue(value) orelse {
            // decimal / ext: no defined encoder order -> skipped -> ineligible.
            e.eligible = false;
            return;
        };
        switch (value) {
            // NaN float is `!orderable`: the engine has no stable NaN position,
            // so any NaN in the column makes the index unable to match it.
            .float => |f| if (std.math.isNan(f)) {
                e.eligible = false;
                return;
            },
            else => {},
        }
        // bool / null: engine ORDER BY drops them -> index would over-return.
        if (cls == .boolean or cls == .null_v) e.eligible = false;
        if (e.value_class) |established| {
            if (established != cls) e.eligible = false;
        } else {
            e.value_class = cls;
        }
    }

    /// Whether ORDER BY for `(label_id, key)` can be safely served from the
    /// ordered index with engine parity. False when the pair is not registered.
    pub fn isEligible(self: *Self, label_id: LabelId, key: []const u8) bool {
        const e = self.find(label_id, key) orelse return false;
        return e.eligible;
    }

    /// Remove the `value`/`node_id` entry from `(label_id, key)`. No-op when the
    /// pair is not registered or `value` is not orderable.
    pub fn remove(self: *Self, label_id: LabelId, key: []const u8, value: PropertyValue, node_id: NodeId) !void {
        const e = self.find(label_id, key) orelse return;
        if (!ordered_encoding.orderable(value)) return;
        const encoded = try ordered_encoding.encodeOrdered(self.allocator, value, node_id);
        defer self.allocator.free(encoded);
        _ = e.tree.remove(encoded);
    }

    /// Open a direction-aware cursor over `(label_id, key)`, parked at the start
    /// for `dir`. Returns null when the pair is not registered.
    pub fn openCursor(self: *Self, label_id: LabelId, key: []const u8, dir: Direction) ?Cursor {
        const e = self.find(label_id, key) orelse return null;
        var inner = e.tree.cursor();
        switch (dir) {
            .asc => inner.seek(""),
            .desc => inner.seekToLast(),
        }
        return .{ .inner = inner, .dir = dir };
    }

    /// Empty every registered tree in place, keeping the registration set. Used
    /// before a rebuild-from-scan so the (label,key) pairs survive but the stale
    /// trees do not.
    pub fn clearTrees(self: *Self) void {
        for (self.entries.items) |*e| {
            e.tree.deinit();
            e.tree = OrderedBTree.init(self.allocator);
            // Recompute eligibility from scratch over the re-scanned values
            // (rebuild/refresh re-`insert`s every live value afterwards).
            e.eligible = true;
            e.value_class = null;
        }
    }

    /// Drop all entries (registration + trees). Used before a load replaces the
    /// in-memory state.
    fn clearAll(self: *Self) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }

    // ========================================================================
    // Persistence
    // ========================================================================

    fn snapshotPath(self: *Self, dir_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, SNAPSHOT_FILE_NAME });
    }

    /// Save every registered index to `<dir_path>/ordered_propidx.snap`, stamped
    /// with `counter` (the engine's manifest.counter). A no-op leaves a valid
    /// empty snapshot (item_count == 0) so a clean restart still loads cleanly.
    pub fn saveToFile(self: *Self, dir_path: []const u8, counter: u64) !void {
        const path = try self.snapshotPath(dir_path);
        defer self.allocator.free(path);

        var w = index_snapshot.SnapshotWriter.init(self.allocator);
        defer w.deinit();

        try w.writeHeader(SNAPSHOT_MAGIC, counter, self.entries.items.len);
        for (self.entries.items) |*e| {
            try w.writeU32(e.label_id);
            try w.writeU32(@intCast(e.property_key.len));
            try w.writeBytes(e.property_key);
            // Eligibility flag + value-order class tag (0 == no class yet).
            const class_tag: u8 = if (e.value_class) |c| @intFromEnum(c) else 0;
            try w.writeBytes(&[_]u8{ @intFromBool(e.eligible), class_tag });
            const blob = try e.tree.serialize(self.allocator);
            defer self.allocator.free(blob);
            try w.writeU64(@intCast(blob.len));
            try w.writeBytes(blob);
        }

        const file = try std.Io.Dir.cwd().createFile(io(), path, .{
            .read = true,
            .truncate = true,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });
        defer file.close(io());
        try w.finalize(file);
    }

    /// Load the snapshot from `<dir_path>/ordered_propidx.snap`, replacing the
    /// in-memory state with the persisted registration set + trees. Returns the
    /// stamped counter, or null when no snapshot file exists (fresh graph / no
    /// ordered index ever created). The caller compares the returned counter to
    /// `manifest.counter`: equal -> trust the loaded trees; not-equal -> keep the
    /// registration but rebuild the trees from a live scan (crash-safety gate).
    pub fn loadFromFile(self: *Self, dir_path: []const u8) !?u64 {
        const path = try self.snapshotPath(dir_path);
        defer self.allocator.free(path);

        var file = std.Io.Dir.cwd().openFile(io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io());

        var loaded = (try index_snapshot.loadPayload(self.allocator, &file, SNAPSHOT_MAGIC, 0)) orelse return null;
        defer loaded.deinit();

        self.clearAll();
        errdefer self.clearAll();

        var r = index_snapshot.SnapshotReader.init(loaded.payload());
        var i: u64 = 0;
        while (i < loaded.item_count) : (i += 1) {
            const label_id = try r.readU32();
            const key_len = try r.readU32();
            const key = try r.readBytes(key_len);
            const flags = try r.readBytes(2);
            const eligible = flags[0] != 0;
            const value_class: ?ValueOrderClass = switch (flags[1]) {
                0 => null,
                @intFromEnum(ValueOrderClass.int) => .int,
                @intFromEnum(ValueOrderClass.float) => .float,
                @intFromEnum(ValueOrderClass.string) => .string,
                @intFromEnum(ValueOrderClass.boolean) => .boolean,
                @intFromEnum(ValueOrderClass.null_v) => .null_v,
                else => return error.InvalidFormat,
            };
            const blob_len = try r.readU64();
            const blob = try r.readBytes(std.math.cast(usize, blob_len) orelse return error.InvalidFormat);

            var tree = try OrderedBTree.deserialize(self.allocator, blob);
            errdefer tree.deinit();
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            try self.entries.append(self.allocator, .{
                .label_id = label_id,
                .property_key = key_copy,
                .tree = tree,
                .eligible = eligible,
                .value_class = value_class,
            });
        }

        return loaded.checkpoint_counter;
    }
};

// ============================================================================
// Unit tests (focused invariants; full TDD spec is
// tests/ordered_property_index_test.zig)
// ============================================================================

const testing = std.testing;

test "register + insert + cursor ascending" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.registerIndex(1, "k");
    try idx.insert(1, "k", .{ .int = 3 }, 30);
    try idx.insert(1, "k", .{ .int = 1 }, 10);
    try idx.insert(1, "k", .{ .int = 2 }, 20);

    var c = idx.openCursor(1, "k", .asc).?;
    var prev: i64 = std.math.minInt(i64);
    var n: usize = 0;
    while (c.next()) |entry| : (n += 1) {
        var d = try ordered_encoding.decode(testing.allocator, entry.key);
        defer d.deinit(testing.allocator);
        try testing.expect(d.value.int > prev);
        prev = d.value.int;
    }
    try testing.expectEqual(@as(usize, 3), n);
}

test "insert into unregistered pair is a no-op" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.insert(9, "x", .{ .int = 1 }, 1);
    try testing.expect(idx.treeLen(9, "x") == null);
}

test "clearTrees keeps registration" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.registerIndex(1, "k");
    try idx.insert(1, "k", .{ .int = 1 }, 1);
    idx.clearTrees();
    try testing.expectEqual(@as(?usize, 0), idx.treeLen(1, "k"));
    try testing.expect(idx.isRegistered(1, "k"));
}

test {
    std.testing.refAllDecls(@This());
}
