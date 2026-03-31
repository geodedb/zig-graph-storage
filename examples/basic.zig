// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for graph-storage
//!
//! Demonstrates creating a graph, adding nodes with labels, connecting
//! them with edges, setting/getting properties, querying adjacency,
//! scanning by label, and checkpointing.
//!
//! Run with: zig build run-example

const std = @import("std");
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const GraphConfig = graph_storage.GraphConfig;
const NodeRec = graph_storage.node.NodeRec;
const PropertyValue = graph_storage.PropertyValue;

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("graph-storage Example\n", .{});
    print("========================\n\n", .{});

    // -- 1. Create a temporary directory for the graph data ----------------
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir);

    // Use a fixed UUID for the example graph
    const graph_uuid = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C };

    const cfg = GraphConfig{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };

    print("[1] Creating graph engine...\n", .{});
    var engine = try GraphEngine.create(allocator, data_dir, graph_uuid, cfg);

    // -- 2. Allocate nodes ------------------------------------------------
    print("[2] Allocating nodes...\n", .{});

    const empty_node = NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1, // must be non-zero so the node is not treated as empty
    };

    const alice_id = try engine.allocNode();
    try engine.putNode(alice_id, empty_node);

    const bob_id = try engine.allocNode();
    try engine.putNode(bob_id, empty_node);

    const charlie_id = try engine.allocNode();
    try engine.putNode(charlie_id, empty_node);

    print("  Created nodes: Alice={d}, Bob={d}, Charlie={d}\n", .{ alice_id, bob_id, charlie_id });

    // -- 3. Add labels to nodes -------------------------------------------
    print("[3] Adding labels...\n", .{});

    const label_person: u32 = 1;
    const label_admin: u32 = 2;

    try engine.addLabel(alice_id, label_person);
    try engine.addLabel(bob_id, label_person);
    try engine.addLabel(charlie_id, label_person);
    try engine.addLabel(alice_id, label_admin);

    print("  Alice: Person + Admin\n", .{});
    print("  Bob:   Person\n", .{});
    print("  Charlie: Person\n", .{});

    // -- 4. Add edges (relationships) -------------------------------------
    print("[4] Adding edges...\n", .{});

    const rel_knows: u32 = 10;
    const rel_manages: u32 = 20;

    const e1 = try engine.addEdge(alice_id, bob_id, rel_knows);
    const e2 = try engine.addEdge(alice_id, charlie_id, rel_manages);
    const e3 = try engine.addEdge(bob_id, charlie_id, rel_knows);

    print("  Edge {d}: Alice --KNOWS--> Bob\n", .{e1});
    print("  Edge {d}: Alice --MANAGES--> Charlie\n", .{e2});
    print("  Edge {d}: Bob --KNOWS--> Charlie\n", .{e3});

    // -- 5. Set properties on nodes ---------------------------------------
    print("[5] Setting properties...\n", .{});

    // Get Alice's current record so we can update prop_head
    var alice_rec = (try engine.getNode(alice_id)).?;
    const alice_prop_head = try engine.putProperty(alice_rec.prop_head, "name", .{ .string = "Alice" });
    alice_rec.prop_head = alice_prop_head;
    try engine.putNode(alice_id, alice_rec);

    var bob_rec = (try engine.getNode(bob_id)).?;
    const bob_prop_head = try engine.putProperty(bob_rec.prop_head, "name", .{ .string = "Bob" });
    bob_rec.prop_head = bob_prop_head;
    try engine.putNode(bob_id, bob_rec);

    print("  Set name='Alice' on node {d}\n", .{alice_id});
    print("  Set name='Bob' on node {d}\n", .{bob_id});

    // -- 6. Get properties back -------------------------------------------
    print("[6] Reading properties...\n", .{});

    const alice_rec2 = (try engine.getNode(alice_id)).?;
    if (try engine.getProperty(alice_rec2.prop_head, "name", allocator)) |val| {
        switch (val) {
            .string => |s| {
                print("  Alice's name: {s}\n", .{s});
                allocator.free(s);
            },
            else => print("  Alice's name: (unexpected type)\n", .{}),
        }
    } else {
        print("  Alice's name: (not found)\n", .{});
    }

    // -- 7. Query adjacency (expand outgoing edges) -----------------------
    print("[7] Querying outgoing edges from Alice...\n", .{});

    const alice_edges = try engine.expandOut(alice_id, null, allocator);
    defer allocator.free(alice_edges);

    print("  Alice has {d} outgoing edge(s):\n", .{alice_edges.len});
    for (alice_edges) |edge| {
        print("    -> node {d} (edge_id={d}, rel_type={d})\n", .{ edge.neighbor, edge.edge_id, edge.rel_type });
    }

    // -- 8. Scan by label -------------------------------------------------
    print("[8] Scanning for all 'Person' nodes (label={d})...\n", .{label_person});

    const persons = try engine.scanLabel(label_person, allocator);
    defer allocator.free(persons);

    print("  Found {d} person node(s): ", .{persons.len});
    for (persons, 0..) |nid, i| {
        if (i > 0) print(", ", .{});
        print("{d}", .{nid});
    }
    print("\n", .{});

    // -- 9. Transactions --------------------------------------------------
    print("[9] Demonstrating transactions...\n", .{});

    const txn = try engine.beginTxn();
    print("  Began transaction {d}\n", .{txn});
    try engine.commitTxn(txn);
    print("  Committed transaction {d}\n", .{txn});

    // -- 10. Checkpoint ---------------------------------------------------
    print("[10] Running checkpoint...\n", .{});
    try engine.checkpoint();
    print("  Checkpoint complete.\n", .{});

    // -- 11. Node and edge counts -----------------------------------------
    print("[11] Graph statistics...\n", .{});

    const n_count = try engine.nodeCount();
    const e_count = try engine.edgeCount();
    print("  Nodes: {d}\n", .{n_count});
    print("  Edges: {d}\n", .{e_count});

    // -- 12. Close the engine ---------------------------------------------
    print("[12] Closing graph engine...\n", .{});
    try engine.close();

    print("\nExample completed successfully!\n", .{});
}
