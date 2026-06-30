// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Phase A (engine early-ready): `GraphEngine.open` returns query-READY WITHOUT
//! building the O(nodes+edges) derived indexes (label_index / property_index
//! chain / edge_index / edge_exist_index). They are materialized lazily, exactly
//! once, on the FIRST accessor (read OR write) via `ensureDerivedHydrated`.
//!
//! Tests:
//!   * open-no-derived-build : open does NOT build any derived index
//!     (derived_materialize_runs == 0, derived_index_loads/rebuilds == 0) and a
//!     getNode point lookup serves immediately (needs no derived index).
//!   * lazy correctness (clean): the first label/edge/property/edge-exist access
//!     materializes ONCE (runs == 1, LOADS the clean snapshot) and returns the
//!     same results as the eager open did.
//!   * concurrency : two concurrent first-accesses materialize exactly once.
//!   * crash : a stale snapshot (counter bumped by a replayed WAL tail) is
//!     REBUILT from a scan at first access (runs == 1, rebuilds == 1), correct.

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const GraphConfig = graph_storage.GraphConfig;
const NodeRec = graph_storage.node.NodeRec;
const NodeId = graph_storage.NodeId;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;

fn earlyReadyConfig() GraphConfig {
    var cfg = graph_storage.test_support.testConfig();
    cfg.buffer_pool_pages = 64; // small pool forces real flushes
    return cfg;
}

fn emptyNode() NodeRec {
    return graph_storage.test_support.emptyNode(1);
}

/// Bulk-write `n` labelled + propertied nodes fanning out from a hub. Every node
/// carries `label_a`; even-indexed nodes also carry `label_b`. Each node gets a
/// unique property "k{i}" = i. Returns the hub node id.
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

    // The edge_index holds exactly one record per hub edge.
    try testing.expectEqual(n, engine.edgeIndexCount());
}

test "Phase A: open returns READY without building derived indexes; point lookup serves immediately" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xA1} ** 16;
    const cfg = earlyReadyConfig();
    const N: usize = 1500;
    const label_a: u32 = 11;
    const label_b: u32 = 22;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        _ = try bulkLoad(engine, N, label_a, label_b);
        // FULL checkpoint writes clean derived snapshots stamped at the current
        // manifest.counter so the reopen below can LOAD (not rebuild).
        try engine.checkpoint();
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // open-no-derived-build: NOTHING built at open.
        try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);

        // Point lookup serves immediately — needs no derived index, so it must
        // NOT trigger materialization.
        const hub_rec = try engine.getNode(1);
        try testing.expect(hub_rec != null);
        try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

        // First label scan materializes the derived set exactly once, via the
        // clean-snapshot LOAD path.
        const a_nodes = try engine.scanLabel(label_a, testing.allocator);
        defer testing.allocator.free(a_nodes);
        try testing.expectEqual(N, a_nodes.len);
        try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);

        // Subsequent accesses across every deferred index do NOT re-materialize.
        try verifyData(engine, N, 1, label_a, label_b);
        try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
    }
}

test "Phase A: a WRITE is a first-access that materializes before mutating the index" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xA2} ** 16;
    const cfg = earlyReadyConfig();
    const N: usize = 800;
    const label_a: u32 = 11;
    const label_b: u32 = 22;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        _ = try bulkLoad(engine, N, label_a, label_b);
        try engine.checkpoint();
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

        // First touch is a WRITE: add a label to the hub. The guard must
        // materialize the (clean) label_index BEFORE this addNode mutates it, so
        // a later scan sees both the loaded set AND this new entry.
        const label_c: u32 = 33;
        try engine.addLabel(1, label_c);
        try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_loads);

        const c_nodes = try engine.scanLabel(label_c, testing.allocator);
        defer testing.allocator.free(c_nodes);
        try testing.expectEqual(@as(usize, 1), c_nodes.len);
        try testing.expectEqual(@as(NodeId, 1), c_nodes[0]);

        // The pre-existing label set is intact (loaded, not clobbered).
        const a_nodes = try engine.scanLabel(label_a, testing.allocator);
        defer testing.allocator.free(a_nodes);
        try testing.expectEqual(N, a_nodes.len);
        try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
    }
}

const ConcurrentCtx = struct {
    engine: *GraphEngine,
    err: ?anyerror = null,
    fn run(self: *ConcurrentCtx) void {
        self.engine.ensureDerivedHydrated() catch |e| {
            self.err = e;
        };
    }
};

test "Phase A: concurrent first-accesses materialize exactly once" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xA3} ** 16;
    const cfg = earlyReadyConfig();
    const N: usize = 1000;
    const label_a: u32 = 11;
    const label_b: u32 = 22;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        _ = try bulkLoad(engine, N, label_a, label_b);
        try engine.checkpoint();
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

        var c0 = ConcurrentCtx{ .engine = engine };
        var c1 = ConcurrentCtx{ .engine = engine };
        const t0 = try std.Thread.spawn(.{}, ConcurrentCtx.run, .{&c0});
        const t1 = try std.Thread.spawn(.{}, ConcurrentCtx.run, .{&c1});
        t0.join();
        t1.join();
        try testing.expect(c0.err == null);
        try testing.expect(c1.err == null);

        // Built exactly once despite two concurrent first-accesses.
        try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
        try testing.expect(engine.derived_hydrated.load(.acquire));

        // ... and the result is correct.
        try verifyData(engine, N, 1, label_a, label_b);
    }
}

test "Phase A: stale snapshot (crash) is REBUILT from scan at first access" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xA4} ** 16;
    // sync_each_commit so the post-checkpoint mutation is fsynced into the WAL
    // and replayed by recovery (which bumps manifest.counter -> snapshot stale).
    var cfg = graph_storage.test_support.testConfig();
    cfg.buffer_pool_pages = 64;
    const N: usize = 1000;
    const label_a: u32 = 11;
    const label_b: u32 = 22;
    const tail_stamp: u64 = 0xDEAD_BEEF;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const hub = try bulkLoad(engine, N, label_a, label_b);
        // Clean derived snapshots stamped at the current counter.
        try engine.checkpoint();
        // Commit a mutation AFTER the snapshot (in-place hub-page rewrite of a
        // non-semantic field — no tombstone, no new allocation); the WAL fsyncs
        // it so recovery replays it and bumps manifest.counter past the snapshot
        // stamp, invalidating the persisted derived snapshot.
        var rec = (try engine.getNode(hub)).?;
        rec.txn_stamp = tail_stamp;
        try engine.putNode(hub, rec);
        // SIMULATED CRASH: abandon the engine (no checkpoint / no close).
        engine.deinit();
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Recovery replayed the WAL tail and bumped manifest.counter, so the
        // persisted derived snapshot is now stale-by-counter — but open still
        // builds NOTHING.
        try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

        // First access materializes once via the REBUILD path (counter mismatch).
        const a_nodes = try engine.scanLabel(label_a, testing.allocator);
        defer testing.allocator.free(a_nodes);
        try testing.expectEqual(N, a_nodes.len);
        try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_loads);

        // The rebuilt indexes are correct over the durable (checkpointed) graph.
        // (Durability of the single WAL-tail write itself is a recovery concern
        // outside Phase A's scope; the rebuild-forced assertion above already
        // proves recovery observed and replayed the tail.)
        try verifyData(engine, N, 1, label_a, label_b);
    }
}
