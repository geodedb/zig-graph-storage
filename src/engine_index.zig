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
// a retired magic ("GSEIDX2"/"GSEIDX3"/"GSEIDX4"/"GSXIDX1"/"GSXIDX2") for a
// future layout.
//
// WAL-aware derived-index durability: the sorted-container header grew a
// second stamp field — checkpoint_epoch + covered_lsn (see
// sorted_index_snapshot.zig) — so the edge magics bump GSEIDX4 -> GSEIDX5 and
// GSXIDX2 -> GSXIDX3. Records are unchanged (40 B / 28 B), sorted, per-block
// CRC directory, loaded by mmap-adopt.
const EDGE_SNAPSHOT_MAGIC = "GSEIDX5\x00";
const EDGE_RECORD_SIZE: u32 = edge_index_map_mod.RECORD_SIZE; // 40

// PHASE 3 existence index: 28 B records sorted by (from, to, rel_type, edge_id)
// in the mmap container, under the bumped GSXIDX3 magic.
const EDGE_EXIST_SNAPSHOT_MAGIC = "GSXIDX3\x00";
const EDGE_EXIST_RECORD_SIZE: u32 = edge_exist_index_mod.RECORD_SIZE; // 28

// ---------------------------------------------------------------------------
// Shared per-node/per-edge DERIVATION helpers. Defined ONCE and called by BOTH
// the full rebuild (below) and the WAL-tail reconcile (reconcileDerivedIndexes-
// FromTail) so the derivation logic can never fork/drift between the two paths
// (the plan's explicit constraint). Each takes the CURRENT node record and adds
// that node's contribution to the derived indexes.
// ---------------------------------------------------------------------------

/// Derive one node's LABEL postings: (label -> node) for each of its labels.
pub fn indexNodeLabels(engine: *GraphEngine, node_id: NodeId, rec: NodeRec) !void {
    if (rec.label_head == 0) return;
    const labels = try engine.label_store.getLabels(rec.label_head, engine.allocator);
    defer engine.allocator.free(labels);
    for (labels) |label_id| {
        try engine.label_index.addNode(label_id, node_id);
    }
}

/// Derive one node's PROPERTY-chain entries: the node's own chain plus each of
/// its out-edges' chains (edge property chains are keyed by the edge's
/// prop_head, exactly as the full rebuild's property pass derives them).
pub fn indexNodeProperties(engine: *GraphEngine, rec: NodeRec) !void {
    try engine.refreshPropertyChainIndex(rec.prop_head);
    if (rec.out_head == 0) return;
    var iter = engine.adj_out.expand(rec.out_head, null);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        try engine.refreshPropertyChainIndex(entry.prop_head);
    }
}

/// Derive one node's EDGE entries: for each out-edge, the edge_index record
/// (edge_id -> {from, neighbor, rel_type, prop_head, public_id}) and the
/// edge-existence record ((from, rel_type, to) -> edge_id). `put` is idempotent
/// per key, so re-deriving an unchanged node is a no-op.
pub fn indexNodeEdges(engine: *GraphEngine, node_id: NodeId, rec: NodeRec) !void {
    if (rec.out_head == 0) return;
    var iter = engine.adj_out.expand(rec.out_head, null);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        try engine.edge_index.put(entry.edge_id, .{
            .from = node_id,
            .neighbor = entry.neighbor,
            .rel_type = entry.rel_type,
            .prop_head = entry.prop_head,
            .public_id = entry.public_id,
        });
        try engine.edge_exist_index.put(node_id, entry.rel_type, entry.neighbor, entry.edge_id);
    }
}

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
            indexNodeLabels(self.engine, node_id, rec) catch |e| {
                self.err = e;
            };
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
            indexNodeProperties(self.engine, rec) catch |e| {
                self.err = e;
            };
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
            // (from = node_id, rel_type, to = neighbor) -> edge_id plus the
            // edge_index record; both `put`s are idempotent per key so a
            // re-applied/duplicated adjacency entry never creates a phantom.
            indexNodeEdges(self.engine, node_id, rec) catch |e| {
                self.err = e;
            };
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
    // GAP adjacency slab packing (P2): the in_idx free space just reset to
    // empty, so any in-memory slab fill-block pointer is stale — drop it so the
    // rebuild's first slab append starts a fresh fill block from reset space.
    engine.adj_in_remote.current_fill_page = null;

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

/// Outcome of the derived-index load gate.
pub const LoadOutcome = enum {
    /// Snapshots missing/corrupt/epoch-mismatched → caller rebuilds O(graph).
    rebuild,
    /// Snapshots loaded AND cover the durable frontier (no tail) → serve as-is.
    loaded_clean,
    /// Snapshots loaded and epoch-matched, but a committed WAL tail exists
    /// beyond their covered_lsn. The adopted bases are KEPT (not cleared); the
    /// caller reconciles the bounded tail-affected pages into them.
    loaded_needs_reconcile,
};

/// Result of a WAL-tail reconcile.
pub const ReconcileResult = enum {
    /// The bounded tail was reconciled into the loaded snapshot.
    reconciled,
    /// The reconcile hit a page it could not decode exactly (e.g. a non-slab
    /// props page) and did a full rebuild instead — always correct, just slow.
    rebuilt,
};

/// Try to load persisted derived index snapshots. Returns a LoadOutcome:
/// `.loaded_clean` (serve directly), `.loaded_needs_reconcile` (bases kept;
/// caller reconciles the tail), or `.rebuild` (rebuild O(graph)).
///
/// WAL-aware durability (Path B) gate — TWO conditions, both required:
///   1. EPOCH MATCH. Each snapshot's durable `checkpoint_epoch` must equal
///      `manifest.checkpoint_epoch`. The epoch advances ONLY at checkpoint,
///      NEVER by a WAL-tail recovery (manifest.zig/checkpoint.zig/recovery.zig),
///      so a snapshot stamped at epoch E stays valid-as-of its covered LSN even
///      after a crash reopen that only replayed committed tail records — unlike
///      the old `manifest.counter` gate, which recovery bumped, needlessly
///      forcing an O(graph) rebuild. A genuine mismatch (a checkpoint ran after
///      the snapshot) → rebuild.
///   2. NO WAL TAIL BEYOND THE SNAPSHOT. When a committed tail exists past the
///      snapshot's `covered_lsn`, the loaded index does not reflect it. Phase 3
///      reconciles the bounded tail into the loaded index; until it lands,
///      Phase 2 routes the tail case to a FULL rebuild for CORRECTNESS — an
///      epoch-matching-but-tail-present snapshot must NEVER be served stale.
///      The tail is detected against the DURABLE COMMITTED FRONTIER,
///      `manifest.last_checkpoint_lsn`: a checkpoint sets it to the checkpoint
///      LSN (== the snapshots' covered_lsn); a WAL-tail recovery bumps it to the
///      replayed tail end (recovery.zig:517). It is NOT moved by this session's
///      own new writes — which matters because derived hydration is DEFERRED to
///      first-access, and that first access is often a WRITE (e.g. addEdge)
///      whose WAL append would spuriously advance the live `wal.currentLsn()`
///      past covered_lsn and fake a tail on a clean reopen. `last_checkpoint_lsn`
///      only moves at checkpoint/recovery, so `covered_lsn < last_checkpoint_lsn`
///      cleanly means "recovery replayed committed records the snapshot predates".
pub fn tryLoadDerivedIndexes(engine: *GraphEngine) !LoadOutcome {
    const label_file = engine.file_manager.getFile(.label_idx) orelse return .rebuild;
    const prop_file = engine.file_manager.getFile(.prop_idx) orelse return .rebuild;
    const edge_file = engine.file_manager.getFile(.edge_idx) orelse return .rebuild;
    // PHASE 3: the existence-index file is ADDITIVE. If it is missing entirely
    // (pre-Phase-3 graph), rebuild ALL derived indexes from durable adjacency —
    // the existence index included.
    const edge_exist_file = engine.file_manager.getFile(.edge_exist_idx) orelse return .rebuild;

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

    const label_stamp = try engine.label_index.loadFromFile(label_file) orelse return .rebuild;
    const prop_stamp = try engine.property_index.loadFromFile(prop_file) orelse return .rebuild;
    const edge_stamp = try loadEdgeIndex(engine, edge_file) orelse return .rebuild;
    // A pre-Phase-3 graph has an empty/absent existence snapshot → load returns
    // null → rebuild. A present-but-stale snapshot fails the epoch check below.
    const edge_exist_stamp = try loadEdgeExistIndex(engine, edge_exist_file) orelse return .rebuild;

    const epoch = engine.manifest.checkpoint_epoch;
    if (label_stamp.epoch != epoch or
        prop_stamp.epoch != epoch or
        edge_stamp.epoch != epoch or
        edge_exist_stamp.epoch != epoch)
    {
        // Genuine epoch mismatch → a checkpoint happened after these snapshots
        // → rebuild from durable node/edge pages.
        engine.label_index.clear();
        engine.property_index.clear();
        engine.edge_index.clearAndFree();
        engine.edge_exist_index.clear();
        return .rebuild;
    }

    // Epoch matches. Detect a committed WAL tail beyond the covered LSN using
    // the durable committed frontier (see condition 2 above), NOT the live WAL
    // position (which a deferred write-triggered hydration would have advanced).
    const durable_lsn = engine.manifest.last_checkpoint_lsn;
    const covered = @min(
        @min(label_stamp.covered_lsn, prop_stamp.covered_lsn),
        @min(edge_stamp.covered_lsn, edge_exist_stamp.covered_lsn),
    );

    // 3. MULTI-RECOVERY GUARD (the reconcile-completeness precondition). The
    //    captured tail-affected page set is only THIS session's recovery slice
    //    (start_lsn..currentLsn). It is a COMPLETE account of the committed
    //    records past the snapshot ONLY when the snapshot's covered_lsn equals
    //    the durable frontier as it stood BEFORE this recovery ran
    //    (`tail_pre_recovery_lsn` = start_lsn-1). If covered_lsn < that, a PRIOR
    //    recovery already advanced the frontier past the snapshot WITHOUT
    //    re-persisting it (two crashes, no checkpoint between) — reconciling
    //    only the latest slice would SILENTLY DROP the earlier tail's committed
    //    mutations from the derived indexes (they remain durable in the primary
    //    stores → the indexes would serve wrong answers). Force a FULL REBUILD.
    //    (An epoch match already rules out a post-snapshot checkpoint, so the
    //    only frontier-advancing events since the snapshot are recoveries; thus
    //    covered == pre_recovery ⟺ THIS is the first recovery since the
    //    snapshot ⟺ the captured slice is complete. covered > pre_recovery is a
    //    defensive impossibility — the manifest frontier only advances — and is
    //    also routed to rebuild.)
    if (covered != engine.tail_pre_recovery_lsn) {
        engine.metrics.derived_index_tail_deferred += 1;
        engine.label_index.clear();
        engine.property_index.clear();
        engine.edge_index.clearAndFree();
        engine.edge_exist_index.clear();
        return .rebuild;
    }

    if (covered < durable_lsn) {
        // epoch-match, covered == the pre-recovery frontier, AND this session's
        // recovery applied a committed tail (durable advanced past covered).
        // The captured set is COMPLETE → Phase 3 KEEPS the adopted bases and
        // reconciles ONLY the bounded tail-affected pages into them (O(tail)),
        // instead of the Phase-2 full rebuild. Counted for observability; the
        // caller runs reconcileDerivedIndexesFromTail and records
        // derived_index_reconciles.
        engine.metrics.derived_index_tail_deferred += 1;
        return .loaded_needs_reconcile;
    }

    return .loaded_clean;
}

/// WAL-aware derived-index durability Phase 3 — the correctness core.
///
/// Reconcile a bounded WAL tail into the just-loaded derived-index snapshots so
/// the result is IDENTICAL to a full rebuild over the current committed store,
/// touching only O(tail-affected-pages) instead of O(graph). Precondition: the
/// four snapshots were loaded (adopted as immutable bases) with EMPTY overlays
/// (tryLoadDerivedIndexes returned `.loaded_needs_reconcile`), so each base
/// holds exactly the derived state as of `covered_lsn`.
///
/// The tail touched only these primary files (others are irrelevant to the four
/// out-derived indexes and are ignored): `.nodes` and `.props`. `.adj_out`
/// changes always co-occur with a `.nodes` write of the owning node (addEdge
/// putNodes `from`; removeEdge is made to log `from`'s node page too), so the
/// node set drives the edge reconcile; label mutations always putNode; and a
/// node-page delete is a tombstoned slot. IN-PLACE property mutations rewrite
/// only the props page (never the node record), so they are reached via the
/// props-page slab-slot pass.
///
/// Per affected node: remove its OLD out-edges (enumerated from the immutable
/// edge-existence base by `from`) and its OLD label memberships, then EITHER
/// re-derive it fully (live) or drop its own property chain (deleted). This is
/// exactly the inverse-then-forward of the shared derivation helpers, so the
/// reconciled indexes equal a rebuild key-for-key.
///
/// Any props page that is not an unambiguous slab page routes to a full rebuild
/// (`.rebuilt`) — always correct, never a mis-decode.
pub fn reconcileDerivedIndexesFromTail(engine: *GraphEngine, pages: []const engine_mod.TailPage) !ReconcileResult {
    // Pass 1 — props pages: refresh (live slot) / drop (tombstoned slot) each
    // slab chain, reaching IN-PLACE property mutations that never touched a
    // node page. A non-slab props page → full rebuild.
    for (pages) |p| {
        if (p.file_id != .props) continue;
        const PropCtx = struct { engine: *GraphEngine };
        var pc = PropCtx{ .engine = engine };
        engine.prop_store.forEachSlabSlotOnPage(p.page_id, &pc, struct {
            fn f(c: *PropCtx, prop_head: u64, live: bool) anyerror!void {
                if (live) {
                    try c.engine.refreshPropertyChainIndex(prop_head);
                } else {
                    c.engine.property_index.removeChain(prop_head);
                }
            }
        }.f) catch |e| switch (e) {
            error.NotSlabPage => return fallbackRebuild(engine),
            else => return e,
        };
    }

    // Pass 2 — node pages: un-derive then re-derive each affected node.
    const npp = engine.node_store.nodes_per_page;
    const max_node = engine.manifest.next_node_id;
    for (pages) |p| {
        if (p.file_id != .nodes) continue;
        var slot: u64 = 0;
        while (slot < npp) : (slot += 1) {
            const node_id = p.page_id * npp + slot;
            if (node_id >= max_node) break;
            const rec = (try engine.node_store.getRawSlot(node_id)) orelse continue;
            try reconcileOneNode(engine, node_id, rec);
        }
    }

    return .reconciled;
}

/// Clear the (partially reconciled) derived indexes and rebuild them fully.
/// Always correct — the safe fallback whenever the reconcile cannot decode a
/// page exactly. Releases the adopted mmap bases via clear/clearAndFree.
fn fallbackRebuild(engine: *GraphEngine) !ReconcileResult {
    engine.label_index.clear();
    engine.property_index.clear();
    engine.edge_index.clearAndFree();
    engine.edge_exist_index.clear();
    try rebuildDerivedIndexes(engine);
    return .rebuilt;
}

/// Reconcile ONE tail-affected node into the loaded snapshot.
fn reconcileOneNode(engine: *GraphEngine, node_id: NodeId, rec: NodeRec) !void {
    // 1. Remove the node's OLD out-edges (edge_index + edge_exist + each such
    //    edge's property chain). Enumerated from the immutable edge-existence
    //    base keyed by `from` — these are the node's covered_lsn out-edges. A
    //    persisted edge is removed then re-added below (net unchanged); a
    //    deleted edge is removed and NOT re-added.
    try removeNodeOldEdges(engine, node_id);

    // 2. Remove the node from ALL label postings (its OLD label memberships).
    engine.label_index.removeNodeFromAll(node_id);

    if (node_mod.isDeleted(&rec)) {
        // Deleted node: drop its own property chain (deleteNode never touches
        // the props page, so pass 1 cannot). Its out-edges + their chains were
        // dropped in step 1; a full rebuild's scanNodes skips it entirely, so
        // the reconciled state (no labels, no chain, no out-edges) matches.
        engine.property_index.removeChain(rec.prop_head);
    } else {
        // Live node: re-derive its FULL current contribution — identical to the
        // shared rebuild derivation for this node.
        try indexNodeLabels(engine, node_id, rec);
        try indexNodeProperties(engine, rec);
        try indexNodeEdges(engine, node_id, rec);
    }
}

/// Remove every OLD (covered_lsn) out-edge of `node_id` from the edge_index and
/// edge-existence index (and drop each edge's property chain). Uses the sorted
/// edge-existence BASE range scan by `from` (overlay is empty at reconcile
/// start, so the base holds all of the node's snapshot out-edges).
fn removeNodeOldEdges(engine: *GraphEngine, node_id: NodeId) !void {
    const Ctx = struct { engine: *GraphEngine, from: NodeId };
    var c = Ctx{ .engine = engine, .from = node_id };
    try engine.edge_exist_index.forEachBaseFrom(node_id, &c, struct {
        fn f(cc: *Ctx, rel_type: u32, to: types.NodeId, edge_id: u64) anyerror!void {
            // A removed edge's property chain must not survive (a rebuild would
            // not index it). Look it up BEFORE removing the edge_index record.
            if (try cc.engine.edge_index.get(edge_id)) |e| {
                if (e.prop_head != 0) cc.engine.property_index.removeChain(e.prop_head);
            }
            try cc.engine.edge_exist_index.remove(cc.from, rel_type, to, edge_id);
            try cc.engine.edge_index.remove(edge_id);
        }
    }.f);
}

/// Save derived index snapshots to disk, stamped with the current
/// `checkpoint_epoch` and the `covered_lsn` of the checkpoint that produced
/// them (threaded from doCheckpoint via `manifest.last_checkpoint_lsn` — the
/// WAL LSN this checkpoint covered). See tryLoadDerivedIndexes for the gate.
pub fn saveDerivedIndexes(engine: *GraphEngine, covered_lsn: u64) !void {
    const label_file = engine.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
    const prop_file = engine.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
    const epoch = engine.manifest.checkpoint_epoch;
    try engine.label_index.saveToFile(label_file, epoch, covered_lsn);
    try engine.property_index.saveToFile(prop_file, epoch, covered_lsn);
    try saveEdgeIndex(engine, covered_lsn);
    try saveEdgeExistIndex(engine, covered_lsn);
}

/// Save only the derived index snapshots whose dirty flag is set, stamped with
/// the current `checkpoint_epoch` + `covered_lsn` (see saveDerivedIndexes).
pub fn saveDerivedIndexesConditional(
    engine: *GraphEngine,
    label_dirty: bool,
    property_dirty: bool,
    edge_dirty: bool,
    edge_exist_dirty: bool,
    covered_lsn: u64,
) !void {
    const epoch = engine.manifest.checkpoint_epoch;
    if (label_dirty) {
        const label_file = engine.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
        try engine.label_index.saveToFile(label_file, epoch, covered_lsn);
    }
    if (property_dirty) {
        const prop_file = engine.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
        try engine.property_index.saveToFile(prop_file, epoch, covered_lsn);
    }
    if (edge_dirty) {
        try saveEdgeIndex(engine, covered_lsn);
    }
    // PHASE 3: persist the existence-index snapshot when dirty (skipped by the
    // light checkpoint, exactly like edge_index — recovery rebuilds from pages).
    if (edge_exist_dirty) {
        try saveEdgeExistIndex(engine, covered_lsn);
    }
}

/// WAL-aware durability: after a successful FULL checkpoint, cheaply RE-STAMP
/// the persisted `(checkpoint_epoch, covered_lsn)` of every CLEAN gated
/// snapshot to the (just advanced and durably written) manifest epoch + the
/// checkpoint's covered LSN — a header-only update, the payload is never
/// rewritten. A clean index is unchanged, so it is valid as of the new
/// checkpoint's LSN; advancing BOTH stamps keeps it loadable AND tail-free on
/// the next open. Without this, a session that dirties only SOME indexes (e.g.
/// edges-only ingest) epoch-invalidates the untouched snapshots: the all-four
/// load gate then rejects the whole set on the next open and pays the O(graph)
/// rebuild for indexes that were semantically current the entire time.
///
/// `covered_lsn` is the checkpoint LSN this checkpoint covered (threaded from
/// doCheckpoint via manifest.last_checkpoint_lsn) — the SAME value the dirty
/// snapshots were just saved with, so all four end up covering the same LSN.
///
/// PRECONDITIONS (enforced by the caller, engine_persist.checkpointEx):
///   * runs LAST — strictly after doCheckpoint persisted manifest@epoch,
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
/// old-stamp-or-new-stamp-or-rejected — a torn restamp fails the format's
/// integrity check at load and routes to the rebuild path. A restamp helper
/// returning false (missing/foreign/corrupt file) is left as-is: that file
/// stays epoch-stale and the next open rebuilds, which is always safe.
///
/// MAPPED-INODE NOTE: the edge/exist restamps may write the very inode a
/// live adopted base has mmap'd; that is safe by construction — see
/// sorted_index_snapshot.restampStamps. The legacy label/prop snapshots are
/// never mmap'd.
pub fn restampCleanDerivedSnapshots(
    engine: *GraphEngine,
    label_clean: bool,
    property_clean: bool,
    edge_clean: bool,
    edge_exist_clean: bool,
    covered_lsn: u64,
) !void {
    const epoch = engine.manifest.checkpoint_epoch;
    if (label_clean) {
        if (engine.file_manager.getFile(.label_idx)) |f| {
            if (try index_snapshot_mod.restampStamps(f, label_index_mod.SNAPSHOT_MAGIC, epoch, covered_lsn)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
    if (property_clean) {
        if (engine.file_manager.getFile(.prop_idx)) |f| {
            if (try index_snapshot_mod.restampStamps(f, property_chain_index_mod.SNAPSHOT_MAGIC, epoch, covered_lsn)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
    if (edge_clean) {
        if (engine.file_manager.getFile(.edge_idx)) |f| {
            if (try sorted_snapshot.restampStamps(engine.allocator, f, EDGE_SNAPSHOT_MAGIC, EDGE_RECORD_SIZE, epoch, covered_lsn)) {
                engine.metrics.derived_index_restamps += 1;
            }
        }
    }
    if (edge_exist_clean) {
        if (engine.file_manager.getFile(.edge_exist_idx)) |f| {
            if (try sorted_snapshot.restampStamps(engine.allocator, f, EDGE_EXIST_SNAPSHOT_MAGIC, EDGE_EXIST_RECORD_SIZE, epoch, covered_lsn)) {
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

fn saveEdgeIndex(engine: *GraphEngine, covered_lsn: u64) !void {
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
        engine.manifest.checkpoint_epoch,
        covered_lsn,
        EDGE_RECORD_SIZE,
        payload,
    );
    try engine.file_manager.reopenFile(.edge_idx);
}

fn loadEdgeIndex(engine: *GraphEngine, file: *std.Io.File) !?index_snapshot_mod.Stamp {
    // mmap-adopt: O(header + directory) instead of O(snapshot). Any error
    // (old GSEIDX2/3/4 magic, torn write, truncation, header/dir CRC)
    // propagates to materializeDerivedIndexes' `catch false` → clean rebuild.
    var loaded = (try sorted_snapshot.load(engine.allocator, file, EDGE_SNAPSHOT_MAGIC, EDGE_RECORD_SIZE)) orelse return null;
    errdefer loaded.deinit();
    // I1 (P1 review): arm the one-shot bit-rot self-invalidation — a lazy
    // payload ChecksumMismatch zeroes the file's magic so the NEXT open
    // rebuilds instead of re-adopting the corrupt snapshot forever.
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/{s}", .{ engine.graph_dir.path, EDGE_IDX_NAME });
    defer engine.allocator.free(path);
    try loaded.enableInvalidateOnCorruption(path);
    const stamp = index_snapshot_mod.Stamp{ .epoch = loaded.checkpoint_epoch, .covered_lsn = loaded.covered_lsn };
    try engine.edge_index.adoptBase(loaded);
    return stamp;
}

// ---------------------------------------------------------------------------
// PHASE 3: edge-existence index snapshot (mirrors saveEdgeIndex/loadEdgeIndex).
// ---------------------------------------------------------------------------

fn saveEdgeExistIndex(engine: *GraphEngine, covered_lsn: u64) !void {
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
        engine.manifest.checkpoint_epoch,
        covered_lsn,
        EDGE_EXIST_RECORD_SIZE,
        payload,
    );
    try engine.file_manager.reopenFile(.edge_exist_idx);
}

fn loadEdgeExistIndex(engine: *GraphEngine, file: *std.Io.File) !?index_snapshot_mod.Stamp {
    var loaded = (try sorted_snapshot.load(engine.allocator, file, EDGE_EXIST_SNAPSHOT_MAGIC, EDGE_EXIST_RECORD_SIZE)) orelse return null;
    errdefer loaded.deinit();
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/{s}", .{ engine.graph_dir.path, EDGE_EXIST_IDX_NAME });
    defer engine.allocator.free(path);
    try loaded.enableInvalidateOnCorruption(path);
    const stamp = index_snapshot_mod.Stamp{ .epoch = loaded.checkpoint_epoch, .covered_lsn = loaded.covered_lsn };
    try engine.edge_exist_index.adoptBase(loaded);
    return stamp;
}
