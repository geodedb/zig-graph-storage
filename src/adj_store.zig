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
            // No-truncate rule: a v1 slot cannot carry a real public_id.
            const would_drop_public_id =
                bh.entry_format == edge_mod.ENTRY_FORMAT_V1 and entry.public_id != 0;
            if (has_space and !would_drop_public_id) {
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
        self.writeBlockHeader(new_data, .{
            .next_block = head_page,
            .count = 1,
            .kind = 0,
            .entry_format = edge_mod.ENTRY_FORMAT_V2,
            .payload_size = @intCast(edge_mod.entrySize(edge_mod.ENTRY_FORMAT_V2)),
            .checksum = 0,
        });
        self.writeEntry(new_data, 0, entry, edge_mod.ENTRY_FORMAT_V2);
        self.buffer_pool.unpin(new_frame_idx, true);
        return new_page;
    }

    /// Slab write path (P2). Placeholder until the writer lands: a tagged head
    /// still cannot be appended to. With `slab_packing` off (default) this is
    /// only reachable via a tagged head, so it preserves the P1 reject.
    fn addEdgeSlab(self: *AdjStore, head_page: PageId, entry: EdgeEntry) !PageId {
        _ = self;
        _ = entry;
        _ = head_page;
        return error.SlabChainWriteNotSupported;
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
    pub fn removeEdge(self: *AdjStore, head_page: PageId, edge_id: EdgeId) !?PageId {
        // P1: slab chains are read-only — see addEdge.
        if (isSlabHead(head_page)) return error.SlabChainWriteNotSupported;
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
                    const entry = readSlabRunEntry(data, run.offset, self.current_index);
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
    pub fn updateEdgePropHead(self: *AdjStore, head_page: PageId, edge_id: EdgeId, new_prop_head: u32) !?PageId {
        // P1: slab chains are read-only — see addEdge.
        if (isSlabHead(head_page)) return error.SlabChainWriteNotSupported;
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
                    // In-place rewrite at the block's own format; public_id
                    // is preserved (v2) or remains absent on disk (v1).
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
        if (bh.entry_format > edge_mod.ENTRY_FORMAT_V2) return error.DataCorruption;
        if (bh.count > @as(u16, @intCast(self.capacityFor(bh.entry_format)))) return error.DataCorruption;
        return bh;
    }

    fn writeBlockHeader(self: *const AdjStore, data: []u8, bh: EdgeBlockHeader) void {
        const off = self.blockHeaderOffset();
        const bytes: *const [BLOCK_HEADER_SIZE]u8 = @ptrCast(&bh);
        @memcpy(data[off..][0..BLOCK_HEADER_SIZE], bytes);
    }

    /// Parse one entry at the given block format. A v1 record is exactly the
    /// 24-byte prefix of `EdgeEntry`; its `public_id` surfaces as 0.
    fn readEntry(self: *const AdjStore, data: []u8, slot: u16, entry_format: u8) EdgeEntry {
        const off = self.entryOffset(slot, entry_format);
        if (entry_format == edge_mod.ENTRY_FORMAT_V2) {
            const bytes = data[off..][0..edge_mod.ENTRY_SIZE_V2];
            return @bitCast(bytes.*);
        }
        var entry = EdgeEntry{ .neighbor = 0, .edge_id = 0, .rel_type = 0, .prop_head = 0, .public_id = 0 };
        @memcpy(std.mem.asBytes(&entry)[0..edge_mod.ENTRY_SIZE_V1], data[off..][0..edge_mod.ENTRY_SIZE_V1]);
        return entry;
    }

    /// Write one entry at the given block format. Writing v1 stores only the
    /// 24-byte prefix — the entry's `public_id` is dropped, which is why
    /// `addEdge` only ever writes v1 records for `public_id == 0` entries
    /// (a real public id gets a fresh v2 block instead — no-truncate rule).
    fn writeEntry(self: *const AdjStore, data: []u8, slot: u16, entry: EdgeEntry, entry_format: u8) void {
        const off = self.entryOffset(slot, entry_format);
        const size = edge_mod.entrySize(entry_format);
        @memcpy(data[off..][0..size], std.mem.asBytes(&entry)[0..size]);
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
        if (bh.entry_format != edge_mod.ENTRY_FORMAT_SLAB) return error.DataCorruption;
        if (bh.next_block != 0) return error.DataCorruption;
        const dir_bytes = @as(u64, bh.count) * edge_mod.SLAB_DIR_ENTRY_SIZE;
        if (edge_mod.SLAB_RUNS_OFFSET + dir_bytes + self.tail_reserve > data.len) return error.DataCorruption;
        return bh;
    }

    /// Resolve a slab (block, slot) to its validated run. The live-head
    /// invariant makes a tombstoned or out-of-range slot reached via a stored
    /// head ref corruption — never silently empty.
    fn resolveSlabRun(self: *const AdjStore, data: []const u8, slot: u32) error{DataCorruption}!edge_mod.SlabSlot {
        const bh = try self.readSlabBlockHeader(data);
        if (slot >= bh.count) return error.DataCorruption;
        const run = edge_mod.readSlabSlot(data, self.tail_reserve, slot);
        if (run.offset == edge_mod.SLAB_SLOT_TOMBSTONE) return error.DataCorruption;
        if (run.offset < edge_mod.SLAB_RUNS_OFFSET) return error.DataCorruption;
        const run_end = @as(u64, run.offset) + @as(u64, run.entry_count) * edge_mod.ENTRY_SIZE_V2;
        if (run_end > edge_mod.slabDirStart(data.len, self.tail_reserve, bh.count)) return error.DataCorruption;
        return run;
    }

    /// Read entry `idx` of a validated slab run (always the v2 32 B stride).
    fn readSlabRunEntry(data: []const u8, run_offset: u32, idx: u16) EdgeEntry {
        const off = @as(usize, run_offset) + @as(usize, idx) * edge_mod.ENTRY_SIZE_V2;
        const bytes = data[off..][0..edge_mod.ENTRY_SIZE_V2];
        return @bitCast(bytes.*);
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
            @memcpy(data[run_off..][0..edge_mod.ENTRY_SIZE_V2], std.mem.asBytes(&e)[0..edge_mod.ENTRY_SIZE_V2]);
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

test "P1 mutators reject slab heads loudly (slab writes land in P2)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();
    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const run = [_]EdgeEntry{v2Edge(10, 701, 5, 0xF1)};
    const page = try writeRawSlabBlock(&store, &.{&run});
    const head = encodeSlabHead(page, 0);

    try testing.expectError(error.SlabChainWriteNotSupported, store.addEdge(head, makeEdge(20, 702, 5)));
    try testing.expectError(error.SlabChainWriteNotSupported, store.removeEdge(head, 701));
    try testing.expectError(error.SlabChainWriteNotSupported, store.updateEdgePropHead(head, 701, 42));
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

test {
    std.testing.refAllDecls(@This());
}
