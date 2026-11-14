// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const edge_mod = @import("edge.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const EdgeEntry = edge_mod.EdgeEntry;
const EdgeBlockHeader = edge_mod.EdgeBlockHeader;
const PageId = types.PageId;
const EdgeId = types.EdgeId;
const FileId = types.FileId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

const BLOCK_HEADER_SIZE: u32 = @sizeOf(EdgeBlockHeader);

/// Maximum hops allowed in an adjacency-block chain traversal before
/// assuming the chain is corrupt or circular (SEC-0042).
pub const MAX_CHAIN_HOPS: u32 = 100_000;

// ============================================================================
// GAP adjacency slab packing — tagged slab head refs (read path since P1).
//
// LAYOUT DISCRIMINATION (the prop-store slab discipline, verbatim): a TAG BIT
// in the chain head ref itself.
//   * Legacy block-chain head: the bare PageId of the head block; bit 63 is
//     CLEAR (page ids are allocated sequentially and never approach 2^63).
//     Reads via the existing chain walk, unchanged, forever.
//   * Slab head: bit 63 is SET. The remaining bits pack (block, slot):
//     bits [24..63) = slab block page id (39 bits), bits [0..24) = slot index
//     (24 bits). Many small chains share one slab block; the slot directory
//     maps each slot to its contiguous run of v2 entries (layout spec in
//     edge.zig, SLAB section).
//
// WHY the tag lives in the head ref and not only the block header: to read a
// block at all you must first know its page id, but a legacy head uses the
// FULL u64 as the page id while a slab head packs (page, slot) into it — so
// the discriminator must be in the head. The slab block ALSO stamps
// entry_format = ENTRY_FORMAT_SLAB (defense-in-depth: slab reads reject a
// block whose format byte is wrong, and legacy chain walks reject slab blocks
// — a slab block is NEVER linked into a block chain).
//
// `NodeRec.out_head` / `NodeRec.in_head` (u64) and `in_head_dir` values are
// unchanged in width and opaque to every layer above AdjStore.
// ============================================================================

/// Tag bit marking a slab-packed head ref (vs a legacy bare block page id).
pub const SLAB_HEAD_TAG_BIT: u64 = @as(u64, 1) << 63;
/// Number of low bits of a slab head used for the slot index.
const SLAB_HEAD_SLOT_BITS: u6 = 24;
const SLAB_HEAD_SLOT_MASK: u64 = (@as(u64, 1) << SLAB_HEAD_SLOT_BITS) - 1;
/// Maximum page id encodable in a slab head (64 - 1 tag - 24 slot = 39).
const SLAB_HEAD_MAX_PAGE_ID: u64 = @as(u64, 1) << (64 - 1 - SLAB_HEAD_SLOT_BITS);

/// True when a chain head ref is a slab-packed (block, slot) pointer (bit 63
/// set) rather than a legacy bare block page id. Head 0 (= empty chain) is
/// untagged and stays the universal "no chain" sentinel.
pub fn isSlabHead(head: u64) bool {
    return (head & SLAB_HEAD_TAG_BIT) != 0;
}

/// Encode a slab head ref from (slab block page id, slot index).
pub fn encodeSlabHead(page_id: PageId, slot: u32) u64 {
    std.debug.assert(page_id < SLAB_HEAD_MAX_PAGE_ID);
    std.debug.assert(@as(u64, slot) <= SLAB_HEAD_SLOT_MASK);
    return SLAB_HEAD_TAG_BIT | (page_id << SLAB_HEAD_SLOT_BITS) | (@as(u64, slot) & SLAB_HEAD_SLOT_MASK);
}

/// P2 entry requirement 4: the WRITER's fallible encoder. A slab head packs
/// the page id into 39 bits; a slab fill page allocated at/above 2^39 cannot
/// be addressed by a slab head, so the writer must FALL BACK to a legacy
/// block chain rather than corrupt the head — NEVER a release assert (which
/// `encodeSlabHead` uses, as its callers already hold in-range ids). Returns
/// null when the page id (or slot) overflows its field; the caller uses the
/// legacy layout instead.
pub fn tryEncodeSlabHead(page_id: PageId, slot: u32) ?u64 {
    if (page_id >= SLAB_HEAD_MAX_PAGE_ID) return null;
    if (@as(u64, slot) > SLAB_HEAD_SLOT_MASK) return null;
    return encodeSlabHead(page_id, slot);
}

/// Decode the slab block page id from a slab head ref.
pub fn slabHeadPageId(head: u64) PageId {
    return (head & ~SLAB_HEAD_TAG_BIT) >> SLAB_HEAD_SLOT_BITS;
}

/// Decode the slot index from a slab head ref.
pub fn slabHeadSlot(head: u64) u32 {
    return @intCast(head & SLAB_HEAD_SLOT_MASK);
}

/// Adjacency block storage for outgoing/incoming edges.
/// Each adjacency list is a chain of pages, each containing an EdgeBlockHeader
/// followed by an array of edge records at the stride of THAT block's
/// `entry_format` (GAP-ENT-0024 read-both): v1 blocks hold 24 B records
/// (no public_id — readers surface 0), v2 blocks hold 32 B records with the
/// inline public_id. Chains may mix formats block-by-block; every reader and
/// in-place mutator below parses each block by its own header byte.
pub const AdjStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    file_id: FileId,
    page_size: u32,
    /// Bytes reserved at the tail of every page for the page-level AES-GCM
    /// authentication tag when at-rest encryption is enabled (the pager
    /// writes the tag into the final `tail_reserve` bytes on flush). The
    /// SLAB slot directory grows backward from `page_size - tail_reserve`,
    /// so it never collides with the tag — the same reservation PropStore
    /// makes for its backward-growing key directory. Legacy v1/v2 chain
    /// blocks grow forward only and are unaffected. Set by the engine to
    /// the encryption tag size when a key is configured, 0 otherwise.
    tail_reserve: u32 = 0,
    /// Capacity of the blocks the PRODUCTION WRITER creates (v2, 32 B
    /// entries, since P2). Use `capacityFor` when parsing an existing block —
    /// legacy v1 blocks hold more (24 B) entries. Named `writer_...` (review
    /// F6) so no future caller mistakes it for a universal per-block capacity
    /// and under-counts v1 blocks (339 vs 254 @ 8 KB).
    writer_entries_per_block: u32,

    /// GAP adjacency slab packing (P2): when true, a NEW small chain's edges
    /// are packed as a slot run in a shared slab fill block instead of a whole
    /// dedicated block; a chain that outgrows the slab GRADUATES to a legacy
    /// block chain. Default OFF — every write stays byte-identical to the
    /// pre-P2 legacy layout (read-both keeps parsing any slab blocks a
    /// slab-enabled store wrote). The engine flips it on per adjacency store.
    slab_packing: bool = false,

    /// GAP-0060: when true, NEW blocks this writer creates use the WIDE (v3 /
    /// slab-v3, 40 B) entry format so an edge's `prop_head` can be widened
    /// to a prop-store slab head (u64) IN PLACE later — geode adds the edge
    /// with `prop_head==0` then attaches props, so the durable record must
    /// have room for the eventual u64 head without changing the node head.
    /// Default OFF — a false value is byte-identical to pre-0060 (v2 / slab-v2
    /// writes). Read-both parses v1/v2/v3/slab-v2/slab-v3 by each block's
    /// format byte regardless of this flag. The engine sets it from
    /// `GraphConfig.edge_prop_slab_packing`.
    wide_heads: bool = false,

    /// The shared "current fill block" new slab runs append to. In-memory
    /// only: after a reopen the first slab write starts a fresh fill block (a
    /// partially-filled predecessor keeps its data and is read normally). The
    /// append state (slot count, next free offset) is always re-derived from
    /// the block itself, never cached, so a stale value cannot corrupt a page.
    current_fill_page: ?PageId = null,

    /// P2 (WAL slab-awareness, prop-store P4 discipline): page ids DIRTIED by
    /// the CURRENT mutating op (`addEdge` / `removeEdge` / `updateEdgePropHead`),
    /// deduplicated, in first-touch order. The ENGINE WAL-images every entry
    /// after the op returns. A chain head is no longer always a page id (slab
    /// heads encode tag|page|slot) and one op can dirty SEVERAL pages (a slab
    /// relocation tombstones the old block and appends to the fill block; a
    /// graduation additionally writes the fresh legacy chain), so logging just
    /// "the head" would image a bogus page id (slab) or under-log (multi-page).
    /// Worst case (graduation of a full slab run) dirties ≤ ~3 distinct pages;
    /// 16 leaves slack and `recordTouched` fails loudly rather than drop a page.
    touched_pages: [MAX_TOUCHED_PAGES]PageId = undefined,
    touched_len: u8 = 0,

    /// GAP-ENT-0022(b) discipline: undo record for the slab-slot tombstone
    /// written by the CURRENT op (at most one — a graduation/relocation
    /// tombstones exactly once, as its LAST mutation). Lets the ENGINE roll
    /// the tombstone back (`undoLastSlabTombstone`) when it fails AFTER the
    /// op returned (WAL imaging, index maintenance, commit) — its caller then
    /// never stores the new head and the old head would reference a dead slot
    /// forever. Cleared by `beginOp` at the top of every mutating op.
    last_slab_tombstone: ?SlabTombstoneUndo = null,

    pub const MAX_TOUCHED_PAGES: usize = 16;

    const SlabTombstoneUndo = struct { page_id: PageId, slot: u32, offset: u32, entry_count: u32 };

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, file_id: FileId, page_size: u32) AdjStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .file_id = file_id,
            .page_size = page_size,
            .writer_entries_per_block = edge_mod.entriesPerBlock(page_size, edge_mod.ENTRY_FORMAT_V2),
        };
    }

    /// P2: forget the previous op's dirtied-page set + tombstone undo. Called
    /// at the top of every public mutating entry point.
    fn beginOp(self: *AdjStore) void {
        self.touched_len = 0;
        self.last_slab_tombstone = null;
    }

    /// P2: record a page dirtied by the current mutating op (deduplicated).
    /// Over-recording is harmless (a redundant page image is still correct);
    /// UNDER-recording is silent data loss on crash — so overflow fails the
    /// op loudly instead of dropping a page.
    fn recordTouched(self: *AdjStore, page_id: PageId) !void {
        for (self.touched_pages[0..self.touched_len]) |p| {
            if (p == page_id) return;
        }
        if (self.touched_len >= MAX_TOUCHED_PAGES) return error.TooManyDirtyAdjPages;
        self.touched_pages[self.touched_len] = page_id;
        self.touched_len += 1;
    }

    /// P2: the pages dirtied by the most recent mutating call on this store.
    /// Valid until the next mutating call. The engine WAL-images each entry.
    pub fn touchedPages(self: *const AdjStore) []const PageId {
        return self.touched_pages[0..self.touched_len];
    }

    /// GAP-ENT-0022(b): best-effort rollback of the slab-slot tombstone
    /// written by the MOST RECENT mutating op. The engine's write paths call
    /// this from an errdefer when they fail AFTER AdjStore relocated/graduated
    /// a slab run and tombstoned the old slot: the engine's caller then never
    /// stores the returned new head, so without the rollback the node record /
    /// in-dir would reference a dead slot — permanent corruption for that
    /// chain. Restores the old slot's entry_count; the run bytes are still
    /// intact (a tombstone only rewrites the slot directory, never the run
    /// data, within the same op), so the old head reads correctly again. The
    /// already-placed new run is leaked until a future compaction — benign.
    /// No-op when the current op wrote no tombstone. Allocation-free (resident
    /// pin + one slot write) so it can succeed under the OOM that failed the op.
    pub fn undoLastSlabTombstone(self: *AdjStore) !void {
        const undo = self.last_slab_tombstone orelse return;
        self.last_slab_tombstone = null;
        const frame = try self.buffer_pool.pin(self.file_id, undo.page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        const cur = edge_mod.readSlabSlot(data, self.tail_reserve, undo.slot);
        if (cur.offset != edge_mod.SLAB_SLOT_TOMBSTONE) {
            // Defensive: not the tombstone this op wrote — leave it alone.
            self.buffer_pool.unpin(frame_idx, false);
            return;
        }
        edge_mod.writeSlabSlot(data, self.tail_reserve, undo.slot, .{ .offset = undo.offset, .entry_count = undo.entry_count });
        self.buffer_pool.unpin(frame_idx, true);
    }

    /// Per-block entry capacity for a (validated) entry format.
    fn capacityFor(self: *const AdjStore, entry_format: u8) u32 {
        return edge_mod.entriesPerBlock(self.page_size, entry_format);
    }

    /// GAP-0060: an entry needs the WIDE (v3 / slab-v3) format when its
    /// `prop_head` does not fit 32 bits (a prop-store slab head, bit 63 set).
    fn entryNeedsWide(entry: EdgeEntry) bool {
        return (entry.prop_head >> 32) != 0;
    }

    /// Chain-block format for a NEW block holding `entry`: v3 when this writer
    /// is wide-heads OR the entry already carries a >u32 head; else v2 (the
    /// no-truncate rule — a wide head is never packed into a v2 record).
    fn newChainFormat(self: *const AdjStore, entry: EdgeEntry) u8 {
        return if (self.wide_heads or entryNeedsWide(entry))
            edge_mod.ENTRY_FORMAT_V3
        else
            edge_mod.ENTRY_FORMAT_V2;
    }

    /// Slab-block format for a NEW slab block this writer creates: slab-v3 when
    /// wide-heads OR any entry needs the wide head; else slab-v2.
    fn newSlabFormat(self: *const AdjStore, entries: []const EdgeEntry) u8 {
        if (self.wide_heads) return edge_mod.ENTRY_FORMAT_SLAB_V3;
        for (entries) |e| if (entryNeedsWide(e)) return edge_mod.ENTRY_FORMAT_SLAB_V3;
        return edge_mod.ENTRY_FORMAT_SLAB;
    }

    /// Add an edge entry to a node's adjacency list (O(1) head-insert).
    /// If the head block has space, inserts there. Otherwise allocates a new
    /// head block whose overflow points to the old head (0 head = new chain).
    /// Returns the head page_id (may be unchanged or new).
    ///
    /// Block-format policy (GAP-ENT-0024 P2 write path):
    ///   * Every NEW block is created v2 (32 B entries, inline public_id) —
    ///     the single construction site below serves the empty-head, the
    ///     full-head-overflow and the no-truncate paths.
    ///   * A v2 head with space takes an in-place append; `entry.public_id`
    ///     persists.
    ///   * A v1 (legacy) head with space takes an in-place 24 B append ONLY
    ///     when `entry.public_id == 0` (legacy callers — bit-for-bit the
    ///     pre-P2 behavior, no format churn). A REAL public_id is NEVER
    ///     silently truncated into a v1 record and the v1 block is NEVER
    ///     rewritten to v2: a fresh v2 block becomes the new head, chained to
    ///     the old one. v1 blocks stay read-only-FORMAT forever (in-place
    ///     field mutation of EXISTING v1 entries remains allowed elsewhere).
    pub fn addEdge(self: *AdjStore, head_page: PageId, entry: EdgeEntry) !PageId {
        self.beginOp();
        // Slab writes (new-chain packing + growth + graduation) land in the
        // slab path when packing is enabled; a tagged head always routes there.
        if (self.slab_packing or isSlabHead(head_page)) {
            return self.addEdgeSlab(head_page, entry);
        }
        return self.addEdgeLegacy(head_page, entry);
    }

    /// Legacy block-chain head-insert (the pre-P2 layout, verbatim). Records
    /// the single page it mutated/allocated into the touched set so the engine
    /// WAL-images exactly it — for a legacy chain that page always equals the
    /// returned head, so imaging is unchanged from pre-P2.
    fn addEdgeLegacy(self: *AdjStore, head_page: PageId, entry: EdgeEntry) !PageId {
        if (isSlabHead(head_page)) return error.SlabChainWriteNotSupported;
        if (head_page != 0) {
            const frame = try self.buffer_pool.pin(self.file_id, head_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            var bh = try self.readBlockHeader(data);

            const has_space = bh.count < @as(u16, @intCast(self.capacityFor(bh.entry_format)));
            // No-truncate rule: a v1 slot cannot carry a real public_id, and a
            // v1/v2 slot cannot carry a >u32 prop_head (GAP-0060). Either forces
            // a fresh wider head block instead of an in-place append.
            const would_drop_public_id =
                bh.entry_format == edge_mod.ENTRY_FORMAT_V1 and entry.public_id != 0;
            const would_drop_wide_head =
                bh.entry_format != edge_mod.ENTRY_FORMAT_V3 and entryNeedsWide(entry);
            if (has_space and !would_drop_public_id and !would_drop_wide_head) {
                // Record the WAL touch BEFORE the first byte is mutated.
                self.recordTouched(head_page) catch |err| {
                    self.buffer_pool.unpin(frame_idx, false);
                    return err;
                };
                // In-place append at the BLOCK's stride/format.
                self.writeEntry(data, bh.count, entry, bh.entry_format);
                bh.count += 1;
                bh.payload_size = @intCast(@as(u32, bh.count) * edge_mod.entrySize(bh.entry_format));
                self.writeBlockHeader(data, bh);
                self.buffer_pool.unpin(frame_idx, true);
                return head_page;
            }
            // Full head, or v1 head that must not absorb a real public_id:
            // leave it untouched and allocate a fresh v2 head in front of it.
            self.buffer_pool.unpin(frame_idx, false);
        }

        // Single block-construction site: a fresh v2 block as the new head;
        // the old head (0 for a new chain) becomes its overflow.
        const new_page = try self.free_space.allocPage();
        // Record the WAL touch BEFORE any byte is written; on failure release
        // the page (a recorded-but-freed page is harmless — the engine never
        // images a FAILED op's touched set).
        self.recordTouched(new_page) catch |err| {
            self.free_space.freePage(new_page) catch {};
            return err;
        };
        const new_frame = try self.buffer_pool.pinNew(self.file_id, new_page);
        const new_frame_idx = self.buffer_pool.frameIndex(new_frame);

        const new_data = new_frame.dataSlice();
        // pinNew zeroes the page; write header with count=1, then slot 0.
        // GAP-0060: a wide-heads writer (or a >u32-head entry) creates a v3
        // block so the head fits now and any in-place widen fits later.
        const new_fmt = self.newChainFormat(entry);
        self.writeBlockHeader(new_data, .{
            .next_block = head_page,
            .count = 1,
            .kind = 0,
            .entry_format = new_fmt,
            .payload_size = @intCast(edge_mod.entrySize(new_fmt)),
            .checksum = 0,
        });
        self.writeEntry(new_data, 0, entry, new_fmt);
        self.buffer_pool.unpin(new_frame_idx, true);
        return new_page;
    }

    // ------------------------------------------------------------------
    // Slab WRITE path (P2). Mirrors the reviewed prop-store slab writer:
    // new small chains pack into a shared fill block as slot runs; a chain
    // grows in place at the block's frontier, else relocates to a new slot,
    // else GRADUATES to a legacy block chain. Every touched page is recorded
    // for the engine to WAL-image; a relocation/graduation tombstones the old
    // slot LAST (the live-head invariant) and arms `undoLastSlabTombstone`.
    // ------------------------------------------------------------------

    /// GAP-0060: a slab block's write state now carries its entry `fmt`
    /// (ENTRY_FORMAT_SLAB=32B or ENTRY_FORMAT_SLAB_V3=40B) so run arithmetic
    /// strides at the block's own width.
    const SlabState = struct { slot_count: u32, next_off: u32, fmt: u8 };

    /// Re-derive a slab block's write state from the page (never cached):
    /// slot count + entry format (from the header) and the free-run frontier
    /// (max live run end, strided at the block's width). Tombstoned slots do
    /// not extend the frontier. Fails DataCorruption on a non-slab / chained /
    /// malformed block.
    fn slabBlockState(self: *const AdjStore, data: []const u8) error{DataCorruption}!SlabState {
        const bh = try self.readSlabBlockHeader(data);
        const stride = edge_mod.slabEntrySize(bh.entry_format);
        const slot_count: u32 = bh.count;
        const dir_start = edge_mod.slabDirStart(data.len, self.tail_reserve, slot_count);
        var next_off: u32 = edge_mod.SLAB_RUNS_OFFSET;
        var i: u32 = 0;
        while (i < slot_count) : (i += 1) {
            const s = edge_mod.readSlabSlot(data, self.tail_reserve, i);
            if (s.offset == edge_mod.SLAB_SLOT_TOMBSTONE) continue;
            if (s.offset < edge_mod.SLAB_RUNS_OFFSET) return error.DataCorruption;
            const end = @as(u64, s.offset) + @as(u64, s.entry_count) * stride;
            if (end > dir_start) return error.DataCorruption;
            if (end > next_off) next_off = @intCast(end);
        }
        return .{ .slot_count = slot_count, .next_off = next_off, .fmt = bh.entry_format };
    }

    /// Max run bytes that can ever fit a FRESH single-slot slab block.
    fn slabFreshRunCap(self: *const AdjStore) u64 {
        return @as(u64, self.page_size) - self.tail_reserve - edge_mod.SLAB_RUNS_OFFSET - edge_mod.SLAB_DIR_ENTRY_SIZE;
    }

    fn writeSlabRunEntryInto(data: []u8, run_offset: u32, idx: u32, entry: EdgeEntry, fmt: u8) void {
        const size = edge_mod.slabEntrySize(fmt);
        const off = @as(usize, run_offset) + @as(usize, idx) * size;
        edge_mod.encodeEntry(data[off .. off + size], entry, fmt);
    }

    /// Write a contiguous run of `fmt`-strided entries at `run_off` and its
    /// slot-dir entry (offset, count). Does NOT touch the header slot_count —
    /// the caller makes the new slot visible (fresh block: header count preset;
    /// fill block: bumpSlabSlotCount after).
    fn writeSlabRun(self: *const AdjStore, data: []u8, run_off: u32, slot: u32, entries: []const EdgeEntry, fmt: u8) void {
        for (entries, 0..) |e, k| writeSlabRunEntryInto(data, run_off, @intCast(k), e, fmt);
        edge_mod.writeSlabSlot(data, self.tail_reserve, slot, .{ .offset = run_off, .entry_count = @intCast(entries.len) });
    }

    fn bumpSlabSlotCount(self: *const AdjStore, data: []u8, new_count: u32, added_bytes: u32) void {
        const off = self.blockHeaderOffset();
        var bh: EdgeBlockHeader = @bitCast(data[off..][0..BLOCK_HEADER_SIZE].*);
        bh.count = @intCast(new_count);
        bh.payload_size = bh.payload_size +% @as(u16, @truncate(added_bytes));
        self.writeBlockHeader(data, bh);
    }

    fn bumpSlabPayload(self: *const AdjStore, data: []u8, added: u16) void {
        const off = self.blockHeaderOffset();
        var bh: EdgeBlockHeader = @bitCast(data[off..][0..BLOCK_HEADER_SIZE].*);
        bh.payload_size = bh.payload_size +% added;
        self.writeBlockHeader(data, bh);
    }

    /// Append `entries` (≥1) as a NEW slot run on the current fill block, or a
    /// fresh slab block when there is none / it is full. Returns the encoded
    /// slab head, or null when the run cannot fit even a fresh slab block, or
    /// the fresh block's page id overflows the slab-head field — the caller
    /// then GRADUATES to a legacy chain. Records the WAL touch BEFORE any byte
    /// is mutated; the new slot becomes visible only via the last write.
    fn appendSlabRun(self: *AdjStore, entries: []const EdgeEntry) !?u64 {
        std.debug.assert(entries.len >= 1);
        // GAP-0060: the run's stride is the writer's chosen slab format (v3 when
        // wide-heads or any entry needs the wide head; else v2).
        const want_fmt = self.newSlabFormat(entries);
        const stride = edge_mod.slabEntrySize(want_fmt);
        const run_bytes: u32 = @intCast(entries.len * stride);
        if (run_bytes > self.slabFreshRunCap()) return null;

        // Try the current fill block first — but only if its on-disk format
        // matches the run's required width (a wide entry can never append to a
        // v2 fill block, and vice versa). Within one session wide_heads is
        // constant so this always matches; the guard protects the wide-entry-
        // in-a-non-wide-session case (colocation rebuild of a widened edge).
        if (self.current_fill_page) |fill_page| {
            const frame = try self.buffer_pool.pin(self.file_id, fill_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const state = self.slabBlockState(data) catch |err| {
                self.buffer_pool.unpin(frame_idx, false);
                return err;
            };
            if (state.fmt == want_fmt and state.slot_count <= SLAB_HEAD_SLOT_MASK) {
                const slot: u32 = state.slot_count;
                const dir_needed: u64 = (@as(u64, slot) + 1) * edge_mod.SLAB_DIR_ENTRY_SIZE;
                const avail_end: u64 = @as(u64, self.page_size) - self.tail_reserve - dir_needed;
                if (@as(u64, state.next_off) + run_bytes <= avail_end) {
                    self.recordTouched(fill_page) catch |err| {
                        self.buffer_pool.unpin(frame_idx, false);
                        return err;
                    };
                    self.writeSlabRun(data, state.next_off, slot, entries, want_fmt);
                    self.bumpSlabSlotCount(data, slot + 1, run_bytes);
                    self.buffer_pool.unpin(frame_idx, true);
                    return encodeSlabHead(fill_page, slot); // fill_page already in range
                }
            }
            // Full (or slot indices exhausted, or format mismatch): retire it.
            self.buffer_pool.unpin(frame_idx, false);
            self.current_fill_page = null;
        }

        // Start a fresh slab fill block.
        const new_page = try self.free_space.allocPage();
        const head = tryEncodeSlabHead(new_page, 0) orelse {
            // page id overflows the 39-bit field — release and graduate.
            self.free_space.freePage(new_page) catch {};
            return null;
        };
        self.recordTouched(new_page) catch |err| {
            self.free_space.freePage(new_page) catch {};
            return err;
        };
        const frame = self.buffer_pool.pinNew(self.file_id, new_page) catch |err| { // zeroed
            self.free_space.freePage(new_page) catch {};
            return err;
        };
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        self.writeBlockHeader(data, .{
            .next_block = 0,
            .count = 1,
            .kind = 0,
            .entry_format = want_fmt,
            .payload_size = @truncate(run_bytes),
            .checksum = 0,
        });
        self.writeSlabRun(data, edge_mod.SLAB_RUNS_OFFSET, 0, entries, want_fmt);
        self.buffer_pool.unpin(frame_idx, true);
        self.current_fill_page = new_page;
        return head;
    }

    /// Tombstone slot `slot` on `page` — records the WAL touch FIRST, then the
    /// single directory write (NO error exit after it, so a failed op leaves
    /// the old slot LIVE and the caller's old head valid). Arms the engine
    /// rollback with the pre-tombstone (offset, count) so it can be restored.
    fn tombstoneSlabSlot(self: *AdjStore, page: PageId, slot: u32, offset: u32, entry_count: u32) !void {
        try self.recordTouched(page);
        const frame = try self.buffer_pool.pin(self.file_id, page);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        edge_mod.writeSlabSlot(data, self.tail_reserve, slot, .{ .offset = edge_mod.SLAB_SLOT_TOMBSTONE, .entry_count = 0 });
        self.buffer_pool.unpin(frame_idx, true);
        self.last_slab_tombstone = .{ .page_id = page, .slot = slot, .offset = offset, .entry_count = entry_count };
    }

    /// Graduation: write every entry of `entries` into a fresh LEGACY block
    /// chain (the pre-slab layout). Inserts in REVERSE so head-insert leaves
    /// the run's original order under enumeration. Records each new legacy
    /// page in the touched set (via addEdgeLegacy).
    fn migrateRunToLegacy(self: *AdjStore, entries: []const EdgeEntry) !PageId {
        std.debug.assert(entries.len >= 1);
        var head: PageId = 0;
        var i: usize = entries.len;
        while (i > 0) {
            i -= 1;
            head = try self.addEdgeLegacy(head, entries[i]);
        }
        std.debug.assert(head != 0);
        return head;
    }

    /// Slab write dispatcher (packing on, or a tagged head). A new chain packs
    /// a single-entry run; an existing slab chain grows; an existing legacy
    /// chain keeps growing as legacy (existing block chains are never
    /// retro-packed).
    fn addEdgeSlab(self: *AdjStore, head_page: PageId, entry: EdgeEntry) !PageId {
        if (isSlabHead(head_page)) return self.growSlabChain(head_page, entry);
        if (head_page == 0) {
            const one = [_]EdgeEntry{entry};
            if (try self.appendSlabRun(&one)) |h| return h;
            return self.addEdgeLegacy(0, entry); // page-id overflow fallback
        }
        return self.addEdgeLegacy(head_page, entry);
    }

    /// Append `entry` to an existing slab-packed chain. In-place tail-grow when
    /// the run is at the block frontier and fits; else relocate the whole
    /// (run + entry) to a new slot and tombstone the old slot LAST; else
    /// graduate to a legacy chain and tombstone the old slot LAST.
    fn growSlabChain(self: *AdjStore, head: u64, entry: EdgeEntry) !PageId {
        const page = slabHeadPageId(head);
        const slot = slabHeadSlot(head);
        if (page == 0) return error.DataCorruption; // F1: corrupt head

        const frame = try self.buffer_pool.pin(self.file_id, page);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        const state = self.slabBlockState(data) catch |err| {
            self.buffer_pool.unpin(frame_idx, false);
            return err;
        };
        if (slot >= state.slot_count) {
            self.buffer_pool.unpin(frame_idx, false);
            return error.DataCorruption;
        }
        // GAP-0060: stride at the block's own format (slab-v2 32B or slab-v3 40B).
        const fmt = state.fmt;
        const stride = edge_mod.slabEntrySize(fmt);
        const s = edge_mod.readSlabSlot(data, self.tail_reserve, slot);
        if (s.offset == edge_mod.SLAB_SLOT_TOMBSTONE or s.offset < edge_mod.SLAB_RUNS_OFFSET) {
            self.buffer_pool.unpin(frame_idx, false);
            return error.DataCorruption; // live-head invariant: head → live run
        }
        const run_end: u64 = @as(u64, s.offset) + @as(u64, s.entry_count) * stride;
        const dir_start = edge_mod.slabDirStart(data.len, self.tail_reserve, state.slot_count);
        if (run_end > dir_start) {
            self.buffer_pool.unpin(frame_idx, false);
            return error.DataCorruption;
        }

        // (A) In-place tail-grow: run ends at the block frontier, one more fits,
        // the entry's head fits the block's width, AND we are not obliged to
        // upgrade a legacy v2 run to v3. GAP-0060: a wide-heads writer growing a
        // pre-0060 slab-v2 chain must MIGRATE it to slab-v3 on first append
        // (falls through to the (B) relocation, which changes the head — the
        // caller already stores addEdge's returned head), so a later in-place
        // prop_head widen fits. Fresh stores are all v3, so this never fires.
        const fits_fmt = !(entryNeedsWide(entry) and fmt != edge_mod.ENTRY_FORMAT_SLAB_V3);
        const must_upgrade = self.wide_heads and fmt != edge_mod.ENTRY_FORMAT_SLAB_V3;
        if (fits_fmt and !must_upgrade and run_end == state.next_off and run_end + stride <= dir_start) {
            self.recordTouched(page) catch |err| {
                self.buffer_pool.unpin(frame_idx, false);
                return err;
            };
            edge_mod.encodeEntry(data[@intCast(run_end)..][0..stride], entry, fmt);
            edge_mod.writeSlabSlot(data, self.tail_reserve, slot, .{ .offset = s.offset, .entry_count = s.entry_count + 1 });
            self.bumpSlabPayload(data, @intCast(stride));
            self.buffer_pool.unpin(frame_idx, true);
            return head; // head unchanged
        }

        // (B) Copy the run out (no mutation yet), then relocate or graduate.
        const alloc = self.buffer_pool.allocator;
        const n: usize = s.entry_count;
        const new_run = alloc.alloc(EdgeEntry, n + 1) catch |err| {
            self.buffer_pool.unpin(frame_idx, false);
            return err;
        };
        defer alloc.free(new_run);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const eoff: usize = @as(usize, s.offset) + i * stride;
            new_run[i] = edge_mod.decodeEntry(data[eoff .. eoff + stride], fmt);
        }
        new_run[n] = entry;
        self.buffer_pool.unpin(frame_idx, false);

        // (C) Relocate to a new slot; tombstone the old slot LAST.
        if (try self.appendSlabRun(new_run)) |new_head| {
            try self.tombstoneSlabSlot(page, slot, s.offset, s.entry_count);
            return new_head;
        }
        // (D) Graduate to a legacy chain; tombstone the old slot LAST.
        const legacy_head = try self.migrateRunToLegacy(new_run);
        try self.tombstoneSlabSlot(page, slot, s.offset, s.entry_count);
        return legacy_head;
    }

    /// Remove an edge from a slab-packed chain: swap-with-last within the run,
    /// shrink the slot's entry_count. Head unchanged; returns the DECODED slab
    /// block page for the engine to WAL-image (or null when absent).
    fn removeEdgeSlab(self: *AdjStore, head: u64, edge_id: EdgeId) !?PageId {
        const page = slabHeadPageId(head);
        if (page == 0) return error.DataCorruption;
        const slot = slabHeadSlot(head);
        const frame = try self.buffer_pool.pin(self.file_id, page);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        var dirty = false;
        defer self.buffer_pool.unpin(frame_idx, dirty);
        const data = frame.dataSlice();
        const run = try self.resolveSlabRun(data, slot);
        var i: u32 = 0;
        while (i < run.entry_count) : (i += 1) {
            const e = readSlabRunEntry(data, run.offset, i, run.fmt);
            if (e.edge_id == edge_id) {
                try self.recordTouched(page);
                if (i < run.entry_count - 1) {
                    const last = readSlabRunEntry(data, run.offset, run.entry_count - 1, run.fmt);
                    writeSlabRunEntryInto(data, run.offset, i, last, run.fmt);
                }
                edge_mod.writeSlabSlot(data, self.tail_reserve, slot, .{ .offset = run.offset, .entry_count = run.entry_count - 1 });
                dirty = true;
                return page;
            }
        }
        return null;
    }

    /// Update an edge's prop_head in a slab-packed chain (in-place rewrite).
    /// Head unchanged; returns the DECODED slab block page (or null when absent).
    fn updateEdgePropHeadSlab(self: *AdjStore, head: u64, edge_id: EdgeId, new_prop_head: u64) !?PageId {
        const page = slabHeadPageId(head);
        if (page == 0) return error.DataCorruption;
        const slot = slabHeadSlot(head);
        const frame = try self.buffer_pool.pin(self.file_id, page);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        var dirty = false;
        defer self.buffer_pool.unpin(frame_idx, dirty);
        const data = frame.dataSlice();
        const run = try self.resolveSlabRun(data, slot);
        // GAP-0060: writing a >u32 (slab) head requires a slab-v3 run. A fresh
        // 0060 store's runs are all v3, so this is the in-place path. A PRE-0060
        // (v2) run can't hold the wide head in place — fail LOUDLY rather than
        // truncate; relocating the run to v3 (a head change) is the documented
        // old-store-upgrade follow-up (never reached by fresh ingest).
        if ((new_prop_head >> 32) != 0 and run.fmt != edge_mod.ENTRY_FORMAT_SLAB_V3) {
            return error.WideHeadInLegacySlabRun;
        }
        var i: u32 = 0;
        while (i < run.entry_count) : (i += 1) {
            var e = readSlabRunEntry(data, run.offset, i, run.fmt);
            if (e.edge_id == edge_id) {
                try self.recordTouched(page);
                e.prop_head = new_prop_head;
                writeSlabRunEntryInto(data, run.offset, i, e, run.fmt);
                dirty = true;
                return page;
            }
        }
        return null;
    }

    /// Remove an edge entry from a node's adjacency list.
    /// Scans all blocks for the matching edge_id and removes it by swapping with the last entry.
    ///
    /// Returns the page id of the block that was MUTATED (the swap-with-last +
    /// count-- happen entirely inside the block holding the entry, which may be
    /// any block of the chain, not just the head), or null when the edge was
    /// not found (no page touched). GAP-ENT-0032: the caller must WAL-image
    /// exactly this page — imaging only the chain head lets older WAL images of
    /// a non-head block resurrect a committed delete on crash recovery.
    ///
    /// SONNY-6470: on a store encrypted by graph_storage <= 0.4.11 the last
    /// slot of a full block can hold AES-GCM tag bytes (`edge.legacyTailLoss`).
    /// The swap below moves that entry into slot `i` and the block stops being
    /// full, after which `repairAdjTailEntries` (last slot of full blocks only)
    /// and any scan can no longer recognise it. Run the repair before the first
    /// write. A <= 0.4.11 binary that already removed an edge from such a block
    /// left an unrecoverable entry (docs/operations.md).
    pub fn removeEdge(self: *AdjStore, head_page: PageId, edge_id: EdgeId) !?PageId {
        self.beginOp();
        // A tagged head is a slab-packed chain (regardless of the packing flag):
        // remove in place within the run, return the decoded block page.
        if (isSlabHead(head_page)) return self.removeEdgeSlab(head_page, edge_id);
        if (head_page == 0) return null;

        var current_page = head_page;
        var hops: u32 = 0;
        while (current_page != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            var bh = try self.readBlockHeader(data);

            var i: u16 = 0;
            while (i < bh.count) : (i += 1) {
                const e = self.readEntry(data, i, bh.entry_format);
                if (e.edge_id == edge_id) {
                    // Found it: swap with last entry and decrement count.
                    // Same-block move at the block's own stride, so a v2
                    // mover keeps its public_id.
                    if (i < bh.count - 1) {
                        const last = self.readEntry(data, bh.count - 1, bh.entry_format);
                        self.writeEntry(data, i, last, bh.entry_format);
                    }
                    bh.count -= 1;
                    bh.payload_size = @intCast(@as(u32, bh.count) * edge_mod.entrySize(bh.entry_format));
                    self.writeBlockHeader(data, bh);
                    self.buffer_pool.unpin(frame_idx, true);
                    return current_page;
                }
            }

            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }
        return null;
    }

    pub const AdjEdgeIterator = struct {
        store: *AdjStore,
        current_page: u64,
        current_frame_idx: ?u32 = null,
        current_index: u16 = 0,
        rel_type: ?u32,
        hops: u32 = 0,
        /// Slab mode (GAP adjacency slab packing): non-null when the iterator
        /// was opened on a bit-63-tagged slab head. `current_page` is the slab
        /// block's page id and iteration walks the slot's single contiguous
        /// run instead of a block chain. The pin/unpin discipline is identical
        /// to chain mode (pin held between next() calls; released at
        /// exhaustion or deinit), so every existing consumer — engine expand
        /// iterators, FanInEdgeIterator, index rebuild scans — inherits slab
        /// support with no signature change.
        slab_slot: ?u32 = null,
        /// F1 guard (P2 entry requirement 1): set when `expand` was handed a
        /// slab-tagged head whose page bits decode to 0 (page 0 is reserved) —
        /// a corrupt head. `next()` surfaces DataCorruption instead of the
        /// silently-empty run a page-0 slab mode would otherwise produce
        /// (the slab loop terminates on current_page == 0). Never set for a
        /// live slab head (its page id is ≥ 2).
        slab_corrupt: bool = false,

        pub fn deinit(self: *AdjEdgeIterator) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, false);
                self.current_frame_idx = null;
            }
        }

        pub fn next(self: *AdjEdgeIterator) anyerror!?EdgeEntry {
            if (self.slab_corrupt) return error.DataCorruption;
            if (self.slab_slot) |slot| return self.nextSlab(slot);
            while (self.current_page != 0) {
                if (self.current_frame_idx == null) {
                    if (self.hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
                    const frame = try self.store.buffer_pool.pin(self.store.file_id, self.current_page);
                    self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                    self.hops += 1;
                }

                const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
                const data = frame.dataSlice();
                const bh = try self.store.readBlockHeader(data);

                while (self.current_index < bh.count) {
                    const entry = self.store.readEntry(data, self.current_index, bh.entry_format);
                    self.current_index += 1;

                    if (self.rel_type) |rt| {
                        if (entry.rel_type == rt) {
                            return entry;
                        }
                    } else {
                        return entry;
                    }
                }

                const next_page = bh.next_block;
                self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                self.current_frame_idx = null;
                self.current_page = next_page;
                self.current_index = 0;
            }

            return null;
        }

        /// Slab-mode iteration: one pinned slab block, one contiguous run of
        /// v2 entries. On a parse error the active pin is left for deinit()
        /// to release — the same discipline as the chain path above.
        fn nextSlab(self: *AdjEdgeIterator, slot: u32) anyerror!?EdgeEntry {
            while (self.current_page != 0) {
                if (self.current_frame_idx == null) {
                    const frame = try self.store.buffer_pool.pin(self.store.file_id, self.current_page);
                    self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                }

                const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
                const data = frame.dataSlice();
                const run = try self.store.resolveSlabRun(data, slot);

                while (self.current_index < run.entry_count) {
                    const entry = readSlabRunEntry(data, run.offset, self.current_index, run.fmt);
                    self.current_index += 1;

                    if (self.rel_type) |rt| {
                        if (entry.rel_type == rt) {
                            return entry;
                        }
                    } else {
                        return entry;
                    }
                }

                // Run exhausted — a slab chain is a single run, no next block.
                self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                self.current_frame_idx = null;
                self.current_page = 0;
            }

            return null;
        }
    };

    /// Return an iterator over edge entries starting from head_page (O(1) allocation path).
    /// `head_page` is a chain head REF: a legacy bare block page id (chain
    /// walk, unchanged) or a bit-63-tagged slab (block, slot) ref (single-run
    /// slab read). Read-both is permanent.
    pub fn expand(self: *AdjStore, head_page: PageId, rel_type_filter: ?u32) AdjEdgeIterator {
        if (isSlabHead(head_page)) {
            const page = slabHeadPageId(head_page);
            return .{
                .store = self,
                .current_page = page,
                .slab_slot = slabHeadSlot(head_page),
                .rel_type = rel_type_filter,
                // F1 guard: a tagged head that decodes to page 0 is corruption.
                .slab_corrupt = (page == 0),
            };
        }
        return .{
            .store = self,
            .current_page = head_page,
            .rel_type = rel_type_filter,
        };
    }

    /// Update the prop_head of an existing edge entry in the adjacency chain.
    /// Scans the chain starting at head_page for the given edge_id.
    ///
    /// Returns the PageId of the block that was MUTATED (which may be any
    /// block of the chain, not just the head) so the caller can WAL-image
    /// exactly that page in the same txn as the property write — the same
    /// contract as `removeEdge` (edge-remove non-head imaging fix). Returns
    /// null when the edge was not found (no page touched, nothing to log).
    pub fn updateEdgePropHead(self: *AdjStore, head_page: PageId, edge_id: EdgeId, new_prop_head: u64) !?PageId {
        self.beginOp();
        if (isSlabHead(head_page)) return self.updateEdgePropHeadSlab(head_page, edge_id, new_prop_head);
        if (head_page == 0) return null;

        var current_page = head_page;
        var hops: u32 = 0;
        while (current_page != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const bh = try self.readBlockHeader(data);

            var i: u16 = 0;
            while (i < bh.count) : (i += 1) {
                const e = self.readEntry(data, i, bh.entry_format);
                if (e.edge_id == edge_id) {
                    // GAP-0060: a >u32 (slab) head only fits a v3 record. In a
                    // fresh wide-heads store every chain block is v3; a legacy
                    // v1/v2 block (old store) cannot hold it in place — refuse
                    // LOUDLY rather than let `encodeEntry`'s assert be stripped
                    // in ReleaseFast and silently truncate the head.
                    if ((new_prop_head >> 32) != 0 and bh.entry_format != edge_mod.ENTRY_FORMAT_V3) {
                        self.buffer_pool.unpin(frame_idx, false);
                        return error.WideHeadInLegacyChainBlock;
                    }
                    // In-place rewrite at the block's own format; public_id
                    // is preserved (v2/v3) or remains absent on disk (v1).
                    self.writeEntry(data, i, .{
                        .neighbor = e.neighbor,
                        .edge_id = e.edge_id,
                        .rel_type = e.rel_type,
                        .prop_head = new_prop_head,
                        .public_id = e.public_id,
                    }, bh.entry_format);
                    self.buffer_pool.unpin(frame_idx, true);
                    return current_page;
                }
            }

            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }
        return null;
    }

    /// Count edges in the adjacency list (legacy chain walk or slab run).
    pub fn edgeCount(self: *AdjStore, head_page: PageId) !u64 {
        if (head_page == 0) return 0;

        if (isSlabHead(head_page)) {
            // F1 guard: a tagged head that decodes to reserved page 0 is
            // corruption — reject before pinning page 0.
            if (slabHeadPageId(head_page) == 0) return error.DataCorruption;
            const frame = try self.buffer_pool.pin(self.file_id, slabHeadPageId(head_page));
            const frame_idx = self.buffer_pool.frameIndex(frame);
            defer self.buffer_pool.unpin(frame_idx, false);
            const run = try self.resolveSlabRun(frame.dataSlice(), slabHeadSlot(head_page));
            return run.entry_count;
        }

        var count: u64 = 0;
        var current_page = head_page;
        var hops: u32 = 0;
        while (current_page != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const bh = try self.readBlockHeader(data);

            count += bh.count;
            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }

        return count;
    }

    /// SONNY-6461: where one entry of a chain lives.
    pub const EntryLocation = struct {
        page: PageId,
        /// Slot within a chain block, or entry index within a slab run.
        slot: u32,
        /// The block's entry format (v1/v2/v3, or slab / slab-v3).
        entry_format: u8,
        entry: EdgeEntry,
        /// Set when the entry is the last slot of a full chain block whose
        /// bytes `lost_from..` reached the legacy tag tail (see
        /// `edge.legacyTailLoss`). Never set for slab runs.
        tail_lost_from: ?u32,
    };

    /// SONNY-6461: find the entry with `edge_id` in the chain at `head`
    /// (legacy chain or slab run). Read-only.
    pub fn locateEntry(self: *AdjStore, head: PageId, edge_id: EdgeId) !?EntryLocation {
        if (head == 0) return null;
        if (isSlabHead(head)) {
            const page = slabHeadPageId(head);
            if (page == 0) return error.DataCorruption;
            const frame = try self.buffer_pool.pin(self.file_id, page);
            defer self.buffer_pool.unpin(self.buffer_pool.frameIndex(frame), false);
            const data = frame.dataSlice();
            const run = try self.resolveSlabRun(data, slabHeadSlot(head));
            var i: u32 = 0;
            while (i < run.entry_count) : (i += 1) {
                const e = readSlabRunEntry(data, run.offset, i, run.fmt);
                if (e.edge_id == edge_id) return .{ .page = page, .slot = i, .entry_format = run.fmt, .entry = e, .tail_lost_from = null };
            }
            return null;
        }
        var current_page = head;
        var hops: u32 = 0;
        while (current_page != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const bh = self.readBlockHeader(data) catch |err| {
                self.buffer_pool.unpin(frame_idx, false);
                return err;
            };
            var i: u16 = 0;
            while (i < bh.count) : (i += 1) {
                const e = self.readEntry(data, i, bh.entry_format);
                if (e.edge_id == edge_id) {
                    self.buffer_pool.unpin(frame_idx, false);
                    return .{ .page = current_page, .slot = i, .entry_format = bh.entry_format, .entry = e, .tail_lost_from = self.tailLostFrom(bh, i) };
                }
            }
            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }
        return null;
    }

    /// SONNY-6529: call `f(ctx, edge_id)` for every entry stored on page
    /// `page_id`, whatever chain(s) it belongs to: each of the `count`
    /// entries of a chain block (v1/v2/v3), or every entry of every live run
    /// of a slab block. Read-only. An unallocated page yields nothing. A page
    /// whose block cannot be parsed fails with `error.NotAdjPage` (the
    /// caller decides; the tail reconcile then rebuilds). Used by the WAL
    /// tail reconcile to find the owners of an adjacency page that was
    /// imaged without its owner's node page (an in-place prop_head rewrite).
    pub fn forEachEdgeIdOnPage(
        self: *AdjStore,
        page_id: PageId,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), edge_id: EdgeId) anyerror!void,
    ) !void {
        if (page_id == 0 or !self.free_space.isAllocated(page_id)) return;
        const frame = try self.buffer_pool.pin(self.file_id, page_id);
        defer self.buffer_pool.unpin(self.buffer_pool.frameIndex(frame), false);
        const data = frame.dataSlice();
        const off = self.blockHeaderOffset();
        const bh: EdgeBlockHeader = @bitCast(data[off..][0..BLOCK_HEADER_SIZE].*);
        switch (bh.entry_format) {
            edge_mod.ENTRY_FORMAT_V1, edge_mod.ENTRY_FORMAT_V2, edge_mod.ENTRY_FORMAT_V3 => {
                const checked = self.readBlockHeader(data) catch return error.NotAdjPage;
                var i: u16 = 0;
                while (i < checked.count) : (i += 1) {
                    try f(ctx, self.readEntry(data, i, checked.entry_format).edge_id);
                }
            },
            edge_mod.ENTRY_FORMAT_SLAB, edge_mod.ENTRY_FORMAT_SLAB_V3 => {
                const sb = self.readSlabBlockHeader(data) catch return error.NotAdjPage;
                var slot: u32 = 0;
                while (slot < sb.count) : (slot += 1) {
                    const s = edge_mod.readSlabSlot(data, self.tail_reserve, slot);
                    if (s.offset == edge_mod.SLAB_SLOT_TOMBSTONE) continue;
                    const run = self.resolveSlabRun(data, slot) catch return error.NotAdjPage;
                    var i: u32 = 0;
                    while (i < run.entry_count) : (i += 1) {
                        try f(ctx, readSlabRunEntry(data, run.offset, i, run.fmt).edge_id);
                    }
                }
            },
            else => return error.NotAdjPage,
        }
    }

    /// SONNY-6461: append to `out` every entry of the chain at `head` that
    /// sits in a legacy-tail slot (the last slot of a full chain block of a
    /// format that reaches the tail at this page size). Slab runs never do.
    pub fn collectTailEntries(self: *AdjStore, head: PageId, allocator: Allocator, out: *std.ArrayList(EntryLocation)) !void {
        if (head == 0 or isSlabHead(head)) return;
        var current_page = head;
        var hops: u32 = 0;
        while (current_page != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const bh = self.readBlockHeader(data) catch |err| {
                self.buffer_pool.unpin(frame_idx, false);
                return err;
            };
            if (edge_mod.legacyTailLoss(self.page_size, bh.entry_format)) |loss| {
                if (bh.count == loss.slot + 1) {
                    const slot: u16 = @intCast(loss.slot);
                    out.append(allocator, .{
                        .page = current_page,
                        .slot = slot,
                        .entry_format = bh.entry_format,
                        .entry = self.readEntry(data, slot, bh.entry_format),
                        .tail_lost_from = loss.lost_from,
                    }) catch |err| {
                        self.buffer_pool.unpin(frame_idx, false);
                        return err;
                    };
                }
            }
            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }
    }

    /// SONNY-6461: overwrite the chain-block entry at (`page`, `slot`) with
    /// `entry`, in the block's own format. Refuses (DataCorruption) unless the
    /// block still has that format, the slot is live and the entry there still
    /// carries `entry.edge_id` and `entry.neighbor`. The caller WAL-images
    /// `page` under its txn (it is also recorded in `touchedPages`).
    pub fn rewriteChainEntry(self: *AdjStore, page: PageId, slot: u32, entry_format: u8, entry: EdgeEntry) !void {
        self.beginOp();
        const frame = try self.buffer_pool.pin(self.file_id, page);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        var dirty = false;
        defer self.buffer_pool.unpin(frame_idx, dirty);
        const data = frame.dataSlice();
        const bh = try self.readBlockHeader(data);
        if (bh.entry_format != entry_format or slot >= bh.count) return error.DataCorruption;
        const cur = self.readEntry(data, @intCast(slot), entry_format);
        if (cur.edge_id != entry.edge_id or cur.neighbor != entry.neighbor) return error.DataCorruption;
        if (!edge_mod.formatHasWideHead(entry_format) and (entry.prop_head >> 32) != 0) return error.WideHeadInLegacyChainBlock;
        try self.recordTouched(page);
        self.writeEntry(data, @intCast(slot), entry, entry_format);
        dirty = true;
    }

    fn tailLostFrom(self: *const AdjStore, bh: EdgeBlockHeader, slot: u16) ?u32 {
        const loss = edge_mod.legacyTailLoss(self.page_size, bh.entry_format) orelse return null;
        if (bh.count != loss.slot + 1 or slot != loss.slot) return null;
        return loss.lost_from;
    }

    // Internal helpers

    fn blockHeaderOffset(_: *const AdjStore) u32 {
        return PAGE_HEADER_SIZE;
    }

    fn entryOffset(self: *const AdjStore, slot: u16, entry_format: u8) u32 {
        return self.blockHeaderOffset() + BLOCK_HEADER_SIZE + @as(u32, slot) * edge_mod.entrySize(entry_format);
    }

    fn readBlockHeader(self: *const AdjStore, data: []u8) error{DataCorruption}!EdgeBlockHeader {
        const off = self.blockHeaderOffset();
        const bytes = data[off..][0..BLOCK_HEADER_SIZE];
        const bh: EdgeBlockHeader = @bitCast(bytes.*);
        // Unknown entry formats are corruption — reject loudly, never parse
        // entries at a guessed stride (GAP-ENT-0024 unguarded-consumer hazard).
        // GAP-0060: v3 (40 B, u64 head) is now a valid CHAIN format; slab
        // formats never reach here (they come via readSlabBlockHeader).
        if (bh.entry_format != edge_mod.ENTRY_FORMAT_V1 and
            bh.entry_format != edge_mod.ENTRY_FORMAT_V2 and
            bh.entry_format != edge_mod.ENTRY_FORMAT_V3) return error.DataCorruption;
        if (bh.count > @as(u16, @intCast(self.capacityFor(bh.entry_format)))) return error.DataCorruption;
        return bh;
    }

    fn writeBlockHeader(self: *const AdjStore, data: []u8, bh: EdgeBlockHeader) void {
        const off = self.blockHeaderOffset();
        const bytes: *const [BLOCK_HEADER_SIZE]u8 = @ptrCast(&bh);
        @memcpy(data[off..][0..BLOCK_HEADER_SIZE], bytes);
    }

    /// Parse one entry at the given chain-block format (v1/v2/v3) via the
    /// versioned wire decoder. A v1 record's `public_id` surfaces 0; a v1/v2
    /// record's `prop_head` high bits surface 0 (a legacy u32 head, losslessly
    /// widened). GAP-0060: v3 records carry the full u64 `prop_head`.
    fn readEntry(self: *const AdjStore, data: []u8, slot: u16, entry_format: u8) EdgeEntry {
        const off = self.entryOffset(slot, entry_format);
        const size = edge_mod.entrySize(entry_format);
        return edge_mod.decodeEntry(data[off..][0..size], entry_format);
    }

    /// Write one entry at the given chain-block format. v1 drops `public_id`;
    /// v1/v2 drop the high 32 bits of `prop_head` (the no-truncate rule in
    /// `encodeEntry` asserts they are zero — a slab/high head must be routed to
    /// a v3 block, exactly as a real public_id is routed to a v2 block).
    fn writeEntry(self: *const AdjStore, data: []u8, slot: u16, entry: EdgeEntry, entry_format: u8) void {
        const off = self.entryOffset(slot, entry_format);
        const size = edge_mod.entrySize(entry_format);
        edge_mod.encodeEntry(data[off..][0..size], entry, entry_format);
    }

    // Slab helpers (GAP adjacency slab packing — layout spec in edge.zig)

    /// Parse + validate the header of a SLAB block reached via a tagged head.
    /// Rejects loudly: wrong format byte (a tagged head must land on a slab
    /// block), a chained slab block (slab blocks are never linked), or a slot
    /// directory that cannot fit the page.
    fn readSlabBlockHeader(self: *const AdjStore, data: []const u8) error{DataCorruption}!EdgeBlockHeader {
        const off = self.blockHeaderOffset();
        const bytes = data[off..][0..BLOCK_HEADER_SIZE];
        const bh: EdgeBlockHeader = @bitCast(bytes.*);
        // GAP-0060: a tagged head lands on a slab-v2 OR slab-v3 block.
        if (bh.entry_format != edge_mod.ENTRY_FORMAT_SLAB and
            bh.entry_format != edge_mod.ENTRY_FORMAT_SLAB_V3) return error.DataCorruption;
        if (bh.next_block != 0) return error.DataCorruption;
        const dir_bytes = @as(u64, bh.count) * edge_mod.SLAB_DIR_ENTRY_SIZE;
        if (edge_mod.SLAB_RUNS_OFFSET + dir_bytes + self.tail_reserve > data.len) return error.DataCorruption;
        return bh;
    }

    /// A validated slab run plus the block's entry `fmt` (its stride), so
    /// callers read/write entries at the right width (v2 32B or v3 40B).
    const ResolvedRun = struct { offset: u32, entry_count: u32, fmt: u8 };

    /// Resolve a slab (block, slot) to its validated run. The live-head
    /// invariant makes a tombstoned or out-of-range slot reached via a stored
    /// head ref corruption — never silently empty.
    fn resolveSlabRun(self: *const AdjStore, data: []const u8, slot: u32) error{DataCorruption}!ResolvedRun {
        const bh = try self.readSlabBlockHeader(data);
        if (slot >= bh.count) return error.DataCorruption;
        const run = edge_mod.readSlabSlot(data, self.tail_reserve, slot);
        if (run.offset == edge_mod.SLAB_SLOT_TOMBSTONE) return error.DataCorruption;
        if (run.offset < edge_mod.SLAB_RUNS_OFFSET) return error.DataCorruption;
        const run_end = @as(u64, run.offset) + @as(u64, run.entry_count) * edge_mod.slabEntrySize(bh.entry_format);
        if (run_end > edge_mod.slabDirStart(data.len, self.tail_reserve, bh.count)) return error.DataCorruption;
        return .{ .offset = run.offset, .entry_count = run.entry_count, .fmt = bh.entry_format };
    }

    /// Read entry `idx` of a validated slab run at the block's `fmt` stride
    /// (slab-v2 32B or slab-v3 40B). GAP-0060.
    fn readSlabRunEntry(data: []const u8, run_offset: u32, idx: u32, fmt: u8) EdgeEntry {
        const size = edge_mod.slabEntrySize(fmt);
        const off = @as(usize, run_offset) + @as(usize, idx) * size;
        return edge_mod.decodeEntry(data[off .. off + size], fmt);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;

const TestEnv = struct {
    pool: BufferPool,
    fsm: FreeSpaceManager,
    tmp_dir: testing.TmpDir,
    adj_file: std.Io.File,
    adj_pager: Pager,

    fn init() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const adj_file = tmp_dir.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "adj_out.store", .{ .read = true, .truncate = true }) catch unreachable;
        var pool = try BufferPool.init(testing.allocator, 4096, 32);
        const fsm = try FreeSpaceManager.init(testing.allocator, &pool, .adj_out);

        return .{
            .pool = pool,
            .fsm = fsm,
            .tmp_dir = tmp_dir,
            .adj_file = adj_file,
            .adj_pager = Pager.init(adj_file, 4096),
        };
    }

    fn fixup(self: *TestEnv) void {
        self.pool.registerPager(.adj_out, &self.adj_pager);
        self.fsm.buffer_pool = &self.pool;
    }

    fn deinit(self: *TestEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.adj_file.close(std.Io.Threaded.global_single_threaded.io());
        self.tmp_dir.cleanup();
    }
};

fn makeEdge(neighbor: u64, edge_id: u64, rel_type: u32) EdgeEntry {
    return .{
        .neighbor = neighbor,
        .edge_id = edge_id,
        .rel_type = rel_type,
        .prop_head = 0,
        // Test helper models a LEGACY (no inline id) edge; v2-entry tests
        // construct their entries explicitly.
        .public_id = 0,
    };
}

test "addEdge to empty list returns new head" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const head = try store.addEdge(0, makeEdge(10, 1, 5));
    try testing.expect(head != 0);
}

test "expand returns added edges" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 5));
    head = try store.addEdge(head, makeEdge(20, 2, 5));

    var iter = store.expand(head, null);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "multiple edges in same block" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 1));
    head = try store.addEdge(head, makeEdge(20, 2, 2));
    head = try store.addEdge(head, makeEdge(30, 3, 3));

    const count = try store.edgeCount(head);
    try testing.expectEqual(@as(u64, 3), count);

    var iter = store.expand(head, null);
    defer iter.deinit();

    var edges_found: usize = 0;
    while (try iter.next()) |e| {
        if (edges_found == 0) try testing.expectEqual(@as(u64, 10), e.neighbor);
        if (edges_found == 1) try testing.expectEqual(@as(u64, 20), e.neighbor);
        if (edges_found == 2) try testing.expectEqual(@as(u64, 30), e.neighbor);
        edges_found += 1;
    }

    try testing.expectEqual(@as(usize, 3), edges_found);
}

test "overflow to second block when first is full" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const epb = store.writer_entries_per_block;

    var head: PageId = 0;
    // Fill first block completely
    var i: u32 = 0;
    while (i < epb) : (i += 1) {
        head = try store.addEdge(head, makeEdge(i, i + 1, 1));
    }

    // One more should overflow
    head = try store.addEdge(head, makeEdge(999, 9999, 1));

    const count = try store.edgeCount(head);
    try testing.expectEqual(@as(u64, epb + 1), count);

    var iter = store.expand(head, null);
    defer iter.deinit();

    var edges_len: usize = 0;
    var first_neighbor: u64 = 0;
    while (try iter.next()) |e| {
        if (edges_len == 0) first_neighbor = e.neighbor;
        edges_len += 1;
    }
    try testing.expectEqual(@as(usize, @intCast(epb + 1)), edges_len);

    // With head-insert, the overflow entry is in the new head block,
    // so expand reads it first.
    try testing.expectEqual(@as(u64, 999), first_neighbor);
}

test "removeEdge removes correct entry" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 5));
    head = try store.addEdge(head, makeEdge(20, 2, 5));
    head = try store.addEdge(head, makeEdge(30, 3, 5));

    const mutated = try store.removeEdge(head, 2);
    try testing.expectEqual(@as(?PageId, head), mutated);

    const count = try store.edgeCount(head);
    try testing.expectEqual(@as(u64, 2), count);

    var iter = store.expand(head, null);
    defer iter.deinit();

    // Edge with edge_id=2 should be gone
    while (try iter.next()) |e| {
        try testing.expect(e.edge_id != 2);
    }
}

test "rel_type_filter in expand" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 1));
    head = try store.addEdge(head, makeEdge(20, 2, 2));
    head = try store.addEdge(head, makeEdge(30, 3, 1));
    head = try store.addEdge(head, makeEdge(40, 4, 3));

    var filter1_iter = store.expand(head, 1);
    defer filter1_iter.deinit();
    var filter1_len: usize = 0;
    while (try filter1_iter.next()) |_| filter1_len += 1;
    try testing.expectEqual(@as(usize, 2), filter1_len);

    var filter2_iter = store.expand(head, 2);
    defer filter2_iter.deinit();
    var filter2_len: usize = 0;
    while (try filter2_iter.next()) |_| filter2_len += 1;
    try testing.expectEqual(@as(usize, 1), filter2_len);

    var filter9_iter = store.expand(head, 9);
    defer filter9_iter.deinit();
    var filter9_len: usize = 0;
    while (try filter9_iter.next()) |_| filter9_len += 1;
    try testing.expectEqual(@as(usize, 0), filter9_len);
}

test "updateEdgePropHead updates matching edge" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 5));
    head = try store.addEdge(head, makeEdge(20, 2, 5));
    head = try store.addEdge(head, makeEdge(30, 3, 5));

    // Update prop_head for edge_id=2 — the mutated page is the (single)
    // head block, and the caller gets it back for WAL imaging.
    const mutated = try store.updateEdgePropHead(head, 2, 42);
    try testing.expectEqual(@as(?PageId, head), mutated);

    // Verify via expand
    var iter = store.expand(head, null);
    defer iter.deinit();

    while (try iter.next()) |e| {
        if (e.edge_id == 2) {
            try testing.expectEqual(@as(u32, 42), e.prop_head);
        } else {
            try testing.expectEqual(@as(u32, 0), e.prop_head);
        }
    }
}

test "updateEdgePropHead returns null for missing edge" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 5));

    const mutated = try store.updateEdgePropHead(head, 999, 42);
    try testing.expectEqual(@as(?PageId, null), mutated);
}

test "updateEdgePropHead on empty list returns null" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const mutated = try store.updateEdgePropHead(0, 1, 42);
    try testing.expectEqual(@as(?PageId, null), mutated);
}

test "edgeCount on empty list returns 0" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const count = try store.edgeCount(0);
    try testing.expectEqual(@as(u64, 0), count);
}

// ============================================================================
// SEC-0042: chain-cycle / max-hop guard regression tests
// ============================================================================

/// Corrupt a block so its next_block points back to itself, creating a
/// self-loop. Caller must already hold no pins on the page.
fn makeSelfLoop(store: *AdjStore, page_id: PageId) !void {
    const frame = try store.buffer_pool.pin(store.file_id, page_id);
    const frame_idx = store.buffer_pool.frameIndex(frame);
    const data = frame.dataSlice();
    var bh = try store.readBlockHeader(data);
    bh.next_block = page_id; // point to itself
    store.writeBlockHeader(data, bh);
    store.buffer_pool.unpin(frame_idx, true);
}

test "SEC-0042: removeEdge detects circular chain" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const head = try store.addEdge(0, makeEdge(10, 1, 5));
    try makeSelfLoop(&store, head);

    // Edge ID 999 does not exist; traversal must trip the hop guard.
    try testing.expectError(error.CircularChainDetected, store.removeEdge(head, 999));
}

test "SEC-0042: AdjEdgeIterator.next detects circular chain" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const head = try store.addEdge(0, makeEdge(10, 1, 5));
    try makeSelfLoop(&store, head);

    var iter = store.expand(head, null);
    defer iter.deinit();

    // Drain until the hop guard fires; each iteration revisits the self-loop
    // block and increments the hop counter. The guard fires after MAX_CHAIN_HOPS.
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

test "SEC-0042: updateEdgePropHead detects circular chain" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const head = try store.addEdge(0, makeEdge(10, 1, 5));
    try makeSelfLoop(&store, head);

    // Edge ID 999 does not exist; traversal must trip the hop guard.
    try testing.expectError(error.CircularChainDetected, store.updateEdgePropHead(head, 999, 42));
}

test "SEC-0042: edgeCount detects circular chain" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const head = try store.addEdge(0, makeEdge(10, 1, 5));
    try makeSelfLoop(&store, head);

    try testing.expectError(error.CircularChainDetected, store.edgeCount(head));
}

// ============================================================================
// GAP adjacency slab packing — P1 slab READ path unit tests.
// ============================================================================

test "slab head refs: bit-63 tag encode/decode round-trip; legacy heads untagged" {
    // Legacy bare page ids (incl. 0 = empty chain) are never slab heads.
    try testing.expect(!isSlabHead(0));
    try testing.expect(!isSlabHead(1));
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

/// Hand-build one SLAB block page: EdgeBlockHeader (entry_format = SLAB,
/// count = number of slots), v2-strided runs packed forward from
/// SLAB_RUNS_OFFSET, slot directory grown backward from the page tail.
/// `runs[i].len == 0` writes slot i as a TOMBSTONE. Raw bytes, deliberately
/// not the (future P2) production writer — the on-disk-format oracle.
fn writeRawSlabBlock(store: *AdjStore, runs: []const []const EdgeEntry) !PageId {
    const page_id = try store.free_space.allocPage();
    const frame = try store.buffer_pool.pinNew(store.file_id, page_id);
    const frame_idx = store.buffer_pool.frameIndex(frame);
    const data = frame.dataSlice();

    const off: usize = PAGE_HEADER_SIZE;
    std.mem.writeInt(u64, data[off..][0..8], 0, .little); // next_block: never chained
    std.mem.writeInt(u16, data[off + 8 ..][0..2], @intCast(runs.len), .little); // count = slots
    data[off + 10] = 0; // kind
    data[off + 11] = edge_mod.ENTRY_FORMAT_SLAB;

    var run_off: u32 = edge_mod.SLAB_RUNS_OFFSET;
    for (runs, 0..) |run, i| {
        if (run.len == 0) {
            edge_mod.writeSlabSlot(data, 0, @intCast(i), .{ .offset = edge_mod.SLAB_SLOT_TOMBSTONE, .entry_count = 0 });
            continue;
        }
        edge_mod.writeSlabSlot(data, 0, @intCast(i), .{ .offset = run_off, .entry_count = @intCast(run.len) });
        for (run) |e| {
            edge_mod.encodeEntry(data[run_off..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
            run_off += edge_mod.ENTRY_SIZE_V2;
        }
    }
    std.mem.writeInt(u16, data[off + 12 ..][0..2], @intCast(run_off - edge_mod.SLAB_RUNS_OFFSET), .little); // payload_size
    std.mem.writeInt(u16, data[off + 14 ..][0..2], 0, .little); // checksum (unused)

    store.buffer_pool.unpin(frame_idx, true);
    return page_id;
}

fn v2Edge(neighbor: u64, edge_id: u64, rel_type: u32, public_id: u64) EdgeEntry {
    return .{ .neighbor = neighbor, .edge_id = edge_id, .rel_type = rel_type, .prop_head = 0, .public_id = public_id };
}

test "slab read path: each tagged (block, slot) head enumerates exactly its run" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const run_a = [_]EdgeEntry{v2Edge(10, 101, 5, 0xA1)};
    const run_b = [_]EdgeEntry{ v2Edge(20, 201, 5, 0xB1), v2Edge(30, 202, 6, 0xB2) };
    const run_c = [_]EdgeEntry{ v2Edge(40, 301, 7, 0xC1), v2Edge(50, 302, 7, 0xC2), v2Edge(60, 303, 8, 0xC3) };
    const page = try writeRawSlabBlock(&store, &.{ &run_a, &run_b, &run_c });

    // Chain A: single entry.
    {
        const head = encodeSlabHead(page, 0);
        try testing.expectEqual(@as(u64, 1), try store.edgeCount(head));
        var it = store.expand(head, null);
        defer it.deinit();
        const e = (try it.next()).?;
        try testing.expectEqual(@as(u64, 10), e.neighbor);
        try testing.expectEqual(@as(u64, 101), e.edge_id);
        try testing.expectEqual(@as(u64, 0xA1), e.public_id);
        try testing.expectEqual(@as(?EdgeEntry, null), try it.next());
    }
    // Chain B: two entries, exact order, exact fields.
    {
        const head = encodeSlabHead(page, 1);
        try testing.expectEqual(@as(u64, 2), try store.edgeCount(head));
        var it = store.expand(head, null);
        defer it.deinit();
        const e0 = (try it.next()).?;
        try testing.expectEqual(@as(u64, 201), e0.edge_id);
        try testing.expectEqual(@as(u64, 0xB1), e0.public_id);
        const e1 = (try it.next()).?;
        try testing.expectEqual(@as(u64, 202), e1.edge_id);
        try testing.expectEqual(@as(u32, 6), e1.rel_type);
        try testing.expectEqual(@as(?EdgeEntry, null), try it.next());
    }
    // Chain C via rel_type filter: only the rel 7 pair surfaces.
    {
        const head = encodeSlabHead(page, 2);
        try testing.expectEqual(@as(u64, 3), try store.edgeCount(head));
        var it = store.expand(head, 7);
        defer it.deinit();
        try testing.expectEqual(@as(u64, 301), ((try it.next()).?).edge_id);
        try testing.expectEqual(@as(u64, 302), ((try it.next()).?).edge_id);
        try testing.expectEqual(@as(?EdgeEntry, null), try it.next());
    }
}

test "slab + legacy chains coexist in one store; a chain linked INTO a slab block is corruption" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    // Legacy chain through the production writer.
    var legacy_head: PageId = 0;
    legacy_head = try store.addEdge(legacy_head, makeEdge(70, 401, 5));
    legacy_head = try store.addEdge(legacy_head, makeEdge(80, 402, 5));

    // Slab block beside it.
    const run = [_]EdgeEntry{v2Edge(90, 501, 5, 0xD1)};
    const slab_page = try writeRawSlabBlock(&store, &.{&run});

    // Both heads read correctly through the same store.
    try testing.expectEqual(@as(u64, 2), try store.edgeCount(legacy_head));
    try testing.expectEqual(@as(u64, 1), try store.edgeCount(encodeSlabHead(slab_page, 0)));

    // An UNTAGGED head pointing at a slab block is a chain walk into a slab
    // block — rejected as corruption, never parsed at a guessed stride.
    var it = store.expand(slab_page, null);
    defer it.deinit();
    try testing.expectError(error.DataCorruption, it.next());
}

test "slab read path rejects tombstoned, out-of-range, and out-of-bounds slots as corruption" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const run = [_]EdgeEntry{v2Edge(10, 601, 5, 0xE1)};
    const tomb = [_]EdgeEntry{}; // empty run => tombstone slot
    const page = try writeRawSlabBlock(&store, &.{ &run, &tomb });

    // Tombstoned slot behind a stored head ref violates the live-head
    // invariant — corruption, never silently empty.
    {
        var it = store.expand(encodeSlabHead(page, 1), null);
        defer it.deinit();
        try testing.expectError(error.DataCorruption, it.next());
        try testing.expectError(error.DataCorruption, store.edgeCount(encodeSlabHead(page, 1)));
    }
    // Slot index beyond the directory.
    {
        var it = store.expand(encodeSlabHead(page, 9), null);
        defer it.deinit();
        try testing.expectError(error.DataCorruption, it.next());
    }
    // Corrupt slot 0's run bounds so it overruns the slot directory.
    {
        const frame = try store.buffer_pool.pin(store.file_id, page);
        const idx = store.buffer_pool.frameIndex(frame);
        edge_mod.writeSlabSlot(frame.dataSlice(), 0, 0, .{ .offset = edge_mod.SLAB_RUNS_OFFSET, .entry_count = 4000 });
        store.buffer_pool.unpin(idx, true);

        var it = store.expand(encodeSlabHead(page, 0), null);
        defer it.deinit();
        try testing.expectError(error.DataCorruption, it.next());
    }
}

test "P2: a tagged slab head is always writable (append/remove/update) even with packing off" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    // Packing OFF: a NEW chain would be legacy, but a tagged head is a slab
    // chain regardless (bit-63 tag discipline) — the writer must service it.
    try testing.expect(!store.slab_packing);

    const run = [_]EdgeEntry{v2Edge(10, 701, 5, 0xF1)};
    const page = try writeRawSlabBlock(&store, &.{&run});
    const head = encodeSlabHead(page, 0);

    // Append grows the slab run in place (single-run tail).
    const grown = try store.addEdge(head, v2Edge(20, 702, 5, 0xF2));
    try testing.expectEqual(head, grown); // tail-grow keeps the head
    try testing.expectEqual(@as(u64, 2), try store.edgeCount(grown));
    // Update + remove operate within the run.
    try testing.expectEqual(@as(?PageId, page), try store.updateEdgePropHead(grown, 702, 9));
    try testing.expectEqual(@as(?PageId, page), try store.removeEdge(grown, 701));
    try testing.expectEqual(@as(u64, 1), try store.edgeCount(grown));
}

// ============================================================================
// GAP adjacency slab packing — P2 ENTRY REQUIREMENT 1 (F1 guard).
// A tagged slab head whose page bits decode to 0 (page 0 is reserved) is a
// CORRUPT head. It must fail DataCorruption on both read entry points, never
// silently enumerate an empty run (that would violate the live-head invariant
// — a stored head must always reference a live run).
// ============================================================================

test "F1: slab head whose page bits decode to page 0 is corruption, never silently empty" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    // A slab-tagged head whose 39-bit page field is 0. page 0 is reserved, so
    // this can only arise from corruption, never from a live slab write.
    const bad = encodeSlabHead(0, 5);
    try testing.expect(isSlabHead(bad));
    try testing.expectEqual(@as(PageId, 0), slabHeadPageId(bad));

    // expand() cannot return an error (it returns a plain iterator), so the
    // corruption must surface on the FIRST next() — not as a silent empty run.
    var it = store.expand(bad, null);
    defer it.deinit();
    try testing.expectError(error.DataCorruption, it.next());

    // edgeCount() rejects it up front rather than pinning the reserved page 0.
    try testing.expectError(error.DataCorruption, store.edgeCount(bad));
}

// ============================================================================
// GAP adjacency slab packing — P2 ENTRY REQUIREMENT 4 (WAL-imaging plumbing +
// fallback encoder). The engine must WAL-image the exact page(s) an addEdge
// mutated — not the returned head, which becomes a tagged (block, slot) ref
// once slab writes land. AdjStore exposes `touchedPages()` (the prop-store P4
// discipline). With slab packing OFF (default), a legacy addEdge touches
// exactly the block it mutated, which always equals the returned head — so
// the engine's imaging is byte-identical whether it logs the head or the
// touched set.
// ============================================================================

test "P2 plumbing: legacy addEdge records exactly the mutated page (== returned head)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    // Default: slab packing OFF — legacy block chains, byte-identical to pre-P2.
    try testing.expect(!store.slab_packing);

    // New chain: touched == [new head block].
    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 5));
    try testing.expectEqualSlices(PageId, &.{head}, store.touchedPages());

    // In-place append to the same block: head unchanged, touched == [head].
    const prev = head;
    head = try store.addEdge(head, makeEdge(20, 2, 5));
    try testing.expectEqual(prev, head);
    try testing.expectEqualSlices(PageId, &.{head}, store.touchedPages());

    // Overflow into a fresh block: touched == [new head], distinct from old.
    const epb = store.writer_entries_per_block;
    var i: u32 = 2;
    while (i < epb) : (i += 1) head = try store.addEdge(head, makeEdge(i, i + 1, 5));
    const before_overflow = head;
    head = try store.addEdge(head, makeEdge(999, 9999, 5));
    try testing.expect(head != before_overflow);
    try testing.expectEqualSlices(PageId, &.{head}, store.touchedPages());
}

test "P2: tryEncodeSlabHead falls back (null) for a page id that overflows the 39-bit field" {
    // 2^39 is the first page id that cannot be addressed by a slab head.
    try testing.expectEqual(@as(?u64, null), tryEncodeSlabHead(@as(u64, 1) << 39, 0));
    const ok = tryEncodeSlabHead((@as(u64, 1) << 39) - 1, 3).?;
    try testing.expect(isSlabHead(ok));
    try testing.expectEqual((@as(u64, 1) << 39) - 1, slabHeadPageId(ok));
    try testing.expectEqual(@as(u32, 3), slabHeadSlot(ok));
}

// ============================================================================
// GAP adjacency slab packing — P2 slab WRITE path (writer contract tests).
// ============================================================================

/// Drain an iterator into a caller list of neighbors (order preserved).
fn collectNeighbors(store: *AdjStore, head: PageId, out: *std.ArrayList(u64)) !void {
    var it = store.expand(head, null);
    defer it.deinit();
    while (try it.next()) |e| try out.append(testing.allocator, e.neighbor);
}

/// The first edge of a chain (helper: expand returns an iterator by value, so
/// its `next()` needs a bound mutable var).
fn firstEdge(store: *AdjStore, head: PageId) !EdgeEntry {
    var it = store.expand(head, null);
    defer it.deinit();
    return (try it.next()).?;
}

test "P2 writer: a NEW chain slab-packs (tagged head, single-block, exact read-back)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;

    const head = try store.addEdge(0, v2Edge(10, 101, 5, 0xA1));
    try testing.expect(isSlabHead(head)); // packed, not a whole block
    try testing.expectEqual(@as(u64, 1), try store.edgeCount(head));
    // touched set is exactly the slab block (decoded), never the tagged head.
    try testing.expectEqualSlices(PageId, &.{slabHeadPageId(head)}, store.touchedPages());

    var it = store.expand(head, null);
    defer it.deinit();
    const e = (try it.next()).?;
    try testing.expectEqual(@as(u64, 10), e.neighbor);
    try testing.expectEqual(@as(u64, 101), e.edge_id);
    try testing.expectEqual(@as(u64, 0xA1), e.public_id);
    try testing.expectEqual(@as(?EdgeEntry, null), try it.next());
}

test "P2 writer: many small NEW chains share ONE slab block (distinct slots)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;

    var heads: [8]PageId = undefined;
    for (&heads, 0..) |*h, i| {
        h.* = try store.addEdge(0, v2Edge(@intCast(100 + i), @intCast(1000 + i), 5, @intCast(0xB0 + i)));
        try testing.expect(isSlabHead(h.*));
    }
    // All packed into the same fill block, on distinct slots.
    const page0 = slabHeadPageId(heads[0]);
    for (heads, 0..) |h, i| {
        try testing.expectEqual(page0, slabHeadPageId(h));
        try testing.expectEqual(@as(u32, @intCast(i)), slabHeadSlot(h));
        const e = try firstEdge(&store, h);
        try testing.expectEqual(@as(u64, @intCast(100 + i)), e.neighbor);
    }
}

test "P2 writer: growing a slab chain keeps every edge (in-place tail-grow + relocate)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;

    // Chain A then chain B: A is no longer the tail run once B is packed.
    var a = try store.addEdge(0, v2Edge(10, 101, 5, 0xA1));
    const b = try store.addEdge(0, v2Edge(20, 201, 5, 0xB1));

    // Grow A (a middle run) — must relocate, tombstone the old slot, stay slab.
    a = try store.addEdge(a, v2Edge(11, 102, 5, 0xA2));
    try testing.expect(isSlabHead(a));
    // Grow A again — now A is the tail run, may grow in place.
    a = try store.addEdge(a, v2Edge(12, 103, 5, 0xA3));

    var na: std.ArrayList(u64) = .empty;
    defer na.deinit(testing.allocator);
    try collectNeighbors(&store, a, &na);
    try testing.expectEqual(@as(usize, 3), na.items.len);
    // exact set {10,11,12}
    var seen_a: [3]bool = .{ false, false, false };
    for (na.items) |n| {
        if (n == 10) seen_a[0] = true else if (n == 11) seen_a[1] = true else if (n == 12) seen_a[2] = true else return error.Unexpected;
    }
    try testing.expect(seen_a[0] and seen_a[1] and seen_a[2]);

    // B untouched by A's relocation.
    try testing.expectEqual(@as(u64, 1), try store.edgeCount(b));
    const be = try firstEdge(&store, b);
    try testing.expectEqual(@as(u64, 20), be.neighbor);
}

test "P2 writer: a chain that outgrows the slab GRADUATES to a legacy block chain" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;

    // Keep appending to one chain until it graduates (head stops being a slab
    // head) — the run outgrew a slab block. Every edge must survive.
    var head = try store.addEdge(0, v2Edge(0, 1, 5, 0xC0));
    var n: u64 = 1;
    var graduated = false;
    while (n < 400) : (n += 1) {
        head = try store.addEdge(head, v2Edge(n, n + 1, 5, 0xC000 + n));
        if (!isSlabHead(head)) {
            graduated = true;
            break;
        }
    }
    try testing.expect(graduated); // must have left the slab at some point
    // Enumerate every edge 0..=n exactly once.
    const total = n + 1;
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(testing.allocator);
    try collectNeighbors(&store, head, &list);
    try testing.expectEqual(@as(usize, @intCast(total)), list.items.len);
    try testing.expectEqual(total, try store.edgeCount(head));
}

test "P2 writer: removeEdge + updateEdgePropHead work on a slab-packed chain" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;

    var head = try store.addEdge(0, v2Edge(10, 101, 5, 0xA1));
    head = try store.addEdge(head, v2Edge(20, 102, 5, 0xA2));
    head = try store.addEdge(head, v2Edge(30, 103, 5, 0xA3));
    try testing.expect(isSlabHead(head));
    try testing.expectEqual(@as(u64, 3), try store.edgeCount(head));

    // update prop_head of the middle edge.
    const up = try store.updateEdgePropHead(head, 102, 77);
    try testing.expectEqual(@as(?PageId, slabHeadPageId(head)), up);
    {
        var it = store.expand(head, null);
        defer it.deinit();
        while (try it.next()) |e| {
            if (e.edge_id == 102) try testing.expectEqual(@as(u32, 77), e.prop_head) else try testing.expectEqual(@as(u32, 0), e.prop_head);
        }
    }

    // remove the middle edge; the other two survive; returned page is decoded.
    const rm = try store.removeEdge(head, 102);
    try testing.expectEqual(@as(?PageId, slabHeadPageId(head)), rm);
    try testing.expectEqual(@as(u64, 2), try store.edgeCount(head));
    var it = store.expand(head, null);
    defer it.deinit();
    while (try it.next()) |e| try testing.expect(e.edge_id != 102);
}

test "P2 writer: relocate then undoLastSlabTombstone brings the old head back to life" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;

    const a = try store.addEdge(0, v2Edge(10, 101, 5, 0xA1));
    _ = try store.addEdge(0, v2Edge(20, 201, 5, 0xB1)); // makes A a middle run

    // Grow A: relocates, tombstones A's old slot, arms the undo.
    const a2 = try store.addEdge(a, v2Edge(11, 102, 5, 0xA2));
    try testing.expect(a2 != a); // head moved (relocation)
    // The old head A now points at a tombstoned slot — reading it is corruption.
    try testing.expectError(error.DataCorruption, store.edgeCount(a));

    // Engine-style rollback: restore the old slot. The OLD head must read again.
    try store.undoLastSlabTombstone();
    try testing.expectEqual(@as(u64, 1), try store.edgeCount(a));
    const e = try firstEdge(&store, a);
    try testing.expectEqual(@as(u64, 10), e.neighbor);
}

// ============================================================================
// GAP-0060 — wide (v3 / slab-v3) edge prop_head write path
// ============================================================================

/// Read the entry-format byte of the slab block a slab head points at.
fn slabBlockFmt(store: *AdjStore, head: u64) !u8 {
    const page = slabHeadPageId(head);
    const frame = try store.buffer_pool.pin(store.file_id, page);
    const idx = store.buffer_pool.frameIndex(frame);
    defer store.buffer_pool.unpin(idx, false);
    return frame.dataSlice()[PAGE_HEADER_SIZE + 11]; // EdgeBlockHeader.entry_format
}

test "GAP-0060: wide_heads writer packs slab-v3 runs; u64 prop_head widens IN PLACE" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;
    store.wide_heads = true;

    // Edges added with prop_head=0 (geode adds the edge, then attaches props).
    var head = try store.addEdge(0, v2Edge(10, 101, 5, 0xA1));
    head = try store.addEdge(head, v2Edge(20, 102, 5, 0xA2));
    head = try store.addEdge(head, v2Edge(30, 103, 5, 0xA3));
    try testing.expect(isSlabHead(head));
    try testing.expectEqual(edge_mod.ENTRY_FORMAT_SLAB_V3, try slabBlockFmt(&store, head));
    try testing.expectEqual(@as(u64, 3), try store.edgeCount(head));

    // Widen the middle edge's prop_head to a prop-store SLAB head (bit 63) IN
    // PLACE — the node's out_head (== head) is unchanged (no relocation).
    const wide: u64 = (@as(u64, 1) << 63) | 0x00AB_CDEF_1234;
    const up = try store.updateEdgePropHead(head, 102, wide);
    try testing.expectEqual(@as(?PageId, slabHeadPageId(head)), up);

    var it = store.expand(head, null);
    defer it.deinit();
    var seen: usize = 0;
    while (try it.next()) |e| {
        seen += 1;
        if (e.edge_id == 102) {
            try testing.expectEqual(wide, e.prop_head); // full u64 survived
            try testing.expectEqual(@as(u64, 0xA2), e.public_id); // public_id intact
        } else {
            try testing.expectEqual(@as(u64, 0), e.prop_head);
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "GAP-0060: v3 CHAIN block carries a u64 prop_head (wide_heads, no slab)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = false; // legacy chain writer
    store.wide_heads = true;

    const wide: u64 = (@as(u64, 1) << 63) | 0xFEED_1234;
    var e = v2Edge(10, 201, 5, 0xB1);
    e.prop_head = wide;
    const head = try store.addEdge(0, e);
    try testing.expect(!isSlabHead(head)); // a bare chain head, not slab
    {
        const frame = try store.buffer_pool.pin(store.file_id, head);
        const idx = store.buffer_pool.frameIndex(frame);
        defer store.buffer_pool.unpin(idx, false);
        try testing.expectEqual(edge_mod.ENTRY_FORMAT_V3, frame.dataSlice()[PAGE_HEADER_SIZE + 11]);
    }
    const got = try firstEdge(&store, head);
    try testing.expectEqual(wide, got.prop_head);
    try testing.expectEqual(@as(u64, 0xB1), got.public_id);
}

test "GAP-0060: slab-v3 grow + remove round-trips all edges" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;
    store.wide_heads = true;

    var head: u64 = 0;
    var k: u64 = 0;
    while (k < 10) : (k += 1) head = try store.addEdge(head, v2Edge(100 + k, 300 + k, 5, 0));
    try testing.expect(isSlabHead(head));
    try testing.expectEqual(edge_mod.ENTRY_FORMAT_SLAB_V3, try slabBlockFmt(&store, head));
    try testing.expectEqual(@as(u64, 10), try store.edgeCount(head));

    const wide: u64 = (@as(u64, 1) << 63) | 7;
    _ = try store.updateEdgePropHead(head, 305, wide);
    _ = try store.removeEdge(head, 302);
    try testing.expectEqual(@as(u64, 9), try store.edgeCount(head));

    var it = store.expand(head, null);
    defer it.deinit();
    var found305 = false;
    var found302 = false;
    while (try it.next()) |e| {
        if (e.edge_id == 305) {
            found305 = true;
            try testing.expectEqual(wide, e.prop_head);
        }
        if (e.edge_id == 302) found302 = true;
    }
    try testing.expect(found305);
    try testing.expect(!found302);
}

test "GAP-0060: read-both — a wide_heads store reads a legacy slab-v2 block" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;
    store.wide_heads = true;

    // A pre-0060 slab-v2 block laid down directly on disk.
    const runs = [_][]const EdgeEntry{&[_]EdgeEntry{ v2Edge(10, 401, 5, 0xC1), v2Edge(20, 402, 5, 0xC2) }};
    const page = try writeRawSlabBlock(&store, &runs);
    const v2head = encodeSlabHead(page, 0);
    var it = store.expand(v2head, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| : (n += 1) {
        try testing.expectEqual(@as(u64, 0), e.prop_head >> 32); // legacy u32 head widened
    }
    try testing.expectEqual(@as(usize, 2), n);

    // ...and a fresh v3 slab chain in the SAME store writes/reads at 40B stride.
    const v3head = try store.addEdge(0, v2Edge(30, 403, 5, 0xC3));
    try testing.expectEqual(edge_mod.ENTRY_FORMAT_SLAB_V3, try slabBlockFmt(&store, v3head));
    try testing.expectEqual(@as(u64, 1), try store.edgeCount(v3head));
}

test "GAP-0060: updateEdgePropHead refuses a wide head in a legacy slab-v2 run (loud, no truncation)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);
    store.slab_packing = true;
    store.wide_heads = true;

    const runs = [_][]const EdgeEntry{&[_]EdgeEntry{v2Edge(10, 501, 5, 0)}};
    const page = try writeRawSlabBlock(&store, &runs);
    const v2head = encodeSlabHead(page, 0);
    // A narrow head fits the v2 run.
    _ = try store.updateEdgePropHead(v2head, 501, 42);
    try testing.expectEqual(@as(u64, 42), (try firstEdge(&store, v2head)).prop_head);
    // A WIDE head cannot fit 32B — refused loudly rather than silently truncated.
    const wide: u64 = (@as(u64, 1) << 63) | 9;
    try testing.expectError(error.WideHeadInLegacySlabRun, store.updateEdgePropHead(v2head, 501, wide));
}

test {
    std.testing.refAllDecls(@This());
}
