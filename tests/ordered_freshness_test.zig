// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P4 Task A1: ordered-index freshness signal.
//
// The value-ordered index trees are rebuilt only at the durability boundary
// (full checkpoint / close), NOT per write. Between a write and the next
// rebuild the trees are STALE and must NOT serve ORDER BY (they would return
// missing / 0 rows). `orderedIndexFresh()` is the planner's gate:
//
//   true  iff a registered ordered index exists AND its trees reflect every
//         committed write since the last rebuild/refresh.
//
// Proven here against a tmpDir engine:
//   * fresh engine, nothing registered            -> false
//   * createOrderedIndex at ZERO nodes            -> true  (empty tree is exact)
//   * a write since the last refresh              -> false (trees now stale)
//   * rebuildOrderedIndex()                       -> true  (trees current again)

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const NodeRec = graph_storage.node.NodeRec;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;

const LABEL: u32 = 11;
const KEY = "k";

fn emptyNode() NodeRec {
    return graph_storage.test_support.emptyNode(1);
}

test "orderedIndexFresh tracks staleness across register / write / rebuild" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xF4} ** 16;
    const cfg = graph_storage.test_support.testConfig();

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // 1. Fresh engine, nothing registered -> not fresh (no ordered index).
    try testing.expect(!engine.orderedIndexFresh());

    // 2. Register an ordered index with ZERO nodes present. The empty tree
    //    correctly reflects all 0 writes, so the signal is fresh.
    try engine.createOrderedIndex(LABEL, KEY);
    try testing.expect(engine.orderedIndexFresh());

    // 3. Create a labelled node carrying KEY through the engine write API. A
    //    write has occurred since the last refresh, so the trees are stale.
    const nid = try engine.allocNode();
    var rec = emptyNode();
    rec.prop_head = try engine.putProperty(rec.prop_head, KEY, .{ .int = 42 });
    try engine.putNode(nid, rec);
    try engine.addLabel(nid, LABEL);
    try testing.expect(!engine.orderedIndexFresh());

    // 4. Rebuild at the durability boundary -> the trees are current again.
    try engine.rebuildOrderedIndex();
    try testing.expect(engine.orderedIndexFresh());
}
