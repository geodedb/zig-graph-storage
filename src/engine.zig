// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const spice = @import("spice");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const config_mod = @import("config.zig");
const interface_mod = @import("interface.zig");
const manifest_mod = @import("manifest.zig");
const graph_dir_mod = @import("graph_dir.zig");
const file_manager_mod = @import("file_manager.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const wal_mod = @import("wal.zig");
const txn_mod = @import("txn.zig");
const node_store_mod = @import("node_store.zig");
const adj_store_mod = @import("adj_store.zig");
const prop_store_mod = @import("prop_store.zig");
const var_store_mod = @import("var_store.zig");
const free_space_mod = @import("free_space.zig");
const label_dict_mod = @import("label_dict.zig");
const checkpoint_mod = @import("checkpoint.zig");
const recovery_mod = @import("recovery.zig");
const label_index_mod = @import("label_index.zig");
const property_chain_index_mod = @import("property_chain_index.zig");
const label_store_mod = @import("label_store.zig");
const metrics_mod = @import("metrics.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const engine_edge_props = @import("engine_edge_props.zig");
const engine_integrity = @import("engine_integrity.zig");
const engine_index = @import("engine_index.zig");
const engine_persist = @import("engine_persist.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const TxnId = types.TxnId;
const LabelId = types.LabelId;
const FileId = types.FileId;
const PropertyValue = types.PropertyValue;
const GraphConfig = config_mod.GraphConfig;
const GraphStorage = interface_mod.GraphStorage;
const Manifest = manifest_mod.Manifest;
const GraphDir = graph_dir_mod.GraphDir;
const FileManager = file_manager_mod.FileManager;
const BufferPool = buffer_pool_mod.BufferPool;
const WalManager = wal_mod.WalManager;
const TxnManager = txn_mod.TxnManager;
const NodeStore = node_store_mod.NodeStore;
const AdjStore = adj_store_mod.AdjStore;
const PropStore = prop_store_mod.PropStore;
const VarStore = var_store_mod.VarStore;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const LabelDictionary = label_dict_mod.LabelDictionary;
const Checkpointer = checkpoint_mod.Checkpointer;
const Recovery = recovery_mod.Recovery;
const LabelIndex = label_index_mod.LabelIndex;
const PropertyChainIndex = property_chain_index_mod.PropertyChainIndex;
const LabelStore = label_store_mod.LabelStore;
const Metrics = metrics_mod.Metrics;
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;

/// In-memory index entry for O(1) edge lookup by EdgeId.
pub const EdgeIndexEntry = struct {
    from: NodeId,
    neighbor: NodeId,
    rel_type: u32,
    prop_head: u32,
};

/// The central GraphEngine that wires everything together and implements
/// the GraphStorage vtable.
///
/// The engine owns all component structs and coordinates their interactions.
/// It supports creating new graphs and opening existing ones with crash recovery.
pub const GraphEngine = struct {
    allocator: Allocator,
    config: GraphConfig,
    graph_uuid: [16]u8,
    graph_dir: GraphDir,
    file_manager: FileManager,
    buffer_pool: BufferPool,
    wal: WalManager,
    txn_manager: TxnManager,
    node_store: NodeStore,
    adj_out: AdjStore,
    adj_in: AdjStore,
    prop_store: PropStore,
    var_store: VarStore,
    free_space_nodes: FreeSpaceManager,
    free_space_adj_out: FreeSpaceManager,
    free_space_adj_in: FreeSpaceManager,
    free_space_props: FreeSpaceManager,
    free_space_var: FreeSpaceManager,
    label_dict: LabelDictionary,
    label_store: LabelStore,
    label_index: LabelIndex,
    property_index: PropertyChainIndex,
    edge_index: std.AutoHashMap(EdgeId, EdgeIndexEntry),
    checkpointer: Checkpointer,
    manifest: Manifest,
    wal_dir_handle: std.fs.Dir,
    thread_pool: spice.ThreadPool,
    metrics: Metrics = .{},

    /// Create a new graph.
    pub fn create(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, cfg: GraphConfig) !*GraphEngine {
        const self = try allocator.create(GraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.config = cfg;
        self.graph_uuid = graph_uuid;

        // 1. Create graph directory
        self.graph_dir = try GraphDir.create(allocator, data_dir, graph_uuid);
        errdefer self.graph_dir.deinit();

        // 2. Init manifest with defaults
        self.manifest = Manifest{
            .graph_uuid = graph_uuid,
            .page_size = cfg.page_size,
            .counter = 0,
            .last_checkpoint_lsn = 0,
            .next_node_id = 1,
            .next_edge_id = 1,
            .next_txn_id = 1,
        };

        // 3. Write initial manifest to slot A
        const path_a = try self.graph_dir.manifestPath(allocator, .a);
        defer allocator.free(path_a);
        try self.manifest.writeToFile(allocator, path_a);

        // 4. Open all store files via FileManager
        self.file_manager = FileManager.init(allocator, self.graph_dir.path, cfg.page_size);
        self.file_manager.encryption_key = cfg.encryption_key;
        _ = try self.file_manager.openFile(.nodes);
        _ = try self.file_manager.openFile(.adj_out);
        _ = try self.file_manager.openFile(.adj_in);
        _ = try self.file_manager.openFile(.props);
        _ = try self.file_manager.openFile(.var_store);
        _ = try self.file_manager.openFile(.free);
        _ = try self.file_manager.openFile(.label_idx);
        _ = try self.file_manager.openFile(.prop_idx);

        // 5. Create buffer pool, register pagers
        self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, cfg.buffer_pool_pages);
        errdefer self.buffer_pool.deinit();
        if (self.file_manager.getPager(.nodes)) |p| self.buffer_pool.registerPager(.nodes, p);
        if (self.file_manager.getPager(.adj_out)) |p| self.buffer_pool.registerPager(.adj_out, p);
        if (self.file_manager.getPager(.adj_in)) |p| self.buffer_pool.registerPager(.adj_in, p);
        if (self.file_manager.getPager(.props)) |p| self.buffer_pool.registerPager(.props, p);
        if (self.file_manager.getPager(.var_store)) |p| self.buffer_pool.registerPager(.var_store, p);
        if (self.file_manager.getPager(.free)) |p| self.buffer_pool.registerPager(.free, p);

        // 6. Init all shared subsystems (free space, WAL, txn, stores, labels, checkpointer)
        try self.initSubsystems(allocator, graph_uuid, cfg, 0);

        // 7. Wire metrics and thread pool into buffer pool
        self.metrics = .{};
        self.wireMetricsCounters();
        self.buffer_pool.setMetrics(&self.metrics);
        self.thread_pool = spice.ThreadPool.init(allocator);
        self.thread_pool.start(.{});
        self.buffer_pool.setThreadPool(&self.thread_pool);

        return self;
    }

    /// Open an existing graph (with recovery).
    pub fn open(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, cfg: GraphConfig) !*GraphEngine {
        const self = try allocator.create(GraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.config = cfg;
        self.graph_uuid = graph_uuid;

        // 1. Open graph directory
        self.graph_dir = try GraphDir.open(allocator, data_dir, graph_uuid);
        errdefer self.graph_dir.deinit();

        // 2. Open store files
        self.file_manager = FileManager.init(allocator, self.graph_dir.path, cfg.page_size);
        self.file_manager.encryption_key = cfg.encryption_key;

        // 3. Create buffer pool
        self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, cfg.buffer_pool_pages);
        errdefer self.buffer_pool.deinit();

        // 4. Run recovery (loads manifest, replays WAL)
        var recovery = Recovery.init(allocator, cfg.encryption_key);
        defer recovery.deinit();
        self.manifest = try recovery.recover(&self.graph_dir, &self.buffer_pool, &self.file_manager);

        _ = try self.file_manager.openFile(.label_idx);
        _ = try self.file_manager.openFile(.prop_idx);

        // SEC-0010: Validate page_size matches manifest after recovery
        if (cfg.page_size != self.manifest.page_size) {
            return error.PageSizeMismatch;
        }

        // PERF-0008: Auto-size buffer pool based on manifest page counts
        const total_pages = self.manifest.nodes_pages +
            self.manifest.adj_out_pages +
            self.manifest.adj_in_pages +
            self.manifest.props_pages +
            self.manifest.var_pages +
            self.manifest.free_pages;
        const effective = cfg.effectiveBufferPoolPages(total_pages);
        if (effective > self.buffer_pool.capacity) {
            // Re-create buffer pool with larger capacity, re-register pagers
            self.buffer_pool.deinit();
            self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, effective);
            if (self.file_manager.getPager(.nodes)) |p| self.buffer_pool.registerPager(.nodes, p);
            if (self.file_manager.getPager(.adj_out)) |p| self.buffer_pool.registerPager(.adj_out, p);
            if (self.file_manager.getPager(.adj_in)) |p| self.buffer_pool.registerPager(.adj_in, p);
            if (self.file_manager.getPager(.props)) |p| self.buffer_pool.registerPager(.props, p);
            if (self.file_manager.getPager(.var_store)) |p| self.buffer_pool.registerPager(.var_store, p);
            if (self.file_manager.getPager(.free)) |p| self.buffer_pool.registerPager(.free, p);
        }

        // 5. Init all shared subsystems (free space, WAL, txn, stores, labels, checkpointer)
        try self.initSubsystems(allocator, graph_uuid, cfg, self.manifest.last_checkpoint_lsn);

        // 5b. Restore free space bitmaps. Prefer the persisted free.store
        // file which accurately tracks freed pages. Fall back to rebuilding
        // from on-disk file sizes (lossy — freed pages appear allocated).
        const loaded_free_store = try self.loadFreeStore();
        if (!loaded_free_store) {
            try self.rebuildFreeSpaceFromDisk();
        }

        // 6. Load persisted label dictionary if it exists
        const labels_path = try std.fmt.allocPrint(allocator, "{s}/labels.dict", .{self.graph_dir.path});
        defer allocator.free(labels_path);
        self.label_dict.loadFromFile(labels_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Expected on fresh graphs
            else => return err,
        };

        // 7. Load persisted derived indexes when they match the active
        // checkpoint. Otherwise rebuild from the primary stores.
        const loaded_indexes = self.tryLoadDerivedIndexes() catch false;
        if (!loaded_indexes) {
            try self.rebuildDerivedIndexes();
        } else {
            // Edge index is in-memory only (no persistence) so always rebuild
            try self.rebuildEdgeIndex();
        }

        // 8. Wire metrics and thread pool into buffer pool
        self.metrics = .{};
        self.wireMetricsCounters();
        self.buffer_pool.setMetrics(&self.metrics);
        self.thread_pool = spice.ThreadPool.init(allocator);
        self.thread_pool.start(.{});
        self.buffer_pool.setThreadPool(&self.thread_pool);

        return self;
    }

    fn initSubsystems(self: *GraphEngine, allocator: Allocator, graph_uuid: [16]u8, cfg: GraphConfig, wal_start_lsn: u64) !void {
        return engine_persist.initSubsystems(self, allocator, graph_uuid, cfg, wal_start_lsn);
    }

    /// GAP-0026: Wire metrics counters that were previously TODO stubs.
    fn wireMetricsCounters(self: *GraphEngine) void {
        // wal_segment_count: single-file WAL always has 1 segment.
        self.metrics.wal_segment_count = 1;

        // fragmentation_ratio: fraction of allocated-but-unused pages across
        // all stores, as fixed-point x10000.
        const total = self.free_space_nodes.total_pages +
            self.free_space_adj_out.total_pages +
            self.free_space_adj_in.total_pages +
            self.free_space_props.total_pages +
            self.free_space_var.total_pages;
        if (total > 0) {
            const free = self.free_space_nodes.freeCount() +
                self.free_space_adj_out.freeCount() +
                self.free_space_adj_in.freeCount() +
                self.free_space_props.freeCount() +
                self.free_space_var.freeCount();
            self.metrics.fragmentation_ratio = (free * 10000) / total;
        }

        // index_rebuild_progress: 10000 = 100% (rebuild complete).
        self.metrics.index_rebuild_progress = 10000;
    }

    // ── Persistence helpers (delegated to engine_persist.zig) ─────────

    fn saveFreeStore(self: *GraphEngine) !void {
        return engine_persist.saveFreeStore(self);
    }

    fn loadFreeStore(self: *GraphEngine) !bool {
        return engine_persist.loadFreeStore(self);
    }

    fn rebuildFreeSpaceFromDisk(self: *GraphEngine) !void {
        return engine_persist.rebuildFreeSpaceFromDisk(self);
    }

    // ── Index operations (delegated to engine_index.zig) ──────────────

    pub fn refreshPropertyChainIndex(self: *GraphEngine, prop_head: u64) !void {
        if (prop_head == 0) {
            return;
        }

        var iter = self.prop_store.getAllProperties(prop_head);
        defer iter.deinit();
        try self.property_index.refreshFromIterator(prop_head, &iter);
    }

    fn rebuildDerivedIndexes(self: *GraphEngine) !void {
        return engine_index.rebuildDerivedIndexes(self);
    }

    fn rebuildEdgeIndex(self: *GraphEngine) !void {
        return engine_index.rebuildEdgeIndex(self);
    }

    fn tryLoadDerivedIndexes(self: *GraphEngine) !bool {
        return engine_index.tryLoadDerivedIndexes(self);
    }

    fn saveDerivedIndexes(self: *GraphEngine) !void {
        return engine_index.saveDerivedIndexes(self);
    }

    fn saveLabelDictionary(self: *GraphEngine) !void {
        return engine_persist.saveLabelDictionary(self);
    }

    /// Clean up the graph engine and its storage resources.
    pub fn deinit(self: *GraphEngine) void {
        self.cleanupResources(self.allocator);
    }

    /// Close the engine (flush, checkpoint, close files).
    ///
    /// Returns an error if the final checkpoint or label dictionary save fails.
    /// Resources are always cleaned up regardless of errors.
    pub fn close(self: *GraphEngine) !void {
        const allocator = self.allocator;

        // Persist current state
        self.manifest.next_txn_id = self.txn_manager.next_txn_id;
        self.manifest.label_count = self.label_dict.count();

        // Track the first error encountered during close
        var close_err: ?anyerror = null;

        // Run a final synchronous checkpoint -- propagate errors
        self.checkpointer.doCheckpoint() catch |err| {
            close_err = err;
        };

        if (close_err == null) {
            self.saveFreeStore() catch |err| {
                if (close_err == null) close_err = err;
            };
        }
        if (close_err == null) {
            self.saveDerivedIndexes() catch |err| {
                if (close_err == null) close_err = err;
            };
        }

        self.saveLabelDictionary() catch |err| {
            if (close_err == null) close_err = err;
        };

        // Cleanup all resources (always runs)
        self.cleanupResources(allocator);

        // Return the first error encountered
        if (close_err) |err| return err;
    }

    /// Internal cleanup of all engine resources. Always runs on close,
    /// even when errors have occurred.
    fn cleanupResources(self: *GraphEngine, allocator: Allocator) void {
        self.thread_pool.deinit();
        self.txn_manager.deinit();
        self.wal.deinit();
        self.wal_dir_handle.close();
        self.free_space_nodes.deinit();
        self.free_space_adj_out.deinit();
        self.free_space_adj_in.deinit();
        self.free_space_props.deinit();
        self.free_space_var.deinit();
        self.label_dict.deinit();
        self.label_index.deinit();
        self.property_index.deinit();
        self.edge_index.deinit();
        self.buffer_pool.deinit();
        self.file_manager.deinit();
        self.graph_dir.deinit();

        // SEC-0003: Zero encryption key material before freeing memory
        self.config.zeroKey();

        allocator.destroy(self);
    }

    /// Get a GraphStorage interface backed by this engine.
    pub fn storage(self: *GraphEngine) GraphStorage {
        return GraphStorage.init(GraphEngine, self);
    }

    // ── Integrity and stats (delegated to engine_integrity.zig) ────────

    pub const StorageStats = engine_integrity.StorageStats;
    pub const IntegrityReport = engine_integrity.IntegrityReport;

    pub fn getMetrics(self: *GraphEngine) *const Metrics {
        return engine_integrity.getMetrics(self);
    }

    pub fn getStorageStats(self: *GraphEngine) StorageStats {
        return engine_integrity.getStorageStats(self);
    }

    pub fn checkIntegrity(self: *GraphEngine) IntegrityReport {
        return engine_integrity.checkIntegrity(self);
    }

    // ========================================================================
    // Internal: WAL page logging helper
    // ========================================================================

    /// Pin a page, log its current contents to the WAL, and unpin it.
    fn logPage(self: *GraphEngine, txn_id: u64, file_id: FileId, page_id: u64) anyerror!void {
        const frame = try self.buffer_pool.pin(file_id, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        defer self.buffer_pool.unpin(frame_idx, false);
        _ = try self.txn_manager.logPageUpdate(txn_id, @intFromEnum(file_id), page_id, frame.dataSlice());
    }

    /// Compute the page ID for a given node ID.
    fn nodePageId(self: *const GraphEngine, node_id: NodeId) u64 {
        return node_id / self.node_store.nodes_per_page;
    }

    // ========================================================================
    // VTable implementation methods (called via GraphStorage interface)
    // ========================================================================

    pub fn getNode(self: *GraphEngine, id: NodeId) anyerror!?NodeRec {
        return self.node_store.getNode(id);
    }

    /// Put a node within an existing transaction (no auto-commit).
    pub fn putNodeTxn(self: *GraphEngine, id: NodeId, rec: NodeRec, txn: TxnId) anyerror!void {
        try self.node_store.putNode(id, rec);
        try self.logPage(txn, .nodes, self.nodePageId(id));
    }

    /// Put a node with auto-commit (backward compatible).
    pub fn putNode(self: *GraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.putNodeTxn(id, rec, txn);

        try self.txn_manager.commit(txn);
    }

    pub fn allocNode(self: *GraphEngine) anyerror!NodeId {
        const id = self.manifest.next_node_id;
        self.manifest.next_node_id += 1;
        self.manifest.node_count += 1;
        self.metrics.nodes_created += 1;
        return id;
    }

    /// Delete a node within an existing transaction (no auto-commit).
    pub fn deleteNodeTxn(self: *GraphEngine, id: NodeId, txn: TxnId) anyerror!void {
        try self.node_store.deleteNode(id);
        try self.logPage(txn, .nodes, self.nodePageId(id));

        if (self.manifest.node_count > 0) {
            self.manifest.node_count -= 1;
        }
        self.metrics.nodes_deleted += 1;
    }

    /// Delete a node with auto-commit (backward compatible).
    pub fn deleteNode(self: *GraphEngine, id: NodeId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.deleteNodeTxn(id, txn);

        try self.txn_manager.commit(txn);
    }

    /// Look up an edge by its ID using the in-memory edge index.
    /// Returns the EdgeEntry if found, null otherwise.
    pub fn getEdge(self: *GraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
        const entry = self.edge_index.get(edge_id) orelse return null;
        return EdgeEntry{
            .neighbor = entry.neighbor,
            .edge_id = edge_id,
            .rel_type = entry.rel_type,
            .prop_head = entry.prop_head,
        };
    }

    pub fn expandOut(self: *GraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        const rec = try self.node_store.getNode(id);
        var iter = self.adj_out.expand(if (rec) |r| r.out_head else 0, rel_type);
        defer iter.deinit();
        return drainEdgeIterator(&iter, allocator);
    }

    pub fn expandIn(self: *GraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        const rec = try self.node_store.getNode(id);
        var iter = self.adj_in.expand(if (rec) |r| r.in_head else 0, rel_type);
        defer iter.deinit();
        return drainEdgeIterator(&iter, allocator);
    }

    /// Drain an AdjEdgeIterator into a heap-allocated slice.
    fn drainEdgeIterator(iter: *AdjStore.AdjEdgeIterator, allocator: Allocator) anyerror![]EdgeEntry {
        var list = try std.ArrayList(EdgeEntry).initCapacity(allocator, 16);
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| {
            try list.append(allocator, entry);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Add an edge within an existing transaction (no auto-commit).
    pub fn addEdgeTxn(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32, txn: TxnId) anyerror!EdgeId {
        const edge_id = self.manifest.next_edge_id;
        self.manifest.next_edge_id += 1;

        const entry = EdgeEntry{
            .neighbor = to,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
        };

        // Update source node's out adjacency list
        var from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        const new_out_head = try self.adj_out.addEdge(from_rec.out_head, entry);
        from_rec.out_head = new_out_head;
        try self.node_store.putNode(from, from_rec);

        // Update target node's in adjacency list
        const in_entry = EdgeEntry{
            .neighbor = from,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
        };
        var to_rec = try self.node_store.getNode(to) orelse return error.NodeNotFound;
        const new_in_head = try self.adj_in.addEdge(to_rec.in_head, in_entry);
        to_rec.in_head = new_in_head;
        try self.node_store.putNode(to, to_rec);

        // Log all dirty pages: adj_out page, adj_in page, from-node page, to-node page
        try self.logPage(txn, .adj_out, new_out_head);
        try self.logPage(txn, .adj_in, new_in_head);
        try self.logPage(txn, .nodes, self.nodePageId(from));
        // Avoid duplicate log if from and to share the same node page
        const to_page = self.nodePageId(to);
        if (to_page != self.nodePageId(from)) {
            try self.logPage(txn, .nodes, to_page);
        }

        // Maintain in-memory edge index for O(1) getEdge lookups
        try self.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = to,
            .rel_type = rel_type,
            .prop_head = 0,
        });

        self.manifest.edge_count += 1;
        self.metrics.edges_created += 1;

        return edge_id;
    }

    /// Add an edge with auto-commit (backward compatible).
    pub fn addEdge(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        const edge_id = try self.addEdgeTxn(from, to, rel_type, txn);

        try self.txn_manager.commit(txn);

        return edge_id;
    }

    /// Remove an edge within an existing transaction (no auto-commit).
    pub fn removeEdgeTxn(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, txn: TxnId) anyerror!void {
        // Remove from source node's out adjacency list
        const from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        try self.adj_out.removeEdge(from_rec.out_head, edge_id);

        // Remove from target node's in adjacency list
        const to_rec = try self.node_store.getNode(to) orelse return error.NodeNotFound;
        try self.adj_in.removeEdge(to_rec.in_head, edge_id);

        // Log dirty adjacency pages
        if (from_rec.out_head != 0) try self.logPage(txn, .adj_out, from_rec.out_head);
        if (to_rec.in_head != 0) try self.logPage(txn, .adj_in, to_rec.in_head);

        // Remove from in-memory edge index
        _ = self.edge_index.remove(edge_id);

        if (self.manifest.edge_count > 0) {
            self.manifest.edge_count -= 1;
        }
        self.metrics.edges_removed += 1;
    }

    /// Remove an edge with auto-commit (backward compatible).
    pub fn removeEdge(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.removeEdgeTxn(from, to, edge_id, txn);

        try self.txn_manager.commit(txn);
    }

    pub fn getProperty(self: *GraphEngine, prop_head: u64, key: []const u8, alloc: Allocator) anyerror!?PropertyValue {
        self.metrics.properties_read += 1;
        if (prop_head == 0) return null;
        if (self.property_index.containsChain(prop_head) and !self.property_index.hasKey(prop_head, key)) {
            return null;
        }
        return self.prop_store.getProperty(prop_head, key, alloc);
    }

    pub fn getAllProperties(self: *GraphEngine, prop_head: u64) anyerror!PropStore.PropIterator {
        return self.prop_store.getAllProperties(prop_head);
    }

    /// Put a property within an existing transaction (no auto-commit).
    pub fn putPropertyTxn(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue, txn: TxnId) anyerror!u64 {
        const new_head = try self.prop_store.putProperty(owner, key, val);

        // Log the property page that was written to
        try self.logPage(txn, .props, new_head);

        if (owner != 0 and owner != new_head) {
            self.property_index.removeChain(owner);
        }
        try self.refreshPropertyChainIndex(new_head);

        self.metrics.properties_written += 1;
        return new_head;
    }

    /// Put a property with auto-commit (backward compatible).
    pub fn putProperty(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        const new_head = try self.putPropertyTxn(owner, key, val, txn);

        try self.txn_manager.commit(txn);

        return new_head;
    }

    pub fn removeProperty(self: *GraphEngine, owner: u64, key: []const u8) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.prop_store.removeProperty(owner, key);

        // Log the property page if there is one
        if (owner != 0) try self.logPage(txn, .props, owner);

        try self.txn_manager.commit(txn);

        try self.refreshPropertyChainIndex(owner);
    }

    /// Add a label within an existing transaction (no auto-commit).
    pub fn addLabelTxn(self: *GraphEngine, node_id: NodeId, label: LabelId, txn: TxnId) anyerror!void {
        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        const result = try self.label_store.addLabel(rec.label_head, label, self.allocator);
        if (result.count != rec.label_count or result.head != rec.label_head) {
            rec.label_head = result.head;
            rec.label_count = result.count;
            try self.node_store.putNode(node_id, rec);

            // Log dirty pages: the var_store page holding the label block, and the node page
            try self.logPage(txn, .var_store, result.head);
            try self.logPage(txn, .nodes, self.nodePageId(node_id));
        }
        try self.label_index.addNode(label, node_id);
    }

    /// Add a label with auto-commit (backward compatible).
    pub fn addLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.addLabelTxn(node_id, label, txn);

        try self.txn_manager.commit(txn);
    }

    /// Remove a label within an existing transaction (no auto-commit).
    pub fn removeLabelTxn(self: *GraphEngine, node_id: NodeId, label: LabelId, txn: TxnId) anyerror!void {
        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        const result = try self.label_store.removeLabel(rec.label_head, label, self.allocator);
        rec.label_head = result.head;
        rec.label_count = result.count;
        try self.node_store.putNode(node_id, rec);
        self.label_index.removeNode(label, node_id);

        // Log dirty pages: var_store page (if any) and node page
        if (result.head != 0) try self.logPage(txn, .var_store, result.head);
        try self.logPage(txn, .nodes, self.nodePageId(node_id));
    }

    /// Remove a label with auto-commit (backward compatible).
    pub fn removeLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.removeLabelTxn(node_id, label, txn);

        try self.txn_manager.commit(txn);
    }

    pub fn scanLabel(self: *GraphEngine, label: LabelId, alloc: Allocator) anyerror![]NodeId {
        // Delegate to label index for O(1) lookup instead of O(N) scan
        return self.label_index.scan(label, alloc);
    }

    pub fn beginTxn(self: *GraphEngine) anyerror!TxnId {
        const txn_id = try self.txn_manager.begin();
        self.metrics.txn_begun += 1;
        return txn_id;
    }

    pub fn commitTxn(self: *GraphEngine, txn: TxnId) anyerror!void {
        try self.txn_manager.commit(txn);
        self.metrics.txn_committed += 1;
    }

    pub fn abortTxn(self: *GraphEngine, txn: TxnId) anyerror!void {
        try self.txn_manager.abort(txn);
        self.metrics.txn_aborted += 1;
    }

    pub fn nodeCount(self: *GraphEngine) anyerror!u64 {
        return self.manifest.node_count;
    }

    pub fn edgeCount(self: *GraphEngine) anyerror!u64 {
        return self.manifest.edge_count;
    }

    pub fn checkpoint(self: *GraphEngine) anyerror!void {
        return engine_persist.checkpoint(self);
    }

    // ── Edge property helpers (delegated to engine_edge_props.zig) ─────

    pub fn setEdgeProperty(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
        return engine_edge_props.setEdgeProperty(self, from, to, edge_id, key, value);
    }

    pub fn removeEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
        return engine_edge_props.removeEdgeProperty(self, from, edge_id, key);
    }

    pub fn getEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        return engine_edge_props.getEdgeProperty(self, from, edge_id, key, allocator);
    }

    pub fn getAllEdgeProperties(self: *GraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
        return engine_edge_props.getAllEdgeProperties(self, from, edge_id);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("engine_test.zig");
    _ = @import("engine_edge_props.zig");
    _ = @import("engine_integrity.zig");
    _ = @import("engine_index.zig");
    _ = @import("engine_persist.zig");
}
