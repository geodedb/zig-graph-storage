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
        var bh = self.readBlockHeader(data);

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
            var bh = self.readBlockHeader(data);

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

    /// Iterate all edge entries starting from head_page.
    /// Returns a slice of EdgeEntry (caller owns, must free).
    pub fn expand(self: *AdjStore, head_page: PageId, rel_type_filter: ?u32, allocator: Allocator) ![]EdgeEntry {
        if (head_page == 0) return try allocator.alloc(EdgeEntry, 0);

        var result: std.ArrayList(EdgeEntry) = .{};
        errdefer result.deinit(allocator);

        var current_page = head_page;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(self.file_id, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();
            const bh = self.readBlockHeader(data);

            var i: u16 = 0;
            while (i < bh.count) : (i += 1) {
                const e = self.readEntry(data, i);
                if (rel_type_filter) |filter| {
                    if (e.rel_type == filter) {
                        try result.append(allocator, e);
                    }
                } else {
                    try result.append(allocator, e);
                }
            }

            const next = bh.next_block;
            self.buffer_pool.unpin(frame_idx, false);
            current_page = next;
        }

        return result.toOwnedSlice(allocator);
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
            const bh = self.readBlockHeader(data);

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

    fn readBlockHeader(self: *const AdjStore, data: []u8) EdgeBlockHeader {
        const off = self.blockHeaderOffset();
        const bytes = data[off..][0..BLOCK_HEADER_SIZE];
        return @bitCast(bytes.*);
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

    const edges = try store.expand(head, null, testing.allocator);
    defer testing.allocator.free(edges);

    try testing.expectEqual(@as(usize, 2), edges.len);
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

    const edges = try store.expand(head, null, testing.allocator);
    defer testing.allocator.free(edges);

    try testing.expectEqual(@as(usize, 3), edges.len);
    try testing.expectEqual(@as(u64, 10), edges[0].neighbor);
    try testing.expectEqual(@as(u64, 20), edges[1].neighbor);
    try testing.expectEqual(@as(u64, 30), edges[2].neighbor);
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

    const edges = try store.expand(head, null, testing.allocator);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, @intCast(epb + 1)), edges.len);

    // With head-insert, the overflow entry is in the new head block,
    // so expand reads it first.
    try testing.expectEqual(@as(u64, 999), edges[0].neighbor);
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

    const edges = try store.expand(head, null, testing.allocator);
    defer testing.allocator.free(edges);

    // Edge with edge_id=2 should be gone
    for (edges) |e| {
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

    const type1_edges = try store.expand(head, 1, testing.allocator);
    defer testing.allocator.free(type1_edges);
    try testing.expectEqual(@as(usize, 2), type1_edges.len);

    const type2_edges = try store.expand(head, 2, testing.allocator);
    defer testing.allocator.free(type2_edges);
    try testing.expectEqual(@as(usize, 1), type2_edges.len);

    const type9_edges = try store.expand(head, 9, testing.allocator);
    defer testing.allocator.free(type9_edges);
    try testing.expectEqual(@as(usize, 0), type9_edges.len);
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
