// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const property_mod = @import("property.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");
const var_store_mod = @import("var_store.zig");
const interface_mod = @import("interface.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const VarStore = var_store_mod.VarStore;
const PropertyValue = types.PropertyValue;
const PropertyEntry = interface_mod.PropertyEntry;
const PageId = types.PageId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Property page metadata offsets (after PAGE_HEADER_SIZE):
/// - [0..8): next_page (u64), pointer to overflow property page
/// - [8..12): entry_count (u32), number of property entries on this page
/// - [12..): entries, each: key_len(2) + key_bytes + encoded_value_bytes
const PROP_META_SIZE: u32 = 12; // next_page(8) + entry_count(4)
const PROP_DATA_OFFSET: u32 = PAGE_HEADER_SIZE + PROP_META_SIZE;

/// Maximum hops allowed in a page chain traversal before assuming corruption.
const MAX_CHAIN_HOPS: u32 = 100_000;

/// Per-page property key directory (PERF-0023).
/// The directory grows backward from the end of each page and maps key hashes
/// to entry offsets for O(1) lookup within a page.
///
/// Page layout:
///   [PageHeader 32B] [meta 12B] [entries → ...free space... ← directory] [dir_count 2B]
///
/// Each directory entry is 4 bytes: [key_hash: u16] [entry_offset: u16].
/// dir_count (u16) is stored in the last 2 bytes of the page.
/// When dir_count == 0 the page is in legacy format and falls back to linear scan.
const DIR_ENTRY_SIZE: u32 = 4; // u16 hash + u16 offset
const DIR_COUNT_SIZE: u32 = 2; // u16 at end of page

/// Compute a 16-bit hash of a property key using FNV-1a.
fn keyHash(key: []const u8) u16 {
    var h: u32 = 2166136261;
    for (key) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return @truncate(h);
}

/// Read the directory entry count from the last 2 bytes of a page.
fn readDirCount(data: []const u8) u16 {
    return std.mem.readInt(u16, data[data.len - DIR_COUNT_SIZE ..][0..DIR_COUNT_SIZE], .little);
}

/// Read dir_count with bounds validation: the directory region (dir_count
/// entries + the 2-byte count field) must fit entirely within the data
/// region that follows PROP_DATA_OFFSET. A corrupt or adversarially crafted
/// page with an inflated dir_count would otherwise cause an integer underflow
/// in readDirEntry's base-address calculation (OOB read in ReleaseFast,
/// panic in ReleaseSafe). SEC-0039.
fn readDirCountChecked(data: []const u8) error{DataCorruption}!u16 {
    const dir_count = readDirCount(data);
    if (dir_count == 0) return 0;
    // Ensure dirOverhead(dir_count) + PROP_DATA_OFFSET <= data.len
    const overhead = dirOverhead(dir_count);
    if (PROP_DATA_OFFSET + overhead > data.len) return error.DataCorruption;
    return dir_count;
}

/// Write the directory entry count to the last 2 bytes of a page.
fn writeDirCount(data: []u8, count: u16) void {
    std.mem.writeInt(u16, data[data.len - DIR_COUNT_SIZE ..][0..DIR_COUNT_SIZE], count, .little);
}

/// Read a directory entry by index (0-based, growing backward from end).
fn readDirEntry(data: []const u8, idx: u16) struct { hash: u16, offset: u16 } {
    const base = data.len - DIR_COUNT_SIZE - (@as(usize, idx) + 1) * DIR_ENTRY_SIZE;
    return .{
        .hash = std.mem.readInt(u16, data[base..][0..2], .little),
        .offset = std.mem.readInt(u16, data[base + 2 ..][0..2], .little),
    };
}

/// Write a directory entry at the given index.
fn writeDirEntry(data: []u8, idx: u16, hash: u16, offset: u16) void {
    const base = data.len - DIR_COUNT_SIZE - (@as(usize, idx) + 1) * DIR_ENTRY_SIZE;
    std.mem.writeInt(u16, data[base..][0..2], hash, .little);
    std.mem.writeInt(u16, data[base + 2 ..][0..2], offset, .little);
}

/// Compute the total directory overhead for a given entry count.
fn dirOverhead(dir_count: u16) u32 {
    return DIR_COUNT_SIZE + @as(u32, dir_count) * DIR_ENTRY_SIZE;
}

// ============================================================================
// GAP prop-store slab packing — Phase P1: slab READ path (read-both).
//
// LAYOUT DISCRIMINATION (authoritative scheme): a TAG BIT in prop_head.
//   - Legacy one-page-per-node: prop_head == page_id (a bare PageId); bit 63 is
//     CLEAR. The whole page belongs to one node and reads via the existing
//     page-chain path, unchanged. (Page ids are allocated sequentially and never
//     approach 2^63, so bit 63 is a safe, otherwise-unused discriminator.)
//   - Slab-packed: bit 63 is SET. The remaining bits pack (page_id, slot):
//     bits [24..63) = page_id (39 bits), bits [0..24) = slot index (24 bits).
//     Many nodes' property blobs share one page; the slot directory (offset,len
//     per slot) grows backward from the page tail — mirroring the legacy
//     intra-page entry directory, but the "entries" are now whole per-node blobs.
//
// WHY the tag lives in prop_head and not only the page header: to read a page at
// all you must first know its page id, but legacy interprets the FULL u64 as the
// page id while slab uses only the high bits — so the discriminator must be in
// prop_head. A slab page ALSO stamps a layout_version byte right after the page
// header (defense-in-depth: readers reject a page whose version byte is wrong).
//
// SLAB BLOB format (reuses the legacy property-entry format verbatim):
//   [entry_count: u32 LE] then entry_count × (key_len: u16, key, encoded_value)
// i.e. identical to a legacy page's entry region, minus the per-page
// next_page/entry_count meta and per-page key directory. P1 does NOT write slabs
// (production writers still emit legacy one-page-per-node); it only READS them.
// ============================================================================

/// Tag bit in prop_head marking a slab-packed pointer (vs a legacy page id).
pub const SLAB_TAG_BIT: u64 = @as(u64, 1) << 63;
/// Number of low bits of a slab prop_head used for the slot index.
const SLAB_SLOT_BITS: u6 = 24;
const SLAB_SLOT_MASK: u64 = (@as(u64, 1) << SLAB_SLOT_BITS) - 1;
/// Maximum page id encodable in a slab prop_head (64 - 1 tag - 24 slot = 39).
const SLAB_MAX_PAGE_ID: u64 = @as(u64, 1) << (64 - 1 - SLAB_SLOT_BITS);

/// True when prop_head is a slab-packed pointer (bit 63 set) rather than a
/// legacy bare page id.
pub fn isSlabHead(prop_head: u64) bool {
    return (prop_head & SLAB_TAG_BIT) != 0;
}

/// Encode a legacy prop_head: the bare page id (the slot is the whole page).
/// Provided so callers can drive both layouts through the same accessors.
pub fn encodeLegacyHead(page_id: PageId) u64 {
    return page_id;
}

/// Encode a slab prop_head from (page_id, slot index into the slab directory).
pub fn encodeSlabHead(page_id: PageId, slot: u32) u64 {
    std.debug.assert(page_id < SLAB_MAX_PAGE_ID);
    std.debug.assert(@as(u64, slot) <= SLAB_SLOT_MASK);
    return SLAB_TAG_BIT | (page_id << SLAB_SLOT_BITS) | (@as(u64, slot) & SLAB_SLOT_MASK);
}

/// Decode the page id from a slab prop_head.
pub fn slabPageId(prop_head: u64) PageId {
    return (prop_head & ~SLAB_TAG_BIT) >> SLAB_SLOT_BITS;
}

/// Decode the slot index from a slab prop_head.
pub fn slabSlot(prop_head: u64) u32 {
    return @intCast(prop_head & SLAB_SLOT_MASK);
}

// --- Slab page on-disk layout constants + helpers (also used by P1 tests and
//     the future P2 writer) ---

/// Byte offset (after the 32-byte page header) of the slab layout_version byte.
pub const SLAB_META_OFFSET: u32 = PAGE_HEADER_SIZE;
/// Current slab page layout version.
pub const SLAB_LAYOUT_VERSION: u8 = 1;
/// Size of the slab meta region (version byte + reserved padding).
pub const SLAB_META_SIZE: u32 = 4;
/// First byte at which per-node blobs are stored.
pub const SLAB_DATA_OFFSET: u32 = PAGE_HEADER_SIZE + SLAB_META_SIZE;
/// Size of one slot-directory entry: blob offset (u32) + blob len (u32).
pub const SLAB_SLOT_SIZE: u32 = 8;
/// Size of the slot_count footer (u32 LE) at the very end of the page.
pub const SLAB_SLOT_COUNT_SIZE: u32 = 4;

/// Read the slab slot_count from the last 4 bytes of a (logical) slab page.
pub fn readSlabSlotCount(data: []const u8) u32 {
    return std.mem.readInt(u32, data[data.len - SLAB_SLOT_COUNT_SIZE ..][0..4], .little);
}

/// Write the slab slot_count to the last 4 bytes (tests / P2 writer).
pub fn writeSlabSlotCount(data: []u8, count: u32) void {
    std.mem.writeInt(u32, data[data.len - SLAB_SLOT_COUNT_SIZE ..][0..4], count, .little);
}

/// Base byte offset of slot `idx` in the backward-growing slot directory.
fn slabSlotBase(data_len: usize, idx: u32) usize {
    return data_len - SLAB_SLOT_COUNT_SIZE - (@as(usize, idx) + 1) * SLAB_SLOT_SIZE;
}

/// Read slot `idx`'s (offset, len) from the slab directory.
pub fn readSlabSlot(data: []const u8, idx: u32) struct { offset: u32, len: u32 } {
    const base = slabSlotBase(data.len, idx);
    return .{
        .offset = std.mem.readInt(u32, data[base..][0..4], .little),
        .len = std.mem.readInt(u32, data[base + 4 ..][0..4], .little),
    };
}

/// Write slot `idx`'s (offset, len) into the slab directory (tests / P2 writer).
pub fn writeSlabSlot(data: []u8, idx: u32, offset: u32, len: u32) void {
    const base = slabSlotBase(data.len, idx);
    std.mem.writeInt(u32, data[base..][0..4], offset, .little);
    std.mem.writeInt(u32, data[base + 4 ..][0..4], len, .little);
}

/// Stamp the slab layout_version byte (tests / P2 writer).
pub fn writeSlabLayoutVersion(data: []u8) void {
    data[SLAB_META_OFFSET] = SLAB_LAYOUT_VERSION;
}

/// Slotted-page property storage with overflow.
/// For v1, uses a simple sequential layout within each property page.
pub const PropStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    var_store: *VarStore,
    page_size: u32,
    /// Bytes reserved at the tail of every physical property page for the
    /// page-level AES-GCM authentication tag when at-rest encryption is
    /// enabled. The slotted-page directory (dir_count + dir entries) grows
    /// backward from the LOGICAL page end (page_size - tail_reserve), so it
    /// never collides with the tag that the pager writes into the final
    /// `tail_reserve` bytes on flush. Set to the encryption tag size when a
    /// key is configured, 0 otherwise.
    ///
    /// SEC: Without this reservation the directory footer and the AES-GCM tag
    /// share the last bytes of the page. Within a session reads hit the
    /// decrypted in-memory frame, but after a restart the page is read from
    /// disk where the tag has overwritten dir_count — producing a garbage
    /// count and an integer-overflow panic in readDirEntry. Reserving the tag
    /// tail keeps the directory inside the encrypted body so it round-trips.
    /// Plaintext mode keeps tail_reserve == 0 for backward compatibility.
    tail_reserve: u32 = 0,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, var_store: *VarStore, page_size: u32) PropStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .var_store = var_store,
            .page_size = page_size,
            .tail_reserve = 0,
        };
    }

    /// Trim a physical page buffer to the logical region usable by the
    /// slotted-page layout, excluding the reserved encryption-tag tail.
    /// All directory and entry math operates on this logical slice so the
    /// directory footer stays clear of the AES-GCM tag region.
    inline fn logical(self: *const PropStore, data: []u8) []u8 {
        return data[0 .. data.len - self.tail_reserve];
    }

    /// Usable data bytes per property page (excluding the dir_count footer
    /// and the reserved encryption-tag tail).
    /// The actual available space also depends on the number of directory
    /// entries; callers must subtract dirOverhead(dir_count) separately.
    fn dataCapacity(self: *const PropStore) u32 {
        return self.page_size - PROP_DATA_OFFSET - DIR_COUNT_SIZE - self.tail_reserve;
    }

    /// QUAL-0040: Inter-page walk over a property page chain.
    ///
    /// Owns the single source of truth for the cross-page traversal scaffold
    /// that was previously duplicated across getProperty, findAndRemoveKey,
    /// insertEntry and removeProperty:
    ///   - pin/unpin discipline (one pinned frame at a time, balanced on exit),
    ///   - the MAX_CHAIN_HOPS guard (→ error.CircularChainDetected),
    ///   - readNextPage to advance the chain,
    ///   - the readEntryCountChecked → error.DataCorruption mapping.
    ///
    /// Callers retain only the op-specific intra-page logic. Each `next()` pins
    /// the next page and returns its logical slice plus metadata; the caller
    /// must call `unpinCurrent(dirty)` before the following `next()`. `deinit()`
    /// guarantees the last frame is released even on an early return.
    ///
    /// **Lifetime:** the `data` slice in a returned `Page` points into the
    /// pinned frame and is invalidated by `unpinCurrent`/`next`/`deinit`.
    const PageChainCursor = struct {
        store: *PropStore,
        /// The next page id to pin; 0 means the chain is exhausted.
        pending_page: PageId,
        hops: u32 = 0,
        current_frame_idx: ?u32 = null,

        const Page = struct {
            data: []u8,
            frame_idx: u32,
            page_id: PageId,
            next_page: PageId,
            entry_count: u32,
        };

        fn init(store: *PropStore, head: PageId) PageChainCursor {
            return .{ .store = store, .pending_page = head };
        }

        /// Pin and return the next page in the chain, or null at chain end.
        /// The caller must have already unpinned the previous page (via
        /// unpinCurrent); a debug assert enforces this invariant.
        fn next(self: *PageChainCursor) !?Page {
            std.debug.assert(self.current_frame_idx == null);
            if (self.pending_page == 0) return null;
            if (self.hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            self.hops += 1;

            const page_id = self.pending_page;
            const frame = try self.store.buffer_pool.pin(.props, page_id);
            const frame_idx = self.store.buffer_pool.frameIndex(frame);
            const data = self.store.logical(frame.dataSlice());

            const next_page = readNextPage(data);
            const entry_count = readEntryCountChecked(data, self.store.page_size) catch {
                self.store.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            };

            self.current_frame_idx = frame_idx;
            self.pending_page = next_page;
            return .{
                .data = data,
                .frame_idx = frame_idx,
                .page_id = page_id,
                .next_page = next_page,
                .entry_count = entry_count,
            };
        }

        /// Release the currently pinned page, marking it dirty when requested.
        fn unpinCurrent(self: *PageChainCursor, dirty: bool) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, dirty);
                self.current_frame_idx = null;
            }
        }

        /// Release any still-pinned page; safe to call unconditionally.
        fn deinit(self: *PageChainCursor) void {
            self.unpinCurrent(false);
        }
    };

    /// Get a property value by key from a property page chain.
    /// Returns null if not found.
    ///
    /// PERF-0023: When a per-page key directory is present (dir_count > 0),
    /// the search key is hashed and looked up in the directory for O(1) access.
    /// Falls back to linear scan for legacy pages or on hash collision miss.
    pub fn getProperty(self: *PropStore, prop_head: u64, key: []const u8, allocator: Allocator) !?PropertyValue {
        if (prop_head == 0) return null;

        // GAP prop-store slab packing (P1): slab-packed heads read via the slab
        // path; legacy bare-page-id heads fall through to the chain path below.
        if (isSlabHead(prop_head)) return self.getSlabProperty(prop_head, key, allocator);

        var cursor = PageChainCursor.init(self, prop_head);
        defer cursor.deinit();
        while (try cursor.next()) |page| {
            const data = page.data;

            // PERF-0023: Try directory-based lookup first.
            const dir_count = readDirCountChecked(data) catch {
                cursor.unpinCurrent(false);
                return error.DataCorruption;
            };
            if (dir_count > 0) {
                const target_hash = keyHash(key);
                var di: u16 = 0;
                while (di < dir_count) : (di += 1) {
                    const entry = readDirEntry(data, di);
                    if (entry.hash == target_hash) {
                        // Candidate match — verify the actual key at the stored offset.
                        const off = @as(u32, entry.offset);
                        if (off + 2 <= data.len) {
                            const key_len = std.mem.bytesToValue(u16, data[off..][0..2]);
                            if (off + 2 + key_len <= data.len) {
                                const entry_key = data[off + 2 ..][0..key_len];
                                if (std.mem.eql(u8, entry_key, key)) {
                                    const val_start = off + 2 + key_len;
                                    const decode_result = try property_mod.decode(allocator, data[val_start..]);
                                    cursor.unpinCurrent(false);
                                    return decode_result.value;
                                }
                            }
                        }
                        // Hash collision — continue scanning directory entries.
                    }
                }
                // If directory was present but key not found, skip to next page
                // (no need to linear-scan since directory is authoritative).
                cursor.unpinCurrent(false);
                continue;
            }

            // Legacy path: linear scan when dir_count == 0.
            var offset: u32 = PROP_DATA_OFFSET;
            var i: u32 = 0;
            while (i < page.entry_count) : (i += 1) {
                if (offset + 2 > data.len) return error.DataCorruption;
                const key_len = std.mem.bytesToValue(u16, data[offset..][0..2]);
                offset += 2;
                if (offset + key_len > data.len) return error.DataCorruption;
                const entry_key = data[offset..][0..key_len];
                offset += key_len;

                if (std.mem.eql(u8, entry_key, key)) {
                    // Found it — decode the value
                    const decode_result = try property_mod.decode(allocator, data[offset..]);
                    cursor.unpinCurrent(false);
                    return decode_result.value;
                }

                // Not the key we want: skip value by encoded size (no heap alloc)
                const val_size = try encodedSizeFromBytes(data[offset..]);
                offset += @intCast(val_size);
            }

            cursor.unpinCurrent(false);
        }

        return null;
    }

    /// GAP prop-store slab packing (P1): resolve the (offset,len) of the blob
    /// for `slot` on a slab-format logical page, with full bounds validation.
    /// Returns error.DataCorruption on any inconsistency (bad version, slot out
    /// of range, directory/blob overrun) — it never reads out of bounds.
    fn slabBlobSpan(_: *const PropStore, data: []const u8, slot: u32) error{DataCorruption}!struct { offset: u32, len: u32 } {
        // Must at least hold the meta region and the slot_count footer.
        if (data.len < SLAB_DATA_OFFSET + SLAB_SLOT_COUNT_SIZE) return error.DataCorruption;
        if (data[SLAB_META_OFFSET] != SLAB_LAYOUT_VERSION) return error.DataCorruption;

        const slot_count = readSlabSlotCount(data);
        // The whole directory (slot_count entries + the count footer) must fit
        // above SLAB_DATA_OFFSET. Use u64 math so a crafted slot_count cannot wrap.
        const dir_bytes: u64 = @as(u64, SLAB_SLOT_COUNT_SIZE) + @as(u64, slot_count) * SLAB_SLOT_SIZE;
        if (@as(u64, SLAB_DATA_OFFSET) + dir_bytes > data.len) return error.DataCorruption;
        if (slot >= slot_count) return error.DataCorruption;

        const s = readSlabSlot(data, slot);
        const dir_start: u32 = @intCast(@as(u64, data.len) - dir_bytes);
        // The blob must live entirely in [SLAB_DATA_OFFSET, dir_start).
        if (s.offset < SLAB_DATA_OFFSET or s.offset > dir_start) return error.DataCorruption;
        if (@as(u64, s.offset) + @as(u64, s.len) > dir_start) return error.DataCorruption;
        return .{ .offset = s.offset, .len = s.len };
    }

    /// GAP prop-store slab packing (P1): read a single property by key from a
    /// slab-packed blob addressed by prop_head = (page_id, slot). Parses the
    /// blob's property entries with the exact legacy entry format.
    fn getSlabProperty(self: *PropStore, prop_head: u64, key: []const u8, allocator: Allocator) !?PropertyValue {
        const page_id = slabPageId(prop_head);
        const slot = slabSlot(prop_head);

        const frame = try self.buffer_pool.pin(.props, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        defer self.buffer_pool.unpin(frame_idx, false);

        const data = self.logical(frame.dataSlice());
        const span = try self.slabBlobSpan(data, slot);
        const blob = data[span.offset..][0..span.len];

        if (blob.len < 4) return error.DataCorruption;
        const entry_count = std.mem.readInt(u32, blob[0..4], .little);
        var off: u32 = 4;
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (off + 2 > blob.len) return error.DataCorruption;
            const key_len = std.mem.bytesToValue(u16, blob[off..][0..2]);
            off += 2;
            if (off + key_len > blob.len) return error.DataCorruption;
            const entry_key = blob[off..][0..key_len];
            off += key_len;

            const val_size = try encodedSizeFromBytes(blob[off..]);
            if (std.mem.eql(u8, entry_key, key)) {
                const decode_result = try property_mod.decode(allocator, blob[off..]);
                return decode_result.value;
            }
            off += @intCast(val_size);
        }
        return null;
    }

    pub const PropertyEntrySlice = struct {
        key: []const u8,
        encoded_value: []const u8,
    };

    /// Zero-allocation iterator over property entries in a page chain.
    ///
    /// **Lifetime:** Returned `PropertyEntrySlice` values contain slices that
    /// point directly into pinned buffer pool frames. These slices become
    /// invalid after the next call to `next()` (which may unpin the current
    /// frame and pin a new one) or after `deinit()` is called. Callers must
    /// copy any key or encoded_value data they need to retain beyond the
    /// current iteration step.
    pub const PropIterator = struct {
        store: *PropStore,
        current_page: u64,
        current_frame_idx: ?u32 = null,
        current_index: u32 = 0,
        current_offset: u32 = PROP_DATA_OFFSET,
        entry_count_cache: u32 = 0,
        hops: u32 = 0,
        /// GAP prop-store slab packing (P1): when set, the head is a slab
        /// pointer; iterate one blob (no page chain) via `slab_slot`.
        is_slab: bool = false,
        slab_slot: u32 = 0,
        /// Absolute end offset (within the logical page) of the slab blob.
        slab_blob_end: u32 = 0,

        pub fn deinit(self: *PropIterator) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, false);
                self.current_frame_idx = null;
            }
        }

        pub fn next(self: *PropIterator) anyerror!?PropertyEntrySlice {
            if (self.is_slab) return self.nextSlab();
            while (self.current_page != 0) {
                if (self.current_frame_idx == null) {
                    if (self.hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
                    const frame = try self.store.buffer_pool.pin(.props, self.current_page);
                    self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                    const data = self.store.logical(frame.dataSlice());
                    self.entry_count_cache = try readEntryCountChecked(data, self.store.page_size);
                    self.current_offset = PROP_DATA_OFFSET;
                    self.hops += 1;
                }

                const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
                const data = self.store.logical(frame.dataSlice());

                if (self.current_index < self.entry_count_cache) {
                    if (self.current_offset + 2 > data.len) return error.DataCorruption;
                    const key_len = std.mem.bytesToValue(u16, data[self.current_offset..][0..2]);
                    self.current_offset += 2;
                    if (self.current_offset + key_len > data.len) return error.DataCorruption;

                    const entry_key = data[self.current_offset..][0..key_len];
                    self.current_offset += key_len;

                    const val_size = try encodedSizeFromBytes(data[self.current_offset..]);
                    const encoded_val = data[self.current_offset..][0..val_size];
                    self.current_offset += @intCast(val_size);

                    self.current_index += 1;

                    return PropertyEntrySlice{
                        .key = entry_key,
                        .encoded_value = encoded_val,
                    };
                }

                const next_page = readNextPage(data);
                self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                self.current_frame_idx = null;
                self.current_page = next_page;
                self.current_index = 0;
                self.current_offset = PROP_DATA_OFFSET;
            }

            return null;
        }

        /// GAP prop-store slab packing (P1): iterate the entries of a single
        /// slab blob addressed by (current_page, slab_slot). No page chaining —
        /// a slab node's whole property set lives in one blob in P1.
        fn nextSlab(self: *PropIterator) anyerror!?PropertyEntrySlice {
            if (self.current_page == 0) return null;

            if (self.current_frame_idx == null) {
                const frame = try self.store.buffer_pool.pin(.props, self.current_page);
                self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                const data = self.store.logical(frame.dataSlice());
                const span = self.store.slabBlobSpan(data, self.slab_slot) catch |err| {
                    self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                    self.current_frame_idx = null;
                    return err;
                };
                if (span.len < 4) {
                    self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                    self.current_frame_idx = null;
                    return error.DataCorruption;
                }
                const blob = data[span.offset..][0..span.len];
                self.entry_count_cache = std.mem.readInt(u32, blob[0..4], .little);
                self.current_offset = span.offset + 4;
                self.slab_blob_end = span.offset + span.len;
                self.current_index = 0;
            }

            const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
            const data = self.store.logical(frame.dataSlice());
            const end = self.slab_blob_end;

            if (self.current_index < self.entry_count_cache) {
                if (self.current_offset + 2 > end) return error.DataCorruption;
                const key_len = std.mem.bytesToValue(u16, data[self.current_offset..][0..2]);
                self.current_offset += 2;
                if (self.current_offset + key_len > end) return error.DataCorruption;

                const entry_key = data[self.current_offset..][0..key_len];
                self.current_offset += key_len;

                const val_size = try encodedSizeFromBytes(data[self.current_offset..end]);
                const encoded_val = data[self.current_offset..][0..val_size];
                self.current_offset += @intCast(val_size);

                self.current_index += 1;

                return PropertyEntrySlice{
                    .key = entry_key,
                    .encoded_value = encoded_val,
                };
            }

            // Blob exhausted: release the frame and stop (no chain in P1).
            self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
            self.current_frame_idx = null;
            self.current_page = 0;
            return null;
        }
    };

    /// Get an iterator over all properties in a property page chain (zero allocation).
    pub fn getAllProperties(self: *PropStore, prop_head: u64) PropIterator {
        // GAP prop-store slab packing (P1): a slab head iterates a single blob;
        // a legacy head walks the page chain as before.
        if (isSlabHead(prop_head)) {
            return .{
                .store = self,
                .current_page = slabPageId(prop_head),
                .is_slab = true,
                .slab_slot = slabSlot(prop_head),
            };
        }
        return .{
            .store = self,
            .current_page = prop_head,
        };
    }

    /// Put a property. Returns the (possibly new) prop_head.
    /// If the key already exists, it is replaced (remove + re-add).
    ///
    /// PERF-0002: Combined find-and-remove pass reduces 3 chain traversals
    /// to at most 2 (find+remove in pass 1, insert in pass 2).
    /// QUAL-0026: Decomposed into findAndRemoveKey + insertEntry helpers.
    pub fn putProperty(self: *PropStore, prop_head: u64, key: []const u8, val: PropertyValue) !u64 {
        if (key.len > std.math.maxInt(u16)) return error.PropertyKeyTooLong;

        // PERF-0022: Use a stack buffer for small fixed-size types to avoid
        // heap allocation on every putProperty call.
        var stack_buf: [32]u8 = undefined;
        const size = property_mod.encodedSize(val);
        var heap_alloc: ?[]const u8 = null;
        const encoded_val: []const u8 = if (size <= stack_buf.len) blk: {
            const n = property_mod.encodeInto(&stack_buf, val) catch unreachable;
            break :blk stack_buf[0..n];
        } else blk: {
            const h = try property_mod.encode(self.buffer_pool.allocator, val);
            heap_alloc = h;
            break :blk h;
        };
        defer if (heap_alloc) |h| self.buffer_pool.allocator.free(h);

        const entry_size: u32 = 2 + @as(u32, @intCast(key.len)) + @as(u32, @intCast(encoded_val.len));

        // Guard: an entry that cannot fit on any single fresh property page
        // (key_len field + key bytes + encoded value + one directory slot) would
        // cause an out-of-bounds write in writePropertyEntry for both the
        // prop_head==0 fast path and the overflow-page allocation in insertEntry.
        // Treat this as an oversized key even when the u16 range guard above
        // passed, because the key is still too long for the configured page size.
        if (entry_size > self.dataCapacity() -| DIR_ENTRY_SIZE) return error.PropertyKeyTooLong;

        if (prop_head == 0) {
            // Allocate new property page
            const new_page = try self.free_space.allocPage();
            const frame = try self.buffer_pool.pinNew(.props, new_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = self.logical(frame.dataSlice());

            writeNextPage(data, 0);
            writeEntryCount(data, 1);
            self.writePropertyEntry(data, PROP_DATA_OFFSET, key, encoded_val);

            // PERF-0023: Initialize directory with the first entry.
            writeDirCount(data, 1);
            writeDirEntry(data, 0, keyHash(key), PROP_DATA_OFFSET);

            self.buffer_pool.unpin(frame_idx, true);
            return new_page;
        }

        // Pass 1: find and remove existing key. If the key is found and
        // there is enough space on the same page, inserts immediately
        // (PERF-0021 fast path) and returns the prop_head directly.
        if (try self.findAndRemoveKey(prop_head, key, encoded_val, entry_size)) |head| {
            return head;
        }

        // Pass 2: insert the new entry into the first page with space,
        // allocating an overflow page if necessary.
        return try self.insertEntry(prop_head, key, encoded_val, entry_size);
    }

    /// Pass 1: Scan the chain to find and remove an existing key.
    /// Returns prop_head if the entry was removed and re-inserted on the
    /// same page (PERF-0021 fast path), or null if Pass 2 is needed.
    fn findAndRemoveKey(
        self: *PropStore,
        prop_head: u64,
        key: []const u8,
        encoded_val: []const u8,
        entry_size: u32,
    ) !?u64 {
        var cursor = PageChainCursor.init(self, prop_head);
        defer cursor.deinit();
        while (try cursor.next()) |page| {
            const data = page.data;

            if (try self.findEntrySpan(data, page.entry_count, key)) |span| {
                const removal = try self.removeEntryAt(data, page.entry_count, span);
                const entry_count = removal.entry_count;

                // PERF-0021: Check if freed space is enough for the new entry.
                const used_after_remove = removal.new_end - PROP_DATA_OFFSET;
                const new_dir_size = @as(u32, entry_count + 1) * DIR_ENTRY_SIZE;
                const available = self.dataCapacity() -| (used_after_remove + new_dir_size);
                if (available >= entry_size) {
                    self.writePropertyEntry(data, removal.new_end, key, encoded_val);
                    writeEntryCount(data, entry_count + 1);
                    rebuildDirectory(data, entry_count + 1, self.page_size);
                    cursor.unpinCurrent(true);
                    return prop_head;
                }

                writeEntryCount(data, entry_count);
                rebuildDirectory(data, entry_count, self.page_size);
                cursor.unpinCurrent(true);

                // Key removed but page too full; caller needs Pass 2.
                return null;
            } else {
                cursor.unpinCurrent(false);
                continue;
            }
        }
        // Key not found anywhere in chain; Pass 2 will insert.
        return null;
    }

    /// Pass 2: Find space in the chain and insert the new entry.
    /// Allocates an overflow page if no existing page has room.
    fn insertEntry(
        self: *PropStore,
        prop_head: u64,
        key: []const u8,
        encoded_val: []const u8,
        entry_size: u32,
    ) !u64 {
        var cursor = PageChainCursor.init(self, prop_head);
        defer cursor.deinit();
        while (try cursor.next()) |page| {
            const data = page.data;

            const used = try self.usedBytes(data, page.entry_count);
            const new_dir_size = @as(u32, page.entry_count + 1) * DIR_ENTRY_SIZE;
            const available = self.dataCapacity() -| (used + new_dir_size);

            if (available >= entry_size) {
                const write_offset = PROP_DATA_OFFSET + used;
                self.writePropertyEntry(data, write_offset, key, encoded_val);
                writeEntryCount(data, page.entry_count + 1);

                // PERF-0038: Append a single directory entry.
                const new_count: u16 = @intCast(page.entry_count + 1);
                writeDirCount(data, new_count);
                writeDirEntry(data, @intCast(page.entry_count), keyHash(key), @intCast(write_offset));

                cursor.unpinCurrent(true);
                return prop_head;
            }

            if (page.next_page == 0) {
                // Allocate overflow page.
                const new_page = try self.free_space.allocPage();
                const new_frame = try self.buffer_pool.pinNew(.props, new_page);
                const new_frame_idx = self.buffer_pool.frameIndex(new_frame);
                const new_data = self.logical(new_frame.dataSlice());

                writeNextPage(new_data, 0);
                writeEntryCount(new_data, 1);
                self.writePropertyEntry(new_data, PROP_DATA_OFFSET, key, encoded_val);

                writeDirCount(new_data, 1);
                writeDirEntry(new_data, 0, keyHash(key), PROP_DATA_OFFSET);

                self.buffer_pool.unpin(new_frame_idx, true);

                // Link the freshly allocated overflow page onto the current
                // page's tail; the cursor still holds the current frame pinned.
                writeNextPage(data, new_page);
                cursor.unpinCurrent(true);
                return prop_head;
            }

            cursor.unpinCurrent(false);
        }

        return error.DataCorruption;
    }

    /// Remove a property by key. Scans all pages in the chain.
    /// Compacts the page by shifting remaining entries forward.
    pub fn removeProperty(self: *PropStore, prop_head: u64, key: []const u8) !void {
        if (prop_head == 0) return;

        var cursor = PageChainCursor.init(self, prop_head);
        defer cursor.deinit();
        while (try cursor.next()) |page| {
            const data = page.data;

            if (try self.findEntrySpan(data, page.entry_count, key)) |span| {
                const removal = try self.removeEntryAt(data, page.entry_count, span);
                writeEntryCount(data, removal.entry_count);
                rebuildDirectory(data, removal.entry_count, self.page_size);
                cursor.unpinCurrent(true);
                return;
            }

            cursor.unpinCurrent(false);
        }
    }

    // Internal helpers

    const EntryCursor = struct {
        offset: u32 = PROP_DATA_OFFSET,
    };

    const ParsedEntry = struct {
        key: []const u8,
        value_offset: u32,
        value_size: usize,
    };

    const EntrySpan = struct {
        index: u32,
        start: u32,
        end: u32,
    };

    const RemovalResult = struct {
        entry_count: u32,
        new_end: u32,
        total_used: u32,
    };

    fn readEntryAt(_: *const PropStore, data: []const u8, cursor: *EntryCursor) !ParsedEntry {
        if (cursor.offset + 2 > data.len) return error.DataCorruption;
        const key_len = std.mem.bytesToValue(u16, data[cursor.offset..][0..2]);
        cursor.offset += 2;
        if (cursor.offset + key_len > data.len) return error.DataCorruption;
        const entry_key = data[cursor.offset..][0..key_len];
        cursor.offset += key_len;

        const value_offset = cursor.offset;
        const value_size = try encodedSizeFromBytes(data[value_offset..]);
        cursor.offset += @intCast(value_size);

        return .{
            .key = entry_key,
            .value_offset = value_offset,
            .value_size = value_size,
        };
    }

    fn findEntrySpan(self: *const PropStore, data: []const u8, entry_count: u32, key: []const u8) !?EntrySpan {
        var cursor: EntryCursor = .{};
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const entry_start = cursor.offset;
            const entry = try self.readEntryAt(data, &cursor);
            if (std.mem.eql(u8, entry.key, key)) {
                return .{
                    .index = i,
                    .start = entry_start,
                    .end = cursor.offset,
                };
            }
        }
        return null;
    }

    fn compactEntryRange(_: *const PropStore, data: []u8, entry_start: u32, entry_end: u32, total_used: u32) u32 {
        const remaining = total_used - entry_end;
        if (remaining > 0) {
            std.mem.copyForwards(u8, data[entry_start..], data[entry_end..][0..remaining]);
        }

        const new_end = entry_start + remaining;
        @memset(data[new_end..total_used], 0);
        return new_end;
    }

    fn removeEntryAt(self: *const PropStore, data: []u8, entry_count: u32, span: EntrySpan) !RemovalResult {
        const total_used = PROP_DATA_OFFSET + try self.usedBytes(data, entry_count);
        const new_end = self.compactEntryRange(data, span.start, span.end, total_used);
        return .{
            .entry_count = entry_count - 1,
            .new_end = new_end,
            .total_used = total_used,
        };
    }

    fn writePropertyEntry(_: *const PropStore, data: []u8, offset: u32, key: []const u8, encoded_val: []const u8) void {
        var off = offset;
        const key_len: u16 = @intCast(key.len);
        @memcpy(data[off..][0..2], &std.mem.toBytes(key_len));
        off += 2;
        @memcpy(data[off..][0..key.len], key);
        off += @intCast(key.len);
        @memcpy(data[off..][0..encoded_val.len], encoded_val);
    }

    fn usedBytes(self: *const PropStore, data: []const u8, entry_count: u32) !u32 {
        var cursor: EntryCursor = .{};
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            _ = try self.readEntryAt(data, &cursor);
        }
        return cursor.offset - PROP_DATA_OFFSET;
    }
};

/// Determine the encoded size of a property value from its raw bytes.
/// This avoids needing to fully decode the value.
/// Returns error.DataCorruption if the encoded length exceeds available bytes.
fn encodedSizeFromBytes(bytes: []const u8) error{ InvalidData, DataCorruption }!usize {
    if (bytes.len < 1) return error.DataCorruption;
    const tag: property_mod.Tag = std.enums.fromInt(property_mod.Tag, bytes[0]) orelse return error.InvalidData;
    const size: usize = switch (tag) {
        .null => 1,
        .bool => 2,
        .int => 9,
        .float => 9,
        .string => blk: {
            if (bytes.len < 5) return error.DataCorruption;
            const len = std.mem.bytesToValue(u32, bytes[1..5]);
            break :blk 5 + @as(usize, len);
        },
        .decimal => 18,
        .ext => blk: {
            if (bytes.len < 7) return error.DataCorruption;
            const data_len = std.mem.bytesToValue(u32, bytes[3..7]);
            break :blk 7 + @as(usize, data_len);
        },
    };
    if (size > bytes.len) return error.DataCorruption;
    return size;
}

fn readNextPage(data: []const u8) PageId {
    return std.mem.bytesToValue(u64, data[PAGE_HEADER_SIZE..][0..8]);
}

fn readEntryCount(data: []const u8) u32 {
    return std.mem.bytesToValue(u32, data[PAGE_HEADER_SIZE + 8 ..][0..4]);
}

/// Read entry_count with bounds validation: the minimum entry size is 3 bytes
/// (2-byte key_len + 1-byte value tag), so entry_count * 3 must fit in the
/// data capacity (minus DIR_COUNT_SIZE for the directory footer).
fn readEntryCountChecked(data: []const u8, page_size: u32) error{DataCorruption}!u32 {
    // `data` is the logical page slice (physical page minus any reserved
    // encryption-tag tail), so derive the capacity from data.len rather than
    // the physical page_size to keep the corruption bound tight when at-rest
    // encryption reserves a tail. page_size is retained for call-site
    // compatibility but data.len is authoritative.
    _ = page_size;
    const entry_count = readEntryCount(data);
    const capacity = @as(u32, @intCast(data.len)) - PROP_DATA_OFFSET - DIR_COUNT_SIZE;
    // Minimum entry is 2 (key_len) + 0 (key) + 1 (tag) = 3 bytes
    // Plus DIR_ENTRY_SIZE bytes of directory overhead per entry.
    const min_per_entry = 3 + DIR_ENTRY_SIZE;
    const max_entries = capacity / min_per_entry;
    if (entry_count > max_entries) return error.DataCorruption;
    return entry_count;
}

fn writeNextPage(data: []u8, page_id: PageId) void {
    @memcpy(data[PAGE_HEADER_SIZE..][0..8], &std.mem.toBytes(page_id));
}

fn writeEntryCount(data: []u8, count: u32) void {
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(count));
}

/// PERF-0023: Rebuild the per-page key directory by scanning all entries.
/// This is called after insertions and removals to keep the directory
/// consistent with the entry data. The scan is O(entry_count) which is
/// bounded by the page size.
///
/// Two-phase approach: first scan to check whether ALL entries fit within the
/// space that would remain after reserving the directory region (max_dir_end).
/// Only when every entry fits do we perform the second pass that writes the
/// directory entries. This prevents partial directory writes from landing inside
/// the entry data region for pages that were constructed without directory
/// overhead (legacy / manually crafted), which would corrupt those entries.
fn rebuildDirectory(data: []u8, entry_count: u32, page_size: u32) void {
    _ = page_size;
    // Lowest address at which a directory entry can safely be placed:
    //   max_dir_end = data.len - DIR_COUNT_SIZE - entry_count * DIR_ENTRY_SIZE
    // If any entry's data pointer exceeds this boundary the directory cannot
    // be placed without overlapping the entry data — disable it.
    const max_dir_end = data.len - DIR_COUNT_SIZE - @as(usize, entry_count) * DIR_ENTRY_SIZE;

    // Phase 1: pre-flight check. Scan all entries without writing anything.
    // If any entry pushes the data pointer past max_dir_end, disable the
    // directory immediately (no writes at all) so that entry data is never
    // corrupted by partially-written directory entries.
    {
        var off: u32 = PROP_DATA_OFFSET;
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (off + 2 > data.len) break;
            const key_len = std.mem.bytesToValue(u16, data[off..][0..2]);
            off += 2;
            if (off + key_len > data.len) break;
            off += key_len;
            const val_size = encodedSizeFromBytes(data[off..]) catch break;
            off += @intCast(val_size);
            if (off > max_dir_end) {
                writeDirCount(data, 0);
                return;
            }
        }
    }

    // Phase 2: all entries fit — build the directory.
    var off: u32 = PROP_DATA_OFFSET;
    var di: u16 = 0;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const entry_off = off;
        if (off + 2 > data.len) break;
        const key_len = std.mem.bytesToValue(u16, data[off..][0..2]);
        off += 2;
        if (off + key_len > data.len) break;
        const k = data[off..][0..key_len];
        off += key_len;
        const val_size = encodedSizeFromBytes(data[off..]) catch break;
        off += @intCast(val_size);
        writeDirEntry(data, di, keyHash(k), @intCast(entry_off));
        di += 1;
    }

    writeDirCount(data, di);
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const testing_support_mod = @import("testing_support.zig");
const DualStoreEnv = testing_support_mod.DualStoreEnv;

const PropTestEnv = struct {
    base: DualStoreEnv,
    vs: VarStore,

    fn init() !PropTestEnv {
        var base = try DualStoreEnv.init(
            testing.allocator,
            .props,
            .props,
            "props.store",
            .var_store,
            "var.store",
            4096,
            32,
        );
        base.register();
        return .{
            .base = base,
            .vs = VarStore.init(&base.pool, &base.fsm, 4096),
        };
    }

    fn pool(self: *PropTestEnv) *BufferPool {
        return &self.base.pool;
    }

    fn fsm(self: *PropTestEnv) *FreeSpaceManager {
        return &self.base.fsm;
    }

    fn deinit(self: *PropTestEnv) void {
        self.base.deinit();
    }
};

test "putProperty + getProperty round-trip: int" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "age", .{ .int = 30 });
    try testing.expect(head != 0);

    const val = try store.getProperty(head, "age", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 30), val.?.int);
}

test "putProperty + getProperty round-trip: string" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "name", .{ .string = "Alice" });

    const val = try store.getProperty(head, "name", testing.allocator);
    try testing.expect(val != null);
    defer property_mod.freeDecoded(testing.allocator, val.?);
    try testing.expectEqualStrings("Alice", val.?.string);
}

test "putProperty + getProperty round-trip: bool" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "active", .{ .bool = true });
    const val = try store.getProperty(head, "active", testing.allocator);
    try testing.expect(val != null);
    try testing.expect(val.?.bool);
}

test "putProperty + getProperty round-trip: float" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "score", .{ .float = 3.14 });
    const val = try store.getProperty(head, "score", testing.allocator);
    try testing.expect(val != null);
    try testing.expectApproxEqAbs(@as(f64, 3.14), val.?.float, 0.001);
}

test "putProperty + getProperty round-trip: null" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "nothing", PropertyValue.null);
    const val = try store.getProperty(head, "nothing", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(PropertyValue.null, val.?);
}

test "getAllProperties returns all stored properties" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "name", .{ .string = "Bob" });
    head = try store.putProperty(head, "age", .{ .int = 25 });
    head = try store.putProperty(head, "active", .{ .bool = false });

    var iter = store.getAllProperties(head);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}

test "removeProperty removes the property" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "x", .{ .int = 1 });
    head = try store.putProperty(head, "y", .{ .int = 2 });
    head = try store.putProperty(head, "z", .{ .int = 3 });

    try store.removeProperty(head, "y");

    const val = try store.getProperty(head, "y", testing.allocator);
    try testing.expect(val == null);

    // x and z should still be there
    const vx = try store.getProperty(head, "x", testing.allocator);
    try testing.expect(vx != null);
    try testing.expectEqual(@as(i64, 1), vx.?.int);

    const vz = try store.getProperty(head, "z", testing.allocator);
    try testing.expect(vz != null);
    try testing.expectEqual(@as(i64, 3), vz.?.int);
}

test "multiple properties on same entity" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "a", .{ .int = 1 });
    head = try store.putProperty(head, "b", .{ .int = 2 });
    head = try store.putProperty(head, "c", .{ .int = 3 });
    head = try store.putProperty(head, "d", .{ .int = 4 });

    const va = try store.getProperty(head, "a", testing.allocator);
    try testing.expectEqual(@as(i64, 1), va.?.int);

    const vd = try store.getProperty(head, "d", testing.allocator);
    try testing.expectEqual(@as(i64, 4), vd.?.int);
}

test "getProperty returns null for nonexistent key" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "x", .{ .int = 1 });
    const val = try store.getProperty(head, "nope", testing.allocator);
    try testing.expect(val == null);
}

test "getProperty returns null for empty prop_head" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const val = try store.getProperty(0, "anything", testing.allocator);
    try testing.expect(val == null);
}

test "putProperty replace-in-place uses single-pass optimization" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Write a property then replace it with a value of same or smaller size.
    // This exercises the PERF-0021 in-place replacement path.
    var head = try store.putProperty(0, "counter", .{ .int = 100 });
    head = try store.putProperty(head, "counter", .{ .int = 999 });

    const val = try store.getProperty(head, "counter", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 999), val.?.int);

    // Verify only one entry exists (no duplicate after replace)
    var iter = store.getAllProperties(head);
    defer iter.deinit();
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "encodedSizeFromBytes rejects invalid property tag byte" {
    const bad_bytes = [_]u8{0xFF}; // 0xFF is not a valid property_mod.Tag
    try testing.expectError(error.InvalidData, encodedSizeFromBytes(&bad_bytes));
}

test "encodedSizeFromBytes returns DataCorruption for empty input" {
    const empty: []const u8 = &.{};
    try testing.expectError(error.DataCorruption, encodedSizeFromBytes(empty));
}

test "encodedSizeFromBytes returns DataCorruption for truncated string" {
    // string tag with only 2 bytes (needs at least 5 for tag + u32 length)
    const truncated = [_]u8{ @intFromEnum(property_mod.Tag.string), 0x05 };
    try testing.expectError(error.DataCorruption, encodedSizeFromBytes(&truncated));
}

test "encodedSizeFromBytes returns DataCorruption for string length exceeding buffer" {
    // string tag with length 100 but only 9 bytes total
    var buf: [9]u8 = undefined;
    buf[0] = @intFromEnum(property_mod.Tag.string);
    @memcpy(buf[1..5], &std.mem.toBytes(@as(u32, 100)));
    try testing.expectError(error.DataCorruption, encodedSizeFromBytes(&buf));
}

test "readEntryCountChecked rejects entry_count exceeding page capacity" {
    // Build a fake page buffer with an absurdly large entry_count
    var data: [4096]u8 = undefined;
    @memset(&data, 0);
    // Write entry_count = 10000 which is way more than (4096 - PROP_DATA_OFFSET) / 3
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(@as(u32, 10000)));
    try testing.expectError(error.DataCorruption, readEntryCountChecked(&data, 4096));
}

test "readEntryCountChecked accepts valid entry_count" {
    var data: [4096]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(@as(u32, 5)));
    const count = try readEntryCountChecked(&data, 4096);
    try testing.expectEqual(@as(u32, 5), count);
}

// ============================================================================
// PERF-0023: Per-page key directory tests
// ============================================================================

test "PERF-0023: directory is created on put and used for lookup" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Insert 10 properties and verify each is found via directory.
    var head: u64 = 0;
    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa" };
    for (keys, 0..) |k, idx| {
        head = try store.putProperty(head, k, .{ .int = @intCast(idx) });
    }

    // Verify each key is found.
    for (keys, 0..) |k, idx| {
        const val = try store.getProperty(head, k, testing.allocator);
        try testing.expect(val != null);
        try testing.expectEqual(@as(i64, @intCast(idx)), val.?.int);
    }

    // Verify the directory is present on the page by pinning and reading dir_count.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    const dir_count = readDirCount(data);
    try testing.expect(dir_count == 10);
    env.pool().unpin(frame_idx, false);
}

test "PERF-0023: hash collision still finds correct key" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Find two keys that produce the same hash to test collision handling.
    // We'll brute-force a collision with the keyHash function.
    var collision_key: [8]u8 = undefined;
    const target_hash = keyHash("testkey");
    var found_collision = false;
    var seed: u32 = 0;
    while (seed < 1_000_000) : (seed += 1) {
        const bytes = std.mem.toBytes(seed);
        @memcpy(collision_key[0..4], &bytes);
        @memcpy(collision_key[4..8], "COLL");
        if (keyHash(&collision_key) == target_hash and !std.mem.eql(u8, &collision_key, "testkey")) {
            found_collision = true;
            break;
        }
    }

    if (!found_collision) {
        // Extremely unlikely but skip if no collision found in reasonable range.
        return;
    }

    var head = try store.putProperty(0, "testkey", .{ .int = 42 });
    head = try store.putProperty(head, &collision_key, .{ .int = 99 });

    // Both keys should be retrievable despite same hash.
    const val1 = try store.getProperty(head, "testkey", testing.allocator);
    try testing.expect(val1 != null);
    try testing.expectEqual(@as(i64, 42), val1.?.int);

    const val2 = try store.getProperty(head, &collision_key, testing.allocator);
    try testing.expect(val2 != null);
    try testing.expectEqual(@as(i64, 99), val2.?.int);
}

test "PERF-0023: legacy page without directory uses linear scan" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Create a page with entries but manually zero out the directory.
    var head = try store.putProperty(0, "key1", .{ .int = 10 });
    head = try store.putProperty(head, "key2", .{ .int = 20 });

    // Manually set dir_count to 0 to simulate a legacy page.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    writeDirCount(data, 0);
    env.pool().unpin(frame_idx, true);

    // Linear scan fallback should still find both keys.
    const val1 = try store.getProperty(head, "key1", testing.allocator);
    try testing.expect(val1 != null);
    try testing.expectEqual(@as(i64, 10), val1.?.int);

    const val2 = try store.getProperty(head, "key2", testing.allocator);
    try testing.expect(val2 != null);
    try testing.expectEqual(@as(i64, 20), val2.?.int);
}

test "PERF-0023: directory survives put-replace cycle" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "x", .{ .int = 1 });
    head = try store.putProperty(head, "y", .{ .int = 2 });
    head = try store.putProperty(head, "z", .{ .int = 3 });

    // Replace y
    head = try store.putProperty(head, "y", .{ .int = 222 });

    // Verify all accessible
    const vx = try store.getProperty(head, "x", testing.allocator);
    try testing.expectEqual(@as(i64, 1), vx.?.int);

    const vy = try store.getProperty(head, "y", testing.allocator);
    try testing.expectEqual(@as(i64, 222), vy.?.int);

    const vz = try store.getProperty(head, "z", testing.allocator);
    try testing.expectEqual(@as(i64, 3), vz.?.int);

    // Verify directory count is correct (3 entries, not 4).
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    const dir_count = readDirCount(data);
    try testing.expectEqual(@as(u16, 3), dir_count);
    env.pool().unpin(frame_idx, false);
}

test "PERF-0023: directory rebuilt after removeProperty" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "a", .{ .int = 1 });
    head = try store.putProperty(head, "b", .{ .int = 2 });
    head = try store.putProperty(head, "c", .{ .int = 3 });

    try store.removeProperty(head, "b");

    // a and c should still be found via directory.
    const va = try store.getProperty(head, "a", testing.allocator);
    try testing.expectEqual(@as(i64, 1), va.?.int);

    const vc = try store.getProperty(head, "c", testing.allocator);
    try testing.expectEqual(@as(i64, 3), vc.?.int);

    // b should not be found.
    const vb = try store.getProperty(head, "b", testing.allocator);
    try testing.expect(vb == null);

    // Directory should have 2 entries.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    try testing.expectEqual(@as(u16, 2), readDirCount(data));
    env.pool().unpin(frame_idx, false);
}

test "PERF-0023: keyHash helper produces consistent u16 values" {
    // Verify deterministic hashing.
    const h1 = keyHash("hello");
    const h2 = keyHash("hello");
    try testing.expectEqual(h1, h2);

    // Different keys should (very likely) produce different hashes.
    const h3 = keyHash("world");
    try testing.expect(h1 != h3);
}

test "PERF-0023: directory helpers read/write round-trip" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);

    writeDirCount(&buf, 3);
    try testing.expectEqual(@as(u16, 3), readDirCount(&buf));

    writeDirEntry(&buf, 0, 0xABCD, 44);
    const e0 = readDirEntry(&buf, 0);
    try testing.expectEqual(@as(u16, 0xABCD), e0.hash);
    try testing.expectEqual(@as(u16, 44), e0.offset);

    writeDirEntry(&buf, 1, 0x1234, 100);
    const e1 = readDirEntry(&buf, 1);
    try testing.expectEqual(@as(u16, 0x1234), e1.hash);
    try testing.expectEqual(@as(u16, 100), e1.offset);
}

// ============================================================================
// SEC-0039: dir_count bounds-validation regression tests
// ============================================================================

test "SEC-0039: getProperty returns DataCorruption when dir_count is 0xFFFF" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Create a real property page.
    const head = try store.putProperty(0, "k", .{ .int = 1 });

    // Corrupt the dir_count field to the maximum possible u16 value.
    // This makes dirOverhead(0xFFFF) = 2 + 65535*4 = 262142 bytes, which
    // far exceeds the 4096-byte page; readDirEntry would underflow the base
    // index in ReleaseFast or panic in ReleaseSafe.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeDirCount(frame.dataSlice(), 0xFFFF);
    env.pool().unpin(frame_idx, true);

    // getProperty must return DataCorruption rather than panicking or
    // producing an out-of-bounds read.
    try testing.expectError(error.DataCorruption, store.getProperty(head, "k", testing.allocator));
}

test "SEC-0039: getProperty returns DataCorruption when dir_count just exceeds capacity" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "k", .{ .int = 1 });

    // Compute the maximum valid dir_count for a 4096-byte page.
    // capacity = 4096 - PROP_DATA_OFFSET - DIR_COUNT_SIZE
    // PROP_DATA_OFFSET = PAGE_HEADER_SIZE(32) + PROP_META_SIZE(12) = 44
    // capacity = 4096 - 44 - 2 = 4050
    // max_valid = capacity / DIR_ENTRY_SIZE(4) = 1012
    // One past capacity: 1013
    const one_past_capacity: u16 = 1013;

    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeDirCount(frame.dataSlice(), one_past_capacity);
    env.pool().unpin(frame_idx, true);

    try testing.expectError(error.DataCorruption, store.getProperty(head, "k", testing.allocator));
}

// ============================================================================
// QUAL-0044: Overflow-page-chain behavior-preservation tests
//
// All other prop_store tests use single pages where next_page is always 0.
// These tests force a multi-page property chain (next_page != 0) and exercise
// the full inter-page walk across getProperty, findAndRemoveKey/insertEntry
// (via putProperty), and removeProperty, asserting correctness and the absence
// of pinned-frame leaks (enforced by std.testing.allocator on env.deinit()).
// ============================================================================

/// Walk a property page chain and count how many physical pages it spans.
fn chainPageCount(env: *PropTestEnv, head: u64) !u32 {
    var current: u64 = head;
    var count: u32 = 0;
    while (current != 0) : (count += 1) {
        const frame = try env.pool().pin(.props, current);
        const frame_idx = env.pool().frameIndex(frame);
        const next = readNextPage(frame.dataSlice());
        env.pool().unpin(frame_idx, false);
        current = next;
    }
    return count;
}

test "QUAL-0044: property overflow chain round-trips across multiple pages" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Insert enough distinct properties to spill the chain onto at least a
    // second page. Each entry is keyN (~6-8 bytes) + a moderately sized string
    // value, so a few dozen entries exceed a single 4096-byte page's capacity.
    const n: usize = 300;
    var key_buf: [32]u8 = undefined;
    var head: u64 = 0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{idx});
        head = try store.putProperty(head, key, .{ .int = @intCast(idx * 7 + 1) });
    }
    try testing.expect(head != 0);

    // Confirm the chain actually spilled onto more than one page; otherwise the
    // test would not exercise the inter-page walk it is meant to protect.
    const pages = try chainPageCount(&env, head);
    try testing.expect(pages >= 2);

    // Read every property back, including ones that must live on non-head pages.
    idx = 0;
    while (idx < n) : (idx += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{idx});
        const val = try store.getProperty(head, key, testing.allocator);
        try testing.expect(val != null);
        try testing.expectEqual(@as(i64, @intCast(idx * 7 + 1)), val.?.int);
    }

    // Read a key that is guaranteed to be on a non-head page (a late index)
    // and one on the head page (an early index) to assert both ends explicitly.
    {
        const late = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{n - 1});
        const v_late = try store.getProperty(head, late, testing.allocator);
        try testing.expect(v_late != null);
        try testing.expectEqual(@as(i64, @intCast((n - 1) * 7 + 1)), v_late.?.int);
    }
    {
        const early = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{0});
        const v_early = try store.getProperty(head, early, testing.allocator);
        try testing.expect(v_early != null);
        try testing.expectEqual(@as(i64, 1), v_early.?.int);
    }

    // getProperty for a key not present anywhere must walk the whole chain and
    // return null.
    const missing = try store.getProperty(head, "no_such_key_at_all", testing.allocator);
    try testing.expect(missing == null);
}

test "QUAL-0044: find+remove and re-insert a key on a non-head page" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const n: usize = 300;
    var key_buf: [32]u8 = undefined;
    var head: u64 = 0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{idx});
        head = try store.putProperty(head, key, .{ .int = @intCast(idx) });
    }
    try testing.expect(try chainPageCount(&env, head) >= 2);

    // Replace a late key (which lives on a non-head page). This goes through
    // findAndRemoveKey on a non-head page; either the in-place fast path or the
    // remove-then-insert path must keep the value correct.
    const target = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{n - 5});
    const target_owned = try testing.allocator.dupe(u8, target);
    defer testing.allocator.free(target_owned);
    head = try store.putProperty(head, target_owned, .{ .int = 123456 });

    const replaced = try store.getProperty(head, target_owned, testing.allocator);
    try testing.expect(replaced != null);
    try testing.expectEqual(@as(i64, 123456), replaced.?.int);

    // All other late keys remain intact.
    const neighbor = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{n - 6});
    const v_neighbor = try store.getProperty(head, neighbor, testing.allocator);
    try testing.expect(v_neighbor != null);
    try testing.expectEqual(@as(i64, @intCast(n - 6)), v_neighbor.?.int);

    // Replacing must not duplicate: exactly n entries remain across the chain.
    var iter = store.getAllProperties(head);
    defer iter.deinit();
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    try testing.expectEqual(n, count);
}

test "QUAL-0044: insert allocates a fresh overflow page when chain is full" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const n: usize = 300;
    var key_buf: [32]u8 = undefined;
    var head: u64 = 0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{idx});
        head = try store.putProperty(head, key, .{ .int = @intCast(idx) });
    }
    const pages_before = try chainPageCount(&env, head);
    try testing.expect(pages_before >= 2);

    // Insert a large value that cannot fit into remaining slack on any existing
    // page, forcing insertEntry to allocate a brand-new overflow page at the
    // chain tail.
    const big_value = "x" ** 3000;
    head = try store.putProperty(head, "huge_overflow_key", .{ .string = big_value });

    const pages_after = try chainPageCount(&env, head);
    try testing.expect(pages_after > pages_before);

    const v = try store.getProperty(head, "huge_overflow_key", testing.allocator);
    try testing.expect(v != null);
    defer property_mod.freeDecoded(testing.allocator, v.?);
    try testing.expectEqualStrings(big_value, v.?.string);
}

test "QUAL-0044: removeProperty removes a key on a non-head page" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const n: usize = 300;
    var key_buf: [32]u8 = undefined;
    var head: u64 = 0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{idx});
        head = try store.putProperty(head, key, .{ .int = @intCast(idx) });
    }
    try testing.expect(try chainPageCount(&env, head) >= 2);

    // Remove a late key (on a non-head page) and a head-page key.
    const late = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{n - 3});
    const late_owned = try testing.allocator.dupe(u8, late);
    defer testing.allocator.free(late_owned);
    try store.removeProperty(head, late_owned);

    const gone = try store.getProperty(head, late_owned, testing.allocator);
    try testing.expect(gone == null);

    try store.removeProperty(head, "property_key_0000");
    const gone_head = try store.getProperty(head, "property_key_0000", testing.allocator);
    try testing.expect(gone_head == null);

    // Surviving keys are still retrievable with correct values.
    const survivor = try std.fmt.bufPrint(&key_buf, "property_key_{d:0>4}", .{n - 4});
    const v_survivor = try store.getProperty(head, survivor, testing.allocator);
    try testing.expect(v_survivor != null);
    try testing.expectEqual(@as(i64, @intCast(n - 4)), v_survivor.?.int);

    // Exactly two entries were removed.
    var iter = store.getAllProperties(head);
    defer iter.deinit();
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    try testing.expectEqual(n - 2, count);
}

test "QUAL-0040: PageChainCursor detects circular chain in getProperty" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "key", .{ .int = 42 });

    // Corrupt next_page into a self-loop so the inter-page walk never terminates
    // naturally; the cursor's MAX_CHAIN_HOPS guard must fire.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeNextPage(frame.dataSlice(), head);
    env.pool().unpin(frame_idx, true);

    // A search for a missing key keeps advancing through the self-loop until the
    // guard fires (the present key short-circuits, so use a missing key).
    try testing.expectError(
        error.CircularChainDetected,
        store.getProperty(head, "missing", testing.allocator),
    );
}

test "QUAL-0040: PageChainCursor detects circular chain in removeProperty" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "key", .{ .int = 42 });

    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeNextPage(frame.dataSlice(), head);
    env.pool().unpin(frame_idx, true);

    // Removing a missing key forces the walk to traverse the whole (looping)
    // chain, so the guard must trip rather than spinning forever.
    try testing.expectError(
        error.CircularChainDetected,
        store.removeProperty(head, "missing"),
    );
}

// ============================================================================
// SEC-0042: PropIterator chain-cycle guard regression test
// ============================================================================

test "SEC-0042: PropIterator.next detects circular page chain" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Create a real property page with one entry.
    const head = try store.putProperty(0, "key", .{ .int = 42 });

    // Corrupt next_page to point back to itself, forming a self-loop.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeNextPage(frame.dataSlice(), head);
    env.pool().unpin(frame_idx, true);

    var iter = store.getAllProperties(head);
    defer iter.deinit();

    // Drain until the hop guard fires; the self-loop causes every page
    // advance to revisit the same page. The guard fires after MAX_CHAIN_HOPS.
    var got_error = false;
    while (true) {
        if (iter.next()) |_| {
            // entry returned; continue draining
        } else |err| {
            try testing.expectEqual(error.CircularChainDetected, err);
            got_error = true;
            break;
        }
    }
    try testing.expect(got_error);
}

// ============================================================================
// QUAL-0044 T2: prop_store edge/boundary cases
// ============================================================================

test "QUAL-0044 T2: putProperty returns PropertyKeyTooLong for key exceeding u16 max" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // key.len = maxInt(u16) + 1 = 65536 must fire the u16-range guard.
    const over_limit = try testing.allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer testing.allocator.free(over_limit);
    @memset(over_limit, 'x');
    try testing.expectError(error.PropertyKeyTooLong, store.putProperty(0, over_limit, .{ .int = 1 }));
}

test "QUAL-0044 T2: putProperty returns PropertyKeyTooLong for key at u16 max on 4096-byte page" {
    // key.len == maxInt(u16) == 65535 passes the u16-range guard but cannot
    // fit on a 4096-byte page. The page-capacity guard must prevent an
    // out-of-bounds write and return a clean error instead of panicking.
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const at_limit = try testing.allocator.alloc(u8, std.math.maxInt(u16));
    defer testing.allocator.free(at_limit);
    @memset(at_limit, 'k');
    try testing.expectError(error.PropertyKeyTooLong, store.putProperty(0, at_limit, .{ .int = 1 }));
}

test "QUAL-0044 T2: page-boundary entry lands exactly at usable-capacity limit" {
    // Compute the maximum entry size that still fits with one directory slot:
    //   dataCapacity = 4096 - PROP_DATA_OFFSET - DIR_COUNT_SIZE = 4050
    //   available for one entry = dataCapacity - DIR_ENTRY_SIZE = 4046
    //   entry layout: 2 (key_len field) + key_len + encoded_null (1)
    //   → max key_len = 4046 - 2 - 1 = 4043
    // Inserting a key of exactly 4043 bytes with a null value must succeed
    // and be retrievable.
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const boundary_key_len: usize = 4043;
    const key = try testing.allocator.alloc(u8, boundary_key_len);
    defer testing.allocator.free(key);
    @memset(key, 'B');

    const head = try store.putProperty(0, key, PropertyValue.null);
    try testing.expect(head != 0);

    const val = try store.getProperty(head, key, testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(PropertyValue.null, val.?);
}

test "QUAL-0044 T2: rebuildDirectory disables directory when data region overlaps directory space" {
    // The rebuildDirectory path that sets dir_count=0 (linear-scan fallback)
    // fires when the total entry data pushes the scan pointer past max_dir_end.
    // This cannot be reached via the normal insert API (which accounts for
    // directory overhead), but can occur for pages that were written in legacy
    // format (dir_count=0) with entries packed tightly.
    //
    // Strategy:
    //   1. Insert one real sentinel entry via putProperty.
    //   2. Pin the page and manually append N entries (key_len=2, 2-byte key,
    //      null value = 5 bytes each) directly into the data region, update
    //      entry_count, and clear dir_count to 0 (legacy mode).
    //   3. Unpin (dirty).
    //   4. Call removeProperty on the real sentinel key — this uses linear scan
    //      (dir_count == 0) to find-and-remove the entry, then calls
    //      rebuildDirectory for the N remaining entries. With N=500 and entry_size
    //      5 bytes, the scan pointer after all N entries exceeds max_dir_end and
    //      the directory is disabled (dir_count stays 0).
    //   5. Assert dir_count == 0.
    //   6. Assert that the remaining 2-byte-key entries are still accessible via
    //      getProperty (linear scan fallback).
    //
    // readEntryCountChecked bound: max_entries = (4096 - 44 - 2) / (3 + 4) = 578.
    // Total entry_count in buffer = 501 (1 sentinel + 500 extra) ≤ 578. OK.
    // After removal: 500 entries × 5 bytes = 2500 bytes of data.
    //   data_end = 44 + 2500 = 2544
    //   max_dir_end = 4094 - 500×4 = 4094 - 2000 = 2094
    //   2544 > 2094 → rebuildDirectory sets dir_count = 0.
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Insert the sentinel entry that will be removed later.
    const sentinel_key = "sentinel";
    const head = try store.putProperty(0, sentinel_key, .{ .int = 99 });

    // n_extra must satisfy:
    //   (1) 1 + n_extra <= max_entries (578) so readEntryCountChecked accepts it.
    //   (2) After removal: n_extra entries of entry_size bytes trigger directory
    //       disable in rebuildDirectory.
    const n_extra: u32 = 500;
    const extra_key_len: u16 = 2;
    const extra_entry_size: u32 = 2 + extra_key_len + 1; // key_len_field + key + null tag

    {
        const frame = try env.pool().pin(.props, head);
        const frame_idx = env.pool().frameIndex(frame);
        const data = frame.dataSlice();

        // Sentinel: key_len(2) + "sentinel"(8) + int_tag(1) + i64(8) = 19 bytes.
        const sentinel_entry_size: u32 = 2 + sentinel_key.len + 9;
        var off: u32 = PROP_DATA_OFFSET + sentinel_entry_size;

        // Write n_extra entries: each is key_len=2, key="\xAB\xCD", null value.
        var i: u32 = 0;
        while (i < n_extra) : (i += 1) {
            std.mem.writeInt(u16, data[off..][0..2], extra_key_len, .little);
            off += 2;
            data[off] = 0xAB;
            off += 1;
            data[off] = 0xCD;
            off += 1;
            data[off] = @intFromEnum(property_mod.Tag.null);
            off += 1;
        }

        // Update entry_count and switch to legacy mode (dir_count = 0).
        writeEntryCount(data, 1 + n_extra);
        writeDirCount(data, 0);

        env.pool().unpin(frame_idx, true);
    }

    // Remove the sentinel. findEntrySpan uses linear scan (dir_count == 0),
    // finds "sentinel", removes it (shifting n_extra entries to front), then
    // calls rebuildDirectory(data, n_extra, 4096). With n_extra=500 and
    // entry_size=5, the data scan pointer exceeds max_dir_end → dir_count = 0.
    try store.removeProperty(head, sentinel_key);

    // Verify dir_count == 0 (directory disabled by rebuildDirectory).
    {
        const frame = try env.pool().pin(.props, head);
        const frame_idx = env.pool().frameIndex(frame);
        const data = frame.dataSlice();
        const dir_count = readDirCount(data);
        env.pool().unpin(frame_idx, false);
        try testing.expectEqual(@as(u16, 0), dir_count);
    }

    // Verify that the extra entries are still readable via linear scan.
    // getProperty with key="\xAB\xCD" must find the first matching entry.
    const lookup_key = "\xAB\xCD";
    const val = try store.getProperty(head, lookup_key, testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(PropertyValue.null, val.?);

    // The sentinel must no longer be visible.
    const gone = try store.getProperty(head, sentinel_key, testing.allocator);
    try testing.expect(gone == null);

    _ = extra_entry_size;
}

test {
    std.testing.refAllDecls(@This());
}
