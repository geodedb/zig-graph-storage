// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P0: order-preserving value encoder — exhaustive ordering tests.
//
// The encoder's total order MUST equal the engine's ORDER BY order. The engine
// comparator is `entryLess` in geode src/execution/match_operations.zig. The
// `logicalCmp` reference below mirrors that documented order for the
// homogeneous-typed (engine-eligible) cases, plus the chosen TYPE_RANK for the
// cross-type cases (which are NOT engine-parity-eligible and fall back to the
// heap in the planner; the rank exists only so a mixed tree stays well-formed).
//
// Documented entryLess order (the spec this file encodes):
//   * str vs str   -> std.mem.order(u8) (byte / UTF-8 code-point order; NO collation)
//   * numeric vs str -> numeric < string
//   * int vs int   -> i64 numeric (lossless)
//   * any float    -> both coerced to f64, `af < bf` (-0.0 == +0.0; NaN unordered)
//   * bool, null   -> entryLess never sees them (engine skips before heap insert)
//
// Encoder parity holds for: homogeneous int, homogeneous float (finite + +/-inf,
// -0.0 normalized to +0.0), homogeneous string. NOT parity-eligible: NaN
// (engine has no stable position -> orderable()==false), mixed numeric int/float
// (engine unifies via f64; encoder type-separates), bool/null (engine drops
// them), decimal/ext (orderable()==false).

const std = @import("std");
const gs = @import("graph_storage");
const oe = gs.ordered_encoding;
const PropertyValue = gs.PropertyValue;

// TYPE_RANK mirror (must match src/ordered_encoding.zig).
const RANK_BOOL: u8 = 0x10;
const RANK_INT: u8 = 0x20;
const RANK_FLOAT: u8 = 0x30;
const RANK_STRING: u8 = 0x40;
const RANK_NULL: u8 = 0xF0;

fn rankOf(v: PropertyValue) u8 {
    return switch (v) {
        .bool => RANK_BOOL,
        .int => RANK_INT,
        .float => RANK_FLOAT,
        .string => RANK_STRING,
        .null => RANK_NULL,
        .decimal, .ext => unreachable, // never in the encodable test set
    };
}

/// Reference logical order over PropertyValue (value only, no node_id).
/// Mirrors entryLess for homogeneous types; uses TYPE_RANK for cross-type.
/// Precondition: floats are non-NaN (NaN is not encodable / not orderable).
fn logicalCmp(a: PropertyValue, b: PropertyValue) std.math.Order {
    const ra = rankOf(a);
    const rb = rankOf(b);
    if (ra != rb) return std.math.order(ra, rb);
    return switch (a) {
        .bool => |av| std.math.order(@intFromBool(av), @intFromBool(b.bool)),
        .int => |av| std.math.order(av, b.int),
        .float => |av| blk: {
            // Normalize -0.0 to +0.0 so -0.0 == +0.0 (matches entryLess `af<bf`).
            const x: f64 = if (av == 0.0) 0.0 else av;
            const y: f64 = if (b.float == 0.0) 0.0 else b.float;
            break :blk std.math.order(x, y);
        },
        .string => |av| std.mem.order(u8, av, b.string),
        .null => .eq,
        .decimal, .ext => unreachable,
    };
}

const Item = struct { v: PropertyValue, id: u64 };

fn fullCmp(a: Item, b: Item) std.math.Order {
    const o = logicalCmp(a.v, b.v);
    if (o != .eq) return o;
    return std.math.order(a.id, b.id);
}

fn sign(o: std.math.Order) i2 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn memSign(a: []const u8, b: []const u8) i2 {
    return sign(std.mem.order(u8, a, b));
}

/// Core invariant check over an explicit item set: for every ordered pair,
/// sign(memcmp(enc a, enc b)) == sign(fullCmp(a, b)).
fn assertAllPairs(alloc: std.mem.Allocator, items: []const Item) !void {
    const encs = try alloc.alloc([]u8, items.len);
    defer {
        for (encs) |e| alloc.free(e);
        alloc.free(encs);
    }
    for (items, 0..) |it, i| {
        encs[i] = try oe.encodeOrdered(alloc, it.v, it.id);
    }
    for (items, 0..) |a, i| {
        for (items, 0..) |b, j| {
            const got = memSign(encs[i], encs[j]);
            const want = sign(fullCmp(a, b));
            if (got != want) {
                std.debug.print(
                    "ORDER MISMATCH: i={d} j={d} got={d} want={d}\n",
                    .{ i, j, got, want },
                );
                return error.OrderMismatch;
            }
        }
    }
}

fn buildBaseSet(alloc: std.mem.Allocator, list: *std.ArrayList(Item)) !void {
    var id: u64 = 1;
    const ints = [_]i64{
        std.math.minInt(i64), std.math.minInt(i64) + 1, -1_000_000, -2,        -1,
        0,                    1,                        2,          1_000_000, std.math.maxInt(i64) - 1,
        std.math.maxInt(i64),
    };
    for (ints) |iv| {
        try list.append(alloc, .{ .v = .{ .int = iv }, .id = id });
        id += 1;
    }

    const floats = [_]f64{
        -std.math.inf(f64),
        -std.math.floatMax(f64),
        -1.5,
        -std.math.floatMin(f64), // smallest negative normal
        -std.math.floatTrueMin(f64), // negative subnormal
        -0.0,
        0.0,
        std.math.floatTrueMin(f64), // positive subnormal
        std.math.floatMin(f64), // smallest positive normal
        1.5,
        std.math.floatMax(f64),
        std.math.inf(f64),
    };
    for (floats) |fv| {
        try list.append(alloc, .{ .v = .{ .float = fv }, .id = id });
        id += 1;
    }

    const strings = [_][]const u8{
        "",   "a",    "ab",    "abc",    "b",
        "ba", "\x00", "a\x00", "a\x00b", "a\x01",
        "z", "zz", "\u{00e9}", // é (multibyte UTF-8)
        "\u{1f600}", // emoji (4-byte)
        "\u{00ff}",
    };
    for (strings) |sv| {
        try list.append(alloc, .{ .v = .{ .string = sv }, .id = id });
        id += 1;
    }

    try list.append(alloc, .{ .v = .{ .bool = false }, .id = id });
    id += 1;
    try list.append(alloc, .{ .v = .{ .bool = true }, .id = id });
    id += 1;
    try list.append(alloc, .{ .v = .null, .id = id });
    id += 1;
}

test "all-pairs: encode order == logical (engine) order over the full typed value set" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(Item) = .empty;
    defer list.deinit(alloc);
    try buildBaseSet(alloc, &list);
    try assertAllPairs(alloc, list.items);
}

test "tie-break by node_id on equal values" {
    const alloc = std.testing.allocator;
    const items = [_]Item{
        .{ .v = .{ .int = 7 }, .id = 1 },
        .{ .v = .{ .int = 7 }, .id = 2 },
        .{ .v = .{ .int = 7 }, .id = 100 },
        .{ .v = .{ .float = -0.0 }, .id = 5 },
        .{ .v = .{ .float = 0.0 }, .id = 6 },
        .{ .v = .{ .string = "x" }, .id = 9 },
        .{ .v = .{ .string = "x" }, .id = 10 },
    };
    try assertAllPairs(alloc, &items);
}

test "explicit edges: negative < positive ints; -0.0 == +0.0; a<ab<b; null position" {
    const alloc = std.testing.allocator;
    // neg < pos
    {
        const en = try oe.encodeOrdered(alloc, .{ .int = -1 }, 0);
        defer alloc.free(en);
        const ep = try oe.encodeOrdered(alloc, .{ .int = 1 }, 0);
        defer alloc.free(ep);
        try std.testing.expect(std.mem.order(u8, en, ep) == .lt);
    }
    // -0.0 vs +0.0 with same node_id -> identical encoding (engine tie)
    {
        const eneg = try oe.encodeOrdered(alloc, .{ .float = -0.0 }, 42);
        defer alloc.free(eneg);
        const epos = try oe.encodeOrdered(alloc, .{ .float = 0.0 }, 42);
        defer alloc.free(epos);
        try std.testing.expect(std.mem.order(u8, eneg, epos) == .eq);
    }
    // "a" < "ab" < "b"
    {
        const a = try oe.encodeOrdered(alloc, .{ .string = "a" }, 0);
        defer alloc.free(a);
        const ab = try oe.encodeOrdered(alloc, .{ .string = "ab" }, 0);
        defer alloc.free(ab);
        const b = try oe.encodeOrdered(alloc, .{ .string = "b" }, 0);
        defer alloc.free(b);
        try std.testing.expect(std.mem.order(u8, a, ab) == .lt);
        try std.testing.expect(std.mem.order(u8, ab, b) == .lt);
    }
    // embedded NUL: "a" < "a\x00" (prefix sorts first)
    {
        const a = try oe.encodeOrdered(alloc, .{ .string = "a" }, 0);
        defer alloc.free(a);
        const an = try oe.encodeOrdered(alloc, .{ .string = "a\x00" }, 0);
        defer alloc.free(an);
        try std.testing.expect(std.mem.order(u8, a, an) == .lt);
    }
    // null sorts after everything (highest TYPE_RANK)
    {
        const big = try oe.encodeOrdered(alloc, .{ .string = "zzzz" }, std.math.maxInt(u64));
        defer alloc.free(big);
        const nul = try oe.encodeOrdered(alloc, .null, 0);
        defer alloc.free(nul);
        try std.testing.expect(std.mem.order(u8, big, nul) == .lt);
    }
}

test "orderable(): decimal/ext/NaN are NOT index-eligible" {
    try std.testing.expect(!oe.orderable(.{ .decimal = .{ .coeff = 100, .scale = 2 } }));
    try std.testing.expect(!oe.orderable(.{ .ext = .{ .type_tag = 1, .data = "" } }));
    try std.testing.expect(!oe.orderable(.{ .float = std.math.nan(f64) }));
    // eligible types
    try std.testing.expect(oe.orderable(.{ .int = 0 }));
    try std.testing.expect(oe.orderable(.{ .float = 1.0 }));
    try std.testing.expect(oe.orderable(.{ .float = std.math.inf(f64) }));
    try std.testing.expect(oe.orderable(.{ .string = "x" }));
    try std.testing.expect(oe.orderable(.{ .bool = true }));
    try std.testing.expect(oe.orderable(.null));
}

test "encodeOrdered returns error.NotOrderable for decimal/ext/NaN" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.NotOrderable, oe.encodeOrdered(alloc, .{ .decimal = .{ .coeff = 1, .scale = 0 } }, 0));
    try std.testing.expectError(error.NotOrderable, oe.encodeOrdered(alloc, .{ .ext = .{ .type_tag = 0, .data = "" } }, 0));
    try std.testing.expectError(error.NotOrderable, oe.encodeOrdered(alloc, .{ .float = std.math.nan(f64) }, 0));
}

// ---------------------------------------------------------------------------
// Task 4: deterministic fuzz / property test.
// ---------------------------------------------------------------------------

fn randomItem(rng: std.Random, arena: std.mem.Allocator) !Item {
    const id = rng.int(u64);
    const which = rng.uintLessThan(u8, 5);
    return switch (which) {
        0 => .{ .v = .{ .int = rng.int(i64) }, .id = id },
        1 => blk: {
            // Random finite-or-inf float, never NaN.
            var f: f64 = @bitCast(rng.int(u64));
            if (std.math.isNan(f)) f = 0.0;
            break :blk .{ .v = .{ .float = f }, .id = id };
        },
        2 => blk: {
            const len = rng.uintLessThan(usize, 12);
            const buf = try arena.alloc(u8, len);
            for (buf) |*c| c.* = rng.int(u8); // includes embedded 0x00
            break :blk .{ .v = .{ .string = buf }, .id = id };
        },
        3 => .{ .v = .{ .bool = rng.boolean() }, .id = id },
        else => .{ .v = .null, .id = id },
    };
}

test "fuzz: encode order == logical order across many deterministic seeds" {
    const seeds = [_]u64{
        0x0,                0x1,                0xDEADBEEF,
        0xCAFEBABE,         0x1234567890ABCDEF, 0xFFFFFFFFFFFFFFFF,
        0x5555555555555555, 0xAAAAAAAAAAAAAAAA, 0x0F0F0F0F0F0F0F0F,
        42,                 1337,               2026,
    };
    for (seeds) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const n: usize = 64;
        const items = try arena.alloc(Item, n);
        for (items) |*it| it.* = try randomItem(rng, arena);

        try assertAllPairs(arena, items);
    }
}

test "round-trip: decode recovers value + node_id for eligible types" {
    const alloc = std.testing.allocator;
    const cases = [_]Item{
        .{ .v = .{ .int = std.math.minInt(i64) }, .id = 1 },
        .{ .v = .{ .int = 0 }, .id = 2 },
        .{ .v = .{ .int = std.math.maxInt(i64) }, .id = 3 },
        .{ .v = .{ .float = -1.5 }, .id = 4 },
        .{ .v = .{ .float = std.math.inf(f64) }, .id = 5 },
        .{ .v = .{ .bool = true }, .id = 6 },
        .{ .v = .null, .id = 7 },
        .{ .v = .{ .string = "hello\x00world" }, .id = 8 },
    };
    for (cases) |c| {
        const enc = try oe.encodeOrdered(alloc, c.v, c.id);
        defer alloc.free(enc);
        const dec = try oe.decode(alloc, enc);
        defer dec.deinit(alloc);
        try std.testing.expectEqual(c.id, dec.node_id);
        switch (c.v) {
            .int => |iv| try std.testing.expectEqual(iv, dec.value.int),
            .float => |fv| try std.testing.expectEqual(fv, dec.value.float),
            .bool => |bv| try std.testing.expectEqual(bv, dec.value.bool),
            .null => try std.testing.expect(dec.value == .null),
            .string => |sv| try std.testing.expectEqualStrings(sv, dec.value.string),
            else => unreachable,
        }
    }
}
