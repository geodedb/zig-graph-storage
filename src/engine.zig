// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
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
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;

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
    label_index: LabelIndex,
    checkpointer: Checkpointer,
    manifest: Manifest,
    wal_dir_handle: std.fs.Dir,

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
        _ = try self.file_manager.openFile(.nodes);
        _ = try self.file_manager.openFile(.adj_out);
        _ = try self.file_manager.openFile(.adj_in);
        _ = try self.file_manager.openFile(.props);
        _ = try self.file_manager.openFile(.var_store);
        _ = try self.file_manager.openFile(.free);

        // 5. Create buffer pool, register pagers
        self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, cfg.buffer_pool_pages);
        errdefer self.buffer_pool.deinit();
        if (self.file_manager.getPager(.nodes)) |p| self.buffer_pool.registerPager(.nodes, p);
        if (self.file_manager.getPager(.adj_out)) |p| self.buffer_pool.registerPager(.adj_out, p);
        if (self.file_manager.getPager(.adj_in)) |p| self.buffer_pool.registerPager(.adj_in, p);
        if (self.file_manager.getPager(.props)) |p| self.buffer_pool.registerPager(.props, p);
        if (self.file_manager.getPager(.var_store)) |p| self.buffer_pool.registerPager(.var_store, p);
        if (self.file_manager.getPager(.free)) |p| self.buffer_pool.registerPager(.free, p);

        // 6. Create free space managers for each store
        self.free_space_nodes = try FreeSpaceManager.init(allocator, &self.buffer_pool, .nodes);
        self.free_space_adj_out = try FreeSpaceManager.init(allocator, &self.buffer_pool, .adj_out);
        self.free_space_adj_in = try FreeSpaceManager.init(allocator, &self.buffer_pool, .adj_in);
        self.free_space_props = try FreeSpaceManager.init(allocator, &self.buffer_pool, .props);
        self.free_space_var = try FreeSpaceManager.init(allocator, &self.buffer_pool, .var_store);

        // 7. Open WAL directory, init WalManager
        const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{self.graph_dir.path});
        defer allocator.free(wal_dir_path);
        try std.fs.cwd().makePath(wal_dir_path);
        self.wal_dir_handle = try std.fs.cwd().openDir(wal_dir_path, .{});

        self.wal = try WalManager.init(allocator, self.wal_dir_handle, graph_uuid, 0, .{
            .encryption_key = cfg.encryption_key,
        });

        // 8. Init TxnManager
        self.txn_manager = TxnManager.init(allocator, &self.wal, self.manifest.next_txn_id);

        // 9. Init all stores
        self.node_store = NodeStore.init(&self.buffer_pool, &self.free_space_nodes, cfg.page_size);
        self.adj_out = AdjStore.init(&self.buffer_pool, &self.free_space_adj_out, .adj_out, cfg.page_size);
        self.adj_in = AdjStore.init(&self.buffer_pool, &self.free_space_adj_in, .adj_in, cfg.page_size);
        self.var_store = VarStore.init(&self.buffer_pool, &self.free_space_var, cfg.page_size);
        self.prop_store = PropStore.init(&self.buffer_pool, &self.free_space_props, &self.var_store, cfg.page_size);

        // 10. Init label dictionary and label index
        self.label_dict = LabelDictionary.init(allocator);
        self.label_index = LabelIndex.init(allocator, &self.buffer_pool, &self.free_space_nodes, cfg.page_size);

        // 11. Init checkpointer
        self.checkpointer = Checkpointer.init(
            allocator,
            &self.buffer_pool,
            &self.wal,
            &self.manifest,
            &self.file_manager,
            &self.graph_dir,
        );

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

        // 3. Create buffer pool
        self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, cfg.buffer_pool_pages);
        errdefer self.buffer_pool.deinit();

        // 4. Run recovery (loads manifest, replays WAL)
        var recovery = Recovery.init(allocator, cfg.encryption_key);
        self.manifest = try recovery.recover(&self.graph_dir, &self.buffer_pool, &self.file_manager);

        // SEC-0010: Validate page_size matches manifest after recovery
        if (cfg.page_size != self.manifest.page_size) {
            return error.PageSizeMismatch;
        }

        // 5. Create free space managers
        self.free_space_nodes = try FreeSpaceManager.init(allocator, &self.buffer_pool, .nodes);
        self.free_space_adj_out = try FreeSpaceManager.init(allocator, &self.buffer_pool, .adj_out);
        self.free_space_adj_in = try FreeSpaceManager.init(allocator, &self.buffer_pool, .adj_in);
        self.free_space_props = try FreeSpaceManager.init(allocator, &self.buffer_pool, .props);
        self.free_space_var = try FreeSpaceManager.init(allocator, &self.buffer_pool, .var_store);

        // 6. Open WAL directory, init WalManager
        const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{self.graph_dir.path});
        defer allocator.free(wal_dir_path);
        try std.fs.cwd().makePath(wal_dir_path);
        self.wal_dir_handle = try std.fs.cwd().openDir(wal_dir_path, .{});

        self.wal = try WalManager.init(allocator, self.wal_dir_handle, graph_uuid, self.manifest.last_checkpoint_lsn, .{
            .encryption_key = cfg.encryption_key,
        });

        // 7. Init TxnManager
        self.txn_manager = TxnManager.init(allocator, &self.wal, self.manifest.next_txn_id);

        // 8. Init all stores
        self.node_store = NodeStore.init(&self.buffer_pool, &self.free_space_nodes, cfg.page_size);
        self.adj_out = AdjStore.init(&self.buffer_pool, &self.free_space_adj_out, .adj_out, cfg.page_size);
        self.adj_in = AdjStore.init(&self.buffer_pool, &self.free_space_adj_in, .adj_in, cfg.page_size);
        self.var_store = VarStore.init(&self.buffer_pool, &self.free_space_var, cfg.page_size);
        self.prop_store = PropStore.init(&self.buffer_pool, &self.free_space_props, &self.var_store, cfg.page_size);

        // 9. Init label dictionary and label index
        self.label_dict = LabelDictionary.init(allocator);
        self.label_index = LabelIndex.init(allocator, &self.buffer_pool, &self.free_space_nodes, cfg.page_size);

        // Try to load label dictionary if it exists
        const labels_path = try std.fmt.allocPrint(allocator, "{s}/labels.dict", .{self.graph_dir.path});
        defer allocator.free(labels_path);
        self.label_dict.loadFromFile(labels_path) catch {};

        // Rebuild label index from node store
        try self.label_index.rebuild(&self.node_store, self.manifest.next_node_id);

        // 10. Init checkpointer
        self.checkpointer = Checkpointer.init(
            allocator,
            &self.buffer_pool,
            &self.wal,
            &self.manifest,
            &self.file_manager,
            &self.graph_dir,
        );

        return self;
    }

    /// Close the engine (flush, checkpoint, close files).
    ///
    /// Returns an error if the final checkpoint or label dictionary save fails.
    /// Resources are always cleaned up regardless of errors.
    pub fn close(self: *GraphEngine) !void {
        const allocator = self.allocator;

        // Persist current state
        self.manifest.next_txn_id = self.txn_manager.next_txn_id.load(.monotonic);
        self.manifest.label_count = self.label_dict.count();

        // Track the first error encountered during close
        var close_err: ?anyerror = null;

        // Run a final checkpoint -- propagate errors
        self.checkpointer.run() catch |err| {
            close_err = err;
        };

        // Save label dictionary -- propagate errors
        const labels_path = std.fmt.allocPrint(allocator, "{s}/labels.dict", .{self.graph_dir.path}) catch |err| {
            if (close_err == null) close_err = err;
            self.cleanupResources(allocator);
            if (close_err) |e| return e;
            return;
        };
        defer allocator.free(labels_path);

        self.label_dict.saveToFile(labels_path) catch |err| {
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

    // ========================================================================
    // VTable implementation methods (called via GraphStorage interface)
    // ========================================================================

    pub fn getNode(self: *GraphEngine, id: NodeId) anyerror!?NodeRec {
        return self.node_store.getNode(id);
    }

    pub fn putNode(self: *GraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
        return self.node_store.putNode(id, rec);
    }

    pub fn allocNode(self: *GraphEngine) anyerror!NodeId {
        const id = self.manifest.next_node_id;
        self.manifest.next_node_id += 1;
        self.manifest.node_count += 1;
        return id;
    }

    pub fn deleteNode(self: *GraphEngine, id: NodeId) anyerror!void {
        try self.node_store.deleteNode(id);
        if (self.manifest.node_count > 0) {
            self.manifest.node_count -= 1;
        }
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

    pub fn expandOut(self: *GraphEngine, id: NodeId, rel_type: ?u32, alloc: Allocator) anyerror![]EdgeEntry {
        const rec = try self.node_store.getNode(id) orelse return try alloc.alloc(EdgeEntry, 0);
        return self.adj_out.expand(rec.out_head, rel_type, alloc);
    }

    pub fn expandIn(self: *GraphEngine, id: NodeId, rel_type: ?u32, alloc: Allocator) anyerror![]EdgeEntry {
        const rec = try self.node_store.getNode(id) orelse return try alloc.alloc(EdgeEntry, 0);
        return self.adj_in.expand(rec.in_head, rel_type, alloc);
    }

    pub fn addEdge(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
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

        self.manifest.edge_count += 1;

        return edge_id;
    }

    pub fn removeEdge(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        // Remove from source node's out adjacency list
        const from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        try self.adj_out.removeEdge(from_rec.out_head, edge_id);

        // Remove from target node's in adjacency list
        const to_rec = try self.node_store.getNode(to) orelse return error.NodeNotFound;
        try self.adj_in.removeEdge(to_rec.in_head, edge_id);

        if (self.manifest.edge_count > 0) {
            self.manifest.edge_count -= 1;
        }
    }

    pub fn getProperty(self: *GraphEngine, prop_head: u64, key: []const u8, alloc: Allocator) anyerror!?PropertyValue {
        return self.prop_store.getProperty(prop_head, key, alloc);
    }

    pub fn getAllProperties(self: *GraphEngine, prop_head: u64, alloc: Allocator) anyerror![]PropertyEntry {
        return self.prop_store.getAllProperties(prop_head, alloc);
    }

    pub fn putProperty(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        return self.prop_store.putProperty(owner, key, val);
    }

    pub fn removeProperty(self: *GraphEngine, owner: u64, key: []const u8) anyerror!void {
        return self.prop_store.removeProperty(owner, key);
    }

    pub fn addLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        rec.label_set |= (@as(u32, 1) << @intCast(label % 32));
        try self.node_store.putNode(node_id, rec);
        try self.label_index.addNode(label, node_id);
    }

    pub fn removeLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        rec.label_set &= ~(@as(u32, 1) << @intCast(label % 32));
        try self.node_store.putNode(node_id, rec);
        self.label_index.removeNode(label, node_id);
    }

    pub fn scanLabel(self: *GraphEngine, label: LabelId, alloc: Allocator) anyerror![]NodeId {
        // Delegate to label index for O(1) lookup instead of O(N) scan
        return self.label_index.scan(label, alloc);
    }

    pub fn beginTxn(self: *GraphEngine) anyerror!TxnId {
        return self.txn_manager.begin();
    }

    pub fn commitTxn(self: *GraphEngine, txn: TxnId) anyerror!void {
        return self.txn_manager.commit(txn);
    }

    pub fn abortTxn(self: *GraphEngine, txn: TxnId) anyerror!void {
        return self.txn_manager.abort(txn);
    }

    pub fn nodeCount(self: *GraphEngine) anyerror!u64 {
        return self.manifest.node_count;
    }

    pub fn edgeCount(self: *GraphEngine) anyerror!u64 {
        return self.manifest.edge_count;
    }

    pub fn checkpoint(self: *GraphEngine) anyerror!void {
        // Update manifest counters before checkpoint
        self.manifest.next_txn_id = self.txn_manager.next_txn_id.load(.monotonic);
        self.manifest.label_count = self.label_dict.count();
        return self.checkpointer.run();
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
        .label_set = 42,
        .flags = 0,
        ._pad = 0,
        .txn_stamp = 1,
    };
    try engine.putNode(node_id, rec);

    // Read it back
    const got = try engine.getNode(node_id);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u32, 42), got.?.label_set);
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
        .label_set = 0,
        .flags = 0,
        ._pad = 0,
        .txn_stamp = 1,
    });

    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_set = 0,
        .flags = 0,
        ._pad = 0,
        .txn_stamp = 1,
    });

    // Add an edge
    const edge_id = try engine.addEdge(n1, n2, 5);
    try testing.expectEqual(@as(EdgeId, 1), edge_id);

    // Expand outgoing edges from n1
    const edges = try engine.expandOut(n1, null, testing.allocator);
    defer testing.allocator.free(edges);

    try testing.expectEqual(@as(usize, 1), edges.len);
    try testing.expectEqual(n2, edges[0].neighbor);
    try testing.expectEqual(edge_id, edges[0].edge_id);
    try testing.expectEqual(@as(u32, 5), edges[0].rel_type);

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
            .label_set = 77,
            .flags = 0,
            ._pad = 0,
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
        try testing.expectEqual(@as(u32, 77), got.?.label_set);
    }
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
        .label_set = 99,
        .flags = 0,
        ._pad = 0,
        .txn_stamp = 1,
    });

    const got = try gs.getNode(node_id);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u32, 99), got.?.label_set);

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
        .label_set = 0,
        .flags = 0,
        ._pad = 0,
        .txn_stamp = 1,
    });
    try testing.expectEqual(@as(u64, 1), try engine.nodeCount());

    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_set = 0,
        .flags = 0,
        ._pad = 0,
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

test {
    std.testing.refAllDecls(@This());
}
