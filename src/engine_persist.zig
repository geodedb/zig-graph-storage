// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Persistence helpers extracted from engine.zig.
//! Covers free space bitmap serialization, label dictionary persistence,
//! and free space rebuild from disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const config_mod = @import("config.zig");
const wal_mod = @import("wal.zig");
const txn_mod = @import("txn.zig");
const node_store_mod = @import("node_store.zig");
const adj_store_mod = @import("adj_store.zig");
const prop_store_mod = @import("prop_store.zig");
const var_store_mod = @import("var_store.zig");
const free_space_mod = @import("free_space.zig");
const label_dict_mod = @import("label_dict.zig");
const checkpoint_mod = @import("checkpoint.zig");
const label_index_mod = @import("label_index.zig");
const property_chain_index_mod = @import("property_chain_index.zig");
const label_store_mod = @import("label_store.zig");
const engine_mod = @import("engine.zig");
const engine_index = @import("engine_index.zig");

const EdgeId = types.EdgeId;
const GraphConfig = config_mod.GraphConfig;
const WalManager = wal_mod.WalManager;
const TxnManager = txn_mod.TxnManager;
const NodeStore = node_store_mod.NodeStore;
const AdjStore = adj_store_mod.AdjStore;
const PropStore = prop_store_mod.PropStore;
const VarStore = var_store_mod.VarStore;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const LabelDictionary = label_dict_mod.LabelDictionary;
const Checkpointer = checkpoint_mod.Checkpointer;
const LabelIndex = label_index_mod.LabelIndex;
const PropertyChainIndex = property_chain_index_mod.PropertyChainIndex;
const LabelStore = label_store_mod.LabelStore;
const GraphEngine = engine_mod.GraphEngine;
const EdgeIndexEntry = engine_mod.EdgeIndexEntry;
const owner_only_file_mode = 0o600;

/// Persist the 5 free space bitmaps to a `free.store` file so that
/// freed pages are correctly tracked across restarts.
pub fn saveFreeStore(engine: *GraphEngine) !void {
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/free.store", .{engine.graph_dir.path});
    defer engine.allocator.free(path);

    // Compute total size needed for all 5 bitmaps.
    const total_size = engine.free_space_nodes.serializedSize() +
        engine.free_space_adj_out.serializedSize() +
        engine.free_space_adj_in.serializedSize() +
        engine.free_space_props.serializedSize() +
        engine.free_space_var.serializedSize();

    const buf = try engine.allocator.alloc(u8, total_size);
    defer engine.allocator.free(buf);

    var offset: usize = 0;
    const managers = [_]*const FreeSpaceManager{
        &engine.free_space_nodes,
        &engine.free_space_adj_out,
        &engine.free_space_adj_in,
        &engine.free_space_props,
        &engine.free_space_var,
    };
    for (managers) |fsm| {
        const written = fsm.serialize(buf[offset..]) catch return error.BufferTooSmall;
        offset += written;
    }

    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode) });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), buf[0..offset]);
}

/// Try to load free space bitmaps from a persisted `free.store` file.
/// Returns true if the file was loaded successfully, false if it does
/// not exist.
pub fn loadFreeStore(engine: *GraphEngine) !bool {
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/free.store", .{engine.graph_dir.path});
    defer engine.allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    if (stat.size == 0) return false;
    const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const buf = try engine.allocator.alloc(u8, file_size);
    defer engine.allocator.free(buf);

    const bytes_read = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), buf, 0);
    if (bytes_read != file_size) return error.UnexpectedEof;

    var offset: usize = 0;
    var managers = [_]*FreeSpaceManager{
        &engine.free_space_nodes,
        &engine.free_space_adj_out,
        &engine.free_space_adj_in,
        &engine.free_space_props,
        &engine.free_space_var,
    };
    const max_pages = [_]u64{
        try maxPersistedPagesForStore(engine, .nodes),
        try maxPersistedPagesForStore(engine, .adj_out),
        try maxPersistedPagesForStore(engine, .adj_in),
        try maxPersistedPagesForStore(engine, .props),
        try maxPersistedPagesForStore(engine, .var_store),
    };
    for (&managers, max_pages) |fsm, max_total_pages| {
        const consumed = try fsm.deserializeBounded(buf[offset..], max_total_pages);
        offset += consumed;
    }

    return true;
}

/// Rebuild free space bitmaps by scanning on-disk file sizes.
/// Called during open() after initSubsystems so that pages written in a
/// previous session are visible to scanNodes and other page walkers.
pub fn rebuildFreeSpaceFromDisk(engine: *GraphEngine) !void {
    const pairs = [_]struct { fsm: *FreeSpaceManager, fid: types.FileId }{
        .{ .fsm = &engine.free_space_nodes, .fid = .nodes },
        .{ .fsm = &engine.free_space_adj_out, .fid = .adj_out },
        .{ .fsm = &engine.free_space_adj_in, .fid = .adj_in },
        .{ .fsm = &engine.free_space_props, .fid = .props },
        .{ .fsm = &engine.free_space_var, .fid = .var_store },
    };

    for (pairs) |pair| {
        const pager = engine.file_manager.getPager(pair.fid) orelse continue;
        const page_count = pager.pageCount() catch continue;
        if (page_count == 0) continue;

        try pair.fsm.ensureCapacity(page_count);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            pair.fsm.bitmap.set(i);
        }
    }
}

fn maxPersistedPagesForStore(engine: *GraphEngine, fid: types.FileId) !u64 {
    const pager = engine.file_manager.getPager(fid) orelse return 64;
    const page_count = try pager.pageCount();
    if (page_count >= std.math.maxInt(u64) / 2) return std.math.maxInt(u64);
    return @max(@as(u64, 64), page_count * 2);
}

/// Persist the label dictionary to a `labels.dict` file.
pub fn saveLabelDictionary(engine: *GraphEngine) !void {
    const labels_path = try std.fmt.allocPrint(engine.allocator, "{s}/labels.dict", .{engine.graph_dir.path});
    defer engine.allocator.free(labels_path);
    try engine.label_dict.saveToFile(labels_path);
}

/// Initialize all subsystems shared between create() and open().
///
/// This covers: free space managers, WAL, transaction manager, data stores,
/// label dictionary, label index, and the checkpointer.
pub fn initSubsystems(self: *GraphEngine, allocator: Allocator, graph_uuid: [16]u8, cfg: GraphConfig, wal_start_lsn: u64) !void {
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
    if (cfg.allow_create_missing_artifacts) {
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), wal_dir_path);
    }
    self.wal_dir_handle = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    errdefer self.wal_dir_handle.close(std.Io.Threaded.global_single_threaded.io());

    self.wal = try WalManager.init(allocator, self.wal_dir_handle, graph_uuid, wal_start_lsn, .{
        .encryption_key = cfg.encryption_key,
        .create_identity_if_missing = cfg.allow_create_missing_artifacts,
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
    // SEC: when at-rest encryption is enabled the pager writes the per-page
    // AES-GCM tag into the final TAG_SIZE bytes of the page on flush. Reserve
    // that tail in the prop_store's slotted-page layout so the per-page key
    // directory (which grows backward from the page end) never collides with
    // the tag — otherwise dir_count is overwritten by tag bytes and the page
    // fails to read back after a restart (integer-overflow panic).
    self.prop_store.tail_reserve = if (cfg.encryption_key != null)
        @import("encryption.zig").TAG_SIZE
    else
        0;

    // Label dictionary, label store, and label index
    self.label_dict = LabelDictionary.init(allocator);
    errdefer self.label_dict.deinit();
    self.label_store = LabelStore.init(&self.var_store);
    self.label_index = LabelIndex.init(allocator, &self.buffer_pool, &self.free_space_nodes, cfg.page_size);
    errdefer self.label_index.deinit();
    self.property_index = PropertyChainIndex.init(allocator);
    errdefer self.property_index.deinit();
    self.edge_index = std.AutoHashMap(EdgeId, EdgeIndexEntry).init(allocator);
    errdefer self.edge_index.deinit();

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

/// Run a full checkpoint: update manifest counters, flush dirty pages,
/// persist free space bitmaps, derived indexes, and label dictionary.
pub fn checkpoint(engine: *GraphEngine) anyerror!void {
    if (!engine.persistence_dirty) {
        return;
    }

    // Update manifest counters before checkpoint
    engine.manifest.next_txn_id = engine.txn_manager.next_txn_id;
    engine.manifest.label_count = engine.label_dict.count();

    // Sync per-store page counts into the manifest so on-disk metadata
    // reflects actual allocation state.
    engine.manifest.nodes_pages = engine.free_space_nodes.allocatedCount();
    engine.manifest.adj_out_pages = engine.free_space_adj_out.allocatedCount();
    engine.manifest.adj_in_pages = engine.free_space_adj_in.allocatedCount();
    engine.manifest.props_pages = engine.free_space_props.allocatedCount();
    engine.manifest.var_pages = engine.free_space_var.allocatedCount();

    // Synchronous checkpoint: flush dirty pages, sync files, write
    // manifest.  Previous versions spawned a detached background thread
    // which could silently lose writes and made the timer meaningless.
    const start_ts = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
    engine.ensureSubmitterRegistered();
    try engine.checkpointer.doCheckpoint();

    // Persist free space bitmaps so freed pages survive restart.
    try saveFreeStore(engine);
    try engine_index.saveDerivedIndexesConditional(
        engine,
        engine.label_index_dirty,
        engine.property_index_dirty,
        engine.edge_index_dirty,
    );
    engine.label_index_dirty = false;
    engine.property_index_dirty = false;
    engine.edge_index_dirty = false;
    try saveLabelDictionary(engine);

    const end_ts = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
    const elapsed = start_ts.durationTo(end_ts);
    engine.metrics.last_checkpoint_duration_ns = @intCast(elapsed.raw.toNanoseconds());
    engine.metrics.checkpoints_completed += 1;
    engine.persistence_dirty = false;
}
