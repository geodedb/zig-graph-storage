// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! ShardedGraphEngine — facade over N independent single-threaded
//! GraphEngine instances, one per shard. See
//! docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md.

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thread_pool");
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
const label_index_mod = @import("label_index.zig");
const two_pc = @import("sharded_engine_2pc.zig");
const sharded_recovery = @import("sharded_recovery.zig");
const prop_store_mod = @import("prop_store.zig");

const GraphConfig = config_mod.GraphConfig;
const GraphEngine = engine_mod.GraphEngine;
const PropStore = prop_store_mod.PropStore;
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

// Encoded TxnId layout for the facade: high 8 bits = shard_index,
// low 56 bits = per-shard local txn id. Keeps the public TxnId shape
// a plain u64 so the GraphStorage vtable binding stays untouched.
const TXN_SHARD_SHIFT: u6 = 56;
const TXN_LOCAL_MASK: u64 = (@as(u64, 1) << 56) - 1;

fn encodeTxn(shard: usize, local: TxnId) TxnId {
    return (@as(TxnId, @intCast(shard)) << TXN_SHARD_SHIFT) | (local & TXN_LOCAL_MASK);
}

fn decodeTxn(txn: TxnId) struct { shard: usize, local: TxnId } {
    const shard = @as(usize, @intCast(txn >> TXN_SHARD_SHIFT));
    const local = txn & TXN_LOCAL_MASK;
    return .{ .shard = shard, .local = local };
}

pub const ShardedGraphEngine = struct {
    allocator: Allocator,
    graph_uuid: [16]u8,
    graph_root: []u8, // owned, "<data_dir>/<graph_uuid_hex>"
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: shard_manifest_mod.ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),
    aggregated_metrics: Metrics = .{},
    /// Shared across all sub-engines. Either points into
    /// `owned_shared_pool` (parent created it) or to a caller-supplied
    /// pool from `cfg.external_thread_pool`.
    shared_thread_pool: *tp.ThreadPool,
    /// Backing storage for the owned shared-pool path. `null` when the
    /// caller injected an external pool. Never reassigned after init.
    owned_shared_pool: ?tp.ThreadPool,

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

        // Init or borrow the shared thread pool BEFORE creating sub-engines.
        // The errdefer below is registered BEFORE the per-shard errdefer so
        // that Zig's LIFO ordering runs sub-engine closes first, then pool
        // teardown — never the other way around. Insert no errdefer between
        // these two registrations.
        self.owned_shared_pool = null;
        if (cfg.external_thread_pool) |ext| {
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                // One submitter slot per shard for THIS sharded graph.
                // Callers that share a single pool across N sharded graphs
                // must inject a pool with max_submitter_queues >= N *
                // SHARD_COUNT (the pool's hard cap is 64). See
                // GraphConfig.external_thread_pool docs and the design at
                // docs/2026-04-25-shared-engine-thread-pool.md §5.4.
                .max_submitter_queues = SHARD_COUNT,
                .max_threads = engine_mod.default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }
        errdefer if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        };

        var created: usize = 0;
        errdefer for (self.shards[0..created]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            per_shard_cfg.external_thread_pool = self.shared_thread_pool;
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

        // Init or borrow the shared thread pool BEFORE opening sub-engines.
        // The errdefer below is registered BEFORE the per-shard errdefer so
        // that Zig's LIFO ordering runs sub-engine closes first, then pool
        // teardown — never the other way around. Insert no errdefer between
        // these two registrations.
        self.owned_shared_pool = null;
        if (cfg.external_thread_pool) |ext| {
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                // One submitter slot per shard for THIS sharded graph.
                // Callers that share a single pool across N sharded graphs
                // must inject a pool with max_submitter_queues >= N *
                // SHARD_COUNT (the pool's hard cap is 64). See
                // GraphConfig.external_thread_pool docs and the design at
                // docs/2026-04-25-shared-engine-thread-pool.md §5.4.
                .max_submitter_queues = SHARD_COUNT,
                .max_threads = engine_mod.default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }
        errdefer if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        };

        var opened: usize = 0;
        errdefer for (self.shards[0..opened]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            per_shard_cfg.external_thread_pool = self.shared_thread_pool;
            self.shards[s] = try GraphEngine.open(
                allocator,
                self.graph_root,
                self.shard_manifest.per_shard_uuids[s],
                per_shard_cfg,
            );
            opened += 1;
        }

        _ = try sharded_recovery.reconcilePendingPrepares(self);

        return self;
    }

    pub fn close(self: *ShardedGraphEngine) !void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.close() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        // Tear down the owned shared pool ONLY after every sub-engine has
        // released its submitter slot and stopped submitting. Borrowed
        // pools (owned_shared_pool == null) belong to the caller.
        if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
        if (first_err) |err| return err;
    }

    pub fn deinit(self: *ShardedGraphEngine) void {
        for (self.shards) |eng| eng.deinit();
        if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        }
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

    fn crossShardAddEdge(
        self: *ShardedGraphEngine,
        from: NodeId,
        to: NodeId,
        rel_type: u32,
        s_from: usize,
        s_to: usize,
    ) !EdgeId {
        const src = self.shards[s_from];
        const dst = self.shards[s_to];

        // 1. Allocate edge id on source shard using its striped stride.
        //    Each per-shard engine already maintains next_edge_id so that
        //    allocated ids satisfy shardOfNode(id) == s_from (Task 4, with
        //    Task 8's shard-0 sentinel offset applied at init).
        const edge_id = src.manifest.next_edge_id;
        src.manifest.next_edge_id += @as(u64, @intCast(SHARD_COUNT));

        const global_txn_id = self.coordinator_txn_counter.fetchAdd(1, .monotonic) + 1;

        // 2. Prepare on both shards (durable before any data mutation).
        var src_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&src_prepare, global_txn_id, .source, @intCast(s_to), edge_id, from, to, rel_type);
        const src_local_txn = try src.beginTxn();
        _ = try two_pc.appendPrepare(src, src_prepare, src_local_txn);

        var dst_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&dst_prepare, global_txn_id, .target, @intCast(s_from), edge_id, from, to, rel_type);
        const dst_local_txn = try dst.beginTxn();
        _ = try two_pc.appendPrepare(dst, dst_prepare, dst_local_txn);

        // 3. Write source outgoing adjacency.
        var from_rec = try src.getNode(from) orelse return error.NodeNotFound;
        const out_entry = edge_mod.EdgeEntry{
            .neighbor = to,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
        };
        const new_out_head = try src.adj_out.addEdge(from_rec.out_head, out_entry);
        from_rec.out_head = new_out_head;
        try src.node_store.putNode(from, from_rec);
        try src.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = to,
            .rel_type = rel_type,
            .prop_head = 0,
        });

        // 4. Write target incoming adjacency.
        const in_entry = edge_mod.EdgeEntry{
            .neighbor = from,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
        };
        var to_rec = try dst.getNode(to) orelse return error.NodeNotFound;
        const new_in_head = try dst.adj_in.addEdge(to_rec.in_head, in_entry);
        to_rec.in_head = new_in_head;
        try dst.node_store.putNode(to, to_rec);

        // 5. Commit on both shards — WAL-durable before acknowledging.
        _ = try two_pc.appendDecision(src, .cross_shard_commit, global_txn_id, src_local_txn);
        _ = try two_pc.appendDecision(dst, .cross_shard_commit, global_txn_id, dst_local_txn);

        try src.commitTxn(src_local_txn);
        try dst.commitTxn(dst_local_txn);

        src.manifest.edge_count += 1;
        return edge_id;
    }

    pub fn addEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        const s_from = shard_count_mod.shardOfNode(from);
        const s_to = shard_count_mod.shardOfNode(to);
        if (s_from == s_to) return self.shards[s_from].addEdge(from, to, rel_type);
        return self.crossShardAddEdge(from, to, rel_type, s_from, s_to);
    }

    pub fn removeEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        const s_from = shard_count_mod.shardOfNode(from);
        const s_to = shard_count_mod.shardOfNode(to);
        if (s_from != s_to) return error.CrossShardEdgeUnsupported;
        return self.shards[s_from].removeEdge(from, to, edge_id);
    }

    pub fn putProperty(self: *ShardedGraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        // `owner == 0` means "create a new chain"; round-robin to a shard.
        if (owner == 0) {
            const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
            return self.shards[idx].putProperty(owner, key, val);
        }
        return self.shards[shard_count_mod.shardOfNode(owner)].putProperty(owner, key, val);
    }

    pub fn removeProperty(self: *ShardedGraphEngine, owner: u64, key: []const u8) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(owner)].removeProperty(owner, key);
    }

    pub fn getAllProperties(self: *ShardedGraphEngine, prop_head: u64) anyerror!PropStore.PropIterator {
        return self.shards[shard_count_mod.shardOfNode(prop_head)].getAllProperties(prop_head);
    }

    pub fn setEdgeProperty(self: *ShardedGraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, val: PropertyValue) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(from)].setEdgeProperty(from, to, edge_id, key, val);
    }

    pub fn removeEdgeProperty(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(from)].removeEdgeProperty(from, edge_id, key);
    }

    pub fn getEdgeProperty(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        return self.shards[shard_count_mod.shardOfNode(from)].getEdgeProperty(from, edge_id, key, allocator);
    }

    pub fn getAllEdgeProperties(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
        return self.shards[shard_count_mod.shardOfNode(from)].getAllEdgeProperties(from, edge_id);
    }

    pub fn addLabel(self: *ShardedGraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(node_id)].addLabel(node_id, label);
    }

    pub fn removeLabel(self: *ShardedGraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(node_id)].removeLabel(node_id, label);
    }

    pub fn scanLabel(self: *ShardedGraphEngine, label: LabelId, allocator: Allocator) anyerror![]NodeId {
        var out: std.ArrayList(NodeId) = .empty;
        errdefer out.deinit(allocator);
        for (self.shards) |eng| {
            const slice = try eng.scanLabel(label, allocator);
            defer allocator.free(slice);
            try out.appendSlice(allocator, slice);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Streaming fan-out iterator across all shards' label indexes.
    /// Two-argument form so `interface.GraphStorage.init` can bind it
    /// to the vtable via its `scanLabelIter(self, label)` detection.
    pub fn scanLabelIter(self: *ShardedGraphEngine, label: LabelId) !FanOutNodeIterator {
        return .{
            .owner = self,
            .label = label,
            .shard_idx = 0,
            .current = null,
        };
    }

    pub fn getOrAssignLabel(self: *ShardedGraphEngine, label_name: []const u8) !LabelId {
        // Label dictionary is global across shards: assign on shard 0 and
        // broadcast the mapping so every shard's label_dict.get agrees on
        // the id. Hot-path addLabel(node, id) is single-shard; this
        // broadcast only fires when a new name is registered.
        const id = try self.shards[0].getOrAssignLabel(label_name);
        for (self.shards[1..]) |eng| {
            _ = try eng.getOrAssignLabel(label_name);
        }
        return id;
    }

    pub fn beginTxn(self: *ShardedGraphEngine) anyerror!TxnId {
        const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
        const local = try self.shards[idx].beginTxn();
        return encodeTxn(idx, local);
    }

    pub fn commitTxn(self: *ShardedGraphEngine, txn: TxnId) anyerror!void {
        const d = decodeTxn(txn);
        return self.shards[d.shard].commitTxn(d.local);
    }

    pub fn abortTxn(self: *ShardedGraphEngine, txn: TxnId) anyerror!void {
        const d = decodeTxn(txn);
        return self.shards[d.shard].abortTxn(d.local);
    }

    pub fn checkpoint(self: *ShardedGraphEngine) anyerror!void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.checkpoint() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        if (first_err) |err| return err;
    }

    /// Aggregated metrics snapshot. Refreshes an internal buffer on each
    /// call and returns a pointer to it — valid until the next call.
    pub fn getMetrics(self: *ShardedGraphEngine) *const Metrics {
        self.aggregated_metrics = .{};
        inline for (std.meta.fields(Metrics)) |field| {
            if (@typeInfo(field.type) == .int) {
                var sum: field.type = 0;
                for (self.shards) |eng| {
                    sum += @field(eng.getMetrics().*, field.name);
                }
                @field(self.aggregated_metrics, field.name) = sum;
            }
        }
        return &self.aggregated_metrics;
    }

    /// Returns a GraphStorage vtable bound to this sharded engine, allowing
    /// external consumers (e.g. geode) to use ShardedGraphEngine through the
    /// standard GraphStorage interface with zero API changes.
    pub fn storage(self: *ShardedGraphEngine) GraphStorage {
        return GraphStorage.init(ShardedGraphEngine, self);
    }

    /// Drains expandOutIter into a caller-owned []EdgeEntry slice.
    pub fn expandOut(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        var iter = try self.expandOutIter(id, rel_type);
        defer iter.deinit();
        var list: std.ArrayList(EdgeEntry) = .empty;
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| try list.append(allocator, entry);
        return list.toOwnedSlice(allocator);
    }

    /// Drains expandInIter into a caller-owned []EdgeEntry slice.
    pub fn expandIn(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        var iter = try self.expandInIter(id, rel_type);
        defer iter.deinit();
        var list: std.ArrayList(EdgeEntry) = .empty;
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| try list.append(allocator, entry);
        return list.toOwnedSlice(allocator);
    }

    /// TEST-ONLY: issue both prepares for a cross-shard edge but never
    /// write the commit or abort record. Simulates a crash between 2PC
    /// steps 2 and 5 of `crossShardAddEdge`. Recovery reconciliation must
    /// abort the dangling prepares on reopen.
    pub fn addEdgeCrashAfterPrepares(
        self: *ShardedGraphEngine,
        from: NodeId,
        to: NodeId,
        rel_type: u32,
    ) !void {
        if (!builtin.is_test) return error.TestOnly;
        const s_from = shard_count_mod.shardOfNode(from);
        const s_to = shard_count_mod.shardOfNode(to);
        if (s_from == s_to) return error.NotCrossShard;

        const src = self.shards[s_from];
        const dst = self.shards[s_to];

        const edge_id = src.manifest.next_edge_id;
        src.manifest.next_edge_id += @as(u64, @intCast(SHARD_COUNT));

        const global_txn_id = self.coordinator_txn_counter.fetchAdd(1, .monotonic) + 1;

        var src_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&src_prepare, global_txn_id, .source, @intCast(s_to), edge_id, from, to, rel_type);
        const src_local_txn = try src.beginTxn();
        _ = try two_pc.appendPrepare(src, src_prepare, src_local_txn);

        var dst_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&dst_prepare, global_txn_id, .target, @intCast(s_from), edge_id, from, to, rel_type);
        const dst_local_txn = try dst.beginTxn();
        _ = try two_pc.appendPrepare(dst, dst_prepare, dst_local_txn);
        // Intentional crash simulation: txns are open but never committed.
    }

    /// TEST-ONLY: run through source-side adjacency + commit but crash
    /// before target adjacency or target commit. Recovery must replay
    /// the target-side write.
    pub fn addEdgeCrashAfterSourceCommit(
        self: *ShardedGraphEngine,
        from: NodeId,
        to: NodeId,
        rel_type: u32,
    ) !EdgeId {
        if (!builtin.is_test) return error.TestOnly;
        const s_from = shard_count_mod.shardOfNode(from);
        const s_to = shard_count_mod.shardOfNode(to);
        if (s_from == s_to) return error.NotCrossShard;
        const src = self.shards[s_from];
        const dst = self.shards[s_to];

        const edge_id = src.manifest.next_edge_id;
        src.manifest.next_edge_id += @as(u64, @intCast(SHARD_COUNT));

        const global_txn_id = self.coordinator_txn_counter.fetchAdd(1, .monotonic) + 1;

        var src_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&src_prepare, global_txn_id, .source, @intCast(s_to), edge_id, from, to, rel_type);
        const src_local_txn = try src.beginTxn();
        _ = try two_pc.appendPrepare(src, src_prepare, src_local_txn);

        var dst_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&dst_prepare, global_txn_id, .target, @intCast(s_from), edge_id, from, to, rel_type);
        const dst_local_txn = try dst.beginTxn();
        _ = try two_pc.appendPrepare(dst, dst_prepare, dst_local_txn);

        // Source-side adjacency + commit, skip target-side adjacency + commit.
        var from_rec = try src.getNode(from) orelse return error.NodeNotFound;
        const out_entry = edge_mod.EdgeEntry{
            .neighbor = to,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
        };
        const new_out_head = try src.adj_out.addEdge(from_rec.out_head, out_entry);
        from_rec.out_head = new_out_head;
        try src.node_store.putNode(from, from_rec);
        try src.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = to,
            .rel_type = rel_type,
            .prop_head = 0,
        });
        src.manifest.edge_count += 1;

        _ = try two_pc.appendDecision(src, .cross_shard_commit, global_txn_id, src_local_txn);
        try src.commitTxn(src_local_txn);

        // Intentional crash simulation: dst_local_txn is open but never committed.
        // dst_local_txn was passed to appendPrepare above so is already used.
        return edge_id;
    }
};

/// Streaming iterator across every shard's `LabelIndex` for a single
/// label. Advances one shard at a time; drops into the next shard's
/// inner iterator when the current one is exhausted. Value-typed so
/// `GraphStorage.init`'s `wrapNodeIterator` can heap-wrap it for the
/// vtable automatically.
pub const FanOutNodeIterator = struct {
    owner: *ShardedGraphEngine,
    label: LabelId,
    shard_idx: usize,
    current: ?label_index_mod.LabelIndex.Iterator,

    pub fn next(self: *FanOutNodeIterator) anyerror!?NodeId {
        while (true) {
            if (self.current) |*inner| {
                if (try inner.next()) |nid| return nid;
                // Exhausted — release the owned posting-list slice (PERF-0054).
                inner.deinit();
                self.current = null;
            }
            if (self.shard_idx >= SHARD_COUNT) return null;
            self.current = try self.owner.shards[self.shard_idx].scanLabelIter(self.label);
            self.shard_idx += 1;
        }
    }

    pub fn deinit(self: *FanOutNodeIterator) void {
        // Release the active shard's owned posting-list slice if iteration
        // was abandoned before the iterator was exhausted (PERF-0054).
        if (self.current) |*inner| inner.deinit();
        self.current = null;
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
