// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const node_mod = @import("node.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");

const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const NodeRec = node_mod.NodeRec;
const NodeId = types.NodeId;
const PageId = types.PageId;
const FileId = types.FileId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Fixed-record node storage on pages via the buffer pool.
/// Nodes are addressed by NodeId, which maps to a page and slot offset.
pub const NodeStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    page_size: u32,
    nodes_per_page: u32,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, page_size: u32) NodeStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .page_size = page_size,
            .nodes_per_page = node_mod.nodesPerPage(page_size),
        };
    }

    /// Read a node record by ID.
    /// Returns null if the node slot is empty (all zeros) or deleted.
    pub fn getNode(self: *NodeStore, node_id: NodeId) !?NodeRec {
        const page_id = self.pageForNode(node_id);
        const slot_offset = self.slotOffset(node_id);

        // Check if page is allocated
        if (!self.free_space.isAllocated(page_id)) return null;

        const frame = try self.buffer_pool.pin(.nodes, page_id);
        defer self.buffer_pool.unpin(self.buffer_pool.frameIndex(frame), false);

        const data = frame.dataSlice();
        // Use bytesToValue for alignment-safe reading from buffer pool pages.
        // Buffer pool pages are page-aligned, but slot offsets within a page
        // may not satisfy NodeRec's alignment requirement.
        const rec = std.mem.bytesToValue(NodeRec, data[slot_offset..][0..@sizeOf(NodeRec)]);

        if (node_mod.isEmpty(&rec)) return null;
        if (node_mod.isDeleted(&rec)) return null;

        return rec;
    }

    /// Write a node record at the given ID.
    /// Allocates the page via free_space if needed.
    pub fn putNode(self: *NodeStore, node_id: NodeId, rec: NodeRec) !void {
        const page_id = self.pageForNode(node_id);
        const slot_offset = self.slotOffset(node_id);

        // Ensure the page is allocated
        if (!self.free_space.isAllocated(page_id)) {
            try self.free_space.ensureCapacity(page_id + 1);
            // Mark this page as allocated in the bitmap
            self.free_space.bitmap.set(@intCast(page_id));
        }

        const frame = try self.buffer_pool.pin(.nodes, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);

        const data = frame.dataSlice();
        const rec_bytes: *const [@sizeOf(NodeRec)]u8 = @ptrCast(&rec);
        @memcpy(data[slot_offset..][0..@sizeOf(NodeRec)], rec_bytes);

        self.buffer_pool.unpin(frame_idx, true);
    }

    /// Mark a node as deleted (set DELETED flag).
    pub fn deleteNode(self: *NodeStore, node_id: NodeId) !void {
        const page_id = self.pageForNode(node_id);
        const slot_offset = self.slotOffset(node_id);

        if (!self.free_space.isAllocated(page_id)) return;

        const frame = try self.buffer_pool.pin(.nodes, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);

        const data = frame.dataSlice();
        // Use bytesToValue/bytesAsSlice for alignment-safe read-modify-write.
        // Read the record, set the deleted flag, and write it back.
        var rec = std.mem.bytesToValue(NodeRec, data[slot_offset..][0..@sizeOf(NodeRec)]);
        rec.flags |= node_mod.NODE_FLAG_DELETED;
        const rec_bytes: *const [@sizeOf(NodeRec)]u8 = @ptrCast(&rec);
        @memcpy(data[slot_offset..][0..@sizeOf(NodeRec)], rec_bytes);

        self.buffer_pool.unpin(frame_idx, true);
    }

    // Internal helpers

    fn pageForNode(self: *const NodeStore, node_id: NodeId) PageId {
        return node_id / self.nodes_per_page;
    }

    fn slotOffset(self: *const NodeStore, node_id: NodeId) u32 {
        const slot = @as(u32, @intCast(node_id % self.nodes_per_page));
        return PAGE_HEADER_SIZE + slot * @sizeOf(NodeRec);
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
    node_file: std.fs.File,
    node_pager: Pager,

    /// Two-phase init: call init(), then fixup() on the result.
    fn init() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const node_file = tmp_dir.dir.createFile("nodes.store", .{ .read = true, .truncate = true }) catch unreachable;
        var pool = try BufferPool.init(testing.allocator, 4096, 16);
        // FreeSpaceManager.init only stores the pointer; buffer_pool is not used during init.
        // We pass &pool here but must fixup after the struct is placed on the caller's stack.
        const fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);

        return .{
            .pool = pool,
            .fsm = fsm,
            .tmp_dir = tmp_dir,
            .node_file = node_file,
            .node_pager = Pager.init(node_file, 4096),
        };
    }

    /// Fix internal pointers after struct is placed on caller's stack.
    fn fixup(self: *TestEnv) void {
        self.pool.registerPager(.nodes, &self.node_pager);
        self.fsm.buffer_pool = &self.pool;
    }

    fn deinit(self: *TestEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.node_file.close();
        self.tmp_dir.cleanup();
    }
};

fn makeTestNode(label: u32) NodeRec {
    return NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_set = label,
        .flags = 0,
        ._pad = 0,
        .txn_stamp = 1,
    };
}

test "putNode + getNode round-trip" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);
    const rec = makeTestNode(42);

    try store.putNode(1, rec);
    const got = try store.getNode(1);

    try testing.expect(got != null);
    try testing.expectEqual(@as(u32, 42), got.?.label_set);
    try testing.expectEqual(@as(u64, 1), got.?.txn_stamp);
}

test "getNode on empty slot returns null" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    const got = try store.getNode(5);
    try testing.expect(got == null);
}

test "deleteNode sets DELETED flag, getNode returns null" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);
    const rec = makeTestNode(7);

    try store.putNode(3, rec);
    try store.deleteNode(3);

    const got = try store.getNode(3);
    try testing.expect(got == null);
}

test "multiple nodes on same page" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    try store.putNode(0, makeTestNode(10));
    try store.putNode(1, makeTestNode(20));
    try store.putNode(2, makeTestNode(30));

    const n0 = (try store.getNode(0)).?;
    const n1 = (try store.getNode(1)).?;
    const n2 = (try store.getNode(2)).?;

    try testing.expectEqual(@as(u32, 10), n0.label_set);
    try testing.expectEqual(@as(u32, 20), n1.label_set);
    try testing.expectEqual(@as(u32, 30), n2.label_set);
}

test "nodes across multiple pages" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    // nodes_per_page for 4096 = (4096-32)/40 = 101
    const npp = store.nodes_per_page;
    try testing.expectEqual(@as(u32, 101), npp);

    // Put a node on page 0 and page 1
    try store.putNode(0, makeTestNode(100));
    try store.putNode(npp, makeTestNode(200)); // first node on page 1

    const n0 = (try store.getNode(0)).?;
    const n1 = (try store.getNode(npp)).?;

    try testing.expectEqual(@as(u32, 100), n0.label_set);
    try testing.expectEqual(@as(u32, 200), n1.label_set);
}

test {
    std.testing.refAllDecls(@This());
}
