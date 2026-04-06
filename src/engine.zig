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

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const TxnId = types.TxnId;
const LabelId = types.LabelId;
const FileId = types.FileId;
const PropertyValue = types.PropertyValue;
const GraphConfig = config_mod.GraphConfig;
const GraphStorage = interface_mod.GraphStorage;
const PropertyEntry = interface_mod.PropertyEntry;
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
const owner_only_file_mode = 0o600;

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
        }

        // 8. Wire metrics and thread pool into buffer pool
        self.metrics = .{};
        self.buffer_pool.setMetrics(&self.metrics);
        self.thread_pool = spice.ThreadPool.init(allocator);
        self.thread_pool.start(.{});
        self.buffer_pool.setThreadPool(&self.thread_pool);

        return self;
    }

    /// Initialize all subsystems shared between create() and open().
    ///
    /// This covers: free space managers, WAL, transaction manager, data stores,
    /// label dictionary, label index, and the checkpointer.
    fn initSubsystems(self: *GraphEngine, allocator: Allocator, graph_uuid: [16]u8, cfg: GraphConfig, wal_start_lsn: u64) !void {
        // Free space managers for each store
        self.free_space_nodes = try FreeSpaceManager.init(allocator, &self.buffer_pool, .nodes);
        errdefer self.free_space_nodes.deinit();
        self.free_space_adj_out = try FreeSpaceManager.init(allocator, &self.buffer_pool, .adj_out);
        errdefer self.free_space_adj_out.deinit();
        self.free_space_adj_in = try FreeSpaceManager.init(allocator, &self.buffer_pool, .adj_in);
        errdefer self.free_space_adj_in.deinit();
        self.free_space_props = try FreeSpaceManager.init(allocator, &self.buffer_pool, .props);
        errdefer self.free_space_props.deinit();
        self.free_space_var = try FreeSpaceManager.init(allocator, &self.buffer_pool, .var_store);
        errdefer self.free_space_var.deinit();

        // WAL directory + WalManager
        const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{self.graph_dir.path});
        defer allocator.free(wal_dir_path);
        try std.fs.cwd().makePath(wal_dir_path);
        self.wal_dir_handle = try std.fs.cwd().openDir(wal_dir_path, .{});
        errdefer self.wal_dir_handle.close();

        self.wal = try WalManager.init(allocator, self.wal_dir_handle, graph_uuid, wal_start_lsn, .{
            .encryption_key = cfg.encryption_key,
        });
        errdefer self.wal.deinit();

        // Transaction manager
        self.txn_manager = TxnManager.init(allocator, &self.wal, self.manifest.next_txn_id);
        errdefer self.txn_manager.deinit();

        // Data stores (non-fallible but clean up if a later init fails)
        self.node_store = NodeStore.init(&self.buffer_pool, &self.free_space_nodes, cfg.page_size);
        self.adj_out = AdjStore.init(&self.buffer_pool, &self.free_space_adj_out, .adj_out, cfg.page_size);
        self.adj_in = AdjStore.init(&self.buffer_pool, &self.free_space_adj_in, .adj_in, cfg.page_size);
        self.var_store = VarStore.init(&self.buffer_pool, &self.free_space_var, cfg.page_size);
        self.prop_store = PropStore.init(&self.buffer_pool, &self.free_space_props, &self.var_store, cfg.page_size);

        // Label dictionary, label store, and label index
        self.label_dict = LabelDictionary.init(allocator);
        errdefer self.label_dict.deinit();
        self.label_store = LabelStore.init(&self.var_store);
        self.label_index = LabelIndex.init(allocator, &self.buffer_pool, &self.free_space_nodes, cfg.page_size);
        errdefer self.label_index.deinit();
        self.property_index = PropertyChainIndex.init(allocator);
        errdefer self.property_index.deinit();

        // Checkpointer
        self.checkpointer = Checkpointer.init(
            allocator,
            &self.buffer_pool,
            &self.wal,
            &self.manifest,
            &self.file_manager,
            &self.graph_dir,
        );
    }

    /// Persist the 5 free space bitmaps to a `free.store` file so that
    /// freed pages are correctly tracked across restarts.
    fn saveFreeStore(self: *GraphEngine) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/free.store", .{self.graph_dir.path});
        defer self.allocator.free(path);

        // Compute total size needed for all 5 bitmaps.
        const total_size = self.free_space_nodes.serializedSize() +
            self.free_space_adj_out.serializedSize() +
            self.free_space_adj_in.serializedSize() +
            self.free_space_props.serializedSize() +
            self.free_space_var.serializedSize();

        const buf = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buf);

        var offset: usize = 0;
        const managers = [_]*const FreeSpaceManager{
            &self.free_space_nodes,
            &self.free_space_adj_out,
            &self.free_space_adj_in,
            &self.free_space_props,
            &self.free_space_var,
        };
        for (managers) |fsm| {
            const written = fsm.serialize(buf[offset..]) catch return error.BufferTooSmall;
            offset += written;
        }

        const file = try std.fs.cwd().createFile(path, .{ .mode = owner_only_file_mode });
        defer file.close();
        try file.writeAll(buf[0..offset]);
    }

    /// Try to load free space bitmaps from a persisted `free.store` file.
    /// Returns true if the file was loaded successfully, false if it does
    /// not exist.
    fn loadFreeStore(self: *GraphEngine) !bool {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/free.store", .{self.graph_dir.path});
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
        const buf = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buf);

        const bytes_read = try file.readAll(buf);
        if (bytes_read != file_size) return error.UnexpectedEof;

        var offset: usize = 0;
        var managers = [_]*FreeSpaceManager{
            &self.free_space_nodes,
            &self.free_space_adj_out,
            &self.free_space_adj_in,
            &self.free_space_props,
            &self.free_space_var,
        };
        for (&managers) |fsm| {
            const consumed = try fsm.deserialize(buf[offset..]);
            offset += consumed;
        }

        return true;
    }

    /// Rebuild free space bitmaps by scanning on-disk file sizes.
    /// Called during open() after initSubsystems so that pages written in a
    /// previous session are visible to scanNodes and other page walkers.
    fn rebuildFreeSpaceFromDisk(self: *GraphEngine) !void {
        const pairs = [_]struct { fsm: *FreeSpaceManager, fid: types.FileId }{
            .{ .fsm = &self.free_space_nodes, .fid = .nodes },
            .{ .fsm = &self.free_space_adj_out, .fid = .adj_out },
            .{ .fsm = &self.free_space_adj_in, .fid = .adj_in },
            .{ .fsm = &self.free_space_props, .fid = .props },
            .{ .fsm = &self.free_space_var, .fid = .var_store },
        };

        for (pairs) |pair| {
            const pager = self.file_manager.getPager(pair.fid) orelse continue;
            const page_count = pager.pageCount() catch continue;
            if (page_count == 0) continue;

            try pair.fsm.ensureCapacity(page_count);
            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                pair.fsm.bitmap.set(i);
            }
        }
    }

    /// Rebuild the in-memory label index by reading each live node's labels
    /// from the LabelStore (var.store-backed). Called during open() after all
    /// subsystems and free-space bitmaps are initialized.
    fn rebuildLabelIndex(self: *GraphEngine) !void {
        self.label_index.clear();

        // Iterate all allocated node IDs and populate the index from LabelStore.
        var id: u64 = 1;
        while (id < self.manifest.next_node_id) : (id += 1) {
            const rec = self.node_store.getNode(id) catch continue orelse continue;
            if (node_mod.isDeleted(&rec) or node_mod.isEmpty(&rec)) continue;
            if (rec.label_head == 0) continue;

            const labels = self.label_store.getLabels(rec.label_head, self.allocator) catch continue;
            defer self.allocator.free(labels);

            for (labels) |label_id| {
                try self.label_index.addNode(label_id, id);
            }
        }
    }

    fn refreshPropertyChainIndex(self: *GraphEngine, prop_head: u64) !void {
        if (prop_head == 0) {
            return;
        }

        var iter = self.prop_store.getAllProperties(prop_head);
        defer iter.deinit();
        try self.property_index.refreshFromIterator(prop_head, &iter);
    }

    fn rebuildPropertyIndex(self: *GraphEngine) !void {
        self.property_index.clear();

        var id: u64 = 1;
        while (id < self.manifest.next_node_id) : (id += 1) {
            const rec = self.node_store.getNode(id) catch continue orelse continue;
            if (node_mod.isDeleted(&rec) or node_mod.isEmpty(&rec)) continue;

            try self.refreshPropertyChainIndex(rec.prop_head);

            if (rec.out_head == 0) continue;
            var iter = self.adj_out.expand(rec.out_head, null);
            defer iter.deinit();
            while (try iter.next()) |entry| {
                try self.refreshPropertyChainIndex(entry.prop_head);
            }
        }
    }

    fn rebuildDerivedIndexes(self: *GraphEngine) !void {
        try self.rebuildLabelIndex();
        try self.rebuildPropertyIndex();
    }

    fn tryLoadDerivedIndexes(self: *GraphEngine) !bool {
        const label_file = self.file_manager.getFile(.label_idx) orelse return false;
        const prop_file = self.file_manager.getFile(.prop_idx) orelse return false;

        self.label_index.clear();
        self.property_index.clear();
        errdefer {
            self.label_index.clear();
            self.property_index.clear();
        }

        const label_counter = try self.label_index.loadFromFile(label_file) orelse return false;
        const prop_counter = try self.property_index.loadFromFile(prop_file) orelse return false;
        if (label_counter != self.manifest.counter or prop_counter != self.manifest.counter) {
            self.label_index.clear();
            self.property_index.clear();
            return false;
        }

        return true;
    }

    fn saveDerivedIndexes(self: *GraphEngine) !void {
        const label_file = self.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
        const prop_file = self.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
        try self.label_index.saveToFile(label_file, self.manifest.counter);
        try self.property_index.saveToFile(prop_file, self.manifest.counter);
    }

    fn saveLabelDictionary(self: *GraphEngine) !void {
        const labels_path = try std.fmt.allocPrint(self.allocator, "{s}/labels.dict", .{self.graph_dir.path});
        defer self.allocator.free(labels_path);
        try self.label_dict.saveToFile(labels_path);
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

    /// Return a read-only pointer to the engine's metrics counters.
    pub fn getMetrics(self: *GraphEngine) *const Metrics {
        return &self.metrics;
    }

    /// Summary statistics about the storage engine's current state.
    pub const StorageStats = struct {
        node_count: u64,
        edge_count: u64,
        label_count: u32,
        format_version: u32,
        page_size: u32,
        wal_lsn: u64,
        last_checkpoint_lsn: u64,
        free_pages_nodes: u64,
        free_pages_adj_out: u64,
        free_pages_adj_in: u64,
        free_pages_props: u64,
        free_pages_var: u64,
    };

    /// Return a snapshot of storage-level statistics.
    pub fn getStorageStats(self: *GraphEngine) StorageStats {
        return .{
            .node_count = self.manifest.node_count,
            .edge_count = self.manifest.edge_count,
            .label_count = self.manifest.label_count,
            .format_version = self.manifest.format_version,
            .page_size = self.config.page_size,
            .wal_lsn = self.txn_manager.next_txn_id,
            .last_checkpoint_lsn = self.manifest.last_checkpoint_lsn,
            .free_pages_nodes = self.free_space_nodes.freeCount(),
            .free_pages_adj_out = self.free_space_adj_out.freeCount(),
            .free_pages_adj_in = self.free_space_adj_in.freeCount(),
            .free_pages_props = self.free_space_props.freeCount(),
            .free_pages_var = self.free_space_var.freeCount(),
        };
    }

    /// Result of a storage integrity check.
    pub const IntegrityReport = struct {
        node_count_consistent: bool,
        edge_count_consistent: bool,
        label_index_entries: u64,
        total_errors: u64,
    };

    /// Walk the node and edge stores and compare actual live counts against
    /// the manifest counters. Returns a report with any inconsistencies.
    pub fn checkIntegrity(self: *GraphEngine) IntegrityReport {
        var report = IntegrityReport{
            .node_count_consistent = true,
            .edge_count_consistent = true,
            .label_index_entries = 0,
            .total_errors = 0,
        };

        // Count actual live nodes (not deleted, not empty)
        var actual_nodes: u64 = 0;
        var id: u64 = 1;
        while (id < self.manifest.next_node_id) : (id += 1) {
            if (self.node_store.getNode(id) catch null) |rec| {
                if (!node_mod.isDeleted(&rec) and !node_mod.isEmpty(&rec)) {
                    actual_nodes += 1;
                }
            }
        }
        if (actual_nodes != self.manifest.node_count) {
            report.node_count_consistent = false;
            report.total_errors += 1;
        }

        // Count actual edges by scanning outgoing adjacency lists of all live nodes
        var actual_edges: u64 = 0;
        var nid: u64 = 1;
        while (nid < self.manifest.next_node_id) : (nid += 1) {
            if (self.node_store.getNode(nid) catch null) |rec| {
                if (!node_mod.isDeleted(&rec) and !node_mod.isEmpty(&rec) and rec.out_head != 0) {
                    var iter = self.adj_out.expand(rec.out_head, null);
                    defer iter.deinit();
                    while (iter.next() catch null) |_| {
                        actual_edges += 1;
                    }
                }
            }
        }
        if (actual_edges != self.manifest.edge_count) {
            report.edge_count_consistent = false;
            report.total_errors += 1;
        }

        return report;
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

    pub fn putNode(self: *GraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.node_store.putNode(id, rec);
        try self.logPage(txn, .nodes, self.nodePageId(id));

        try self.txn_manager.commit(txn);
    }

    pub fn allocNode(self: *GraphEngine) anyerror!NodeId {
        const id = self.manifest.next_node_id;
        self.manifest.next_node_id += 1;
        self.manifest.node_count += 1;
        self.metrics.nodes_created += 1;
        return id;
    }

    pub fn deleteNode(self: *GraphEngine, id: NodeId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.node_store.deleteNode(id);
        try self.logPage(txn, .nodes, self.nodePageId(id));

        try self.txn_manager.commit(txn);

        if (self.manifest.node_count > 0) {
            self.manifest.node_count -= 1;
        }
        self.metrics.nodes_deleted += 1;
    }

    /// Look up an edge by its ID.
    ///
    /// QUAL-0006: Returns error.EdgeIndexNotImplemented instead of silently
    /// returning null. A dedicated edge-ID index is required for efficient
    /// lookup; the current storage layout does not maintain one.
    pub fn getEdge(self: *GraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
        _ = self;
        _ = edge_id;
        return error.EdgeIndexNotImplemented;
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
        var list = std.ArrayList(EdgeEntry){};
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| {
            try list.append(allocator, entry);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn addEdge(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

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

        try self.txn_manager.commit(txn);

        self.manifest.edge_count += 1;
        self.metrics.edges_created += 1;

        return edge_id;
    }

    pub fn removeEdge(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        // Remove from source node's out adjacency list
        const from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        try self.adj_out.removeEdge(from_rec.out_head, edge_id);

        // Remove from target node's in adjacency list
        const to_rec = try self.node_store.getNode(to) orelse return error.NodeNotFound;
        try self.adj_in.removeEdge(to_rec.in_head, edge_id);

        // Log dirty adjacency pages
        if (from_rec.out_head != 0) try self.logPage(txn, .adj_out, from_rec.out_head);
        if (to_rec.in_head != 0) try self.logPage(txn, .adj_in, to_rec.in_head);

        try self.txn_manager.commit(txn);

        if (self.manifest.edge_count > 0) {
            self.manifest.edge_count -= 1;
        }
        self.metrics.edges_removed += 1;
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

    pub fn putProperty(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        const new_head = try self.prop_store.putProperty(owner, key, val);

        // Log the property page that was written to
        try self.logPage(txn, .props, new_head);

        try self.txn_manager.commit(txn);

        if (owner != 0 and owner != new_head) {
            self.property_index.removeChain(owner);
        }
        try self.refreshPropertyChainIndex(new_head);

        self.metrics.properties_written += 1;
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

    pub fn addLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

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

        try self.txn_manager.commit(txn);
    }

    pub fn removeLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        const result = try self.label_store.removeLabel(rec.label_head, label, self.allocator);
        rec.label_head = result.head;
        rec.label_count = result.count;
        try self.node_store.putNode(node_id, rec);
        self.label_index.removeNode(label, node_id);

        // Log dirty pages: var_store page (if any) and node page
        if (result.head != 0) try self.logPage(txn, .var_store, result.head);
        try self.logPage(txn, .nodes, self.nodePageId(node_id));

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
        // Update manifest counters before checkpoint
        self.manifest.next_txn_id = self.txn_manager.next_txn_id;
        self.manifest.label_count = self.label_dict.count();

        // Sync per-store page counts into the manifest so on-disk metadata
        // reflects actual allocation state.
        self.manifest.nodes_pages = self.free_space_nodes.allocatedCount();
        self.manifest.adj_out_pages = self.free_space_adj_out.allocatedCount();
        self.manifest.adj_in_pages = self.free_space_adj_in.allocatedCount();
        self.manifest.props_pages = self.free_space_props.allocatedCount();
        self.manifest.var_pages = self.free_space_var.allocatedCount();

        // Synchronous checkpoint: flush dirty pages, sync files, write
        // manifest.  Previous versions spawned a detached background thread
        // which could silently lose writes and made the timer meaningless.
        var timer = std.time.Timer.start() catch null;
        try self.checkpointer.doCheckpoint();

        // Persist free space bitmaps so freed pages survive restart.
        try self.saveFreeStore();
        try self.saveDerivedIndexes();
        try self.saveLabelDictionary();

        if (timer) |*t| {
            self.metrics.last_checkpoint_duration_ns = t.read();
        }
        self.metrics.checkpoints_completed += 1;
    }

    // ── Edge property helpers ──────────────────────────────────────────

    /// Scan the outgoing adjacency list of a node for a specific edge_id
    /// and return its prop_head. Returns null if the edge was not found.
    fn findEdgePropHead(self: *GraphEngine, from_out_head: u64, edge_id: EdgeId) anyerror!?u32 {
        var iter = self.adj_out.expand(from_out_head, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.edge_id == edge_id) {
                return entry.prop_head;
            }
        }
        return null;
    }

    /// Set (or overwrite) a property on an edge identified by (from, to, edge_id).
    /// Updates the prop_head in both the outgoing and incoming adjacency lists.
    pub fn setEdgeProperty(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
        // 1. Look up source node to get out_head
        const from_rec = (try self.node_store.getNode(from)) orelse return error.NodeNotFound;

        // 2. Scan outgoing edges to find current prop_head for this edge_id
        const found_prop_head = (try self.findEdgePropHead(from_rec.out_head, edge_id)) orelse return error.EdgeNotFound;

        // 3. Write property, get new prop_head
        const new_head_u64 = try self.putProperty(@as(u64, found_prop_head), key, value);
        const new_head: u32 = @intCast(new_head_u64 & 0xFFFFFFFF);

        // 4. If prop_head changed, update BOTH adjacency copies
        if (new_head != found_prop_head) {
            _ = try self.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head);
            const to_rec = (try self.node_store.getNode(to)) orelse return error.NodeNotFound;
            _ = try self.adj_in.updateEdgePropHead(to_rec.in_head, edge_id, new_head);
        }

        if (found_prop_head != 0 and found_prop_head != new_head) {
            self.property_index.removeChain(found_prop_head);
        }
        try self.refreshPropertyChainIndex(new_head_u64);
    }

    /// Remove a property from an edge. The removal is in-place so the prop_head
    /// does not change.
    pub fn removeEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
        const from_rec = (try self.node_store.getNode(from)) orelse return error.NodeNotFound;

        const prop_head = (try self.findEdgePropHead(from_rec.out_head, edge_id)) orelse return error.EdgeNotFound;
        if (prop_head == 0) return; // no properties to remove
        try self.removeProperty(@as(u64, prop_head), key);
    }

    /// Read a single property from an edge.
    pub fn getEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        const from_rec = (try self.node_store.getNode(from)) orelse return error.NodeNotFound;

        const prop_head = (try self.findEdgePropHead(from_rec.out_head, edge_id)) orelse return null;
        if (prop_head == 0) return null;
        return self.getProperty(@as(u64, prop_head), key, allocator);
    }

    /// Return an iterator over all properties on an edge.
    pub fn getAllEdgeProperties(self: *GraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
        const from_rec = (try self.node_store.getNode(from)) orelse return error.NodeNotFound;

        const prop_head = (try self.findEdgePropHead(from_rec.out_head, edge_id)) orelse return null;
        if (prop_head == 0) return null;
        return self.prop_store.getAllProperties(@as(u64, prop_head));
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn testDataDir() !struct { tmp_dir: testing.TmpDir, path: []const u8 } {
    var tmp_dir = testing.tmpDir(.{});
    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    return .{ .tmp_dir = tmp_dir, .path = path };
}

fn testConfig() GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
        .data_dir = "data",
    };
}

test "create engine, allocNode, putNode, getNode round-trip" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x01} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Allocate and write a node
    const node_id = try engine.allocNode();
    try testing.expectEqual(@as(NodeId, 1), node_id);

    const rec = NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
    try engine.putNode(node_id, rec);

    // Read it back
    const got = try engine.getNode(node_id);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 0), got.?.label_head);
    try testing.expectEqual(@as(u16, 0), got.?.label_count);
}

test "create engine, addEdge, expandOut returns edge" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x02} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Create two nodes
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    // Add an edge
    const edge_id = try engine.addEdge(n1, n2, 5);
    try testing.expectEqual(@as(EdgeId, 1), edge_id);

    // Expand outgoing edges from n1
    const out_edges = try engine.expandOut(n1, null, testing.allocator);
    defer testing.allocator.free(out_edges);

    try testing.expectEqual(@as(usize, 1), out_edges.len);
    try testing.expectEqual(n2, out_edges[0].neighbor);
    try testing.expectEqual(edge_id, out_edges[0].edge_id);
    try testing.expectEqual(@as(u32, 5), out_edges[0].rel_type);

    // Expand incoming edges at n2
    const in_edges = try engine.expandIn(n2, null, testing.allocator);
    defer testing.allocator.free(in_edges);

    try testing.expectEqual(@as(usize, 1), in_edges.len);
    try testing.expectEqual(n1, in_edges[0].neighbor);
}

test "create engine, checkpoint, close, open again, data persists" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x03} ** 16;
    const cfg = testConfig();

    // Create and populate
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const n1 = try engine.allocNode();
        try engine.putNode(n1, NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        });

        // Checkpoint to persist
        try engine.checkpoint();

        try engine.close();
    }

    // Re-open and verify data survived checkpoint+close+reopen
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // The node MUST be present after checkpoint+close+reopen
        const got = try engine.getNode(1);
        try testing.expect(got != null);
        try testing.expectEqual(@as(u64, 0), got.?.label_head);
    }
}

test "checkpoint persists labels.dict, labels.idx and props.idx snapshots" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x11} ** 16;
    const cfg = testConfig();

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const node_id = try engine.allocNode();
        var rec = NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try engine.putNode(node_id, rec);
        try engine.addLabel(node_id, 7);

        rec = (try engine.getNode(node_id)).?;
        rec.prop_head = try engine.putProperty(rec.prop_head, "name", .{ .string = "Alice" });
        try engine.putNode(node_id, rec);

        try engine.checkpoint();
        try engine.close();
    }

    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();

    const labels_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.idx", .{graph_dir.path});
    defer testing.allocator.free(labels_idx_path);
    const props_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/props.idx", .{graph_dir.path});
    defer testing.allocator.free(props_idx_path);
    const labels_dict_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.dict", .{graph_dir.path});
    defer testing.allocator.free(labels_dict_path);

    const labels_dict_stat = try std.fs.cwd().statFile(labels_dict_path);
    const labels_stat = try std.fs.cwd().statFile(labels_idx_path);
    const props_stat = try std.fs.cwd().statFile(props_idx_path);
    try testing.expect(labels_dict_stat.size > 0);
    try testing.expect(labels_stat.size > 0);
    try testing.expect(props_stat.size > 0);
}

test "open rebuilds derived indexes when snapshot files are stale" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x12} ** 16;
    const cfg = testConfig();

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const node_id = try engine.allocNode();
        var rec = NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try engine.putNode(node_id, rec);
        try engine.addLabel(node_id, 9);

        rec = (try engine.getNode(node_id)).?;
        rec.prop_head = try engine.putProperty(rec.prop_head, "email", .{ .string = "alice@example.com" });
        try engine.putNode(node_id, rec);

        try engine.checkpoint();
        try engine.close();
    }

    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();
    const labels_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.idx", .{graph_dir.path});
    defer testing.allocator.free(labels_idx_path);

    const labels_file = try std.fs.cwd().createFile(labels_idx_path, .{ .read = true, .truncate = true });
    labels_file.close();

    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    const labeled_nodes = try engine.scanLabel(9, testing.allocator);
    defer testing.allocator.free(labeled_nodes);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{1}, labeled_nodes);

    const rec = (try engine.getNode(1)).?;
    const email = try engine.getProperty(rec.prop_head, "email", testing.allocator);
    defer if (email) |value| switch (value) {
        .string => |s| testing.allocator.free(s),
        .ext => |e| testing.allocator.free(e.data),
        else => {},
    };
    try testing.expect(email != null);
    try testing.expectEqualStrings("alice@example.com", email.?.string);
}

test "GraphStorage vtable interface works" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x04} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Get the vtable interface
    const gs = engine.storage();

    // Use vtable methods
    const node_id = try gs.allocNode();
    try gs.putNode(node_id, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const got = try gs.getNode(node_id);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 0), got.?.label_head);

    const count = try gs.nodeCount();
    try testing.expectEqual(@as(u64, 1), count);
}

test "GAP-0006: close returns error union, not void" {
    // Verify that close() returns !void by calling try on it
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x06} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());

    // This call would fail to compile if close() returned void
    try engine.close();
}

test "SEC-0010: open rejects page_size mismatch" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x10} ** 16;
    const cfg = testConfig(); // page_size = 4096

    // Create with page_size 4096
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Try to open with different page_size -- should fail
    {
        var bad_cfg = testConfig();
        bad_cfg.page_size = 8192;
        const result = GraphEngine.open(testing.allocator, td.path, uuid, bad_cfg);
        try testing.expectError(error.PageSizeMismatch, result);
    }
}

test "QUAL-0006: getEdge returns EdgeIndexNotImplemented error" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x07} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // getEdge should return an explicit error, not silent null
    const result = engine.getEdge(1);
    try testing.expectError(error.EdgeIndexNotImplemented, result);
}

test "PERF-0005: nodeCount/edgeCount are O(1) via manifest counters" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x50} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Initially zero
    try testing.expectEqual(@as(u64, 0), try engine.nodeCount());
    try testing.expectEqual(@as(u64, 0), try engine.edgeCount());

    // Allocate and write two nodes
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    try testing.expectEqual(@as(u64, 1), try engine.nodeCount());

    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    try testing.expectEqual(@as(u64, 2), try engine.nodeCount());

    // Add edges
    _ = try engine.addEdge(n1, n2, 1);
    try testing.expectEqual(@as(u64, 1), try engine.edgeCount());

    _ = try engine.addEdge(n2, n1, 2);
    try testing.expectEqual(@as(u64, 2), try engine.edgeCount());

    // Remove an edge
    try engine.removeEdge(n1, n2, 1);
    try testing.expectEqual(@as(u64, 1), try engine.edgeCount());

    // Delete a node
    try engine.deleteNode(n1);
    try testing.expectEqual(@as(u64, 1), try engine.nodeCount());

    // Counters are directly from manifest (O(1))
    try testing.expectEqual(@as(u64, 1), engine.manifest.node_count);
    try testing.expectEqual(@as(u64, 1), engine.manifest.edge_count);
}

test "PERF-0008: open auto-sizes buffer pool from manifest" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x08} ** 16;

    // Create with small buffer pool
    var cfg = testConfig();
    cfg.buffer_pool_pages = 64;
    cfg.buffer_pool_auto_size = true;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Re-open: auto-size should kick in (minimum 1024 even for empty graph)
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Buffer pool should be at least 1024 (the auto-size minimum)
        try testing.expect(engine.buffer_pool.capacity >= 1024);
    }
}

test "PERF-0008: open respects buffer_pool_auto_size=false" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x09} ** 16;

    var cfg = testConfig();
    cfg.buffer_pool_pages = 64;
    cfg.buffer_pool_auto_size = false;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Re-open with auto-size disabled: should keep configured size
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        try testing.expectEqual(@as(u32, 64), engine.buffer_pool.capacity);
    }
}

test "getStorageStats returns correct counters" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x71} ** 16;
    const cfg = testConfig();
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // Fresh engine stats
    const stats0 = engine.getStorageStats();
    try testing.expectEqual(@as(u64, 0), stats0.node_count);
    try testing.expectEqual(@as(u64, 0), stats0.edge_count);
    try testing.expectEqual(@as(u32, 2), stats0.format_version); // V2
    try testing.expectEqual(@as(u32, 4096), stats0.page_size);

    // Add a node and check stats update
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const stats1 = engine.getStorageStats();
    try testing.expectEqual(@as(u64, 1), stats1.node_count);
}

test "checkIntegrity reports consistent state" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x72} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Empty engine should be consistent
    const r0 = engine.checkIntegrity();
    try testing.expect(r0.node_count_consistent);
    try testing.expect(r0.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r0.total_errors);

    // Add two nodes and an edge
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    _ = try engine.addEdge(n1, n2, 1);

    // Should still be consistent
    const r1 = engine.checkIntegrity();
    try testing.expect(r1.node_count_consistent);
    try testing.expect(r1.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r1.total_errors);

    // Remove the edge, then delete a node — counts should stay consistent
    try engine.removeEdge(n1, n2, 1);
    try engine.deleteNode(n1);
    const r2 = engine.checkIntegrity();
    try testing.expect(r2.node_count_consistent);
    try testing.expect(r2.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r2.total_errors);
}

test "V1 format detection returns V1FormatRequiresRecreation" {
    var td = try testDataDir();
    defer {
        testing.allocator.free(td.path);
        td.tmp_dir.cleanup();
    }

    const uuid = [_]u8{0x61} ** 16;
    const cfg = testConfig();

    // Create a valid V2 graph so the directory structure exists
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Now overwrite manifest_a with a V1 format_version
    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();

    const v1_manifest = Manifest{
        .graph_uuid = uuid,
        .page_size = cfg.page_size,
        .counter = 10, // Higher counter so it wins A/B selection
        .format_version = manifest_mod.MANIFEST_VERSION_V1,
    };
    const path_a = try graph_dir.manifestPath(testing.allocator, .a);
    defer testing.allocator.free(path_a);
    try v1_manifest.writeToFile(testing.allocator, path_a);

    // Also write to slot B so selectManifest picks V1
    const path_b = try graph_dir.manifestPath(testing.allocator, .b);
    defer testing.allocator.free(path_b);
    try v1_manifest.writeToFile(testing.allocator, path_b);

    // open() should detect V1 and return error
    const result = GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    try testing.expectError(error.IncompatibleVersion, result);
}

test {
    std.testing.refAllDecls(@This());
}
