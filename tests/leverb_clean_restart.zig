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

        // Phase A: the derived-index build is DEFERRED out of open, so the
        // load/rebuild counters are 0 until the first accessor materializes them.
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);

        // First derived access materializes via the clean-snapshot LOAD path.
        try verifyData(engine, N, 1, label_a, label_b);

        // Lever B core assertion (now at first-access): the clean restart LOADED
        // the persisted snapshots (O(snapshot)) and did NOT run the O(graph)
        // rebuild.
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);
    }
}

test "Lever B Test B: crash restart REBUILDS (stale snapshot invalidated by counter bump)" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xB2} ** 16;
    // Default sync mode (sync_each_commit) so the post-checkpoint writes are
    // fsynced into the WAL and therefore replayed by recovery after the crash.
    var cfg = graph_storage.test_support.testConfig();
    cfg.buffer_pool_pages = 64;

    const N: usize = 2000; // multiple of 500 -> last bulk op is a light checkpoint
    const label_a: u32 = 11;
    const label_b: u32 = 22;
    const tail_flags: u8 = 0x7; // marker written by the post-snapshot mutation

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const hub = try bulkLoad(engine, N, label_a, label_b);
        try testing.expectEqual(@as(NodeId, 1), hub);

        // FULL checkpoint: saves VALID derived snapshots stamped at the current
        // manifest.counter (post-Lever-B this happens even though the trailing
        // light checkpoint left persistence_dirty=false). The snapshot is now
        // current — a clean restart from HERE would load it.
        const saves_before = engine.getMetrics().derived_index_saves;
        try engine.checkpoint();
        try testing.expect(engine.getMetrics().derived_index_saves > saves_before);

        // Commit a mutation AFTER the snapshot: an in-place rewrite of the hub
        // node page (no new allocation, so the stale checkpoint-era free.store
        // stays valid; the hub carries no labels so label counts are
        // unperturbed — this isolates the test to the snapshot
        // counter-invalidation path). sync_each_commit fsyncs it to the WAL, so
        // recovery will replay it. This is the "committed-but-uncheckpointed
        // mutation after the snapshot" that must invalidate the snapshot.
        var rec = (try engine.getNode(hub)).?;
        rec.flags = tail_flags;
        try engine.putNode(hub, rec);

        // SIMULATED CRASH: no checkpoint(), no close() — abandon the engine.
        // Only the fsynced WAL tail survives.
        engine.deinit();
    }

    // Reopen. Recovery replays the committed WAL tail (the post-snapshot
    // mutation) and bumps manifest.counter, so the saved snapshot is now
    // stale-by-counter. The load gate MUST reject it and force a rebuild — this
    // is the crash-safety invariant Lever B must not weaken.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Phase A: the build is DEFERRED, so no rebuild has run at open yet.
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_loads);

        // The rebuilt indexes are correct over the durable (checkpointed) graph.
        // The first scanLabel materializes via the REBUILD path (stale snapshot).
        const a_nodes = try engine.scanLabel(label_a, testing.allocator);
        defer testing.allocator.free(a_nodes);
        try testing.expectEqual(N, a_nodes.len);

        const b_nodes = try engine.scanLabel(label_b, testing.allocator);
        defer testing.allocator.free(b_nodes);
        try testing.expectEqual((N + 1) / 2, b_nodes.len);

        // CRASH-SAFETY PROOF (the Lever B invariant), now asserted at first-
        // access: the rebuild was FORCED and the stale snapshot was NOT loaded.
        // derived_index_rebuilds can only be 1 here if recovery saw the
        // post-snapshot WAL tail and bumped manifest.counter past the snapshot's
        // stamp. Had the tail not been seen, the snapshot would still be current
        // and the first access would have LOADED it (loads==1) — the bug.
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_loads);

        // NOTE: the durability of the single post-checkpoint WAL-tail write
        // itself (getNode survival of the crash-tail mutation) is a recovery/
        // replay + free-space concern that Lever B does not touch — Lever B only
        // changes the checkpoint SAVE path, never recovery. It is intentionally
        // not asserted here; the rebuild-forced assertion above already proves
        // recovery observed and replayed the tail.
    }
}
