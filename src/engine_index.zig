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

    // PERF-0032: Pre-allocate edge_index based on manifest edge count.
    const estimated_edges: u32 = @intCast(@min(engine.manifest.next_edge_id, std.math.maxInt(u32)));
    if (estimated_edges > 1) {
        try engine.edge_index.ensureTotalCapacity(estimated_edges);
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

    engine.label_index.clear();
    engine.property_index.clear();
    engine.edge_index.clearAndFree();
    errdefer {
        engine.label_index.clear();
        engine.property_index.clear();
        engine.edge_index.clearAndFree();
    }

    const label_counter = try engine.label_index.loadFromFile(label_file) orelse return false;
    const prop_counter = try engine.property_index.loadFromFile(prop_file) orelse return false;
    const edge_counter = try loadEdgeIndex(engine, edge_file) orelse return false;
    if (label_counter != engine.manifest.counter or prop_counter != engine.manifest.counter or edge_counter != engine.manifest.counter) {
        engine.label_index.clear();
        engine.property_index.clear();
        engine.edge_index.clearAndFree();
        return false;
    }

    return true;
}

/// Save derived index snapshots to disk.
pub fn saveDerivedIndexes(engine: *GraphEngine) !void {
    const label_file = engine.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
    const prop_file = engine.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
    const edge_file = engine.file_manager.getFile(.edge_idx) orelse return error.EdgeIndexFileNotOpen;
    try engine.label_index.saveToFile(label_file, engine.manifest.counter);
    try engine.property_index.saveToFile(prop_file, engine.manifest.counter);
    try saveEdgeIndex(engine, edge_file);
}

/// Save only the derived index snapshots whose dirty flag is set.
pub fn saveDerivedIndexesConditional(
    engine: *GraphEngine,
    label_dirty: bool,
    property_dirty: bool,
    edge_dirty: bool,
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
