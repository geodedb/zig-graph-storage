// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Second-pass cross-shard recovery reconciliation for
//! ShardedGraphEngine. Each shard's single-threaded Recovery has
//! already replayed its local WAL before this runs, so the engines
//! are in a self-consistent intra-shard state. This pass walks every
//! shard's WAL to identify cross_shard_prepare records and joins them
//! by global_txn_id with any cross_shard_commit/cross_shard_abort
//! record on any shard. Dangling prepares are resolved per the spec:
//!
//!   - If ANY shard logged a commit for the global_txn_id: replay
//!     the adjacency write on any shard whose prepare is dangling,
//!     then log a commit decision locally.
//!   - Otherwise: log an abort decision on every shard with a
//!     dangling prepare. No data undo needed — prepares happen
//!     before any adjacency mutation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sharded_engine = @import("sharded_engine.zig");
const two_pc = @import("sharded_engine_2pc.zig");
const wal_record = @import("wal_record.zig");
const wal_mod = @import("wal.zig");
const engine_mod = @import("engine.zig");
const edge_mod = @import("edge.zig");

const WalRecord = wal_record.WalRecord;
const WalRecordType = wal_record.WalRecordType;
const ShardedGraphEngine = sharded_engine.ShardedGraphEngine;
const GraphEngine = engine_mod.GraphEngine;

pub const ReconcileStats = struct {
    committed: u32 = 0,
    aborted: u32 = 0,
};

/// Pass-A streaming callback context. Records cross-shard prepare/commit/abort
/// observations into the global state vector and this shard's prepares map.
/// Non-cross-shard records are ignored. Invoked only for records whose checksum
/// has already been verified by `forEachFromStrict`.
const CollectStateCtx = struct {
    state: *std.AutoHashMap(u64, u8),
    prepared_here: *std.AutoHashMap(u64, two_pc.PreparePayload),

    fn mark(self: *@This(), gid: u64, bit: u8) !void {
        const entry = try self.state.getOrPut(gid);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* |= bit;
    }

    fn visit(self: *@This(), rec: *const WalRecord) !void {
        switch (rec.record_type) {
            .cross_shard_prepare => {
                const payload = try two_pc.decodePreparePayload(rec.payload);
                try self.prepared_here.put(payload.global_txn_id, payload);
                try self.mark(payload.global_txn_id, 0b001);
            },
            .cross_shard_commit => try self.mark(try two_pc.decodeDecisionPayload(rec.payload), 0b010),
            .cross_shard_abort => try self.mark(try two_pc.decodeDecisionPayload(rec.payload), 0b100),
            else => {},
        }
    }
};

/// Pass-B streaming callback context. Records which global_txn_ids this shard
/// has already logged a local decision for, so reconciliation does not append a
/// duplicate decision. Invoked only for checksum-verified records.
const CollectResolvedCtx = struct {
    locally_resolved: *std.AutoHashMap(u64, void),

    fn visit(self: *@This(), rec: *const WalRecord) !void {
        switch (rec.record_type) {
            .cross_shard_commit, .cross_shard_abort => {
                const gid = try two_pc.decodeDecisionPayload(rec.payload);
                try self.locally_resolved.put(gid, {});
            },
            else => {},
        }
    }
};

pub fn reconcilePendingPrepares(self: *ShardedGraphEngine) !ReconcileStats {
    const allocator = self.allocator;

    // State bitmask per global_txn_id:
    //   0b001 = prepare observed on some shard
    //   0b010 = commit observed on some shard
    //   0b100 = abort observed on some shard
    var state = std.AutoHashMap(u64, u8).init(allocator);
    defer state.deinit();

    // Per-shard: prepares this shard owns and has not yet resolved.
    var prepared_here: [sharded_engine.SHARD_COUNT]std.AutoHashMap(u64, two_pc.PreparePayload) = undefined;
    for (&prepared_here) |*m| m.* = std.AutoHashMap(u64, two_pc.PreparePayload).init(allocator);
    defer for (&prepared_here) |*m| m.deinit();

    // Pass A: collect state from every shard's WAL via a CHECKSUM-VERIFYING
    // streaming walk. `forEachFromStrict` validates each record's checksum and
    // fails closed (error.ChecksumMismatch / error.InvalidFormat) on any
    // malformed or forged record — a crafted prepare/commit can no longer be
    // trusted to forge an edge. Only the small per-txn bookkeeping maps are
    // retained; the full record set is never materialized (PERF-0053).
    for (self.shards, 0..) |eng, s| {
        var failure: ?wal_mod.ReplayFailure = null;
        var ctx = CollectStateCtx{
            .state = &state,
            .prepared_here = &prepared_here[s],
        };
        try eng.wal.forEachFromStrict(0, allocator, &failure, &ctx, CollectStateCtx.visit);
    }

    // Pass B: for each shard, for each prepare it owns, apply the
    // global decision. A prepare here is "resolved" only if this
    // shard has also logged a commit/abort for the same global id.
    // For simplicity we consider any prepare without a matching
    // decision on THIS shard as dangling and resolve based on the
    // GLOBAL state vector built in Pass A.
    var stats = ReconcileStats{};
    for (self.shards, 0..) |eng, s| {
        // Skip prepares that already have a matching decision on THIS shard.
        // We detect that by re-reading this shard's WAL for decision records
        // keyed by global_txn_id. (Cheap: only the prepares map is small.)
        var locally_resolved = std.AutoHashMap(u64, void).init(allocator);
        defer locally_resolved.deinit();
        {
            var failure: ?wal_mod.ReplayFailure = null;
            var ctx = CollectResolvedCtx{ .locally_resolved = &locally_resolved };
            try eng.wal.forEachFromStrict(0, allocator, &failure, &ctx, CollectResolvedCtx.visit);
        }

        var it = prepared_here[s].iterator();
        while (it.next()) |entry| {
            const gid = entry.key_ptr.*;
            const payload = entry.value_ptr.*;
            const st = state.get(gid) orelse 0;
            const committed = (st & 0b010) != 0;
            const aborted = (st & 0b100) != 0;
            if (committed and !aborted) {
                // Always attempt to replay adjacency: the check inside
                // replayAdjacencyIfNeeded is idempotent (source uses
                // edge_index.contains; target re-applies adj_in which is
                // safe to repeat). The adjacency data may have been lost
                // even on the shard that logged the commit, if the buffer
                // pool was not flushed before the crash.
                try replayAdjacencyIfNeeded(eng, payload);
                // Only log the decision if this shard has not already done so.
                if (!locally_resolved.contains(gid)) {
                    const local_txn = try eng.beginTxn();
                    _ = try two_pc.appendDecision(eng, .cross_shard_commit, gid, local_txn);
                    try eng.commitTxn(local_txn);
                    stats.committed += 1;
                }
            } else {
                // Abort: no adjacency to replay. Only log if not already resolved.
                if (!locally_resolved.contains(gid)) {
                    const local_txn = try eng.beginTxn();
                    _ = try two_pc.appendDecision(eng, .cross_shard_abort, gid, local_txn);
                    try eng.commitTxn(local_txn);
                    stats.aborted += 1;
                }
            }
        }
    }
    return stats;
}

fn replayAdjacencyIfNeeded(
    eng: *GraphEngine,
    payload: two_pc.PreparePayload,
) !void {
    // If the adjacency write already happened pre-crash, the edge id
    // will already exist in the edge_index (for source) or the
    // relevant node record's in_head chain (for target). We key the
    // idempotence check on edge_index for source, and do a best-effort
    // reapply for target (addEdge on adj_in is idempotent by slot).
    switch (payload.role) {
        .source => {
            if (eng.edge_index.contains(payload.edge_id)) return;
            var from_rec = try eng.getNode(payload.from) orelse return error.NodeNotFound;
            const out_entry = edge_mod.EdgeEntry{
                .neighbor = payload.to,
                .edge_id = payload.edge_id,
                .rel_type = payload.rel_type,
                .prop_head = 0,
            };
            const new_out_head = try eng.adj_out.addEdge(from_rec.out_head, out_entry);
            from_rec.out_head = new_out_head;
            try eng.node_store.putNode(payload.from, from_rec);
            try eng.edge_index.put(payload.edge_id, .{
                .from = payload.from,
                .neighbor = payload.to,
                .rel_type = payload.rel_type,
                .prop_head = 0,
            });
            eng.manifest.edge_count += 1;
        },
        .target => {
            var to_rec = try eng.getNode(payload.to) orelse return error.NodeNotFound;
            const in_entry = edge_mod.EdgeEntry{
                .neighbor = payload.from,
                .edge_id = payload.edge_id,
                .rel_type = payload.rel_type,
                .prop_head = 0,
            };
            const new_in_head = try eng.adj_in.addEdge(to_rec.in_head, in_entry);
            to_rec.in_head = new_in_head;
            try eng.node_store.putNode(payload.to, to_rec);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
