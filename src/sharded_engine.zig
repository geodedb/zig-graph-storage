// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! ShardedGraphEngine — facade over N independent single-threaded
//! GraphEngine instances, one per shard. See
//! docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const engine_mod = @import("engine.zig");
const interface_mod = @import("interface.zig");
const shard_count_mod = @import("shard_count.zig");
const shard_manifest_mod = @import("shard_manifest.zig");
const shard_uuid_mod = @import("shard_uuid.zig");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const metrics_mod = @import("metrics.zig");
const adj_store_mod = @import("adj_store.zig");

const GraphConfig = config_mod.GraphConfig;
const GraphEngine = engine_mod.GraphEngine;
const GraphStorage = interface_mod.GraphStorage;
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const LabelId = types.LabelId;
const TxnId = types.TxnId;
const PropertyValue = types.PropertyValue;
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;
const Metrics = metrics_mod.Metrics;

pub const SHARD_COUNT = shard_count_mod.SHARD_COUNT;

pub const ShardedGraphEngine = struct {
    allocator: Allocator,
    graph_uuid: [16]u8,
    graph_root: []u8, // owned, "<data_dir>/<graph_uuid_hex>"
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: shard_manifest_mod.ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),

    pub fn create(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, self.graph_root);

        var per_shard: [SHARD_COUNT][16]u8 = undefined;
        for (&per_shard, 0..) |*u, s| {
            u.* = shard_uuid_mod.deriveShardUuid(graph_uuid, s);
        }

        self.shard_manifest = .{
            .version = shard_manifest_mod.SHARD_MANIFEST_VERSION,
            .shard_count = @intCast(SHARD_COUNT),
            .algorithm_hash = shard_manifest_mod.SHARD_ALGORITHM_HASH,
            .per_shard_uuids = per_shard,
        };

        try shard_manifest_mod.writeToDir(allocator, self.graph_root, self.shard_manifest);

        var created: usize = 0;
        errdefer for (self.shards[0..created]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            self.shards[s] = try GraphEngine.create(allocator, self.graph_root, per_shard[s], per_shard_cfg);
            created += 1;
        }

        return self;
    }

    pub fn open(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        self.shard_manifest = try shard_manifest_mod.readFromDir(allocator, self.graph_root);

        var opened: usize = 0;
        errdefer for (self.shards[0..opened]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            self.shards[s] = try GraphEngine.open(
                allocator,
                self.graph_root,
                self.shard_manifest.per_shard_uuids[s],
                per_shard_cfg,
            );
            opened += 1;
        }

        return self;
    }

    pub fn close(self: *ShardedGraphEngine) !void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.close() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
        if (first_err) |err| return err;
    }

    pub fn deinit(self: *ShardedGraphEngine) void {
        for (self.shards) |eng| eng.deinit();
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
    }

    pub fn getNode(self: *ShardedGraphEngine, id: NodeId) anyerror!?NodeRec {
        return self.shards[shard_count_mod.shardOfNode(id)].getNode(id);
    }

    pub fn putNode(self: *ShardedGraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(id)].putNode(id, rec);
    }

    pub fn allocNode(self: *ShardedGraphEngine) anyerror!NodeId {
        // Round-robin across shards so consumers that call allocNode in a
        // tight loop get balanced distribution. Deterministic routing keeps
        // tests reproducible.
        const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
        return self.shards[idx].allocNode();
    }

    pub fn deleteNode(self: *ShardedGraphEngine, id: NodeId) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(id)].deleteNode(id);
    }

    pub fn getEdge(self: *ShardedGraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
        // Edges live on their source node's shard. Edge id is shard-striped
        // (allocated on the source shard), so shardOfNode(edge_id) == source shard.
        return self.shards[shard_count_mod.shardOfNode(edge_id)].getEdge(edge_id);
    }

    pub fn expandOutIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!adj_store_mod.AdjStore.AdjEdgeIterator {
        return self.shards[shard_count_mod.shardOfNode(id)].expandOutIter(id, rel_type);
    }

    pub fn expandInIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!adj_store_mod.AdjStore.AdjEdgeIterator {
        // expandIn is intra-shard by construction — incoming adjacency
        // for node v lives in v's shard (§Cross-shard operations.2).
        return self.shards[shard_count_mod.shardOfNode(id)].expandInIter(id, rel_type);
    }

    pub fn getProperty(self: *ShardedGraphEngine, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        // Property chain heads live on the same shard as their owning node;
        // prop_head is itself shard-striped.
        return self.shards[shard_count_mod.shardOfNode(prop_head)].getProperty(prop_head, key, allocator);
    }

    pub fn nodeCount(self: *ShardedGraphEngine) anyerror!u64 {
        var total: u64 = 0;
        for (self.shards) |eng| total += try eng.nodeCount();
        return total;
    }

    pub fn edgeCount(self: *ShardedGraphEngine) anyerror!u64 {
        var total: u64 = 0;
        for (self.shards) |eng| total += try eng.edgeCount();
        return total;
    }
};

pub fn uuidHex(uuid: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (uuid, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

test {
    _ = @import("sharded_engine_test.zig");
}
