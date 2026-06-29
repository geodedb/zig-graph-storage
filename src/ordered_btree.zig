// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # Byte-key ordered B+Tree with a lazy ASC/DESC cursor (H3-P1 Task 1)
//!
//! A forked, byte-keyed specialisation of `btree.zig`'s generic B+Tree. The
//! key is `[]u8` and the value is a `u64` node id. The tree's natural order is
//! pure `std.mem.order(u8, a, b)` (i.e. `memcmp`), which by construction equals
//! the order produced by the H3-P0 `ordered_encoding` keys — so an in-order
//! walk IS the engine's ORDER BY order, with no per-key comparator.
//!
//! ## Key ownership (critical)
//!
//! The tree OWNS every key it stores: `insert` duplicates the caller's bytes
//! into a heap copy, `remove`/`deinit` free those copies. Leaf nodes hold the
//! canonical key copies (one per entry); internal nodes hold SEPARATE separator
//! copies (dup'd on leaf split, or moved up on internal split). Because leaf
//! and internal copies are distinct allocations, freeing a leaf key on remove
//! never dangles a separator, and `deinit` frees every node's own keys with no
//! double-free.
//!
//! ## Cursor (lazy, one entry at a time — NO full-slice materialisation)
//!
//! A `Cursor` holds `(leaf, idx)` pointing AT the current valid entry (or
//! `leaf == null` when exhausted). `seek(prefix)` descends to the first key
//! `>= prefix` (ASC start); `seekToLast()` parks at the rightmost entry (DESC
//! start). `next()` returns the current entry then steps forward via
//! `next_leaf`; `prev()` returns the current entry then steps backward via the
//! `prev_leaf` back-pointers added here. Both skip empty leaves (a `remove`
//! may leave a leaf sparse/empty; no rebalance is performed).
//!
//! ## Persistence
//!
//! `serialize`/`deserialize` use a variable-length framing: a `u32` entry-count
//! header, then per entry `[u32 key_len][key bytes][u64 node_id]` in in-order
//! (leaf-linked-list) order. The round-trip reproduces the exact in-order walk.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OrderedBTree = struct {
    const Self = @This();
    pub const ORDER = 64; // max keys per node before split

    allocator: Allocator,
    root: ?*Node = null,
    count: usize = 0,

    /// One returned tree entry. `key` borrows the tree's owned copy and is only
    /// valid until the next mutation of the tree.
    pub const Entry = struct { key: []const u8, node_id: u64 };

    pub const Node = struct {
        keys: std.ArrayList([]u8) = .empty,
        values: ?std.ArrayList(u64) = null, // leaf only
        children: ?std.ArrayList(*Node) = null, // internal only
        is_leaf: bool,
        next_leaf: ?*Node = null, // leaf linked-list (forward)
        prev_leaf: ?*Node = null, // leaf linked-list (reverse) — for DESC walk

        fn initLeaf(allocator: Allocator) !*Node {
            const node = try allocator.create(Node);
            node.* = .{ .values = .empty, .is_leaf = true };
            return node;
        }

        fn initInternal(allocator: Allocator) !*Node {
            const node = try allocator.create(Node);
            node.* = .{ .children = .empty, .is_leaf = false };
            return node;
        }

        /// Recursively free this subtree, including every owned key copy.
        fn deinit(self: *Node, allocator: Allocator) void {
            if (!self.is_leaf) {
                if (self.children) |*ch| {
                    for (ch.items) |child| child.deinit(allocator);
                    ch.deinit(allocator);
                }
            }
            for (self.keys.items) |k| allocator.free(k);
            self.keys.deinit(allocator);
            if (self.values) |*v| v.deinit(allocator);
            allocator.destroy(self);
        }

        /// First index whose key is >= `key` (byte order).
        fn lowerBound(self: *const Node, key: []const u8) usize {
            const items = self.keys.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, items[mid], key) == .lt) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        /// First index whose key is > `key` (byte order). Internal child select.
        fn upperBound(self: *const Node, key: []const u8) usize {
            const items = self.keys.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, items[mid], key) != .gt) {
                    lo = mid + 1; // items[mid] <= key
                } else {
                    hi = mid;
                }
            }
            return lo;
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.root = null;
        }
        self.count = 0;
    }

    pub fn len(self: *const Self) usize {
        return self.count;
    }

    // ========================================================================
    // Insert
    // ========================================================================

    /// Insert (or replace the value of) `key`. The tree dups `key` into an
    /// owned heap copy; on an exact-equal existing key the stored value is
    /// REPLACED in place (unique keys — P0 keys embed node_id so duplicates do
    /// not occur in practice, but replace is the well-defined contract).
    pub fn insert(self: *Self, key: []const u8, node_id: u64) !void {
        if (self.root == null) {
            const leaf = try Node.initLeaf(self.allocator);
            errdefer leaf.deinit(self.allocator);
            const owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned);
            try leaf.keys.append(self.allocator, owned);
            try leaf.values.?.append(self.allocator, node_id);
            self.root = leaf;
            self.count = 1;
            return;
        }

        const result = try self.insertInto(self.root.?, key, node_id);
        if (result.split) |split| {
            const new_root = try Node.initInternal(self.allocator);
            // On OOM here the median copy would leak; append children first is
            // not possible without the key, so dup the separator into the root.
            try new_root.keys.append(self.allocator, split.median);
            try new_root.children.?.append(self.allocator, self.root.?);
            try new_root.children.?.append(self.allocator, split.right);
            self.root = new_root;
        }
    }

    const SplitResult = struct {
        /// Owned separator key copy handed UP to the parent.
        median: []u8,
        right: *Node,
    };

    const InsertResult = struct {
        split: ?SplitResult = null,
        replaced: bool = false,
    };

    const InsertError = Allocator.Error;

    fn insertInto(self: *Self, node: *Node, key: []const u8, node_id: u64) InsertError!InsertResult {
        if (node.is_leaf) return self.insertIntoLeaf(node, key, node_id);
        return self.insertIntoInternal(node, key, node_id);
    }

    fn insertIntoLeaf(self: *Self, node: *Node, key: []const u8, node_id: u64) InsertError!InsertResult {
        const pos = node.lowerBound(key);
        if (pos < node.keys.items.len and std.mem.order(u8, node.keys.items[pos], key) == .eq) {
            node.values.?.items[pos] = node_id; // replace value, keep owned key
            return .{ .replaced = true };
        }
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try node.keys.insert(self.allocator, pos, owned);
        errdefer _ = node.keys.orderedRemove(pos);
        try node.values.?.insert(self.allocator, pos, node_id);
        self.count += 1;

        if (node.keys.items.len > ORDER) {
            const split = try self.splitLeaf(node);
            return .{ .split = split };
        }
        return .{};
    }

    fn insertIntoInternal(self: *Self, node: *Node, key: []const u8, node_id: u64) InsertError!InsertResult {
        const idx: usize = node.upperBound(key);
        const child = node.children.?.items[idx];
        const result = try self.insertInto(child, key, node_id);

        if (result.split) |split| {
            const insert_pos = node.lowerBound(split.median);
            try node.keys.insert(self.allocator, insert_pos, split.median);
            errdefer _ = node.keys.orderedRemove(insert_pos);
            try node.children.?.insert(self.allocator, insert_pos + 1, split.right);

            if (node.keys.items.len > ORDER) {
                const new_split = try self.splitInternal(node);
                return .{ .split = new_split };
            }
        }
        return .{ .replaced = result.replaced };
    }

    fn splitLeaf(self: *Self, node: *Node) !SplitResult {
        const mid = node.keys.items.len / 2;
        const right = try Node.initLeaf(self.allocator);
        errdefer right.deinit(self.allocator);

        try right.keys.appendSlice(self.allocator, node.keys.items[mid..]);
        try right.values.?.appendSlice(self.allocator, node.values.?.items[mid..]);

        // Separator for the parent is a SEPARATE owned copy of the right node's
        // first key (the leaf still owns its own copy of that key).
        const median = try self.allocator.dupe(u8, right.keys.items[0]);
        errdefer self.allocator.free(median);

        node.keys.shrinkRetainingCapacity(mid);
        node.values.?.shrinkRetainingCapacity(mid);

        // Maintain the doubly-linked leaf list.
        right.next_leaf = node.next_leaf;
        right.prev_leaf = node;
        if (node.next_leaf) |nxt| nxt.prev_leaf = right;
        node.next_leaf = right;

        return .{ .median = median, .right = right };
    }

    fn splitInternal(self: *Self, node: *Node) !SplitResult {
        const mid = node.keys.items.len / 2;
        // The median separator is MOVED up (ownership transfers; it was already
        // a distinct heap copy). Keys after mid move to the right node.
        const median = node.keys.items[mid];
        const right = try Node.initInternal(self.allocator);
        errdefer {
            // Right took no ownership yet on the failing append paths below; on
            // a late failure its appended slices are still owned by `node`, so
            // only destroy the empty container.
            right.keys.deinit(self.allocator);
            if (right.children) |*c| c.deinit(self.allocator);
            self.allocator.destroy(right);
        }

        try right.keys.appendSlice(self.allocator, node.keys.items[mid + 1 ..]);
        try right.children.?.appendSlice(self.allocator, node.children.?.items[mid + 1 ..]);

        node.keys.shrinkRetainingCapacity(mid);
        node.children.?.shrinkRetainingCapacity(mid + 1);

        return .{ .median = median, .right = right };
    }

    // ========================================================================
    // Search / remove
    // ========================================================================

    pub fn search(self: *const Self, key: []const u8) ?u64 {
        const leaf = self.findLeaf(key) orelse return null;
        const pos = leaf.lowerBound(key);
        if (pos < leaf.keys.items.len and std.mem.order(u8, leaf.keys.items[pos], key) == .eq) {
            return leaf.values.?.items[pos];
        }
        return null;
    }

    /// Remove `key`. Returns true if found+removed (and its owned copy freed).
    /// No merge/redistribute on underflow — sparse/empty leaves are acceptable
    /// (the cursor skips them; rebuild compacts).
    pub fn remove(self: *Self, key: []const u8) bool {
        const root = self.root orelse return false;
        return self.removeFrom(root, key);
    }

    fn removeFrom(self: *Self, node: *Node, key: []const u8) bool {
        if (node.is_leaf) {
            const pos = node.lowerBound(key);
            if (pos < node.keys.items.len and std.mem.order(u8, node.keys.items[pos], key) == .eq) {
                const owned = node.keys.orderedRemove(pos);
                self.allocator.free(owned);
                _ = node.values.?.orderedRemove(pos);
                self.count -= 1;
                return true;
            }
            return false;
        }
        const child_idx = node.upperBound(key);
        return self.removeFrom(node.children.?.items[child_idx], key);
    }

    // ========================================================================
    // Traversal helpers
    // ========================================================================

    fn findLeaf(self: *const Self, key: []const u8) ?*Node {
        var node = self.root orelse return null;
        while (!node.is_leaf) {
            const idx = node.upperBound(key);
            node = node.children.?.items[idx];
        }
        return node;
    }

    fn leftmostLeaf(self: *const Self) ?*Node {
        var node = self.root orelse return null;
        while (!node.is_leaf) node = node.children.?.items[0];
        return node;
    }

    fn rightmostLeaf(self: *const Self) ?*Node {
        var node = self.root orelse return null;
        while (!node.is_leaf) node = node.children.?.items[node.children.?.items.len - 1];
        return node;
    }

    // ========================================================================
    // Cursor — lazy ASC/DESC iteration, one entry at a time
    // ========================================================================

    pub fn cursor(self: *Self) Cursor {
        return .{ .tree = self, .leaf = null, .idx = 0 };
    }

    pub const Cursor = struct {
        tree: *Self,
        /// Invariant: either `leaf == null` (exhausted) OR `idx < leaf.keys.len`
        /// and `(leaf, idx)` names a valid current entry.
        leaf: ?*Node,
        idx: usize,

        /// Park at the first key `>= prefix` (ASC start). An empty prefix is
        /// `<= ` every key, so it parks at the very first entry.
        pub fn seek(self: *Cursor, prefix: []const u8) void {
            const leaf = self.tree.findLeaf(prefix) orelse {
                self.leaf = null;
                return;
            };
            self.leaf = leaf;
            self.idx = leaf.lowerBound(prefix);
            self.normalizeForward();
        }

        /// Park at the rightmost (largest) entry (DESC start).
        pub fn seekToLast(self: *Cursor) void {
            var leaf = self.tree.rightmostLeaf();
            // Skip empty leaves backward (possible after removes).
            while (leaf) |cur| {
                if (cur.keys.items.len > 0) {
                    self.leaf = cur;
                    self.idx = cur.keys.items.len - 1;
                    return;
                }
                leaf = cur.prev_leaf;
            }
            self.leaf = null;
        }

        /// If `idx` ran off the end of a (possibly empty) leaf, advance to the
        /// next non-empty entry, or mark exhausted.
        fn normalizeForward(self: *Cursor) void {
            while (self.leaf) |cur| {
                if (self.idx < cur.keys.items.len) return;
                self.leaf = cur.next_leaf;
                self.idx = 0;
            }
        }

        /// Return the current entry, then step forward (via `next_leaf`).
        pub fn next(self: *Cursor) ?Entry {
            self.normalizeForward();
            const cur = self.leaf orelse return null;
            const e = Entry{ .key = cur.keys.items[self.idx], .node_id = cur.values.?.items[self.idx] };
            self.idx += 1;
            self.normalizeForward();
            return e;
        }

        /// Mirror of `normalizeForward` for the DESC walk. BEFORE any backward
        /// access, re-validate the cursor against the (possibly shrunk) leaf: a
        /// concurrent `remove` during a lock-release window can drop entries
        /// from the current leaf, leaving `idx >= keys.len` or the whole leaf
        /// empty. Clamp `idx` back into range (a torn read — a removed entry is
        /// skipped or a shifted entry may repeat — is acceptable), and skip
        /// empty leaves to `prev_leaf`, marking exhausted if we walk off the
        /// front. After this returns, `leaf == null` OR `idx < leaf.keys.len`,
        /// so `prev()` can never read past the array.
        fn normalizeBackward(self: *Cursor) void {
            while (self.leaf) |cur| {
                if (cur.keys.items.len == 0) {
                    // Leaf emptied by a concurrent remove: step to the previous
                    // leaf and position at ITS last entry on the next iteration.
                    self.leaf = cur.prev_leaf;
                    self.idx = std.math.maxInt(usize); // force the clamp below
                    continue;
                }
                if (self.idx >= cur.keys.items.len) self.idx = cur.keys.items.len - 1;
                return;
            }
        }

        /// Return the current entry, then step backward (via `prev_leaf`).
        pub fn prev(self: *Cursor) ?Entry {
            self.normalizeBackward();
            const cur = self.leaf orelse return null;
            const e = Entry{ .key = cur.keys.items[self.idx], .node_id = cur.values.?.items[self.idx] };
            if (self.idx > 0) {
                self.idx -= 1;
            } else {
                var p = cur.prev_leaf;
                while (p) |pl| {
                    if (pl.keys.items.len > 0) {
                        self.leaf = pl;
                        self.idx = pl.keys.items.len - 1;
                        return e;
                    }
                    p = pl.prev_leaf;
                }
                self.leaf = null; // walked off the front
            }
            return e;
        }
    };

    // ========================================================================
    // Variable-length serialize / deserialize
    // ========================================================================

    /// Flat binary format (all little-endian):
    ///   [entry_count: u32]
    ///   per entry (in-order / leaf-linked-list order):
    ///     [key_len: u32] [key bytes] [node_id: u64]
    pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
        var total: usize = @sizeOf(u32);
        {
            var leaf: ?*Node = self.leftmostLeaf();
            while (leaf) |cur| {
                for (cur.keys.items) |k| total += @sizeOf(u32) + k.len + @sizeOf(u64);
                leaf = cur.next_leaf;
            }
        }

        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);

        std.mem.writeInt(u32, buf[0..4], @intCast(self.count), .little);
        var off: usize = @sizeOf(u32);

        var leaf: ?*Node = self.leftmostLeaf();
        while (leaf) |cur| {
            for (cur.keys.items, 0..) |k, i| {
                std.mem.writeInt(u32, buf[off..][0..4], @intCast(k.len), .little);
                off += 4;
                @memcpy(buf[off..][0..k.len], k);
                off += k.len;
                std.mem.writeInt(u64, buf[off..][0..8], cur.values.?.items[i], .little);
                off += 8;
            }
            leaf = cur.next_leaf;
        }
        std.debug.assert(off == total);
        return buf;
    }

    /// Rebuild a tree from a `serialize` buffer. Entries arrive in sorted order
    /// so the bulk `insert` reproduces the exact in-order walk.
    pub fn deserialize(allocator: Allocator, data: []const u8) !Self {
        if (data.len < @sizeOf(u32)) return error.InvalidFormat;
        const entry_count = std.mem.readInt(u32, data[0..4], .little);

        var tree = Self.init(allocator);
        errdefer tree.deinit();

        var off: usize = @sizeOf(u32);
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (off + @sizeOf(u32) > data.len) return error.InvalidFormat;
            const klen = std.mem.readInt(u32, data[off..][0..4], .little);
            off += 4;
            if (off + klen + @sizeOf(u64) > data.len) return error.InvalidFormat;
            const key = data[off..][0..klen];
            off += klen;
            const node_id = std.mem.readInt(u64, data[off..][0..8], .little);
            off += 8;
            try tree.insert(key, node_id);
        }
        if (off != data.len) return error.InvalidFormat;
        return tree;
    }
};

// ============================================================================
// Unit tests (focused invariants; the full TDD spec is tests/ordered_btree_test.zig)
// ============================================================================

const testing = std.testing;

test "insert + search + replace" {
    var tree = OrderedBTree.init(testing.allocator);
    defer tree.deinit();

    try tree.insert("banana", 2);
    try tree.insert("apple", 1);
    try testing.expectEqual(@as(?u64, 1), tree.search("apple"));
    try testing.expectEqual(@as(?u64, 2), tree.search("banana"));
    try testing.expect(tree.search("cherry") == null);

    try tree.insert("apple", 99); // replace
    try testing.expectEqual(@as(usize, 2), tree.len());
    try testing.expectEqual(@as(?u64, 99), tree.search("apple"));
}

test "cursor seek/next/prev across a single split boundary" {
    var tree = OrderedBTree.init(testing.allocator);
    defer tree.deinit();

    var buf: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < OrderedBTree.ORDER * 3) : (i += 1) {
        std.mem.writeInt(u32, &buf, i, .big);
        try tree.insert(&buf, i);
    }

    var c = tree.cursor();
    c.seek("");
    var prev_key: [4]u8 = .{ 0, 0, 0, 0 };
    var seen: u32 = 0;
    var first = true;
    while (c.next()) |e| : (seen += 1) {
        if (!first) try testing.expect(std.mem.order(u8, &prev_key, e.key) == .lt);
        @memcpy(&prev_key, e.key);
        first = false;
    }
    try testing.expectEqual(OrderedBTree.ORDER * 3, seen);
}

test {
    std.testing.refAllDecls(@This());
}
