// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Persistence helpers extracted from engine.zig.
//! Covers free space bitmap serialization, label dictionary persistence,
//! and free space rebuild from disk.

const std = @import("std");
const scoped_file = @import("scoped_file.zig");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const config_mod = @import("config.zig");
const wal_mod = @import("wal.zig");
const txn_mod = @import("txn.zig");
const node_store_mod = @import("node_store.zig");
const adj_store_mod = @import("adj_store.zig");
const in_head_dir_mod = @import("in_head_dir.zig");
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
const engine_property_index = @import("engine_property_index.zig");
const side_file_crypto = @import("side_file_crypto.zig");
const manifest_mod = @import("manifest.zig");

const EdgeId = types.EdgeId;
const GraphConfig = config_mod.GraphConfig;
const WalManager = wal_mod.WalManager;
const TxnManager = txn_mod.TxnManager;
const NodeStore = node_store_mod.NodeStore;
const AdjStore = adj_store_mod.AdjStore;
const InHeadDir = in_head_dir_mod.InHeadDir;
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

/// Write the free space bitmaps to `free.store` (temp file, fsync, rename;
/// no directory fsync — see `saveFreeStore` / `checkpointSideFiles`).
fn writeFreeStoreFile(engine: *GraphEngine) !void {
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/free.store", .{engine.graph_dir.path});
    defer engine.allocator.free(path);

    // Compute total size needed for all bitmaps. Edge co-location (Phase A)
    // appends in_idx + in_dir at the END so the format stays additive (a legacy
    // 5-bitmap free.store is still readable; the new trailing bitmaps default to
    // empty when absent — see loadFreeStore).
    const total_size = engine.free_space_nodes.serializedSize() +
        engine.free_space_adj_out.serializedSize() +
        engine.free_space_adj_in.serializedSize() +
        engine.free_space_props.serializedSize() +
        engine.free_space_var.serializedSize() +
        engine.free_space_in_idx.serializedSize() +
        engine.free_space_in_dir.serializedSize();

    const buf = try engine.allocator.alloc(u8, total_size);
    defer engine.allocator.free(buf);

    var offset: usize = 0;
    const managers = [_]*const FreeSpaceManager{
        &engine.free_space_nodes,
        &engine.free_space_adj_out,
        &engine.free_space_adj_in,
        &engine.free_space_props,
        &engine.free_space_var,
        &engine.free_space_in_idx,
        &engine.free_space_in_dir,
    };
    // SONNY-6470: a host that cannot write the defined layout (64-bit
    // little-endian mask words) persists an EMPTY file, which every reader
    // treats as "no bitmap" (rebuild from the store files), never one that a
    // 64-bit little-endian host would misread.
    if (free_space_mod.host_layout_supported) {
        for (managers) |fsm| {
            const written = fsm.serialize(buf[offset..]) catch |err| switch (err) {
                error.BufferTooSmall => return error.BufferTooSmall,
                error.UnsupportedHostLayout => unreachable,
            };
            offset += written;
        }
    }

    // GAP-ENT-0011 (review F-2): write ATOMICALLY — tmp + fsync + rename +
    // dir fsync. The crash-recovery path made this file correctness-
    // load-bearing (the rebuilt bitmap is re-persisted right after recovery),
    // and the previous in-place createFile truncated the old file first: a
    // torn write could land exactly at the 5-bitmap legacy boundary, which
    // loadFreeStore parses as a legacy file with EMPTY in_idx/in_dir bitmaps
    // (silent double allocation of live co-located-adjacency pages), and a
    // truncation elsewhere bricks the open until the file is hand-deleted.
    // With the rename as the commit point, a crash mid-save leaves the OLD
    // file intact (on the recovery path that is the recovery-truncated EMPTY
    // file → rebuild fallback).
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_path = try std.fmt.allocPrint(engine.allocator, "{s}.tmp", .{path});
    defer engine.allocator.free(tmp_path);

    {
        // exclusive is omitted: a stale .tmp from a previous killed save may
        // exist and must simply be overwritten.
        const tmp_file = try scoped_file.create(io, tmp_path, .{
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
            .resolve_beneath = true,
        });
        defer tmp_file.close(io);
        try tmp_file.writeStreamingAll(io, buf[0..offset]);
        try tmp_file.sync(io);
    }

    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Persist the free space bitmaps durably: `writeFreeStoreFile`, then fsync
/// the graph directory so the rename itself survives power loss (the
/// recovery path relies on that, not just on surviving a process crash).
pub fn saveFreeStore(engine: *GraphEngine) !void {
    try writeFreeStoreFile(engine);
    try syncGraphDir(engine);
}

/// SONNY-6491: the checkpoint's pre-manifest step. `free.store` must be
/// durable BEFORE the manifest that advances the frontier: written after it,
/// a crash in between left the new manifest (and a truncated or covered WAL)
/// next to the previous bitmap, and the next clean open handed pages
/// allocated since then to new writers. Written before it, a crash in between
/// leaves a bitmap NEWER than the manifest, which is safe: when the WAL tail
/// holds committed records recovery discards the file and rebuilds it from
/// the store files (recovery.zig, GAP-ENT-0011); when it holds none, the
/// pages the bitmap describes were flushed and fsynced just before it.
fn checkpointSideFiles(ctx: *anyopaque) anyerror!void {
    const engine: *GraphEngine = @ptrCast(@alignCast(ctx));
    try writeFreeStoreFile(engine);
    try engine.checkpointer.faultPoint(.post_free_store);
    try syncGraphDir(engine);
}

pub fn preManifestStep(engine: *GraphEngine) Checkpointer.PreManifest {
    return .{ .ctx = engine, .run = checkpointSideFiles };
}

/// Copy the in-memory counters the manifest records into it before a
/// checkpoint writes it (shared by checkpointEx and close).
pub fn refreshManifestCounters(engine: *GraphEngine) void {
    engine.manifest.next_txn_id = engine.txn_manager.next_txn_id;
    engine.manifest.label_count = engine.label_dict.count();
    // Per-store page counts: on-disk metadata reflects allocation state, and
    // loadFreeStore checks a loaded bitmap against them (SONNY-6491).
    engine.manifest.nodes_pages = engine.free_space_nodes.allocatedCount();
    engine.manifest.adj_out_pages = engine.free_space_adj_out.allocatedCount();
    engine.manifest.adj_in_pages = engine.free_space_adj_in.allocatedCount();
    engine.manifest.in_idx_pages = engine.free_space_in_idx.allocatedCount();
    engine.manifest.in_dir_pages = engine.free_space_in_dir.allocatedCount();
    engine.manifest.props_pages = engine.free_space_props.allocatedCount();
    engine.manifest.var_pages = engine.free_space_var.allocatedCount();
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
    // SONNY-6470: see free_space.host_layout_supported — rebuild instead.
    if (!free_space_mod.host_layout_supported) return false;
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

    // Edge co-location (Phase A): the in_idx + in_dir bitmaps are appended at the
    // end. They are ADDITIVE — a legacy free.store written before co-location has
    // no trailing bytes here, in which case we leave both at their (empty) init
    // state. A fresh free.store always carries them.
    var trailing = [_]*FreeSpaceManager{
        &engine.free_space_in_idx,
        &engine.free_space_in_dir,
    };
    const trailing_max = [_]u64{
        try maxPersistedPagesForStore(engine, .in_idx),
        try maxPersistedPagesForStore(engine, .in_dir),
    };
    for (&trailing, trailing_max) |fsm, max_total_pages| {
        if (offset >= buf.len) break; // legacy free.store: no trailing bitmaps.
        const consumed = try fsm.deserializeBounded(buf[offset..], max_total_pages);
        offset += consumed;
    }

    // SONNY-6491: graph_storage <= 0.4.13 saved free.store AFTER the
    // manifest and the WAL truncate. A store that crashed in between holds the
    // new manifest, an empty WAL tail and the previous bitmap, which would
    // hand pages allocated since then to new writers. Detect what can be
    // detected cheaply and rebuild from the store files instead (safe; freed
    // pages then read as allocated until reused).
    if (try freeStoreTrailsManifest(engine)) {
        std.log.warn("free.store is older than the manifest (crash during a <= 0.4.13 checkpoint); rebuilding the free-space bitmaps from the store files", .{});
        return false;
    }
    return true;
}

/// SONNY-6491: true when the loaded bitmaps cannot be the ones the manifest's
/// checkpoint saw. Two checks, both O(bitmap):
///   * a store has fewer allocated pages than the manifest's per-store page
///     count (`*_pages`, recorded from the same bitmaps at that checkpoint);
///   * a node page that exists in `nodes.store` and lies at or below the
///     page of the highest node id the manifest issued is not allocated (node
///     pages are never freed).
/// Limits: a bitmap that is stale only in WHICH pages it marks (as many pages
/// freed as allocated since its save) passes both checks; manifests written by
/// `close()` before 0.4.14 carry the page counts of the last `checkpoint()`,
/// so the count check only sees growth since then; the node check can fire for
/// a page whose ids were all issued and never written (aborted), costing a
/// harmless rebuild.
fn freeStoreTrailsManifest(engine: *GraphEngine) !bool {
    const m = &engine.manifest;
    const pairs = [_]struct { fsm: *const FreeSpaceManager, pages: u64 }{
        .{ .fsm = &engine.free_space_nodes, .pages = m.nodes_pages },
        .{ .fsm = &engine.free_space_adj_out, .pages = m.adj_out_pages },
        .{ .fsm = &engine.free_space_adj_in, .pages = m.adj_in_pages },
        .{ .fsm = &engine.free_space_in_idx, .pages = m.in_idx_pages },
        .{ .fsm = &engine.free_space_in_dir, .pages = m.in_dir_pages },
        .{ .fsm = &engine.free_space_props, .pages = m.props_pages },
        .{ .fsm = &engine.free_space_var, .pages = m.var_pages },
    };
    for (pairs) |pr| {
        if (pr.fsm.allocatedCount() < pr.pages) return true;
    }

    const stride: u64 = if (engine.config.base_shard_index != null)
        @intCast(@import("sharded_store.zig").SHARD_COUNT)
    else
        1;
    if (m.next_node_id < stride) return false;
    const npp: u64 = @import("node.zig").nodesPerPage(engine.config.page_size);
    const last_page = (m.next_node_id - stride) / npp;
    const pager = engine.file_manager.getPager(.nodes) orelse return error.StorePagerUnavailable;
    const page_count = try pager.pageCount();
    var p: u64 = 0;
    while (p <= last_page and p < page_count) : (p += 1) {
        if (!engine.free_space_nodes.isAllocated(p)) return true;
    }
    return false;
}

/// Rebuild free space bitmaps by scanning on-disk file sizes.
/// Called during open() after initSubsystems so that pages written in a
/// previous session are visible to scanNodes and other page walkers.
pub fn rebuildFreeSpaceFromDisk(engine: *GraphEngine) !void {
    const pairs = [_]struct { fsm: *FreeSpaceManager, fid: types.FileId }{
        .{ .fsm = &engine.free_space_nodes, .fid = .nodes },
        .{ .fsm = &engine.free_space_adj_out, .fid = .adj_out },
        .{ .fsm = &engine.free_space_adj_in, .fid = .adj_in },
        .{ .fsm = &engine.free_space_in_idx, .fid = .in_idx },
        .{ .fsm = &engine.free_space_in_dir, .fid = .in_dir },
        .{ .fsm = &engine.free_space_props, .fid = .props },
        .{ .fsm = &engine.free_space_var, .fid = .var_store },
    };

    for (pairs) |pair| {
        // Review F-4 (GAP-ENT-0011): this rebuild is the PRIMARY defense on
        // the crash-recovery path. Swallowing a missing pager or an fstat
        // error here would leave that store's bitmap EMPTY (all free) —
        // silent double allocation, the very bug under repair. All seven
        // store files are opened before this runs, so both failures are
        // exceptional and must fail the open loudly.
        const pager = engine.file_manager.getPager(pair.fid) orelse return error.StorePagerUnavailable;
        const page_count = try pager.pageCount();
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

/// SONNY-6590: the side-file cipher of this store (labels.dict, props.idx,
/// ordered_propidx.snap, props.catalog, propidx_*.btree), derived from the
/// at-rest key and bound to this graph's (shard's) uuid; null without a key.
/// The caller `deinit`s it (zeroes the derived key).
pub fn sideCipher(engine: *const GraphEngine) ?side_file_crypto.Cipher {
    return side_file_crypto.Cipher.forKey(engine.config.encryption_key, engine.graph_uuid);
}

/// SONNY-6590: how this store reads a side file. Under a key, a plaintext
/// file is accepted only while the manifest still says format_version 4 (a
/// store written by <= 0.4.16, upgraded at open by `sealLegacySideFiles`);
/// once the manifest says 5 every side file must be sealed.
pub fn sideReadPolicy(engine: *const GraphEngine, cipher: ?*const side_file_crypto.Cipher) side_file_crypto.ReadPolicy {
    return .{
        .cipher = cipher,
        .require_sealed = engine.manifest.format_version >= manifest_mod.MANIFEST_VERSION_SEALED_SIDE_FILES,
    };
}

/// Persist the label dictionary to a `labels.dict` file (sealed under
/// at-rest encryption, SONNY-6590).
pub fn saveLabelDictionary(engine: *GraphEngine) !void {
    const labels_path = try std.fmt.allocPrint(engine.allocator, "{s}/labels.dict", .{engine.graph_dir.path});
    defer engine.allocator.free(labels_path);
    var cipher = sideCipher(engine);
    defer if (cipher) |*c| c.deinit();
    try engine.label_dict.saveToFileWith(labels_path, if (cipher) |*c| c else null);
}

/// SONNY-6590: upgrade the side files of a store written by graph_storage
/// <= 0.4.16 under at-rest encryption (manifest format_version 4, side files
/// in the plaintext layout) at open, then mark the manifest format_version 5
/// (persisted by the next checkpoint or close). Each step is crash-safe on
/// its own and the manifest stays at 4 until all are done, so a store killed
/// at any point opens again and resumes:
///   1. a stale `labels.dict.tmp` (never read) is removed: one left by an
///      older binary holds the names in plaintext;
///   2. labels.dict is rewritten sealed (temp + fsync + rename + dir fsync);
///   3. a plaintext props.idx is emptied (derived: rebuilt from the pages on
///      first use and saved sealed at the next full checkpoint);
///   4. ordered_propidx.snap is rewritten sealed from the loaded snapshot,
///      keeping its stamp (a stale stamp still forces a rebuild), or removed
///      when it could not be loaded;
///   5. props.catalog and every declared propidx_*.btree are rewritten sealed
///      from memory (temp + fsync + rename, then dir fsync).
/// No-op without a key, on a read-only open, and on a store already at 5
/// beyond step 1. `label_dict_was_plaintext` and `ordered_stamp` come from
/// the loads `GraphEngine.open` ran just before. Returns true when it moved
/// the in-memory manifest to 5: the caller marks the store dirty so the next
/// checkpoint (or close) persists it.
pub fn sealLegacySideFiles(
    engine: *GraphEngine,
    label_dict_was_plaintext: bool,
    ordered_stamp: ?@import("index_snapshot.zig").Stamp,
) !bool {
    if (engine.read_only) return false;
    var cipher = sideCipher(engine);
    defer if (cipher) |*c| c.deinit();
    const c: *const side_file_crypto.Cipher = if (cipher) |*cc| cc else return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = engine.allocator;
    const dir = engine.graph_dir.path;

    {
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.tmp", .{ dir, label_dict_mod.FILE_NAME });
        defer alloc.free(p);
        std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    if (engine.manifest.format_version >= manifest_mod.MANIFEST_VERSION_SEALED_SIDE_FILES) return false;

    var upgraded = false;
    if (label_dict_was_plaintext) {
        try saveLabelDictionaryDurable(engine);
        try side_file_crypto.faultPoint(.label_dict_sealed);
        upgraded = true;
    }

    if (engine.file_manager.getFile(.prop_idx)) |f| {
        if (try plaintextOnDisk(f.*)) {
            try f.setLength(io, 0);
            try f.sync(io);
            try side_file_crypto.faultPoint(.prop_chain_index_dropped);
            upgraded = true;
        }
    }

    {
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, @import("ordered_property_index.zig").SNAPSHOT_FILE_NAME });
        defer alloc.free(p);
        if (try plaintextFileOnDisk(p)) {
            if (ordered_stamp) |st| {
                try engine.ordered_property_index.saveToFileWith(dir, st.epoch, st.covered_lsn, c);
            } else {
                try std.Io.Dir.cwd().deleteFile(io, p);
            }
            try syncGraphDir(engine);
            try side_file_crypto.faultPoint(.ordered_index_sealed);
            upgraded = true;
        }
    }

    if (try engine_property_index.sealLegacy(engine, c)) upgraded = true;

    if (upgraded) std.log.info("graph-storage: sealed the side files of a store written by graph_storage <= 0.4.16 under at-rest encryption (SONNY-6590)", .{});
    engine.manifest.format_version = manifest_mod.MANIFEST_VERSION_SEALED_SIDE_FILES;
    return true;
}

/// True when the open file is non-empty and not a sealed envelope.
pub fn plaintextOnDisk(file: std.Io.File) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var head: [side_file_crypto.MAGIC.len]u8 = undefined;
    const n = try file.readPositionalAll(io, &head, 0);
    if (n == 0) return false;
    return !side_file_crypto.isSealed(head[0..n]);
}

/// `plaintextOnDisk` by path; false when the file does not exist.
pub fn plaintextFileOnDisk(path: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer f.close(io);
    return plaintextOnDisk(f);
}

/// SONNY-6491: `saveLabelDictionary` (temp file, fsync, rename) followed by a
/// directory fsync, so the rename itself survives power loss.
pub fn saveLabelDictionaryDurable(engine: *GraphEngine) !void {
    try saveLabelDictionary(engine);
    try engine.checkpointer.faultPoint(.post_label_dict);
    try syncGraphDir(engine);
}

/// fsync the graph directory so renames into it are durable. `.iterate =
/// true` forces a real O_RDONLY|O_DIRECTORY fd — the default openDir uses
/// O_PATH, on which fsync fails with EBADF.
pub fn syncGraphDir(engine: *GraphEngine) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var gdir = try std.Io.Dir.cwd().openDir(io, engine.graph_dir.path, .{ .iterate = true });
    defer gdir.close(io);
    const gdir_file = std.Io.File{ .handle = gdir.handle, .flags = .{ .nonblocking = false } };
    try gdir_file.sync(io);
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
    // Edge co-location (Phase A): own free space for the incoming-adjacency
    // chain bodies + directory, each store managing its own file's page space
    // exactly like adj_in / nodes.
    self.free_space_in_idx = try FreeSpaceManager.init(allocator, &self.buffer_pool, .in_idx);
    errdefer self.free_space_in_idx.deinit();
    self.free_space_in_dir = try FreeSpaceManager.init(allocator, &self.buffer_pool, .in_dir);
    errdefer self.free_space_in_dir.deinit();
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

    // Transaction manager. Wire the configured commit durability policy
    // (PERF-0045). DEFAULT is `sync_each_commit` — per-commit fsync,
    // byte-for-byte the historical behavior (NFR-SEC-003).
    self.txn_manager = TxnManager.initWithSyncMode(
        allocator,
        &self.wal,
        self.manifest.next_txn_id,
        cfg.sync_mode,
    );
    errdefer self.txn_manager.deinit();
    // SONNY-6558: overflow chains released by a journaled property write are
    // freed when its transaction commits (see engine_undo.onCommit).
    self.txn_manager.commit_hook = .{ .ctx = self, .run = @import("engine_undo.zig").onCommit };

    // Data stores (non-fallible but clean up if a later init fails)
    self.node_store = NodeStore.init(&self.buffer_pool, &self.free_space_nodes, cfg.page_size);
    self.adj_out = AdjStore.init(&self.buffer_pool, &self.free_space_adj_out, .adj_out, cfg.page_size);
    self.adj_in = AdjStore.init(&self.buffer_pool, &self.free_space_adj_in, .adj_in, cfg.page_size);
    // Edge co-location (Phase A): incoming-adjacency chain bodies + directory.
    self.adj_in_remote = AdjStore.init(&self.buffer_pool, &self.free_space_in_idx, .in_idx, cfg.page_size);
    self.in_head_dir = InHeadDir.init(&self.buffer_pool, &self.free_space_in_dir, .in_dir, cfg.page_size);
    self.var_store = VarStore.init(&self.buffer_pool, &self.free_space_var, cfg.page_size);
    self.prop_store = PropStore.init(&self.buffer_pool, &self.free_space_props, &self.var_store, cfg.page_size);
    // SEC: before SONNY-6441 the pager wrote the per-page AES-GCM tag into the
    // final TAG_SIZE bytes of an encrypted page, so the backward-growing
    // directories below reserve that tail. The pager now keeps the tag in the
    // page header, but the reservation stays: it fixes WHERE an existing
    // encrypted store's directories sit (dir_count at page end - TAG_SIZE),
    // so it is part of the on-disk layout of every encrypted store.
    // Property-value OVERFLOW: the configured sanity cap on a single property
    // value's encoded size (bounds WAL volume and per-op memory — see
    // GraphConfig.max_property_value_bytes).
    self.prop_store.max_property_value_bytes = cfg.max_property_value_bytes;
    self.prop_store.tail_reserve = if (cfg.encryption_key != null)
        @import("encryption.zig").TAG_SIZE
    else
        0;
    // Same reservation for the adjacency stores' SLAB slot directories (GAP
    // adjacency slab packing): a slab block's directory grows backward from
    // the page end exactly like the prop-store key directory. Legacy v1/v2
    // chain blocks grow forward only and never reached the tail, so this is
    // a no-op for them.
    self.adj_out.tail_reserve = self.prop_store.tail_reserve;
    self.adj_in.tail_reserve = self.prop_store.tail_reserve;
    self.adj_in_remote.tail_reserve = self.prop_store.tail_reserve;
    // Same tail reservation for the var-store SLAB slot directory (GAP var-store
    // slab packing): a slab block's directory grows backward from the page end
    // exactly like the prop-store/adjacency directories. Legacy var chains grow
    // forward only, so this is a no-op for them. The slab WRITER is ON by
    // default since P7 (freshly-created stores pack new var-chains; existing
    // legacy chains keep reading via the read-both path — no migration); set it
    // explicitly for clarity / to keep the toggle discoverable for rollback.
    self.var_store.tail_reserve = self.prop_store.tail_reserve;
    self.var_store.slab_packing = true;

    // GAP adjacency slab packing (P2): opt-in per config. New small chains on
    // all three adjacency stores pack into shared slab blocks. Reads stay
    // slab-aware regardless (read-both), so toggling this never strands data.
    self.adj_out.slab_packing = cfg.adjacency_slab_packing;
    self.adj_in.slab_packing = cfg.adjacency_slab_packing;
    self.adj_in_remote.slab_packing = cfg.adjacency_slab_packing;

    // GAP-0060: edge-prop slab packing needs the adjacency writer to emit the
    // WIDE (v3 / slab-v3) entry format so an edge's u64 prop_head is durable
    // and in-place-widenable. Read-both parses legacy blocks regardless.
    self.adj_out.wide_heads = cfg.edge_prop_slab_packing;
    self.adj_in.wide_heads = cfg.edge_prop_slab_packing;
    self.adj_in_remote.wide_heads = cfg.edge_prop_slab_packing;

    // Label dictionary, label store, and label index
    self.label_dict = LabelDictionary.init(allocator);
    errdefer self.label_dict.deinit();
    self.label_store = LabelStore.init(&self.var_store);
    self.label_index = LabelIndex.init(allocator, &self.buffer_pool, &self.free_space_nodes, cfg.page_size);
    errdefer self.label_index.deinit();
    self.property_index = PropertyChainIndex.init(allocator);
    errdefer self.property_index.deinit();
    // PHASE G reverse map (prop_head -> node_id). Starts empty: create() leaves
    // it empty (fresh graph, maintained live from the first putNode since a
    // fresh graph is hydrated); open() loads its snapshot or rebuilds it during
    // hydration.
    self.prop_rev_index = @import("prop_rev_index.zig").PropRevIndex.init(allocator);
    errdefer self.prop_rev_index.deinit();
    self.edge_index = @import("edge_index_map.zig").EdgeIndexMap.init(allocator);
    errdefer self.edge_index.deinit();
    // PHASE 3: edge-existence index. Starts empty; open() loads its snapshot or
    // rebuilds from adjacency, create() leaves it empty.
    self.edge_exist_index = @import("edge_exist_index.zig").EdgeExistenceIndex.init(allocator);
    errdefer self.edge_exist_index.deinit();

    // GAP-0027 / FR-016 / FR-017: opt-in B+tree property indexes + catalog.
    // Starts empty; create() leaves it empty (no catalog file), open() loads it.
    self.property_index_set = engine_property_index.PropertyIndexSet.init(allocator);
    errdefer self.property_index_set.deinit();
    self.property_catalog_dirty = false;

    // H3-P1: per-(label,key) value-ordered index. Starts empty; create() leaves
    // it empty (no snapshot file), open() loads-or-rebuilds it counter-gated.
    self.ordered_property_index = @import("ordered_property_index.zig").OrderedPropertyIndex.init(allocator);
    errdefer self.ordered_property_index.deinit();
    self.ordered_index_dirty = false;

    // Checkpointer
    self.checkpointer = Checkpointer.init(
        allocator,
        &self.buffer_pool,
        &self.wal,
        &self.manifest,
        &self.file_manager,
        &self.graph_dir,
    );
    // SEC-0043: HMAC-authenticate the manifest at checkpoint when TDE is enabled.
    self.checkpointer.encryption_key = cfg.encryption_key;
}

/// Run a full checkpoint: update manifest counters, flush dirty pages,
/// persist free space bitmaps, derived indexes, and label dictionary.
///
/// Backward-compatible wrapper: existing callers get the full behavior
/// (save_derived = true).
pub fn checkpoint(engine: *GraphEngine) anyerror!void {
    return checkpointEx(engine, true);
}

/// Run a "light" (incremental/bounded) checkpoint: do the memory-bounding work
/// (flush dirty pages, sync dirty files, write manifest, TRUNCATE the WAL,
/// persist free space + label dictionary + declared B+tree indexes) but SKIP
/// the O(graph-size) derived-index snapshot save.
///
/// GAP-0900 Layer-2: the full checkpoint re-saves label_index + property_index
/// + edge_index by iterating ALL entries every time, which is O(nodes/edges)
/// and cannot keep pace during a 13M ingest -> checkpoints fall behind -> WAL +
/// dirty pages grow -> RSS climbs -> OOM. The light checkpoint is O(dirty).
///
/// This is SAFE: skipping the derived-index save leaves the on-disk snapshots
/// stale (their saved counter stays behind manifest.counter, which doCheckpoint
/// advances). On reopen, tryLoadDerivedIndexes() compares each snapshot's
/// counter to manifest.counter, finds them stale, returns false, and
/// rebuildDerivedIndexes() reconstructs them from the durable node/edge pages.
/// The pages are flushed and the WAL is truncated, so no data is lost.
pub fn checkpointLight(engine: *GraphEngine) anyerror!void {
    return checkpointEx(engine, false);
}

/// Core checkpoint implementation. When `save_derived` is false the
/// O(graph-size) derived-index snapshot save is skipped and the index dirty
/// flags are PRESERVED so a later full checkpoint (e.g. clean shutdown) still
/// persists them.
pub fn checkpointEx(engine: *GraphEngine, save_derived: bool) anyerror!void {
    // Lever B: a FULL checkpoint (save_derived=true) must still run when any
    // derived-index dirty flag is set, even if pages are clean
    // (persistence_dirty==false). A trailing checkpointLight clears
    // persistence_dirty and bumps manifest.counter but leaves the derived dirty
    // flags set; without this the clean-shutdown full checkpoint would skip the
    // derived save, leaving the snapshot stale-by-counter so a CLEAN restart
    // would do the O(graph) rebuildDerivedIndexes instead of an O(snapshot)
    // load. The LIGHT path passes save_derived=false, so derived_pending is
    // always false there — the light path stays O(dirty) (no derived save).
    // Crash-safety is unchanged: the load gate still requires the snapshot
    // counter == manifest.counter, and recovery bumps manifest.counter on WAL
    // replay, so a crash after the snapshot still forces a rebuild.
    const derived_pending = save_derived and
        (engine.label_index_dirty or engine.property_index_dirty or
            engine.edge_index_dirty or engine.edge_exist_index_dirty or
            engine.prop_rev_index_dirty or engine.ordered_index_dirty);
    // SONNY-6527: take the flag at the START. A set that lands while this
    // checkpoint runs (a label named from a broadcast worker thread) then
    // stays set for the next one instead of being cleared after the fact;
    // a failed checkpoint puts it back.
    const was_dirty = engine.persistence_dirty.swap(false, .acq_rel);
    if (!was_dirty and !derived_pending) {
        return;
    }
    errdefer engine.persistence_dirty.store(true, .release);

    // Update manifest counters before checkpoint
    refreshManifestCounters(engine);

    // Synchronous checkpoint: flush dirty pages, sync files, write
    // manifest.  Previous versions spawned a detached background thread
    // which could silently lose writes and made the timer meaningless.
    const start_ts = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
    engine.ensureSubmitterRegistered();
    // free.store is made durable inside the checkpoint, before the manifest
    // (SONNY-6491, see checkpointSideFiles).
    try engine.checkpointer.doCheckpointWith(preManifestStep(engine));
    // GAP-0900 L2: the derived-index snapshot save is the only O(graph-size)
    // step here. The light path skips it (recovery rebuilds from pages) and
    // leaves the dirty flags set so a later full checkpoint still persists them.
    // GAP warm-reopen P2: capture which gated snapshots were CLEAN at the
    // moment the dirty flags were consumed — those are the restamp candidates
    // at the end of this checkpoint (a dirty index is saved, NEVER restamped).
    var label_was_dirty = false;
    var property_was_dirty = false;
    var edge_was_dirty = false;
    var edge_exist_was_dirty = false;
    var prop_rev_was_dirty = false;
    if (save_derived) {
        label_was_dirty = engine.label_index_dirty;
        property_was_dirty = engine.property_index_dirty;
        edge_was_dirty = engine.edge_index_dirty;
        edge_exist_was_dirty = engine.edge_exist_index_dirty;
        prop_rev_was_dirty = engine.prop_rev_index_dirty;
        // WAL-aware durability: doCheckpoint (above) set
        // manifest.last_checkpoint_lsn to the LSN this checkpoint covered;
        // stamp the derived-index snapshots with it (paired with the advanced
        // checkpoint_epoch) so the next open's epoch gate can detect a tail.
        try engine_index.saveDerivedIndexesConditional(
            engine,
            label_was_dirty,
            property_was_dirty,
            edge_was_dirty,
            edge_exist_was_dirty,
            engine.manifest.last_checkpoint_lsn,
        );
        // PHASE G reverse map: persist it when dirty, stamped with the same
        // (epoch, covered_lsn) as the other derived snapshots so they load/gate
        // together. A clean map is restamped below (not re-saved).
        if (prop_rev_was_dirty) {
            try engine.prop_rev_index.saveToFile(
                engine.graph_dir.path,
                engine.manifest.checkpoint_epoch,
                engine.manifest.last_checkpoint_lsn,
            );
        }
        engine.label_index_dirty = false;
        engine.property_index_dirty = false;
        engine.edge_index_dirty = false;
        engine.edge_exist_index_dirty = false;
        engine.prop_rev_index_dirty = false;
        engine.metrics.derived_index_saves += 1;
        try engine.checkpointer.faultPoint(.post_derived);
    }
    // Label dictionary: NOT rebuildable from pages (it maps name<->id) and not
    // WAL-logged, so every new name is made durable when it is assigned
    // (GraphEngine.getOrAssignLabel, SONNY-6491); a checkpoint has nothing to
    // add.
    // GAP-0027: persist the index catalog + declared B+tree property indexes.
    // No-op when no index is declared (opt-in / backward compat).
    try engine_property_index.save(engine);

    // H3-P1 CHECKPOINT-REFRESH: on the FULL path, REBUILD the ordered trees from
    // a live-node scan BEFORE saving so in-place property-value drift is
    // corrected. The engine has no node-aware property-write hook, so an in-place
    // value change on a still-labelled node never updates the ordered tree (or
    // its dirty flag); mirror engine_property_index.refreshLive and self-heal at
    // the durability boundary. NOT gated on ordered_index_dirty — that flag is
    // only set by label-mutation hooks and would miss pure in-place drift. Gated
    // instead on a registered index existing, and only on the FULL path: the
    // LIGHT path (save_derived=false) skips this entirely so it stays O(dirty)
    // (the OOM-avoidance contract). The rebuild is serial (single scanNodes pass
    // in rebuildOrderedIndex); acceptable since full checkpoints are infrequent.
    // It marks the index dirty so the save block below persists the corrected
    // snapshot, stamped at the now-advanced manifest.counter for a clean reload.
    if (save_derived and engine.ordered_property_index.count() > 0) {
        try engine.rebuildOrderedIndex();
        engine.ordered_index_dirty = true;
        engine.metrics.ordered_index_refreshes += 1;
    }

    // GAP-0050: persist the value-ordered index on the FULL path only, gated on
    // its dirty flag (reuse the Lever-B derived gating). The light path passes
    // save_derived=false so it stays O(dirty); a stale-after-crash snapshot is
    // rejected by the Path B gate on open and rebuilt from a scan. The snapshot
    // is stamped at the NOW-advanced `(checkpoint_epoch, last_checkpoint_lsn)` —
    // the SAME token the derived snapshots just took — so a CLEAN reopen (epoch
    // current, no tail) LOADS it. The refresh above (rebuildOrderedIndex) ran
    // AFTER doCheckpoint with no intervening writes, so the trees reflect exactly
    // the covered_lsn (last_checkpoint_lsn) state.
    if (save_derived and engine.ordered_index_dirty) {
        var cipher = sideCipher(engine);
        defer if (cipher) |*c| c.deinit();
        try engine.ordered_property_index.saveToFileWith(
            engine.graph_dir.path,
            engine.manifest.checkpoint_epoch,
            engine.manifest.last_checkpoint_lsn,
            if (cipher) |*c| c else null,
        );
        engine.ordered_index_dirty = false;
        engine.metrics.ordered_index_saves += 1;
    }

    // GAP warm-reopen P2: cross-index counter re-stamp — the cure for "one
    // dirty index counter-invalidates every clean snapshot". ORDERING: this
    // runs LAST, strictly after (1) doCheckpoint durably wrote the manifest
    // at the advanced counter, (2) every dirty derived snapshot save
    // succeeded (stamped at that same counter), and (3) the label-dict /
    // B+tree-catalog / ordered-index saves succeeded — so a restamp can
    // never bless a clean snapshot while any part of this checkpoint failed
    // partway (an error above propagates out before we get here). A crash
    // anywhere before or during the restamps leaves each not-yet-restamped
    // file counter-stale (→ rebuild, safe) and a torn restamp is rejected by
    // the format's integrity check (→ rebuild, safe); see the per-format
    // restampStamps docs for the exact torn-write analysis.
    //
    // Gated on derived_snapshots_trusted: only when the clean snapshots are
    // KNOWN content-current for this session (established by create(), a
    // counter-gated load, or a rebuild-then-save — see the engine field doc).
    // Without the gate, a page-only session after a crash restart could
    // stamp crash-stale snapshots current = silent data loss. When untrusted
    // but this checkpoint saved ALL FOUR (post-rebuild path), the on-disk
    // set is now content-current by construction — record that so the NEXT
    // full checkpoint can restamp.
    if (save_derived) {
        if (engine.derived_snapshots_trusted) {
            try engine_index.restampCleanDerivedSnapshots(
                engine,
                !label_was_dirty,
                !property_was_dirty,
                !edge_was_dirty,
                !edge_exist_was_dirty,
                engine.manifest.last_checkpoint_lsn,
            );
            // PHASE G: restamp a CLEAN reverse map to the advanced epoch so a
            // partial checkpoint does not epoch-invalidate it (→ needless scan
            // rebuild on the next open). A dirty map was saved above.
            if (!prop_rev_was_dirty) {
                _ = try engine.prop_rev_index.restampFile(
                    engine.graph_dir.path,
                    engine.manifest.checkpoint_epoch,
                    engine.manifest.last_checkpoint_lsn,
                );
            }
        } else if (label_was_dirty and property_was_dirty and edge_was_dirty and edge_exist_was_dirty) {
            engine.derived_snapshots_trusted = true;
        }
    }

    const end_ts = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
    const elapsed = start_ts.durationTo(end_ts);
    engine.metrics.last_checkpoint_duration_ns = @intCast(elapsed.raw.toNanoseconds());
    engine.metrics.checkpoints_completed += 1;
}
