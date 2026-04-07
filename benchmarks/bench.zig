// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Performance benchmark harness for the graph-storage engine.
//!
//! Benchmarks: node insert, edge insert, property write, property read,
//! adjacency expansion, label scan, checkpoint, and cold-start (open).
//!
//! Run via: zig build bench
//!      or: make bench

const std = @import("std");
const gs = @import("graph_storage");

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const NodeRec = gs.node.NodeRec;
const PropertyValue = gs.PropertyValue;
const NodeId = gs.NodeId;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const NODE_COUNT: usize = 10_000;
const EDGE_COUNT: usize = 10_000;
const PROP_WRITE_COUNT: usize = 5_000;
const PROP_READ_COUNT: usize = 5_000;
const HIGH_DEGREE_EDGES: usize = 500;
const LABEL_NODE_COUNT: usize = 2_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const BenchResult = struct {
    name: []const u8,
    count: usize,
    total_ns: u64,

    fn ops_per_sec(self: BenchResult) f64 {
        if (self.total_ns == 0) return 0;
        const count_f: f64 = @floatFromInt(self.count);
        const ns_f: f64 = @floatFromInt(self.total_ns);
        return count_f / (ns_f / 1_000_000_000.0);
    }

    fn avg_ns(self: BenchResult) f64 {
        if (self.count == 0) return 0;
        const ns_f: f64 = @floatFromInt(self.total_ns);
        const count_f: f64 = @floatFromInt(self.count);
        return ns_f / count_f;
    }
};

const print = std.debug.print;

fn printHeader() void {
    print("\n{s}\n", .{"=" ** 78});
    print("  graph-storage benchmark suite\n", .{});
    print("{s}\n\n", .{"=" ** 78});
    print("  {s:<30} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "Benchmark", "Count", "Total (ms)", "Avg (ns)", "ops/sec",
    });
    print("  {s:<30} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "-" ** 30, "-" ** 10, "-" ** 14, "-" ** 12, "-" ** 10,
    });
}

fn printResult(r: BenchResult) void {
    const total_ms = @as(f64, @floatFromInt(r.total_ns)) / 1_000_000.0;
    print("  {s:<30} {d:>10} {d:>14.2} {d:>12.1} {d:>10.0}\n", .{
        r.name,
        r.count,
        total_ms,
        r.avg_ns(),
        r.ops_per_sec(),
    });
}

fn printFooter() void {
    print("\n{s}\n\n", .{"=" ** 78});
}

fn makeConfig() GraphConfig {
    return .{
        .page_size = 8192,
        .buffer_pool_pages = 1024,
        .data_dir = "data",
    };
}

fn graphUuid(seed: u8) [16]u8 {
    return [_]u8{seed} ** 16;
}

fn emptyNode(seed: u64) NodeRec {
    // txn_stamp must be non-zero; a record with all-zero fields is treated as empty
    return NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = seed +| 1,
    };
}

// ---------------------------------------------------------------------------
// Individual benchmarks
// ---------------------------------------------------------------------------

fn benchNodeInsert(data_dir: []const u8) !BenchResult {
    const engine = try GraphEngine.create(std.heap.page_allocator, data_dir, graphUuid(0x10), makeConfig());
    defer engine.close() catch {};

    var timer = try std.time.Timer.start();

    for (0..NODE_COUNT) |i| {
        const nid = try engine.allocNode();
        try engine.putNode(nid, emptyNode(i));
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "node insert", .count = NODE_COUNT, .total_ns = elapsed };
}

fn benchEdgeInsert(data_dir: []const u8) !BenchResult {
    const allocator = std.heap.page_allocator;
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0x20), makeConfig());
    defer engine.close() catch {};

    // Create node pairs and add edges (same pattern as expandOut benchmark)
    var timer = try std.time.Timer.start();

    for (0..EDGE_COUNT) |i| {
        const from = try engine.allocNode();
        try engine.putNode(from, emptyNode(1));
        const to = try engine.allocNode();
        try engine.putNode(to, emptyNode(i + 2));
        _ = try engine.addEdge(from, to, @intCast(i % 8));
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "edge insert", .count = EDGE_COUNT, .total_ns = elapsed };
}

fn benchPropertyWrite(data_dir: []const u8) !BenchResult {
    const engine = try GraphEngine.create(std.heap.page_allocator, data_dir, graphUuid(0x30), makeConfig());
    defer engine.close() catch {};

    // Create a node to hold properties
    const nid = try engine.allocNode();
    try engine.putNode(nid, emptyNode(1));

    // Pre-generate unique key strings
    const allocator = std.heap.page_allocator;
    var keys: [PROP_WRITE_COUNT][]const u8 = undefined;
    for (0..PROP_WRITE_COUNT) |i| {
        keys[i] = try std.fmt.allocPrint(allocator, "key_{d:0>6}", .{i});
    }
    defer for (0..PROP_WRITE_COUNT) |i| {
        allocator.free(keys[i]);
    };

    // We write properties to the node's property chain.
    // The engine API uses putProperty(prop_head, key, value) -> new_head.
    // We need to update the node's prop_head each time.
    var prop_head: u64 = 0;

    var timer = try std.time.Timer.start();

    for (0..PROP_WRITE_COUNT) |i| {
        prop_head = try engine.putProperty(prop_head, keys[i], PropertyValue{ .int = @intCast(i) });
    }

    const elapsed = timer.read();

    // Update the node with the final prop_head so the state is consistent
    var rec = (try engine.getNode(nid)).?;
    rec.prop_head = prop_head;
    try engine.putNode(nid, rec);

    return BenchResult{ .name = "property write", .count = PROP_WRITE_COUNT, .total_ns = elapsed };
}

fn benchPropertyRead(data_dir: []const u8) !BenchResult {
    const allocator = std.heap.page_allocator;

    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0x40), makeConfig());
    defer engine.close() catch {};

    // Create node and write properties
    const nid = try engine.allocNode();
    try engine.putNode(nid, emptyNode(1));

    var keys: [PROP_READ_COUNT][]const u8 = undefined;
    for (0..PROP_READ_COUNT) |i| {
        keys[i] = try std.fmt.allocPrint(allocator, "rkey_{d:0>6}", .{i});
    }
    defer for (0..PROP_READ_COUNT) |i| {
        allocator.free(keys[i]);
    };

    var prop_head: u64 = 0;
    for (0..PROP_READ_COUNT) |i| {
        prop_head = try engine.putProperty(prop_head, keys[i], PropertyValue{ .int = @intCast(i) });
    }

    // Now benchmark reads
    var timer = try std.time.Timer.start();

    for (0..PROP_READ_COUNT) |i| {
        const val = try engine.getProperty(prop_head, keys[i], allocator);
        if (val) |v| {
            switch (v) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "property read", .count = PROP_READ_COUNT, .total_ns = elapsed };
}

fn benchExpandOut(data_dir: []const u8) !BenchResult {
    const allocator = std.heap.page_allocator;

    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0x50), makeConfig());
    defer engine.close() catch {};

    // Create a high-degree hub node and many target nodes
    const hub = try engine.allocNode();
    try engine.putNode(hub, emptyNode(1));

    for (0..HIGH_DEGREE_EDGES) |i| {
        const target = try engine.allocNode();
        try engine.putNode(target, emptyNode(i + 2));
        _ = try engine.addEdge(hub, target, @intCast(i % 8));
    }

    // Benchmark expandOut
    const iterations: usize = 100;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var iter = try engine.expandOutIter(hub, null);
        while (try iter.next()) |_| {}
        iter.deinit();
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "expandOut (500 edges)", .count = iterations, .total_ns = elapsed };
}

fn benchLabelScan(data_dir: []const u8) !BenchResult {
    const allocator = std.heap.page_allocator;

    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0x60), makeConfig());
    defer engine.close() catch {};

    // Create nodes and assign a label to a subset
    const label_id: u32 = 1;
    for (0..LABEL_NODE_COUNT) |i| {
        const nid = try engine.allocNode();
        try engine.putNode(nid, emptyNode(i));
        if (i % 3 == 0) {
            try engine.addLabel(nid, label_id);
        }
    }

    const iterations: usize = 200;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var iter = try engine.scanLabelIter(label_id);
        while (try iter.next()) |_| {}
        iter.deinit();
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "scanLabel", .count = iterations, .total_ns = elapsed };
}

fn benchCheckpoint(data_dir: []const u8) !BenchResult {
    const engine = try GraphEngine.create(std.heap.page_allocator, data_dir, graphUuid(0x70), makeConfig());
    defer engine.close() catch {};

    // Bulk insert to dirty many pages
    for (0..5_000) |i| {
        const nid = try engine.allocNode();
        try engine.putNode(nid, emptyNode(i));
    }

    var timer = try std.time.Timer.start();
    try engine.checkpoint();
    const elapsed = timer.read();

    return BenchResult{ .name = "checkpoint (5k nodes)", .count = 1, .total_ns = elapsed };
}

fn benchColdStart(data_dir: []const u8) !BenchResult {
    const allocator = std.heap.page_allocator;
    const cfg = makeConfig();
    const uuid = graphUuid(0x80);

    // Create, populate, and close
    {
        const engine = try GraphEngine.create(allocator, data_dir, uuid, cfg);
        for (0..5_000) |i| {
            const nid = try engine.allocNode();
            try engine.putNode(nid, emptyNode(i));
        }
        try engine.checkpoint();
        try engine.close();
    }

    // Benchmark open (includes WAL replay / recovery)
    const iterations: usize = 5;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        const engine = try GraphEngine.open(allocator, data_dir, uuid, cfg);
        try engine.close();
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "cold start (open)", .count = iterations, .total_ns = elapsed };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn runBench(base_path: []const u8, comptime suffix: []const u8, comptime func: *const fn ([]const u8) anyerror!BenchResult) void {
    const sub = std.fmt.allocPrint(std.heap.page_allocator, "{s}/bench_{s}", .{ base_path, suffix }) catch |err| {
        print("  FAILED: {s} -- {s}\n", .{ @errorName(err), suffix });
        return;
    };
    defer std.heap.page_allocator.free(sub);
    std.fs.cwd().makePath(sub) catch |err| {
        print("  FAILED: {s} -- {s}\n", .{ @errorName(err), suffix });
        return;
    };
    const result = func(sub) catch |err| {
        print("  FAILED: {s} -- {s}\n", .{ @errorName(err), suffix });
        return;
    };
    printResult(result);
}

pub fn main() !void {
    // Create a temporary directory for all benchmark data
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const base_path = try tmp_dir.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(base_path);

    printHeader();

    runBench(base_path, "01", benchNodeInsert);
    runBench(base_path, "02", benchEdgeInsert);
    runBench(base_path, "03", benchPropertyWrite);
    runBench(base_path, "04", benchPropertyRead);
    runBench(base_path, "05", benchExpandOut);
    runBench(base_path, "06", benchLabelScan);
    runBench(base_path, "07", benchCheckpoint);
    runBench(base_path, "08", benchColdStart);

    printFooter();
}
