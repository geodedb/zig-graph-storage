// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");

pub const PropertyValue = types.PropertyValue;
pub const Allocator = std.mem.Allocator;

/// Tag bytes for property value encoding.
pub const Tag = enum(u8) {
    null = 0,
    bool = 1,
    int = 2,
    float = 3,
    string = 4,
    decimal = 5,
    ext = 6,
    /// OVERFLOW STUB — never a `PropertyValue` variant. A value whose encoded
    /// form does not fit the per-page property entry budget is written to a
    /// var-store chain and the property entry holds a fixed 13-byte stub
    /// instead (see `OVERFLOW_STUB_SIZE`). The prop-store read path resolves
    /// the stub back into the real encoded bytes BEFORE decoding, so a decoder
    /// that ever sees this tag is looking at an unresolved stub — a plumbing
    /// bug, reported as `error.UnresolvedOverflowValue`.
    ///
    /// Forward compatibility: a reader built before this tag existed rejects
    /// it as `error.InvalidFormat` (it is not a member of its Tag enum) — a
    /// clean, loud refusal, never a misparse.
    overflow = 7,
};

/// On-page size of an overflow stub: tag(1) + encoded_len u32(4) + var_ref u64(8).
///
/// Layout:
///   [0]        u8  = 7 (`Tag.overflow`)
///   [1..5)    u32 LE  encoded_len — length of the ORIGINAL encoded value
///   [5..13)   u64 LE  var_ref — var-store chain holding those encoded bytes
///
/// `encoded_len` is redundant with the chain itself and exists precisely to
/// cross-check it: a resolved chain whose length disagrees is corruption.
pub const OVERFLOW_STUB_SIZE: usize = 13;

/// Decoded form of an overflow stub.
pub const OverflowStub = struct {
    /// Length of the original encoded value stored in the var chain.
    encoded_len: u32,
    /// Var-store reference (legacy chain ref) holding the encoded value.
    var_ref: u64,
};

/// True when `bytes` begins with an overflow stub tag. Empty input is not a stub.
pub fn isOverflowStub(bytes: []const u8) bool {
    return bytes.len >= 1 and bytes[0] == @intFromEnum(Tag.overflow);
}

/// Serialize an overflow stub into `buf` (which must hold OVERFLOW_STUB_SIZE bytes).
pub fn writeOverflowStub(buf: []u8, encoded_len: u32, var_ref: u64) error{BufferTooSmall}!void {
    if (buf.len < OVERFLOW_STUB_SIZE) return error.BufferTooSmall;
    buf[0] = @intFromEnum(Tag.overflow);
    std.mem.writeInt(u32, buf[1..5], encoded_len, .little);
    std.mem.writeInt(u64, buf[5..13], var_ref, .little);
}

/// Parse an overflow stub from `bytes`. Fully bounds-checked: a truncated or
/// mistagged entry fails loudly rather than reading past the slice.
pub fn readOverflowStub(bytes: []const u8) error{ UnexpectedEndOfInput, InvalidFormat }!OverflowStub {
    if (bytes.len < 1) return error.UnexpectedEndOfInput;
    if (bytes[0] != @intFromEnum(Tag.overflow)) return error.InvalidFormat;
    if (bytes.len < OVERFLOW_STUB_SIZE) return error.UnexpectedEndOfInput;
    return .{
        .encoded_len = std.mem.readInt(u32, bytes[1..5], .little),
        .var_ref = std.mem.readInt(u64, bytes[5..13], .little),
    };
}

/// Result of decoding a property value from bytes.
pub const DecodeResult = struct {
    value: PropertyValue,
    bytes_read: usize,
};

/// Return the encoded size of a PropertyValue without allocating.
pub fn encodedSize(value: PropertyValue) usize {
    return switch (value) {
        .null => 1, // tag only
        .bool => 2, // tag + 1 byte
        .int => 9, // tag + 8 bytes
        .float => 9, // tag + 8 bytes
        .string => |s| 1 + 4 + s.len, // tag + length(u32) + data
        .decimal => 18, // tag + 16 bytes coeff + 1 byte scale
        .ext => |e| 1 + 2 + 4 + e.data.len, // tag + type_tag(u16) + length(u32) + data
    };
}

/// Encode a PropertyValue into a caller-provided buffer.
/// Returns the number of bytes written, or error.BufferTooSmall if the
/// buffer is not large enough. Use `encodedSize` to determine the required
/// buffer length before calling.
pub fn encodeInto(buf: []u8, value: PropertyValue) error{BufferTooSmall}!usize {
    const size = encodedSize(value);
    if (buf.len < size) return error.BufferTooSmall;

    switch (value) {
        .null => {
            buf[0] = @intFromEnum(Tag.null);
        },
        .bool => |v| {
            buf[0] = @intFromEnum(Tag.bool);
            buf[1] = if (v) 1 else 0;
        },
        .int => |v| {
            buf[0] = @intFromEnum(Tag.int);
            @memcpy(buf[1..9], &std.mem.toBytes(@as(i64, v)));
        },
        .float => |v| {
            buf[0] = @intFromEnum(Tag.float);
            @memcpy(buf[1..9], &std.mem.toBytes(@as(f64, v)));
        },
        .string => |s| {
            buf[0] = @intFromEnum(Tag.string);
            const len: u32 = @intCast(s.len);
            @memcpy(buf[1..5], &std.mem.toBytes(std.mem.nativeToLittle(u32, len)));
            @memcpy(buf[5 .. 5 + s.len], s);
        },
        .decimal => |d| {
            buf[0] = @intFromEnum(Tag.decimal);
            @memcpy(buf[1..17], &std.mem.toBytes(std.mem.nativeToLittle(i128, d.coeff)));
            buf[17] = d.scale;
        },
        .ext => |e| {
            buf[0] = @intFromEnum(Tag.ext);
            @memcpy(buf[1..3], &std.mem.toBytes(std.mem.nativeToLittle(u16, e.type_tag)));
            const data_len: u32 = @intCast(e.data.len);
            @memcpy(buf[3..7], &std.mem.toBytes(std.mem.nativeToLittle(u32, data_len)));
            @memcpy(buf[7 .. 7 + e.data.len], e.data);
        },
    }

    return size;
}

/// Encode a PropertyValue to a newly allocated byte slice. Caller owns the returned memory.
pub fn encode(allocator: Allocator, value: PropertyValue) ![]u8 {
    const size = encodedSize(value);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = encodeInto(buf, value) catch unreachable; // size is pre-computed, cannot fail
    return buf;
}

/// Decode a PropertyValue from a byte slice. String and ext data are duped using the allocator.
/// Returns the decoded value and the number of bytes consumed.
pub fn decode(allocator: Allocator, bytes: []const u8) !DecodeResult {
    if (bytes.len < 1) return error.UnexpectedEndOfInput;

    const tag: Tag = std.enums.fromInt(Tag, bytes[0]) orelse return error.InvalidFormat;

    switch (tag) {
        .null => {
            return DecodeResult{ .value = PropertyValue.null, .bytes_read = 1 };
        },
        .bool => {
            if (bytes.len < 2) return error.UnexpectedEndOfInput;
            return DecodeResult{
                .value = PropertyValue{ .bool = bytes[1] != 0 },
                .bytes_read = 2,
            };
        },
        .int => {
            if (bytes.len < 9) return error.UnexpectedEndOfInput;
            const v = std.mem.littleToNative(i64, @bitCast(bytes[1..9].*));
            return DecodeResult{
                .value = PropertyValue{ .int = v },
                .bytes_read = 9,
            };
        },
        .float => {
            if (bytes.len < 9) return error.UnexpectedEndOfInput;
            const v: f64 = @bitCast(std.mem.littleToNative(u64, @bitCast(bytes[1..9].*)));
            return DecodeResult{
                .value = PropertyValue{ .float = v },
                .bytes_read = 9,
            };
        },
        .string => {
            if (bytes.len < 5) return error.UnexpectedEndOfInput;
            const len = std.mem.littleToNative(u32, @bitCast(bytes[1..5].*));
            const total = 5 + @as(usize, len);
            if (bytes.len < total) return error.UnexpectedEndOfInput;
            const duped = try allocator.dupe(u8, bytes[5..total]);
            return DecodeResult{
                .value = PropertyValue{ .string = duped },
                .bytes_read = total,
            };
        },
        .decimal => {
            if (bytes.len < 18) return error.UnexpectedEndOfInput;
            const coeff = std.mem.littleToNative(i128, @bitCast(bytes[1..17].*));
            const scale = bytes[17];
            return DecodeResult{
                .value = PropertyValue{ .decimal = .{ .coeff = coeff, .scale = scale } },
                .bytes_read = 18,
            };
        },
        .ext => {
            if (bytes.len < 7) return error.UnexpectedEndOfInput;
            const type_tag = std.mem.littleToNative(u16, @bitCast(bytes[1..3].*));
            const data_len = std.mem.littleToNative(u32, @bitCast(bytes[3..7].*));
            const total = 7 + @as(usize, data_len);
            if (bytes.len < total) return error.UnexpectedEndOfInput;
            const duped = try allocator.dupe(u8, bytes[7..total]);
            return DecodeResult{
                .value = PropertyValue{ .ext = .{ .type_tag = type_tag, .data = duped } },
                .bytes_read = total,
            };
        },
        .overflow => {
            // An overflow stub only REFERENCES the real value; the prop-store
            // read path must resolve it before decoding.
            return error.UnresolvedOverflowValue;
        },
    }
}

/// Zero-copy decode: string and ext slices borrow directly from `bytes`.
/// Caller must ensure `bytes` remains valid for the lifetime of the returned value.
/// No allocator needed — no heap allocation occurs.
pub fn decodeView(bytes: []const u8) error{ UnexpectedEndOfInput, InvalidFormat, UnresolvedOverflowValue }!DecodeResult {
    if (bytes.len < 1) return error.UnexpectedEndOfInput;

    const tag: Tag = std.enums.fromInt(Tag, bytes[0]) orelse return error.InvalidFormat;

    switch (tag) {
        .null => {
            return DecodeResult{ .value = PropertyValue.null, .bytes_read = 1 };
        },
        .bool => {
            if (bytes.len < 2) return error.UnexpectedEndOfInput;
            return DecodeResult{
                .value = PropertyValue{ .bool = bytes[1] != 0 },
                .bytes_read = 2,
            };
        },
        .int => {
            if (bytes.len < 9) return error.UnexpectedEndOfInput;
            const v = std.mem.littleToNative(i64, @bitCast(bytes[1..9].*));
            return DecodeResult{
                .value = PropertyValue{ .int = v },
                .bytes_read = 9,
            };
        },
        .float => {
            if (bytes.len < 9) return error.UnexpectedEndOfInput;
            const v: f64 = @bitCast(std.mem.littleToNative(u64, @bitCast(bytes[1..9].*)));
            return DecodeResult{
                .value = PropertyValue{ .float = v },
                .bytes_read = 9,
            };
        },
        .string => {
            if (bytes.len < 5) return error.UnexpectedEndOfInput;
            const len = std.mem.littleToNative(u32, @bitCast(bytes[1..5].*));
            const total = 5 + @as(usize, len);
            if (bytes.len < total) return error.UnexpectedEndOfInput;
            return DecodeResult{
                .value = PropertyValue{ .string = bytes[5..total] },
                .bytes_read = total,
            };
        },
        .decimal => {
            if (bytes.len < 18) return error.UnexpectedEndOfInput;
            const coeff = std.mem.littleToNative(i128, @bitCast(bytes[1..17].*));
            const scale = bytes[17];
            return DecodeResult{
                .value = PropertyValue{ .decimal = .{ .coeff = coeff, .scale = scale } },
                .bytes_read = 18,
            };
        },
        .ext => {
            if (bytes.len < 7) return error.UnexpectedEndOfInput;
            const type_tag = std.mem.littleToNative(u16, @bitCast(bytes[1..3].*));
            const data_len = std.mem.littleToNative(u32, @bitCast(bytes[3..7].*));
            const total = 7 + @as(usize, data_len);
            if (bytes.len < total) return error.UnexpectedEndOfInput;
            return DecodeResult{
                .value = PropertyValue{ .ext = .{ .type_tag = type_tag, .data = bytes[7..total] } },
                .bytes_read = total,
            };
        },
        .overflow => {
            // See `decode`: a stub must be resolved by the prop-store read
            // path before it reaches a decoder.
            return error.UnresolvedOverflowValue;
        },
    }
}

/// Free the allocator-owned memory inside a decoded PropertyValue.
pub fn freeDecoded(allocator: Allocator, value: PropertyValue) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .ext => |e| allocator.free(e.data),
        else => {},
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "encode/decode round-trip: null" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, PropertyValue.null);
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    try std.testing.expectEqual(PropertyValue.null, result.value);
    try std.testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "encode/decode round-trip: bool true" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, PropertyValue{ .bool = true });
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    try std.testing.expect(result.value.bool == true);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "encode/decode round-trip: bool false" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, PropertyValue{ .bool = false });
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    try std.testing.expect(result.value.bool == false);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "encode/decode round-trip: int" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, PropertyValue{ .int = -9999999 });
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    try std.testing.expectEqual(@as(i64, -9999999), result.value.int);
    try std.testing.expectEqual(@as(usize, 9), result.bytes_read);
}

test "encode/decode round-trip: float" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, PropertyValue{ .float = 3.14159 });
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), result.value.float, 1e-10);
    try std.testing.expectEqual(@as(usize, 9), result.bytes_read);
}

test "encode/decode round-trip: string" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, PropertyValue{ .string = "hello world" });
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    defer freeDecoded(allocator, result.value);
    try std.testing.expectEqualStrings("hello world", result.value.string);
    try std.testing.expectEqual(@as(usize, 1 + 4 + 11), result.bytes_read);
}

test "encode/decode round-trip: decimal" {
    const allocator = std.testing.allocator;
    const val = PropertyValue{ .decimal = .{ .coeff = 123456789, .scale = 4 } };
    const encoded = try encode(allocator, val);
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    try std.testing.expectEqual(@as(i128, 123456789), result.value.decimal.coeff);
    try std.testing.expectEqual(@as(u8, 4), result.value.decimal.scale);
    try std.testing.expectEqual(@as(usize, 18), result.bytes_read);
}

test "encode/decode round-trip: ext" {
    const allocator = std.testing.allocator;
    const val = PropertyValue{ .ext = .{ .type_tag = 42, .data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } } };
    const encoded = try encode(allocator, val);
    defer allocator.free(encoded);
    const result = try decode(allocator, encoded);
    defer freeDecoded(allocator, result.value);
    try std.testing.expectEqual(@as(u16, 42), result.value.ext.type_tag);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, result.value.ext.data);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 4 + 4), result.bytes_read);
}

test "encodedSize matches actual encode output length" {
    const allocator = std.testing.allocator;
    const values = [_]PropertyValue{
        PropertyValue.null,
        PropertyValue{ .bool = true },
        PropertyValue{ .bool = false },
        PropertyValue{ .int = 42 },
        PropertyValue{ .float = 1.0 },
        PropertyValue{ .string = "test" },
        PropertyValue{ .decimal = .{ .coeff = 100, .scale = 2 } },
        PropertyValue{ .ext = .{ .type_tag = 1, .data = "abc" } },
    };

    for (values) |val| {
        const expected_size = encodedSize(val);
        const encoded = try encode(allocator, val);
        defer allocator.free(encoded);
        try std.testing.expectEqual(expected_size, encoded.len);
    }
}

test "decode returns error on empty input" {
    const allocator = std.testing.allocator;
    const result = decode(allocator, &[_]u8{});
    try std.testing.expectError(error.UnexpectedEndOfInput, result);
}

test "encodeInto round-trip matches encode for all fixed types" {
    const allocator = std.testing.allocator;
    const values = [_]PropertyValue{
        PropertyValue.null,
        PropertyValue{ .bool = true },
        PropertyValue{ .int = -42 },
        PropertyValue{ .float = 2.718 },
        PropertyValue{ .decimal = .{ .coeff = 999, .scale = 3 } },
    };

    for (values) |val| {
        var buf: [32]u8 = undefined;
        const n = try encodeInto(&buf, val);
        const heap = try encode(allocator, val);
        defer allocator.free(heap);
        try std.testing.expectEqualSlices(u8, heap, buf[0..n]);
    }
}

test "overflow stub: round-trips through write/read and is exactly 13 bytes" {
    var buf: [OVERFLOW_STUB_SIZE]u8 = undefined;
    try writeOverflowStub(&buf, 123456, 0xABCDEF0123456789);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Tag.overflow)), buf[0]);

    const stub = try readOverflowStub(&buf);
    try std.testing.expectEqual(@as(u32, 123456), stub.encoded_len);
    try std.testing.expectEqual(@as(u64, 0xABCDEF0123456789), stub.var_ref);

    try std.testing.expect(isOverflowStub(&buf));
    try std.testing.expect(!isOverflowStub(&[_]u8{@intFromEnum(Tag.string)}));
    try std.testing.expect(!isOverflowStub(&[_]u8{}));
}

test "overflow stub: truncated / mistagged input fails loudly, never reads OOB" {
    var buf: [OVERFLOW_STUB_SIZE]u8 = undefined;
    try writeOverflowStub(&buf, 1, 2);
    try std.testing.expectError(error.UnexpectedEndOfInput, readOverflowStub(buf[0..12]));
    try std.testing.expectError(error.UnexpectedEndOfInput, readOverflowStub(&[_]u8{}));
    try std.testing.expectError(error.InvalidFormat, readOverflowStub(&[_]u8{ 4, 0, 0, 0, 0 }));

    var tiny: [12]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, writeOverflowStub(&tiny, 1, 2));
}

test "overflow stub: decoding an UNRESOLVED stub is a hard error on both decode paths" {
    var buf: [OVERFLOW_STUB_SIZE]u8 = undefined;
    try writeOverflowStub(&buf, 4096, 0x1234);
    try std.testing.expectError(error.UnresolvedOverflowValue, decodeView(&buf));
    try std.testing.expectError(error.UnresolvedOverflowValue, decode(std.testing.allocator, &buf));
}

test "encodeInto returns BufferTooSmall for undersized buffer" {
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encodeInto(&tiny, PropertyValue{ .int = 42 }));
}

test "encodeInto works for variable-length string" {
    const allocator = std.testing.allocator;
    const val = PropertyValue{ .string = "hello" };
    const size = encodedSize(val);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    const n = try encodeInto(buf, val);
    try std.testing.expectEqual(size, n);

    const decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(allocator, decoded.value);
    try std.testing.expectEqualStrings("hello", decoded.value.string);
}

test {
    std.testing.refAllDecls(@This());
}
