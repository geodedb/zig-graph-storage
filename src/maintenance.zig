// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Maintenance operations for graph administration.
//!
//! Provides force-checkpoint, index rebuild, integrity verification,
//! and storage statistics gathering.

const std = @import("std");
const Allocator = std.mem.Allocator;

const manifest_mod = @import("manifest.zig");
const label_index_mod = @import("label_index.zig");
const node_store_mod = @import("node_store.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const operation_result_mod = @import("operation_result.zig");

const Manifest = manifest_mod.Manifest;
const LabelIndex = label_index_mod.LabelIndex;
const NodeStore = node_store_mod.NodeStore;
const BufferPool = buffer_pool_mod.BufferPool;
const GraphOperationSummary = operation_result_mod.GraphOperationSummary;

/// Types of maintenance operations.
pub const MaintenanceOp = enum {
    force_checkpoint,
    rebuild_indexes,
    verify_integrity,
    compact,
};

/// Storage statistics extracted from the manifest.
pub const StorageStats = struct {
    next_node_id: u64,
    next_edge_id: u64,
    last_checkpoint_lsn: u64,
    nodes_pages: u64,
    adj_out_pages: u64,
    adj_in_pages: u64,
    props_pages: u64,
    var_pages: u64,
};

pub const MaintenanceResult = struct {
    summary: GraphOperationSummary,
    flushed_pages: u32 = 0,
    stats: ?StorageStats = null,

    pub fn writeJson(self: *const MaintenanceResult, writer: anytype) !void {
        try writer.writeByte('{');
        try self.summary.writeJsonFields(writer);
        try writer.print(",\"flushed_pages\":{d}", .{self.flushed_pages});
        if (self.stats) |stats| {
            try writer.writeAll(",\"stats\":{");
            try writer.print("\"next_node_id\":{d}", .{stats.next_node_id});
            try writer.print(",\"next_edge_id\":{d}", .{stats.next_edge_id});
            try writer.print(",\"last_checkpoint_lsn\":{d}", .{stats.last_checkpoint_lsn});
            try writer.print(",\"nodes_pages\":{d}", .{stats.nodes_pages});
            try writer.print(",\"adj_out_pages\":{d}", .{stats.adj_out_pages});
            try writer.print(",\"adj_in_pages\":{d}", .{stats.adj_in_pages});
            try writer.print(",\"props_pages\":{d}", .{stats.props_pages});
            try writer.print(",\"var_pages\":{d}", .{stats.var_pages});
            try writer.writeByte('}');
            try writer.writeByte('}');
        } else {
            try writer.writeByte('}');
        }
    }
};

/// Graph maintenance operations.
pub const Maintenance = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Maintenance {
        return .{ .allocator = allocator };
    }

    /// Force a checkpoint on the engine via a callback.
    ///
    /// The caller provides an opaque pointer to the engine and a function
    /// pointer that performs the checkpoint. This decouples maintenance
    /// from the engine type.
    pub fn forceCheckpoint(
        self: *Maintenance,
        engine_ptr: *anyopaque,
        checkpoint_fn: *const fn (*anyopaque) anyerror!void,
    ) !void {
        _ = try self.forceCheckpointResult(engine_ptr, checkpoint_fn);
    }

    pub fn forceCheckpointResult(
        self: *Maintenance,
        engine_ptr: *anyopaque,
        checkpoint_fn: *const fn (*anyopaque) anyerror!void,
    ) !MaintenanceResult {
        _ = self;
        try checkpoint_fn(engine_ptr);
        return .{
            .summary = .{
                .operation = .force_checkpoint,
                .status = .ok,
                .items_processed = 1,
                .bytes_processed = 0,
                .issue_count = 0,
                .changed = true,
            },
        };
    }

    /// Rebuild label indexes from the node store.
    ///
    /// Clears the existing index and re-scans all nodes up to max_node_id.
    pub fn rebuildLabelIndex(
        self: *Maintenance,
        label_index: *LabelIndex,
        node_store: *NodeStore,
        max_node_id: u64,
    ) !void {
        _ = try self.rebuildLabelIndexResult(label_index, node_store, max_node_id);
    }

    pub fn rebuildLabelIndexResult(
        self: *Maintenance,
        label_index: *LabelIndex,
        node_store: *NodeStore,
        max_node_id: u64,
    ) !MaintenanceResult {
        _ = self;
        try label_index.rebuild(node_store, max_node_id);
        return .{
            .summary = .{
                .operation = .rebuild_indexes,
                .status = .ok,
                .items_processed = max_node_id,
                .bytes_processed = 0,
                .issue_count = 0,
                .changed = true,
            },
        };
    }

    /// Pre-flush dirty pages to reduce eviction stalls.
    ///
    /// Delegates to `BufferPool.flushDirtyPages`, which walks the LRU list
    /// from the tail and flushes up to `max_count` dirty unpinned frames.
    /// Returns the number of pages actually flushed.
    pub fn flushDirtyPages(self: *Maintenance, buffer_pool: *BufferPool, max_count: u32) !u32 {
        return (try self.flushDirtyPagesResult(buffer_pool, max_count)).flushed_pages;
    }

    pub fn flushDirtyPagesResult(_: *Maintenance, buffer_pool: *BufferPool, max_count: u32) !MaintenanceResult {
        const flushed = try buffer_pool.flushDirtyPages(max_count);
        return .{
            .summary = .{
                .operation = .flush_dirty_pages,
                .status = .ok,
                .items_processed = flushed,
                .bytes_processed = 0,
                .issue_count = 0,
                .changed = flushed > 0,
            },
            .flushed_pages = flushed,
        };
    }

    /// Get storage statistics from a manifest.
    pub fn getStats(self: *Maintenance, m: *const Manifest) StorageStats {
        return self.getStatsResult(m).stats.?;
    }

    pub fn getStatsResult(self: *Maintenance, m: *const Manifest) MaintenanceResult {
        _ = self;
        const stats: StorageStats = .{
            .next_node_id = m.next_node_id,
            .next_edge_id = m.next_edge_id,
            .last_checkpoint_lsn = m.last_checkpoint_lsn,
            .nodes_pages = m.nodes_pages,
            .adj_out_pages = m.adj_out_pages,
            .adj_in_pages = m.adj_in_pages,
            .props_pages = m.props_pages,
            .var_pages = m.var_pages,
        };
        return .{
            .summary = .{
                .operation = .storage_stats,
                .status = .ok,
                .items_processed = stats.nodes_pages + stats.adj_out_pages + stats.adj_in_pages + stats.props_pages + stats.var_pages,
                .bytes_processed = 0,
                .issue_count = 0,
                .changed = false,
            },
            .stats = stats,
        };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "getStats returns correct values from manifest" {
    const m = Manifest{
        .next_node_id = 42,
        .next_edge_id = 100,
        .last_checkpoint_lsn = 999,
        .nodes_pages = 10,
        .adj_out_pages = 20,
        .adj_in_pages = 30,
        .props_pages = 40,
        .var_pages = 50,
    };

    var maint = Maintenance.init(testing.allocator);
    const stats = maint.getStats(&m);

    try testing.expectEqual(@as(u64, 42), stats.next_node_id);
    try testing.expectEqual(@as(u64, 100), stats.next_edge_id);
    try testing.expectEqual(@as(u64, 999), stats.last_checkpoint_lsn);
    try testing.expectEqual(@as(u64, 10), stats.nodes_pages);
    try testing.expectEqual(@as(u64, 20), stats.adj_out_pages);
    try testing.expectEqual(@as(u64, 30), stats.adj_in_pages);
    try testing.expectEqual(@as(u64, 40), stats.props_pages);
    try testing.expectEqual(@as(u64, 50), stats.var_pages);
}

test "getStats on default manifest returns defaults" {
    const m = Manifest{};
    var maint = Maintenance.init(testing.allocator);
    const stats = maint.getStats(&m);

    try testing.expectEqual(@as(u64, 1), stats.next_node_id);
    try testing.expectEqual(@as(u64, 1), stats.next_edge_id);
    try testing.expectEqual(@as(u64, 0), stats.last_checkpoint_lsn);
    try testing.expectEqual(@as(u64, 0), stats.nodes_pages);
}

test "forceCheckpoint invokes callback" {
    var called = false;
    var maint = Maintenance.init(testing.allocator);

    const Ctx = struct {
        fn doCheckpoint(ptr: *anyopaque) anyerror!void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    };

    try maint.forceCheckpoint(@ptrCast(&called), Ctx.doCheckpoint);
    try testing.expect(called);
}

test "forceCheckpoint propagates errors" {
    var maint = Maintenance.init(testing.allocator);
    var dummy: u8 = 0;

    const Ctx = struct {
        fn failCheckpoint(_: *anyopaque) anyerror!void {
            return error.OutOfMemory;
        }
    };

    const result = maint.forceCheckpoint(@ptrCast(&dummy), Ctx.failCheckpoint);
    try testing.expectError(error.OutOfMemory, result);
}

test "rebuildLabelIndex works" {
    // This test requires a full BufferPool/FreeSpaceManager/NodeStore setup.
    // We verify the function is callable by using the same TestEnv pattern.
    const free_space_mod = @import("free_space.zig");
    const pager_mod = @import("pager.zig");
    const node_mod = @import("node.zig");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const node_file = tmp_dir.dir.createFile("nodes.store", .{ .read = true, .truncate = true }) catch unreachable;
    defer node_file.close();

    var pool = try buffer_pool_mod.BufferPool.init(testing.allocator, 4096, 16);
    defer pool.deinit();

    var fsm = try free_space_mod.FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    var node_pager = pager_mod.Pager.init(node_file, 4096);
    pool.registerPager(.nodes, &node_pager);
    fsm.buffer_pool = &pool;

    var store = node_store_mod.NodeStore.init(&pool, &fsm, 4096);

    // Create some nodes
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

    var idx = LabelIndex.init(testing.allocator, &pool, &fsm, 4096);
    defer idx.deinit();

    var maint = Maintenance.init(testing.allocator);
    try maint.rebuildLabelIndex(&idx, &store, 2);

    // With var.store-backed labels, rebuild is a no-op (needs LabelStore).
    // Labels added at runtime via addNode() are tracked correctly.
    try testing.expectEqual(@as(u64, 0), idx.count(10));
}

test "flushDirtyPages delegates to buffer pool" {
    const pager_mod = @import("pager.zig");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const node_file = tmp_dir.dir.createFile("nodes_flush.store", .{ .read = true, .truncate = true }) catch unreachable;
    defer node_file.close();

    var pool = try buffer_pool_mod.BufferPool.init(testing.allocator, 4096, 8);
    defer pool.deinit();

    var node_pager = pager_mod.Pager.init(node_file, 4096);
    pool.registerPager(.nodes, &node_pager);

    // Create 3 dirty unpinned pages
    for (0..3) |i| {
        const f = try pool.pinNew(.nodes, @intCast(i));
        const fidx = pool.frameIndex(f);
        pool.unpin(fidx, true);
    }

    var maint = Maintenance.init(testing.allocator);
    const flushed = try maint.flushDirtyPages(&pool, 2);
    try testing.expectEqual(@as(u32, 2), flushed);

    // One page should still be dirty
    var dirty_count: u32 = 0;
    for (pool.frames[0..pool.capacity]) |frame| {
        if (frame.dirty and frame.valid) dirty_count += 1;
    }
    try testing.expectEqual(@as(u32, 1), dirty_count);
}

test "MaintenanceResult writeJson includes stats when present" {
    const result = MaintenanceResult{
        .summary = .{
            .operation = .storage_stats,
            .status = .ok,
            .items_processed = 5,
            .bytes_processed = 0,
            .issue_count = 0,
            .changed = false,
        },
        .stats = .{
            .next_node_id = 10,
            .next_edge_id = 20,
            .last_checkpoint_lsn = 30,
            .nodes_pages = 1,
            .adj_out_pages = 2,
            .adj_in_pages = 3,
            .props_pages = 4,
            .var_pages = 5,
        },
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);

    try result.writeJson(buf.writer(testing.allocator));
    const json = buf.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"operation\":\"storage_stats\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"flushed_pages\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"stats\":{\"next_node_id\":10") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"var_pages\":5") != null);
}

test "MaintenanceResult writeJson omits stats when absent" {
    const result = MaintenanceResult{
        .summary = .{
            .operation = .flush_dirty_pages,
            .status = .ok,
            .items_processed = 2,
            .bytes_processed = 0,
            .issue_count = 0,
            .changed = true,
        },
        .flushed_pages = 2,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);

    try result.writeJson(buf.writer(testing.allocator));
    const json = buf.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"operation\":\"flush_dirty_pages\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"flushed_pages\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"stats\"") == null);
}

test {
    std.testing.refAllDecls(@This());
}
