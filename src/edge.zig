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
/// GAP-0060: a v3 CHAIN block — 40 B entries carrying a full u64
/// `prop_head` (v2 + the high 32 bits). Written only when an entry's prop_head
/// exceeds 32 bits (a prop-store slab head); legacy v1/v2 blocks keep reading.
pub const ENTRY_FORMAT_V3: u8 = 3;
/// GAP-0060: a v3 SLAB block — like `ENTRY_FORMAT_SLAB` but its runs are
/// v3-strided (40 B), so a slab-packed edge can carry a u64 prop_head in
/// place. Reached only via a bit-63-tagged slab head, never chained.
pub const ENTRY_FORMAT_SLAB_V3: u8 = 4;

/// On-disk size of one entry in a v1-format block: neighbor, edge_id,
/// rel_type, prop_head-low32 (no public_id, no prop_head-high32).
pub const ENTRY_SIZE_V1: u32 = 24;
/// On-disk size of one entry in a v2-format block: v1 + inline public_id.
pub const ENTRY_SIZE_V2: u32 = 32;
/// GAP-0060: on-disk size of one entry in a v3-format block: v2 + the
/// high 32 bits of a widened u64 `prop_head` (so an edge prop head can be a
/// prop-store SLAB ref, `bit63|page|slot`). Wire layout is a strict SUPERSET
/// of v1/v2 (see `encodeEntry`), so a v1/v2 record is still a valid prefix and
/// read-both never has to relocate a legacy block.
pub const ENTRY_SIZE_V3: u32 = 40;

/// Adjacency edge entry — IN-MEMORY representation. GAP-0060 widened
/// `prop_head` u32 -> u64; the struct is therefore NO LONGER the wire record
/// (a v1/v2 wire record stores only the low 32 bits of `prop_head`, a v3 wire
/// record stores all 64). All (de)serialization goes through `encodeEntry` /
/// `decodeEntry`; nothing byte-casts this struct any more.
pub const EdgeEntry = struct {
    neighbor: u64, // target node ID
    edge_id: u64, // unique edge ID
    rel_type: u32, // relationship type (LabelId)
    /// GAP-0060: property chain head, u64. A legacy bare-page-id head is
    /// < 2^39 and rides in the low 32 bits (v1/v2 wire stores exactly those
    /// low 32 bits, hi=0). A prop-store slab head (bit 63 set) needs a v3
    /// (or slab-v3) wire record — `encodeEntry` asserts a non-u32 head is
    /// never written to a v1/v2 record (the no-truncate rule, extended from
    /// public_id to prop_head).
    prop_head: u64,
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

/// True when this format carries the widened high 32 bits of `prop_head`
/// (v3 chain block or v3 slab run). v1/v2 store only the low 32 bits.
pub fn formatHasWideHead(entry_format: u8) bool {
    return entry_format == ENTRY_FORMAT_V3 or entry_format == ENTRY_FORMAT_SLAB_V3;
}

/// Byte size of one on-disk chain-block entry for `entry_format` (v1/v2/v3).
/// Slab blocks stride by `slabEntrySize` (their runs may be v2 or v3), parsed
/// via the slab helpers. Callers must have validated the format.
pub fn entrySize(entry_format: u8) u32 {
    return switch (entry_format) {
        ENTRY_FORMAT_V1 => ENTRY_SIZE_V1,
        ENTRY_FORMAT_V2 => ENTRY_SIZE_V2,
        ENTRY_FORMAT_V3 => ENTRY_SIZE_V3,
        else => unreachable, // readBlockHeader rejects unknown chain formats
    };
}

/// Stride of one entry in a slab block's runs, keyed by the block's format:
/// legacy `ENTRY_FORMAT_SLAB` runs are v2 (32 B, u32 head); GAP-0060
/// `ENTRY_FORMAT_SLAB_V3` runs are v3 (40 B, u64 head).
pub fn slabEntrySize(entry_format: u8) u32 {
    return if (entry_format == ENTRY_FORMAT_SLAB_V3) ENTRY_SIZE_V3 else ENTRY_SIZE_V2;
}

/// Wire encode one `EdgeEntry` at the given format into `dst` (len must equal
/// the format's entry size). The wire layout is a strict superset:
///   [neighbor u64 @0][edge_id u64 @8][rel_type u32 @16][prop_head_lo u32 @20]
///   [public_id u64 @24]                        (v2/v3/slab only)
///   [prop_head_hi u32 @32][reserved u32 @36]   (v3/slab-v3 only)
/// so a v1 record is the first 24 bytes and a v2 record the first 32 — the
/// exact bytes the pre-0060 extern-struct layout produced (byte-for-byte).
pub fn encodeEntry(dst: []u8, e: EdgeEntry, entry_format: u8) void {
    const wide = formatHasWideHead(entry_format);
    // No-truncate rule (extended from public_id): a slab/high head must never
    // be written to a narrow (v1/v2/slab-v2) record — its high bits would be
    // silently dropped. Callers route such entries to a v3 record instead.
    std.debug.assert(wide or (e.prop_head >> 32) == 0);
    std.mem.writeInt(u64, dst[0..8], e.neighbor, .little);
    std.mem.writeInt(u64, dst[8..16], e.edge_id, .little);
    std.mem.writeInt(u32, dst[16..20], e.rel_type, .little);
    std.mem.writeInt(u32, dst[20..24], @truncate(e.prop_head), .little);
    // v1 stops here (public_id dropped — the no-public-id rule).
    if (dst.len >= ENTRY_SIZE_V2) {
        std.mem.writeInt(u64, dst[24..32], e.public_id, .little);
    }
    if (wide) {
        std.mem.writeInt(u32, dst[32..36], @intCast(e.prop_head >> 32), .little);
        std.mem.writeInt(u32, dst[36..40], 0, .little); // reserved
    }
}

/// Wire decode one `EdgeEntry` at the given format from `src` (len must equal
/// the format's entry size). `public_id` surfaces 0 for v1; `prop_head` high
/// bits surface 0 (a legacy u32 head) for v1/v2/slab-v2 — losslessly widened.
pub fn decodeEntry(src: []const u8, entry_format: u8) EdgeEntry {
    const lo: u64 = std.mem.readInt(u32, src[20..24], .little);
    const public_id: u64 = if (src.len >= ENTRY_SIZE_V2) std.mem.readInt(u64, src[24..32], .little) else 0;
    const hi: u64 = if (formatHasWideHead(entry_format)) std.mem.readInt(u32, src[32..36], .little) else 0;
    return .{
        .neighbor = std.mem.readInt(u64, src[0..8], .little),
        .edge_id = std.mem.readInt(u64, src[8..16], .little),
        .rel_type = std.mem.readInt(u32, src[16..20], .little),
        .prop_head = lo | (hi << 32),
        .public_id = public_id,
    };
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
    std.debug.assert(entry_format == ENTRY_FORMAT_V1 or
        entry_format == ENTRY_FORMAT_V2 or entry_format == ENTRY_FORMAT_V3);
    return (page_size - PAGE_HEADER_SIZE - @sizeOf(EdgeBlockHeader)) / entrySize(entry_format);
}

// ============================================================================
// SONNY-6461: entries lost to the pre-0.4.12 page-encryption tail.
//
// graph_storage <= 0.4.11 wrote the 16-byte AES-GCM tag over the LAST 16 bytes
// of every encrypted page (the "legacy envelope"); whatever a layout kept there
// never reached the disk, and 0.4.12+ reads those bytes back as zero. A chain
// block fills forward from byte 48, so only the LAST slot of a FULL block can
// reach the tail, and only for some (page size, format) pairs. Slab blocks
// reserve the tail (`AdjStore.tail_reserve`) and never lose an entry.
//
// Entry byte layout (see `encodeEntry`): neighbor 0..8, edge_id 8..16,
// rel_type 16..20, prop_head low half 20..24, public_id 24..32, prop_head high
// half 32..36, reserved 36..40. Lost bytes per page size (powers of two):
//
//   page   v1 (24 B)                 v2 (32 B)  v3 (40 B)
//   4 KiB  none (168 ends at -16)    none       slot 100: 32..40 (prop hi)
//   8 KiB  slot 338: 16..24          none       none (203 ends at -24)
//          (rel_type, prop_head)
//   16 KiB none                      none       none
//   32 KiB slot 1362: 16..24         none       slot 817: 24..40
//          (rel_type, prop_head)                (public_id, prop hi)
//   64 KiB none                      none       slot 1636: 32..40 (prop hi)
//
// `neighbor` and `edge_id` are never lost (the tail is 16 bytes and every
// format's entry is at least 24), so a damaged entry can always be matched to
// its mirror in the other direction's chain by edge id.
// ============================================================================

/// Size of the page tail the legacy (pre-0.4.12) encryption envelope
/// overwrote with the AES-GCM tag. Equal to `encryption.TAG_SIZE`.
pub const LEGACY_TAG_TAIL: u32 = 16;

/// The one chain-block slot whose bytes reached the legacy tag tail, and the
/// entry-relative byte offset from which its bytes were lost.
pub const LegacyTailLoss = struct {
    /// Slot index (always `entriesPerBlock - 1`); exposed only when the block
    /// is full (`count == entriesPerBlock`).
    slot: u32,
    /// First lost byte, relative to the entry start, rounded down to the start
    /// of the field it falls in. Bytes `lost_from..entrySize` were lost.
    lost_from: u32,
};

/// Start offsets of the wire fields of a chain entry (superset layout).
const entry_field_starts = [_]u32{ 0, 8, 16, 20, 24, 32, 36 };

/// SONNY-6461: which entry of a full chain block of `entry_format` (v1/v2/v3)
/// lost bytes to the legacy tag tail at `page_size`, or null when the format
/// keeps clear of the tail at that size.
pub fn legacyTailLoss(page_size: u32, entry_format: u8) ?LegacyTailLoss {
    if (entry_format != ENTRY_FORMAT_V1 and entry_format != ENTRY_FORMAT_V2 and
        entry_format != ENTRY_FORMAT_V3) return null;
    if (page_size <= PAGE_HEADER_SIZE + @sizeOf(EdgeBlockHeader) + LEGACY_TAG_TAIL) return null;
    const cap = entriesPerBlock(page_size, entry_format);
    if (cap == 0) return null;
    const esz = entrySize(entry_format);
    const tail_start = page_size - LEGACY_TAG_TAIL;
    const last_off = PAGE_HEADER_SIZE + @sizeOf(EdgeBlockHeader) + (cap - 1) * esz;
    if (last_off + esz <= tail_start) return null;
    const raw = tail_start - last_off;
    var lost_from: u32 = 0;
    for (entry_field_starts) |s| {
        if (s <= raw) lost_from = s;
    }
    return .{ .slot = cap - 1, .lost_from = lost_from };
}

/// SONNY-6461: rebuild an entry whose bytes `lost_from..` were lost, taking
/// exactly those fields from `mirror` (the same edge's entry in the other
/// direction's chain) and keeping the intact prefix of `damaged`. Fields the
/// format does not store (public_id for v1, the high half of prop_head for
/// v1/v2) are dropped as `encodeEntry` drops them. Returns
/// error.WideHeadInLegacyChainBlock when the restored prop_head does not fit
/// a v1/v2 record.
pub fn restoreLostFields(damaged: EdgeEntry, mirror: EdgeEntry, lost_from: u32, entry_format: u8) error{WideHeadInLegacyChainBlock}!EdgeEntry {
    var out = damaged;
    if (lost_from <= 16) out.rel_type = mirror.rel_type;
    var lo: u64 = damaged.prop_head & 0xFFFF_FFFF;
    var hi: u64 = damaged.prop_head >> 32;
    if (lost_from <= 20) lo = mirror.prop_head & 0xFFFF_FFFF;
    if (lost_from <= 32) hi = mirror.prop_head >> 32;
    if (lost_from <= 24) out.public_id = mirror.public_id;
    if (!formatHasWideHead(entry_format)) {
        if (hi != 0) return error.WideHeadInLegacyChainBlock;
        if (entry_format == ENTRY_FORMAT_V1) out.public_id = 0;
    }
    out.prop_head = lo | (hi << 32);
    return out;
}

/// SONNY-6461: true when the fields `lost_from..` of `a` and `b` agree, as
/// stored by `entry_format` (fields the format does not store are ignored).
pub fn lostFieldsEqual(a: EdgeEntry, b: EdgeEntry, lost_from: u32, entry_format: u8) bool {
    var buf_a: [ENTRY_SIZE_V3]u8 = undefined;
    var buf_b: [ENTRY_SIZE_V3]u8 = undefined;
    const esz = entrySize(entry_format);
    var na = a;
    var nb = b;
    if (!formatHasWideHead(entry_format)) {
        na.prop_head &= 0xFFFF_FFFF;
        nb.prop_head &= 0xFFFF_FFFF;
    }
    encodeEntry(buf_a[0..esz], na, entry_format);
    encodeEntry(buf_b[0..esz], nb, entry_format);
    return std.mem.eql(u8, buf_a[lost_from..esz], buf_b[lost_from..esz]);
}

/// SONNY-6461: true when the fields `lost_from..` of `e`, as stored by
/// `entry_format`, are all zero — what a legacy-envelope tail reads back as.
pub fn lostFieldsZero(e: EdgeEntry, lost_from: u32, entry_format: u8) bool {
    var buf: [ENTRY_SIZE_V3]u8 = undefined;
    const esz = entrySize(entry_format);
    var n = e;
    if (!formatHasWideHead(entry_format)) n.prop_head &= 0xFFFF_FFFF;
    encodeEntry(buf[0..esz], n, entry_format);
    return std.mem.allEqual(u8, buf[lost_from..esz], 0);
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

test "wire entry sizes: v1=24, v2=32, v3=40" {
    try std.testing.expectEqual(@as(u32, 24), entrySize(ENTRY_FORMAT_V1));
    try std.testing.expectEqual(@as(u32, 32), entrySize(ENTRY_FORMAT_V2));
    try std.testing.expectEqual(@as(u32, 40), entrySize(ENTRY_FORMAT_V3));
    try std.testing.expectEqual(@as(u32, 32), slabEntrySize(ENTRY_FORMAT_SLAB));
    try std.testing.expectEqual(@as(u32, 40), slabEntrySize(ENTRY_FORMAT_SLAB_V3));
}

test "GAP-0060: encode/decode round-trips every format; v1/v2 wire is byte-identical" {
    const e_full = EdgeEntry{
        .neighbor = 0x1111_2222_3333_4444,
        .edge_id = 0x5555_6666_7777_8888,
        .rel_type = 0x9ABC_DEF0,
        .prop_head = 0, // narrow-safe head for v1/v2
        .public_id = 0xCAFE_BABE_DEAD_0001,
    };

    // v2 wire must be byte-identical to the old extern-struct memory image
    // (neighbor@0, edge_id@8, rel_type@16, prop_head_lo@20, public_id@24).
    var v2: [ENTRY_SIZE_V2]u8 = undefined;
    encodeEntry(&v2, e_full, ENTRY_FORMAT_V2);
    try std.testing.expectEqual(e_full.neighbor, std.mem.readInt(u64, v2[0..8], .little));
    try std.testing.expectEqual(e_full.edge_id, std.mem.readInt(u64, v2[8..16], .little));
    try std.testing.expectEqual(e_full.rel_type, std.mem.readInt(u32, v2[16..20], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, v2[20..24], .little));
    try std.testing.expectEqual(e_full.public_id, std.mem.readInt(u64, v2[24..32], .little));
    try std.testing.expectEqual(e_full, decodeEntry(&v2, ENTRY_FORMAT_V2));

    // v1: public_id dropped (surfaces 0), head low bits preserved.
    var v1: [ENTRY_SIZE_V1]u8 = undefined;
    encodeEntry(&v1, e_full, ENTRY_FORMAT_V1);
    const d1 = decodeEntry(&v1, ENTRY_FORMAT_V1);
    try std.testing.expectEqual(@as(u64, 0), d1.public_id);
    try std.testing.expectEqual(e_full.prop_head, d1.prop_head);
    try std.testing.expectEqual(e_full.edge_id, d1.edge_id);

    // v3: a full u64 slab-shaped head (bit 63 set) survives; v2 prefix of the
    // v3 record still decodes the low 32 bits + public_id.
    var e_slab = e_full;
    e_slab.prop_head = (@as(u64, 1) << 63) | (0x7F_FFFF_FFFF << 24) | 0xABCDEF;
    var v3: [ENTRY_SIZE_V3]u8 = undefined;
    encodeEntry(&v3, e_slab, ENTRY_FORMAT_V3);
    try std.testing.expectEqual(e_slab, decodeEntry(&v3, ENTRY_FORMAT_V3));
    // The first 32 bytes of a v3 record ARE a valid v2 record (superset).
    const as_v2 = decodeEntry(v3[0..ENTRY_SIZE_V2], ENTRY_FORMAT_V2);
    try std.testing.expectEqual(e_slab.public_id, as_v2.public_id);
    try std.testing.expectEqual(@as(u64, @as(u32, @truncate(e_slab.prop_head))), as_v2.prop_head);
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

test "SONNY-6461: restoreLostFields copies exactly the lost fields" {
    const mirror = EdgeEntry{ .neighbor = 9, .edge_id = 4, .rel_type = 7, .prop_head = (@as(u64, 1) << 63) | 0x1234, .public_id = 55 };
    // v3 at 4 KiB: only the high half of prop_head was lost.
    var damaged = mirror;
    damaged.prop_head = 0x1234;
    damaged.neighbor = 1; // an intact field is never taken from the mirror
    const r3 = try restoreLostFields(damaged, mirror, 32, ENTRY_FORMAT_V3);
    try std.testing.expectEqual(mirror.prop_head, r3.prop_head);
    try std.testing.expectEqual(@as(u64, 1), r3.neighbor);
    try std.testing.expect(!lostFieldsEqual(damaged, mirror, 32, ENTRY_FORMAT_V3));
    try std.testing.expect(lostFieldsEqual(r3, mirror, 32, ENTRY_FORMAT_V3));
    try std.testing.expect(lostFieldsZero(damaged, 32, ENTRY_FORMAT_V3));

    // v1 at 8 KiB: rel_type and the (narrow) prop_head were lost.
    const narrow = EdgeEntry{ .neighbor = 9, .edge_id = 4, .rel_type = 7, .prop_head = 0x99, .public_id = 55 };
    const d1 = EdgeEntry{ .neighbor = 9, .edge_id = 4, .rel_type = 0, .prop_head = 0, .public_id = 0 };
    const r1 = try restoreLostFields(d1, narrow, 16, ENTRY_FORMAT_V1);
    try std.testing.expectEqual(@as(u32, 7), r1.rel_type);
    try std.testing.expectEqual(@as(u64, 0x99), r1.prop_head);
    try std.testing.expectEqual(@as(u64, 0), r1.public_id); // v1 stores none
    // A 64-bit head cannot go into a v1 record.
    try std.testing.expectError(error.WideHeadInLegacyChainBlock, restoreLostFields(d1, mirror, 16, ENTRY_FORMAT_V1));

    // v3 at 32 KiB: public_id and the high half.
    var d32 = mirror;
    d32.public_id = 0;
    d32.prop_head = 0x1234;
    const r32 = try restoreLostFields(d32, mirror, 24, ENTRY_FORMAT_V3);
    try std.testing.expectEqual(mirror, r32);
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
