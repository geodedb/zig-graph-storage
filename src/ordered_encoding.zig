// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # Order-preserving value encoder (H3-P0)
//!
//! Encodes a `PropertyValue` + `node_id` into a composite byte key such that
//! `std.mem.order(u8, enc(a), enc(b))` (i.e. plain `memcmp`) reproduces the
//! SAME total order the engine's `ORDER BY` uses. This is the foundation of the
//! value-ordered index (H3): later phases store these keys in a B+Tree, so the
//! tree's natural byte order IS the query order — no per-key comparator needed.
//!
//! ## Composite key layout
//!
//!     TYPE_RANK (1 byte) ‖ type_payload ‖ node_id (8 bytes, big-endian)
//!
//! The `node_id` suffix makes every key unique and breaks value ties by
//! `node_id` (matching how the engine's stable sort settles equal values), so
//! no posting lists are required.
//!
//! ## Parity with the engine comparator
//!
//! The engine orders ORDER BY rows with `entryLess` in geode
//! `src/execution/match_operations.zig`. Its rules:
//!   * string vs string -> `std.mem.order(u8, ...)` — byte / UTF-8 code-point
//!     order. NO locale collation.
//!   * numeric vs string -> numeric sorts before string.
//!   * int vs int -> lossless i64 `<`.
//!   * any pair involving a float (float/float OR int/float) -> both coerced to
//!     `f64`, compared with `af < bf` (so `-0.0 == +0.0`; NaN is unordered).
//!   * bool / null -> `entryLess` NEVER sees them: the scan skips bool/null (and
//!     ext) values before heap insertion, and coerces decimal to f64.
//!
//! This encoder reproduces that order for the **engine-eligible** cases:
//! homogeneous int columns, homogeneous float columns (finite, ±inf, with
//! `-0.0` normalized to `+0.0`), and homogeneous string columns.
//!
//! ### NOT index-eligible (documented divergences)
//!   * **decimal, ext** -> no defined byte order here; `orderable()` returns
//!     false and `encodeOrdered` returns `error.NotOrderable`. Planner falls
//!     back to the heap.
//!   * **NaN float** -> the engine gives NaN no stable position (`af < bf` is
//!     false in both directions). A byte encoding cannot reproduce "unordered",
//!     so a NaN value is treated as not-orderable: `orderable()` returns false
//!     and `encodeOrdered` returns `error.NotOrderable`.
//!   * **mixed int + float in one column** -> the engine unifies via f64; this
//!     encoder type-separates (distinct TYPE_RANK for int vs float), so the
//!     planner must NOT use the index for mixed-numeric columns (heap fallback).
//!   * **bool, null** -> the engine drops these from ORDER BY entirely. This
//!     encoder still assigns them a well-defined TYPE_RANK + payload so a mixed
//!     tree stays well-formed, but the planner gains no engine-parity guarantee
//!     for them (using the index here would surface rows the engine omits).

const std = @import("std");
const types = @import("types.zig");

pub const PropertyValue = types.PropertyValue;

/// TYPE_RANK: the leading byte of every composite key. Ordering between ranks
/// only matters for non-eligible mixed-type columns (kept well-formed, not
/// engine-parity). For the engine-eligible numeric-before-string relation,
/// note int/float ranks both precede string. Sparse values leave room.
pub const TypeRank = struct {
    pub const bool_: u8 = 0x10;
    pub const int: u8 = 0x20;
    pub const float: u8 = 0x30;
    pub const string: u8 = 0x40;
    pub const null_: u8 = 0xF0;
};

const SIGN_BIT: u64 = 0x8000_0000_0000_0000;

pub const EncodeError = error{NotOrderable} || std.mem.Allocator.Error;

/// Whether a value has a byte-encoding that reproduces the engine's ORDER BY
/// order. Type-level exclusions: decimal, ext. Value-level exclusion: NaN
/// floats (the engine has no stable order for them).
pub fn orderable(value: PropertyValue) bool {
    return switch (value) {
        .int, .bool, .null, .string => true,
        .float => |f| !std.math.isNan(f),
        .decimal, .ext => false,
    };
}

/// Encode `value` + `node_id` into a freshly-allocated, order-preserving
/// composite key. Caller owns the returned slice. Returns `error.NotOrderable`
/// for values `orderable()` rejects (decimal, ext, NaN).
pub fn encodeOrdered(
    allocator: std.mem.Allocator,
    value: PropertyValue,
    node_id: u64,
) EncodeError![]u8 {
    if (!orderable(value)) return error.NotOrderable;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    switch (value) {
        .bool => |b| {
            try buf.append(allocator, TypeRank.bool_);
            try buf.append(allocator, if (b) 0x01 else 0x00);
        },
        .int => |i| {
            try buf.append(allocator, TypeRank.int);
            try appendU64BE(allocator, &buf, encodeIntKey(i));
        },
        .float => |f| {
            try buf.append(allocator, TypeRank.float);
            try appendU64BE(allocator, &buf, encodeFloatKey(f));
        },
        .string => |s| {
            try buf.append(allocator, TypeRank.string);
            try appendEscapedString(allocator, &buf, s);
        },
        .null => {
            try buf.append(allocator, TypeRank.null_);
        },
        .decimal, .ext => unreachable, // filtered by orderable() above
    }

    // node_id suffix (big-endian) — uniqueness + value-tie break.
    try appendU64BE(allocator, &buf, node_id);

    return buf.toOwnedSlice(allocator);
}

/// i64 -> order-preserving u64: flip the sign bit so two's-complement negatives
/// (high bit set) sort before non-negatives under unsigned big-endian memcmp.
pub fn encodeIntKey(i: i64) u64 {
    return @as(u64, @bitCast(i)) ^ SIGN_BIT;
}

/// f64 -> order-preserving u64 (IEEE-754 total order, minus NaN handling which
/// is excluded upstream). `-0.0` is normalized to `+0.0` so they encode
/// identically (the engine treats them equal). For negative floats the bit
/// pattern is inverted; for non-negative the sign bit is set. Result: ascending
/// unsigned big-endian memcmp == ascending numeric order.
pub fn encodeFloatKey(f_in: f64) u64 {
    // Normalize -0.0 -> +0.0 (engine: -0.0 == +0.0).
    const f: f64 = if (f_in == 0.0) 0.0 else f_in;
    const bits: u64 = @bitCast(f);
    return if (bits >> 63 == 1) ~bits else (bits | SIGN_BIT);
}

fn appendU64BE(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .big);
    try buf.appendSlice(allocator, &tmp);
}

/// String payload: each `0x00` byte -> `0x00 0xFF`; then terminate with
/// `0x00 0x00`. The terminator is strictly less than any escaped-NUL (`0x00
/// 0xFF`) or any real content byte, so a prefix sorts before its extensions and
/// the node_id suffix can never be confused with content. memcmp over the
/// payload == byte / code-point order of the UTF-8 string.
fn appendEscapedString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c == 0x00) {
            try buf.append(allocator, 0x00);
            try buf.append(allocator, 0xFF);
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, 0x00);
    try buf.append(allocator, 0x00);
}

// ===========================================================================
// Decode (round-trip helper; not on any hot path)
// ===========================================================================

pub const Decoded = struct {
    value: PropertyValue,
    node_id: u64,

    /// Frees an owned string payload if present.
    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        switch (self.value) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

pub const DecodeError = error{ MalformedKey, NotOrderable } || std.mem.Allocator.Error;

/// Inverse of `encodeOrdered` for the eligible types. The trailing 8 bytes are
/// the big-endian node_id; the leading byte is the TYPE_RANK. String payloads
/// are unescaped into a freshly-allocated slice (caller frees via `deinit`).
pub fn decode(allocator: std.mem.Allocator, key: []const u8) DecodeError!Decoded {
    if (key.len < 1 + 8) return error.MalformedKey;
    const rank = key[0];
    const node_id = std.mem.readInt(u64, key[key.len - 8 ..][0..8], .big);
    const payload = key[1 .. key.len - 8];

    switch (rank) {
        TypeRank.bool_ => {
            if (payload.len != 1) return error.MalformedKey;
            return .{ .value = .{ .bool = payload[0] != 0 }, .node_id = node_id };
        },
        TypeRank.int => {
            if (payload.len != 8) return error.MalformedKey;
            const k = std.mem.readInt(u64, payload[0..8], .big);
            return .{ .value = .{ .int = @bitCast(k ^ SIGN_BIT) }, .node_id = node_id };
        },
        TypeRank.float => {
            if (payload.len != 8) return error.MalformedKey;
            const k = std.mem.readInt(u64, payload[0..8], .big);
            const bits: u64 = if (k >> 63 == 1) (k & ~SIGN_BIT) else ~k;
            return .{ .value = .{ .float = @bitCast(bits) }, .node_id = node_id };
        },
        TypeRank.string => {
            const s = try decodeEscapedString(allocator, payload);
            return .{ .value = .{ .string = s }, .node_id = node_id };
        },
        TypeRank.null_ => {
            if (payload.len != 0) return error.MalformedKey;
            return .{ .value = .null, .node_id = node_id };
        },
        else => return error.MalformedKey,
    }
}

fn decodeEscapedString(allocator: std.mem.Allocator, payload: []const u8) DecodeError![]u8 {
    // Strip the trailing 0x00 0x00 terminator.
    if (payload.len < 2 or payload[payload.len - 2] != 0x00 or payload[payload.len - 1] != 0x00) {
        return error.MalformedKey;
    }
    const body = payload[0 .. payload.len - 2];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == 0x00) {
            // Must be an escaped NUL: 0x00 0xFF.
            if (i + 1 >= body.len or body[i + 1] != 0xFF) return error.MalformedKey;
            try out.append(allocator, 0x00);
            i += 2;
        } else {
            try out.append(allocator, body[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ===========================================================================
// Unit tests (module-local sanity; the exhaustive suite lives in
// tests/ordered_encoding_test.zig).
// ===========================================================================

test "int key sign-flip orders negatives before positives" {
    try std.testing.expect(encodeIntKey(-1) < encodeIntKey(0));
    try std.testing.expect(encodeIntKey(std.math.minInt(i64)) < encodeIntKey(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(u64, 0), encodeIntKey(std.math.minInt(i64)));
}

test "float key -0.0 normalizes to +0.0" {
    try std.testing.expectEqual(encodeFloatKey(0.0), encodeFloatKey(-0.0));
    try std.testing.expect(encodeFloatKey(-1.0) < encodeFloatKey(1.0));
    try std.testing.expect(encodeFloatKey(-std.math.inf(f64)) < encodeFloatKey(std.math.inf(f64)));
}

test "orderable rejects decimal/ext/NaN" {
    try std.testing.expect(!orderable(.{ .decimal = .{ .coeff = 1, .scale = 0 } }));
    try std.testing.expect(!orderable(.{ .ext = .{ .type_tag = 0, .data = "" } }));
    try std.testing.expect(!orderable(.{ .float = std.math.nan(f64) }));
    try std.testing.expect(orderable(.{ .int = 0 }));
}
