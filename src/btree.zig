// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;

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
            keys: std.ArrayList(K) = .empty,
            values: ?std.ArrayList(V) = null, // leaf only
            children: ?std.ArrayList(*Node) = null, // internal only
            is_leaf: bool,
            next_leaf: ?*Node = null, // leaf linked-list for range scans

            fn initLeaf(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .values = .empty,
                    .is_leaf = true,
                };
                return node;
            }

            fn initInternal(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .children = .empty,
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
            var result: std.ArrayList(V) = .empty;
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

        // ====================================================================
        // Snapshot serialization / deserialization
        // ====================================================================

        /// Flat binary format (all little-endian):
        ///   [entry_count: u32]
        ///   For each key-value pair (leaf-linked-list order):
        ///     [key: @sizeOf(K) bytes] [value: @sizeOf(V) bytes]
        pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
            const entry_count: u32 = @intCast(self.count);
            const header_size = @sizeOf(u32);
            const entry_size = @sizeOf(K) + @sizeOf(V);
            const total = header_size + @as(usize, entry_count) * entry_size;

            const buf = try allocator.alloc(u8, total);
            errdefer allocator.free(buf);

            std.mem.writeInt(u32, buf[0..4], entry_count, .little);
            var offset: usize = header_size;

            // Walk leaf linked list from leftmost leaf.
            var leaf: ?*Node = self.findLeftmostLeaf();
            while (leaf) |cur| {
                for (cur.keys.items, 0..) |key, i| {
                    std.mem.writeInt(K, buf[offset..][0..@sizeOf(K)], key, .little);
                    offset += @sizeOf(K);
                    std.mem.writeInt(V, buf[offset..][0..@sizeOf(V)], cur.values.?.items[i], .little);
                    offset += @sizeOf(V);
                }
                leaf = cur.next_leaf;
            }

            std.debug.assert(offset == total);
            return buf;
        }

        /// Deserialize a tree from a buffer produced by `serialize`.
        /// Entries are in sorted order so bulk-insert is efficient.
        pub fn deserialize(allocator: Allocator, data: []const u8) !Self {
            if (data.len < @sizeOf(u32)) return error.InvalidFormat;

            const entry_count = std.mem.readInt(u32, data[0..4], .little);
            const entry_size = @sizeOf(K) + @sizeOf(V);
            const expected = @sizeOf(u32) + @as(usize, entry_count) * entry_size;
            if (data.len != expected) return error.InvalidFormat;

            var tree = Self.init(allocator);
            errdefer tree.deinit();

            var offset: usize = @sizeOf(u32);
            var i: u32 = 0;
            while (i < entry_count) : (i += 1) {
                const key = std.mem.readInt(K, data[offset..][0..@sizeOf(K)], .little);
                offset += @sizeOf(K);
                const value = std.mem.readInt(V, data[offset..][0..@sizeOf(V)], .little);
                offset += @sizeOf(V);
                try tree.insert(key, value);
            }

            return tree;
        }

        /// Find the leftmost leaf by descending through first children.
        fn findLeftmostLeaf(self: *const Self) ?*Node {
            var node = self.root orelse return null;
            while (!node.is_leaf) {
                node = node.children.?.items[0];
            }
            return node;
        }

        // ====================================================================
        // File-based snapshot persistence
        // ====================================================================

        pub const BTREE_SNAPSHOT_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'B', 'T', 'R', '0', '1' };
        const BTREE_SNAPSHOT_VERSION: u32 = 1;

        /// Save the tree to a file.
        /// Format: [magic 8B] [version 4B] [serialized tree data] [CRC32 4B]
        pub fn saveToFile(self: *const Self, allocator: Allocator, path: []const u8) !void {
            const tree_data = try self.serialize(allocator);
            defer allocator.free(tree_data);

            const total_size = 8 + 4 + tree_data.len + 4;
            const buf = try allocator.alloc(u8, total_size);
            defer allocator.free(buf);

            @memcpy(buf[0..8], &BTREE_SNAPSHOT_MAGIC);
            std.mem.writeInt(u32, buf[8..12], BTREE_SNAPSHOT_VERSION, .little);
            @memcpy(buf[12 .. 12 + tree_data.len], tree_data);

            const crc = Crc32.hash(buf[0 .. total_size - 4]);
            std.mem.writeInt(u32, buf[total_size - 4 ..][0..4], crc, .little);

            const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
            defer file.close(std.Io.Threaded.global_single_threaded.io());
            try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), buf);
        }

        /// Load a tree from a file written by `saveToFile`.
        pub fn loadFromFile(allocator: Allocator, path: []const u8) !Self {
            const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
            defer file.close(std.Io.Threaded.global_single_threaded.io());

            const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
            const file_size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
            if (file_size < 8 + 4 + 4 + 4) return error.InvalidFormat; // magic + version + min tree data + crc

            const buf = try allocator.alloc(u8, file_size);
            defer allocator.free(buf);

            const bytes_read = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), buf, 0);
            if (bytes_read != file_size) return error.UnexpectedEndOfFile;

            // Verify magic
            if (!std.mem.eql(u8, buf[0..8], &BTREE_SNAPSHOT_MAGIC)) return error.InvalidFormat;

            // Verify version
            const version = std.mem.readInt(u32, buf[8..12], .little);
            if (version != BTREE_SNAPSHOT_VERSION) return error.InvalidFormat;

            // Verify CRC
            const stored_crc = std.mem.readInt(u32, buf[file_size - 4 ..][0..4], .little);
            const computed_crc = Crc32.hash(buf[0 .. file_size - 4]);
            if (stored_crc != computed_crc) return error.InvalidFormat;

            // Deserialize tree data (between version and CRC)
            return Self.deserialize(allocator, buf[12 .. file_size - 4]);
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

// ============================================================================
// Serialization / Deserialization Tests
// ============================================================================

test "serialize + deserialize — empty tree round-trips" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    const data = try tree.serialize(testing.allocator);
    defer testing.allocator.free(data);

    var loaded = try Tree.deserialize(testing.allocator, data);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.len());
}

test "serialize + deserialize — 100 entries round-trip" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try tree.insert(i, i * 7);
    }

    const data = try tree.serialize(testing.allocator);
    defer testing.allocator.free(data);

    var loaded = try Tree.deserialize(testing.allocator, data);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 100), loaded.len());
    i = 0;
    while (i < 100) : (i += 1) {
        const v = loaded.search(i);
        try testing.expect(v != null);
        try testing.expectEqual(i * 7, v.?);
    }
}

test "deserialized tree supports get and range scan" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 50) : (i += 1) {
        try tree.insert(i, i + 1000);
    }

    const data = try tree.serialize(testing.allocator);
    defer testing.allocator.free(data);

    var loaded = try Tree.deserialize(testing.allocator, data);
    defer loaded.deinit();

    // Point lookup
    try testing.expectEqual(@as(u64, 1010), loaded.search(10).?);
    try testing.expect(loaded.search(999) == null);

    // Range scan
    const result = try loaded.range(5, 9, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 5), result.len);
    for (result, 0..) |v, j| {
        try testing.expectEqual(@as(u64, 1005 + j), v);
    }
}

test "serialize + deserialize — large tree with splits" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    const n: u64 = Tree.ORDER * 4;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try tree.insert(i, i * 3);
    }

    const data = try tree.serialize(testing.allocator);
    defer testing.allocator.free(data);

    var loaded = try Tree.deserialize(testing.allocator, data);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, @intCast(n)), loaded.len());
    i = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(i * 3, loaded.search(i).?);
    }
}

test "deserialize — invalid data returns error" {
    const Tree = BPlusTree(u64, u64);
    // Too short
    try testing.expectError(error.InvalidFormat, Tree.deserialize(testing.allocator, &[_]u8{ 0, 0 }));

    // Wrong length (claims 1 entry but no data)
    var bad: [4]u8 = undefined;
    std.mem.writeInt(u32, &bad, 1, .little);
    try testing.expectError(error.InvalidFormat, Tree.deserialize(testing.allocator, &bad));
}

// ============================================================================
// File-based Snapshot Tests
// ============================================================================

test "saveToFile + loadFromFile — round-trip" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 75) : (i += 1) {
        try tree.insert(i, i + 500);
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/btree.snap", .{path});
    defer testing.allocator.free(file_path);

    try tree.saveToFile(testing.allocator, file_path);

    var loaded = try Tree.loadFromFile(testing.allocator, file_path);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 75), loaded.len());
    i = 0;
    while (i < 75) : (i += 1) {
        try testing.expectEqual(i + 500, loaded.search(i).?);
    }
}

test "saveToFile + loadFromFile — empty tree round-trip" {
    const Tree = BPlusTree(u64, u64);
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/btree_empty.snap", .{path});
    defer testing.allocator.free(file_path);

    try tree.saveToFile(testing.allocator, file_path);

    var loaded = try Tree.loadFromFile(testing.allocator, file_path);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.len());
}

test "loadFromFile — corrupted file returns error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/btree_bad.snap", .{path});
    defer testing.allocator.free(file_path);

    // Write garbage data
    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "this is not a valid snapshot file!!");
    }

    const Tree = BPlusTree(u64, u64);
    try testing.expectError(error.InvalidFormat, Tree.loadFromFile(testing.allocator, file_path));
}

test {
    std.testing.refAllDecls(@This());
}
