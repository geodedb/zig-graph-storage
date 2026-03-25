// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const page = @import("page.zig");

pub const PAGE_HEADER_SIZE = page.PAGE_HEADER_SIZE;

/// Adjacency edge entry. Exactly 24 bytes.
pub const EdgeEntry = extern struct {
    neighbor: u64, // target node ID
    edge_id: u64, // unique edge ID
    rel_type: u32, // relationship type (LabelId)
    prop_head: u32, // property page/slot ref (lower 32 bits sufficient for initial scale)
};

comptime {
    if (@sizeOf(EdgeEntry) != 24) @compileError("EdgeEntry must be exactly 24 bytes");
}

/// Edge block header preceding entries in an adjacency block page. Exactly 16 bytes.
pub const EdgeBlockHeader = extern struct {
    next_block: u64, // next overflow block PageId (0 = none)
    count: u16, // entries in this block
    kind: u8, // block kind: 0=mixed, 1=single rel_type partition
    _reserved: u8,
    payload_size: u16, // used bytes in payload area
    checksum: u16, // block-level integrity (CRC16 of entries)
};

comptime {
    if (@sizeOf(EdgeBlockHeader) != 16) @compileError("EdgeBlockHeader must be exactly 16 bytes");
}

/// How many EdgeEntry records fit in a block page body after the page header and block header.
/// Formula: (page_size - PAGE_HEADER_SIZE - @sizeOf(EdgeBlockHeader)) / @sizeOf(EdgeEntry)
pub fn entriesPerBlock(page_size: u32) u32 {
    return (page_size - PAGE_HEADER_SIZE - @sizeOf(EdgeBlockHeader)) / @sizeOf(EdgeEntry);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "EdgeEntry is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(EdgeEntry));
}

test "EdgeBlockHeader is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(EdgeBlockHeader));
}

test "entriesPerBlock for 8192-byte pages" {
    // (8192 - 32 - 16) / 24 = 339
    try std.testing.expectEqual(@as(u32, 339), entriesPerBlock(8192));
}

test {
    std.testing.refAllDecls(@This());
}
