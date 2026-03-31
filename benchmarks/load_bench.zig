// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Heavy-load benchmark using the Geode-model test data seeder.
//!
//! Uses seed.zig to populate a graph at various scales, then benchmarks
//! point lookups, property reads, adjacency traversal, label scans,
//! checkpoint, cold start, and mixed workloads.
//!
//! Run via: zig build load-bench
//!      or: zig build load-bench -- medium
//!      or: zig build load-bench -- large

const std = @import("std");
const gs = @import("graph_storage");
const seed = @import("seed");

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const NodeRec = gs.node.NodeRec;
const NodeId = gs.NodeId;
const PropertyValue = gs.PropertyValue;

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

fn printHeader(profile_name: []const u8, cfg: seed.SeedConfig) void {
    print("\n{s}\n", .{"=" ** 78});
    print("  graph-storage heavy-load benchmark ({s} profile)\n", .{profile_name});
    print("  Expected nodes: {d}  edges: ~{d}\n", .{ cfg.totalNodes(), cfg.totalEdges() });
    print("{s}\n\n", .{"=" ** 78});
    print("  {s:<35} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "Benchmark", "Count", "Total (ms)", "Avg (ns)", "ops/sec",
    });
    print("  {s:<35} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "-" ** 35, "-" ** 10, "-" ** 14, "-" ** 12, "-" ** 10,
    });
}

fn printResult(r: BenchResult) void {
    const total_ms = @as(f64, @floatFromInt(r.total_ns)) / 1_000_000.0;
    print("  {s:<35} {d:>10} {d:>14.2} {d:>12.1} {d:>10.0}\n", .{
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
        .page_size = 4096,
        .buffer_pool_pages = 4096, // larger pool for heavy load
        .data_dir = "data",
    };
}

fn graphUuid(tag: u8) [16]u8 {
    return [_]u8{tag} ** 16;
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

fn benchSeedThroughput(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !struct { result: BenchResult, seed_result: seed.SeedResult } {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA0), makeConfig());
    errdefer engine.close() catch {};

    var timer = try std.time.Timer.start();
    const sr = try seed.populate(engine, cfg);
    const elapsed = timer.read();

    // Keep engine open for subsequent benchmarks -- caller will close
    // Actually, close here; each benchmark creates its own engine.
    try engine.checkpoint();
    try engine.close();

    const total_entities = sr.node_count + sr.edge_count;

    return .{
        .result = BenchResult{
            .name = "seed throughput (nodes+edges)",
            .count = @intCast(total_entities),
            .total_ns = elapsed,
        },
        .seed_result = sr,
    };
}

fn benchPointLookup(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA1), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iterations: usize = @min(5000, @as(usize, @intCast(sr.node_count)));
    var rng = std.Random.DefaultPrng.init(123);
    const random = rng.random();

    // Pre-generate random node IDs to look up
    var ids = try allocator.alloc(NodeId, iterations);
    defer allocator.free(ids);
    for (0..iterations) |i| {
        ids[i] = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
    }

    var timer = try std.time.Timer.start();
    for (ids) |id| {
        _ = try engine.getNode(id);
    }
    const elapsed = timer.read();

    return BenchResult{ .name = "point lookup (getNode)", .count = iterations, .total_ns = elapsed };
}

fn benchPropertyLookup(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA2), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iterations: usize = @min(2000, @as(usize, @intCast(sr.users.count())));
    var rng = std.Random.DefaultPrng.init(456);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const uid = random.intRangeAtMost(NodeId, sr.users.start, sr.users.end - 1);
        const rec = try engine.getNode(uid);
        if (rec) |r| {
            if (r.prop_head != 0) {
                const val = try engine.getProperty(r.prop_head, "display_name", allocator);
                if (val) |v| {
                    switch (v) {
                        .string => |s| allocator.free(s),
                        else => {},
                    }
                }
            }
        }
    }
    const elapsed = timer.read();

    return BenchResult{ .name = "property lookup (display_name)", .count = iterations, .total_ns = elapsed };
}

fn benchAdjacencyTraversal(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA3), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iterations: usize = @min(2000, @as(usize, @intCast(sr.users.count())));
    var rng = std.Random.DefaultPrng.init(789);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const uid = random.intRangeAtMost(NodeId, sr.users.start, sr.users.end - 1);
        const edges = try engine.expandOut(uid, null, std.heap.page_allocator);
        defer std.heap.page_allocator.free(edges);
    }
    const elapsed = timer.read();

    return BenchResult{ .name = "adjacency traversal (expandOut)", .count = iterations, .total_ns = elapsed };
}

fn benchLabelScan(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA4), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iterations: usize = 50;

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const users = try engine.scanLabel(sr.labels.user, allocator);
        allocator.free(users);
    }
    const elapsed = timer.read();

    return BenchResult{ .name = "label scan (User)", .count = iterations, .total_ns = elapsed };
}

fn benchCheckpoint(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA5), makeConfig());
    defer engine.close() catch {};

    _ = try seed.populate(engine, cfg);

    var timer = try std.time.Timer.start();
    try engine.checkpoint();
    const elapsed = timer.read();

    return BenchResult{ .name = "checkpoint (full graph)", .count = 1, .total_ns = elapsed };
}

fn benchColdStart(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const gcfg = makeConfig();
    const uuid = graphUuid(0xA6);

    // Create, populate, checkpoint, close
    {
        const engine = try GraphEngine.create(allocator, data_dir, uuid, gcfg);
        _ = try seed.populate(engine, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    // Benchmark open (includes recovery)
    const iterations: usize = 3;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        const engine = try GraphEngine.open(allocator, data_dir, uuid, gcfg);
        try engine.close();
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "cold start (open+close)", .count = iterations, .total_ns = elapsed };
}

fn benchMixedWorkload(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xA7), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    // Mixed workload: 80% reads, 15% writes, 5% deletes
    const total_ops: usize = @min(5000, @as(usize, @intCast(sr.node_count)));
    var rng = std.Random.DefaultPrng.init(999);
    const random = rng.random();

    var timer = try std.time.Timer.start();

    for (0..total_ops) |_| {
        const roll = random.intRangeAtMost(u32, 0, 99);
        if (roll < 80) {
            // Read: point lookup
            const nid = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
            _ = try engine.getNode(nid);
        } else if (roll < 95) {
            // Write: create a new node
            const nid = try engine.allocNode();
            try engine.putNode(nid, NodeRec{
                .out_head = 0,
                .in_head = 0,
                .prop_head = 0,
                .label_set = 0,
                .flags = 0,
                ._pad = 0,
                .txn_stamp = 1,
            });
        } else {
            // Delete: delete a random node (best effort)
            const nid = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
            engine.deleteNode(nid) catch {};
        }
    }

    const elapsed = timer.read();
    return BenchResult{ .name = "mixed (80/15/5 r/w/d)", .count = total_ops, .total_ns = elapsed };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse profile from command-line args
    var args = std.process.args();
    _ = args.next(); // skip program name

    var profile_name: []const u8 = "small";
    var cfg = seed.SeedConfig.small();

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "tiny")) {
            profile_name = "tiny";
            cfg = seed.SeedConfig.tiny();
        } else if (std.mem.eql(u8, arg, "small")) {
            profile_name = "small";
            cfg = seed.SeedConfig.small();
        } else if (std.mem.eql(u8, arg, "medium")) {
            profile_name = "medium";
            cfg = seed.SeedConfig.medium();
        } else if (std.mem.eql(u8, arg, "large")) {
            profile_name = "large";
            cfg = seed.SeedConfig.large();
        } else {
            print("Unknown profile: {s}. Use: tiny, small, medium, large\n", .{arg});
            return;
        }
    }

    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const base_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base_path);

    printHeader(profile_name, cfg);

    // Run each benchmark in its own subdirectory
    runSingleBench(allocator, base_path, "01_seed", benchSeedThroughputWrapper, cfg);
    runSingleBench(allocator, base_path, "02_lookup", benchPointLookup, cfg);
    runSingleBench(allocator, base_path, "03_props", benchPropertyLookup, cfg);
    runSingleBench(allocator, base_path, "04_adj", benchAdjacencyTraversal, cfg);
    runSingleBench(allocator, base_path, "05_label", benchLabelScan, cfg);
    runSingleBench(allocator, base_path, "06_ckpt", benchCheckpoint, cfg);
    runSingleBench(allocator, base_path, "07_cold", benchColdStart, cfg);
    runSingleBench(allocator, base_path, "08_mixed", benchMixedWorkload, cfg);

    printFooter();
}

fn runSingleBench(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    suffix: []const u8,
    func: *const fn (std.mem.Allocator, []const u8, seed.SeedConfig) anyerror!BenchResult,
    cfg: seed.SeedConfig,
) void {
    const sub = std.fmt.allocPrint(allocator, "{s}/lb_{s}", .{ base_path, suffix }) catch {
        print("  FAILED: alloc -- {s}\n", .{suffix});
        return;
    };
    defer allocator.free(sub);
    std.fs.cwd().makePath(sub) catch {
        print("  FAILED: mkdir -- {s}\n", .{suffix});
        return;
    };
    const result = func(allocator, sub, cfg) catch |err| {
        print("  FAILED: {s} -- {s}\n", .{ @errorName(err), suffix });
        return;
    };
    printResult(result);
}

/// Wrapper that discards the seed_result and returns only the BenchResult.
fn benchSeedThroughputWrapper(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !BenchResult {
    const outcome = try benchSeedThroughput(allocator, data_dir, cfg);
    return outcome.result;
}
