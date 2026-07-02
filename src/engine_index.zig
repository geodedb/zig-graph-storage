// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Index rebuild and persistence helpers extracted from engine.zig.

const std = @import("std");

const node_mod = @import("node.zig");
const index_snapshot_mod = @import("index_snapshot.zig");
const types = @import("types.zig");
const engine_mod = @import("engine.zig");
const config_mod = @import("config.zig");

const NodeId = types.NodeId;
const NodeRec = node_mod.NodeRec;
const GraphEngine = engine_mod.GraphEngine;
const EdgeIndexEntry = engine_mod.EdgeIndexEntry;
// SEC-0051: snapshot format appends a trailing CRC32 over the payload.
// GAP-ENT-0024 P3: the magic IS the snapshot format version. "GSEIDX3"
// records are 40 B (+public_id u64); the previous "GSEIDX2" records were
// 32 B. Bumping the magic makes loadFile REJECT an old snapshot outright
// (error.InvalidFormat → materializeDerivedIndexes' `catch false` → clean
// one-time rebuild from durable adjacency) — an old file can never be
// misparsed at the 40 B stride, and an old binary rejects a new file the
// same way. Do NOT reuse "GSEIDX2" for any future layout.
const EDGE_SNAPSHOT_MAGIC = "GSEIDX3\x00";

// SEC-0044/SEC-0048: smallest bytes a single edge-index record consumes on disk
// (edge_id u64 + from u64 + neighbor u64 + rel_type u32 + prop_head u32 +
//  public_id u64).
const EDGE_RECORD_MIN_SIZE: usize = 8 + 8 + 8 + 4 + 4 + 8;

// PHASE 3: edge-EXISTENCE index snapshot. Distinct magic so a wrong/legacy file
// is rejected rather than misparsed; one record is (from u64 + to u64 + rel_type
// u32 + edge_id u64).
const EDGE_EXIST_SNAPSHOT_MAGIC = "GSXIDX1\x00";
const EDGE_EXIST_RECORD_MIN_SIZE: usize = 8 + 8 + 4 + 8;

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
                self.engine.logPagePublic(self.txn, .in_idx, new_head) catch |e| {
                    self.err = e;
                    return;
                };
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
    const edge_file = engine.file_manager.getFile(.edge_idx) orelse return error.EdgeIndexFileNotOpen;
    const edge_exist_file = engine.file_manager.getFile(.edge_exist_idx) orelse return error.EdgeExistIndexFileNotOpen;
    try engine.label_index.saveToFile(label_file, engine.manifest.counter);
    try engine.property_index.saveToFile(prop_file, engine.manifest.counter);
    try saveEdgeIndex(engine, edge_file);
    try saveEdgeExistIndex(engine, edge_exist_file);
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
        const edge_file = engine.file_manager.getFile(.edge_idx) orelse return error.EdgeIndexFileNotOpen;
        try saveEdgeIndex(engine, edge_file);
    }
    // PHASE 3: persist the existence-index snapshot when dirty (skipped by the
    // light checkpoint, exactly like edge_index — recovery rebuilds from pages).
    if (edge_exist_dirty) {
        const edge_exist_file = engine.file_manager.getFile(.edge_exist_idx) orelse return error.EdgeExistIndexFileNotOpen;
        try saveEdgeExistIndex(engine, edge_exist_file);
    }
}

fn saveEdgeIndex(engine: *GraphEngine, file: *std.Io.File) !void {
    // PERF-0052: serialize the entire snapshot into one in-memory buffer and
    // flush it with a single positional write instead of ~5 syscalls per edge.
    // The byte layout (magic | counter | item_count | payload | crc32) is
    // identical to the previous per-field path; CRC32 (SEC-0051) is appended by
    // finalize().
    var w = index_snapshot_mod.SnapshotWriter.init(engine.allocator);
    defer w.deinit();

    try w.writeHeader(EDGE_SNAPSHOT_MAGIC, engine.manifest.counter, engine.edge_index.count());

    var it = engine.edge_index.iterator();
    while (it.next()) |entry| {
        try w.writeU64(entry.key_ptr.*);
        try w.writeU64(entry.value_ptr.from);
        try w.writeU64(entry.value_ptr.neighbor);
        try w.writeU32(entry.value_ptr.rel_type);
        try w.writeU32(entry.value_ptr.prop_head);
        // P3 (GSEIDX3): 40 B record — trailing inline public id.
        try w.writeU64(entry.value_ptr.public_id);
    }

    try w.finalize(file.*);
}

fn loadEdgeIndex(engine: *GraphEngine, file: *std.Io.File) !?u64 {
    // PERF-0052: read + validate the whole snapshot once (CRC32 verified per
    // SEC-0051; item_count bounded vs payload per SEC-0044/0048), then walk the
    // resident payload instead of issuing ~5 positional reads per edge.
    var snapshot = (try index_snapshot_mod.loadPayload(engine.allocator, file, EDGE_SNAPSHOT_MAGIC, EDGE_RECORD_MIN_SIZE)) orelse return null;
    defer snapshot.deinit();

    var r = index_snapshot_mod.SnapshotReader.init(snapshot.payload());

    // SEC-0044/SEC-0048: item_count was bounded against payload_size in
    // loadPayload, so this reservation cannot be driven past the available bytes.
    // Guard the u64-to-u32 cast: a crafted snapshot with item_count > maxInt(u32)
    // would panic in ReleaseSafe without this check (DoS via integer overflow).
    if (snapshot.item_count > std.math.maxInt(u32)) return error.InvalidFormat;
    try engine.edge_index.ensureTotalCapacity(@intCast(snapshot.item_count));

    var i: u64 = 0;
    while (i < snapshot.item_count) : (i += 1) {
        const edge_id = try r.readU64();
        const from = try r.readU64();
        const neighbor = try r.readU64();
        const rel_type = try r.readU32();
        const prop_head = try r.readU32();
        // P3 (GSEIDX3): 40 B record — trailing inline public id. An OLD 32 B
        // snapshot never reaches this reader (magic-rejected in loadPayload).
        const public_id = try r.readU64();

        try engine.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = neighbor,
            .rel_type = rel_type,
            .prop_head = prop_head,
            .public_id = public_id,
        });
    }

    if (r.remaining() != 0) return error.InvalidFormat;
    return snapshot.checkpoint_counter;
}

// ---------------------------------------------------------------------------
// PHASE 3: edge-existence index snapshot (mirrors saveEdgeIndex/loadEdgeIndex).
// ---------------------------------------------------------------------------

const SnapshotWriterT = index_snapshot_mod.SnapshotWriter;

fn saveEdgeExistIndex(engine: *GraphEngine, file: *std.Io.File) !void {
    var w = SnapshotWriterT.init(engine.allocator);
    defer w.deinit();

    try w.writeHeader(EDGE_EXIST_SNAPSHOT_MAGIC, engine.manifest.counter, engine.edge_exist_index.recordCount());

    // Write one record per (key, edge_id). forEachRecord visits every record
    // exactly once across both the primary and overflow maps.
    const Ctx = struct { w: *SnapshotWriterT };
    var ctx = Ctx{ .w = &w };
    try engine.edge_exist_index.forEachRecord(&ctx, struct {
        fn f(c: *Ctx, from: u64, rel_type: u32, to: u64, edge_id: u64) anyerror!void {
            try c.w.writeU64(from);
            try c.w.writeU64(to);
            try c.w.writeU32(rel_type);
            try c.w.writeU64(edge_id);
        }
    }.f);

    try w.finalize(file.*);
}

fn loadEdgeExistIndex(engine: *GraphEngine, file: *std.Io.File) !?u64 {
    var snapshot = (try index_snapshot_mod.loadPayload(engine.allocator, file, EDGE_EXIST_SNAPSHOT_MAGIC, EDGE_EXIST_RECORD_MIN_SIZE)) orelse return null;
    defer snapshot.deinit();

    var r = index_snapshot_mod.SnapshotReader.init(snapshot.payload());

    if (snapshot.item_count > std.math.maxInt(u32)) return error.InvalidFormat;
    try engine.edge_exist_index.ensureTotalCapacity(@intCast(snapshot.item_count));

    var i: u64 = 0;
    while (i < snapshot.item_count) : (i += 1) {
        const from = try r.readU64();
        const to = try r.readU64();
        const rel_type = try r.readU32();
        const edge_id = try r.readU64();
        try engine.edge_exist_index.put(from, rel_type, to, edge_id);
    }

    if (r.remaining() != 0) return error.InvalidFormat;
    return snapshot.checkpoint_counter;
}
