// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SONNY-6461: restore adjacency entries that graph_storage <= 0.4.11 lost
//! to the AES-GCM tag of the legacy page-encryption envelope (SONNY-6441).
//!
//! Every edge is stored twice: in its source's outgoing chain (`adj_out`) and
//! in an incoming chain keyed by its destination — the co-located
//! `adj_in_remote` chain (`in_idx`, kept current by every edge write and by
//! `setEdgeProperty`) or, for edges written by the legacy `addEdge` path, the
//! destination node's `adj_in` chain. Only the last slot of a full chain block
//! can have reached the page tail (`edge.legacyTailLoss`), so a damaged entry
//! and its mirror are almost never both damaged. This module walks every
//! chain, takes each tail-slot entry, finds its mirror by edge id and copies
//! back exactly the fields the tail held. See
//! `GraphEngine.repairAdjTailEntries`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const edge_mod = @import("edge.zig");
const node_mod = @import("node.zig");
const adj_store_mod = @import("adj_store.zig");
const engine_mod = @import("engine.zig");
const engine_index = @import("engine_index.zig");

const GraphEngine = engine_mod.GraphEngine;
const AdjStore = adj_store_mod.AdjStore;
const EntryLocation = AdjStore.EntryLocation;
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const PageId = types.PageId;
const FileId = types.FileId;
const NodeRec = node_mod.NodeRec;

comptime {
    if (edge_mod.LEGACY_TAG_TAIL != @import("encryption.zig").TAG_SIZE)
        @compileError("edge.LEGACY_TAG_TAIL must equal the AES-GCM tag size");
}

/// One tail-slot entry that could not be restored.
pub const AdjTailIssue = struct {
    /// `.adj_out`, `.adj_in` or `.in_idx`.
    file: FileId,
    page: PageId,
    slot: u32,
    /// Node whose chain holds the entry: the source for `adj_out`, the
    /// destination for `adj_in` and `in_idx`.
    owner: NodeId,
    edge_id: EdgeId,
    neighbor: NodeId,
    reason: Reason,

    pub const Reason = enum {
        /// No copy of the edge in the other direction on this engine (its
        /// other endpoint lives on another shard and the edge predates
        /// co-location, or the other chain no longer holds it).
        no_mirror,
        /// The mirror is itself in a tail slot and its copy of the lost
        /// fields is zero or disagrees, so neither copy can be trusted.
        mirror_in_tail,
        /// The only mirror is a legacy `adj_in` entry and the lost fields
        /// include `prop_head`, which `setEdgeProperty` does not keep current
        /// in `adj_in`; restoring it from there could install a stale head.
        prop_head_not_mirrored,
        /// The mirror's `prop_head` needs 64 bits and the damaged entry is in
        /// a v1/v2 block, which stores only 32 (the copies already disagreed).
        wide_head_in_narrow_entry,
    };
};

/// Result of `GraphEngine.repairAdjTailEntries`.
pub const AdjTailRepairReport = struct {
    /// False for a plaintext store: nothing was ever lost, nothing was read.
    encrypted: bool = false,
    /// Entries examined: every entry in a legacy-tail slot of
    /// `adj_out`, `adj_in` and `in_idx` chains.
    examined: u64 = 0,
    /// Entries whose lost fields were rewritten from an intact mirror.
    repaired: u64 = 0,
    /// Entries whose lost fields already agree with an intact mirror (never
    /// damaged, or repaired by an earlier call).
    consistent: u64 = 0,
    /// Entries left as they are, with the reason. Owned; free with `deinit`.
    unrepairable: std.ArrayList(AdjTailIssue) = .empty,

    pub fn deinit(self: *AdjTailRepairReport, allocator: Allocator) void {
        self.unrepairable.deinit(allocator);
        self.* = undefined;
    }
};

const Candidate = struct {
    file: FileId,
    owner: NodeId,
    loc: EntryLocation,
};

const MirrorKind = enum { out, in_remote, in_legacy };

const Mirror = struct {
    kind: MirrorKind,
    loc: EntryLocation,
};

/// Edges repaired per WAL transaction.
const commit_batch: u32 = 1024;

pub fn repairAdjTailEntries(engine: *GraphEngine, allocator: Allocator) anyerror!AdjTailRepairReport {
    var report: AdjTailRepairReport = .{};
    errdefer report.unrepairable.deinit(allocator);
    if (engine.config.encryption_key == null) return report;
    report.encrypted = true;
    if (engine.read_only) return error.ReadOnlyMode;
    // The derived edge indexes are rebuilt below when an outgoing entry
    // changes; materialize them first so the rebuild is the final state.
    try engine.ensureDerivedHydrated();

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    try collectCandidates(engine, allocator, &candidates);
    report.examined = candidates.items.len;

    var txn = try engine.txn_manager.begin();
    var txn_open = true;
    errdefer if (txn_open) engine.txn_manager.abort(txn) catch {};
    var in_batch: u32 = 0;
    var out_changed = false;

    for (candidates.items) |c| {
        const lost_from = c.loc.tail_lost_from.?;
        const fmt = c.loc.entry_format;
        const damaged = c.loc.entry;
        const mirror = (try findMirror(engine, c)) orelse {
            try report.unrepairable.append(allocator, issue(c, .no_mirror));
            continue;
        };
        const m = mirror.loc.entry;
        if (mirror.loc.tail_lost_from) |m_lost| {
            // Both copies sit in tail slots. The mirror's copy of the fields
            // this entry lost is trustworthy only if the mirror did not lose
            // them too; when both lost some, agreement on non-zero bytes is
            // the only evidence left (a lost tail reads back as zero).
            const both_from = @max(lost_from, m_lost);
            const both_to = @min(edge_mod.entrySize(fmt), edge_mod.entrySize(mirror.loc.entry_format));
            if (both_from < both_to) {
                const equal = edge_mod.lostFieldsEqual(damaged, m, lost_from, fmt);
                if (equal and !edge_mod.lostFieldsZero(damaged, both_from, fmt)) {
                    report.consistent += 1;
                } else {
                    try report.unrepairable.append(allocator, issue(c, .mirror_in_tail));
                }
                continue;
            }
        }
        if (edge_mod.lostFieldsEqual(damaged, m, lost_from, fmt)) {
            report.consistent += 1;
            continue;
        }
        if (mirror.kind == .in_legacy and storedPropHead(damaged, fmt) != storedPropHead(m, fmt)) {
            try report.unrepairable.append(allocator, issue(c, .prop_head_not_mirrored));
            continue;
        }
        const restored = edge_mod.restoreLostFields(damaged, m, lost_from, fmt) catch {
            try report.unrepairable.append(allocator, issue(c, .wide_head_in_narrow_entry));
            continue;
        };
        const store = storeFor(engine, c.file);
        try store.rewriteChainEntry(c.loc.page, c.loc.slot, fmt, restored);
        try engine.logPagePublic(txn, c.file, c.loc.page);
        if (c.file == .adj_out) {
            // Image the owner's (unchanged) node page too, as removeEdge and
            // setEdgeProperty do: it puts the owner in recovery's
            // tail-affected node set, so a crash before the next checkpoint
            // re-derives this node's edges from the repaired entry.
            try engine.logPagePublic(txn, .nodes, c.owner / engine.node_store.nodes_per_page);
            out_changed = true;
        }
        report.repaired += 1;
        in_batch += 1;
        if (in_batch >= commit_batch) {
            txn_open = false;
            try engine.txn_manager.commit(txn);
            txn = try engine.txn_manager.begin();
            txn_open = true;
            in_batch = 0;
        }
    }
    txn_open = false;
    try engine.txn_manager.commit(txn);

    if (out_changed) {
        // edge_index / edge_exist_index / the property-chain index were
        // derived from the damaged outgoing entries: re-derive them and have
        // the next checkpoint persist them.
        try engine_index.rebuildDerivedIndexes(engine);
        engine.label_index_dirty = true;
        engine.property_index_dirty = true;
        engine.edge_index_dirty = true;
        engine.edge_exist_index_dirty = true;
        engine.prop_rev_index_dirty = true;
    }
    if (report.repaired != 0) engine.markPersistenceDirty();
    return report;
}

/// `prop_head` as a record of `entry_format` stores it.
fn storedPropHead(e: edge_mod.EdgeEntry, entry_format: u8) u64 {
    return if (edge_mod.formatHasWideHead(entry_format)) e.prop_head else e.prop_head & 0xFFFF_FFFF;
}

fn issue(c: Candidate, reason: AdjTailIssue.Reason) AdjTailIssue {
    return .{
        .file = c.file,
        .page = c.loc.page,
        .slot = c.loc.slot,
        .owner = c.owner,
        .edge_id = c.loc.entry.edge_id,
        .neighbor = c.loc.entry.neighbor,
        .reason = reason,
    };
}

fn storeFor(engine: *GraphEngine, file: FileId) *AdjStore {
    return switch (file) {
        .adj_out => &engine.adj_out,
        .adj_in => &engine.adj_in,
        .in_idx => &engine.adj_in_remote,
        else => unreachable,
    };
}

/// Every tail-slot entry of every chain reachable from a node record
/// (`out_head`, `in_head`) or from the co-located in-edge directory.
fn collectCandidates(engine: *GraphEngine, allocator: Allocator, out: *std.ArrayList(Candidate)) !void {
    var scratch: std.ArrayList(EntryLocation) = .empty;
    defer scratch.deinit(allocator);

    const Ctx = struct {
        engine: *GraphEngine,
        allocator: Allocator,
        out: *std.ArrayList(Candidate),
        scratch: *std.ArrayList(EntryLocation),
        err: ?anyerror = null,

        fn add(self: *@This(), file: FileId, owner: NodeId, store: *AdjStore, head: PageId) !void {
            self.scratch.clearRetainingCapacity();
            try store.collectTailEntries(head, self.allocator, self.scratch);
            for (self.scratch.items) |loc| try self.out.append(self.allocator, .{ .file = file, .owner = owner, .loc = loc });
        }

        fn callback(self: *@This(), node_id: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            self.add(.adj_out, node_id, &self.engine.adj_out, rec.out_head) catch |e| {
                self.err = e;
                return;
            };
            self.add(.adj_in, node_id, &self.engine.adj_in, rec.in_head) catch |e| {
                self.err = e;
            };
        }
    };
    var ctx = Ctx{ .engine = engine, .allocator = allocator, .out = out, .scratch = &scratch };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;

    // The co-located in-edge directory is keyed by destination ids of the
    // whole graph (other shards' nodes too), so walk its pages rather than
    // this engine's node ids.
    const dir_pages = if (engine.file_manager.getPager(.in_dir)) |p| try p.pageCount() else 0;
    const hpp: u64 = engine.in_head_dir.heads_per_page;
    var pg: u64 = 0;
    while (pg < dir_pages) : (pg += 1) {
        if (!engine.free_space_in_dir.isAllocated(pg)) continue;
        var slot: u64 = 0;
        while (slot < hpp) : (slot += 1) {
            const dst = pg * hpp + slot;
            const head = try engine.in_head_dir.getHead(dst);
            if (head == 0) continue;
            try ctx.add(.in_idx, dst, &engine.adj_in_remote, head);
        }
    }
}

/// The same edge in the other direction: an outgoing entry's mirror is in
/// the destination's co-located in-chain (preferred; `setEdgeProperty` keeps
/// it current) or legacy `adj_in` chain; an incoming entry's mirror is in the
/// source's outgoing chain. The mirror must point back at `c.owner`.
fn findMirror(engine: *GraphEngine, c: Candidate) !?Mirror {
    const e = c.loc.entry;
    switch (c.file) {
        .adj_out => {
            const remote_head = try engine.in_head_dir.getHead(e.neighbor);
            if (try engine.adj_in_remote.locateEntry(remote_head, e.edge_id)) |loc| {
                if (loc.entry.neighbor == c.owner) return .{ .kind = .in_remote, .loc = loc };
            }
            const dst = (try engine.node_store.getNode(e.neighbor)) orelse return null;
            if (try engine.adj_in.locateEntry(dst.in_head, e.edge_id)) |loc| {
                if (loc.entry.neighbor == c.owner) return .{ .kind = .in_legacy, .loc = loc };
            }
            return null;
        },
        .adj_in, .in_idx => {
            const src = (try engine.node_store.getNode(e.neighbor)) orelse return null;
            if (try engine.adj_out.locateEntry(src.out_head, e.edge_id)) |loc| {
                if (loc.entry.neighbor == c.owner) return .{ .kind = .out, .loc = loc };
            }
            return null;
        },
        else => unreachable,
    }
}
