// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P1 Task 1: byte-key ordered B+Tree + lazy ASC/DESC cursor.
//
// Correctness is critical: the tree backs ORDER BY results, so an in-order
// cursor walk MUST equal `std.sort` of the inserted (encoded_key) set, ASC and
// DESC must be exact reverses, and `seek(prefix)` must land at the first key
// >= prefix. All comparisons are byte-wise (`std.mem.order(u8, a, b)`).
//
// The tree OWNS heap copies of every key (dup on insert, free on remove/deinit),
// so these tests run under `testing.allocator` and any leak fails the run.

const std = @import("std");
const gs = @import("graph_storage");
const Tree = gs.ordered_btree.OrderedBTree;

const testing = std.testing;

fn keyLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Generate `n` DISTINCT random byte keys of varying length (1..=16 bytes)
/// using a deterministic PRNG. Caller owns each returned slice and the list.
fn genDistinctKeys(allocator: std.mem.Allocator, n: usize, seed: u64) !std.ArrayList([]u8) {
    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    while (keys.items.len < n) {
        const klen = rand.intRangeAtMost(usize, 1, 16);
        const buf = try allocator.alloc(u8, klen);
        for (buf) |*b| b.* = rand.int(u8);
        if (seen.contains(buf)) {
            allocator.free(buf);
            continue;
        }
        try seen.put(allocator, buf, {});
        try keys.append(allocator, buf);
    }
    return keys;
}

/// Build a sorted (ascending, byte-order) view over `keys` (shares slices).
fn sortedView(allocator: std.mem.Allocator, keys: []const []u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, keys.len);
    for (keys, 0..) |k, i| out[i] = k;
    std.mem.sort([]const u8, out, {}, keyLess);
    return out;
}

/// First index in ascending `sorted` whose key is >= `probe`, or null.
fn firstGE(sorted: []const []const u8, probe: []const u8) ?usize {
    for (sorted, 0..) |k, i| {
        if (std.mem.order(u8, k, probe) != .lt) return i;
    }
    return null;
}

test "forward cursor walk == std.sort ascending (N=1000 distinct varying-length keys)" {
    const n = 1000;
    var keys = try genDistinctKeys(testing.allocator, n, 0xA1B2C3D4);
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    for (keys.items, 0..) |k, i| try tree.insert(k, @intCast(i));

    try testing.expectEqual(@as(usize, n), tree.len());

    const sorted = try sortedView(testing.allocator, keys.items);
    defer testing.allocator.free(sorted);

    var cur = tree.cursor();
    cur.seek(""); // empty prefix <= every key → first entry
    var i: usize = 0;
    while (cur.next()) |e| : (i += 1) {
        try testing.expect(i < n);
        try testing.expectEqualSlices(u8, sorted[i], e.key);
    }
    try testing.expectEqual(@as(usize, n), i);
}

test "reverse cursor walk == std.sort descending" {
    const n = 1000;
    var keys = try genDistinctKeys(testing.allocator, n, 0x5566778899AABBCC);
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    for (keys.items, 0..) |k, i| try tree.insert(k, @intCast(i));

    const sorted = try sortedView(testing.allocator, keys.items);
    defer testing.allocator.free(sorted);

    var cur = tree.cursor();
    cur.seekToLast();
    var i: usize = 0;
    while (cur.prev()) |e| : (i += 1) {
        try testing.expect(i < n);
        // descending: sorted[n-1-i]
        try testing.expectEqualSlices(u8, sorted[n - 1 - i], e.key);
    }
    try testing.expectEqual(@as(usize, n), i);
}

test "seek(prefix) lands at first key >= prefix (before-all / after-all / exact / between)" {
    const n = 500;
    var keys = try genDistinctKeys(testing.allocator, n, 0x0F0F0F0F0F0F0F0F);
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    for (keys.items, 0..) |k, i| try tree.insert(k, @intCast(i));

    const sorted = try sortedView(testing.allocator, keys.items);
    defer testing.allocator.free(sorted);

    const Probe = struct { bytes: []const u8, owned: bool };
    var probes: std.ArrayList(Probe) = .empty;
    defer {
        for (probes.items) |p| if (p.owned) testing.allocator.free(p.bytes);
        probes.deinit(testing.allocator);
    }

    // before-all: empty prefix is <= every key.
    try probes.append(testing.allocator, .{ .bytes = "", .owned = false });
    // after-all: 17 bytes of 0xFF exceeds any 1..16-byte key.
    {
        const big = try testing.allocator.alloc(u8, 17);
        @memset(big, 0xFF);
        try probes.append(testing.allocator, .{ .bytes = big, .owned = true });
    }
    // exact hits at several positions.
    for ([_]usize{ 0, 1, n / 3, n / 2, n - 2, n - 1 }) |idx| {
        try probes.append(testing.allocator, .{ .bytes = sorted[idx], .owned = false });
    }
    // between: sorted[idx] ++ "\x00" (strictly greater than sorted[idx]).
    for ([_]usize{ 0, n / 4, n / 2, n - 2 }) |idx| {
        const b = try testing.allocator.alloc(u8, sorted[idx].len + 1);
        @memcpy(b[0..sorted[idx].len], sorted[idx]);
        b[sorted[idx].len] = 0x00;
        try probes.append(testing.allocator, .{ .bytes = b, .owned = true });
    }

    for (probes.items) |p| {
        var cur = tree.cursor();
        cur.seek(p.bytes);
        const got = cur.next();
        const want = firstGE(sorted, p.bytes);
        if (want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualSlices(u8, sorted[w], got.?.key);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "remove subset → walk excludes them, rest intact + ordered" {
    const n = 800;
    var keys = try genDistinctKeys(testing.allocator, n, 0xDEADBEEFCAFEF00D);
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    for (keys.items, 0..) |k, i| try tree.insert(k, @intCast(i));

    const sorted = try sortedView(testing.allocator, keys.items);
    defer testing.allocator.free(sorted);

    // Remove every 3rd key (by sorted position). Build expected survivors.
    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(testing.allocator);
    var removed_count: usize = 0;
    for (sorted, 0..) |k, idx| {
        if (idx % 3 == 0) {
            try testing.expect(tree.remove(k));
            removed_count += 1;
        } else {
            try expected.append(testing.allocator, k);
        }
    }
    // Removing an already-removed key returns false.
    try testing.expect(!tree.remove(sorted[0]));

    try testing.expectEqual(@as(usize, n - removed_count), tree.len());

    var cur = tree.cursor();
    cur.seek("");
    var i: usize = 0;
    while (cur.next()) |e| : (i += 1) {
        try testing.expect(i < expected.items.len);
        try testing.expectEqualSlices(u8, expected.items[i], e.key);
    }
    try testing.expectEqual(expected.items.len, i);
}

test "serialize → deserialize → walk identical (round-trip)" {
    const n = 600;
    var keys = try genDistinctKeys(testing.allocator, n, 0x1234567890ABCDEF);
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    for (keys.items, 0..) |k, i| try tree.insert(k, @intCast(i * 7 + 1));

    // Also remove a few so the round-trip covers a post-delete tree.
    const sorted = try sortedView(testing.allocator, keys.items);
    defer testing.allocator.free(sorted);
    var idx: usize = 0;
    while (idx < n) : (idx += 5) _ = tree.remove(sorted[idx]);

    const buf = try tree.serialize(testing.allocator);
    defer testing.allocator.free(buf);

    var loaded = try Tree.deserialize(testing.allocator, buf);
    defer loaded.deinit();

    try testing.expectEqual(tree.len(), loaded.len());

    var ca = tree.cursor();
    ca.seek("");
    var cb = loaded.cursor();
    cb.seek("");
    var count: usize = 0;
    while (true) {
        const a = ca.next();
        const b = cb.next();
        if (a == null and b == null) break;
        try testing.expect(a != null and b != null);
        try testing.expectEqualSlices(u8, a.?.key, b.?.key);
        try testing.expectEqual(a.?.node_id, b.?.node_id);
        count += 1;
    }
    try testing.expectEqual(tree.len(), count);
}

test {
    std.testing.refAllDecls(@This());
}
