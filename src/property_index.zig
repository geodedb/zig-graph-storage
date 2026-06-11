// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const btree_mod = @import("btree.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const LabelId = types.LabelId;
const NodeId = types.NodeId;

/// Concrete B+tree instantiation backing a property index: value-hash -> node-id.
/// Exposed so engine integration can load/save the underlying tree snapshot.
pub const BPlusTreeU64U64 = btree_mod.BPlusTree(u64, u64);

/// Property index backed by a B+tree.
/// Keys are hashes of property values; values are node IDs.
pub const PropertyIndex = struct {
    allocator: Allocator,
    tree: BPlusTreeU64U64,
    label_id: LabelId,
    property_key: []const u8,

    pub fn init(allocator: Allocator, label_id: LabelId, property_key: []const u8) !PropertyIndex {
        const key_copy = try allocator.dupe(u8, property_key);
        return .{
            .allocator = allocator,
            .tree = btree_mod.BPlusTree(u64, u64).init(allocator),
            .label_id = label_id,
            .property_key = key_copy,
        };
    }

    pub fn deinit(self: *PropertyIndex) void {
        self.tree.deinit();
        self.allocator.free(self.property_key);
    }

    /// Index a node's property value.
    pub fn insert(self: *PropertyIndex, node_id: NodeId, value_hash: u64) !void {
        try self.tree.insert(value_hash, node_id);
    }

    /// Remove a node from the index.
    pub fn remove(self: *PropertyIndex, _: NodeId, value_hash: u64) bool {
        return self.tree.delete(value_hash);
    }

    /// Find a node by exact property value hash.
    pub fn findExact(self: *const PropertyIndex, value_hash: u64) ?u64 {
        return self.tree.search(value_hash);
    }

    /// Find nodes by property value range.
    pub fn findRange(self: *const PropertyIndex, lo: u64, hi: u64, allocator: Allocator) ![]u64 {
        return try self.tree.range(lo, hi, allocator);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "insert + findExact" {
    var idx = try PropertyIndex.init(testing.allocator, 1, "name");
    defer idx.deinit();

    try idx.insert(100, 0xABCD);

    const result = idx.findExact(0xABCD);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 100), result.?);
}

test "findExact returns null for missing key" {
    var idx = try PropertyIndex.init(testing.allocator, 1, "name");
    defer idx.deinit();

    try testing.expect(idx.findExact(999) == null);
}

test "findRange returns correct results" {
    var idx = try PropertyIndex.init(testing.allocator, 1, "age");
    defer idx.deinit();

    try idx.insert(10, 100);
    try idx.insert(20, 200);
    try idx.insert(30, 300);
    try idx.insert(40, 400);

    const result = try idx.findRange(150, 350, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(u64, 20), result[0]);
    try testing.expectEqual(@as(u64, 30), result[1]);
}

test "remove + findExact returns null" {
    var idx = try PropertyIndex.init(testing.allocator, 1, "email");
    defer idx.deinit();

    try idx.insert(42, 0xFF);
    try testing.expect(idx.findExact(0xFF) != null);

    const removed = idx.remove(42, 0xFF);
    try testing.expect(removed);
    try testing.expect(idx.findExact(0xFF) == null);
}

test {
    std.testing.refAllDecls(@This());
}
