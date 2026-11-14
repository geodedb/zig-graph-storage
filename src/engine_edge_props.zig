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
const engine_undo = @import("engine_undo.zig");

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
/// Auto-commit wrapper of `setEdgePropertyTxn`.
pub fn setEdgeProperty(engine: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
    // Edge-prop-head WAL imaging: ONE txn spans the property write AND the
    // in-place adjacency prop_head rewrites. The old shape committed the
    // property pages in their own auto-commit txn and then mutated the
    // adjacency blocks with NO WAL imaging at all — on crash replay the
    // property chain came back but nothing referenced it, silently losing
    // the committed property. Image exactly the page each rewrite mutated,
    // in the SAME txn, so replay is all-or-nothing.
    const txn = try engine.txn_manager.begin();
    errdefer engine_undo.abortFailedWrite(engine, txn);
    try setEdgePropertyTxn(engine, from, to, edge_id, key, value, txn);
    try engine.txn_manager.commit(txn);
}

/// SONNY-6529: `setEdgeProperty` inside the caller's transaction `txn`: the
/// property write, both adjacency copies' prop_head and the edge index,
/// every rewritten page imaged under `txn`. Undone by `abortTxn` when the
/// edge had no properties before the transaction (its first property; a
/// change to an existing chain makes the abort fail closed, see
/// `GraphConfig.abort_undo`). This is the call for a consumer that joins its
/// own transaction (geode's adapter) instead of rewriting the adjacency with
/// `AdjStore.updateEdgePropHead` + `logPagePublic`.
pub fn setEdgePropertyTxn(engine: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue, txn: u64) anyerror!void {
    const edge_entry = try edgeIndexEntry(engine, from, edge_id);
    if (edge_entry.neighbor != to) return error.EdgeNotFound;

    const from_rec = (try engine.node_store.getNode(from)) orelse return error.NodeNotFound;
    const found_prop_head = edge_entry.prop_head;

    // Write property, get new prop_head.
    //    GAP-0060: edge property chains slab-pack exactly like node props when
    //    `edge_prop_slab_packing` is on — the head is a full u64 (a prop-store
    //    slab head, bit 63) stored durably in the WIDE (v3 / slab-v3) adjacency
    //    entry + edge index. The routing is gated on the SAME flag as the
    //    adjacency `wide_heads`: a slab head must only ever be produced for a
    //    store whose adjacency can hold it (else a legacy v2 run can't take the
    //    wide head — the exact invariant `updateEdgePropHead*` enforces loudly).
    //    When off, edges keep the legacy one-page-per-edge writer (u32 head).
    //    putProperty*Txn also refreshes the property-chain index (and drops
    //    the old chain's entries when the head moved).
    const new_head: u64 = if (engine.config.edge_prop_slab_packing)
        try engine.putPropertyTxn(@as(u64, found_prop_head), key, value, txn)
    else
        try engine.putPropertyLegacyTxn(@as(u64, found_prop_head), key, value, txn);

    // If prop_head changed, update BOTH adjacency copies and edge index.
    //    Edge co-location (Phase A): the incoming copy lives in THIS shard's
    //    `adj_in_remote`, keyed by `to` via `in_head_dir` — NOT in `to.in_head`
    //    on the dst shard (which may not even be this engine). `to` is not
    //    resident here, so we do NOT read its NodeRec.
    if (new_head != found_prop_head) {
        // SONNY-6529: recorded before the rewrites, so a failure half-way is
        // undone too (the inverse rewrites both copies back to the old head).
        try engine_undo.reserve(engine, txn);
        engine_undo.recordEdgePropHead(engine, txn, from, to, edge_id, found_prop_head);
        // The entry may live in ANY block of either chain (not just the
        // head); AdjStore reports the exact PageId it mutated and that page
        // is WAL-imaged under the spanning txn. SONNY-6529: only the
        // adjacency pages are imaged. `from`'s node record does not change,
        // and the first-access tail reconcile finds the owner of every tail
        // `.adj_out` page through the edge index
        // (engine_index.reconcileDerivedIndexesFromTail, pass 3), so the
        // node-page image this used to add is not needed.
        if (try engine.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head)) |p| {
            try engine.logPage(txn, .adj_out, p);
        }
        const in_head = try engine.in_head_dir.getHead(to);
        if (try engine.adj_in_remote.updateEdgePropHead(in_head, edge_id, new_head)) |p| {
            try engine.logPage(txn, .in_idx, p);
        }

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
