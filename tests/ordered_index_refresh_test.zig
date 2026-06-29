// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P1: CHECKPOINT-REFRESH of the value-ordered index.
//
// The value-ordered index maintains entries incrementally on
// addLabel/removeLabel/deleteNode, but the engine has NO node-aware
// property-write hook: an in-place property-value change on a still-labelled
// node does NOT update the ordered tree. This is the bounded-staleness
// contract — the cursor is stale until the next FULL checkpoint.
//
// The fix mirrors engine_property_index.refreshLive: at a FULL checkpoint the
// ordered trees are REBUILT from a live-node scan before the snapshot is saved,
// so the in-memory cursor AND the persisted snapshot both reflect current live
// values. The LIGHT checkpoint must NOT do this (it stays O(dirty) — the
// OOM-avoidance contract).
//
//   Test 1: stale-before — change a value in place; before any checkpoint the
//   cursor still shows the OLD value (pins the bounded-staleness contract).
//
//   Test 2: correct-after-full — a FULL checkpoint refreshes the in-memory
//   cursor to the NEW value at the correct sort position; the OLD value is gone.
//
//   Test 3: correct-on-clean-reload — after the refreshing FULL checkpoint, a
//   clean reopen LOADS a snapshot that reflects the NEW value.
//
//   Test 4: light-no-refresh — a LIGHT checkpoint does NOT trigger the
//   O(graph) refresh (ordered_index_refreshes stays flat); a FULL one does.

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const NodeRec = graph_storage.node.NodeRec;
const NodeId = graph_storage.NodeId;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;
const ordered_encoding = graph_storage.ordered_encoding;

const LABEL: u32 = 11;
const KEY = "score";

fn emptyNode() NodeRec {
    return graph_storage.test_support.emptyNode(1);
}

/// Create a labelled node carrying KEY = value (property set BEFORE addLabel so
/// the incremental add-label hook indexes it). Returns the node id.
fn addLabelledNode(engine: *GraphEngine, value: i64) !NodeId {
    const nid = try engine.allocNode();
    var rec = emptyNode();
    rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = value });
    try engine.putNode(nid, rec);
    try engine.addLabel(nid, LABEL); // triggers the incremental ordered insert
    return nid;
}

/// Change KEY to `new_value` IN PLACE on an existing, still-labelled node. This
/// is the node-property write path (putProperty + putNode); it does NOT call
/// addLabel/removeLabel, so the ordered-index hooks are not invoked — the tree
/// drifts until a FULL checkpoint refreshes it.
fn changeValueInPlace(engine: *GraphEngine, nid: NodeId, new_value: i64) !void {
    var rec = (try engine.getNode(nid)) orelse return error.NodeMissing;
    rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = new_value });
    try engine.putNode(nid, rec);
}

/// Collect the ASC cursor's int values into a freshly-allocated slice.
fn collectAsc(engine: *GraphEngine) ![]i64 {
    var cursor = engine.openOrderedCursor(LABEL, KEY, .asc) orelse return error.NoOrderedIndex;
    var got: std.ArrayList(i64) = .empty;
    errdefer got.deinit(testing.allocator);
    while (cursor.next()) |entry| {
        var d = try ordered_encoding.decode(testing.allocator, entry.key);
        defer d.deinit(testing.allocator);
        try got.append(testing.allocator, d.value.int);
    }
    return got.toOwnedSlice(testing.allocator);
}

test "stale-before: in-place value change is NOT reflected before a checkpoint" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xD1} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    try engine.createOrderedIndex(LABEL, KEY);

    const V_old: i64 = 100;
    const V_new: i64 = 900;
    const nid = try addLabelledNode(engine, V_old);

    // Cursor shows V_old.
    {
        const got = try collectAsc(engine);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(i64, &.{V_old}, got);
    }

    // Change in place (no label mutation) — bounded-staleness: still V_old.
    try changeValueInPlace(engine, nid, V_new);
    {
        const got = try collectAsc(engine);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(i64, &.{V_old}, got); // STALE, by contract
    }
}

test "correct-after-full: a FULL checkpoint refreshes the in-memory cursor" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xD2} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    try engine.createOrderedIndex(LABEL, KEY);

    // Three nodes so a value change actually MOVES sort position.
    const a = try addLabelledNode(engine, 100);
    _ = try addLabelledNode(engine, 300);
    _ = try addLabelledNode(engine, 500);

    // Move 100 -> 400 in place (between 300 and 500 after refresh).
    try changeValueInPlace(engine, a, 400);

    // FULL checkpoint refreshes the trees from the live scan.
    try engine.checkpoint();

    const got = try collectAsc(engine);
    defer testing.allocator.free(got);
    // 100 is GONE, 400 is at the correct sort position.
    try testing.expectEqualSlices(i64, &.{ 300, 400, 500 }, got);
}

test "correct-on-clean-reload: the refreshed snapshot persists" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xD3} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        try engine.createOrderedIndex(LABEL, KEY);
        const a = try addLabelledNode(engine, 100);
        _ = try addLabelledNode(engine, 300);
        _ = try addLabelledNode(engine, 500);

        try changeValueInPlace(engine, a, 400);
        try engine.checkpoint(); // refresh + save the corrected snapshot
    }

    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Clean restart LOADED the snapshot (no crash-rebuild) and it is correct.
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_loads);
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().ordered_index_rebuilds);

        const got = try collectAsc(engine);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(i64, &.{ 300, 400, 500 }, got);
    }
}

test "light-no-refresh: LIGHT checkpoint skips the O(graph) refresh; FULL runs it" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xD4} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    try engine.createOrderedIndex(LABEL, KEY);
    const a = try addLabelledNode(engine, 100);
    _ = try addLabelledNode(engine, 300);

    try changeValueInPlace(engine, a, 400);

    // LIGHT checkpoint must NOT refresh (stays O(dirty)): counter flat, cursor stale.
    const before = engine.getMetrics().ordered_index_refreshes;
    try engine.checkpointLight();
    try testing.expectEqual(before, engine.getMetrics().ordered_index_refreshes);
    {
        const got = try collectAsc(engine);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(i64, &.{ 100, 300 }, got); // still stale
    }

    // FULL checkpoint DOES refresh: counter bumps, cursor corrected.
    try engine.checkpoint();
    try testing.expect(engine.getMetrics().ordered_index_refreshes > before);
    {
        const got = try collectAsc(engine);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(i64, &.{ 300, 400 }, got);
    }
}

/// Create a labelled node carrying KEY = `value` (arbitrary type). Property set
/// BEFORE addLabel so the incremental add-label hook indexes it.
fn addLabelledNodeVal(engine: *GraphEngine, value: PropertyValue) !NodeId {
    const nid = try engine.allocNode();
    var rec = emptyNode();
    rec.prop_head = try engine.putProperty(rec.prop_head, KEY, value);
    try engine.putNode(nid, rec);
    try engine.addLabel(nid, LABEL);
    return nid;
}

/// Change KEY to an arbitrary-typed `value` IN PLACE (no label mutation, so the
/// ordered-index hooks are not invoked — only a FULL checkpoint refresh sees it).
fn setValInPlace(engine: *GraphEngine, nid: NodeId, value: PropertyValue) !void {
    var rec = (try engine.getNode(nid)) orelse return error.NodeMissing;
    rec.prop_head = try engine.putProperty(rec.prop_head, KEY, value);
    try engine.putNode(nid, rec);
}

test "eligibility: homogeneous int column is index-eligible; introducing a float makes it ineligible" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xE1} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    try engine.createOrderedIndex(LABEL, KEY);
    try testing.expect(engine.isOrderedIndexEligible(LABEL, KEY)); // empty -> eligible

    _ = try addLabelledNodeVal(engine, .{ .int = 100 });
    _ = try addLabelledNodeVal(engine, .{ .int = 300 });
    try testing.expect(engine.isOrderedIndexEligible(LABEL, KEY)); // homogeneous int

    // Incremental add-label hook re-runs the eligibility rule: a float value in
    // the same column flips it ineligible (encoder type-separates int/float).
    _ = try addLabelledNodeVal(engine, .{ .float = 2.5 });
    try testing.expect(!engine.isOrderedIndexEligible(LABEL, KEY));

    // An unregistered (label,key) is never eligible.
    try testing.expect(!engine.isOrderedIndexEligible(999, "nope"));
}

test "eligibility: a FULL checkpoint refresh recomputes the flag from live values" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xE2} ** 16;
    var cfg = graph_storage.test_support.testConfig();
    cfg.sync_mode = .deferred;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        try engine.createOrderedIndex(LABEL, KEY);
        _ = try addLabelledNodeVal(engine, .{ .int = 100 });
        // A decimal is not-orderable: the incremental hook flags it ineligible.
        const dec = try addLabelledNodeVal(engine, .{ .decimal = .{ .coeff = 5, .scale = 1 } });
        try testing.expect(!engine.isOrderedIndexEligible(LABEL, KEY));

        // Fix the bad value IN PLACE to an int. Bounded-staleness: the hook is
        // not invoked, so the flag stays false until the FULL checkpoint.
        try setValInPlace(engine, dec, .{ .int = 200 });
        try testing.expect(!engine.isOrderedIndexEligible(LABEL, KEY));

        // FULL checkpoint rebuilds the trees from a live scan and RECOMPUTES the
        // flag over the now-homogeneous-int column -> eligible.
        try engine.checkpoint();
        try testing.expect(engine.isOrderedIndexEligible(LABEL, KEY));
    }

    // The recomputed flag persists and is restored on a clean reload.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        try testing.expectEqual(@as(u64, 1), engine.getMetrics().ordered_index_loads);
        try testing.expect(engine.isOrderedIndexEligible(LABEL, KEY));
    }
}
