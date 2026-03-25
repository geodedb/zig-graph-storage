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
};

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

/// Encode a PropertyValue to a newly allocated byte slice. Caller owns the returned memory.
pub fn encode(allocator: Allocator, value: PropertyValue) ![]u8 {
    const size = encodedSize(value);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

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

    return buf;
}

/// Decode a PropertyValue from a byte slice. String and ext data are duped using the allocator.
/// Returns the decoded value and the number of bytes consumed.
pub fn decode(allocator: Allocator, bytes: []const u8) !DecodeResult {
    if (bytes.len < 1) return error.UnexpectedEndOfInput;

    const tag: Tag = @enumFromInt(bytes[0]);

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

test {
    std.testing.refAllDecls(@This());
}
