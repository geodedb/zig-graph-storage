// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Edge property helpers extracted from engine.zig.
//! All functions take a `*GraphEngine` as the first parameter and are
//! called by the corresponding thin delegators in `GraphEngine`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const prop_store_mod = @import("prop_store.zig");
const engine_mod = @import("engine.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const PropertyValue = types.PropertyValue;
const PropStore = prop_store_mod.PropStore;
const GraphEngine = engine_mod.GraphEngine;

/// Scan the outgoing adjacency list of a node for a specific edge_id
/// and return its prop_head. Returns null if the edge was not found.
pub fn findEdgePropHead(engine: *GraphEngine, from_out_head: u64, edge_id: EdgeId) anyerror!?u32 {
    var iter = engine.adj_out.expand(from_out_head, null);
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
pub fn setEdgeProperty(engine: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
    // 1. Look up source node to get out_head
    const from_rec = (try engine.node_store.getNode(from)) orelse return error.NodeNotFound;

    // 2. Scan outgoing edges to find current prop_head for this edge_id
    const found_prop_head = (try findEdgePropHead(engine, from_rec.out_head, edge_id)) orelse return error.EdgeNotFound;

    // 3. Write property, get new prop_head
    const new_head_u64 = try engine.putProperty(@as(u64, found_prop_head), key, value);
    const new_head: u32 = std.math.cast(u32, new_head_u64) orelse return error.Overflow;

    // 4. If prop_head changed, update BOTH adjacency copies and edge index
    if (new_head != found_prop_head) {
        _ = try engine.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head);
        const to_rec = (try engine.node_store.getNode(to)) orelse return error.NodeNotFound;
        _ = try engine.adj_in.updateEdgePropHead(to_rec.in_head, edge_id, new_head);

        // Keep edge index prop_head in sync
        if (engine.edge_index.getPtr(edge_id)) |idx_entry| {
            idx_entry.prop_head = new_head;
        }
    }

    if (found_prop_head != 0 and found_prop_head != new_head) {
        engine.property_index.removeChain(found_prop_head);
    }
    try engine.refreshPropertyChainIndex(new_head_u64);
}

/// Remove a property from an edge. The removal is in-place so the prop_head
/// does not change.
pub fn removeEdgeProperty(engine: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
    const from_rec = (try engine.node_store.getNode(from)) orelse return error.NodeNotFound;

    const prop_head = (try findEdgePropHead(engine, from_rec.out_head, edge_id)) orelse return error.EdgeNotFound;
    if (prop_head == 0) return; // no properties to remove
    try engine.removeProperty(@as(u64, prop_head), key);
}

/// Read a single property from an edge.
pub fn getEdgeProperty(engine: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
    const from_rec = (try engine.node_store.getNode(from)) orelse return error.NodeNotFound;

    const prop_head = (try findEdgePropHead(engine, from_rec.out_head, edge_id)) orelse return null;
    if (prop_head == 0) return null;
    return engine.getProperty(@as(u64, prop_head), key, allocator);
}

/// Return an iterator over all properties on an edge.
pub fn getAllEdgeProperties(engine: *GraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
    const from_rec = (try engine.node_store.getNode(from)) orelse return error.NodeNotFound;

    const prop_head = (try findEdgePropHead(engine, from_rec.out_head, edge_id)) orelse return null;
    if (prop_head == 0) return null;
    return engine.prop_store.getAllProperties(@as(u64, prop_head));
}
