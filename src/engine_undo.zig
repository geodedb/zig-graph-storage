// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SONNY-6529: recording and applying transaction undo (see txn_undo.zig for
//! the model). The `record*` helpers are called by the engine's write paths
//! right after the store mutation they describe, BEFORE the steps that can
//! still fail (WAL imaging, index maintenance), so a write that fails half-way
//! is undone too; every inverse tolerates the parts of its write that did not
//! happen. `abort` applies a journal.
//!
//! Lock order / threading: none of its own. Everything here runs under the
//! engine's single-writer contract, like the writes it records.

const std = @import("std");
const builtin = @import("builtin");

const engine_mod = @import("engine.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const types = @import("types.zig");
const txn_undo = @import("txn_undo.zig");
const BufferPool = @import("buffer_pool.zig").BufferPool;

const GraphEngine = engine_mod.GraphEngine;
const NodeRec = node_mod.NodeRec;
const NodeId = types.NodeId;
const UndoJournal = txn_undo.UndoJournal;
const UndoRec = txn_undo.UndoRec;
pub const Reason = txn_undo.Reason;

/// The journal writes of `txn` are recorded in, or null while an abort is
/// applying inverses (those are not recorded) or when `txn` is not active.
pub fn journalFor(engine: *GraphEngine, txn: u64) ?*UndoJournal {
    if (engine.undo_applying) return null;
    return engine.txn_manager.journal(txn);
}

/// Make room to record the write about to happen in `txn`, BEFORE it
/// mutates anything (see `UndoJournal.reserve`). An out-of-memory error
/// fails the write cleanly.
pub fn reserve(engine: *GraphEngine, txn: u64) !void {
    const j = journalFor(engine, txn) orelse return;
    try j.reserve(engine.allocator);
}

pub fn markNotUndoable(engine: *GraphEngine, txn: u64, reason: Reason) void {
    const j = journalFor(engine, txn) orelse return;
    j.fail(engine.allocator, reason);
}

fn push(engine: *GraphEngine, txn: u64, rec: UndoRec) ?usize {
    const j = journalFor(engine, txn) orelse return null;
    return j.push(engine.allocator, rec);
}

fn recAt(engine: *GraphEngine, txn: u64, idx: ?usize) ?*UndoRec {
    const i = idx orelse return null;
    const j = journalFor(engine, txn) orelse return null;
    if (j.not_undoable != null or i >= j.records.items.len) return null;
    return &j.records.items[i];
}

/// `putNodeTxn` wrote `after` over `before` (null: an empty slot).
pub fn recordNodePut(engine: *GraphEngine, txn: u64, id: NodeId, before: ?NodeRec, after: NodeRec) void {
    const j = journalFor(engine, txn) orelse return;
    if (before) |b| {
        // A pointer to a chain the caller manages itself cannot be put back
        // safely (the old chain may have been moved or freed meanwhile) —
        // unless the node is this transaction's own, which undo empties.
        const chain_changed = b.out_head != after.out_head or b.in_head != after.in_head or
            b.label_head != after.label_head or b.label_count != after.label_count;
        if (chain_changed and !j.nodeCreatedHere(id)) {
            j.fail(engine.allocator, .node_chain_pointer_changed);
            return;
        }
    } else {
        j.noteCreatedNode(engine.allocator, id);
    }
    _ = j.push(engine.allocator, .{ .node_put = .{ .id = id, .before = before, .after = after } });
}

pub fn recordNodeDelete(engine: *GraphEngine, txn: u64, id: NodeId) ?usize {
    return push(engine, txn, .{ .node_delete = .{ .id = id, .counted = false } });
}

pub fn markNodeDeleteCounted(engine: *GraphEngine, txn: u64, idx: ?usize) void {
    if (recAt(engine, txn, idx)) |r| r.node_delete.counted = true;
}

pub fn recordEdgeAdd(engine: *GraphEngine, txn: u64, from: NodeId, to: NodeId, edge_id: u64, colocated: bool) ?usize {
    return push(engine, txn, .{ .edge_add = .{ .from = from, .to = to, .edge_id = edge_id, .colocated = colocated, .counted = false } });
}

pub fn markEdgeAddCounted(engine: *GraphEngine, txn: u64, idx: ?usize) void {
    if (recAt(engine, txn, idx)) |r| r.edge_add.counted = true;
}

/// Before `removeEdgeTxn` mutates anything. `entry` is the edge index's
/// record of the edge (null: the index does not hold it).
pub fn recordEdgeRemove(engine: *GraphEngine, txn: u64, from: NodeId, to: NodeId, edge_id: u64, entry: ?engine_mod.EdgeIndexEntry) ?usize {
    const e = entry orelse return push(engine, txn, .{ .edge_remove = .{
        .from = from,
        .to = to,
        .edge_id = edge_id,
        .known = false,
        .rel_type = 0,
        .prop_head = 0,
        .public_id = 0,
        .out_removed = false,
        .in_removed = false,
        .counted = false,
    } });
    return push(engine, txn, .{ .edge_remove = .{
        .known = true,
        .from = from,
        .to = to,
        .edge_id = edge_id,
        .rel_type = e.rel_type,
        .prop_head = e.prop_head,
        .public_id = e.public_id,
        .out_removed = false,
        .in_removed = false,
        .counted = false,
    } });
}

pub const EdgeRemoveStep = enum { out_removed, in_removed, legacy_in_removed, counted };

/// A removal step happened. A removed chain entry the edge index did not
/// describe cannot be re-inserted: the transaction is then not undoable.
pub fn markEdgeRemove(engine: *GraphEngine, txn: u64, idx: ?usize, known: bool, step: EdgeRemoveStep) void {
    const r = recAt(engine, txn, idx) orelse return;
    if (!known and step != .counted) {
        markNotUndoable(engine, txn, .edge_removal_unknown_entry);
        return;
    }
    switch (step) {
        .out_removed => r.edge_remove.out_removed = true,
        .in_removed => r.edge_remove.in_removed = true,
        .legacy_in_removed => r.edge_remove.legacy_in_removed = true,
        .counted => r.edge_remove.counted = true,
    }
}

pub fn recordLabel(engine: *GraphEngine, txn: u64, node: NodeId, label: u32, added: bool) void {
    _ = push(engine, txn, if (added)
        .{ .label_add = .{ .node = node, .label = label } }
    else
        .{ .label_remove = .{ .node = node, .label = label } });
}

/// Before a property write (put or remove) on chain `owner`: reserve the
/// record, and when `owner` is a slab chain that existed before the
/// transaction, return a copy of its blob for the undo (owned by the caller
/// until handed to `notePropertyWrite`). Null for a new chain, a chain the
/// transaction created, a legacy chain, or when nothing is journaled.
pub fn capturePropertyChain(engine: *GraphEngine, txn: u64, owner: u64) !?[]u8 {
    const j = journalFor(engine, txn) orelse return null;
    try j.reserve(engine.allocator);
    // SONNY-6558: room for the overflow chains this write may release (at
    // most one per op; the store's bound), so deferring them cannot fail.
    try j.deferred_var_frees.ensureUnusedCapacity(engine.allocator, @import("prop_store.zig").PropStore.MAX_TOUCHED_VAR_REFS);
    if (owner == 0 or j.chainCreatedHere(owner) or j.not_undoable != null) return null;
    return engine.prop_store.slabBlobCopy(engine.allocator, owner);
}

/// A property write (put or remove) on chain `owner` succeeded and left the
/// chain at `new_head`; `pre` is what `capturePropertyChain` returned (owned
/// here from now on). A new chain (`owner == 0`) or one this transaction
/// created is referenced by nothing outside the transaction, so undoing it
/// only retires it. A slab chain that existed before is restored from `pre`.
/// A legacy chain cannot be put back: not undoable. SONNY-6558: an overflow
/// (var-store) chain whose stub the write replaced or removed is not freed by
/// the write (`deferVarFrees`) but at commit, so the restored blob's stub
/// still points at a live chain.
pub fn notePropertyWrite(engine: *GraphEngine, txn: u64, owner: u64, new_head: u64, pre: ?[]u8) void {
    const j = journalFor(engine, txn) orelse {
        if (pre) |b| engine.allocator.free(b);
        return;
    };
    // Capacity was reserved by `capturePropertyChain` (same journal).
    for (engine.prop_store.freedVarRefs()) |ref| j.deferred_var_frees.appendAssumeCapacity(ref);
    if (owner != 0 and !j.chainCreatedHere(owner)) {
        const blob = pre orelse {
            j.fail(engine.allocator, .property_on_existing_chain);
            return;
        };
        if (new_head != owner) j.noteCreatedChain(engine.allocator, new_head);
        _ = j.push(engine.allocator, .{ .prop_restore = .{ .owner = owner, .new_head = new_head, .old_blob = blob } });
        return;
    }
    if (pre) |b| engine.allocator.free(b);
    if (new_head == 0 or j.chainCreatedHere(new_head)) return;
    j.noteCreatedChain(engine.allocator, new_head);
    _ = j.push(engine.allocator, .{ .prop_chain = .{ .head = new_head } });
}

/// SONNY-6558: whether a property write in `txn` must leave the overflow
/// chains it releases allocated (the engine sets `PropStore.defer_var_frees`
/// to this around the write). True exactly when the write is journaled.
pub fn defersVarFrees(engine: *GraphEngine, txn: u64) bool {
    return journalFor(engine, txn) != null;
}

/// SONNY-6558: `TxnManager.commit_hook`. The transaction committed: release
/// the overflow chains its property writes replaced or removed. A failure
/// leaves the chain allocated (unreferenced) until compaction.
pub fn onCommit(ctx: *anyopaque, j: *UndoJournal) void {
    const engine: *GraphEngine = @ptrCast(@alignCast(ctx));
    for (j.deferred_var_frees.items) |ref| {
        engine.prop_store.var_store.free(ref) catch |err| {
            std.log.warn("graph-storage: freeing a replaced overflow value at commit failed ({s}); its pages stay allocated until compaction (SONNY-6558)", .{@errorName(err)});
        };
    }
    j.deferred_var_frees.clearRetainingCapacity();
}

/// SONNY-6648: `TxnManager.txn_hook`. A transaction began: hold the pages
/// it dirties (and every page dirtied while it is open) off disk.
pub fn onTxnBegan(ctx: *anyopaque) void {
    const engine: *GraphEngine = @ptrCast(@alignCast(ctx));
    engine.buffer_pool.beginTxnHold();
}

/// SONNY-6648: `TxnManager.txn_hook`. A transaction ended. When none is
/// open any more the held pages are committed or undone: writable again,
/// after a WAL sync under deferred commits. After an abort that could not
/// undo its writes (the engine is poisoned, set BEFORE the transaction is
/// ended) they stay held: those bytes must never reach disk.
pub fn onTxnEnded(ctx: *anyopaque) void {
    const engine: *GraphEngine = @ptrCast(@alignCast(ctx));
    const how: BufferPool.TxnEnd = if (engine.abort_not_undone != null)
        .keep
    else switch (engine.txn_manager.sync_mode) {
        .sync_each_commit => .release,
        .deferred => .after_wal_sync,
    };
    engine.buffer_pool.endTxnHold(how);
}

/// SONNY-6648: `BufferPool.wal_sync_hook`.
pub fn syncWalForPool(ctx: *anyopaque) anyerror!void {
    const engine: *GraphEngine = @ptrCast(@alignCast(ctx));
    try engine.wal.sync();
}

pub fn recordEdgePropHead(engine: *GraphEngine, txn: u64, from: NodeId, to: NodeId, edge_id: u64, old_head: u64) void {
    _ = push(engine, txn, .{ .edge_prop_head = .{ .from = from, .to = to, .edge_id = edge_id, .old_head = old_head } });
}

// ---------------------------------------------------------------------------
// Abort
// ---------------------------------------------------------------------------

/// End `txn` undoing its writes. See `GraphEngine.abortTxn`.
pub fn abort(engine: *GraphEngine, txn: u64) !void {
    if (!engine.txn_manager.isActive(txn)) return engine.txn_manager.abort(txn); // TxnNotFound / already ended
    const j_taken = engine.txn_manager.takeJournal(txn) orelse UndoJournal{};
    var j = j_taken;
    defer engine.txn_manager.recycleJournal(j);

    if (j.isEmpty()) return engine.txn_manager.abort(txn);
    if (engine.abort_not_undone != null) {
        // Already failed closed: no inverse may be logged now.
        try engine.txn_manager.abort(txn);
        return error.AbortNotUndone;
    }

    if (j.not_undoable) |reason| {
        // SONNY-6648: poison (fail_closed) BEFORE the transaction ends, so
        // its pages stay held (`onTxnEnded`).
        const refused = refuse(engine, reason);
        try engine.txn_manager.abort(txn);
        return refused;
    }

    // Apply the inverses in reverse order, logged under `txn`, then end it
    // with COMMIT so replay redoes them after its forward images.
    engine.undo_applying = true;
    defer engine.undo_applying = false;
    var i = j.records.items.len;
    var applied: usize = 0;
    while (i > 0) {
        try testCrashPoint(engine, applied);
        i -= 1;
        applyOne(engine, txn, j.records.items[i]) catch |err| {
            // Poisoned before the transaction ends (SONNY-6648, `onTxnEnded`).
            engine.abort_not_undone = .undo_failed;
            engine.txn_manager.abort(txn) catch {};
            std.log.warn("graph-storage: undoing aborted transaction {d} failed ({s}); refusing further writes and checkpoints (SONNY-6529)", .{ txn, @errorName(err) });
            return error.AbortNotUndone;
        };
        applied += 1;
    }
    try testCrashPoint(engine, applied);
    engine.txn_manager.commit(txn) catch |err| {
        engine.abort_not_undone = .undo_failed;
        engine.txn_manager.abort(txn) catch {};
        std.log.warn("graph-storage: ending undone transaction {d} failed ({s}); refusing further writes and checkpoints (SONNY-6529)", .{ txn, @errorName(err) });
        return error.AbortNotUndone;
    };
    engine.metrics.txn_aborts_undone += 1;
}

/// SONNY-6648 (tests only): stop the abort after `applied` inverses, as a
/// process dying there would (see `GraphEngine.test_abort_crash_after`).
fn testCrashPoint(engine: *const GraphEngine, applied: usize) error{TestCrashInjected}!void {
    if (comptime !builtin.is_test) return;
    if (engine.test_abort_crash_after) |n| {
        if (n == applied) return error.TestCrashInjected;
    }
}

/// End `txn` after one of the engine's auto-commit writes failed inside it
/// (the wrappers' errdefer). Its inverses are applied in memory only and the
/// transaction is discarded: none of its records was committed, and under
/// the caller's write serialization no other transaction committed while it
/// ran, so no committed page image can carry its bytes — the restored pages
/// are dirty and reach disk with the next checkpoint. Logging nothing keeps
/// this path free of WAL allocations, so it also completes under the
/// out-of-memory condition that typically failed the write (GAP-ENT-0022(b)).
/// An inverse that still fails fails closed, as `abort` does.
pub fn abortFailedWrite(engine: *GraphEngine, txn: u64) void {
    if (!engine.txn_manager.isActive(txn)) return;
    const j_taken = engine.txn_manager.takeJournal(txn) orelse UndoJournal{};
    var j = j_taken;
    defer engine.txn_manager.recycleJournal(j);
    if (!j.isEmpty() and engine.abort_not_undone == null) {
        if (j.not_undoable) |reason| {
            refuse(engine, reason) catch {};
        } else {
            engine.undo_applying = true;
            engine.undo_no_log = true;
            defer {
                engine.undo_applying = false;
                engine.undo_no_log = false;
            }
            var i = j.records.items.len;
            while (i > 0) {
                i -= 1;
                applyOne(engine, txn, j.records.items[i]) catch |err| {
                    std.log.warn("graph-storage: undoing failed write in transaction {d} failed ({s}); refusing further writes and checkpoints (SONNY-6529)", .{ txn, @errorName(err) });
                    engine.abort_not_undone = .undo_failed;
                    break;
                };
            }
        }
    }
    engine.txn_manager.abort(txn) catch {};
}

fn refuse(engine: *GraphEngine, reason: Reason) !void {
    engine.metrics.txn_aborts_not_undone += 1;
    switch (engine.config.abort_undo) {
        .keep_writes => return,
        .fail_closed => {
            std.log.warn("graph-storage: aborted transaction cannot be undone ({s}); its writes stay in memory, and further writes and checkpoints are refused so they are never made durable: reopen the store (SONNY-6529)", .{@tagName(reason)});
            engine.abort_not_undone = reason;
            return error.AbortNotUndone;
        },
    }
}

fn applyOne(engine: *GraphEngine, txn: u64, rec: UndoRec) !void {
    switch (rec) {
        .node_put => |r| try undoNodePut(engine, txn, r.id, r.before, r.after),
        .node_delete => |r| try undoNodeDelete(engine, txn, r.id, r.counted),
        .edge_add => |r| try undoEdgeAdd(engine, txn, r.from, r.to, r.edge_id, r.colocated, r.counted),
        .edge_remove => |r| try undoEdgeRemove(engine, txn, r),
        .label_add => |r| try engine.removeLabelTxn(r.node, r.label, txn),
        .label_remove => |r| try engine.addLabelTxn(r.node, r.label, txn),
        .prop_chain => |r| try retireChain(engine, txn, r.head),
        .prop_restore => |r| {
            if (r.new_head != r.owner) try retireChain(engine, txn, r.new_head);
            if (try engine.prop_store.restoreSlabBlob(r.owner, r.old_blob)) |p| try engine.logPage(txn, .props, p);
            // Out of memory: drop the chain's entries instead — a chain the
            // property index does not hold is read from the store (the index
            // only short-cuts negative lookups), so this stays correct.
            engine.refreshPropertyChainIndex(r.owner) catch engine.property_index.removeChain(r.owner);
            engine.property_index_dirty = true;
            if (engine.ordered_property_index.count() > 0) engine.ordered_index_stale = true;
            engine.markDirty();
        },
        .edge_prop_head => |r| try undoEdgePropHead(engine, txn, r.from, r.to, r.edge_id, r.old_head),
    }
}

/// Nothing references chain `head` now: retire its slab slot (so a
/// crash-reopen's tail reconcile does not index it as live) and drop its
/// derived entries. Its bytes (and a legacy chain's pages) leak until
/// compaction.
fn retireChain(engine: *GraphEngine, txn: u64, head: u64) !void {
    if (try engine.prop_store.retireSlabChain(head)) |p| try engine.logPage(txn, .props, p);
    engine.property_index.removeChain(head);
    engine.property_index_dirty = true;
    if (engine.derived_hydrated.load(.acquire)) {
        if (engine.prop_rev_index.owner(head) != null) {
            engine.prop_rev_index.remove(head);
            engine.prop_rev_index_dirty = true;
        }
    }
    if (engine.ordered_property_index.count() > 0) engine.ordered_index_stale = true;
    engine.markDirty();
}

fn writeSlot(engine: *GraphEngine, txn: u64, id: NodeId, rec: NodeRec) !void {
    try engine.node_store.putNode(id, rec);
    try engine.logPage(txn, .nodes, engine.nodePageId(id));
    engine.markDirty();
}

fn undoNodePut(engine: *GraphEngine, txn: u64, id: NodeId, before: ?NodeRec, after: NodeRec) !void {
    const hydrated = engine.derived_hydrated.load(.acquire);
    const cur = (try engine.node_store.getRawSlot(id)) orelse std.mem.zeroes(NodeRec);
    const b = before orelse {
        // A create: the slot goes back to empty and allocNode's count and
        // (when nothing was allocated after it) id are given back. The
        // chains the transaction hung off it were all its own and are
        // already emptied by the inverses applied before this one; their
        // bytes leak until compaction.
        if (hydrated and cur.prop_head != 0) engine.prop_rev_index.remove(cur.prop_head);
        if (hydrated and cur.prop_head != 0) engine.prop_rev_index_dirty = true;
        try writeSlot(engine, txn, id, std.mem.zeroes(NodeRec));
        if (!node_mod.isEmpty(&cur) and !node_mod.isDeleted(&cur) and engine.manifest.node_count > 0)
            engine.manifest.node_count -= 1;
        const stride = engine.idStride();
        if (engine.manifest.next_node_id == id + stride) engine.manifest.next_node_id = id;
        if (engine.ordered_property_index.count() > 0) engine.ordered_index_stale = true;
        return;
    };
    // An update: put back each field this write changed and nothing has
    // changed since (another transaction's later write wins).
    var rec = cur;
    if (cur.prop_head == after.prop_head) rec.prop_head = b.prop_head;
    if (cur.flags == after.flags) rec.flags = b.flags;
    if (cur.txn_stamp == after.txn_stamp) rec.txn_stamp = b.txn_stamp;
    if (std.mem.eql(u8, &cur._pad, &after._pad)) rec._pad = b._pad;
    // out_head / in_head / label_head / label_count are never put back: a
    // change to one of them by this write made the transaction not undoable
    // (recordNodePut), unless the node is the transaction's own, which the
    // create's inverse empties.
    if (std.mem.eql(u8, std.mem.asBytes(&rec), std.mem.asBytes(&cur))) return;
    if (hydrated and rec.prop_head != cur.prop_head) {
        engine.prop_rev_index.remove(cur.prop_head);
        try engine.prop_rev_index.put(rec.prop_head, id);
        engine.prop_rev_index_dirty = true;
    }
    try writeSlot(engine, txn, id, rec);
    if (engine.ordered_property_index.count() > 0) engine.ordered_index_stale = true;
}

fn undoNodeDelete(engine: *GraphEngine, txn: u64, id: NodeId, counted: bool) !void {
    var rec = (try engine.node_store.getRawSlot(id)) orelse return;
    if (node_mod.isDeleted(&rec)) {
        rec.flags &= ~node_mod.NODE_FLAG_DELETED;
        try writeSlot(engine, txn, id, rec);
        if (engine.derived_hydrated.load(.acquire) and rec.prop_head != 0) {
            try engine.prop_rev_index.put(rec.prop_head, id);
            engine.prop_rev_index_dirty = true;
        }
    }
    if (counted) engine.manifest.node_count += 1;
    if (engine.ordered_property_index.count() > 0) engine.ordered_index_stale = true;
}

fn undoEdgeAdd(engine: *GraphEngine, txn: u64, from: NodeId, to: NodeId, edge_id: u64, colocated: bool, counted: bool) !void {
    // Out entry, from `from`'s current chain (the head may have moved).
    if (try engine.node_store.getRawSlot(from)) |from_rec| {
        if (try engine.adj_out.removeEdge(from_rec.out_head, edge_id)) |p| {
            try engine.logPage(txn, .adj_out, p);
            // As removeEdgeTxn: puts `from` in the tail-affected node set.
            try engine.logPage(txn, .nodes, engine.nodePageId(from));
        }
    }
    // In entry.
    if (colocated) {
        const in_head = try engine.in_head_dir.getHead(to);
        if (try engine.adj_in_remote.removeEdge(in_head, edge_id)) |p| try engine.logPage(txn, .in_idx, p);
    } else if (try engine.node_store.getRawSlot(to)) |to_rec| {
        if (try engine.adj_in.removeEdge(to_rec.in_head, edge_id)) |p| try engine.logPage(txn, .adj_in, p);
    }
    // Derived indexes (no-op for what the failed write never added).
    if (try engine.edge_index.get(edge_id)) |e| {
        try engine.edge_exist_index.remove(e.from, e.rel_type, e.neighbor, edge_id);
        engine.edge_exist_index_dirty = true;
    }
    try engine.edge_index.remove(edge_id);
    engine.edge_index_dirty = true;
    if (counted and engine.manifest.edge_count > 0) engine.manifest.edge_count -= 1;
    const stride = engine.idStride();
    if (engine.manifest.next_edge_id == edge_id + stride) engine.manifest.next_edge_id = edge_id;
    engine.markDirty();
}

fn undoEdgeRemove(engine: *GraphEngine, txn: u64, r: @FieldType(UndoRec, "edge_remove")) !void {
    // The index did not hold the edge: the removal took nothing out of it,
    // and a chain entry it took out made the transaction not undoable.
    if (!r.known) return;
    const out_entry = edge_mod.EdgeEntry{
        .neighbor = r.to,
        .edge_id = r.edge_id,
        .rel_type = r.rel_type,
        .prop_head = r.prop_head,
        .public_id = r.public_id,
    };
    if (r.out_removed) {
        var from_rec = (try engine.node_store.getRawSlot(r.from)) orelse return error.NodeNotFound;
        const new_head = try engine.adj_out.addEdge(from_rec.out_head, out_entry);
        errdefer engine.adj_out.undoLastSlabTombstone() catch {};
        if (new_head != from_rec.out_head) {
            from_rec.out_head = new_head;
            try engine.node_store.putNode(r.from, from_rec);
        }
        try engine.logTouchedAdj(txn, .adj_out, &engine.adj_out);
        try engine.logPage(txn, .nodes, engine.nodePageId(r.from));
    }
    if (r.in_removed) {
        const in_entry = edge_mod.EdgeEntry{
            .neighbor = r.from,
            .edge_id = r.edge_id,
            .rel_type = r.rel_type,
            .prop_head = r.prop_head,
            .public_id = r.public_id,
        };
        const old_in = try engine.in_head_dir.getHead(r.to);
        const new_in = try engine.adj_in_remote.addEdge(old_in, in_entry);
        errdefer engine.adj_in_remote.undoLastSlabTombstone() catch {};
        const dir_page = try engine.in_head_dir.setHead(r.to, new_in);
        try engine.logTouchedAdj(txn, .in_idx, &engine.adj_in_remote);
        try engine.logPage(txn, .in_dir, dir_page);
    }
    if (r.legacy_in_removed) {
        // SONNY-6558: back into the legacy `adj_in` chain of `to`.
        const in_entry = edge_mod.EdgeEntry{
            .neighbor = r.from,
            .edge_id = r.edge_id,
            .rel_type = r.rel_type,
            .prop_head = r.prop_head,
            .public_id = r.public_id,
        };
        var to_rec = (try engine.node_store.getRawSlot(r.to)) orelse return error.NodeNotFound;
        const new_head = try engine.adj_in.addEdge(to_rec.in_head, in_entry);
        errdefer engine.adj_in.undoLastSlabTombstone() catch {};
        if (new_head != to_rec.in_head) {
            to_rec.in_head = new_head;
            try engine.node_store.putNode(r.to, to_rec);
        }
        try engine.logTouchedAdj(txn, .adj_in, &engine.adj_in);
        try engine.logPage(txn, .nodes, engine.nodePageId(r.to));
    }
    // The index held the edge (else the record was refused): put it back
    // (idempotent when the removal failed before taking it out).
    {
        try engine.edge_index.put(r.edge_id, .{
            .from = r.from,
            .neighbor = r.to,
            .rel_type = r.rel_type,
            .prop_head = r.prop_head,
            .public_id = r.public_id,
        });
        engine.edge_index_dirty = true;
        try engine.edge_exist_index.put(r.from, r.rel_type, r.to, r.edge_id);
        engine.edge_exist_index_dirty = true;
        // SONNY-6558: the edge owns its chain again.
        if (r.prop_head != 0 and engine.derived_hydrated.load(.acquire)) {
            try engine.prop_rev_index.putEdge(r.prop_head, r.edge_id);
            engine.prop_rev_index_dirty = true;
        }
    }
    if (r.counted) engine.manifest.edge_count += 1;
    engine.markDirty();
}

fn undoEdgePropHead(engine: *GraphEngine, txn: u64, from: NodeId, to: NodeId, edge_id: u64, old_head: u64) !void {
    if (try engine.node_store.getRawSlot(from)) |from_rec| {
        if (try engine.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, old_head)) |p|
            try engine.logPage(txn, .adj_out, p);
    }
    const in_head = try engine.in_head_dir.getHead(to);
    if (try engine.adj_in_remote.updateEdgePropHead(in_head, edge_id, old_head)) |p|
        try engine.logPage(txn, .in_idx, p);
    // SONNY-6558: move the reverse map's edge entry back to `old_head`.
    if (engine.derived_hydrated.load(.acquire)) {
        if (try engine.edge_index.get(edge_id)) |e| engine.prop_rev_index.removeEdge(e.prop_head, edge_id);
        try engine.prop_rev_index.putEdge(old_head, edge_id);
        engine.prop_rev_index_dirty = true;
    }
    try engine.edge_index.updatePropHead(edge_id, old_head);
    engine.edge_index_dirty = true;
    if (old_head != 0) try engine.refreshPropertyChainIndex(old_head);
    engine.markDirty();
}
