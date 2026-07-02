// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const page = @import("page.zig");

pub const PAGE_HEADER_SIZE = page.PAGE_HEADER_SIZE;

/// Per-block adjacency entry formats (EdgeBlockHeader.entry_format).
/// The discriminator is block-granular: a chain may freely mix v1 and v2
/// blocks and readers parse each block by ITS format (read-both is permanent
/// — v1 blocks keep working forever, no store migration).
pub const ENTRY_FORMAT_V1: u8 = 0; // 24 B entries, no public_id (legacy; the old zero-init `_reserved` byte)
pub const ENTRY_FORMAT_V2: u8 = 1; // 32 B entries with inline public_id

/// On-disk size of one entry in a v1-format block (the first 24 bytes of
/// `EdgeEntry`: neighbor, edge_id, rel_type, prop_head).
pub const ENTRY_SIZE_V1: u32 = 24;
/// On-disk size of one entry in a v2-format block (all 32 bytes of `EdgeEntry`).
pub const ENTRY_SIZE_V2: u32 = 32;

/// Adjacency edge entry. In-memory representation and the exact v2 on-disk
/// record (32 bytes). A v1 on-disk record is exactly the first 24 bytes
/// (`public_id` is absent on disk and surfaces as 0 when read).
pub const EdgeEntry = extern struct {
    neighbor: u64, // target node ID
    edge_id: u64, // unique edge ID
    rel_type: u32, // relationship type (LabelId)
    prop_head: u32, // property page/slot ref (lower 32 bits sufficient for initial scale)
    /// Inline 64-bit public edge id (GAP-ENT-0024). 0 = unknown/absent:
    /// entries read from v1 blocks always surface 0, and callers fall back to
    /// the legacy `__geode_internal_edge_id` property in that case.
    public_id: u64 = 0,
};

comptime {
    if (@sizeOf(EdgeEntry) != ENTRY_SIZE_V2) @compileError("EdgeEntry must be exactly 32 bytes");
    // A v1 record must be the exact prefix of EdgeEntry: field offsets are
    // load-bearing for the read-both block parser.
    if (@offsetOf(EdgeEntry, "neighbor") != 0) @compileError("EdgeEntry.neighbor must be at offset 0");
    if (@offsetOf(EdgeEntry, "edge_id") != 8) @compileError("EdgeEntry.edge_id must be at offset 8");
    if (@offsetOf(EdgeEntry, "rel_type") != 16) @compileError("EdgeEntry.rel_type must be at offset 16");
    if (@offsetOf(EdgeEntry, "prop_head") != 20) @compileError("EdgeEntry.prop_head must be at offset 20");
    if (@offsetOf(EdgeEntry, "public_id") != ENTRY_SIZE_V1) @compileError("EdgeEntry.public_id must start exactly where a v1 record ends");
}

/// Byte size of one on-disk entry for a block's `entry_format`. Callers must
/// have validated the format (readBlockHeader rejects unknown values).
pub fn entrySize(entry_format: u8) u32 {
    return if (entry_format == ENTRY_FORMAT_V2) ENTRY_SIZE_V2 else ENTRY_SIZE_V1;
}

/// Edge block header preceding entries in an adjacency block page. Exactly 16 bytes.
pub const EdgeBlockHeader = extern struct {
    next_block: u64, // next overflow block PageId (0 = none)
    count: u16, // entries in this block
    kind: u8, // block kind: 0=mixed, 1=single rel_type partition
    /// Entry format of THIS block: ENTRY_FORMAT_V1 (0) or ENTRY_FORMAT_V2 (1).
    /// Repurposed from the always-zero `_reserved` byte, so every pre-existing
    /// block on disk is implicitly (and correctly) v1. Any other value is
    /// rejected as DataCorruption — never misparsed.
    entry_format: u8,
    payload_size: u16, // used bytes in payload area
    checksum: u16, // block-level integrity (CRC16 of entries)
};

comptime {
    if (@sizeOf(EdgeBlockHeader) != 16) @compileError("EdgeBlockHeader must be exactly 16 bytes");
}

/// How many entries of the given block format fit in a block page body after
/// the page header and block header.
pub fn entriesPerBlock(page_size: u32, entry_format: u8) u32 {
    return (page_size - PAGE_HEADER_SIZE - @sizeOf(EdgeBlockHeader)) / entrySize(entry_format);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "EdgeEntry is 32 bytes (v2 record); v1 record is its 24-byte prefix" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(EdgeEntry));
    try std.testing.expectEqual(@as(u32, 24), entrySize(ENTRY_FORMAT_V1));
    try std.testing.expectEqual(@as(u32, 32), entrySize(ENTRY_FORMAT_V2));
}

test "EdgeEntry.public_id defaults to 0 (legacy literal sites stay valid)" {
    const e = EdgeEntry{ .neighbor = 1, .edge_id = 2, .rel_type = 3, .prop_head = 4 };
    try std.testing.expectEqual(@as(u64, 0), e.public_id);
}

test "EdgeBlockHeader is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(EdgeBlockHeader));
}

test "entriesPerBlock for 8192-byte pages" {
    // v1: (8192 - 32 - 16) / 24 = 339
    try std.testing.expectEqual(@as(u32, 339), entriesPerBlock(8192, ENTRY_FORMAT_V1));
    // v2: (8192 - 32 - 16) / 32 = 254
    try std.testing.expectEqual(@as(u32, 254), entriesPerBlock(8192, ENTRY_FORMAT_V2));
}

test {
    std.testing.refAllDecls(@This());
}
