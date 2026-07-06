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

    /// WAL-aware derived-index tail reconcile: read a node record INCLUDING a
    /// DELETED one (unlike `getNode`, which returns null for deleted). Returns
    /// null only for an unallocated page or a genuinely empty slot. The caller
    /// classifies via `node_mod.isDeleted`. deleteNode never cascades (labels,
    /// props, out-adjacency stay intact), so a deleted record's head pointers
    /// are still safe to walk when un-deriving its stale index entries.
    pub fn getRawSlot(self: *NodeStore, node_id: NodeId) !?NodeRec {
        const page_id = self.pageForNode(node_id);
        if (!self.free_space.isAllocated(page_id)) return null;

        const frame = try self.buffer_pool.pin(.nodes, page_id);
        defer self.buffer_pool.unpin(self.buffer_pool.frameIndex(frame), false);

        const data = frame.dataSlice();
        const rec = std.mem.bytesToValue(NodeRec, data[self.slotOffset(node_id)..][0..@sizeOf(NodeRec)]);
        if (node_mod.isEmpty(&rec)) return null;
        return rec; // may be DELETED — caller checks node_mod.isDeleted
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

    /// Page-scan iterator. Pins each page once and visits every non-empty,
    /// non-deleted node slot, calling `callback(context, node_id, rec)` for
    /// each live node. This eliminates the per-ID pin/unpin overhead that
    /// occurs when calling `getNode` in a loop over consecutive IDs.
    pub fn scanNodes(
        self: *NodeStore,
        max_node_id: u64,
        context: anytype,
        callback: *const fn (@TypeOf(context), NodeId, NodeRec) void,
    ) !void {
        if (max_node_id == 0) return;

        const npp = self.nodes_per_page;
        // Compute the page range we need to visit.
        // node_id 0 lives on page 0, node_id npp lives on page 1, etc.
        const last_node = max_node_id - 1;
        const last_page = last_node / npp;

        var page_id: u64 = 0;
        while (page_id <= last_page) : (page_id += 1) {
            // Skip pages that were never allocated.
            if (!self.free_space.isAllocated(page_id)) {
                continue;
            }

            const frame = try self.buffer_pool.pin(.nodes, page_id);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            defer self.buffer_pool.unpin(frame_idx, false);

            const data = frame.dataSlice();

            // How many slots to inspect on this page.
            const first_node_on_page = page_id * npp;
            const remaining = max_node_id - first_node_on_page;
            const slots_on_page: u32 = if (remaining >= npp) npp else @intCast(remaining);

            var slot: u32 = 0;
            while (slot < slots_on_page) : (slot += 1) {
                const offset = PAGE_HEADER_SIZE + slot * @sizeOf(NodeRec);
                const rec = std.mem.bytesToValue(NodeRec, data[offset..][0..@sizeOf(NodeRec)]);

                if (node_mod.isEmpty(&rec)) {
                    continue;
                }
                if (node_mod.isDeleted(&rec)) {
                    continue;
                }

                const node_id: NodeId = first_node_on_page + slot;
                callback(context, node_id, rec);
            }
        }
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
const testing_support_mod = @import("testing_support.zig");
const SingleStoreEnv = testing_support_mod.SingleStoreEnv;

fn makeTestNode(_: u32) NodeRec {
    return NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
}

test "putNode + getNode round-trip" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);
    const rec = makeTestNode(42);

    try store.putNode(1, rec);
    const got = try store.getNode(1);

    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 0), got.?.label_head);
    try testing.expectEqual(@as(u64, 1), got.?.txn_stamp);
}

test "getNode on empty slot returns null" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    const got = try store.getNode(5);
    try testing.expect(got == null);
}

test "deleteNode sets DELETED flag, getNode returns null" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);
    const rec = makeTestNode(7);

    try store.putNode(3, rec);
    try store.deleteNode(3);

    const got = try store.getNode(3);
    try testing.expect(got == null);
}

test "multiple nodes on same page" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    try store.putNode(0, makeTestNode(10));
    try store.putNode(1, makeTestNode(20));
    try store.putNode(2, makeTestNode(30));

    const n0 = (try store.getNode(0)).?;
    const n1 = (try store.getNode(1)).?;
    const n2 = (try store.getNode(2)).?;

    try testing.expectEqual(@as(u64, 0), n0.label_head);
    try testing.expectEqual(@as(u64, 0), n1.label_head);
    try testing.expectEqual(@as(u64, 0), n2.label_head);
}

test "nodes across multiple pages" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    // nodes_per_page for 4096 = (4096-32)/48 = 84
    const npp = store.nodes_per_page;
    try testing.expectEqual(@as(u32, 84), npp);

    // Put a node on page 0 and page 1
    try store.putNode(0, makeTestNode(100));
    try store.putNode(npp, makeTestNode(200)); // first node on page 1

    const n0 = (try store.getNode(0)).?;
    const n1 = (try store.getNode(npp)).?;

    try testing.expectEqual(@as(u64, 0), n0.label_head);
    try testing.expectEqual(@as(u64, 0), n1.label_head);
}

test "scanNodes visits all live nodes across multiple pages" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 64);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    // nodes_per_page = 84 for 4096-byte pages.
    // 500 nodes spans 5 pages (pages 0..4).
    const total_nodes: u64 = 500;
    var i: u64 = 0;
    while (i < total_nodes) : (i += 1) {
        // All nodes have label_head = 0 (no labels in var.store).
        try store.putNode(i, makeTestNode(@intCast((i % 10) + 1)));
    }

    // Delete a few nodes to verify they are skipped.
    try store.deleteNode(10);
    try store.deleteNode(200);
    try store.deleteNode(499);

    // Scan and collect results.
    const ScanCtx = struct {
        count: u64 = 0,
        id_sum: u64 = 0,

        fn onNode(self: *@This(), node_id: NodeId, _: NodeRec) void {
            self.count += 1;
            self.id_sum += node_id;
        }
    };
    var ctx = ScanCtx{};
    try store.scanNodes(total_nodes, &ctx, &ScanCtx.onNode);

    // 500 - 3 deleted = 497 live nodes.
    try testing.expectEqual(@as(u64, 497), ctx.count);

    // Sum of 0..499 minus 10, 200, 499 = (499*500/2) - 709 = 124750 - 709 = 124041.
    try testing.expectEqual(@as(u64, 124041), ctx.id_sum);
}

test "scanNodes with zero max_node_id is a no-op" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    const Counter = struct {
        count: u64 = 0,
        fn onNode(self: *@This(), _: NodeId, _: NodeRec) void {
            self.count += 1;
        }
    };
    var ctx = Counter{};
    try store.scanNodes(0, &ctx, &Counter.onNode);
    try testing.expectEqual(@as(u64, 0), ctx.count);
}

test "scanNodes skips unallocated pages" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    // Put a node on page 1 (node_id = npp) but not page 0.
    const npp = store.nodes_per_page;
    try store.putNode(npp, makeTestNode(42));

    const Counter = struct {
        count: u64 = 0,
        last_id: NodeId = 0,
        fn onNode(self: *@This(), node_id: NodeId, _: NodeRec) void {
            self.count += 1;
            self.last_id = node_id;
        }
    };
    var ctx = Counter{};
    // Scan up to npp+1 so we cover both page 0 and page 1.
    try store.scanNodes(npp + 1, &ctx, &Counter.onNode);

    try testing.expectEqual(@as(u64, 1), ctx.count);
    try testing.expectEqual(@as(NodeId, npp), ctx.last_id);
}

test {
    std.testing.refAllDecls(@This());
}
