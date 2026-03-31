// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const page = @import("page.zig");

pub const PAGE_HEADER_SIZE = page.PAGE_HEADER_SIZE;

/// Bit flag indicating the node has been logically deleted.
pub const NODE_FLAG_DELETED: u16 = 0x1;

/// Bit flag indicating the node has overflow data.
pub const NODE_FLAG_HAS_OVERFLOW: u16 = 0x2;

/// Fixed-size node record stored in the node store. Exactly 48 bytes.
pub const NodeRec = extern struct {
    out_head: u64, // first adj_out page (PageId)
    in_head: u64, // first adj_in page (PageId)
    prop_head: u64, // first property page/slot in props.store
    label_head: u64, // pointer to var.store label block (0 = no labels)
    label_count: u16, // number of labels on this node
    flags: u16, // bitfield: DELETED=0x1, HAS_OVERFLOW=0x2
    _pad: [4]u8, // alignment padding to 48 bytes
    txn_stamp: u64, // reserved for future MVCC (creation TxnId for now)
};

comptime {
    if (@sizeOf(NodeRec) != 48) @compileError("NodeRec must be exactly 48 bytes");
}

/// Returns true if the DELETED flag is set.
pub fn isDeleted(rec: *const NodeRec) bool {
    return (rec.flags & NODE_FLAG_DELETED) != 0;
}

/// Returns true if all fields are zero (unallocated slot).
pub fn isEmpty(rec: *const NodeRec) bool {
    return rec.out_head == 0 and
        rec.in_head == 0 and
        rec.prop_head == 0 and
        rec.label_head == 0 and
        rec.label_count == 0 and
        rec.flags == 0 and
        std.mem.eql(u8, &rec._pad, &[_]u8{ 0, 0, 0, 0 }) and
        rec.txn_stamp == 0;
}

/// How many NodeRecs fit in a page body (page_size minus 32-byte header).
pub fn nodesPerPage(page_size: u32) u32 {
    return (page_size - PAGE_HEADER_SIZE) / @sizeOf(NodeRec);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "NodeRec is 48 bytes" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(NodeRec));
}

test "isDeleted returns true when DELETED flag is set" {
    const rec = NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = NODE_FLAG_DELETED,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 0,
    };
    try std.testing.expect(isDeleted(&rec));
}

test "isDeleted returns false when DELETED flag is not set" {
    const rec = NodeRec{
        .out_head = 1,
        .in_head = 2,
        .prop_head = 3,
        .label_head = 4,
        .label_count = 1,
        .flags = NODE_FLAG_HAS_OVERFLOW,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 5,
    };
    try std.testing.expect(!isDeleted(&rec));
}

test "isEmpty returns true for zeroed record" {
    const rec = std.mem.zeroes(NodeRec);
    try std.testing.expect(isEmpty(&rec));
}

test "isEmpty returns false for non-zero record" {
    const rec = NodeRec{
        .out_head = 1,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 0,
    };
    try std.testing.expect(!isEmpty(&rec));
}

test "nodesPerPage returns correct count for 8192-byte pages" {
    // (8192 - 32) / 48 = 170
    try std.testing.expectEqual(@as(u32, 170), nodesPerPage(8192));
}

test {
    std.testing.refAllDecls(@This());
}
