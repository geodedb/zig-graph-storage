// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic in-memory B+tree.
///
/// K and V must be integer types supporting standard comparison.
/// For v1 this is entirely in-memory; page-based persistence is a future
/// optimisation.
pub fn BPlusTree(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const ORDER = 64; // max keys per node before split

        allocator: Allocator,
        root: ?*Node = null,
        count: usize = 0,

        pub const Node = struct {
            keys: std.ArrayList(K) = .{},
            values: ?std.ArrayList(V) = null, // leaf only
            children: ?std.ArrayList(*Node) = null, // internal only
            is_leaf: bool,
            next_leaf: ?*Node = null, // leaf linked-list for range scans

            fn initLeaf(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .values = .{},
                    .is_leaf = true,
                };
                return node;
            }

            fn initInternal(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .children = .{},
                    .is_leaf = false,
                };
                return node;
            }

            fn deinit(self: *Node, allocator: Allocator) void {
                self.deinitChildren(allocator);
                self.keys.deinit(allocator);
                if (self.values) |*v| v.deinit(allocator);
                allocator.destroy(self);
            }

            /// Recursively free child nodes for internal (non-leaf) nodes.
            fn deinitChildren(self: *Node, allocator: Allocator) void {
                if (self.is_leaf) return;
                const ch = &(self.children orelse return);
                for (ch.items) |child| {
                    child.deinit(allocator);
                }
                ch.deinit(allocator);
            }

            /// Lower bound: returns the index of the first key >= `key`.
            fn lowerBound(self: *const Node, key: K) usize {
                const items = self.keys.items;
                var lo: usize = 0;
                var hi: usize = items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid] < key) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                return lo;
            }

            /// Upper bound: returns the index of the first key > `key`.
            /// Used for internal node child selection in B+tree traversal.
            fn upperBound(self: *const Node, key: K) usize {
                const items = self.keys.items;
                var lo: usize = 0;
                var hi: usize = items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid] <= key) {
                        lo = mid + 1;
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
        }

        /// Insert a key-value pair. If key already exists, update the value.
        pub fn insert(self: *Self, key: K, value: V) !void {
            if (self.root == null) {
                const leaf = try Node.initLeaf(self.allocator);
                try leaf.keys.append(self.allocator, key);
                try leaf.values.?.append(self.allocator, value);
                self.root = leaf;
                self.count = 1;
                return;
            }

            const result = try self.insertInto(self.root.?, key, value);
            if (result.split) |split| {
                // Root was split — create a new root.
                const new_root = try Node.initInternal(self.allocator);
                try new_root.keys.append(self.allocator, split.median);
                try new_root.children.?.append(self.allocator, self.root.?);
                try new_root.children.?.append(self.allocator, split.right);
                self.root = new_root;
            }
        }

        const SplitResult = struct {
            median: K,
            right: *Node,
        };

        const InsertResult = struct {
            split: ?SplitResult = null,
            replaced: bool = false,
        };

        const InsertError = Allocator.Error;

        fn insertInto(self: *Self, node: *Node, key: K, value: V) InsertError!InsertResult {
            if (node.is_leaf) {
                return self.insertIntoLeaf(node, key, value);
            }
            return self.insertIntoInternal(node, key, value);
        }

        fn insertIntoLeaf(self: *Self, node: *Node, key: K, value: V) InsertError!InsertResult {
            const pos = node.lowerBound(key);
            // Check for existing key — update in place.
            if (pos < node.keys.items.len and node.keys.items[pos] == key) {
                node.values.?.items[pos] = value;
                return .{ .replaced = true };
            }
            try node.keys.insert(self.allocator, pos, key);
            try node.values.?.insert(self.allocator, pos, value);
            self.count += 1;

            // Split if overflowed.
            if (node.keys.items.len > ORDER) {
                const split = try self.splitLeaf(node);
                return .{ .split = split };
            }
            return .{};
        }

        fn insertIntoInternal(self: *Self, node: *Node, key: K, value: V) InsertError!InsertResult {
            // Find child to descend into using upper bound.
            // children[i] covers keys where keys[i-1] <= k < keys[i].
            const idx: usize = node.upperBound(key);
            const child = node.children.?.items[idx];
            const result = try self.insertInto(child, key, value);

            if (result.split) |split| {
                const insert_pos = node.lowerBound(split.median);
                try node.keys.insert(self.allocator, insert_pos, split.median);
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

            try right.keys.appendSlice(self.allocator, node.keys.items[mid..]);
            try right.values.?.appendSlice(self.allocator, node.values.?.items[mid..]);

            node.keys.shrinkRetainingCapacity(mid);
            node.values.?.shrinkRetainingCapacity(mid);

            // Maintain leaf linked list.
            right.next_leaf = node.next_leaf;
            node.next_leaf = right;

            return .{
                .median = right.keys.items[0],
                .right = right,
            };
        }

        fn splitInternal(self: *Self, node: *Node) !SplitResult {
            const mid = node.keys.items.len / 2;
            const median = node.keys.items[mid];
            const right = try Node.initInternal(self.allocator);

            try right.keys.appendSlice(self.allocator, node.keys.items[mid + 1 ..]);
            try right.children.?.appendSlice(self.allocator, node.children.?.items[mid + 1 ..]);

            node.keys.shrinkRetainingCapacity(mid);
            node.children.?.shrinkRetainingCapacity(mid + 1);

            return .{
                .median = median,
                .right = right,
            };
        }

        /// Search for a key. Returns null if not found.
        pub fn search(self: *const Self, key: K) ?V {
            const leaf = self.findLeaf(key) orelse return null;
            const pos = leaf.lowerBound(key);
            if (pos < leaf.keys.items.len and leaf.keys.items[pos] == key) {
                return leaf.values.?.items[pos];
            }
            return null;
        }

        /// Delete a key. Returns true if found and removed.
        /// For v1 we don't merge/redistribute on underflow.
        pub fn delete(self: *Self, key: K) bool {
            const root = self.root orelse return false;
            return self.deleteFrom(root, key);
        }

        fn deleteFrom(self: *Self, node: *Node, key: K) bool {
            if (node.is_leaf) {
                const pos = node.lowerBound(key);
                if (pos < node.keys.items.len and node.keys.items[pos] == key) {
                    _ = node.keys.orderedRemove(pos);
                    _ = node.values.?.orderedRemove(pos);
                    self.count -= 1;
                    return true;
                }
                return false;
            }
            const child_idx = node.upperBound(key);
            return self.deleteFrom(node.children.?.items[child_idx], key);
        }

        /// Range scan: returns all values where lo <= key <= hi.
        pub fn range(self: *const Self, lo: K, hi: K, allocator: Allocator) ![]V {
            var result = std.ArrayList(V){};
            errdefer result.deinit(allocator);

            const start_leaf = self.findLeaf(lo) orelse
                return try result.toOwnedSlice(allocator);

            try collectRange(start_leaf, lo, hi, allocator, &result);
            return try result.toOwnedSlice(allocator);
        }

        /// Traverse from root to the leaf node that would contain `key`.
        fn findLeaf(self: *const Self, key: K) ?*Node {
            var node = self.root orelse return null;
            while (!node.is_leaf) {
                const idx = node.upperBound(key);
                node = node.children.?.items[idx];
            }
            return node;
        }

        /// Walk the leaf linked list from `start`, collecting values
        /// for keys in [lo, hi].
        fn collectRange(start: *Node, lo: K, hi: K, allocator: Allocator, result: *std.ArrayList(V)) !void {
            var leaf: ?*Node = start;
            while (leaf) |cur| {
                for (cur.keys.items, 0..) |k, i| {
                    if (k > hi) return;
                    if (k >= lo) try result.append(allocator, cur.values.?.items[i]);
                }
                leaf = cur.next_leaf;
            }
        }

        /// Number of entries.
        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "insert + search — found" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    try tree.insert(42, 100);
    const v = tree.search(42);
    try testing.expect(v != null);
    try testing.expectEqual(@as(u64, 100), v.?);
}

test "search not found returns null" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    try tree.insert(1, 10);
    try testing.expect(tree.search(999) == null);
}

test "insert many, all searchable" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 200) : (i += 1) {
        try tree.insert(i, i * 10);
    }

    i = 0;
    while (i < 200) : (i += 1) {
        const v = tree.search(i);
        try testing.expect(v != null);
        try testing.expectEqual(i * 10, v.?);
    }
}

test "insert enough to trigger splits (> ORDER), all still findable" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    const n: u64 = Tree.ORDER * 4;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try tree.insert(i, i + 1000);
    }

    try testing.expectEqual(@as(usize, @intCast(n)), tree.len());

    i = 0;
    while (i < n) : (i += 1) {
        const v = tree.search(i);
        try testing.expect(v != null);
        try testing.expectEqual(i + 1000, v.?);
    }
}

test "range scan returns correct range" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try tree.insert(i, i);
    }

    const result = try tree.range(10, 19, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 10), result.len);
    for (result, 0..) |v, j| {
        try testing.expectEqual(@as(u64, 10 + j), v);
    }
}

test "delete + search — not found" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    try tree.insert(5, 50);
    try tree.insert(10, 100);

    const removed = tree.delete(5);
    try testing.expect(removed);
    try testing.expect(tree.search(5) == null);
    try testing.expect(tree.search(10) != null);
}

test "delete non-existent key returns false" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    try tree.insert(1, 10);
    try testing.expect(!tree.delete(999));
}

test "len tracks count correctly" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.len());

    try tree.insert(1, 10);
    try tree.insert(2, 20);
    try testing.expectEqual(@as(usize, 2), tree.len());

    _ = tree.delete(1);
    try testing.expectEqual(@as(usize, 1), tree.len());
}

test "insert duplicate key updates value" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    try tree.insert(42, 100);
    try tree.insert(42, 200);

    try testing.expectEqual(@as(usize, 1), tree.len());
    try testing.expectEqual(@as(u64, 200), tree.search(42).?);
}

test "range scan on empty tree" {
    var tree = BPlusTree(u64, u64).init(testing.allocator);
    defer tree.deinit();

    const result = try tree.range(0, 100, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "insert in reverse order with splits" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    const n: u64 = Tree.ORDER * 3;
    var i: u64 = n;
    while (i > 0) {
        i -= 1;
        try tree.insert(i, i);
    }

    try testing.expectEqual(@as(usize, @intCast(n)), tree.len());

    i = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(i, tree.search(i).?);
    }
}

test {
    std.testing.refAllDecls(@This());
}
