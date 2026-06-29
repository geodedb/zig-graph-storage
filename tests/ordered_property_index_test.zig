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

// ── ORDER BY eligibility flag (safe index-served ORDER BY planning) ──────────
//
// `isEligible(label,key)` tells the planner whether ORDER BY can be served from
// the ordered index with full engine parity (no missing / mis-ordered rows). The
// rule (see applyEligibility): eligible iff EVERY value is orderable AND shares a
// single order-class, with bool/null columns excluded (the engine drops them).

/// Walk a (label,key) ASC cursor, decoding each composite key back to its string
/// value. Returns the values in cursor order (caller owns the list + items).
fn walkStrings(
    idx: *OrderedPropertyIndex,
    label_id: u32,
    key: []const u8,
    allocator: std.mem.Allocator,
) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var cursor = idx.openCursor(label_id, key, .asc) orelse return out;
    while (cursor.next()) |entry| {
        const decoded = try ordered_encoding.decode(allocator, entry.key);
        // Hand ownership of the string to the list (don't deinit decoded here).
        try out.append(allocator, @constCast(decoded.value.string));
    }
    return out;
}

test "eligibility: homogeneous string column is eligible and cursor returns all in order" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    const label: u32 = 1;
    const key = "name";
    try idx.registerIndex(label, key);

    try idx.insert(label, key, .{ .string = "delta" }, 1);
    try idx.insert(label, key, .{ .string = "alpha" }, 2);
    try idx.insert(label, key, .{ .string = "charlie" }, 3);
    try idx.insert(label, key, .{ .string = "bravo" }, 4);

    try testing.expect(idx.isEligible(label, key));
    try testing.expectEqual(@as(?usize, 4), idx.treeLen(label, key));

    var got = try walkStrings(&idx, label, key, testing.allocator);
    defer {
        for (got.items) |s| testing.allocator.free(s);
        got.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 4), got.items.len);
    try testing.expectEqualStrings("alpha", got.items[0]);
    try testing.expectEqualStrings("bravo", got.items[1]);
    try testing.expectEqualStrings("charlie", got.items[2]);
    try testing.expectEqualStrings("delta", got.items[3]);
}

test "eligibility: a decimal value mixed in makes the column ineligible" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    const label: u32 = 2;
    const key = "amount";
    try idx.registerIndex(label, key);

    try idx.insert(label, key, .{ .int = 1 }, 1);
    try idx.insert(label, key, .{ .int = 2 }, 2);
    try testing.expect(idx.isEligible(label, key)); // homogeneous int so far

    // A decimal is not-orderable: it is SKIPPED (missing row) -> ineligible.
    try idx.insert(label, key, .{ .decimal = .{ .coeff = 999, .scale = 2 } }, 3);
    try testing.expect(!idx.isEligible(label, key));
    try testing.expectEqual(@as(?usize, 2), idx.treeLen(label, key)); // decimal not stored
}

test "eligibility: mixed int+float column is ineligible (encoder type-separates; engine f64-unifies)" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    const label: u32 = 3;
    const key = "measure";
    try idx.registerIndex(label, key);

    try idx.insert(label, key, .{ .int = 10 }, 1);
    try testing.expect(idx.isEligible(label, key));
    try idx.insert(label, key, .{ .float = 2.5 }, 2);
    try testing.expect(!idx.isEligible(label, key));

    // Both are still stored (both orderable), but parity is lost -> ineligible.
    try testing.expectEqual(@as(?usize, 2), idx.treeLen(label, key));
}

test "eligibility: bool and null columns are ineligible (engine drops them from ORDER BY)" {
    var idx = OrderedPropertyIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.registerIndex(1, "flag");
    try idx.insert(1, "flag", .{ .bool = true }, 1);
    try idx.insert(1, "flag", .{ .bool = false }, 2);
    try testing.expect(!idx.isEligible(1, "flag"));

    try idx.registerIndex(2, "missing");
    try idx.insert(2, "missing", .null, 10);
    try idx.insert(2, "missing", .null, 11);
    try testing.expect(!idx.isEligible(2, "missing"));

    // An int column with a single null mixed in is also ineligible.
    try idx.registerIndex(3, "score");
    try idx.insert(3, "score", .{ .int = 5 }, 20);
    try testing.expect(idx.isEligible(3, "score"));
    try idx.insert(3, "score", .null, 21);
    try testing.expect(!idx.isEligible(3, "score"));
}

test "eligibility: survives save -> load and is recomputed by a clearTrees rebuild" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    const counter: u64 = 88;
    const L_ok: u32 = 1; // homogeneous int -> eligible
    const L_bad: u32 = 2; // int+float -> ineligible

    {
        var idx = OrderedPropertyIndex.init(testing.allocator);
        defer idx.deinit();
        try idx.registerIndex(L_ok, "score");
        try idx.registerIndex(L_bad, "measure");
        try idx.insert(L_ok, "score", .{ .int = 1 }, 1);
        try idx.insert(L_ok, "score", .{ .int = 2 }, 2);
        try idx.insert(L_bad, "measure", .{ .int = 1 }, 3);
        try idx.insert(L_bad, "measure", .{ .float = 1.5 }, 4);

        try testing.expect(idx.isEligible(L_ok, "score"));
        try testing.expect(!idx.isEligible(L_bad, "measure"));
        try idx.saveToFile(dir_path, counter);
    }

    {
        var idx = OrderedPropertyIndex.init(testing.allocator);
        defer idx.deinit();
        const loaded = try idx.loadFromFile(dir_path);
        try testing.expectEqual(@as(?u64, counter), loaded);

        // Restored from the snapshot, not recomputed.
        try testing.expect(idx.isEligible(L_ok, "score"));
        try testing.expect(!idx.isEligible(L_bad, "measure"));

        // A rebuild (clearTrees) resets eligibility to true; re-inserting only
        // homogeneous values recomputes it back to eligible for BOTH (proving
        // the flag reflects the CURRENT data, not the stale snapshot).
        idx.clearTrees();
        try testing.expect(idx.isEligible(L_ok, "score")); // reset to true, no values yet
        try idx.insert(L_ok, "score", .{ .int = 7 }, 1);
        try idx.insert(L_bad, "measure", .{ .int = 9 }, 3); // now homogeneous int
        try testing.expect(idx.isEligible(L_ok, "score"));
        try testing.expect(idx.isEligible(L_bad, "measure")); // recomputed -> eligible

        // And a rebuild that re-scans a not-orderable value flips it false again.
        idx.clearTrees();
        try idx.insert(L_ok, "score", .{ .int = 7 }, 1);
        try idx.insert(L_ok, "score", .{ .float = std.math.nan(f64) }, 2);
        try testing.expect(!idx.isEligible(L_ok, "score")); // NaN -> ineligible
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
