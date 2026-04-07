// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub const NodeId = u64;
pub const EdgeId = u64;
pub const PageId = u64;
pub const SlotId = u16;
pub const Lsn = u64;
pub const TxnId = u64;
pub const LabelId = u32;
pub const GraphUuid = [16]u8;

pub const FileId = enum(u8) {
    nodes = 0,
    adj_out = 1,
    adj_in = 2,
    props = 3,
    var_store = 4,
    free = 5,
    label_idx = 6,
    prop_idx = 7,
    edge_idx = 8,
};

pub const PropertyValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null,
    decimal: Decimal,
    ext: ExtValue,

    pub const Decimal = struct { coeff: i128, scale: u8 };
    pub const ExtValue = struct { type_tag: u16, data: []const u8 };
};

// ============================================================================
// Unit Tests
// ============================================================================

test "FileId values are correct" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(FileId.nodes));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(FileId.adj_out));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(FileId.adj_in));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(FileId.props));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(FileId.var_store));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(FileId.free));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(FileId.label_idx));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(FileId.prop_idx));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(FileId.edge_idx));
}

test "PropertyValue can be constructed for all 7 variants" {
    const str_val = PropertyValue{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", str_val.string);

    const int_val = PropertyValue{ .int = -42 };
    try std.testing.expectEqual(@as(i64, -42), int_val.int);

    const float_val = PropertyValue{ .float = 3.14 };
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), float_val.float, 0.001);

    const bool_val = PropertyValue{ .bool = true };
    try std.testing.expect(bool_val.bool);

    const null_val = PropertyValue.null;
    try std.testing.expectEqual(PropertyValue.null, null_val);

    const dec_val = PropertyValue{ .decimal = .{ .coeff = 12345, .scale = 2 } };
    try std.testing.expectEqual(@as(i128, 12345), dec_val.decimal.coeff);
    try std.testing.expectEqual(@as(u8, 2), dec_val.decimal.scale);

    const ext_val = PropertyValue{ .ext = .{ .type_tag = 99, .data = "binary" } };
    try std.testing.expectEqual(@as(u16, 99), ext_val.ext.type_tag);
    try std.testing.expectEqualStrings("binary", ext_val.ext.data);
}

test "PropertyValue.Decimal can hold large values" {
    const large_coeff: i128 = 170_141_183_460_469_231_731_687_303_715_884_105_727; // max i128
    const dec = PropertyValue{ .decimal = .{ .coeff = large_coeff, .scale = 255 } };
    try std.testing.expectEqual(large_coeff, dec.decimal.coeff);
    try std.testing.expectEqual(@as(u8, 255), dec.decimal.scale);

    const neg_dec = PropertyValue{ .decimal = .{ .coeff = -large_coeff, .scale = 0 } };
    try std.testing.expectEqual(-large_coeff, neg_dec.decimal.coeff);
}

test {
    std.testing.refAllDecls(@This());
}
