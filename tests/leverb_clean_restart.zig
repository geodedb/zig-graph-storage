// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Lever B: a CLEAN restart must LOAD the persisted derived-index snapshots
//! instead of doing the O(graph) rebuildDerivedIndexes, while a CRASH restart
//! must STILL be forced to rebuild (crash-safety preserved).
//!
//! Root cause exercised here: a bulk-ingest workload runs trailing
//! `checkpointLight()` calls. The light path advances `manifest.counter` and
//! leaves the derived-index dirty flags set, but sets `persistence_dirty=false`.
//! Before the fix, the clean-shutdown FULL `checkpoint()` then hit the
//! `if (!persistence_dirty) return;` early-return and skipped the derived save,
//! so the snapshot stayed stale-by-counter and the next open rebuilt from pages.
//!
//! Test A (this file, "clean restart LOADS"): periodic light checkpoints, then a
//! final FULL checkpoint, then reopen -> NO rebuild + the final checkpoint DID
//! save the derived snapshots even though pages were clean.
//!
//! Test B ("crash restart REBUILDS"): periodic light checkpoints, then more
//! committed writes AFTER the last light checkpoint, then a simulated crash
//! (deinit, no close/checkpoint). Recovery replays the WAL tail and bumps
//! manifest.counter, so the snapshot is stale-by-counter and the rebuild is
//! forced. Proves Lever B did NOT weaken crash-safety.

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const GraphConfig = graph_storage.GraphConfig;
const NodeRec = graph_storage.node.NodeRec;
const NodeId = graph_storage.NodeId;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;

fn leverbConfig() GraphConfig {
    var cfg = graph_storage.test_support.testConfig();
    // Deferred mode mirrors the bulk-ingest path that drives the light-checkpoint
    // cadence; small buffer pool forces dirty pages to actually flush.
    cfg.sync_mode = .deferred;
    cfg.buffer_pool_pages = 64;
    return cfg;
}

fn emptyNode() NodeRec {
    return graph_storage.test_support.emptyNode(1);
}

/// Bulk-write `n` labelled+propertied nodes fanning out from a hub, running a
/// LIGHT checkpoint every 500 inserts (the bulk-ingest cadence). Returns the
/// hub node id. The two labels: every node gets `label_a`; even-indexed nodes
/// also get `label_b`. Each node gets a unique property "k{i}" = i.
fn bulkLoad(engine: *GraphEngine, n: usize, label_a: u32, label_b: u32) !NodeId {
    const hub = try engine.allocNode();
    try engine.putNode(hub, emptyNode());

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const nid = try engine.allocNode();
        try engine.putNode(nid, emptyNode());
        try engine.addLabel(nid, label_a);
        if (i % 2 == 0) try engine.addLabel(nid, label_b);

        var rec = (try engine.getNode(nid)).?;
        var keybuf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        rec.prop_head = try engine.putProperty(rec.prop_head, key, .{ .int = @intCast(i) });
        try engine.putNode(nid, rec);

        _ = try engine.addEdge(hub, nid, @intCast(i % 4));

        // LIGHT checkpoint at the bulk cadence. With n a multiple of 500 the
        // FINAL loop iteration runs a light checkpoint, leaving
        // persistence_dirty=false and the derived dirty flags set — exactly the
        // pre-condition that made the subsequent full checkpoint early-return.
        if (i % 500 == 499) try engine.checkpointLight();
    }
    return hub;
}

/// Verify the derived indexes reflect the bulkLoad state.
fn verifyData(engine: *GraphEngine, n: usize, hub: NodeId, label_a: u32, label_b: u32) !void {
    const a_nodes = try engine.scanLabel(label_a, testing.allocator);
    defer testing.allocator.free(a_nodes);
    try testing.expectEqual(n, a_nodes.len);

    const b_nodes = try engine.scanLabel(label_b, testing.allocator);
    defer testing.allocator.free(b_nodes);
    try testing.expectEqual((n + 1) / 2, b_nodes.len);

    var i: usize = 0;
    while (i < n) : (i += 100) {
        const nid: NodeId = @intCast(i + 2); // hub=1, nodes 2..n+1
        const rec = (try engine.getNode(nid)).?;
        var keybuf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        const val = try engine.getProperty(rec.prop_head, key, testing.allocator);
        try testing.expect(val != null);
        try testing.expectEqual(@as(i64, @intCast(i)), val.?.int);
    }

    const out = try engine.expandOut(hub, null, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(n, out.len);
}

test "Lever B Test A: clean restart LOADS derived indexes (no O(graph) rebuild)" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xB1} ** 16;
    const cfg = leverbConfig();

    const N: usize = 3000; // multiple of 500 -> last op is a light checkpoint
    const label_a: u32 = 11;
    const label_b: u32 = 22;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        const hub = try bulkLoad(engine, N, label_a, label_b);
        try testing.expectEqual(@as(NodeId, 1), hub);

        // After the trailing light checkpoint, no derived save has happened yet
        // and persistence_dirty is false.
        const before = engine.getMetrics().derived_index_saves;
        try testing.expectEqual(@as(u64, 0), before);

        // FINAL FULL checkpoint = clean-shutdown model. Lever B regression guard:
        // this MUST persist the dirty derived snapshots even though pages are
        // clean (persistence_dirty == false). Before the fix it early-returned.
        try engine.checkpoint();
        const after = engine.getMetrics().derived_index_saves;
        try testing.expect(after > before);
    }

    // Reopen = clean restart. The derived snapshots are current (counter ==
    // manifest.counter), so tryLoadDerivedIndexes() succeeds and NO rebuild runs.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Lever B core assertion: the clean restart LOADED the persisted
        // snapshots (O(snapshot)) and did NOT run the O(graph) rebuild. On
        // current code this FAILS (the stale snapshot forces a rebuild).
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);

        try verifyData(engine, N, 1, label_a, label_b);
    }
}
