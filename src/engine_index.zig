// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Index rebuild and persistence helpers extracted from engine.zig.

const std = @import("std");

const node_mod = @import("node.zig");
const engine_mod = @import("engine.zig");

const GraphEngine = engine_mod.GraphEngine;
const EdgeIndexEntry = engine_mod.EdgeIndexEntry;

/// Rebuild the in-memory label index by reading each live node's labels
/// from the LabelStore (var.store-backed).
pub fn rebuildLabelIndex(engine: *GraphEngine) !void {
    engine.label_index.clear();

    var id: u64 = 1;
    while (id < engine.manifest.next_node_id) : (id += 1) {
        const rec = engine.node_store.getNode(id) catch continue orelse continue;
        if (node_mod.isDeleted(&rec) or node_mod.isEmpty(&rec)) continue;
        if (rec.label_head == 0) continue;

        const labels = engine.label_store.getLabels(rec.label_head, engine.allocator) catch continue;
        defer engine.allocator.free(labels);

        for (labels) |label_id| {
            try engine.label_index.addNode(label_id, id);
        }
    }
}

/// Rebuild the property chain index from all live nodes and their edges.
pub fn rebuildPropertyIndex(engine: *GraphEngine) !void {
    engine.property_index.clear();

    var id: u64 = 1;
    while (id < engine.manifest.next_node_id) : (id += 1) {
        const rec = engine.node_store.getNode(id) catch continue orelse continue;
        if (node_mod.isDeleted(&rec) or node_mod.isEmpty(&rec)) continue;

        try engine.refreshPropertyChainIndex(rec.prop_head);

        if (rec.out_head == 0) continue;
        var iter = engine.adj_out.expand(rec.out_head, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            try engine.refreshPropertyChainIndex(entry.prop_head);
        }
    }
}

/// Rebuild all derived indexes (label, property, edge).
pub fn rebuildDerivedIndexes(engine: *GraphEngine) !void {
    try rebuildLabelIndex(engine);
    try rebuildPropertyIndex(engine);
    try rebuildEdgeIndex(engine);
}

/// Rebuild the in-memory edge index by scanning each live node's outgoing
/// adjacency list.
pub fn rebuildEdgeIndex(engine: *GraphEngine) !void {
    engine.edge_index.clearAndFree();

    // PERF-0032: Pre-allocate edge_index based on manifest edge count.
    const estimated_edges: u32 = @intCast(@min(engine.manifest.next_edge_id, std.math.maxInt(u32)));
    if (estimated_edges > 1) {
        try engine.edge_index.ensureTotalCapacity(estimated_edges);
    }

    var id: u64 = 1;
    while (id < engine.manifest.next_node_id) : (id += 1) {
        const rec = engine.node_store.getNode(id) catch continue orelse continue;
        if (node_mod.isDeleted(&rec) or node_mod.isEmpty(&rec)) continue;
        if (rec.out_head == 0) continue;

        var iter = engine.adj_out.expand(rec.out_head, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            try engine.edge_index.put(entry.edge_id, .{
                .from = id,
                .neighbor = entry.neighbor,
                .rel_type = entry.rel_type,
                .prop_head = entry.prop_head,
            });
        }
    }
}

/// Try to load persisted derived index snapshots. Returns true if they
/// match the current manifest counter.
pub fn tryLoadDerivedIndexes(engine: *GraphEngine) !bool {
    const label_file = engine.file_manager.getFile(.label_idx) orelse return false;
    const prop_file = engine.file_manager.getFile(.prop_idx) orelse return false;

    engine.label_index.clear();
    engine.property_index.clear();
    errdefer {
        engine.label_index.clear();
        engine.property_index.clear();
    }

    const label_counter = try engine.label_index.loadFromFile(label_file) orelse return false;
    const prop_counter = try engine.property_index.loadFromFile(prop_file) orelse return false;
    if (label_counter != engine.manifest.counter or prop_counter != engine.manifest.counter) {
        engine.label_index.clear();
        engine.property_index.clear();
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
}
