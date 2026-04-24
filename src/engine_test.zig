// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Unit tests for GraphEngine, extracted from engine.zig.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const config_mod = @import("config.zig");
const manifest_mod = @import("manifest.zig");
const graph_dir_mod = @import("graph_dir.zig");
const node_mod = @import("node.zig");
const test_support = @import("testing_support.zig");
const engine_mod = @import("engine.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const GraphConfig = config_mod.GraphConfig;
const Manifest = manifest_mod.Manifest;
const GraphDir = graph_dir_mod.GraphDir;
const NodeRec = node_mod.NodeRec;
const TestDataDir = test_support.TestDataDir;
const GraphEngine = engine_mod.GraphEngine;

fn testDataDir() !TestDataDir {
    return TestDataDir.init(testing.allocator);
}

fn testConfig() GraphConfig {
    return test_support.testConfig();
}

test "create engine, allocNode, putNode, getNode round-trip" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x01} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Allocate and write a node
    const node_id = try engine.allocNode();
    try testing.expectEqual(@as(NodeId, 1), node_id);

    const rec = NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
    try engine.putNode(node_id, rec);

    // Read it back
    const got = try engine.getNode(node_id);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 0), got.?.label_head);
    try testing.expectEqual(@as(u16, 0), got.?.label_count);
}

test "create engine, addEdge, expandOut returns edge" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x02} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Create two nodes
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    // Add an edge
    const edge_id = try engine.addEdge(n1, n2, 5);
    try testing.expectEqual(@as(EdgeId, 1), edge_id);

    // Expand outgoing edges from n1
    const out_edges = try engine.expandOut(n1, null, testing.allocator);
    defer testing.allocator.free(out_edges);

    try testing.expectEqual(@as(usize, 1), out_edges.len);
    try testing.expectEqual(n2, out_edges[0].neighbor);
    try testing.expectEqual(edge_id, out_edges[0].edge_id);
    try testing.expectEqual(@as(u32, 5), out_edges[0].rel_type);

    // Expand incoming edges at n2
    const in_edges = try engine.expandIn(n2, null, testing.allocator);
    defer testing.allocator.free(in_edges);

    try testing.expectEqual(@as(usize, 1), in_edges.len);
    try testing.expectEqual(n1, in_edges[0].neighbor);
}

test "create engine, checkpoint, close, open again, data persists" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x03} ** 16;
    const cfg = testConfig();

    // Create and populate
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const n1 = try engine.allocNode();
        try engine.putNode(n1, NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        });

        // Checkpoint to persist
        try engine.checkpoint();

        try engine.close();
    }

    // Re-open and verify data survived checkpoint+close+reopen
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // The node MUST be present after checkpoint+close+reopen
        const got = try engine.getNode(1);
        try testing.expect(got != null);
        try testing.expectEqual(@as(u64, 0), got.?.label_head);
    }
}

test "checkpoint persists labels.dict, labels.idx and props.idx snapshots" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x11} ** 16;
    const cfg = testConfig();

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const node_id = try engine.allocNode();
        var rec = NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try engine.putNode(node_id, rec);
        try engine.addLabel(node_id, 7);

        rec = (try engine.getNode(node_id)).?;
        rec.prop_head = try engine.putProperty(rec.prop_head, "name", .{ .string = "Alice" });
        try engine.putNode(node_id, rec);

        try engine.checkpoint();
        try engine.close();
    }

    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();

    const labels_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.idx", .{graph_dir.path});
    defer testing.allocator.free(labels_idx_path);
    const props_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/props.idx", .{graph_dir.path});
    defer testing.allocator.free(props_idx_path);
    const edges_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{graph_dir.path});
    defer testing.allocator.free(edges_idx_path);
    const labels_dict_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.dict", .{graph_dir.path});
    defer testing.allocator.free(labels_dict_path);

    const labels_dict_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), labels_dict_path, .{});
    const labels_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), labels_idx_path, .{});
    const props_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), props_idx_path, .{});
    const edges_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), edges_idx_path, .{});
    try testing.expect(labels_dict_stat.size > 0);
    try testing.expect(labels_stat.size > 0);
    try testing.expect(props_stat.size > 0);
    try testing.expect(edges_stat.size > 0);
}

test "open rebuilds derived indexes when snapshot files are stale" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x12} ** 16;
    const cfg = testConfig();

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const node_id = try engine.allocNode();
        var rec = NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try engine.putNode(node_id, rec);
        try engine.addLabel(node_id, 9);

        rec = (try engine.getNode(node_id)).?;
        rec.prop_head = try engine.putProperty(rec.prop_head, "email", .{ .string = "alice@example.com" });
        try engine.putNode(node_id, rec);

        try engine.checkpoint();
        try engine.close();
    }

    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();
    const labels_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.idx", .{graph_dir.path});
    defer testing.allocator.free(labels_idx_path);

    const labels_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), labels_idx_path, .{ .read = true, .truncate = true });
    labels_file.close(std.Io.Threaded.global_single_threaded.io());

    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    const labeled_nodes = try engine.scanLabel(9, testing.allocator);
    defer testing.allocator.free(labeled_nodes);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{1}, labeled_nodes);

    const rec = (try engine.getNode(1)).?;
    const email = try engine.getProperty(rec.prop_head, "email", testing.allocator);
    defer if (email) |value| switch (value) {
        .string => |s| testing.allocator.free(s),
        .ext => |e| testing.allocator.free(e.data),
        else => {},
    };
    try testing.expect(email != null);
    try testing.expectEqualStrings("alice@example.com", email.?.string);
}

test "GraphStorage vtable interface works" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x04} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Get the vtable interface
    const gs = engine.storage();

    // Use vtable methods
    const node_id = try gs.allocNode();
    try gs.putNode(node_id, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const got = try gs.getNode(node_id);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 0), got.?.label_head);

    const count = try gs.nodeCount();
    try testing.expectEqual(@as(u64, 1), count);
}

test "GAP-0006: close returns error union, not void" {
    // Verify that close() returns !void by calling try on it
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x06} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());

    // This call would fail to compile if close() returned void
    try engine.close();
}

test "SEC-0010: open rejects page_size mismatch" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x10} ** 16;
    const cfg = testConfig(); // page_size = 4096

    // Create with page_size 4096
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Try to open with different page_size -- should fail
    {
        var bad_cfg = testConfig();
        bad_cfg.page_size = 8192;
        const result = GraphEngine.open(testing.allocator, td.path, uuid, bad_cfg);
        try testing.expectError(error.PageSizeMismatch, result);
    }
}

test "QUAL-0006: getEdge returns null for nonexistent edge" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x07} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // getEdge should return null for an edge that does not exist
    const result = try engine.getEdge(999);
    try testing.expect(result == null);
}

test "GAP-0021: getEdge returns edge after addEdge" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x21} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Create two nodes
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    // Add an edge and look it up by ID
    const edge_id = try engine.addEdge(n1, n2, 42);
    const edge = try engine.getEdge(edge_id);
    try testing.expect(edge != null);
    try testing.expectEqual(n2, edge.?.neighbor);
    try testing.expectEqual(edge_id, edge.?.edge_id);
    try testing.expectEqual(@as(u32, 42), edge.?.rel_type);
    try testing.expectEqual(@as(u32, 0), edge.?.prop_head);

    // Remove the edge, getEdge should return null
    try engine.removeEdge(n1, n2, edge_id);
    const removed = try engine.getEdge(edge_id);
    try testing.expect(removed == null);
}

test "GAP-0071: open loads the persisted edge index without rescanning adjacency" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x71} ** 16;
    const cfg = testConfig();

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        const n1 = try engine.allocNode();
        try engine.putNode(n1, NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        });
        const n2 = try engine.allocNode();
        try engine.putNode(n2, NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        });

        _ = try engine.addEdge(n1, n2, 17);
        try engine.checkpoint();
        try engine.close();
    }

    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();

    const adj_out_path = try std.fmt.allocPrint(testing.allocator, "{s}/adj_out.store", .{graph_dir.path});
    defer testing.allocator.free(adj_out_path);
    const edges_idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{graph_dir.path});
    defer testing.allocator.free(edges_idx_path);

    try testing.expect((try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), edges_idx_path, .{})).size > 0);

    {
        const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), adj_out_path, .{ .mode = .write_only });
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        var buf: [4096]u8 = undefined;
        @memset(&buf, 0xFF);
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), &buf);
    }

    const reopened = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer reopened.close() catch {};

    const edge = try reopened.getEdge(1);
    try testing.expect(edge != null);
    try testing.expectEqual(@as(NodeId, 2), edge.?.neighbor);
    try testing.expectEqual(@as(u32, 17), edge.?.rel_type);
}

test "GAP-0088: GraphStorage iterators do not require result-sized allocations" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x88} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    const hub = try engine.allocNode();
    try engine.putNode(hub, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const label_id: u32 = 7;
    for (0..24) |i| {
        const node_id = try engine.allocNode();
        try engine.putNode(node_id, NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        });
        try engine.addLabel(node_id, label_id);
        _ = try engine.addEdge(hub, node_id, @intCast(i % 3));
    }

    const storage = engine.storage();

    var edge_iter_buf: [96]u8 = undefined;
    var edge_iter_alloc = std.heap.FixedBufferAllocator.init(&edge_iter_buf);
    var edge_iter = try storage.expandOut(hub, null, edge_iter_alloc.allocator());
    defer edge_iter.deinit();

    var edge_count: usize = 0;
    while (try edge_iter.next()) |_| {
        edge_count += 1;
    }
    try testing.expectEqual(@as(usize, 24), edge_count);

    var label_iter_buf: [96]u8 = undefined;
    var label_iter_alloc = std.heap.FixedBufferAllocator.init(&label_iter_buf);
    var label_iter = try storage.scanLabelIter(label_id, label_iter_alloc.allocator());
    defer label_iter.deinit();

    var label_count: usize = 0;
    while (try label_iter.next()) |_| {
        label_count += 1;
    }
    try testing.expectEqual(@as(usize, 24), label_count);
}

test "PERF-0005: nodeCount/edgeCount are O(1) via manifest counters" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x50} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Initially zero
    try testing.expectEqual(@as(u64, 0), try engine.nodeCount());
    try testing.expectEqual(@as(u64, 0), try engine.edgeCount());

    // Allocate and write two nodes
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    try testing.expectEqual(@as(u64, 1), try engine.nodeCount());

    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    try testing.expectEqual(@as(u64, 2), try engine.nodeCount());

    // Add edges
    _ = try engine.addEdge(n1, n2, 1);
    try testing.expectEqual(@as(u64, 1), try engine.edgeCount());

    _ = try engine.addEdge(n2, n1, 2);
    try testing.expectEqual(@as(u64, 2), try engine.edgeCount());

    // Remove an edge
    try engine.removeEdge(n1, n2, 1);
    try testing.expectEqual(@as(u64, 1), try engine.edgeCount());

    // Delete a node
    try engine.deleteNode(n1);
    try testing.expectEqual(@as(u64, 1), try engine.nodeCount());

    // Counters are directly from manifest (O(1))
    try testing.expectEqual(@as(u64, 1), engine.manifest.node_count);
    try testing.expectEqual(@as(u64, 1), engine.manifest.edge_count);
}

test "PERF-0008: open auto-sizes buffer pool from manifest" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x08} ** 16;

    // Create with small buffer pool
    var cfg = testConfig();
    cfg.buffer_pool_pages = 64;
    cfg.buffer_pool_auto_size = true;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Re-open: auto-size should kick in (minimum 1024 even for empty graph)
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Buffer pool should be at least 1024 (the auto-size minimum)
        try testing.expect(engine.buffer_pool.capacity >= 1024);
    }
}

test "PERF-0008: open respects buffer_pool_auto_size=false" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x09} ** 16;

    var cfg = testConfig();
    cfg.buffer_pool_pages = 64;
    cfg.buffer_pool_auto_size = false;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Re-open with auto-size disabled: should keep configured size
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        try testing.expectEqual(@as(u32, 64), engine.buffer_pool.capacity);
    }
}

test "getStorageStats returns correct counters" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x71} ** 16;
    const cfg = testConfig();
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // Fresh engine stats
    const stats0 = engine.getStorageStats();
    try testing.expectEqual(@as(u64, 0), stats0.node_count);
    try testing.expectEqual(@as(u64, 0), stats0.edge_count);
    try testing.expectEqual(@as(u32, 2), stats0.format_version); // V2
    try testing.expectEqual(@as(u32, 4096), stats0.page_size);

    // Add a node and check stats update
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const stats1 = engine.getStorageStats();
    try testing.expectEqual(@as(u64, 1), stats1.node_count);
}

test "checkIntegrity reports consistent state" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x72} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Empty engine should be consistent
    const r0 = engine.checkIntegrity();
    try testing.expect(r0.node_count_consistent);
    try testing.expect(r0.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r0.total_errors);

    // Add two nodes and an edge
    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });
    _ = try engine.addEdge(n1, n2, 1);

    // Should still be consistent
    const r1 = engine.checkIntegrity();
    try testing.expect(r1.node_count_consistent);
    try testing.expect(r1.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r1.total_errors);

    // Remove the edge, then delete a node -- counts should stay consistent
    try engine.removeEdge(n1, n2, 1);
    try engine.deleteNode(n1);
    const r2 = engine.checkIntegrity();
    try testing.expect(r2.node_count_consistent);
    try testing.expect(r2.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r2.total_errors);
}

test "V1 format detection returns V1FormatRequiresRecreation" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x61} ** 16;
    const cfg = testConfig();

    // Create a valid V2 graph so the directory structure exists
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Now overwrite manifest_a with a V1 format_version
    const graph_dir = try GraphDir.open(testing.allocator, td.path, uuid);
    defer @constCast(&graph_dir).deinit();

    const v1_manifest = Manifest{
        .graph_uuid = uuid,
        .page_size = cfg.page_size,
        .counter = 10, // Higher counter so it wins A/B selection
        .format_version = manifest_mod.MANIFEST_VERSION_V1,
    };
    const path_a = try graph_dir.manifestPath(testing.allocator, .a);
    defer testing.allocator.free(path_a);
    try v1_manifest.writeToFile(testing.allocator, path_a);

    // Also write to slot B so selectManifest picks V1
    const path_b = try graph_dir.manifestPath(testing.allocator, .b);
    defer testing.allocator.free(path_b);
    try v1_manifest.writeToFile(testing.allocator, path_b);

    // open() should detect V1 and return error
    const result = GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    try testing.expectError(error.IncompatibleVersion, result);
}

test "GAP-0022: multi-op transaction groups mutations" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x70} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Begin an explicit transaction
    const txn = try engine.beginTxn();

    // Allocate and put two nodes within the same transaction
    const n1 = try engine.allocNode();
    const rec1 = NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
    try engine.putNodeTxn(n1, rec1, txn);

    const n2 = try engine.allocNode();
    const rec2 = NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
    try engine.putNodeTxn(n2, rec2, txn);

    // Add an edge within the same transaction
    const edge_id = try engine.addEdgeTxn(n1, n2, 42, txn);

    // Commit the single transaction covering all three mutations
    try engine.commitTxn(txn);

    // Verify all data is present
    const got1 = try engine.getNode(n1);
    try testing.expect(got1 != null);

    const got2 = try engine.getNode(n2);
    try testing.expect(got2 != null);

    const edges = try engine.expandOut(n1, null, testing.allocator);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, 1), edges.len);
    try testing.expectEqual(edge_id, edges[0].edge_id);
    try testing.expectEqual(@as(u32, 42), edges[0].rel_type);
}

test "GraphEngine auto-registers a submitter slot on first flush" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x42} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // Before any flush, submitter_slot is unset.
    try testing.expectEqual(@as(?usize, null), engine.submitter_slot);

    // Force the lazy-register path — direct invocation is the narrowest
    // test of the contract (the flush path calls the same helper).
    engine.ensureSubmitterRegistered();

    try testing.expect(engine.submitter_slot != null);
    try testing.expect(engine.submitter_slot.? < 64);

    // Idempotence: second call must NOT claim a new slot — it's a no-op.
    const first_slot = engine.submitter_slot.?;
    engine.ensureSubmitterRegistered();
    try testing.expectEqual(first_slot, engine.submitter_slot.?);
}

test "GraphEngine with base_shard_index allocates striped node ids" {
    const SHARD_COUNT = @import("sharded_store.zig").SHARD_COUNT;

    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0xAA} ** 16;

    var cfg = testConfig();
    cfg.base_shard_index = 3;

    const engine = try GraphEngine.create(std.testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    const id1 = try engine.allocNode();
    const id2 = try engine.allocNode();
    try std.testing.expectEqual(@as(u64, 3), id1);
    try std.testing.expectEqual(@as(u64, 3 + SHARD_COUNT), id2);
    const shard_count_mod = @import("shard_count.zig");
    try std.testing.expectEqual(@as(usize, 3), shard_count_mod.shardOfNode(id1));
    try std.testing.expectEqual(@as(usize, 3), shard_count_mod.shardOfNode(id2));
}

test "GraphEngine with base_shard_index bumps edge ids in stride" {
    const SHARD_COUNT = @import("sharded_store.zig").SHARD_COUNT;

    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0xAB} ** 16;

    var cfg = testConfig();
    cfg.base_shard_index = 5;

    const engine = try GraphEngine.create(std.testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    const n1 = try engine.allocNode();
    try engine.putNode(n1, test_support.emptyNode(1));
    const n2 = try engine.allocNode();
    try engine.putNode(n2, test_support.emptyNode(1));

    const e1 = try engine.addEdge(n1, n2, 1);
    const e2 = try engine.addEdge(n1, n2, 1);
    try std.testing.expectEqual(@as(u64, 5), e1);
    try std.testing.expectEqual(@as(u64, 5 + SHARD_COUNT), e2);
}
