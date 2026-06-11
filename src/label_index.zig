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

// PERF-0054: posting lists backed by a hash set for O(1) add/remove/contains.
// scan() and iterator() materialise a sorted []NodeId on demand so callers
// that need ordered output (tests, snapshot round-trips) continue to work.
const NodeSet = std.AutoHashMapUnmanaged(NodeId, void);

// SEC-0051: v2 snapshot format appends a trailing CRC32 over the payload.
const SNAPSHOT_MAGIC = "GSLIDX2\x00";

// SEC-0044/SEC-0048: smallest bytes a single label record consumes on disk
// (label_id u32 + node_count u64, with zero nodes).
const LABEL_RECORD_MIN_SIZE: usize = 4 + 8;

// SEC-0044/SEC-0048: bytes a single node id consumes on disk.
const NODE_RECORD_SIZE: usize = 8;

/// Label posting lists — maps LabelId to membership sets of NodeId.
/// For v1, the posting lists are kept in memory and rebuilt from the
/// node store on startup.
pub const LabelIndex = struct {
    allocator: Allocator,
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    page_size: u32,

    /// In-memory index: LabelId -> set of NodeId (PERF-0054: O(1) add/remove).
    index: std.AutoHashMapUnmanaged(LabelId, NodeSet),

    /// Streaming iterator over a materialised, sorted posting list.
    /// The iterator owns the backing slice; call deinit() to release it.
    pub const Iterator = struct {
        items: []NodeId,
        pos: usize = 0,
        allocator: Allocator,

        pub fn next(self: *Iterator) !?NodeId {
            if (self.pos >= self.items.len) return null;
            defer self.pos += 1;
            return self.items[self.pos];
        }

        pub fn deinit(self: *Iterator) void {
            self.allocator.free(self.items);
            self.items = &.{};
        }
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
            .index = .empty,
        };
    }

    pub fn clear(self: *LabelIndex) void {
        var it = self.index.valueIterator();
        while (it.next()) |set| {
            @constCast(set).deinit(self.allocator);
        }
        self.index.clearAndFree(self.allocator);
    }

    pub fn deinit(self: *LabelIndex) void {
        self.clear();
        self.index.deinit(self.allocator);
    }

    /// Add a node to a label's posting list.  O(1) amortised; idempotent.
    pub fn addNode(self: *LabelIndex, label_id: LabelId, node_id: NodeId) !void {
        const gop = try self.index.getOrPut(self.allocator, label_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        _ = try gop.value_ptr.getOrPut(self.allocator, node_id);
    }

    /// Remove a node from a label's posting list.  O(1).
    pub fn removeNode(self: *LabelIndex, label_id: LabelId, node_id: NodeId) void {
        const set = self.index.getPtr(label_id) orelse return;
        _ = set.remove(node_id);
    }

    /// Scan all node IDs for a label. Returns a sorted, owned slice (caller frees).
    pub fn scan(self: *const LabelIndex, label_id: LabelId, allocator: Allocator) ![]NodeId {
        const set = self.index.getPtr(label_id) orelse return try allocator.alloc(NodeId, 0);
        const result = try allocator.alloc(NodeId, set.count());
        var i: usize = 0;
        var kit = set.keyIterator();
        while (kit.next()) |key| {
            result[i] = key.*;
            i += 1;
        }
        std.mem.sort(NodeId, result, {}, std.sort.asc(NodeId));
        return result;
    }

    /// Iterate node IDs for a label without a result-sized caller allocation.
    /// The returned Iterator owns its backing slice; call deinit() to release it.
    pub fn iterator(self: *const LabelIndex, label_id: LabelId, allocator: Allocator) !Iterator {
        const items = try self.scan(label_id, allocator);
        return .{
            .items = items,
            .pos = 0,
            .allocator = allocator,
        };
    }

    /// Number of nodes with a given label.
    pub fn count(self: *const LabelIndex, label_id: LabelId) u64 {
        const set = self.index.getPtr(label_id) orelse return 0;
        return set.count();
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
    pub fn saveToFile(self: *const LabelIndex, file: *std.Io.File, checkpoint_counter: u64) !void {
        // PERF-0052: serialize the whole snapshot into one in-memory buffer and
        // flush it with a single positional write instead of one syscall per
        // node id. Byte layout and trailing CRC32 (SEC-0051) are unchanged.
        var w = index_snapshot_mod.SnapshotWriter.init(self.allocator);
        defer w.deinit();

        try w.writeHeader(SNAPSHOT_MAGIC, checkpoint_counter, self.index.count());

        var it = self.index.iterator();
        while (it.next()) |entry| {
            try w.writeU32(entry.key_ptr.*);

            const set = entry.value_ptr;
            try w.writeU64(set.count());

            // Collect and sort node IDs for deterministic snapshot output.
            const sorted = try self.scan(entry.key_ptr.*, self.allocator);
            defer self.allocator.free(sorted);

            for (sorted) |node_id| {
                try w.writeU64(node_id);
            }
        }

        try w.finalize(file.*);
    }

    /// Load a previously persisted labels.idx snapshot.
    /// Returns the checkpoint counter embedded in the snapshot, or null when
    /// the file is empty.
    pub fn loadFromFile(self: *LabelIndex, file: *std.Io.File) !?u64 {
        // PERF-0052: read + validate the whole snapshot once (CRC32 per SEC-0051,
        // label_count bounded vs payload per SEC-0044/0048), then walk the
        // resident payload instead of one positional read per node id.
        var snapshot = (try index_snapshot_mod.loadPayload(self.allocator, file, SNAPSHOT_MAGIC, LABEL_RECORD_MIN_SIZE)) orelse return null;
        defer snapshot.deinit();

        self.clear();
        errdefer self.clear();

        var r = index_snapshot_mod.SnapshotReader.init(snapshot.payload());

        var i: u64 = 0;
        const label_count = snapshot.item_count;
        while (i < label_count) : (i += 1) {
            const label_id = try r.readU32();
            const node_count = try r.readU64();

            // SEC-0044/SEC-0048: bound the per-label posting-list reservation
            // against the bytes still available before reserving capacity.
            if (node_count > r.remaining() / NODE_RECORD_SIZE) return error.InvalidFormat;

            const gop = try self.index.getOrPut(self.allocator, label_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }

            try gop.value_ptr.ensureTotalCapacity(self.allocator, @intCast(node_count));

            var j: u64 = 0;
            while (j < node_count) : (j += 1) {
                const node_id = try r.readU64();
                try gop.value_ptr.put(self.allocator, node_id, {});
            }
        }

        if (r.remaining() != 0) return error.InvalidFormat;
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
const testing_support_mod = @import("testing_support.zig");
const SingleStoreEnv = testing_support_mod.SingleStoreEnv;

test "addNode + scan returns the node" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
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
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
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
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    // Insert in reverse order to exercise that scan always returns sorted output.
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

// PERF-0054: bulk add 5000 nodes to a single label, assert membership,
// remove a subset, assert correctness, assert idempotent re-add.
test "PERF-0054: bulk 5000-node label — add/remove/dedup correctness" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    const N = 5000;
    const label: LabelId = 42;

    // Bulk-add in reverse order; O(1) per insert with hash-set backing.
    var n: u64 = N;
    while (n > 0) {
        n -= 1;
        try idx.addNode(label, n);
    }

    try testing.expectEqual(@as(u64, N), idx.count(label));

    // scan() returns all nodes in sorted order.
    const all = try idx.scan(label, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, N), all.len);
    for (all, 0..) |v, j| {
        try testing.expectEqual(@as(NodeId, j), v);
    }

    // Idempotent re-add: count must not grow.
    try idx.addNode(label, 0);
    try idx.addNode(label, N - 1);
    try testing.expectEqual(@as(u64, N), idx.count(label));

    // Remove even-numbered nodes (half of N).
    var k: u64 = 0;
    while (k < N) : (k += 2) {
        idx.removeNode(label, k);
    }
    try testing.expectEqual(@as(u64, N / 2), idx.count(label));

    // Remaining nodes must all be odd and sorted.
    const remaining = try idx.scan(label, testing.allocator);
    defer testing.allocator.free(remaining);
    try testing.expectEqual(@as(usize, N / 2), remaining.len);
    for (remaining, 0..) |v, j| {
        try testing.expectEqual(@as(NodeId, j * 2 + 1), v);
    }

    // Remove of an absent node must be a no-op.
    idx.removeNode(label, 0); // already removed
    try testing.expectEqual(@as(u64, N / 2), idx.count(label));
}

// PERF-0054: snapshot round-trip with large posting list preserves contents.
test "PERF-0054: snapshot round-trip with large posting list" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    const N: u64 = 500;
    const label: LabelId = 7;

    var n: u64 = 0;
    while (n < N) : (n += 1) {
        try idx.addNode(label, n);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try env.tmp_dir.dir.createFile(io, "labels_perf.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    try idx.saveToFile(&file, 99);

    var loaded = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer loaded.deinit();

    const ctr = try loaded.loadFromFile(&file);
    try testing.expect(ctr != null);
    try testing.expectEqual(@as(u64, 99), ctr.?);

    try testing.expectEqual(@as(u64, N), loaded.count(label));

    const result = try loaded.scan(label, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, N), result.len);
    for (result, 0..) |v, j| {
        try testing.expectEqual(@as(NodeId, j), v);
    }
}

test "saveToFile + loadFromFile round-trip preserves posting lists" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 10);
    try idx.addNode(1, 20);
    try idx.addNode(2, 99);

    var file = try env.tmp_dir.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "labels.idx", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

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

// SEC-0044/SEC-0048: a tiny labels.idx that declares a huge label count must be
// rejected with error.InvalidFormat rather than driving a giant reservation.
test "loadFromFile rejects an oversized label_count (SEC-0044/0048)" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try env.tmp_dir.dir.createFile(io, "labels.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    var write_offset: u64 = 0;
    try index_snapshot_mod.writeHeader(file, &write_offset, SNAPSHOT_MAGIC, 1, std.math.maxInt(u64));
    try file.writePositionalAll(io, &[_]u8{0}, write_offset);
    write_offset += 1;
    try index_snapshot_mod.finalizeChecksum(testing.allocator, file, write_offset);

    var loaded = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer loaded.deinit();

    try testing.expectError(error.InvalidFormat, loaded.loadFromFile(&file));
}

// SEC-0044/SEC-0048: a valid label header but an absurd per-label node_count
// must be rejected before reserving the posting list.
test "loadFromFile rejects an oversized node_count (SEC-0044/0048)" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try env.tmp_dir.dir.createFile(io, "labels.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    var write_offset: u64 = 0;
    try index_snapshot_mod.writeHeader(file, &write_offset, SNAPSHOT_MAGIC, 1, 1);
    // One label: label_id=1, node_count=maxInt(u64) but no node bytes follow.
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    std.mem.writeInt(u64, buf[4..12], std.math.maxInt(u64), .little);
    try file.writePositionalAll(io, &buf, write_offset);
    write_offset += buf.len;
    try index_snapshot_mod.finalizeChecksum(testing.allocator, file, write_offset);

    var loaded = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer loaded.deinit();

    try testing.expectError(error.InvalidFormat, loaded.loadFromFile(&file));
}

// SEC-0051: flipping one payload byte (header intact) must be rejected as a
// checksum mismatch rather than silently loading corrupt data.
test "loadFromFile rejects a flipped payload byte (SEC-0051)" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 10);
    try idx.addNode(1, 20);

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try env.tmp_dir.dir.createFile(io, "labels.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    try idx.saveToFile(&file, 42);

    const payload_off: u64 = SNAPSHOT_MAGIC.len + index_snapshot_mod.HEADER_FIELDS_SIZE;
    var orig: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &orig, payload_off);
    const flipped: [1]u8 = .{orig[0] ^ 0xFF};
    try file.writePositionalAll(io, &flipped, payload_off);

    var loaded = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer loaded.deinit();

    try testing.expectError(error.ChecksumMismatch, loaded.loadFromFile(&file));
}

test "count returns correct value" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
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
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    try idx.addNode(1, 42);
    try idx.addNode(1, 42);

    try testing.expectEqual(@as(u64, 1), idx.count(1));
}

test "scan on unknown label returns empty slice" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
    defer env.deinit();

    var idx = LabelIndex.init(testing.allocator, &env.pool, &env.fsm, 4096);
    defer idx.deinit();

    const result = try idx.scan(999, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "rebuild from node store" {
    var env = try SingleStoreEnv.init(testing.allocator, .nodes, "nodes.store", 4096, 16);
    env.register();
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
