// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integrity check and statistics helpers extracted from engine.zig.

const std = @import("std");

const metrics_mod = @import("metrics.zig");
const node_mod = @import("node.zig");
const types = @import("types.zig");
const engine_mod = @import("engine.zig");

const NodeId = types.NodeId;
const NodeRec = node_mod.NodeRec;
const GraphEngine = engine_mod.GraphEngine;
const Metrics = metrics_mod.Metrics;

/// Summary statistics about the storage engine's current state.
pub const StorageStats = struct {
    node_count: u64,
    edge_count: u64,
    label_count: u32,
    format_version: u32,
    page_size: u32,
    wal_lsn: u64,
    last_checkpoint_lsn: u64,
    free_pages_nodes: u64,
    free_pages_adj_out: u64,
    free_pages_adj_in: u64,
    free_pages_props: u64,
    free_pages_var: u64,
};

/// Result of a storage integrity check.
pub const IntegrityReport = struct {
    node_count_consistent: bool,
    edge_count_consistent: bool,
    label_index_entries: u64,
    total_errors: u64,
    io_errors: u64 = 0,
};

/// Return a read-only pointer to the engine's metrics counters.
pub fn getMetrics(engine: *GraphEngine) *const Metrics {
    return &engine.metrics;
}

/// Return a snapshot of storage-level statistics.
pub fn getStorageStats(engine: *GraphEngine) StorageStats {
    return .{
        .node_count = engine.manifest.node_count,
        .edge_count = engine.manifest.edge_count,
        .label_count = engine.manifest.label_count,
        .format_version = engine.manifest.format_version,
        .page_size = engine.config.page_size,
        .wal_lsn = engine.txn_manager.next_txn_id,
        .last_checkpoint_lsn = engine.manifest.last_checkpoint_lsn,
        .free_pages_nodes = engine.free_space_nodes.freeCount(),
        .free_pages_adj_out = engine.free_space_adj_out.freeCount(),
        .free_pages_adj_in = engine.free_space_adj_in.freeCount(),
        .free_pages_props = engine.free_space_props.freeCount(),
        .free_pages_var = engine.free_space_var.freeCount(),
    };
}

/// Walk the node and edge stores and compare actual live counts against
/// the manifest counters. Returns a report with any inconsistencies.
///
/// A genuine I/O error encountered while scanning a node's outgoing
/// adjacency chain is propagated to the caller rather than being silently
/// counted as a clean end-of-iteration: a truncated chain would otherwise
/// undercount edges and could be reported as "consistent" by accident.
///
/// PERF-0060: Uses scanNodes batch API to perform a single page-level pass
/// over the node store, counting live nodes and walking outgoing adjacency
/// chains simultaneously. This eliminates the two sequential per-id getNode
/// full scans and their associated per-id re-pinning overhead.
pub fn checkIntegrity(engine: *GraphEngine) anyerror!IntegrityReport {
    const Ctx = struct {
        engine: *GraphEngine,
        actual_nodes: u64 = 0,
        actual_edges: u64 = 0,
        err: ?anyerror = null,

        fn callback(self: *@This(), _: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            // scanNodes already filters empty and deleted records; every
            // visited slot is a live node.
            self.actual_nodes += 1;
            if (rec.out_head == 0) return;
            var iter = self.engine.adj_out.expand(rec.out_head, null);
            defer iter.deinit();
            while (iter.next() catch |e| {
                self.err = e;
                return;
            }) |_| {
                self.actual_edges += 1;
            }
        }
    };

    var ctx = Ctx{ .engine = engine };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;

    var report = IntegrityReport{
        .node_count_consistent = true,
        .edge_count_consistent = true,
        .label_index_entries = 0,
        .total_errors = 0,
    };

    if (ctx.actual_nodes != engine.manifest.node_count) {
        report.node_count_consistent = false;
        report.total_errors += 1;
    }
    if (ctx.actual_edges != engine.manifest.edge_count) {
        report.edge_count_consistent = false;
        report.total_errors += 1;
    }

    return report;
}
