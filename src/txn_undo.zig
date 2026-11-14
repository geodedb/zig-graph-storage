// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SONNY-6529: per-transaction undo journal.
//!
//! The engine applies every write to its pages in place, in the buffer pool,
//! before commit; the WAL carries page after-images and recovery redoes
//! committed transactions only. To abort a transaction the engine therefore
//! undoes its writes LOGICALLY: while the transaction runs, each engine write
//! records what it changed (one `UndoRec` per write), and `abortTxn` applies
//! the inverses in reverse order through the same engine paths, logging
//! their page images under the aborting transaction, then ends it with a
//! COMMIT record. Replay of that transaction (forward images, then the
//! inverse images at later LSNs) reproduces the state before it began; a
//! crash before the COMMIT record leaves the whole transaction unreplayed.
//! Inverses are record-level (one node slot, one edge entry, one label), so
//! they leave other transactions' writes on shared pages alone.
//!
//! A write whose exact inverse the engine cannot produce sets
//! `not_undoable` instead (see `Reason`); aborting such a transaction fails
//! closed (`error.AbortNotUndone`).
//!
//! Owned by `TxnManager` (one journal per active transaction, freed at
//! commit/abort). Accessed only under the engine's single-writer contract.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");

const NodeRec = node_mod.NodeRec;

/// Records a journal may hold before it gives up (≈ 64 MiB). A transaction
/// past this can no longer be undone and fails closed on abort.
pub const MAX_RECORDS: usize = 1 << 20;

/// Why a transaction cannot be undone.
pub const Reason = enum {
    /// A property write changed a chain that existed before the transaction
    /// and that cannot be put back byte for byte: a legacy (non-slab) chain,
    /// or a replaced value whose overflow chain the write freed.
    property_on_existing_chain,
    /// `putNodeTxn` changed `out_head`, `in_head`, `label_head` or
    /// `label_count` of a node that existed before the transaction (the
    /// caller managed a chain itself).
    node_chain_pointer_changed,
    /// The caller imaged a page itself (`logPagePublic` / `zeroPageLogged`).
    caller_page_image,
    /// An edge removal whose entry the edge index did not hold.
    edge_removal_unknown_entry,
    /// The journal could not be extended (out of memory or `MAX_RECORDS`).
    journal_full,
    /// Applying an inverse failed (an I/O or allocation error during the
    /// abort itself).
    undo_failed,
};

pub const UndoRec = union(enum) {
    /// `putNodeTxn`. `before == null`: the slot was empty (a create).
    node_put: struct { id: u64, before: ?NodeRec, after: NodeRec },
    /// `deleteNodeTxn`. `counted`: the manifest node count was decremented.
    node_delete: struct { id: u64, counted: bool },
    /// `addEdgeTxn` / `addEdgeColocatedTxn*`. The inverse removes whatever
    /// of the edge exists, so a write that failed half-way is undone too.
    edge_add: struct { from: u64, to: u64, edge_id: u64, colocated: bool, counted: bool },
    /// `removeEdgeTxn` (co-located layout). The inverse re-inserts what
    /// the removal took out.
    edge_remove: struct {
        from: u64,
        to: u64,
        edge_id: u64,
        /// The edge index held the edge (its fields below are valid).
        known: bool,
        rel_type: u32,
        prop_head: u64,
        public_id: u64,
        out_removed: bool,
        in_removed: bool,
        counted: bool,
    },
    /// `addLabelTxn` that added `label`.
    label_add: struct { node: u64, label: u32 },
    /// `removeLabelTxn` that removed `label`.
    label_remove: struct { node: u64, label: u32 },
    /// A property write (put or remove) on slab chain `owner`, which existed
    /// before the transaction, leaving it at `new_head` (== owner: rewritten
    /// in place; else relocated, the old slot tombstoned). `old_blob` is the
    /// chain's blob before the write (owned by the journal). The inverse
    /// retires `new_head` when it moved and writes `old_blob` back into
    /// `owner`'s slot, refusing if those bytes now belong to another live
    /// chain.
    prop_restore: struct { owner: u64, new_head: u64, old_blob: []u8 },
    /// A property chain the transaction created (or moved a chain it
    /// created to). Nothing outside the transaction references it; the
    /// inverse drops its derived index entries (its bytes leak until
    /// compaction).
    prop_chain: struct { head: u64 },
    /// `setEdgePropertyTxn` moved the edge's property head.
    edge_prop_head: struct { from: u64, to: u64, edge_id: u64, old_head: u64 },
};

pub const UndoJournal = struct {
    records: std.ArrayListUnmanaged(UndoRec) = .empty,
    /// Property chain heads created by this transaction.
    created_chains: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Node ids this transaction created (empty slot → record).
    created_nodes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    not_undoable: ?Reason = null,

    pub fn deinit(self: *UndoJournal, allocator: Allocator) void {
        self.freeBlobs(allocator);
        self.records.deinit(allocator);
        self.created_chains.deinit(allocator);
        self.created_nodes.deinit(allocator);
        self.* = .{};
    }

    /// True when the transaction wrote nothing that needs undoing.
    pub fn isEmpty(self: *const UndoJournal) bool {
        return self.records.items.len == 0 and self.not_undoable == null;
    }

    /// Mark the transaction not undoable. The first reason wins; recorded
    /// inverses are dropped (they are never applied).
    pub fn fail(self: *UndoJournal, allocator: Allocator, reason: Reason) void {
        if (self.not_undoable == null) self.not_undoable = reason;
        self.freeBlobs(allocator);
        self.records.clearRetainingCapacity();
        self.created_chains.clearRetainingCapacity();
        self.created_nodes.clearRetainingCapacity();
    }

    /// Empty the journal for reuse by another transaction, keeping its
    /// buffers (the commit path then allocates nothing for journaling).
    pub fn reset(self: *UndoJournal, allocator: Allocator) void {
        self.freeBlobs(allocator);
        self.records.clearRetainingCapacity();
        self.created_chains.clearRetainingCapacity();
        self.created_nodes.clearRetainingCapacity();
        self.not_undoable = null;
    }

    /// Buffers large enough that keeping them for reuse would pin memory a
    /// big transaction needed once.
    pub fn oversized(self: *const UndoJournal) bool {
        return self.records.capacity > 4096 or self.created_chains.capacity() > 4096 or
            self.created_nodes.capacity() > 4096;
    }

    fn freeBlobs(self: *UndoJournal, allocator: Allocator) void {
        for (self.records.items) |r| switch (r) {
            .prop_restore => |p| allocator.free(p.old_blob),
            else => {},
        };
    }

    /// Make room for one more record and one more entry in each created-set
    /// BEFORE a write mutates anything, so recording it afterwards cannot
    /// fail for lack of memory (the write fails cleanly instead).
    pub fn reserve(self: *UndoJournal, allocator: Allocator) !void {
        if (self.not_undoable != null) return;
        try self.records.ensureUnusedCapacity(allocator, 1);
        try self.created_chains.ensureUnusedCapacity(allocator, 1);
        try self.created_nodes.ensureUnusedCapacity(allocator, 1);
    }

    /// Append a record; returns its index (for a later in-place update), or
    /// null when the transaction is (now) not undoable.
    /// A `prop_restore` record's `old_blob` is owned by the journal from
    /// here on, also when the push is refused (it is freed then).
    pub fn push(self: *UndoJournal, allocator: Allocator, rec: UndoRec) ?usize {
        if (self.not_undoable != null) {
            if (rec == .prop_restore) allocator.free(rec.prop_restore.old_blob);
            return null;
        }
        if (self.records.items.len >= MAX_RECORDS) {
            if (rec == .prop_restore) allocator.free(rec.prop_restore.old_blob);
            self.fail(allocator, .journal_full);
            return null;
        }
        self.records.append(allocator, rec) catch {
            if (rec == .prop_restore) allocator.free(rec.prop_restore.old_blob);
            self.fail(allocator, .journal_full);
            return null;
        };
        return self.records.items.len - 1;
    }

    pub fn noteCreatedChain(self: *UndoJournal, allocator: Allocator, head: u64) void {
        if (self.not_undoable != null or head == 0) return;
        self.created_chains.put(allocator, head, {}) catch self.fail(allocator, .journal_full);
    }

    pub fn noteCreatedNode(self: *UndoJournal, allocator: Allocator, id: u64) void {
        if (self.not_undoable != null) return;
        self.created_nodes.put(allocator, id, {}) catch self.fail(allocator, .journal_full);
    }

    pub fn chainCreatedHere(self: *const UndoJournal, head: u64) bool {
        return self.created_chains.contains(head);
    }

    pub fn nodeCreatedHere(self: *const UndoJournal, id: u64) bool {
        return self.created_nodes.contains(id);
    }
};

test "journal: fail drops records and keeps the first reason" {
    const a = std.testing.allocator;
    var j = UndoJournal{};
    defer j.deinit(a);
    try std.testing.expect(j.isEmpty());
    _ = j.push(a, .{ .label_add = .{ .node = 1, .label = 2 } });
    j.noteCreatedChain(a, 7);
    try std.testing.expect(!j.isEmpty());
    j.fail(a, .caller_page_image);
    j.fail(a, .journal_full);
    try std.testing.expectEqual(@as(?Reason, .caller_page_image), j.not_undoable);
    try std.testing.expectEqual(@as(usize, 0), j.records.items.len);
    try std.testing.expect(j.push(a, .{ .prop_chain = .{ .head = 1 } }) == null);
    try std.testing.expect(!j.chainCreatedHere(7));
}
