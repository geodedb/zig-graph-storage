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

fn edgeIndexEntry(engine: *GraphEngine, from: NodeId, edge_id: EdgeId) !engine_mod.EdgeIndexEntry {
    // Phase A: edge_index is deferred. Every edge-property accessor (get/set/
    // remove/getAll) flows through this single lookup chokepoint, so guarding
    // here covers all of them. setEdgeProperty additionally touches the
    // property_index chain, but materialize hydrates the whole derived set.
    try engine.ensureDerivedHydrated();
    const entry = (try engine.edge_index.get(edge_id)) orelse return error.EdgeNotFound;
    if (entry.from != from) return error.EdgeNotFound;
    return entry;
}

/// Set (or overwrite) a property on an edge identified by (from, to, edge_id).
/// Updates the prop_head in both the outgoing and incoming adjacency lists.
pub fn setEdgeProperty(engine: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
    const edge_entry = try edgeIndexEntry(engine, from, edge_id);
    if (edge_entry.neighbor != to) return error.EdgeNotFound;

    const from_rec = (try engine.node_store.getNode(from)) orelse return error.NodeNotFound;
    const found_prop_head = edge_entry.prop_head;

    // 3. Write property, get new prop_head.
    //    GAP prop-store slab packing (P5): edge property chains are
    //    LEGACY-ONLY. The head is packed as u32 below (adjacency entries +
    //    edge index), which cannot represent a slab head (tag bit 63), so
    //    slab allocation is gated off for this owner class.
    const new_head_u64 = try engine.putPropertyLegacy(@as(u64, found_prop_head), key, value);
    // Loud invariant guard: a slab-encoded head must never reach the u32
    // packing. Unreachable via the legacy-only put above; fails hard (never
    // truncates) if the gate is ever bypassed.
    if (prop_store_mod.isSlabHead(new_head_u64)) return error.UnexpectedSlabHead;
    const new_head: u32 = std.math.cast(u32, new_head_u64) orelse return error.Overflow;

    // 4. If prop_head changed, update BOTH adjacency copies and edge index.
    //    Edge co-location (Phase A): the incoming copy now lives in THIS shard's
    //    `adj_in_remote`, keyed by `to` via `in_head_dir` — NOT in `to.in_head`
    //    on the dst shard (which may not even be this engine). Both the out-chain
    //    and the in-chain are therefore on the source shard, so this single-engine
    //    update is correct (it was BROKEN for cross-shard edges before co-location,
    //    which only ever touched one engine). `to` is not resident here, so we do
    //    NOT read its NodeRec.
    if (new_head != found_prop_head) {
        _ = try engine.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head);
        const in_head = try engine.in_head_dir.getHead(to);
        _ = try engine.adj_in_remote.updateEdgePropHead(in_head, edge_id, new_head);

        // Keep edge index prop_head in sync (no-op if the edge is absent).
        // GAP warm-reopen P1: a base-resident entry is copied into the overlay
        // with the new head (the mmap base is immutable).
        try engine.edge_index.updatePropHead(edge_id, new_head);
        // P2 re-review F1: the in-memory edge index now diverges from the
        // persisted edges.idx snapshot, so it MUST be marked dirty at the
        // mutation point — otherwise a full checkpoint RESTAMPS the
        // clean-looking snapshot to the new counter with the OLD prop_head
        // content, and the next open silently loses the property linkage
        // (blessed-stale, the 0018-class silent-loss shape).
        engine.edge_index_dirty = true;
    }

    if (found_prop_head != 0 and found_prop_head != new_head) {
        engine.property_index.removeChain(found_prop_head);
    }
    try engine.refreshPropertyChainIndex(new_head_u64);
}

/// Remove a property from an edge. The removal is in-place so the prop_head
/// does not change.
pub fn removeEdgeProperty(engine: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
    const prop_head = (try edgeIndexEntry(engine, from, edge_id)).prop_head;
    if (prop_head == 0) return; // no properties to remove
    try engine.removeProperty(@as(u64, prop_head), key);
}

/// Read a single property from an edge.
pub fn getEdgeProperty(engine: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
    const prop_head = (try edgeIndexEntry(engine, from, edge_id)).prop_head;
    if (prop_head == 0) return null;
    return engine.getProperty(@as(u64, prop_head), key, allocator);
}

/// Return an iterator over all properties on an edge.
pub fn getAllEdgeProperties(engine: *GraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
    const prop_head = (try edgeIndexEntry(engine, from, edge_id)).prop_head;
    if (prop_head == 0) return null;
    return engine.prop_store.getAllProperties(@as(u64, prop_head));
}
