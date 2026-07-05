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
/// GAP adjacency slab packing: a SHARED slab block holding many small chains'
/// entry runs + a backward-growing slot directory (see the layout section
/// below). Slab blocks are reachable ONLY via bit-63-tagged (block, slot)
/// head refs (adj_store.isSlabHead) — they are NEVER linked into a legacy
/// block chain, so the chain-walking readers keep rejecting format 2 as
/// corruption (readBlockHeader's `> ENTRY_FORMAT_V2` guard).
pub const ENTRY_FORMAT_SLAB: u8 = 2;

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
    ///
    /// Deliberately NO default value (mirrors `EdgeIndexEntry.public_id`):
    /// every construction site must state the id it carries. A silent `= 0`
    /// default let `migrateColocateInEdges` drop real ids from rebuilt
    /// in-entries while compiling cleanly (review F2/F5); the compiler now
    /// re-audits every literal site.
    public_id: u64,
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

/// Byte size of one on-disk entry for a block's `entry_format`. Chain-block
/// formats only (v1/v2) — a slab block's runs are always v2-strided and its
/// layout is parsed via the slab helpers below, never through this. Callers
/// must have validated the format (readBlockHeader rejects unknown values).
pub fn entrySize(entry_format: u8) u32 {
    std.debug.assert(entry_format <= ENTRY_FORMAT_V2);
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
/// the page header and block header. Chain-block formats only (v1/v2): a slab
/// block's capacity is dynamic (runs + slot directory share the body).
pub fn entriesPerBlock(page_size: u32, entry_format: u8) u32 {
    std.debug.assert(entry_format <= ENTRY_FORMAT_V2);
    return (page_size - PAGE_HEADER_SIZE - @sizeOf(EdgeBlockHeader)) / entrySize(entry_format);
}

// ============================================================================
// GAP adjacency slab packing — SLAB block layout (entry_format = 2).
//
//   [page header 32 B][EdgeBlockHeader 16 B][runs →   ...gap...   ← slot dir][tail_reserve]
//
//   * EdgeBlockHeader: `next_block` MUST be 0 (slab blocks are never chained);
//     `count` = slot-directory size (live + tombstoned slots); `payload_size`
//     = used run bytes (writer bookkeeping — reads bound-check via the slot
//     directory, never via payload_size); `checksum` unused (0), as in v1/v2.
//   * Runs: consecutive ENTRY_FORMAT_V2 (32 B) records, one contiguous run
//     per small chain, growing FORWARD from SLAB_RUNS_OFFSET.
//   * Slot directory: grows BACKWARD from (page end - tail_reserve); slot i
//     is 8 B (run byte-offset u32 LE | entry_count u32 LE) based at
//     data.len - tail_reserve - (i+1)*8. `offset == SLAB_SLOT_TOMBSTONE`
//     marks a dead slot (chain graduated to a dedicated block chain, or
//     removed); a live head ref never points at a tombstone.
//   * tail_reserve: the same per-page AES-GCM tag reservation as prop-store
//     slab pages — the pager writes the tag into the final TAG_SIZE bytes of
//     every page when at-rest encryption is enabled, and the backward-growing
//     directory must never collide with it.
//
// A chain's slab head ref is a bit-63-tagged (block page id, slot) — see
// adj_store.zig `encodeSlabHead` — so NodeRec.out_head/in_head (u64) and
// in_head_dir values are unchanged in width. P1 READS slab blocks only; the
// P2 writer packs NEW small chains and graduates overflowing ones.
// ============================================================================

/// Byte offset of the first run byte (right after page header + block header).
pub const SLAB_RUNS_OFFSET: u32 = PAGE_HEADER_SIZE + @sizeOf(EdgeBlockHeader);
/// Slot directory entry: run byte-offset (u32 LE) + entry count (u32 LE).
pub const SLAB_DIR_ENTRY_SIZE: u32 = 8;
/// Tombstone marker in a slot's offset field.
pub const SLAB_SLOT_TOMBSTONE: u32 = 0xFFFF_FFFF;

pub const SlabSlot = struct { offset: u32, entry_count: u32 };

/// First byte of the slot directory (== one-past-the-end of usable run
/// space) for a slab block with `slot_count` directory entries.
pub fn slabDirStart(data_len: usize, tail_reserve: u32, slot_count: u32) usize {
    return data_len - tail_reserve - @as(usize, slot_count) * SLAB_DIR_ENTRY_SIZE;
}

fn slabSlotBase(data_len: usize, tail_reserve: u32, idx: u32) usize {
    return data_len - tail_reserve - (@as(usize, idx) + 1) * SLAB_DIR_ENTRY_SIZE;
}

/// Read slot `idx`'s (offset, entry_count) from the slab slot directory.
/// Caller must have validated `idx` against the block header's `count`.
pub fn readSlabSlot(data: []const u8, tail_reserve: u32, idx: u32) SlabSlot {
    const base = slabSlotBase(data.len, tail_reserve, idx);
    return .{
        .offset = std.mem.readInt(u32, data[base..][0..4], .little),
        .entry_count = std.mem.readInt(u32, data[base + 4 ..][0..4], .little),
    };
}

/// Write slot `idx`'s directory entry (tests / the P2 writer).
pub fn writeSlabSlot(data: []u8, tail_reserve: u32, idx: u32, slot: SlabSlot) void {
    const base = slabSlotBase(data.len, tail_reserve, idx);
    std.mem.writeInt(u32, data[base..][0..4], slot.offset, .little);
    std.mem.writeInt(u32, data[base + 4 ..][0..4], slot.entry_count, .little);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "EdgeEntry is 32 bytes (v2 record); v1 record is its 24-byte prefix" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(EdgeEntry));
    try std.testing.expectEqual(@as(u32, 24), entrySize(ENTRY_FORMAT_V1));
    try std.testing.expectEqual(@as(u32, 32), entrySize(ENTRY_FORMAT_V2));
}

test "EdgeEntry.public_id has NO default — every literal site states it (F5)" {
    // Compile-time contract: if this initializer compiles WITHOUT .public_id,
    // the field regained a silent default and writer-feeding literals can drop
    // real ids again (review F2). Keep the explicit field here.
    const e = EdgeEntry{ .neighbor = 1, .edge_id = 2, .rel_type = 3, .prop_head = 4, .public_id = 0 };
    try std.testing.expectEqual(@as(u64, 0), e.public_id);
    comptime {
        // public_id must be a required field: struct must NOT be default-
        // initializable without it.
        for (@typeInfo(EdgeEntry).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "public_id") and f.default_value_ptr != null) {
                @compileError("EdgeEntry.public_id must not have a default value (review F5)");
            }
        }
    }
}

test "EdgeBlockHeader is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(EdgeBlockHeader));
}

test "slab slot directory round-trips (with and without tail reserve)" {
    var buf = [_]u8{0} ** 4096;

    // No tail reserve: slot 0 sits in the final 8 bytes.
    writeSlabSlot(&buf, 0, 0, .{ .offset = SLAB_RUNS_OFFSET, .entry_count = 3 });
    writeSlabSlot(&buf, 0, 1, .{ .offset = SLAB_SLOT_TOMBSTONE, .entry_count = 0 });
    const s0 = readSlabSlot(&buf, 0, 0);
    try std.testing.expectEqual(SLAB_RUNS_OFFSET, s0.offset);
    try std.testing.expectEqual(@as(u32, 3), s0.entry_count);
    try std.testing.expectEqual(SLAB_SLOT_TOMBSTONE, readSlabSlot(&buf, 0, 1).offset);
    try std.testing.expectEqual(@as(usize, 4096 - 16), slabDirStart(buf.len, 0, 2));

    // 16-byte tail reserve (AES-GCM tag): the directory shifts up wholesale
    // and never touches the reserved tail.
    @memset(&buf, 0);
    writeSlabSlot(&buf, 16, 0, .{ .offset = 123, .entry_count = 7 });
    const r0 = readSlabSlot(&buf, 16, 0);
    try std.testing.expectEqual(@as(u32, 123), r0.offset);
    try std.testing.expectEqual(@as(u32, 7), r0.entry_count);
    for (buf[4096 - 16 ..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(@as(usize, 4096 - 16 - 8), slabDirStart(buf.len, 16, 1));
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
