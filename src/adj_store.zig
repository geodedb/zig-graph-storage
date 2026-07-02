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
    /// Capacity of the blocks the PRODUCTION WRITER creates (v2, 32 B
    /// entries, since P2). Use `capacityFor` when parsing an existing block —
    /// legacy v1 blocks hold more (24 B) entries.
    entries_per_block: u32,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, file_id: FileId, page_size: u32) AdjStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .file_id = file_id,
            .page_size = page_size,
            .entries_per_block = edge_mod.entriesPerBlock(page_size, edge_mod.ENTRY_FORMAT_V2),
        };
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

    /// Remove an edge entry from a node's adjacency list.
    /// Scans all blocks for the matching edge_id and removes it by swapping with the last entry.
    pub fn removeEdge(self: *AdjStore, head_page: PageId, edge_id: EdgeId) !void {
        if (head_page == 0) return;

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
                    return;
                }
            }

            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }
    }

    pub const AdjEdgeIterator = struct {
        store: *AdjStore,
        current_page: u64,
        current_frame_idx: ?u32 = null,
        current_index: u16 = 0,
        rel_type: ?u32,
        hops: u32 = 0,

        pub fn deinit(self: *AdjEdgeIterator) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, false);
                self.current_frame_idx = null;
            }
        }

        pub fn next(self: *AdjEdgeIterator) anyerror!?EdgeEntry {
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
    };

    /// Return an iterator over edge entries starting from head_page (O(1) allocation path).
    pub fn expand(self: *AdjStore, head_page: PageId, rel_type_filter: ?u32) AdjEdgeIterator {
        return .{
            .store = self,
            .current_page = head_page,
            .rel_type = rel_type_filter,
        };
    }

    /// Update the prop_head of an existing edge entry in the adjacency chain.
    /// Scans the chain starting at head_page for the given edge_id.
    /// Returns true if found and updated, false if edge not found.
    pub fn updateEdgePropHead(self: *AdjStore, head_page: PageId, edge_id: EdgeId, new_prop_head: u32) !bool {
        if (head_page == 0) return false;

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
                    return true;
                }
            }

            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }
        return false;
    }

    /// Count edges in the adjacency list.
    pub fn edgeCount(self: *AdjStore, head_page: PageId) !u64 {
        if (head_page == 0) return 0;

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

    const epb = store.entries_per_block;

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

    try store.removeEdge(head, 2);

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

    // Update prop_head for edge_id=2
    const found = try store.updateEdgePropHead(head, 2, 42);
    try testing.expect(found);

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

test "updateEdgePropHead returns false for missing edge" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    var head: PageId = 0;
    head = try store.addEdge(head, makeEdge(10, 1, 5));

    const found = try store.updateEdgePropHead(head, 999, 42);
    try testing.expect(!found);
}

test "updateEdgePropHead on empty list returns false" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = AdjStore.init(&env.pool, &env.fsm, .adj_out, 4096);

    const found = try store.updateEdgePropHead(0, 1, 42);
    try testing.expect(!found);
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

test {
    std.testing.refAllDecls(@This());
}
