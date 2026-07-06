// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Index rebuild and persistence helpers extracted from engine.zig.

const std = @import("std");

const node_mod = @import("node.zig");
const types = @import("types.zig");
const engine_mod = @import("engine.zig");
const config_mod = @import("config.zig");

const NodeId = types.NodeId;
const NodeRec = node_mod.NodeRec;
const GraphEngine = engine_mod.GraphEngine;
const EdgeIndexEntry = engine_mod.EdgeIndexEntry;
const edge_index_map_mod = @import("edge_index_map.zig");
const edge_exist_index_mod = @import("edge_exist_index.zig");
const sorted_snapshot = @import("sorted_index_snapshot.zig");
// GAP warm-reopen P2 (counter restamp of clean snapshots):
const index_snapshot_mod = @import("index_snapshot.zig");
const label_index_mod = @import("label_index.zig");
const property_chain_index_mod = @import("property_chain_index.zig");
const file_manager_mod = @import("file_manager.zig");

/// File names of the two sorted edge snapshots, shared with FileManager so
/// the atomic-replace save (tmp + rename) and the fd reopen target the same
/// path.
const EDGE_IDX_NAME = file_manager_mod.FILE_NAMES[@intFromEnum(types.FileId.edge_idx)];
const EDGE_EXIST_IDX_NAME = file_manager_mod.FILE_NAMES[@intFromEnum(types.FileId.edge_exist_idx)];
// GAP-ENT-0024 P3 rule, still in force: the magic IS the snapshot format
// version — bumping it makes the loader REJECT an old snapshot outright
// (error.InvalidFormat → materializeDerivedIndexes' `catch false` → clean
// one-time rebuild from durable adjacency); an old file can never be
// misparsed, and an old binary rejects a new file the same way. Never reuse
// a retired magic ("GSEIDX2"/"GSEIDX3"/"GSXIDX1") for a future layout.
//
// GAP warm-reopen P1: "GSEIDX4" — same 40 B record fields as GSEIDX3 but in
// the SORTED mmap container (sorted_index_snapshot.zig): records ordered by
// edge_id, per-block CRC directory, loaded by mmap-adopt instead of a
// whole-file read + hashmap build.
const EDGE_SNAPSHOT_MAGIC = "GSEIDX4\x00";
const EDGE_RECORD_SIZE: u32 = edge_index_map_mod.RECORD_SIZE; // 40

// PHASE 3 existence index, same P1 treatment: "GSXIDX2" — 28 B GSXIDX1 record
// fields, sorted by (from, to, rel_type, edge_id) in the mmap container.
const EDGE_EXIST_SNAPSHOT_MAGIC = "GSXIDX2\x00";
const EDGE_EXIST_RECORD_SIZE: u32 = edge_exist_index_mod.RECORD_SIZE; // 28

/// Rebuild the in-memory label index by reading each live node's labels
/// from the LabelStore (var.store-backed).
/// PERF-0030: Uses scanNodes batch API instead of per-ID getNode.
pub fn rebuildLabelIndex(engine: *GraphEngine) !void {
    engine.label_index.clear();

    const Ctx = struct {
        engine: *GraphEngine,
        err: ?anyerror = null,

        fn callback(self: *@This(), node_id: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            if (rec.label_head == 0) return;

            const labels = self.engine.label_store.getLabels(rec.label_head, self.engine.allocator) catch return;
            defer self.engine.allocator.free(labels);

            for (labels) |label_id| {
                self.engine.label_index.addNode(label_id, node_id) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };

    var ctx = Ctx{ .engine = engine };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;
}

/// Rebuild the property chain index from all live nodes and their edges.
/// PERF-0030: Uses scanNodes batch API instead of per-ID getNode.
pub fn rebuildPropertyIndex(engine: *GraphEngine) !void {
    engine.property_index.clear();

    const Ctx = struct {
        engine: *GraphEngine,
        err: ?anyerror = null,

        fn callback(self: *@This(), _: NodeId, rec: NodeRec) void {
            if (self.err != null) return;

            self.engine.refreshPropertyChainIndex(rec.prop_head) catch |e| {
                self.err = e;
                return;
            };

            if (rec.out_head == 0) return;
            var iter = self.engine.adj_out.expand(rec.out_head, null);
            defer iter.deinit();
            while (iter.next() catch |e| {
                self.err = e;
                return;
            }) |entry| {
                self.engine.refreshPropertyChainIndex(entry.prop_head) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };

    var ctx = Ctx{ .engine = engine };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;
}

/// Rebuild all derived indexes (label, property, edge).
pub fn rebuildDerivedIndexes(engine: *GraphEngine) !void {
    config_mod.emitEvent(engine.config.log_fn, .index_build_start);
    defer config_mod.emitEvent(engine.config.log_fn, .index_build_end);
    // GAP-0026: Track index rebuild progress (0-10000).
    engine.metrics.index_rebuild_progress = 0;
    try rebuildLabelIndex(engine);
    engine.metrics.index_rebuild_progress = 3333;
    try rebuildPropertyIndex(engine);
    engine.metrics.index_rebuild_progress = 6666;
    try rebuildEdgeIndex(engine);
    engine.metrics.index_rebuild_progress = 10000;
}

/// Rebuild the in-memory edge index by scanning each live node's outgoing
/// adjacency list.
/// PERF-0030: Uses scanNodes batch API instead of per-ID getNode.
pub fn rebuildEdgeIndex(engine: *GraphEngine) !void {
    engine.edge_index.clearAndFree();
    // PHASE 3: the edge-existence index is DERIVED from the same out-adjacency,
    // so rebuild it in the SAME scan. This is the recovery-correctness backbone:
    // whatever out-adjacency the WAL restored determines the existence index
    // EXACTLY, so a crash can never leave it disagreeing with adjacency.
    engine.edge_exist_index.clear();

    // PERF-0032: Pre-allocate edge_index based on manifest edge count.
    const estimated_edges: u32 = @intCast(@min(engine.manifest.next_edge_id, std.math.maxInt(u32)));
    if (estimated_edges > 1) {
        try engine.edge_index.ensureTotalCapacity(estimated_edges);
        try engine.edge_exist_index.ensureTotalCapacity(estimated_edges);
    }

    const Ctx = struct {
        engine: *GraphEngine,
        err: ?anyerror = null,

        fn callback(self: *@This(), node_id: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            if (rec.out_head == 0) return;

            var iter = self.engine.adj_out.expand(rec.out_head, null);
            defer iter.deinit();
            while (iter.next() catch |e| {
                self.err = e;
                return;
            }) |entry| {
                self.engine.edge_index.put(entry.edge_id, .{
                    .from = node_id,
                    .neighbor = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                    // P3: carried straight from the adjacency scan — v2 blocks
                    // yield the real inline id, v1 blocks yield 0 (readers fall
                    // back to the legacy id property for those).
                    .public_id = entry.public_id,
                }) catch |e| {
                    self.err = e;
                    return;
                };
                // (from = node_id, rel_type, to = neighbor) -> edge_id. `put` is
                // idempotent per edge_id, so re-applied/duplicated adjacency
                // entries never create a phantom record.
                self.engine.edge_exist_index.put(node_id, entry.rel_type, entry.neighbor, entry.edge_id) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };

    var ctx = Ctx{ .engine = engine };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;
}

/// Edge co-location (Phase B) — MIGRATION.
///
/// Rebuild THIS shard's co-located incoming-adjacency (`adj_in_remote` +
/// `in_head_dir`) from its OUT-adjacency, which is the authoritative, complete,
/// layout-INDEPENDENT edge set (every edge `(from on this shard)->(to)` appears
/// exactly once in `from`'s out-chain). For each out-edge we insert the mirror
/// in-entry `{neighbor=from, edge_id, rel_type, prop_head}` into THIS shard's
/// `adj_in_remote` keyed by `to` — the SAME single-shard write the co-located
/// add path does (`engine.addEdgeColocatedTxn`).
///
/// IDEMPOTENCY + CRASH-SAFETY (the migration is gated by the shard manifest's
/// `layout_version`; this runs only when it is < CURRENT):
///   * We first reset the `in_idx` + `in_dir` free space to EMPTY and zero every
///     existing `in_dir` page. This makes the starting state deterministic-empty
///     regardless of any partial state left by a crashed prior migration:
///       - chain bodies (`in_idx`): page allocation now restarts at page 1 and
///         is a deterministic function of the (unchanged) out-adjacency, so the
///         rebuild OVERWRITES every page a partial prior run could have touched.
///         AdjStore writes are slot-addressed with an authoritative block
///         `count`, and each chain-head write rewrites the block header
///         (`next_block`), so any stale bytes beyond `count` are never read.
///       - directory (`in_dir`): zeroing the pages makes `getHead` return 0 for
///         every dst until this pass writes its real head, so no stale head can
///         seed a chain.
///   * Writes go through the normal WAL `logPage` path inside bounded txns, and
///     the caller checkpoints + stamps `layout_version` LAST. A crash before the
///     stamp re-runs this (idempotent); a crash after it skips migration (the
///     pages are durable). adj_out is never mutated.
///
/// Bounded RSS: the scan streams (one chain at a time) and commits in batches of
/// `commit_batch` edges, checkpointing periodically so dirty pages do not grow
/// unbounded on a very large legacy graph (see MEMORY: geode deferred checkpoint
/// cadence). The final checkpoint is the caller's responsibility.
pub fn migrateColocateInEdges(engine: *GraphEngine) !void {
    // 1a. Zero every existing in_dir page so no stale dst->head survives, then
    //     reset the in_dir free space to empty. Zeroing is logged so it is
    //     crash-durable with the rebuild.
    {
        const txn = try engine.txn_manager.begin();
        errdefer engine.txn_manager.abort(txn) catch {};
        const dir_pages = if (engine.file_manager.getPager(.in_dir)) |p| (p.pageCount() catch 0) else 0;
        var pg: u64 = 0;
        while (pg < dir_pages) : (pg += 1) {
            try engine.zeroPageLogged(txn, .in_dir, pg);
        }
        try engine.txn_manager.commit(txn);
    }
    resetFreeSpaceEmpty(&engine.free_space_in_dir);
    // 1b. Reset the in_idx (chain body) free space to empty. The bodies are
    //     overwritten in-place by the deterministic rebuild (slot-addressed,
    //     count-authoritative), so they need no explicit zeroing.
    resetFreeSpaceEmpty(&engine.free_space_in_idx);

    // 2. Stream the out-adjacency and rebuild adj_in_remote keyed by `to`.
    const commit_batch: u32 = 4096;
    const Ctx = struct {
        engine: *GraphEngine,
        txn: u64,
        in_batch: u32 = 0,
        err: ?anyerror = null,

        fn flush(self: *@This()) !void {
            try self.engine.txn_manager.commit(self.txn);
            // A bounded checkpoint keeps dirty pages from growing unbounded on a
            // large legacy graph. Skips the O(graph) derived-index snapshot.
            try self.engine.checkpointLight();
            self.txn = try self.engine.txn_manager.begin();
            self.in_batch = 0;
        }

        fn callback(self: *@This(), node_id: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            if (rec.out_head == 0) return;

            var iter = self.engine.adj_out.expand(rec.out_head, null);
            defer iter.deinit();
            while (iter.next() catch |e| {
                self.err = e;
                return;
            }) |entry| {
                // Mirror in-entry for the co-located layout: neighbor = source
                // (this node), keyed by the edge's destination (entry.neighbor).
                const to = entry.neighbor;
                const in_entry = @import("edge.zig").EdgeEntry{
                    .neighbor = node_id,
                    .edge_id = entry.edge_id,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                    // Review F2: the rebuilt in-entry must carry the source
                    // entry's inline public id. Dropping it here (the old
                    // silent-default behavior) wiped every FanIn-route id when
                    // the colocation migration re-ran over a v2 store (e.g.
                    // after a lost/stale shard_manifest.json → layout_version 0).
                    .public_id = entry.public_id,
                };
                const old_head = self.engine.in_head_dir.getHead(to) catch |e| {
                    self.err = e;
                    return;
                };
                const new_head = self.engine.adj_in_remote.addEdge(old_head, in_entry) catch |e| {
                    self.err = e;
                    return;
                };
                const dir_page = self.engine.in_head_dir.setHead(to, new_head) catch |e| {
                    self.err = e;
                    return;
                };
                // Image every in_idx page the addEdge dirtied. `new_head` may be
                // a slab (block,slot) ref (not a page id) and a slab relocation
                // dirties several pages — the store records the exact set (with
                // slab packing off this is exactly [new_head], unchanged).
                for (self.engine.adj_in_remote.touchedPages()) |p| {
                    self.engine.logPagePublic(self.txn, .in_idx, p) catch |e| {
                        self.err = e;
                        return;
                    };
                }
                self.engine.logPagePublic(self.txn, .in_dir, dir_page) catch |e| {
                    self.err = e;
                    return;
                };
                self.in_batch += 1;
                if (self.in_batch >= commit_batch) {
                    self.flush() catch |e| {
                        self.err = e;
                        return;
                    };
                }
            }
        }
    };

    var ctx = Ctx{ .engine = engine, .txn = try engine.txn_manager.begin() };
    errdefer engine.txn_manager.abort(ctx.txn) catch {};
    engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback) catch |e| {
        return e;
    };
    if (ctx.err) |e| return e;
    try engine.txn_manager.commit(ctx.txn);
}

/// Reset a free-space bitmap to "only page 0 reserved" (genuinely empty store).
fn resetFreeSpaceEmpty(fsm: *@import("free_space.zig").FreeSpaceManager) void {
    var i: usize = 0;
    const total: usize = @intCast(fsm.total_pages);
    while (i < total) : (i += 1) fsm.bitmap.unset(i);
    fsm.bitmap.set(0); // page 0 is always reserved (bitmap metadata page)
}

/// Try to load persisted derived index snapshots. Returns true if they
/// match the current manifest counter.
pub fn tryLoadDerivedIndexes(engine: *GraphEngine) !bool {
    const label_file = engine.file_manager.getFile(.label_idx) orelse return false;
    const prop_file = engine.file_manager.getFile(.prop_idx) orelse return false;
    const edge_file = engine.file_manager.getFile(.edge_idx) orelse return false;
    // PHASE 3: the existence-index file is ADDITIVE. If it is missing entirely
    // (pre-Phase-3 graph), return false so the caller rebuilds ALL derived
    // indexes from durable adjacency — the existence index included.
    const edge_exist_file = engine.file_manager.getFile(.edge_exist_idx) orelse return false;

    engine.label_index.clear();
    engine.property_index.clear();
    engine.edge_index.clearAndFree();
    engine.edge_exist_index.clear();
    errdefer {
        engine.label_index.clear();
        engine.property_index.clear();
        engine.edge_index.clearAndFree();
        engine.edge_exist_index.clear();
    }

    const label_counter = try engine.label_index.loadFromFile(label_file) orelse return false;
    const prop_counter = try engine.property_index.loadFromFile(prop_file) orelse return false;
    const edge_counter = try loadEdgeIndex(engine, edge_file) orelse return false;
    // A pre-Phase-3 graph has an empty/absent existence snapshot → load returns
    // null → rebuild. A present-but-stale snapshot fails the counter check below.
    const edge_exist_counter = try loadEdgeExistIndex(engine, edge_exist_file) orelse return false;
    if (label_counter != engine.manifest.counter or
        prop_counter != engine.manifest.counter or
        edge_counter != engine.manifest.counter or
        edge_exist_counter != engine.manifest.counter)
    {
        engine.label_index.clear();
        engine.property_index.clear();
        engine.edge_index.clearAndFree();
        engine.edge_exist_index.clear();
        return false;
    }

    return true;
}

/// Save derived index snapshots to disk.
pub fn saveDerivedIndexes(engine: *GraphEngine) !void {
    const label_file = engine.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
    const prop_file = engine.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
    try engine.label_index.saveToFile(label_file, engine.manifest.counter);
    try engine.property_index.saveToFile(prop_file, engine.manifest.counter);
    try saveEdgeIndex(engine);
    try saveEdgeExistIndex(engine);
}

/// Save only the derived index snapshots whose dirty flag is set.
pub fn saveDerivedIndexesConditional(
    engine: *GraphEngine,
    label_dirty: bool,
    property_dirty: bool,
    edge_dirty: bool,
    edge_exist_dirty: bool,
) !void {
    if (label_dirty) {
        const label_file = engine.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
        try engine.label_index.saveToFile(label_file, engine.manifest.counter);
    }
    if (property_dirty) {
        const prop_file = engine.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
        try engine.property_index.saveToFile(prop_file, engine.manifest.counter);
    }
    if (edge_dirty) {
        try saveEdgeIndex(engine);
    }
    // PHASE 3: persist the existence-index snapshot when dirty (skipped by the
    // light checkpoint, exactly like edge_index — recovery rebuilds from pages).
    if (edge_exist_dirty) {
        try saveEdgeExistIndex(engine);
    }
}

/// GAP warm-reopen P2: after a successful FULL checkpoint, cheaply RE-STAMP
/// the persisted counter of every CLEAN gated snapshot to the (just advanced
/// and durably written) manifest.counter — a header-only update, the payload
/// is never rewritten. Without this, a session that dirties only SOME
/// indexes (e.g. edges-only ingest) counter-invalidates the untouched
/// snapshots: the all-four load gate then rejects the whole set on the next
/// open and pays the O(graph) rebuild for indexes that were semantically
/// current the entire time.
///
/// PRECONDITIONS (enforced by the caller, engine_persist.checkpointEx):
///   * runs LAST — strictly after doCheckpoint persisted manifest@counter,
///     after every dirty snapshot save, and after the label-dict / catalog /
///     ordered-index saves, so a restamp can never bless a snapshot while
///     any part of the checkpoint failed;
///   * a `*_clean` flag is only passed true when that index's dirty flag was
///     false when the saves were gated — a DIRTY index is saved, NEVER
///     restamped (its snapshot content is genuinely stale);
///   * engine.derived_snapshots_trusted is true — the clean snapshots are
///     KNOWN content-current for this session (see the field doc; without it
///     a crash-stale snapshot hiding behind clean flags could be blessed).
///
/// Crash-safety is delegated to the per-format restamp helpers: both are
/// old-counter-or-new-counter-or-rejected — a torn restamp fails the
/// format's integrity check at load and routes to the rebuild path. A
/// restamp helper returning false (missing/foreign/corrupt file) is left
/// as-is: that file stays counter-stale and the next open rebuilds, which is
/// always safe.
///
/// MAPPED-INODE NOTE: the edge/exist restamps may write the very inode a
/// live adopted base has mmap'd; that is safe by construction — see
/// sorted_index_snapshot.restampCounter. The legacy label/prop snapshots are
/// never mmap'd.
pub fn restampCleanDerivedSnapshots(
    engine: *GraphEngine,
    label_clean: bool,
    property_clean: bool,
    edge_clean: bool,
    edge_exist_clean: bool,
) !void {
    const counter = engine.manifest.counter;
    if (label_clean) {
        if (engine.file_manager.getFile(.label_idx)) |f| {
            if (try index_snapshot_mod.restampCounter(f, label_index_mod.SNAPSHOT_MAGIC, counter)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
    if (property_clean) {
        if (engine.file_manager.getFile(.prop_idx)) |f| {
            if (try index_snapshot_mod.restampCounter(f, property_chain_index_mod.SNAPSHOT_MAGIC, counter)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
    if (edge_clean) {
        if (engine.file_manager.getFile(.edge_idx)) |f| {
            if (try sorted_snapshot.restampCounter(engine.allocator, f, EDGE_SNAPSHOT_MAGIC, EDGE_RECORD_SIZE, counter)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
    if (edge_exist_clean) {
        if (engine.file_manager.getFile(.edge_exist_idx)) |f| {
            if (try sorted_snapshot.restampCounter(engine.allocator, f, EDGE_EXIST_SNAPSHOT_MAGIC, EDGE_EXIST_RECORD_SIZE, counter)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
}

// GAP warm-reopen P1: both edge snapshots now use the SORTED mmap container
// (sorted_index_snapshot.zig). The saver serializes the MERGED live view
// (overlay ⊕ base ⊖ tombstones — a never-mutated mmap-backed index never gets
// here because its dirty flag stays false, so the old snapshot file survives
// untouched), sorts the fixed-width records in place, and writes them with the
// per-block CRC directory. The loader mmap-adopts the file as the immutable
// base — NO whole-file read, NO hashmap build.
//
// P1 review C1 (mapped-inode rule): the save REPLACES the file atomically
// (tmp + fsync + rename via writeAtomicReplace) instead of truncating and
// rewriting it in place. A mid-session full checkpoint therefore never
// touches the inode the live adopted base has mmap'd — the base keeps
// serving the old inode (still the correct live view together with the
// overlay/tombstones) for the rest of the session, and the next open adopts
// the new file. The FileManager fd is reopened after the rename so later
// fd-based access (counter restamp, next-session-in-process loads) targets
// the CURRENT inode, not the replaced one.

fn saveEdgeIndex(engine: *GraphEngine) !void {
    const n = engine.edge_index.count();
    const payload = try engine.allocator.alloc(u8, n * EDGE_RECORD_SIZE);
    defer engine.allocator.free(payload);

    const Ctx = struct { buf: []u8, i: usize = 0 };
    var ctx = Ctx{ .buf = payload };
    try engine.edge_index.forEachLive(&ctx, struct {
        fn f(c: *Ctx, edge_id: u64, e: EdgeIndexEntry) anyerror!void {
            // forEachLive visits exactly count() live entries; a disagreement
            // here would mean the live-count invariant broke — fail loudly
            // rather than write a short/torn payload.
            if (c.i * EDGE_RECORD_SIZE >= c.buf.len) return error.InvalidFormat;
            edge_index_map_mod.encodeRecord(c.buf[c.i * EDGE_RECORD_SIZE ..][0..EDGE_RECORD_SIZE], edge_id, e);
            c.i += 1;
        }
    }.f);
    if (ctx.i != n) return error.InvalidFormat;

    sorted_snapshot.sortRecords(payload, EDGE_RECORD_SIZE, edge_index_map_mod.recordLess);
    try sorted_snapshot.writeAtomicReplace(
        engine.allocator,
        engine.graph_dir.path,
        EDGE_IDX_NAME,
        EDGE_SNAPSHOT_MAGIC,
        engine.manifest.counter,
        EDGE_RECORD_SIZE,
        payload,
    );
    try engine.file_manager.reopenFile(.edge_idx);
}

fn loadEdgeIndex(engine: *GraphEngine, file: *std.Io.File) !?u64 {
    // mmap-adopt: O(header + directory) instead of O(snapshot). Any error
    // (old GSEIDX3/GSEIDX2 magic, torn write, truncation, header/dir CRC)
    // propagates to materializeDerivedIndexes' `catch false` → clean rebuild.
    var loaded = (try sorted_snapshot.load(engine.allocator, file, EDGE_SNAPSHOT_MAGIC, EDGE_RECORD_SIZE)) orelse return null;
    errdefer loaded.deinit();
    // I1 (P1 review): arm the one-shot bit-rot self-invalidation — a lazy
    // payload ChecksumMismatch zeroes the file's magic so the NEXT open
    // rebuilds instead of re-adopting the corrupt snapshot forever.
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/{s}", .{ engine.graph_dir.path, EDGE_IDX_NAME });
    defer engine.allocator.free(path);
    try loaded.enableInvalidateOnCorruption(path);
    try engine.edge_index.adoptBase(loaded);
    return loaded.checkpoint_counter;
}

// ---------------------------------------------------------------------------
// PHASE 3: edge-existence index snapshot (mirrors saveEdgeIndex/loadEdgeIndex).
// ---------------------------------------------------------------------------

fn saveEdgeExistIndex(engine: *GraphEngine) !void {
    const n = engine.edge_exist_index.recordCount();
    const payload = try engine.allocator.alloc(u8, n * EDGE_EXIST_RECORD_SIZE);
    defer engine.allocator.free(payload);

    // One record per LIVE (key, edge_id); forEachRecord visits each exactly
    // once across primary + overflow + base−tombstones.
    const Ctx = struct { buf: []u8, i: usize = 0 };
    var ctx = Ctx{ .buf = payload };
    try engine.edge_exist_index.forEachRecord(&ctx, struct {
        fn f(c: *Ctx, from: u64, rel_type: u32, to: u64, edge_id: u64) anyerror!void {
            if (c.i * EDGE_EXIST_RECORD_SIZE >= c.buf.len) return error.InvalidFormat;
            edge_exist_index_mod.encodeRecord(
                c.buf[c.i * EDGE_EXIST_RECORD_SIZE ..][0..EDGE_EXIST_RECORD_SIZE],
                .{ .from = from, .to = to, .rel_type = rel_type, .edge_id = edge_id },
            );
            c.i += 1;
        }
    }.f);
    if (ctx.i != n) return error.InvalidFormat;

    sorted_snapshot.sortRecords(payload, EDGE_EXIST_RECORD_SIZE, edge_exist_index_mod.recordLess);
    try sorted_snapshot.writeAtomicReplace(
        engine.allocator,
        engine.graph_dir.path,
        EDGE_EXIST_IDX_NAME,
        EDGE_EXIST_SNAPSHOT_MAGIC,
        engine.manifest.counter,
        EDGE_EXIST_RECORD_SIZE,
        payload,
    );
    try engine.file_manager.reopenFile(.edge_exist_idx);
}

fn loadEdgeExistIndex(engine: *GraphEngine, file: *std.Io.File) !?u64 {
    var loaded = (try sorted_snapshot.load(engine.allocator, file, EDGE_EXIST_SNAPSHOT_MAGIC, EDGE_EXIST_RECORD_SIZE)) orelse return null;
    errdefer loaded.deinit();
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/{s}", .{ engine.graph_dir.path, EDGE_EXIST_IDX_NAME });
    defer engine.allocator.free(path);
    try loaded.enableInvalidateOnCorruption(path);
    try engine.edge_exist_index.adoptBase(loaded);
    return loaded.checkpoint_counter;
}
