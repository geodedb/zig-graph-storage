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
const ENTRY_SIZE: u32 = @sizeOf(EdgeEntry);

/// Adjacency block storage for outgoing/incoming edges.
/// Each adjacency list is a chain of pages, each containing an EdgeBlockHeader
/// followed by an array of EdgeEntry records.
pub const AdjStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    file_id: FileId,
    page_size: u32,
    entries_per_block: u32,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, file_id: FileId, page_size: u32) AdjStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .file_id = file_id,
            .page_size = page_size,
            .entries_per_block = edge_mod.entriesPerBlock(page_size),
        };
    }

    /// Add an edge entry to a node's adjacency list (O(1) head-insert).
    /// If head_page is 0 (no existing list), allocates a new block and returns its page_id as the new head.
    /// If the head block has space, inserts there. If the head block is full, allocates a new head
    /// block whose overflow points to the old head.
    /// Returns the head page_id (may be unchanged or new).
    pub fn addEdge(self: *AdjStore, head_page: PageId, entry: EdgeEntry) !PageId {
        if (head_page == 0) {
            // No existing list: allocate a new block
            const new_page = try self.free_space.allocPage();
            const frame = try self.buffer_pool.pinNew(self.file_id, new_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);

            const data = frame.dataSlice();
            // Zero out the page (pinNew already does this)
            // Write block header with count=1
            self.writeBlockHeader(data, .{
                .next_block = 0,
                .count = 1,
                .kind = 0,
                ._reserved = 0,
                .payload_size = ENTRY_SIZE,
                .checksum = 0,
            });
            // Write the entry at slot 0
            self.writeEntry(data, 0, entry);

            self.buffer_pool.unpin(frame_idx, true);
            return new_page;
        }

        // Head-insert: only check the head block. If it has space, insert
        // there (O(1)). If full, allocate a new block as the new head and
        // chain the old head as its overflow (O(1)). This avoids the O(blocks)
        // walk that the previous tail-append strategy required.
        const frame = try self.buffer_pool.pin(self.file_id, head_page);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const data = frame.dataSlice();
        var bh = try self.readBlockHeader(data);

        if (bh.count < @as(u16, @intCast(self.entries_per_block))) {
            // Space in the head block -- insert here
            self.writeEntry(data, bh.count, entry);
            bh.count += 1;
            bh.payload_size = @intCast(@as(u32, bh.count) * ENTRY_SIZE);
            self.writeBlockHeader(data, bh);
            self.buffer_pool.unpin(frame_idx, true);
            return head_page;
        }

        // Head block is full -- allocate a new head that points to the old head
        self.buffer_pool.unpin(frame_idx, false);

        const new_page = try self.free_space.allocPage();
        const new_frame = try self.buffer_pool.pinNew(self.file_id, new_page);
        const new_frame_idx = self.buffer_pool.frameIndex(new_frame);

        const new_data = new_frame.dataSlice();
        self.writeBlockHeader(new_data, .{
            .next_block = head_page,
            .count = 1,
            .kind = 0,
            ._reserved = 0,
            .payload_size = ENTRY_SIZE,
            .checksum = 0,
        });
        self.writeEntry(new_data, 0, entry);
        self.buffer_pool.unpin(new_frame_idx, true);
        return new_page;
    }

    /// Remove an edge entry from a node's adjacency list.
    /// Scans all blocks for the matching edge_id and removes it by swapping with the last entry.
    pub fn removeEdge(self: *AdjStore, head_page: PageId, edge_id: EdgeId) !void {
        if (head_page == 0) return;

        var current_page = head_page;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            var bh = try self.readBlockHeader(data);

            var i: u16 = 0;
            while (i < bh.count) : (i += 1) {
                const e = self.readEntry(data, i);
                if (e.edge_id == edge_id) {
                    // Found it: swap with last entry and decrement count
                    if (i < bh.count - 1) {
                        const last = self.readEntry(data, bh.count - 1);
                        self.writeEntry(data, i, last);
                    }
                    bh.count -= 1;
                    bh.payload_size = @intCast(@as(u32, bh.count) * ENTRY_SIZE);
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

        pub fn deinit(self: *AdjEdgeIterator) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, false);
                self.current_frame_idx = null;
            }
        }

        pub fn next(self: *AdjEdgeIterator) anyerror!?EdgeEntry {
            while (self.current_page != 0) {
                if (self.current_frame_idx == null) {
                    const frame = try self.store.buffer_pool.pin(self.store.file_id, self.current_page);
                    self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                }

                const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
                const data = frame.dataSlice();
                const bh = try self.store.readBlockHeader(data);

                while (self.current_index < bh.count) {
                    const entry = self.store.readEntry(data, self.current_index);
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
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const bh = try self.readBlockHeader(data);

            var i: u16 = 0;
            while (i < bh.count) : (i += 1) {
                const e = self.readEntry(data, i);
                if (e.edge_id == edge_id) {
                    self.writeEntry(data, i, .{
                        .neighbor = e.neighbor,
                        .edge_id = e.edge_id,
                        .rel_type = e.rel_type,
                        .prop_head = new_prop_head,
                    });
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
        while (current_page != 0) {
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

    fn entryOffset(self: *const AdjStore, slot: u16) u32 {
        return self.blockHeaderOffset() + BLOCK_HEADER_SIZE + @as(u32, slot) * ENTRY_SIZE;
    }

    fn readBlockHeader(self: *const AdjStore, data: []u8) error{DataCorruption}!EdgeBlockHeader {
        const off = self.blockHeaderOffset();
        const bytes = data[off..][0..BLOCK_HEADER_SIZE];
        const bh: EdgeBlockHeader = @bitCast(bytes.*);
        if (bh.count > @as(u16, @intCast(self.entries_per_block))) return error.DataCorruption;
        return bh;
    }

    fn writeBlockHeader(self: *const AdjStore, data: []u8, bh: EdgeBlockHeader) void {
        const off = self.blockHeaderOffset();
        const bytes: *const [BLOCK_HEADER_SIZE]u8 = @ptrCast(&bh);
        @memcpy(data[off..][0..BLOCK_HEADER_SIZE], bytes);
    }

    fn readEntry(self: *const AdjStore, data: []u8, slot: u16) EdgeEntry {
        const off = self.entryOffset(slot);
        const bytes = data[off..][0..ENTRY_SIZE];
        return @bitCast(bytes.*);
    }

    fn writeEntry(self: *const AdjStore, data: []u8, slot: u16, entry: EdgeEntry) void {
        const off = self.entryOffset(slot);
        const bytes: *const [ENTRY_SIZE]u8 = @ptrCast(&entry);
        @memcpy(data[off..][0..ENTRY_SIZE], bytes);
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
    adj_file: std.fs.File,
    adj_pager: Pager,

    fn init() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const adj_file = tmp_dir.dir.createFile("adj_out.store", .{ .read = true, .truncate = true }) catch unreachable;
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
        self.adj_file.close();
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

test {
    std.testing.refAllDecls(@This());
}
