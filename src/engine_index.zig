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
// SEC-0051: v2 snapshot format appends a trailing CRC32 over the payload.
const EDGE_SNAPSHOT_MAGIC = "GSEIDX2\x00";

// SEC-0044/SEC-0048: smallest bytes a single edge-index record consumes on disk
// (edge_id u64 + from u64 + neighbor u64 + rel_type u32 + prop_head u32).
const EDGE_RECORD_MIN_SIZE: usize = 8 + 8 + 8 + 4 + 4;

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

        try engine.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = neighbor,
            .rel_type = rel_type,
            .prop_head = prop_head,
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
