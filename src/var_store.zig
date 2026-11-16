// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const FillHook = buffer_pool_mod.FillHook;
const FileId = @import("types.zig").FileId;
const free_space_mod = @import("free_space.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const PageId = types.PageId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Variable-length data overflow store.
/// Stores large values that don't fit inline in property pages.
///
/// Each write returns a reference: (page_id << 16 | offset).
/// For v1, each write allocates a new page (or chain of pages for large data).
///
/// Page layout:
/// - [0..PAGE_HEADER_SIZE): PageHeader
/// - [PAGE_HEADER_SIZE..PAGE_HEADER_SIZE+8): next_page pointer (u64, 0 = none)
/// - [PAGE_HEADER_SIZE+8..PAGE_HEADER_SIZE+12): data_len (u32, bytes used on this page)
/// - [PAGE_HEADER_SIZE+12..): data bytes
const VAR_META_SIZE: u32 = 12; // next_page(8) + data_len(4)

// ============================================================================
// GAP var-store slab packing — tagged slab head refs + slab block layout
// (READ path since P1; the P2 writer packs NEW small chains + graduates).
//
// LAYOUT DISCRIMINATION mirrors the adjacency slab (adj_store.zig) and the
// prop-store slab verbatim: a TAG BIT in the var head ref itself.
//   * Legacy var-chain head: `first_page << 16` (a var REF, NOT a raw page id —
//     the low 16 bits are the historical offset field, always 0). Bit 63 is
//     CLEAR (page ids are allocated sequentially and never approach 2^47, so
//     `first_page << 16` never sets bit 63). Reads via the existing page-chain
//     walk, unchanged, forever.
//   * Slab head: bit 63 is SET. The remaining bits pack (block, slot):
//     bits [24..63) = slab block page id (39 bits), bits [0..24) = slot index
//     (24 bits) — the SAME packing as adj_store's encodeSlabHead. Many small
//     var-chains share one slab block; the slot directory maps each slot to a
//     contiguous BYTE run.
//
// WHY the tag lives in the head ref and not only the block header: to read a
// block you must first know its page id, but a legacy head packs
// `first_page << 16` while a slab head packs (page, slot) into the same u64 —
// so the discriminator must be in the head. Defense-in-depth: a slab block's
// header stamps VAR_SLAB_MARKER in the exact u32 slot the LEGACY reader parses
// as `data_len`, and the marker is > any page's dataCapacity — so a legacy
// chain walk that lands on a slab block trips the existing `data_len >
// dataCapacity` DataCorruption guard, and a slab read that lands on a legacy
// page finds marker != VAR_SLAB_MARKER. A slab block is NEVER chained.
//
// The stored var_head u64 (NodeRec.label_head, prop string refs) is unchanged
// in width and opaque to every layer above VarStore.
// ============================================================================

/// Tag bit marking a slab-packed var head (vs a legacy `first_page << 16` ref).
pub const SLAB_HEAD_TAG_BIT: u64 = @as(u64, 1) << 63;
/// Number of low bits of a slab head used for the slot index (mirrors adj).
const SLAB_HEAD_SLOT_BITS: u6 = 24;
const SLAB_HEAD_SLOT_MASK: u64 = (@as(u64, 1) << SLAB_HEAD_SLOT_BITS) - 1;
/// Maximum page id encodable in a slab head (64 - 1 tag - 24 slot = 39 bits).
const SLAB_HEAD_MAX_PAGE_ID: u64 = @as(u64, 1) << (64 - 1 - SLAB_HEAD_SLOT_BITS);

/// Slab block layout (page-relative), mirroring edge.zig's SLAB geometry:
///   [page header 32 B][VarSlab header 16 B][byte runs → ...gap... ← slot dir][tail_reserve]
/// The VarSlab header is 16 B so runs begin at the same offset (48) as the
/// adjacency slab, and the slot directory grows BACKWARD from
/// `page end - tail_reserve` exactly as edge.zig does.
///
/// VarSlab header:
///   [0..8)   next_page (u64) = 0 — slab blocks are never chained.
///   [8..12)  marker (u32) = VAR_SLAB_MARKER — aliases the legacy `data_len`
///            field; > any dataCapacity so a legacy misread self-rejects.
///   [12..16) slot_count (u32) — live + tombstoned slots.
const VAR_SLAB_HEADER_SIZE: u32 = 16;
/// Byte offset of the first run byte (after page header + VarSlab header).
const VAR_SLAB_RUNS_OFFSET: u32 = PAGE_HEADER_SIZE + VAR_SLAB_HEADER_SIZE;
/// Slot-directory entry: run byte-offset (u32 LE) + run byte-length (u32 LE).
const VAR_SLAB_DIR_ENTRY_SIZE: u32 = 8;
/// Tombstone marker in a slot's offset field (dead slot: chain graduated to a
/// dedicated page chain, or was removed). A live head never points at one.
const VAR_SLAB_SLOT_TOMBSTONE: u32 = 0xFFFF_FFFF;
/// Marker stamped in the VarSlab header's [8..12) window. Distinct magic that
/// is > any real dataCapacity (page sizes are <= 64 KB), so it can never equal
/// a legacy `data_len` (which is always <= dataCapacity). "VARS" tag.
const VAR_SLAB_MARKER: u32 = 0x5641_5253;
/// Graduation threshold: the largest byte run the slab writer packs into a
/// shared block. Runs above this migrate to a dedicated legacy page-chain, so a
/// shared block always holds MANY small records (packing — not one ~page-sized
/// run that would defeat the whole point). ~1 KB sits at the top of the plan's
/// ~512 B–1 KB band; taxa var strings (scientific_name/authorship ~40–500 B)
/// and label blocks (2 + 4·n B) pack comfortably below it. Physically capped by
/// the block's own capacity in `slabMaxRunLen`.
const VAR_SLAB_MAX_RUN: u32 = 1024;

/// True when a var head ref is a slab-packed (block, slot) pointer (bit 63 set)
/// rather than a legacy `first_page << 16` ref. Head 0 (= empty / no chain) is
/// untagged and stays the universal "no chain" sentinel.
pub fn isSlabHead(head: u64) bool {
    return (head & SLAB_HEAD_TAG_BIT) != 0;
}

/// Encode a slab var head from (slab block page id, slot index).
pub fn encodeSlabHead(page_id: PageId, slot: u32) u64 {
    std.debug.assert(page_id < SLAB_HEAD_MAX_PAGE_ID);
    std.debug.assert(@as(u64, slot) <= SLAB_HEAD_SLOT_MASK);
    return SLAB_HEAD_TAG_BIT | (page_id << SLAB_HEAD_SLOT_BITS) | (@as(u64, slot) & SLAB_HEAD_SLOT_MASK);
}

/// Decode the slab block page id from a slab var head.
pub fn slabHeadPageId(head: u64) PageId {
    return (head & ~SLAB_HEAD_TAG_BIT) >> SLAB_HEAD_SLOT_BITS;
}

/// Decode the slot index from a slab var head.
pub fn slabHeadSlot(head: u64) u32 {
    return @intCast(head & SLAB_HEAD_SLOT_MASK);
}

/// One slab slot: byte offset of the run in the page, and the run's byte length.
const VarSlabSlot = struct { offset: u32, byte_len: u32 };

/// First byte of the slot directory (== one-past-the-end of usable run space).
fn varSlabDirStart(data_len: usize, tail_reserve: u32, slot_count: u32) usize {
    return data_len - tail_reserve - @as(usize, slot_count) * VAR_SLAB_DIR_ENTRY_SIZE;
}

fn varSlabSlotBase(data_len: usize, tail_reserve: u32, idx: u32) usize {
    return data_len - tail_reserve - (@as(usize, idx) + 1) * VAR_SLAB_DIR_ENTRY_SIZE;
}

/// Read slot `idx`'s (offset, byte_len) from the slot directory. Caller must
/// have validated `idx` against the block header's slot_count.
fn readVarSlabSlot(data: []const u8, tail_reserve: u32, idx: u32) VarSlabSlot {
    const base = varSlabSlotBase(data.len, tail_reserve, idx);
    return .{
        .offset = std.mem.readInt(u32, data[base..][0..4], .little),
        .byte_len = std.mem.readInt(u32, data[base + 4 ..][0..4], .little),
    };
}

/// Write slot `idx`'s directory entry (tests / the future P2 writer).
fn writeVarSlabSlot(data: []u8, tail_reserve: u32, idx: u32, slot: VarSlabSlot) void {
    const base = varSlabSlotBase(data.len, tail_reserve, idx);
    std.mem.writeInt(u32, data[base..][0..4], slot.offset, .little);
    std.mem.writeInt(u32, data[base + 4 ..][0..4], slot.byte_len, .little);
}

/// Stamp a fresh VarSlab block header (P2 writer): next_page = 0 (never
/// chained), marker = VAR_SLAB_MARKER (aliases the legacy `data_len` window so
/// a mis-typed read self-rejects), slot_count.
fn writeVarSlabHeader(data: []u8, slot_count: u32) void {
    const off = PAGE_HEADER_SIZE;
    std.mem.writeInt(u64, data[off..][0..8], 0, .little);
    std.mem.writeInt(u32, data[off + 8 ..][0..4], VAR_SLAB_MARKER, .little);
    std.mem.writeInt(u32, data[off + 12 ..][0..4], slot_count, .little);
}

/// Overwrite just the slot_count field of an existing VarSlab header (P2
/// writer appends: a new slot becomes visible only via this bump AFTER its run
/// bytes + directory entry are written).
fn writeVarSlabSlotCount(data: []u8, slot_count: u32) void {
    std.mem.writeInt(u32, data[PAGE_HEADER_SIZE + 12 ..][0..4], slot_count, .little);
}

pub const VarStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    page_size: u32,
    /// Bytes reserved at the tail of every page for the page-level AES-GCM
    /// authentication tag when at-rest encryption is enabled. The slab slot
    /// directory grows backward from `page_size - tail_reserve`, so it never
    /// collides with the tag — the same reservation the adjacency and prop
    /// slabs make. Legacy var-chain pages grow forward only and are
    /// unaffected. Set by the engine to the tag size when a key is configured
    /// (the P2 writer path); 0 otherwise, including all P1 read-both fixtures.
    tail_reserve: u32 = 0,

    /// GAP var-store slab packing (P2): when true, `write` packs a NEW small
    /// var-chain (a whole byte run) as a SLOT in the shared `current_fill_page`
    /// instead of allocating a whole >=page_size page per record — so many
    /// small strings/label blocks share one page. Runs that exceed the
    /// graduation threshold (or trip the page-id encode limit) fall back to the
    /// legacy one-page-per-chain layout. Default ON since P7 (mirroring
    /// prop_store): freshly-created stores pack new var-chains; existing legacy
    /// chains keep reading via the read-both path (no migration). Tests that
    /// exercise the legacy one-page-per-chain writer opt out with
    /// `slab_packing = false`.
    slab_packing: bool = true,

    /// The shared "current fill page" NEW slab runs append to. In-memory only:
    /// after a reopen the first slab write simply starts a fresh fill page
    /// (mirrors prop_store.current_fill_page — a copied/stale VarStore value
    /// can never corrupt a page because append state is re-derived from the
    /// page itself, never cached).
    current_fill_page: ?PageId = null,
    /// SONNY-6659: set by the engine; see `buffer_pool.FillHook`.
    fill_hook: ?FillHook = null,

    /// GAP-ENT-0022(b): undo record for the slab-slot tombstone written by the
    /// CURRENT top-level op (at most one — a var-chain free tombstones exactly
    /// one slot). Lets the ENGINE roll the tombstone back
    /// (`undoLastSlabTombstone`) when it fails AFTER `free` returned but before
    /// the node record durably points at the NEW head — otherwise the stored
    /// (old) head would reference a dead slot forever. Reset by the engine
    /// (`resetSlabUndo`) at the top of each label op.
    last_slab_tombstone: ?SlabTombstoneUndo = null,

    const SlabTombstoneUndo = struct { page_id: PageId, slot: u32, offset: u32, byte_len: u32 };

    const FILL_FILE: FileId = .var_store;

    /// SONNY-6659: the fill page to append to (see `buffer_pool.FillHook`).
    fn fillPage(self: *const @This()) ?PageId {
        if (self.fill_hook) |h| return h.get(h.ctx, FILL_FILE);
        return self.current_fill_page;
    }

    fn setFillPage(self: *@This(), page: ?PageId) void {
        if (self.fill_hook) |h| return h.set(h.ctx, FILL_FILE, page);
        self.current_fill_page = page;
    }

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, page_size: u32) VarStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .page_size = page_size,
            .tail_reserve = 0,
            .slab_packing = true,
            .current_fill_page = null,
            .last_slab_tombstone = null,
        };
    }

    /// GAP-ENT-0022(b): forget the previous op's slab-slot tombstone. The
    /// engine calls this at the top of each label mutation, before the
    /// label_store call that may tombstone the old slab slot.
    pub fn resetSlabUndo(self: *VarStore) void {
        self.last_slab_tombstone = null;
    }

    /// Usable data bytes per LEGACY chain page.
    ///
    /// SEC: the reserved tail must be excluded. When at-rest encryption is on,
    /// the pager writes the per-page AES-GCM tag into the final `tail_reserve`
    /// bytes on flush; a chunk that ran into that region round-tripped fine
    /// within a session (reads hit the decrypted frame) but came back as tag
    /// bytes after a restart — silent corruption of the chunk's tail. The slab
    /// layout has always reserved the tail (`slabCapacity`); legacy chains now
    /// do too. `tail_reserve` is 0 in plaintext mode, so the plaintext layout
    /// is byte-for-byte unchanged.
    fn dataCapacity(self: *const VarStore) u32 {
        return self.page_size - PAGE_HEADER_SIZE - VAR_META_SIZE - self.tail_reserve;
    }

    /// Bytes on a slab block available for byte runs + slot-directory entries
    /// (page minus header/VarSlab-header and the AES-GCM tail reservation).
    fn slabCapacity(self: *const VarStore) u32 {
        return self.page_size - self.tail_reserve - VAR_SLAB_RUNS_OFFSET;
    }

    /// Largest single run the writer packs into a slab block: the graduation
    /// threshold, physically capped so even a fresh block (one dir entry) holds
    /// it. Runs above this graduate to a legacy chain.
    fn slabMaxRunLen(self: *const VarStore) u32 {
        const physical = self.slabCapacity() - VAR_SLAB_DIR_ENTRY_SIZE;
        return @min(VAR_SLAB_MAX_RUN, physical);
    }

    const VarSlabState = struct { slot_count: u32, next_off: u32 };

    /// Re-derive a slab block's append state from the page itself (never cached
    /// — a stale VarStore value can't corrupt a page): the slot count (from the
    /// validated header) and the first free run byte (max over LIVE slots of
    /// offset+byte_len; tombstoned slots keep their dir entry but free no run
    /// space until compaction). O(slot_count), bounded by page_size.
    fn slabBlockState(self: *const VarStore, data: []const u8) error{DataCorruption}!VarSlabState {
        const slot_count = try self.readSlabBlockHeader(data);
        const dir_start = varSlabDirStart(data.len, self.tail_reserve, slot_count);
        var next_off: u32 = VAR_SLAB_RUNS_OFFSET;
        var i: u32 = 0;
        while (i < slot_count) : (i += 1) {
            const s = readVarSlabSlot(data, self.tail_reserve, i);
            if (s.offset == VAR_SLAB_SLOT_TOMBSTONE) continue;
            if (s.offset < VAR_SLAB_RUNS_OFFSET) return error.DataCorruption;
            const end = @as(u64, s.offset) + @as(u64, s.byte_len);
            if (end > dir_start) return error.DataCorruption;
            if (end > next_off) next_off = @intCast(end);
        }
        return .{ .slot_count = slot_count, .next_off = next_off };
    }

    /// Pack `data` as a NEW slot on the current fill block, or on a fresh slab
    /// block when there is no fill block / it is full. Returns the bit-63 tagged
    /// (block, slot) head, or null when the run can never fit a slab block
    /// (> graduation threshold) or the page-id encode guard trips — the caller
    /// then uses the legacy layout. Never partially writes: the slot becomes
    /// visible only via the slot_count bump AFTER the run bytes + directory
    /// entry are written.
    fn appendSlabRun(self: *VarStore, data: []const u8) !?u64 {
        if (data.len > self.slabMaxRunLen()) return null; // graduate to legacy
        const run_len: u32 = @intCast(data.len);

        // Try the current fill block first.
        if (self.fillPage()) |fill_page| {
            const frame = try self.buffer_pool.pin(.var_store, fill_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();
            const state = self.slabBlockState(page_data) catch |err| {
                self.buffer_pool.unpin(frame_idx, false);
                return err;
            };
            if (@as(u64, state.slot_count) <= SLAB_HEAD_SLOT_MASK) {
                const slot: u32 = state.slot_count;
                // Space for the run AND one more directory entry (the new slot).
                const dir_end = varSlabDirStart(page_data.len, self.tail_reserve, slot + 1);
                if (@as(u64, state.next_off) + run_len <= dir_end) {
                    if (run_len > 0) @memcpy(page_data[state.next_off..][0..run_len], data);
                    writeVarSlabSlot(page_data, self.tail_reserve, slot, .{ .offset = state.next_off, .byte_len = run_len });
                    writeVarSlabSlotCount(page_data, slot + 1);
                    self.buffer_pool.unpin(frame_idx, true);
                    return encodeSlabHead(fill_page, slot);
                }
            }
            // Full (or slot indices exhausted): retire it — no mutation.
            self.buffer_pool.unpin(frame_idx, false);
            self.setFillPage(null);
        }

        // Start a fresh slab fill block.
        const new_page = try self.free_space.allocPage();
        // The page id must fit the 39-bit slab-head field with the tag clear;
        // never encode an out-of-range id (that would corrupt the head) —
        // release the page and use the legacy layout.
        if (new_page >= SLAB_HEAD_MAX_PAGE_ID) {
            self.free_space.freePage(new_page) catch {};
            return null;
        }
        const frame = self.buffer_pool.pinNew(.var_store, new_page) catch |err| { // zeroed
            self.free_space.freePage(new_page) catch {};
            return err;
        };
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const page_data = frame.dataSlice();
        writeVarSlabHeader(page_data, 1);
        if (run_len > 0) @memcpy(page_data[VAR_SLAB_RUNS_OFFSET..][0..run_len], data);
        writeVarSlabSlot(page_data, self.tail_reserve, 0, .{ .offset = VAR_SLAB_RUNS_OFFSET, .byte_len = run_len });
        self.buffer_pool.unpin(frame_idx, true);
        self.setFillPage(new_page);
        return encodeSlabHead(new_page, 0);
    }

    /// Write variable-length data. Returns a var head: a bit-63 tagged slab
    /// (block, slot) ref when slab packing is on and the run fits the
    /// graduation threshold, else a legacy `page_id << 16` page-chain ref.
    /// For multi-page (legacy) data, pages are chained via next_page pointers.
    pub fn write(self: *VarStore, data: []const u8) !u64 {
        // GAP var-store slab packing (P2): pack a NEW small run into the shared
        // fill block. A null result means "graduate to legacy" (run over the
        // threshold, or the page-id encode limit tripped) — fall through.
        if (self.slab_packing) {
            if (try self.appendSlabRun(data)) |head| return head;
        }

        return self.writeLegacyChain(data);
    }

    /// Write variable-length data as a LEGACY `first_page << 16` page chain,
    /// bypassing slab packing entirely. Returns the chain ref.
    ///
    /// Callers that must be able to `free` the result WITHOUT disturbing the
    /// store's shared `last_slab_tombstone` undo slot use this entry point
    /// instead of `write`: `free` on a slab head tombstones a slot and ARMS
    /// that single per-store undo record, and PropStore shares one VarStore
    /// with LabelStore (see engine_persist.zig) — a prop-store free could
    /// otherwise overwrite / consume a label op's pending undo. A legacy chain
    /// frees by releasing its own pages and never touches the undo slot.
    pub fn writeLegacyChain(self: *VarStore, data: []const u8) !u64 {
        const cap = self.dataCapacity();
        var remaining = data;
        var first_page: PageId = 0;
        var prev_page: PageId = 0;
        var prev_frame_idx: ?u32 = null;

        while (remaining.len > 0 or first_page == 0) {
            const page_id = try self.free_space.allocPage();
            if (first_page == 0) first_page = page_id;

            const frame = try self.buffer_pool.pinNew(.var_store, page_id);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const chunk_len: u32 = @intCast(@min(remaining.len, cap));

            // Write metadata: next_page = 0 (will be updated if more pages follow)
            const meta_off = PAGE_HEADER_SIZE;
            @memcpy(page_data[meta_off..][0..8], &std.mem.toBytes(@as(u64, 0)));
            @memcpy(page_data[meta_off + 8 ..][0..4], &std.mem.toBytes(chunk_len));

            // Write data
            if (chunk_len > 0) {
                @memcpy(page_data[meta_off + VAR_META_SIZE ..][0..chunk_len], remaining[0..chunk_len]);
            }

            // Link previous page to this one
            if (prev_frame_idx) |pfi| {
                // Re-pin previous page to update its next_page pointer
                const pframe = try self.buffer_pool.pin(.var_store, prev_page);
                const pfi2 = self.buffer_pool.frameIndex(pframe);
                const pdata = pframe.dataSlice();
                @memcpy(pdata[PAGE_HEADER_SIZE..][0..8], &std.mem.toBytes(page_id));
                self.buffer_pool.unpin(pfi2, true);
                _ = pfi; // prev_frame_idx was already unpinned
            }

            self.buffer_pool.unpin(frame_idx, true);
            prev_page = page_id;
            prev_frame_idx = frame_idx;

            if (chunk_len >= remaining.len) break;
            remaining = remaining[chunk_len..];
        }

        return first_page << 16;
    }

    /// Decode the FIRST PAGE ID of the chain a var-store reference points at.
    /// A ref is `first_page << 16`, NOT a page id — callers that need the
    /// on-disk page (e.g. to WAL-image the chain) must decode it here instead
    /// of passing the raw ref around as if it were a page id.
    pub fn refFirstPage(ref: u64) PageId {
        return ref >> 16;
    }

    /// Read the next-page link of a chain page (0 = end of chain). Used by
    /// the engine to WAL-image every page of a freshly written chain.
    pub fn nextChainPage(self: *VarStore, page_id: PageId) !PageId {
        const frame = try self.buffer_pool.pin(.var_store, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const page_data = frame.dataSlice();
        const next = std.mem.bytesToValue(u64, page_data[PAGE_HEADER_SIZE..][0..8]);
        self.buffer_pool.unpin(frame_idx, false);
        return next;
    }

    /// Read variable-length data by reference (read-both, permanent).
    /// `ref` is a var head: a legacy `first_page << 16` page-chain ref (the
    /// walk below, unchanged) or a bit-63-tagged slab (block, slot) ref (single
    /// contiguous byte run). Caller owns the returned slice and must free it.
    pub fn read(self: *VarStore, ref: u64, allocator: Allocator) ![]u8 {
        if (isSlabHead(ref)) return self.readSlab(ref, allocator);

        const start_page: PageId = ref >> 16;
        if (start_page == 0) return error.InvalidPageId;

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var current_page = start_page;
        var hops: u32 = 0;
        const max_hops: u32 = 100_000;
        while (current_page != 0) : (hops += 1) {
            if (hops >= max_hops) return error.CircularChainDetected;

            const frame = try self.buffer_pool.pin(.var_store, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const meta_off = PAGE_HEADER_SIZE;
            const next_page = std.mem.bytesToValue(u64, page_data[meta_off..][0..8]);
            const data_len = std.mem.bytesToValue(u32, page_data[meta_off + 8 ..][0..4]);

            if (data_len > self.dataCapacity()) {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            }

            if (data_len > 0) {
                const chunk = page_data[meta_off + VAR_META_SIZE ..][0..data_len];
                try result.appendSlice(allocator, chunk);
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }

        return result.toOwnedSlice(allocator);
    }

    /// Read a slab-packed var head: resolve the (block, slot) to its single
    /// contiguous byte run and return a copy. F1-style guard: a slab-tagged
    /// head whose page bits decode to 0 (page 0 is reserved) is corruption,
    /// never silently-empty. Caller owns the returned slice.
    fn readSlab(self: *VarStore, ref: u64, allocator: Allocator) ![]u8 {
        const page_id = slabHeadPageId(ref);
        if (page_id == 0) return error.DataCorruption; // page 0 reserved (F1)
        const slot = slabHeadSlot(ref);

        const frame = try self.buffer_pool.pin(.var_store, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        defer self.buffer_pool.unpin(frame_idx, false);
        const page_data = frame.dataSlice();

        const run = try self.resolveSlabRun(page_data, slot);
        const out = try allocator.alloc(u8, run.byte_len);
        errdefer allocator.free(out);
        if (run.byte_len > 0) {
            @memcpy(out, page_data[run.offset..][0..run.byte_len]);
        }
        return out;
    }

    /// Parse + validate the header of a SLAB block reached via a tagged head.
    /// Rejects loudly (mirrors adj_store.readSlabBlockHeader): wrong marker (a
    /// tagged head must land on a slab block, and a legacy chain walk that
    /// lands here already self-rejects via the `data_len > dataCapacity`
    /// guard), a chained slab block (slab blocks are never linked), or a slot
    /// directory that cannot fit the page.
    fn readSlabBlockHeader(self: *const VarStore, data: []const u8) error{DataCorruption}!u32 {
        const off = PAGE_HEADER_SIZE;
        const next_page = std.mem.readInt(u64, data[off..][0..8], .little);
        const marker = std.mem.readInt(u32, data[off + 8 ..][0..4], .little);
        const slot_count = std.mem.readInt(u32, data[off + 12 ..][0..4], .little);
        if (marker != VAR_SLAB_MARKER) return error.DataCorruption;
        if (next_page != 0) return error.DataCorruption;
        const dir_bytes = @as(u64, slot_count) * VAR_SLAB_DIR_ENTRY_SIZE;
        if (VAR_SLAB_RUNS_OFFSET + dir_bytes + self.tail_reserve > data.len) return error.DataCorruption;
        return slot_count;
    }

    /// Resolve a slab (block, slot) to its validated byte run. The live-head
    /// invariant makes a tombstoned or out-of-range slot reached via a stored
    /// head ref corruption — never silently empty (mirrors adj_store).
    fn resolveSlabRun(self: *const VarStore, data: []const u8, slot: u32) error{DataCorruption}!VarSlabSlot {
        const slot_count = try self.readSlabBlockHeader(data);
        if (slot >= slot_count) return error.DataCorruption;
        const run = readVarSlabSlot(data, self.tail_reserve, slot);
        if (run.offset == VAR_SLAB_SLOT_TOMBSTONE) return error.DataCorruption;
        if (run.offset < VAR_SLAB_RUNS_OFFSET) return error.DataCorruption;
        const run_end = @as(u64, run.offset) + @as(u64, run.byte_len);
        if (run_end > varSlabDirStart(data.len, self.tail_reserve, slot_count)) return error.DataCorruption;
        return run;
    }

    /// Free variable-length data by reference.
    /// Walks the page chain and frees each page (legacy), or slot-tombstones a
    /// slab-packed run (P2 — a slab head packs (block, slot), NOT a page id, so
    /// a chain-style free would free the SHARED block out from under its other
    /// live slots). The tombstone is the op's LAST mutation and records an undo
    /// so the engine can revive the slot if a later step of the same op fails
    /// (the GAP-ENT-0022(b) live-head invariant).
    pub fn free(self: *VarStore, ref: u64) !void {
        if (isSlabHead(ref)) return self.tombstoneSlabSlot(ref);

        const start_page: PageId = ref >> 16;
        if (start_page == 0) return;

        var current_page = start_page;
        var hops: u32 = 0;
        const max_hops: u32 = 100_000;
        while (current_page != 0) : (hops += 1) {
            if (hops >= max_hops) return error.CircularChainDetected;

            const frame = try self.buffer_pool.pin(.var_store, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const next_page = std.mem.bytesToValue(u64, page_data[PAGE_HEADER_SIZE..][0..8]);

            self.buffer_pool.unpin(frame_idx, false);
            try self.free_space.freePage(current_page);

            current_page = next_page;
        }
    }

    /// P2: mark a slab (block, slot) run dead — set its slot-directory offset
    /// to VAR_SLAB_SLOT_TOMBSTONE (distinct from a LIVE empty-string run, whose
    /// offset stays a real byte offset with byte_len == 0). Other slots in the
    /// shared block are untouched. The block itself is NOT reclaimed here
    /// (compaction is a separate pass — mirrors prop_store, which leaves dead
    /// slots until P6): packing, not slot reclamation, delivers the bytes/node
    /// win.
    ///
    /// GAP-ENT-0022(b) ordering: the caller's OLD head keeps pointing at this
    /// slot until the engine durably swings the node record to the NEW head, so
    /// the tombstone must be the op's LAST mutation and it arms an undo record.
    /// The run is validated (loudly) BEFORE the mutation; there is no error exit
    /// after the slot write.
    fn tombstoneSlabSlot(self: *VarStore, ref: u64) !void {
        const page_id = slabHeadPageId(ref);
        if (page_id == 0) return error.DataCorruption; // page 0 reserved (F1)
        const slot = slabHeadSlot(ref);

        const frame = try self.buffer_pool.pin(.var_store, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        // Validate + snapshot the run for the undo record BEFORE mutating: a
        // tombstoned / out-of-range / out-of-bounds slot reached via a stored
        // head is corruption (the live-head invariant), never a silent no-op.
        const run = self.resolveSlabRun(data, slot) catch |err| {
            self.buffer_pool.unpin(frame_idx, false);
            return err;
        };
        writeVarSlabSlot(data, self.tail_reserve, slot, .{ .offset = VAR_SLAB_SLOT_TOMBSTONE, .byte_len = 0 });
        self.buffer_pool.unpin(frame_idx, true);
        // Arm the engine-level rollback (GAP-ENT-0022(b)).
        self.last_slab_tombstone = .{ .page_id = page_id, .slot = slot, .offset = run.offset, .byte_len = run.byte_len };
    }

    /// GAP-ENT-0022(b): best-effort rollback of the slab-slot tombstone written
    /// by the MOST RECENT op on this store. The engine calls this from an
    /// errdefer when a label op fails AFTER `free` tombstoned the old slot but
    /// before the node record durably referenced the new head — without it the
    /// stored (old) head would reference a dead slot: permanent DataCorruption
    /// for that node.
    ///
    /// Effect: restores the old slot's (offset, byte_len). The run bytes are
    /// still intact (a tombstone only rewrites the directory entry; the data
    /// region is never reused within the same op), so the old head reads again.
    /// Allocation-free (resident-page pin + one slot write) so it can succeed
    /// under the very OOM that failed the op. No-op when the current op wrote no
    /// tombstone (first writes, legacy frees, dedup no-ops).
    ///
    /// Crash safety: only invoked on an op whose txn aborts, so none of that
    /// txn's WAL page images replay — recovery reproduces the pre-op pages,
    /// which agree with this in-memory restoration (the restored page is dirty
    /// and flushes with the next checkpoint).
    pub fn undoLastSlabTombstone(self: *VarStore) !void {
        const undo = self.last_slab_tombstone orelse return;
        self.last_slab_tombstone = null;
        const frame = try self.buffer_pool.pin(.var_store, undo.page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        const cur = readVarSlabSlot(data, self.tail_reserve, undo.slot);
        if (cur.offset != VAR_SLAB_SLOT_TOMBSTONE) {
            // Defensive: not the tombstone this op wrote — leave it alone.
            self.buffer_pool.unpin(frame_idx, false);
            return;
        }
        writeVarSlabSlot(data, self.tail_reserve, undo.slot, .{ .offset = undo.offset, .byte_len = undo.byte_len });
        self.buffer_pool.unpin(frame_idx, true);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const testing_support_mod = @import("testing_support.zig");
const SingleStoreEnv = testing_support_mod.SingleStoreEnv;

test "write + read round-trip for small data" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const data = "hello, world!";
    const ref = try store.write(data);
    try testing.expect(ref != 0);

    const result = try store.read(ref, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(data, result);
}

test "write + read for data larger than a page (multi-page)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    // Data capacity per page: 4096 - 32 - 12 = 4052
    // Create data that spans 3 pages
    const size = 4052 * 2 + 100; // ~8200 bytes, needs 3 pages
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const ref = try store.write(data);
    const result = try store.read(ref, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(data.len, result.len);
    try testing.expectEqualSlices(u8, data, result);
}

test "free releases pages" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    // Legacy one-page-per-chain writer: this test asserts that freeing a
    // var-chain releases its WHOLE page back to free space. Slab packing
    // (default ON since P7) tombstones the slot but keeps the shared fill page,
    // so opt the legacy writer back in to keep exercising the page-release path.
    store.slab_packing = false;

    const free_before = env.fsm.freeCount();
    const ref = try store.write("some data");
    const free_after_write = env.fsm.freeCount();
    try testing.expect(free_after_write < free_before);

    try store.free(ref);
    const free_after_free = env.fsm.freeCount();
    try testing.expectEqual(free_before, free_after_free);
}

test "read rejects data_len exceeding dataCapacity (dataCapacity+1)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    // Allocate a real page through the free space manager so it has a valid page_id.
    const page_id = try env.fsm.allocPage();

    // Pin the page and write a corrupt header directly: next_page=0, data_len=cap+1.
    const frame = try env.pool.pinNew(.var_store, page_id);
    const frame_idx = env.pool.frameIndex(frame);
    const page_data = frame.dataSlice();
    const meta_off = PAGE_HEADER_SIZE;
    @memcpy(page_data[meta_off..][0..8], &std.mem.toBytes(@as(u64, 0))); // next_page = 0
    const bad_len: u32 = store.dataCapacity() + 1;
    @memcpy(page_data[meta_off + 8 ..][0..4], &std.mem.toBytes(bad_len));
    env.pool.unpin(frame_idx, true);

    // Build a ref matching how write() encodes it.
    const ref: u64 = @as(u64, page_id) << 16;
    try testing.expectError(error.DataCorruption, store.read(ref, testing.allocator));
}

test "read rejects data_len exceeding dataCapacity (0xFFFFFFFF)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const page_id = try env.fsm.allocPage();

    const frame = try env.pool.pinNew(.var_store, page_id);
    const frame_idx = env.pool.frameIndex(frame);
    const page_data = frame.dataSlice();
    const meta_off = PAGE_HEADER_SIZE;
    @memcpy(page_data[meta_off..][0..8], &std.mem.toBytes(@as(u64, 0))); // next_page = 0
    @memcpy(page_data[meta_off + 8 ..][0..4], &std.mem.toBytes(@as(u32, 0xFFFFFFFF)));
    env.pool.unpin(frame_idx, true);

    const ref: u64 = @as(u64, page_id) << 16;
    try testing.expectError(error.DataCorruption, store.read(ref, testing.allocator));
}

// ============================================================================
// GAP var-store slab packing — P0 oracle: bytes/node baseline + round-trip
// parity harness.
//
// The var.store is the biggest un-slabbed store: measured at the 14.27M scale
// it costs exactly 8,192 B/node = ONE 8 KB page per node's var-chain, because
// `write` allocates a fresh page (chain) per call even for a ~40-90 B string.
// These tests LOCK that baseline as a regression oracle (the "before" number
// the slab initiative is judged against) and provide the round-trip parity
// harness reused by P1 (a slab-format block must read byte-identical to the
// legacy page-chain encoding) and the future writer.
// ============================================================================

/// Round-trip parity oracle. Writes every opaque var record through the legacy
/// funnel, forces the pages to disk (`flushAll` + a buffer pool small enough
/// that natural eviction re-reads from the persisted image), then reads each
/// back and asserts byte-identical. A node's label block and a property string
/// are both just bytes to VarStore, so one harness covers "every var string AND
/// every label reads back byte-identical after write + reopen".
fn expectVarRoundTripParity(store: *VarStore, pool: *buffer_pool_mod.BufferPool, records: []const []const u8) !void {
    const refs = try testing.allocator.alloc(u64, records.len);
    defer testing.allocator.free(refs);
    for (records, 0..) |rec, i| refs[i] = try store.write(rec);

    // Persist the whole store; with a small pool the earlier chains have
    // already been evicted to disk, so the read-back exercises the on-disk
    // image, not just the write cache.
    try pool.flushAll();

    for (records, 0..) |rec, i| {
        const got = try store.read(refs[i], testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, rec, got);
    }
}

test "P0 oracle: legacy var.store costs one full 8 KB page per small chain (the bloat baseline)" {
    const page_size: u32 = 8192;
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, 64);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, page_size);
    // This LOCKS the legacy one-page-per-chain baseline the slab writer must
    // beat — force legacy explicitly so the oracle stays valid regardless of
    // the default.
    store.slab_packing = false;

    // Short taxa var strings — scientific_name + authorship sized (~40-90 B),
    // far below one page.
    const n: u32 = 200;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "Acanthurus leucosternon {d} (Bennett, 1833)", .{i});
        _ = try store.write(s);
    }

    // One page allocated per chain — the un-slabbed layout, verbatim.
    const pages = env.fsm.allocatedCount();
    try testing.expectEqual(@as(u64, n), pages);

    // The number the whole initiative is judged against: 8,192 B/node.
    // P2's slab writer flips this assertion toward O(actual bytes); until then
    // this LOCKS the baseline so a regression that reinflates it fails loudly.
    const bytes_per_node = pages * page_size / n;
    try testing.expectEqual(@as(u64, 8192), bytes_per_node);
}

test "P0 parity: short strings + label blocks round-trip byte-identical (legacy, after flush)" {
    // Small pool (8 pages) vs many chains ⇒ eviction forces disk round-trips.
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 8);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    // Legacy one-page-per-chain writer under test (name: "legacy, after
    // flush"): pin it so store.write() exercises the legacy chain + eviction
    // disk round-trip, not the slab writer (default ON since P7).
    store.slab_packing = false;

    var records: std.ArrayList([]const u8) = .empty;
    defer {
        for (records.items) |r| testing.allocator.free(r);
        records.deinit(testing.allocator);
    }

    // Interleave variable-length taxa strings with encoded label blocks — the
    // exact on-disk LabelStore encoding ([u16 count][u32 ids...]) so "labels
    // read back byte-identical" is covered at the byte level.
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        if (i % 2 == 0) {
            const s = try std.fmt.allocPrint(testing.allocator, "Chromis viridis {d} authorship remark payload", .{i});
            try records.append(testing.allocator, s);
        } else {
            const nlabels: u32 = 1 + (i % 5);
            const buf = try testing.allocator.alloc(u8, 2 + nlabels * 4);
            std.mem.writeInt(u16, buf[0..2], @intCast(nlabels), .little);
            var k: u32 = 0;
            while (k < nlabels) : (k += 1) {
                std.mem.writeInt(u32, buf[2 + k * 4 ..][0..4], i * 100 + k, .little);
            }
            try records.append(testing.allocator, buf);
        }
    }

    try expectVarRoundTripParity(&store, &env.pool, records.items);
}

// ============================================================================
// GAP var-store slab packing — P1 slab READ path (read-both), NO writer.
//
// The production write path stays legacy in this phase; slab blocks are
// hand-built by the raw fixture below (the on-disk-format oracle) and proven to
// read byte-identical to the legacy page-chain encoding of the same data. The
// P2 writer packs NEW small chains + graduates overflowing ones.
// ============================================================================

const LabelStore = @import("label_store.zig").LabelStore;

/// Hand-build one SLAB block page: VarSlab header (marker + slot_count = number
/// of slots), byte runs packed FORWARD from VAR_SLAB_RUNS_OFFSET, slot
/// directory grown BACKWARD from the page tail. `runs[i].len == 0` writes slot
/// i as a TOMBSTONE. Raw bytes — deliberately NOT the (future P2) production
/// writer; the read-path oracle mirroring adj_store's writeRawSlabBlock.
fn writeRawSlabVarBlock(store: *VarStore, runs: []const []const u8) !PageId {
    const page_id = try store.free_space.allocPage();
    const frame = try store.buffer_pool.pinNew(.var_store, page_id);
    const frame_idx = store.buffer_pool.frameIndex(frame);
    const data = frame.dataSlice();

    const off: usize = PAGE_HEADER_SIZE;
    std.mem.writeInt(u64, data[off..][0..8], 0, .little); // next_page: never chained
    std.mem.writeInt(u32, data[off + 8 ..][0..4], VAR_SLAB_MARKER, .little);
    std.mem.writeInt(u32, data[off + 12 ..][0..4], @intCast(runs.len), .little); // slot_count

    var run_off: u32 = VAR_SLAB_RUNS_OFFSET;
    for (runs, 0..) |run, i| {
        if (run.len == 0) {
            writeVarSlabSlot(data, 0, @intCast(i), .{ .offset = VAR_SLAB_SLOT_TOMBSTONE, .byte_len = 0 });
            continue;
        }
        writeVarSlabSlot(data, 0, @intCast(i), .{ .offset = run_off, .byte_len = @intCast(run.len) });
        @memcpy(data[run_off..][0..run.len], run);
        run_off += @intCast(run.len);
    }

    store.buffer_pool.unpin(frame_idx, true);
    return page_id;
}

/// Encode a label set the way LabelStore does ([u16 count][u32 ids...]).
fn encodeLabelBlock(allocator: Allocator, ids: []const u32) ![]u8 {
    const buf = try allocator.alloc(u8, 2 + ids.len * 4);
    std.mem.writeInt(u16, buf[0..2], @intCast(ids.len), .little);
    for (ids, 0..) |id, i| std.mem.writeInt(u32, buf[2 + i * 4 ..][0..4], id, .little);
    return buf;
}

test "P1 slab var heads: bit-63 tag encode/decode round-trip; legacy heads untagged" {
    // Legacy refs (incl. 0 = no chain and a `first_page << 16` ref) are never
    // slab heads.
    try testing.expect(!isSlabHead(0));
    try testing.expect(!isSlabHead(@as(u64, 1) << 16));
    try testing.expect(!isSlabHead(0x7FFF_FFFF_FFFF_FFFF));

    const head = encodeSlabHead(12345, 678);
    try testing.expect(isSlabHead(head));
    try testing.expectEqual(@as(PageId, 12345), slabHeadPageId(head));
    try testing.expectEqual(@as(u32, 678), slabHeadSlot(head));

    // Extremes of both fields survive the round trip.
    const big = encodeSlabHead((@as(u64, 1) << 39) - 1, (1 << 24) - 1);
    try testing.expect(isSlabHead(big));
    try testing.expectEqual((@as(u64, 1) << 39) - 1, slabHeadPageId(big));
    try testing.expectEqual(@as(u32, (1 << 24) - 1), slabHeadSlot(big));
}

test "P1 slab read path: each (block, slot) head reads byte-identical to the legacy chain" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    // store.write() must produce LEGACY chain refs so the read-both comparison
    // below is genuinely legacy-vs-slab (slab default ON since P7);
    // writeRawSlabVarBlock builds the slab block directly regardless.
    store.slab_packing = false;

    // The SAME payloads, written two ways — a legacy page-chain per payload and
    // all payloads packed into ONE shared slab block. Every read must match the
    // source bytes AND match across the two encodings (the read-both invariant).
    const payloads = [_][]const u8{
        "Acanthurus leucosternon",
        "Chromis viridis (Cuvier, 1830)",
        "remarks: reef-associated; depth 2-40 m; IUCN LC",
    };

    var legacy_refs: [payloads.len]u64 = undefined;
    for (payloads, 0..) |p, i| legacy_refs[i] = try store.write(p);

    const page = try writeRawSlabVarBlock(&store, &payloads);

    for (payloads, 0..) |p, i| {
        const via_legacy = try store.read(legacy_refs[i], testing.allocator);
        defer testing.allocator.free(via_legacy);
        const via_slab = try store.read(encodeSlabHead(page, @intCast(i)), testing.allocator);
        defer testing.allocator.free(via_slab);
        try testing.expectEqualSlices(u8, p, via_legacy);
        try testing.expectEqualSlices(u8, p, via_slab);
        try testing.expectEqualSlices(u8, via_legacy, via_slab);
    }
}

test "P1 slab read path: LabelStore decodes label blocks packed in a slab block" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    // Labels live in var_store; pack two label blocks as slab runs and read
    // them back through the REAL LabelStore (which funnels via var_store.read).
    const ids_a = [_]u32{ 10, 20, 30 };
    const ids_b = [_]u32{ 7, 42 };
    const block_a = try encodeLabelBlock(testing.allocator, &ids_a);
    defer testing.allocator.free(block_a);
    const block_b = try encodeLabelBlock(testing.allocator, &ids_b);
    defer testing.allocator.free(block_b);

    const runs = [_][]const u8{ block_a, block_b };
    const page = try writeRawSlabVarBlock(&store, &runs);

    var ls = LabelStore.init(&store);

    const got_a = try ls.getLabels(encodeSlabHead(page, 0), testing.allocator);
    defer testing.allocator.free(got_a);
    try testing.expectEqualSlices(u32, &ids_a, got_a);

    const got_b = try ls.getLabels(encodeSlabHead(page, 1), testing.allocator);
    defer testing.allocator.free(got_b);
    try testing.expectEqualSlices(u32, &ids_b, got_b);
}

test "P1: slab + legacy var chains coexist; an untagged head into a slab block is corruption" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    // The "legacy" write must be a real legacy chain ref for slab + legacy
    // coexistence to be exercised (slab default ON since P7).
    store.slab_packing = false;

    const legacy = try store.write("legacy payload");
    const runs = [_][]const u8{"slabbed payload"};
    const slab_page = try writeRawSlabVarBlock(&store, &runs);

    const via_legacy = try store.read(legacy, testing.allocator);
    defer testing.allocator.free(via_legacy);
    try testing.expectEqualStrings("legacy payload", via_legacy);

    const via_slab = try store.read(encodeSlabHead(slab_page, 0), testing.allocator);
    defer testing.allocator.free(via_slab);
    try testing.expectEqualStrings("slabbed payload", via_slab);

    // An UNTAGGED head pointing at the slab block is a legacy chain walk into a
    // slab block: the marker sits in the `data_len` window and exceeds
    // dataCapacity, so the existing legacy guard rejects it — never parsed.
    const untagged: u64 = @as(u64, slab_page) << 16;
    try testing.expectError(error.DataCorruption, store.read(untagged, testing.allocator));
}

test "P1 slab read path rejects tombstoned, out-of-range, out-of-bounds, and page-0 heads" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const runs = [_][]const u8{ "live", "" }; // slot 1 empty => tombstone
    const page = try writeRawSlabVarBlock(&store, &runs);

    // Sanity: slot 0 still reads.
    {
        const ok = try store.read(encodeSlabHead(page, 0), testing.allocator);
        defer testing.allocator.free(ok);
        try testing.expectEqualStrings("live", ok);
    }
    // Tombstoned slot behind a stored head ref violates the live-head invariant.
    try testing.expectError(error.DataCorruption, store.read(encodeSlabHead(page, 1), testing.allocator));
    // Slot index beyond the directory.
    try testing.expectError(error.DataCorruption, store.read(encodeSlabHead(page, 9), testing.allocator));
    // F1: a slab-tagged head whose page bits decode to 0 (page 0 reserved) is
    // corruption, never silently-empty.
    try testing.expectError(error.DataCorruption, store.read(encodeSlabHead(0, 0), testing.allocator));

    // Corrupt slot 0's run bounds so it overruns the slot directory.
    {
        const frame = try store.buffer_pool.pin(.var_store, page);
        const idx = store.buffer_pool.frameIndex(frame);
        writeVarSlabSlot(frame.dataSlice(), 0, 0, .{ .offset = VAR_SLAB_RUNS_OFFSET, .byte_len = 5000 });
        store.buffer_pool.unpin(idx, true);
        try testing.expectError(error.DataCorruption, store.read(encodeSlabHead(page, 0), testing.allocator));
    }
}

test "P2: free() slot-tombstones a slab run; sibling slots stay live and readable" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const runs = [_][]const u8{ "alpha payload", "beta payload", "gamma payload" };
    const page = try writeRawSlabVarBlock(&store, &runs);
    const free_before = env.fsm.freeCount();

    // Tombstone the MIDDLE slot.
    try store.free(encodeSlabHead(page, 1));

    // The shared block is NOT reclaimed (tombstone-only; no chain-free).
    try testing.expectEqual(free_before, env.fsm.freeCount());

    // The tombstoned slot now errors loudly (live-head invariant) …
    try testing.expectError(error.DataCorruption, store.read(encodeSlabHead(page, 1), testing.allocator));

    // … while the sibling slots remain byte-identical and untouched.
    {
        const a = try store.read(encodeSlabHead(page, 0), testing.allocator);
        defer testing.allocator.free(a);
        try testing.expectEqualStrings("alpha payload", a);
        const c = try store.read(encodeSlabHead(page, 2), testing.allocator);
        defer testing.allocator.free(c);
        try testing.expectEqualStrings("gamma payload", c);
    }
}

test "legacy chain: a multi-page write never touches the reserved encryption tail" {
    const page_size: u32 = 4096;
    const tail: u32 = 16; // encryption.TAG_SIZE
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, page_size);
    store.slab_packing = false;
    store.tail_reserve = tail;

    // Three pages' worth of non-zero payload.
    const payload = try testing.allocator.alloc(u8, 3 * page_size);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @as(u8, @truncate(i)) | 1;

    const ref = try store.write(payload);
    {
        const back = try store.read(ref, testing.allocator);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u8, payload, back);
    }

    // Every page of the chain must leave its final `tail` bytes untouched —
    // that region belongs to the pager's AES-GCM tag.
    var page: PageId = VarStore.refFirstPage(ref);
    var pages: usize = 0;
    while (page != 0) : (pages += 1) {
        const frame = try env.pool.pin(.var_store, page);
        const idx = env.pool.frameIndex(frame);
        const data = frame.dataSlice();
        for (data[data.len - tail ..]) |b| try testing.expectEqual(@as(u8, 0), b);
        const next = std.mem.bytesToValue(u64, data[PAGE_HEADER_SIZE..][0..8]);
        env.pool.unpin(idx, false);
        page = next;
    }
    try testing.expect(pages >= 3);
}

test "writeLegacyChain: bypasses slab packing and frees without arming the shared undo slot" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    store.slab_packing = true;

    // A run small enough that `write` WOULD slab-pack it.
    const small = "tiny run";
    try testing.expect(isSlabHead(try store.write(small)));

    // writeLegacyChain always produces a legacy `first_page << 16` ref…
    const legacy_ref = try store.writeLegacyChain(small);
    try testing.expect(!isSlabHead(legacy_ref));
    {
        const back = try store.read(legacy_ref, testing.allocator);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(small, back);
    }

    // …and freeing it must NOT touch the per-store slab undo slot, which the
    // label path relies on being exclusively its own (PropStore and
    // LabelStore share one VarStore).
    const runs = [_][]const u8{ "keep-me", "armed" };
    const page = try writeRawSlabVarBlock(&store, &runs);
    store.resetSlabUndo();
    try store.free(encodeSlabHead(page, 1)); // arms the undo record
    try store.free(legacy_ref); // must leave that record intact
    try store.undoLastSlabTombstone();
    const revived = try store.read(encodeSlabHead(page, 1), testing.allocator);
    defer testing.allocator.free(revived);
    try testing.expectEqualStrings("armed", revived);
}

test "P2: undoLastSlabTombstone revives the slot the current op tombstoned" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const runs = [_][]const u8{ "keep-me", "revive-me" };
    const page = try writeRawSlabVarBlock(&store, &runs);

    store.resetSlabUndo();
    try store.free(encodeSlabHead(page, 1));
    try testing.expectError(error.DataCorruption, store.read(encodeSlabHead(page, 1), testing.allocator));

    // The engine's failure path calls this: the slot comes back to life with
    // byte-identical content, and the undo record is consumed (idempotent).
    try store.undoLastSlabTombstone();
    {
        const revived = try store.read(encodeSlabHead(page, 1), testing.allocator);
        defer testing.allocator.free(revived);
        try testing.expectEqualStrings("revive-me", revived);
    }
    try store.undoLastSlabTombstone(); // no-op second time
    {
        const still = try store.read(encodeSlabHead(page, 1), testing.allocator);
        defer testing.allocator.free(still);
        try testing.expectEqualStrings("revive-me", still);
    }

    // Sibling untouched throughout.
    const keep = try store.read(encodeSlabHead(page, 0), testing.allocator);
    defer testing.allocator.free(keep);
    try testing.expectEqualStrings("keep-me", keep);
}

test "P2: free() on an already-tombstoned slab slot errors (live-head invariant)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const runs = [_][]const u8{"solo"};
    const page = try writeRawSlabVarBlock(&store, &runs);
    try store.free(encodeSlabHead(page, 0));
    // Double-free of a dead slot is corruption, not a silent no-op.
    try testing.expectError(error.DataCorruption, store.free(encodeSlabHead(page, 0)));
}

// ============================================================================
// GAP var-store slab packing — P2 slab WRITE path (the REAL writer, not the
// hand-built fixture): NEW small runs pack into shared blocks; oversized runs
// graduate to legacy; the empty-string encoding is distinct from a tombstone;
// LabelStore add/remove funnels through the writer/tombstone.
// ============================================================================

test "P2 writer: many small var runs pack into shared slab blocks and read byte-identical" {
    const page_size: u32 = 8192;
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, 64);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, page_size);
    store.slab_packing = true;

    const n: u32 = 200;
    var refs: [n]u64 = undefined;
    var bufs: [n][96]u8 = undefined;
    var lens: [n]usize = undefined;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const s = try std.fmt.bufPrint(&bufs[i], "Acanthurus leucosternon {d} (Bennett, 1833)", .{i});
        lens[i] = s.len;
        refs[i] = try store.write(s);
        try testing.expect(isSlabHead(refs[i])); // packed, not a legacy chain
    }

    // Packing: 200 short runs share a handful of pages, NOT 200 (the legacy
    // baseline). bytes/node collapses from 8,192 to the acceptance target.
    const pages = env.fsm.allocatedCount();
    try testing.expect(pages < 10);
    const bytes_per_node = pages * page_size / n;
    try testing.expect(bytes_per_node <= 256);

    // Every packed run reads byte-identical — no cross-slot bleed.
    i = 0;
    while (i < n) : (i += 1) {
        const got = try store.read(refs[i], testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(bufs[i][0..lens[i]], got);
    }
}

test "P2 writer: an empty var string packs as a LIVE empty run, distinct from a tombstone" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    store.slab_packing = true;

    const empty_ref = try store.write("");
    try testing.expect(isSlabHead(empty_ref));
    const nonempty_ref = try store.write("x");

    // The empty run reads back as an EMPTY slice — NOT a DataCorruption
    // tombstone. This is the explicit empty-string-vs-tombstone encoding: a
    // live run keeps a real offset (byte_len 0); only offset == TOMBSTONE is
    // dead.
    {
        const got = try store.read(empty_ref, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }

    // Tombstoning it flips it to DataCorruption, proving the two encodings are
    // distinct.
    try store.free(empty_ref);
    try testing.expectError(error.DataCorruption, store.read(empty_ref, testing.allocator));

    // Sibling non-empty run untouched.
    const x = try store.read(nonempty_ref, testing.allocator);
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("x", x);
}

test "P2 writer: a run over the graduation threshold falls back to a legacy chain (byte-identical)" {
    const page_size: u32 = 8192;
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, page_size);
    store.slab_packing = true;

    // A small run slabs …
    const small = try store.write("small run");
    try testing.expect(isSlabHead(small));

    // … a 4 KB run (>> VAR_SLAB_MAX_RUN = 1 KB) graduates to a legacy page
    // chain, read-both correct.
    const big = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 256);
    const big_ref = try store.write(big);
    try testing.expect(!isSlabHead(big_ref)); // legacy

    const got_small = try store.read(small, testing.allocator);
    defer testing.allocator.free(got_small);
    try testing.expectEqualStrings("small run", got_small);
    const got_big = try store.read(big_ref, testing.allocator);
    defer testing.allocator.free(got_big);
    try testing.expectEqualSlices(u8, big, got_big);
}

test "P2 writer: LabelStore add/remove funnels through slab writer/tombstone (update + delete + sibling)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();
    var store = VarStore.init(&env.pool, &env.fsm, 4096);
    store.slab_packing = true;
    var ls = LabelStore.init(&store);

    // Node A: each add rewrites the block (new slab slot, old slot tombstoned).
    var a_head: u64 = 0;
    {
        const r = try ls.addLabel(a_head, 10, testing.allocator);
        a_head = r.head;
        try testing.expect(isSlabHead(a_head));
    }
    a_head = (try ls.addLabel(a_head, 20, testing.allocator)).head;
    a_head = (try ls.addLabel(a_head, 30, testing.allocator)).head;

    // Node B shares the same block — must be undisturbed by A's churn.
    const b = try ls.putLabels(&[_]u32{ 7, 8 }, testing.allocator);
    try testing.expect(isSlabHead(b));

    // Delete a middle label from A (rewrite + tombstone the old slot).
    a_head = (try ls.removeLabel(a_head, 20, testing.allocator)).head;
    {
        const got = try ls.getLabels(a_head, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u32, &[_]u32{ 10, 30 }, got);
    }
    {
        const got = try ls.getLabels(b, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u32, &[_]u32{ 7, 8 }, got);
    }

    // Remove the rest of A → head 0; B still intact after all the tombstoning.
    a_head = (try ls.removeLabel(a_head, 10, testing.allocator)).head;
    const last = try ls.removeLabel(a_head, 30, testing.allocator);
    try testing.expectEqual(@as(u64, 0), last.head);
    try testing.expectEqual(@as(u16, 0), last.count);
    const got_b2 = try ls.getLabels(b, testing.allocator);
    defer testing.allocator.free(got_b2);
    try testing.expectEqualSlices(u32, &[_]u32{ 7, 8 }, got_b2);
}

test {
    std.testing.refAllDecls(@This());
}
