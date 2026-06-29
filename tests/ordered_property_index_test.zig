// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P1 Task 2: per-(label,key) ordered property index.
//
// The index owns one byte-key `OrderedBTree` per REGISTERED (label_id, key)
// pair. `insert` encodes a `PropertyValue` + node_id with the P0 order-
// preserving encoder, so an ASC/DESC cursor walk over a tree reproduces the
// engine's ORDER BY order. Correctness asserted here:
//   * ASC cursor == values ascending; DESC == exact reverse (orderable-only).
//   * a not-orderable value (decimal) is SKIPPED (no tree growth, no error).
//   * save -> load round-trips the snapshot counter and the exact cursor walk.
//   * an unregistered (label,key) is never indexed (openCursor returns null).
//
// All trees own heap copies of their keys, so the suite runs under
// `testing.allocator` and any leak fails the run.

const std = @import("std");
const gs = @import("graph_storage");

const OrderedPropertyIndex = gs.ordered_property_index.OrderedPropertyIndex;
const Direction = OrderedPropertyIndex.Direction;
const PropertyValue = gs.PropertyValue;
const ordered_encoding = gs.ordered_encoding;

const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();

/// Walk a (label,key) cursor in `dir`, decoding each composite key back into its
/// i64 value. Returns the values in cursor order (caller owns the list).
fn walkInts(
    idx: *OrderedPropertyIndex,
    label_id: u32,
    key: []const u8,
    dir: Direction,
    allocator: std.mem.Allocator,
) !std.ArrayList(i64) {
    var out: std.ArrayList(i64) = .empty;
    errdefer out.deinit(allocator);
    var cursor = idx.openCursor(label_id, key, dir) orelse return out;
    while (cursor.next()) |entry| {
        var decoded = try ordered_encoding.decode(allocator, entry.key);
        defer decoded.deinit(allocator);
        try out.append(allocator, decoded.value.int);
    }
    return out;
}

test "ASC/DESC cursor reproduces sorted value order (orderable-only)" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    const label: u32 = 1;
    const key = "score";
    try idx.registerIndex(label, key);

    // Insert ints out of order, each on a distinct node.
    try idx.insert(label, key, .{ .int = 5 }, 100);
    try idx.insert(label, key, .{ .int = -3 }, 101);
    try idx.insert(label, key, .{ .int = 100 }, 102);
    try idx.insert(label, key, .{ .int = 0 }, 103);
    try idx.insert(label, key, .{ .int = 42 }, 104);

    try testing.expectEqual(@as(?usize, 5), idx.treeLen(label, key));

    var asc = try walkInts(&idx, label, key, .asc, testing.allocator);
    defer asc.deinit(testing.allocator);
    try testing.expectEqualSlices(i64, &[_]i64{ -3, 0, 5, 42, 100 }, asc.items);

    var desc = try walkInts(&idx, label, key, .desc, testing.allocator);
    defer desc.deinit(testing.allocator);
    try testing.expectEqualSlices(i64, &[_]i64{ 100, 42, 5, 0, -3 }, desc.items);
}

test "not-orderable value (decimal) is skipped" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    const label: u32 = 7;
    const key = "amount";
    try idx.registerIndex(label, key);

    try idx.insert(label, key, .{ .int = 1 }, 1);
    try idx.insert(label, key, .{ .int = 2 }, 2);
    // decimal has no order-preserving encoding -> orderable() == false -> skip.
    try idx.insert(label, key, .{ .decimal = .{ .coeff = 999, .scale = 2 } }, 3);
    // NaN float likewise.
    try idx.insert(label, key, .{ .float = std.math.nan(f64) }, 4);

    // Only the two ints were indexed.
    try testing.expectEqual(@as(?usize, 2), idx.treeLen(label, key));
}

test "unregistered (label,key) is never indexed" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    // No registerIndex call -> insert is a no-op, openCursor returns null.
    try idx.insert(3, "nope", .{ .int = 1 }, 1);
    try testing.expect(idx.treeLen(3, "nope") == null);
    try testing.expect(idx.openCursor(3, "nope", .asc) == null);
}

test "remove drops the entry from the cursor walk" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    const label: u32 = 1;
    const key = "score";
    try idx.registerIndex(label, key);

    try idx.insert(label, key, .{ .int = 5 }, 100);
    try idx.insert(label, key, .{ .int = -3 }, 101);
    try idx.insert(label, key, .{ .int = 42 }, 104);

    try idx.remove(label, key, .{ .int = 5 }, 100);
    try testing.expectEqual(@as(?usize, 2), idx.treeLen(label, key));

    var asc = try walkInts(&idx, label, key, .asc, testing.allocator);
    defer asc.deinit(testing.allocator);
    try testing.expectEqualSlices(i64, &[_]i64{ -3, 42 }, asc.items);
}

test "save -> load round-trips counter and the cursor walk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    const label_a: u32 = 1;
    const label_b: u32 = 2;
    const counter: u64 = 77;

    {
        var idx = OrderedPropertyIndex.init(testing.allocator);
        defer idx.deinit();

        try idx.registerIndex(label_a, "score");
        try idx.registerIndex(label_b, "rank");
        try idx.insert(label_a, "score", .{ .int = 5 }, 100);
        try idx.insert(label_a, "score", .{ .int = -3 }, 101);
        try idx.insert(label_a, "score", .{ .int = 42 }, 102);
        try idx.insert(label_b, "rank", .{ .int = 9 }, 200);
        try idx.insert(label_b, "rank", .{ .int = 1 }, 201);

        try idx.saveToFile(dir_path, counter);
    }

    {
        var idx = OrderedPropertyIndex.init(testing.allocator);
        defer idx.deinit();

        const loaded = try idx.loadFromFile(dir_path);
        try testing.expectEqual(@as(?u64, counter), loaded);

        try testing.expectEqual(@as(?usize, 3), idx.treeLen(label_a, "score"));
        try testing.expectEqual(@as(?usize, 2), idx.treeLen(label_b, "rank"));

        var a = try walkInts(&idx, label_a, "score", .asc, testing.allocator);
        defer a.deinit(testing.allocator);
        try testing.expectEqualSlices(i64, &[_]i64{ -3, 5, 42 }, a.items);

        var b = try walkInts(&idx, label_b, "rank", .desc, testing.allocator);
        defer b.deinit(testing.allocator);
        try testing.expectEqualSlices(i64, &[_]i64{ 9, 1 }, b.items);
    }
}

test "loadFromFile returns null when no snapshot exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    try testing.expectEqual(@as(?u64, null), try idx.loadFromFile(dir_path));
}
