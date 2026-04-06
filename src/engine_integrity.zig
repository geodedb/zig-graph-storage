// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integrity check and statistics helpers extracted from engine.zig.

const std = @import("std");

const metrics_mod = @import("metrics.zig");
const node_mod = @import("node.zig");
const engine_mod = @import("engine.zig");

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
pub fn checkIntegrity(engine: *GraphEngine) IntegrityReport {
    var report = IntegrityReport{
        .node_count_consistent = true,
        .edge_count_consistent = true,
        .label_index_entries = 0,
        .total_errors = 0,
    };

    // Count actual live nodes (not deleted, not empty)
    var actual_nodes: u64 = 0;
    var id: u64 = 1;
    while (id < engine.manifest.next_node_id) : (id += 1) {
        if (engine.node_store.getNode(id) catch null) |rec| {
            if (!node_mod.isDeleted(&rec) and !node_mod.isEmpty(&rec)) {
                actual_nodes += 1;
            }
        }
    }
    if (actual_nodes != engine.manifest.node_count) {
        report.node_count_consistent = false;
        report.total_errors += 1;
    }

    // Count actual edges by scanning outgoing adjacency lists of all live nodes
    var actual_edges: u64 = 0;
    var nid: u64 = 1;
    while (nid < engine.manifest.next_node_id) : (nid += 1) {
        if (engine.node_store.getNode(nid) catch null) |rec| {
            if (!node_mod.isDeleted(&rec) and !node_mod.isEmpty(&rec) and rec.out_head != 0) {
                var iter = engine.adj_out.expand(rec.out_head, null);
                defer iter.deinit();
                while (iter.next() catch null) |_| {
                    actual_edges += 1;
                }
            }
        }
    }
    if (actual_edges != engine.manifest.edge_count) {
        report.edge_count_consistent = false;
        report.total_errors += 1;
    }

    return report;
}
