// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");
const index_snapshot_mod = @import("index_snapshot.zig");
const node_store_mod = @import("node_store.zig");
const node_mod = @import("node.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const NodeStore = node_store_mod.NodeStore;
const LabelId = types.LabelId;
const NodeId = types.NodeId;

const NodeList = std.ArrayList(NodeId);
const SNAPSHOT_MAGIC = "GSLIDX1\x00";

/// Label posting lists — maps LabelId to sorted arrays of NodeId.
/// For v1, the posting lists are kept in memory and rebuilt from the
/// node store on startup.
pub const LabelIndex = struct {
    allocator: Allocator,
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    page_size: u32,

    /// In-memory index: LabelId -> list of NodeId
    index: std.AutoHashMap(LabelId, NodeList),

    pub const Iterator = struct {
        items: []const NodeId,
        index: usize = 0,

        pub fn next(self: *Iterator) !?NodeId {
            if (self.index >= self.items.len) return null;
            defer self.index += 1;
            return self.items[self.index];
        }

        pub fn deinit(_: *Iterator) void {}
    };

    pub fn init(
        allocator: Allocator,
        buffer_pool: *BufferPool,
        free_space: *FreeSpaceManager,
        page_size: u32,
    ) LabelIndex {
        return .{
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .page_size = page_size,
            .index = std.AutoHashMap(LabelId, NodeList).init(allocator),
        };
    }

    pub fn clear(self: *LabelIndex) void {
        var it = self.index.valueIterator();
        while (it.next()) |list| {
            @constCast(list).deinit(self.allocator);
        }
        self.index.clearAndFree();
    }

    pub fn deinit(self: *LabelIndex) void {
        self.clear();
        self.index.deinit();
    }

    /// Add a node to a label's posting list.
    pub fn addNode(self: *LabelIndex, label_id: LabelId, node_id: NodeId) !void {
        const gop = try self.index.getOrPut(label_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        // Insert in sorted order using binary search; skip duplicates.
        const list = gop.value_ptr;
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < node_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < items.len and items[lo] == node_id) return;
        try list.insert(self.allocator, lo, node_id);
    }

    /// Remove a node from a label's posting list.
    pub fn removeNode(self: *LabelIndex, label_id: LabelId, node_id: NodeId) void {
        const list = self.index.getPtr(label_id) orelse return;
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < node_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < items.len and items[lo] == node_id) {
            _ = list.orderedRemove(lo);
        }
    }

    /// Scan all node IDs for a label. Returns a copy (caller owns).
    pub fn scan(self: *const LabelIndex, label_id: LabelId, allocator: Allocator) ![]NodeId {
        const list = self.index.getPtr(label_id) orelse return try allocator.alloc(NodeId, 0);
        const result = try allocator.alloc(NodeId, list.items.len);
        @memcpy(result, list.items);
        return result;
    }

    /// Iterate node IDs for a label without copying the posting list.
    pub fn iterator(self: *const LabelIndex, label_id: LabelId) Iterator {
        const empty = &[_]NodeId{};
        const list = self.index.getPtr(label_id);
        return .{
            .items = if (list) |posting| posting.items else empty,
        };
    }

    /// Number of nodes with a given label.
    pub fn count(self: *const LabelIndex, label_id: LabelId) u64 {
        const list = self.index.getPtr(label_id) orelse return 0;
        return @intCast(list.items.len);
    }

    /// Rebuild the index from a node store by scanning all nodes.
    /// Uses page-level scanning to pin each page once instead of
    /// per-ID pin/unpin cycles (PERF-0012).
    pub fn rebuild(self: *LabelIndex, node_store: *NodeStore, max_node_id: NodeId) !void {
        // Clear existing data.
        self.clear();

        // Use page-scan to iterate all live nodes efficiently.
        try node_store.scanNodes(max_node_id, self, &rebuildCallback);
    }

    /// Persist the in-memory posting lists to labels.idx.
    /// Format:
    ///   [8 bytes magic][u64 checkpoint_counter][u64 label_count]
    ///   repeated label_count times:
    ///     [u32 label_id][u64 node_count][node_count * u64 node_id]
    pub fn saveToFile(self: *const LabelIndex, file: *std.fs.File, checkpoint_counter: u64) !void {
        try file.setEndPos(0);
        try file.seekTo(0);
        try index_snapshot_mod.writeHeader(file, SNAPSHOT_MAGIC, checkpoint_counter, self.index.count());

        var u32_buf: [4]u8 = undefined;
        var u64_buf: [8]u8 = undefined;

        var it = self.index.iterator();
        while (it.next()) |entry| {
            std.mem.writeInt(u32, &u32_buf, entry.key_ptr.*, .little);
            try file.writeAll(&u32_buf);

            std.mem.writeInt(u64, &u64_buf, entry.value_ptr.items.len, .little);
            try file.writeAll(&u64_buf);

            for (entry.value_ptr.items) |node_id| {
                std.mem.writeInt(u64, &u64_buf, node_id, .little);
                try file.writeAll(&u64_buf);
            }
        }
    }

    /// Load a previously persisted labels.idx snapshot.
    /// Returns the checkpoint counter embedded in the snapshot, or null when
    /// the file is empty.
    pub fn loadFromFile(self: *LabelIndex, file: *std.fs.File) !?u64 {
        var snapshot = (try index_snapshot_mod.loadFile(self.allocator, file, SNAPSHOT_MAGIC)) orelse return null;
        defer snapshot.deinit();

        self.clear();
        errdefer self.clear();

        const payload = snapshot.payload();
        var offset: usize = 0;

        var i: u64 = 0;
        const label_count = snapshot.item_count;
        while (i < label_count) : (i += 1) {
            if (offset + 12 > payload.len) return error.InvalidFormat;

            const label_id = std.mem.readInt(u32, payload[offset..][0..4], .little);
            offset += 4;

            const node_count = std.mem.readInt(u64, payload[offset..][0..8], .little);
            offset += 8;

            const gop = try self.index.getOrPut(label_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }

            try gop.value_ptr.ensureTotalCapacity(self.allocator, @intCast(node_count));

            var j: u64 = 0;
            while (j < node_count) : (j += 1) {
                if (offset + 8 > payload.len) return error.InvalidFormat;
                const node_id = std.mem.readInt(u64, payload[offset..][0..8], .little);
                offset += 8;
                gop.value_ptr.appendAssumeCapacity(node_id);
            }
        }

        if (offset != payload.len) return error.InvalidFormat;
        return snapshot.checkpoint_counter;
    }

    fn rebuildCallback(_: *LabelIndex, _: NodeId, _: node_mod.NodeRec) void {
        // No-op: label_head is a var.store reference requiring LabelStore +
        // allocator which the callback signature doesn't support.
        // The real rebuild is done by GraphEngine.rebuildLabelIndex() which
        // iterates nodes and reads labels via LabelStore directly.
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

    fn create() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const node_file = tmp_dir.dir.createFile("nodes.store", .{ .read = true, .truncate = true }) catch unreachable;
        var pool = try BufferPool.init(testing.allocator, 4096, 16);
        const fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
        return .{
            .pool = pool,
            .fsm = fsm,
            .tmp_dir = tmp_dir,
            .node_file = node_file,
            .node_pager = Pager.init(node_file, 4096),
        };
    }

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

test "addNode + scan returns the node" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 100);
    try idx.addNode(1, 200);

    const result = try idx.scan(1, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(NodeId, 100), result[0]);
    try testing.expectEqual(@as(NodeId, 200), result[1]);
}

test "removeNode + scan excludes the node" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 10);
    try idx.addNode(1, 20);
    try idx.addNode(1, 30);

    idx.removeNode(1, 20);

    const result = try idx.scan(1, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(NodeId, 10), result[0]);
    try testing.expectEqual(@as(NodeId, 30), result[1]);
}

test "large label — add 1000 nodes, scan returns all" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    // Insert in reverse order to exercise sorted insertion.
    var i: u64 = 1000;
    while (i > 0) {
        i -= 1;
        try idx.addNode(5, i);
    }

    const result = try idx.scan(5, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 1000), result.len);
    for (result, 0..) |v, j| {
        try testing.expectEqual(@as(NodeId, j), v);
    }
}

test "saveToFile + loadFromFile round-trip preserves posting lists" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 10);
    try idx.addNode(1, 20);
    try idx.addNode(2, 99);

    var file = try env.tmp_dir.dir.createFile("labels.idx", .{ .read = true, .truncate = true });
    defer file.close();

    try idx.saveToFile(&file, 42);

    var loaded = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer loaded.deinit();

    const checkpoint_counter = try loaded.loadFromFile(&file);
    try testing.expect(checkpoint_counter != null);
    try testing.expectEqual(@as(u64, 42), checkpoint_counter.?);

    const label_one = try loaded.scan(1, testing.allocator);
    defer testing.allocator.free(label_one);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{ 10, 20 }, label_one);

    const label_two = try loaded.scan(2, testing.allocator);
    defer testing.allocator.free(label_two);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{99}, label_two);
}

test "count returns correct value" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try testing.expectEqual(@as(u64, 0), idx.count(1));

    try idx.addNode(1, 10);
    try idx.addNode(1, 20);
    try idx.addNode(1, 30);

    try testing.expectEqual(@as(u64, 3), idx.count(1));

    idx.removeNode(1, 20);
    try testing.expectEqual(@as(u64, 2), idx.count(1));
}

test "addNode deduplication" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 42);
    try idx.addNode(1, 42);

    try testing.expectEqual(@as(u64, 1), idx.count(1));
}

test "scan on unknown label returns empty slice" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    const result = try idx.scan(999, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "rebuild from node store" {
    var env = try TestEnv.create();
    env.fixup();
    defer env.deinit();

    var store = NodeStore.init(&env.pool, &env.fsm, 4096);

    // Create some nodes (labels are now stored in var.store, not inline).
    try store.putNode(0, node_mod.NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    try store.putNode(1, node_mod.NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    // Rebuild is a no-op for label data (requires LabelStore for var.store reads).
    // Labels added at runtime via addNode() are tracked correctly.
    try idx.rebuild(&store, 2);

    // No labels populated from rebuild (var.store-backed labels need LabelStore).
    try testing.expectEqual(@as(u64, 0), idx.count(10));
    try testing.expectEqual(@as(u64, 0), idx.count(20));

    // Manually add entries to verify the index still works.
    try idx.addNode(10, 0);
    try idx.addNode(10, 1);
    try testing.expectEqual(@as(u64, 2), idx.count(10));
}

test {
    std.testing.refAllDecls(@This());
}
