// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Edge co-location (Phase A): the per-shard incoming-adjacency directory.
//!
//! Maps a destination node id -> the head PageId of that dst's incoming-edge
//! chain *for edges whose SOURCE hashes to this shard* (the chain bodies live in
//! the sibling `adj_in_remote` AdjStore, FileId `in_idx`). Co-location records a
//! cross-endpoint edge's incoming adjacency on the SOURCE shard rather than the
//! destination shard, so an edge `(from)-[r]->(to)` is a single-shard write; this
//! directory is how `expandIn(to)`'s scatter-gather finds that dst's chain head
//! on each of the 16 shards.
//!
//! It is a page-backed fixed-record store modeled VERBATIM on `NodeStore`: the
//! record is a bare 8-byte PageId, addressed by `dst_id / heads_per_page` +
//! in-page slot. Crucially it has NO snapshot/serialize logic of its own — its
//! durability is inherited entirely from the WAL `logPage` + checkpoint
//! `flushAll`/`syncDirty` path, exactly like AdjStore and NodeStore. A directory
//! page modified by an edge write is logged via `logPage(.in_dir, page)` in the
//! SAME single-shard txn as the chain body, so physical page-image redo
//! (`recovery.zig`) restores it crash-consistently with the body — there is
//! nothing to rebuild on open (the design's "page-backed directory" choice that
//! avoids the existence-index's snapshot+rebuild machinery).
//!
//! A `0` head means "no incoming chain on this shard for this dst", matching the
//! AdjStore `head_page == 0` empty-list convention.

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");

const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const NodeId = types.NodeId;
const PageId = types.PageId;
const FileId = types.FileId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Bytes per directory record: a single PageId.
const HEAD_SIZE: u32 = @sizeOf(PageId);

/// Page-backed `dst_node_id -> head PageId` directory, one per shard.
pub const InHeadDir = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    file_id: FileId,
    page_size: u32,
    heads_per_page: u32,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, file_id: FileId, page_size: u32) InHeadDir {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .file_id = file_id,
            .page_size = page_size,
            .heads_per_page = headsPerPage(page_size),
        };
    }

    /// Page id holding the directory entry for `dst`.
    pub fn pageForNode(self: *const InHeadDir, dst: NodeId) PageId {
        return dst / self.heads_per_page;
    }

    fn slotOffset(self: *const InHeadDir, dst: NodeId) u32 {
        const slot = @as(u32, @intCast(dst % self.heads_per_page));
        return PAGE_HEADER_SIZE + slot * HEAD_SIZE;
    }

    /// Read the incoming-chain head PageId for `dst` (0 = no chain on this shard).
    pub fn getHead(self: *InHeadDir, dst: NodeId) !PageId {
        const page_id = self.pageForNode(dst);
        if (!self.free_space.isAllocated(page_id)) return 0;

        const frame = try self.buffer_pool.pin(self.file_id, page_id);
        defer self.buffer_pool.unpin(self.buffer_pool.frameIndex(frame), false);

        const data = frame.dataSlice();
        const off = self.slotOffset(dst);
        return std.mem.bytesToValue(PageId, data[off..][0..HEAD_SIZE]);
    }

    /// Write `head` as the incoming-chain head PageId for `dst`. Allocates the
    /// directory page (in this store's own free space) if needed. Returns the
    /// directory page id that was written so the caller can `logPage` it under
    /// the edge's txn.
    pub fn setHead(self: *InHeadDir, dst: NodeId, head: PageId) !PageId {
        const page_id = self.pageForNode(dst);
        if (!self.free_space.isAllocated(page_id)) {
            try self.free_space.ensureCapacity(page_id + 1);
            self.free_space.bitmap.set(@intCast(page_id));
        }

        const frame = try self.buffer_pool.pin(self.file_id, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);

        const data = frame.dataSlice();
        const off = self.slotOffset(dst);
        const head_bytes: *const [HEAD_SIZE]u8 = @ptrCast(&head);
        @memcpy(data[off..][0..HEAD_SIZE], head_bytes);

        self.buffer_pool.unpin(frame_idx, true);
        return page_id;
    }
};

/// How many PageId heads fit in a page body (page_size minus 32-byte header).
pub fn headsPerPage(page_size: u32) u32 {
    return (page_size - PAGE_HEADER_SIZE) / HEAD_SIZE;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const testing_support_mod = @import("testing_support.zig");
const SingleStoreEnv = testing_support_mod.SingleStoreEnv;

test "headsPerPage for 8192-byte pages" {
    // (8192 - 32) / 8 = 1020
    try testing.expectEqual(@as(u32, 1020), headsPerPage(8192));
}

test "setHead + getHead round-trip on one page" {
    var env = try SingleStoreEnv.init(testing.allocator, .in_dir, "adj_in_dir.store", 4096, 16);
    env.register();
    defer env.deinit();

    var dir = InHeadDir.init(&env.pool, &env.fsm, .in_dir, 4096);

    // Unset dst reads as 0.
    try testing.expectEqual(@as(PageId, 0), try dir.getHead(7));

    _ = try dir.setHead(7, 123);
    _ = try dir.setHead(8, 456);
    try testing.expectEqual(@as(PageId, 123), try dir.getHead(7));
    try testing.expectEqual(@as(PageId, 456), try dir.getHead(8));

    // Overwrite is visible.
    _ = try dir.setHead(7, 999);
    try testing.expectEqual(@as(PageId, 999), try dir.getHead(7));
}

test "setHead + getHead across multiple pages" {
    var env = try SingleStoreEnv.init(testing.allocator, .in_dir, "adj_in_dir.store", 4096, 16);
    env.register();
    defer env.deinit();

    var dir = InHeadDir.init(&env.pool, &env.fsm, .in_dir, 4096);
    const hpp = dir.heads_per_page;

    _ = try dir.setHead(0, 11);
    _ = try dir.setHead(hpp, 22); // first slot on page 1
    _ = try dir.setHead(hpp * 3 + 5, 33); // page 3

    try testing.expectEqual(@as(PageId, 11), try dir.getHead(0));
    try testing.expectEqual(@as(PageId, 22), try dir.getHead(hpp));
    try testing.expectEqual(@as(PageId, 33), try dir.getHead(hpp * 3 + 5));
    // An untouched slot on an allocated page still reads 0.
    try testing.expectEqual(@as(PageId, 0), try dir.getHead(1));
}

test {
    std.testing.refAllDecls(@This());
}
