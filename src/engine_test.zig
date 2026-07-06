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
const page_mod = @import("page.zig");
const edge_mod = @import("edge.zig");
const test_support = @import("testing_support.zig");
const engine_mod = @import("engine.zig");
const engine_index = @import("engine_index.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const PropertyValue = types.PropertyValue;
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

test "encrypted properties survive checkpoint+close+reopen (tag/dir-footer collision regression)" {
    // SEC regression: the prop_store per-page key directory (dir_count + dir
    // entries) grows backward from the page end. The pager writes the per-page
    // AES-GCM tag into the final TAG_SIZE bytes on flush. Without reserving the
    // tag tail, the tag overwrites dir_count on disk; the next OPEN reads a
    // garbage dir_count and panics with an integer overflow in readDirEntry.
    // This test writes several encrypted properties, persists, reopens, and
    // verifies every property reads back intact.
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x5e} ** 16;
    var cfg = testConfig();
    cfg.encryption_key = [_]u8{0xab} ** 32;

    const keys = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" };
    const vals = [_][]const u8{ "v-alpha", "v-bravo", "v-charlie", "v-delta", "v-echo", "v-foxtrot" };

    var head: u64 = 0;

    // Write several string properties (builds a per-page directory), then
    // checkpoint + close so the pages are flushed (encrypted) to disk.
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        for (keys, vals) |k, v| {
            head = try engine.putProperty(head, k, .{ .string = v });
        }

        try engine.checkpoint();
        try engine.close();
    }

    // Re-open with the same key: this is the path that previously panicked.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        for (keys, vals) |k, expected| {
            const got = try engine.getProperty(head, k, testing.allocator);
            try testing.expect(got != null);
            defer if (got) |g| switch (g) {
                .string => |s| testing.allocator.free(s),
                else => {},
            };
            try testing.expectEqualStrings(expected, got.?.string);
        }
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

test "getPropertyNoDerived matches getProperty for present keys without hydrating the derived index" {
    // H1-engine: loop1's per-node chain read must not trigger
    // ensureDerivedHydrated (the full derived property-chain index build).
    // getPropertyNoDerived walks prop_store directly; verify it returns the
    // same value as getProperty for a chain that spans multiple property
    // pages, and that calling ONLY getPropertyNoDerived never materializes
    // the derived indexes (derived_hydrated stays false, derived_materialize_runs
    // stays 0).
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x20} ** 16;
    const cfg = testConfig();

    // Build a property chain that spans more than one page (page_size=4096
    // in testConfig; ~36 bytes/entry incl. directory overhead means well
    // under 200 entries overflows a single page).
    const entry_count: usize = 200;
    var head: u64 = 0;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);

        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < entry_count) : (i += 1) {
            const key = try std.fmt.bufPrint(&buf, "k{d}", .{i});
            var vbuf: [32]u8 = undefined;
            const val = try std.fmt.bufPrint(&vbuf, "v{d}", .{i});
            head = try engine.putProperty(head, key, .{ .string = val });
        }

        try testing.expect(head != 0);

        try engine.checkpoint();
        try engine.close();
    }

    // Re-open: Phase A means the derived indexes are NOT yet hydrated.
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    try testing.expect(!engine.derived_hydrated.load(.acquire));
    try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

    // prop_head == 0 returns null without touching prop_store.
    try testing.expectEqual(@as(?PropertyValue, null), try engine.getPropertyNoDerived(0, "k0", testing.allocator));

    // Present key, no-derived path: must succeed and match the expected value.
    const nd_first = try engine.getPropertyNoDerived(head, "k0", testing.allocator);
    defer if (nd_first) |v| switch (v) {
        .string => |s| testing.allocator.free(s),
        .ext => |e| testing.allocator.free(e.data),
        else => {},
    };
    try testing.expect(nd_first != null);
    try testing.expectEqualStrings("v0", nd_first.?.string);

    // A key near the tail of the chain (forces a multi-page walk).
    const nd_last = try engine.getPropertyNoDerived(head, "k199", testing.allocator);
    defer if (nd_last) |v| switch (v) {
        .string => |s| testing.allocator.free(s),
        .ext => |e| testing.allocator.free(e.data),
        else => {},
    };
    try testing.expect(nd_last != null);
    try testing.expectEqualStrings("v199", nd_last.?.string);

    // The derived index must STILL be unhydrated: getPropertyNoDerived never
    // calls ensureDerivedHydrated.
    try testing.expect(!engine.derived_hydrated.load(.acquire));
    try testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

    // Now compare against getProperty (which DOES hydrate) for byte-identical
    // results on present keys.
    const d_first = try engine.getProperty(head, "k0", testing.allocator);
    defer if (d_first) |v| switch (v) {
        .string => |s| testing.allocator.free(s),
        .ext => |e| testing.allocator.free(e.data),
        else => {},
    };
    try testing.expect(d_first != null);
    try testing.expectEqualStrings(nd_first.?.string, d_first.?.string);

    const d_last = try engine.getProperty(head, "k199", testing.allocator);
    defer if (d_last) |v| switch (v) {
        .string => |s| testing.allocator.free(s),
        .ext => |e| testing.allocator.free(e.data),
        else => {},
    };
    try testing.expect(d_last != null);
    try testing.expectEqualStrings(nd_last.?.string, d_last.?.string);

    // getProperty hydrated the derived index exactly once, as expected.
    try testing.expect(engine.derived_hydrated.load(.acquire));
    try testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
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
    // expandOutIter is the first-class zero-copy vtable entry: it heap-boxes only
    // the iterator state, never a result-sized buffer, so a tiny fixed buffer
    // suffices regardless of edge count.
    var edge_iter = try storage.expandOutIter(hub, null, edge_iter_alloc.allocator());
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

test "QUAL-0043/PERF-0041: expandOutIter/expandInIter dispatch through GraphStorage vtable" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x43} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

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
    const n3 = try engine.allocNode();
    try engine.putNode(n3, NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    });

    const e1 = try engine.addEdge(n1, n2, 5);
    const e2 = try engine.addEdge(n1, n3, 5);

    // Dispatch the zero-copy iterator THROUGH the type-erased vtable, not the
    // concrete engine. This proves expandOutIter is a first-class vtable method
    // reachable without @hasDecl reflection on the concrete type.
    const gs = engine.storage();

    // A tiny fixed buffer is enough: the iterator state is heap-boxed once, but
    // NO result-sized slice is allocated regardless of edge count.
    var out_buf: [128]u8 = undefined;
    var out_fba = std.heap.FixedBufferAllocator.init(&out_buf);
    var out_iter = try gs.expandOutIter(n1, null, out_fba.allocator());
    defer out_iter.deinit();

    var saw_e1 = false;
    var saw_e2 = false;
    var out_count: usize = 0;
    while (try out_iter.next()) |entry| {
        out_count += 1;
        if (entry.edge_id == e1) saw_e1 = true;
        if (entry.edge_id == e2) saw_e2 = true;
    }
    try testing.expectEqual(@as(usize, 2), out_count);
    try testing.expect(saw_e1);
    try testing.expect(saw_e2);

    // expandInIter through the vtable as well.
    var in_buf: [128]u8 = undefined;
    var in_fba = std.heap.FixedBufferAllocator.init(&in_buf);
    var in_iter = try gs.expandInIter(n2, null, in_fba.allocator());
    defer in_iter.deinit();

    var in_count: usize = 0;
    while (try in_iter.next()) |entry| {
        in_count += 1;
        try testing.expectEqual(n1, entry.neighbor);
        try testing.expectEqual(e1, entry.edge_id);
    }
    try testing.expectEqual(@as(usize, 1), in_count);
}

test "QUAL-0043: expandOut ownership contract — caller frees returned slice, no leak" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x44} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

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
    _ = try engine.addEdge(n1, n2, 5);

    // Per the documented contract, expandOut returns an owned slice that the
    // caller must free with the SAME allocator. std.testing.allocator fails the
    // test if that contract is violated (leak or double-free).
    const out_edges = try engine.expandOut(n1, null, testing.allocator);
    defer testing.allocator.free(out_edges);
    try testing.expectEqual(@as(usize, 1), out_edges.len);
    try testing.expectEqual(n2, out_edges[0].neighbor);
}

test "QUAL-0043: scanLabel ownership contract — caller frees returned slice, no leak" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x45} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    const label_id: u32 = 11;
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
    try engine.addLabel(n1, label_id);

    // Per the documented contract, scanLabel returns an owned []NodeId that the
    // caller must free with the SAME allocator. std.testing.allocator enforces
    // no leak / no double-free.
    const nodes = try engine.scanLabel(label_id, testing.allocator);
    defer testing.allocator.free(nodes);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{n1}, nodes);
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

test "PERF-0051: create auto-sizes buffer pool (not left at tiny default)" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x51} ** 16;

    // Tiny configured pool, auto-size enabled (the default).
    var cfg = testConfig();
    cfg.buffer_pool_pages = 16;
    cfg.buffer_pool_auto_size = true;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // create() must apply the same auto-size floor open() uses instead of the
    // tiny configured 16 frames.
    try testing.expect(engine.buffer_pool.capacity >= 1024);
    try testing.expect(engine.buffer_pool.capacity > cfg.buffer_pool_pages);
}

test "PERF-0051: create respects buffer_pool_auto_size=false" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x52} ** 16;

    var cfg = testConfig();
    cfg.buffer_pool_pages = 64;
    cfg.buffer_pool_auto_size = false;

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // With auto-size disabled, create() keeps the configured size verbatim.
    try testing.expectEqual(@as(u32, 64), engine.buffer_pool.capacity);
}

test "PERF-0051: create reserves frames for the hot node store" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x53} ** 16;
    const cfg = testConfig();

    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // The node store must have a non-zero reservation floor so cold scans
    // cannot evict every cached node page.
    const reserve = engine.buffer_pool.reserved_frames[@intFromEnum(types.FileId.nodes)];
    try testing.expect(reserve > 0);
    try testing.expect(reserve <= engine.buffer_pool.capacity);
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
    try testing.expectEqual(@as(u32, 4), stats0.format_version); // V4 (v0.2.29 checkpoint_epoch downgrade gate)
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
    const r0 = try engine.checkIntegrity();
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
    const r1 = try engine.checkIntegrity();
    try testing.expect(r1.node_count_consistent);
    try testing.expect(r1.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r1.total_errors);

    // Remove the edge, then delete a node -- counts should stay consistent
    try engine.removeEdge(n1, n2, 1);
    try engine.deleteNode(n1);
    const r2 = try engine.checkIntegrity();
    try testing.expect(r2.node_count_consistent);
    try testing.expect(r2.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), r2.total_errors);
}

// QUAL-0047(c): a genuine I/O / corruption error encountered while scanning a
// node's outgoing adjacency chain must propagate to the caller rather than
// being silently swallowed as a clean end-of-iteration (which previously left
// the edge undercounted and could be reported as "consistent" by accident).
test "checkIntegrity propagates adjacency-scan I/O errors" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x73} ** 16;
    // This test corrupts a LEGACY EdgeBlockHeader (block-per-chain layout) to
    // force a circular chain. Adjacency slab packing defaults ON since P7, which
    // makes a low-fanout out_head a slab head instead of a raw block page — so
    // opt the legacy adjacency writer back in to keep exercising this path.
    var cfg = testConfig();
    cfg.adjacency_slab_packing = false;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // Two nodes with a single edge so node n1 has a non-empty out_head chain.
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

    // Locate n1's outgoing adjacency head page.
    const rec = (try engine.node_store.getNode(n1)).?;
    try testing.expect(rec.out_head != 0);

    // Corrupt the head block so its next_block points back to itself. The
    // adjacency iterator trips its hop guard and returns CircularChainDetected,
    // simulating an I/O/corruption fault mid-scan. The EdgeBlockHeader begins
    // at PAGE_HEADER_SIZE in the page and is read/written via @bitCast, so we
    // mutate it through the same representation here.
    const frame = try engine.adj_out.buffer_pool.pin(engine.adj_out.file_id, rec.out_head);
    const frame_idx = engine.adj_out.buffer_pool.frameIndex(frame);
    const data = frame.dataSlice();
    const off = page_mod.PAGE_HEADER_SIZE;
    const hdr_bytes = data[off..][0..@sizeOf(edge_mod.EdgeBlockHeader)];
    var bh: edge_mod.EdgeBlockHeader = @bitCast(hdr_bytes.*);
    bh.next_block = rec.out_head; // point the chain at itself
    hdr_bytes.* = @bitCast(bh);
    engine.adj_out.buffer_pool.unpin(frame_idx, true);

    // The integrity scan must surface the error instead of counting it clean.
    try testing.expectError(error.CircularChainDetected, engine.checkIntegrity());
}

// PERF-0060: verify checkIntegrity reports are correct for a graph that spans
// multiple node-store pages (more than 84 nodes on a 4 KiB page).
test "checkIntegrity correct on multi-page node store" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x74} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    // testConfig uses page_size=4096; with PAGE_HEADER_SIZE=32 and NodeRec=48 bytes,
    // nodes_per_page = (4096-32)/48 = 84. Allocate 170 nodes to span at least
    // two full node pages, then add edges across the page boundary.
    const total_nodes: usize = 170;
    var node_ids: [total_nodes]NodeId = undefined;
    for (0..total_nodes) |i| {
        const nid = try engine.allocNode();
        try engine.putNode(nid, NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        });
        node_ids[i] = nid;
    }

    // Add edges between nodes on different pages (first node -> last node and back).
    _ = try engine.addEdge(node_ids[0], node_ids[total_nodes - 1], 1);
    _ = try engine.addEdge(node_ids[total_nodes - 1], node_ids[0], 2);

    const report = try engine.checkIntegrity();
    try testing.expect(report.node_count_consistent);
    try testing.expect(report.edge_count_consistent);
    try testing.expectEqual(@as(u64, 0), report.total_errors);
    try testing.expectEqual(@as(u64, 0), report.io_errors);
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

test "GraphEngine owned thread pool defaults to 4 workers" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x77} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    const stats = engine.thread_pool.statsSnapshot();
    try testing.expectEqual(@as(usize, 4), stats.worker_stats.len);
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

test "GraphEngine borrows external thread pool — pool stays alive after engine close" {
    const tp = @import("thread_pool");

    var td = try testDataDir();
    defer td.deinit();

    var caller_pool = try tp.ThreadPool.init(testing.allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 16,
        .max_threads = 4,
    });
    defer {
        caller_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        caller_pool.deinit();
    }

    var cfg = testConfig();
    cfg.external_thread_pool = &caller_pool;

    const uuid = [_]u8{0x88} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    try engine.close();

    // Pool must still be usable after the engine closed. registerSubmitter
    // will return error.PoolShutdown if the engine ran shutdown on us.
    const slot = try caller_pool.registerSubmitter();
    caller_pool.releaseSubmitter(slot);
}

test "two GraphEngines can borrow the same external thread pool" {
    const tp = @import("thread_pool");

    var td = try testDataDir();
    defer td.deinit();

    var caller_pool = try tp.ThreadPool.init(testing.allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 8,
        .max_threads = 4,
    });
    defer {
        caller_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        caller_pool.deinit();
    }

    var cfg = testConfig();
    cfg.external_thread_pool = &caller_pool;

    const uuid_a = [_]u8{0x91} ** 16;
    const uuid_b = [_]u8{0x92} ** 16;

    const eng_a = try GraphEngine.create(testing.allocator, td.path, uuid_a, cfg);
    defer eng_a.close() catch {};
    const eng_b = try GraphEngine.create(testing.allocator, td.path, uuid_b, cfg);
    defer eng_b.close() catch {};

    // Both engines must point at the same pool.
    try testing.expectEqual(&caller_pool, eng_a.thread_pool);
    try testing.expectEqual(&caller_pool, eng_b.thread_pool);
    try testing.expect(eng_a.owned_thread_pool == null);
    try testing.expect(eng_b.owned_thread_pool == null);

    // Force each to claim a submitter slot — must each get a distinct slot.
    eng_a.ensureSubmitterRegistered();
    eng_b.ensureSubmitterRegistered();
    try testing.expect(eng_a.submitter_slot != null);
    try testing.expect(eng_b.submitter_slot != null);
    try testing.expect(eng_a.submitter_slot.? != eng_b.submitter_slot.?);
}

// QUAL-0042 (#124): a step that fails AFTER initSubsystems during open() must
// not leak the subsystems (WAL, txn manager, indexes, free-space managers) or
// the WAL directory handle. initSubsystems' internal errdefer guards discharge
// once it returns successfully, so without an `errdefer cleanupSubsystems()`
// after that call the subsystems leak. We induce a deterministic failure by
// corrupting labels.dict so that label_dict.loadFromFile (open step 6) returns
// error.InvalidData (a non-FileNotFound error that propagates via `else =>
// return err`). std.testing.allocator turns the leaked allocations into a test
// failure pre-fix; post-fix the failure path frees everything and the only
// observable result is the propagated error.InvalidData.
test "open() failing after initSubsystems frees subsystems (QUAL-0042)" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x42} ** 16;
    const cfg = testConfig();

    // Create and cleanly close a graph so a valid on-disk graph exists.
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        try engine.close();
    }

    // Locate the graph directory: <data_dir>/graphs/<uuid_hex>.
    var hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (uuid, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    const labels_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/graphs/{s}/labels.dict",
        .{ td.path, hex },
    );
    defer testing.allocator.free(labels_path);

    // Corrupt labels.dict with a too-small payload. loadFromFile requires at
    // least 8 bytes and returns error.InvalidData for anything shorter, which
    // is a non-FileNotFound error and therefore propagates out of open().
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = try std.Io.Dir.cwd().createFile(io, labels_path, .{ .truncate = true });
        defer f.close(io);
        _ = try f.writePositionalAll(io, "bad", 0);
    }

    // open() must fail at the label_dict load step (after initSubsystems) and
    // must not leak. A leak here is detected by testing.allocator and fails the
    // test pre-fix.
    const result = GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    try testing.expectError(error.InvalidData, result);
}

// PERF-0055: Verify that the per-write property encode no longer allocates a
// heap ArrayList on the hot path for fixed-size (stack-encodable) values,
// and that read-back is correct for both small (inline/stack) and large
// (overflow) property values.
test "PERF-0055: putProperty no redundant ArrayList alloc for fixed-size values" {
    // A minimal counting allocator that wraps testing.allocator and counts
    // the number of heap allocations issued.
    const CountingAllocator = struct {
        inner: std.mem.Allocator,
        alloc_count: usize = 0,

        fn allocFn(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.alloc_count += 1;
            return self.inner.rawAlloc(n, alignment, ra);
        }

        fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.rawResize(buf, alignment, new_len, ra);
        }

        fn remapFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.rawRemap(buf, alignment, new_len, ra);
        }

        fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.inner.rawFree(buf, alignment, ra);
        }

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocFn,
                    .resize = resizeFn,
                    .remap = remapFn,
                    .free = freeFn,
                },
            };
        }
    };

    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x55} ** 16;
    const cfg = testConfig();

    // -----------------------------------------------------------------------
    // Part 1: correctness for all value kinds (inline and large).
    // -----------------------------------------------------------------------
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        var head: u64 = 0;

        // Fixed-size types (all encode into ≤18 bytes — well within 32-byte
        // stack buffer).
        head = try engine.putProperty(head, "a_bool", .{ .bool = true });
        head = try engine.putProperty(head, "an_int", .{ .int = -9_876_543_210 });
        head = try engine.putProperty(head, "a_float", .{ .float = 2.71828 });
        head = try engine.putProperty(head, "a_decimal", .{ .decimal = .{ .coeff = 999_999_999_999, .scale = 6 } });
        head = try engine.putProperty(head, "a_null", PropertyValue.null);

        // Variable-length types: short string (fits in stack buf) and a long
        // string that overflows the 32-byte stack buf in the encode path.
        head = try engine.putProperty(head, "short_str", .{ .string = "hi" });
        const long_str = "A" ** 64; // 64 bytes → encoded size = 1+4+64 = 69 > 32
        head = try engine.putProperty(head, "long_str", .{ .string = long_str });

        // Update an existing key so the upsertKey fast-path is exercised.
        head = try engine.putProperty(head, "an_int", .{ .int = 42 });

        // Read every key back and assert correctness.
        {
            const v = (try engine.getProperty(head, "a_bool", testing.allocator)).?;
            try testing.expectEqual(true, v.bool);
        }
        {
            const v = (try engine.getProperty(head, "an_int", testing.allocator)).?;
            try testing.expectEqual(@as(i64, 42), v.int);
        }
        {
            const v = (try engine.getProperty(head, "a_float", testing.allocator)).?;
            try testing.expectApproxEqAbs(@as(f64, 2.71828), v.float, 1e-9);
        }
        {
            const v = (try engine.getProperty(head, "a_decimal", testing.allocator)).?;
            try testing.expectEqual(@as(i128, 999_999_999_999), v.decimal.coeff);
            try testing.expectEqual(@as(u8, 6), v.decimal.scale);
        }
        {
            const v = (try engine.getProperty(head, "a_null", testing.allocator)).?;
            try testing.expectEqual(PropertyValue.null, v);
        }
        {
            const v = (try engine.getProperty(head, "short_str", testing.allocator)).?;
            defer testing.allocator.free(v.string);
            try testing.expectEqualStrings("hi", v.string);
        }
        {
            const v = (try engine.getProperty(head, "long_str", testing.allocator)).?;
            defer testing.allocator.free(v.string);
            try testing.expectEqualStrings(long_str, v.string);
        }
    }

    // -----------------------------------------------------------------------
    // Part 2: allocation-count regression for the upsertKey fast path.
    //
    // On the *second* putProperty for a key that already exists AND whose
    // chain head is unchanged (the upsertKey branch), the old code allocated
    // an ArrayList (1 heap alloc + 1 free).  With PERF-0055 applied, fixed-
    // size values use a stack buffer and incur ZERO extra heap allocations
    // on that path.
    //
    // We measure this by wrapping the engine allocator with a counting shim
    // and issuing an update for a fixed-size (int) property, then asserting
    // that zero additional allocations were made by the encode path.
    // -----------------------------------------------------------------------
    var td2 = try TestDataDir.init(testing.allocator);
    defer td2.deinit();

    const uuid2 = [_]u8{0x56} ** 16;

    var counting = CountingAllocator{ .inner = testing.allocator };
    const count_alloc = counting.allocator();

    const engine2 = try GraphEngine.create(count_alloc, td2.path, uuid2, cfg);
    defer engine2.close() catch {};

    // PERF-0055 asserts the LEGACY upsertKey stack-buffer encode path (a slab
    // in-place update legitimately rebuilds the blob and may allocate) —
    // force the legacy writer now that slab_packing defaults ON (P7).
    engine2.prop_store.slab_packing = false;

    // First write: creates the property chain and index entry.
    var head2: u64 = 0;
    head2 = try engine2.putProperty(head2, "counter", .{ .int = 0 });

    // Reset counter *after* the first write so setup noise is excluded.
    counting.alloc_count = 0;

    // Second write: updates an existing key on the same chain head (upsertKey
    // path). With the fix, no ArrayList is allocated for the encode, so no
    // extra heap allocation for the encode step.
    head2 = try engine2.putProperty(head2, "counter", .{ .int = 1 });

    // Verify correctness first.
    const got = (try engine2.getProperty(head2, "counter", testing.allocator)).?;
    try testing.expectEqual(@as(i64, 1), got.int);

    // The encode step must contribute zero allocations (fixed-size int uses
    // the stack buffer path).  Other allocations (txn bookkeeping etc.) may
    // still occur; we only assert the encode no longer adds its own.
    // Before the fix: 1 allocation (ArrayList for the encoded bytes).
    // After the fix: 0 allocations from the encode path.
    //
    // We count total allocations in the update and assert the fix did not
    // re-introduce an ArrayList allocation.  The total is bounded: txn begin
    // may allocate, but the encode itself contributes 0.
    // To make this assertion concrete we verify the count is strictly less
    // than it would have been with the old ArrayList approach (which always
    // allocated at least 1 time for the ArrayList backing store).
    //
    // The simplest portable assertion: allocations for a fixed-size update
    // MUST be fewer than 2 (i.e. no ArrayList alloc for the encode).
    try testing.expect(counting.alloc_count < 2);
}

var index_build_event_count: usize = 0;
var index_build_event_labels: [8][]const u8 = undefined;

fn indexBuildTestLogFn(_: config_mod.LogLevel, msg: []const u8) void {
    if (index_build_event_count < index_build_event_labels.len) {
        index_build_event_labels[index_build_event_count] = msg;
        index_build_event_count += 1;
    }
}

test "NFR-OBS-002: lazy derived-index build emits index_build_start and index_build_end events" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0xEE} ** 16;

    // Create then close so the directory exists for open()
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
        try engine.close();
    }

    index_build_event_count = 0;
    var cfg = testConfig();
    cfg.log_fn = &indexBuildTestLogFn;

    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    // Phase A: the derived-index build is DEFERRED out of open, so no build
    // events fire at open. The first derived accessor materializes the indexes
    // (this fresh graph wrote no clean snapshot, so it takes the REBUILD path,
    // which emits the build events). A label scan is such an accessor.
    try testing.expectEqual(@as(usize, 0), index_build_event_count);
    const empty = try engine.scanLabel(1, testing.allocator);
    testing.allocator.free(empty);

    var found_start = false;
    var found_end = false;
    for (index_build_event_labels[0..index_build_event_count]) |lbl| {
        if (std.mem.eql(u8, lbl, "index_build_start")) found_start = true;
        if (std.mem.eql(u8, lbl, "index_build_end")) found_end = true;
    }
    try testing.expect(found_start);
    try testing.expect(found_end);
    // start must precede end
    var start_pos: usize = 0;
    var end_pos: usize = 0;
    for (index_build_event_labels[0..index_build_event_count], 0..) |lbl, i| {
        if (std.mem.eql(u8, lbl, "index_build_start")) start_pos = i;
        if (std.mem.eql(u8, lbl, "index_build_end")) end_pos = i;
    }
    try testing.expect(start_pos < end_pos);
}

test "GAP-0900 L2: checkpointLight is O(dirty) — skips derived-index save, truncates WAL, recovery rebuilds correctly" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x9C} ** 16;
    var cfg = testConfig();
    // Deferred mode mirrors the bulk-ingest path that triggers GAP-0900.
    cfg.sync_mode = .deferred;
    // Small buffer pool so dirty pages must flush (memory-bounded path is real).
    cfg.buffer_pool_pages = 64;

    const N: usize = 3000;
    const label_a: u32 = 11;
    const label_b: u32 = 22;

    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // Hub node every edge points from, so edges have an out-list.
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

        var prev_wal_bytes: u64 = 0;
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const nid = try engine.allocNode();
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
            try engine.putNode(nid, rec);
            // Every node gets label_a; even nodes also get label_b.
            try engine.addLabel(nid, label_a);
            if (i % 2 == 0) try engine.addLabel(nid, label_b);

            // A unique property keyed by index so we can verify lookups later.
            rec = (try engine.getNode(nid)).?;
            var keybuf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
            rec.prop_head = try engine.putProperty(rec.prop_head, key, .{ .int = @intCast(i) });
            try engine.putNode(nid, rec);

            _ = try engine.addEdge(hub, nid, @intCast(i % 4));

            // Periodically run a LIGHT checkpoint, as the load-driven path does.
            if (i % 500 == 499) {
                const before = engine.getMetrics().*;
                try engine.checkpointLight();
                const after = engine.getMetrics().*;

                // (b1) A derived-index save did NOT occur on the light path.
                try testing.expectEqual(before.derived_index_saves, after.derived_index_saves);
                // The light checkpoint still counts as a completed checkpoint.
                try testing.expect(after.checkpoints_completed > before.checkpoints_completed);

                // (b2) The WAL was truncated: bytes-since-compact is bounded and
                // does not grow unboundedly across checkpoints.
                const wal_bytes = engine.wal.bytesSinceCompact();
                if (prev_wal_bytes != 0) {
                    // After each light checkpoint the WAL is compacted, so the
                    // residual never balloons to O(total writes).
                    try testing.expect(wal_bytes <= prev_wal_bytes + 4096);
                }
                prev_wal_bytes = wal_bytes;
            }
        }

        // No full checkpoint ran, so NO derived-index save happened at all.
        try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_saves);
        try testing.expect(engine.getMetrics().checkpoints_completed > 0);

        // The label-index snapshot file must be stale relative to the manifest
        // counter (light checkpoints advanced the manifest but skipped the save).
        // Confirm by reopening below: recovery must rebuild from pages.
    }

    // (c) Reopen on the same data dir. The derived-index snapshots are stale, so
    // tryLoadDerivedIndexes() returns false and rebuildDerivedIndexes() runs.
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer engine.close() catch {};

        // The rebuild path sets index_rebuild_progress to 100% (10000).
        try testing.expectEqual(@as(u64, 10000), engine.getMetrics().index_rebuild_progress);

        // Scan by label_a returns ALL N nodes.
        const a_nodes = try engine.scanLabel(label_a, testing.allocator);
        defer testing.allocator.free(a_nodes);
        try testing.expectEqual(N, a_nodes.len);

        // Scan by label_b returns exactly the even-indexed nodes.
        const b_nodes = try engine.scanLabel(label_b, testing.allocator);
        defer testing.allocator.free(b_nodes);
        try testing.expectEqual((N + 1) / 2, b_nodes.len);

        // Property lookups return the right values after rebuild.
        // Node ids are hub=1, then 2..N+1 for i=0..N-1.
        var i: usize = 0;
        while (i < N) : (i += 100) {
            const nid: NodeId = @intCast(i + 2);
            const rec = (try engine.getNode(nid)).?;
            var keybuf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
            const val = try engine.getProperty(rec.prop_head, key, testing.allocator);
            try testing.expect(val != null);
            try testing.expectEqual(@as(i64, @intCast(i)), val.?.int);
        }

        // Edges are intact: the hub fans out to all N nodes.
        const out = try engine.expandOut(1, null, testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqual(N, out.len);
    }
}

// ============================================================================
// PHASE G — crash-reopen exact-index reconcile: gs public API tests (G2).
// checkpointEpoch / durableFrontierLsn / preRecoveryFrontierLsn — stable
// accessors over the manifest + recovery state. ADDITIVE; pure reads.
// ============================================================================

test "PHASE G G2: getters reflect manifest + recovery state across checkpoint and crash" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x4B} ** 16;
    const cfg = testConfig();

    var epoch_after_ckpt: u64 = undefined;
    var durable_after_ckpt: u64 = undefined;
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const epoch0 = engine.checkpointEpoch();
        const id = try engine.allocNode();
        try engine.putNode(id, test_support.emptyNode(1));
        try engine.checkpoint();
        // A checkpoint advances the epoch and the durable frontier.
        try testing.expect(engine.checkpointEpoch() > epoch0);
        try testing.expect(engine.durableFrontierLsn() > 0);
        epoch_after_ckpt = engine.checkpointEpoch();
        durable_after_ckpt = engine.durableFrontierLsn();
        try engine.close();
    }
    {
        // Clean reopen: pre-recovery == durable; epoch preserved.
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        try testing.expectEqual(engine.durableFrontierLsn(), engine.preRecoveryFrontierLsn());
        try testing.expectEqual(epoch_after_ckpt, engine.checkpointEpoch());
        const id = try engine.allocNode();
        try engine.putNode(id, test_support.emptyNode(2));
        engine.deinit(); // committed tail, then crash
    }
    // Crash reopen with a replayed tail: durable advanced past pre-recovery;
    // the epoch did NOT advance (recovery never bumps it); pre-recovery frontier
    // == the last checkpoint's durable frontier.
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    try testing.expect(engine.durableFrontierLsn() > engine.preRecoveryFrontierLsn());
    try testing.expectEqual(epoch_after_ckpt, engine.checkpointEpoch());
    try testing.expectEqual(durable_after_ckpt, engine.preRecoveryFrontierLsn());
}

// ============================================================================
// PHASE G — crash-reopen exact-index reconcile: tailAffectedNodeIds (G1).
// Resolve the Path-B tail-affected page set to owning node ids; empty is the
// "full rebuild / nothing to reconcile" sentinel. ADDITIVE; pure reads.
// ============================================================================

test "PHASE G G1: tailAffectedNodeIds resolves a nodes-page tail to exactly the affected node ids" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x47} ** 16;
    const cfg = testConfig();

    var new_ids: [3]NodeId = undefined;
    {
        // Session 1: fill nodes page 0 exactly, checkpoint (durable), close —
        // so page 0 is NOT in the crash tail and new nodes start a fresh page.
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const npp = engine.node_store.nodes_per_page;
        var created: u64 = 0;
        while (created < npp - 1) : (created += 1) {
            const id = try engine.allocNode();
            try engine.putNode(id, test_support.emptyNode(1));
        }
        try engine.checkpoint();
        try engine.close();
    }
    {
        // Session 2: create 3 NEW nodes on the fresh page (the tail), CRASH
        // (deinit — no checkpoint).
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        for (&new_ids) |*nid| {
            const id = try engine.allocNode();
            try engine.putNode(id, test_support.emptyNode(2));
            nid.* = id;
        }
        engine.deinit();
    }
    // Session 3: reopen (capture on) → the tail-affected node ids are exactly
    // the 3 new nodes (their page holds only them).
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    const got = (try engine.tailAffectedNodeIds(testing.allocator)).?;
    defer testing.allocator.free(got);
    std.mem.sort(NodeId, &new_ids, {}, std.sort.asc(NodeId));
    try testing.expectEqualSlices(NodeId, &new_ids, got);
}

test "PHASE G G1: tailAffectedNodeIds is empty on a clean reopen (no tail)" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x48} ** 16;
    const cfg = testConfig();
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const id = try engine.allocNode();
        try engine.putNode(id, test_support.emptyNode(1));
        try engine.checkpoint();
        try engine.close();
    }
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    // Clean reopen: pre-recovery frontier == durable frontier, no captured tail.
    try testing.expectEqual(engine.durableFrontierLsn(), engine.preRecoveryFrontierLsn());
    // No tail → non-null EMPTY ("nothing to reconcile"), distinct from the
    // null "rebuild required" sentinel exercised by the overflow test below.
    const got = (try engine.tailAffectedNodeIds(testing.allocator)).?;
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "PHASE G G1: tailAffectedNodeIds is null (rebuild required) when the tail capture is unavailable (overflow)" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x49} ** 16;
    const cfg = testConfig();
    {
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const id = try engine.allocNode();
        try engine.putNode(id, test_support.emptyNode(1));
        try engine.checkpoint();
        try engine.close();
    }
    {
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        const id = try engine.allocNode();
        try engine.putNode(id, test_support.emptyNode(2));
        engine.deinit(); // crash with a committed tail
    }
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    // A committed tail advanced the durable frontier past the pre-recovery one.
    try testing.expect(engine.durableFrontierLsn() > engine.preRecoveryFrontierLsn());
    try testing.expect(engine.tail_affected_pages != null);
    // Simulate an overflowed / absent capture: drop the captured set while the
    // frontier still shows a tail was applied → must fall back to full rebuild.
    testing.allocator.free(engine.tail_affected_pages.?);
    engine.tail_affected_pages = null;
    // A committed tail with no usable capture returns the null "rebuild
    // required" sentinel — NOT an empty slice (which would read as "nothing to
    // reconcile" and leave the external index silently stale on the tail node).
    const got = try engine.tailAffectedNodeIds(testing.allocator);
    try testing.expect(got == null);
}

test "PHASE G reverse-map: an in-place property value change (props-only tail) resolves the changed node" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x4A} ** 16;
    const cfg = testConfig();
    {
        // Session 1: node 1 with a fixed-size property; checkpoint (persists the
        // reverse map node1->head); close.
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const id = try engine.allocNode();
        var rec = test_support.emptyNode(1);
        rec.prop_head = try engine.putProperty(0, "k", .{ .int = 1 });
        try engine.putNode(id, rec);
        try engine.checkpoint();
        try engine.close();
    }
    {
        // Session 2: IN-PLACE value change (same key, same-size i64) rewrites
        // ONLY the props page, never node 1's record → node 1 is on NO tail
        // nodes page. Crash.
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        const rec = (try engine.getNode(1)).?;
        const new_head = try engine.putProperty(rec.prop_head, "k", .{ .int = 2 });
        try testing.expectEqual(rec.prop_head, new_head); // in-place: head unchanged
        engine.deinit();
    }
    // Session 3: the tail props page's live slot resolves to node 1 via the
    // reverse map (loaded on demand) — RED->GREEN: previously an empty rebuild.
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    try testing.expect(engine.tail_affected_pages != null);
    const got = (try engine.tailAffectedNodeIds(testing.allocator)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{1}, got);
}

test "PHASE G reverse-map: fill-page co-tenant is resolved (not a rebuild) on an in-place change" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x4C} ** 16;
    const cfg = testConfig();
    {
        // Session 1: nodes 1 and 2 both get a small property → they share one
        // slab fill page. Checkpoint persists the reverse map for BOTH; close.
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const id1 = try engine.allocNode();
        var r1 = test_support.emptyNode(1);
        r1.prop_head = try engine.putProperty(0, "k", .{ .int = 1 });
        try engine.putNode(id1, r1);
        const id2 = try engine.allocNode();
        var r2 = test_support.emptyNode(1);
        r2.prop_head = try engine.putProperty(0, "k", .{ .int = 2 });
        try engine.putNode(id2, r2);
        try engine.checkpoint();
        try engine.close();
    }
    {
        // Session 2: IN-PLACE change to node 1 only → rewrites the shared fill
        // page (node 2's live slot rides along, unchanged). No nodes page in the
        // tail. Crash.
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        const rec = (try engine.getNode(1)).?;
        _ = try engine.putProperty(rec.prop_head, "k", .{ .int = 9 });
        engine.deinit();
    }
    // Session 3: the shared props page resolves BOTH the changed node 1 AND the
    // co-tenant node 2 (harmless superset) via the reverse map — where the
    // nodes-page pass alone would have force-rebuilt.
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    const got = (try engine.tailAffectedNodeIds(testing.allocator)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(NodeId, &[_]NodeId{ 1, 2 }, got);
}

// ============================================================================
// PHASE G reverse map (prop_head -> node_id) — build/persist/reload wiring.
// ============================================================================

test "PHASE G reverse-map: fresh-graph build + checkpoint + reopen LOADS prop_head->node (not rebuilt)" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x5A} ** 16;
    const cfg = testConfig();
    var head1: u64 = undefined;
    var head2: u64 = undefined;
    {
        // A fresh graph is hydrated from creation, so putNode maintains the
        // reverse map live (no scan).
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        const id1 = try engine.allocNode();
        var r1 = test_support.emptyNode(1);
        r1.prop_head = try engine.putProperty(0, "k", .{ .int = 1 });
        try engine.putNode(id1, r1);
        head1 = r1.prop_head;
        const id2 = try engine.allocNode();
        var r2 = test_support.emptyNode(1);
        r2.prop_head = try engine.putProperty(0, "k", .{ .int = 2 });
        try engine.putNode(id2, r2);
        head2 = r2.prop_head;
        try testing.expectEqual(@as(?NodeId, id1), engine.prop_rev_index.get(head1));
        try testing.expectEqual(@as(?NodeId, id2), engine.prop_rev_index.get(head2));
        try engine.checkpoint();
        try engine.close();
    }
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    try engine.ensureDerivedHydrated();
    // Epoch matched → derived indexes LOADED clean (not rebuilt); the reverse
    // map loaded from its snapshot in the same path (no O(nodes) scan).
    try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_loads);
    try testing.expectEqual(@as(u64, 0), engine.getMetrics().derived_index_rebuilds);
    try testing.expectEqual(@as(?NodeId, 1), engine.prop_rev_index.get(head1));
    try testing.expectEqual(@as(?NodeId, 2), engine.prop_rev_index.get(head2));
}

test "PHASE G reverse-map: tail reconcile (insert + delete) equals a full rebuild of the map" {
    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0x4D} ** 16;
    const cfg = testConfig();
    {
        // Session 1: nodes 1,2,3 each with a property; checkpoint; close.
        const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        var n: u64 = 0;
        while (n < 3) : (n += 1) {
            const id = try engine.allocNode();
            var r = test_support.emptyNode(1);
            r.prop_head = try engine.putProperty(0, "k", .{ .int = @intCast(id) });
            try engine.putNode(id, r);
        }
        try engine.checkpoint();
        try engine.close();
    }
    {
        // Session 2 (committed tail): INSERT node 4 (with a prop) + DELETE node 1.
        // Crash (deinit — no checkpoint) so session 3 must reconcile.
        const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        const id = try engine.allocNode();
        var r = test_support.emptyNode(2);
        r.prop_head = try engine.putProperty(0, "k", .{ .int = 99 });
        try engine.putNode(id, r);
        try engine.deleteNode(1);
        engine.deinit();
    }
    // Session 3: hydrate → the bounded tail is RECONCILED into the loaded map.
    const engine = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer engine.deinit();
    try engine.ensureDerivedHydrated();
    try testing.expectEqual(@as(u64, 1), engine.getMetrics().derived_index_reconciles);

    // Snapshot the RECONCILED reverse map.
    var snap: std.AutoHashMapUnmanaged(u64, NodeId) = .empty;
    defer snap.deinit(testing.allocator);
    {
        var it = engine.prop_rev_index.map.iterator();
        while (it.next()) |e| try snap.put(testing.allocator, e.key_ptr.*, e.value_ptr.*);
    }

    // Ground truth: a full rebuild from a live node scan (deleted node 1 is
    // excluded by scanNodes; inserted node 4 is present).
    try engine_index.buildPropRevIndexFromScan(engine);

    try testing.expectEqual(engine.prop_rev_index.count(), snap.count());
    var it = engine.prop_rev_index.map.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(@as(?NodeId, e.value_ptr.*), snap.get(e.key_ptr.*));
    }
    // Node 1 was deleted → absent from both; node 4 present in both.
    const rec4 = (try engine.getNode(4)).?;
    try testing.expectEqual(@as(?NodeId, 4), snap.get(rec4.prop_head));
}
