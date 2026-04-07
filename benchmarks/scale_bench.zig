// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Incremental scale benchmark for graph-storage.
//!
//! Runs the same battery of operations at progressively larger graph sizes
//! and emits structured JSON to stdout for tracking over time.
//! A human-readable summary table is printed to stderr via std.debug.print.
//!
//! Run via: zig build scale-bench
//! Save:   zig build scale-bench 2>/dev/null > results.json

const std = @import("std");
const gs = @import("graph_storage");
const seed = @import("seed");
const builtin = @import("builtin");

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const NodeRec = gs.node.NodeRec;
const NodeId = gs.NodeId;
const PropertyValue = gs.PropertyValue;

const print = std.debug.print;

// ---------------------------------------------------------------------------
// Scale tier definitions
// ---------------------------------------------------------------------------

const Tier = struct {
    name: []const u8,
    cfg: seed.SeedConfig,
};

const tiers = [_]Tier{
    .{
        .name = "1K",
        .cfg = .{
            .users = 100,
            .devices = 200,
            .applications = 50,
            .groups = 30,
            .sites = 10,
            .locations = 20,
            .drives = 50,
            .drive_items = 500,
            .ip_addresses = 40,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        },
    },
    .{
        .name = "10K",
        .cfg = .{
            .users = 1_000,
            .devices = 2_000,
            .applications = 500,
            .groups = 300,
            .sites = 100,
            .locations = 200,
            .drives = 500,
            .drive_items = 5_000,
            .ip_addresses = 400,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        },
    },
    .{
        .name = "50K",
        .cfg = .{
            .users = 5_000,
            .devices = 10_000,
            .applications = 2_500,
            .groups = 1_500,
            .sites = 500,
            .locations = 1_000,
            .drives = 2_500,
            .drive_items = 25_000,
            .ip_addresses = 2_000,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        },
    },
    .{
        .name = "100K",
        .cfg = .{
            .users = 10_000,
            .devices = 20_000,
            .applications = 5_000,
            .groups = 3_000,
            .sites = 1_000,
            .locations = 2_000,
            .drives = 5_000,
            .drive_items = 50_000,
            .ip_addresses = 4_000,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        },
    },
    .{
        .name = "250K",
        .cfg = .{
            .users = 25_000,
            .devices = 50_000,
            .applications = 12_500,
            .groups = 7_500,
            .sites = 2_500,
            .locations = 5_000,
            .drives = 12_500,
            .drive_items = 125_000,
            .ip_addresses = 10_000,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        },
    },
    .{
        .name = "500K",
        .cfg = .{
            .users = 50_000,
            .devices = 100_000,
            .applications = 25_000,
            .groups = 15_000,
            .sites = 5_000,
            .locations = 10_000,
            .drives = 25_000,
            .drive_items = 250_000,
            .ip_addresses = 20_000,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        },
    },
};

// ---------------------------------------------------------------------------
// Per-tier results
// ---------------------------------------------------------------------------

const TierResult = struct {
    name: []const u8,
    node_count: u64,
    edge_count: u64,
    seed_ops_sec: f64,
    seed_ops_sec_stats: MetricStats = .{},
    point_lookup_ns: f64,
    point_lookup_ns_stats: MetricStats = .{},
    prop_read_ns: f64,
    prop_read_ns_stats: MetricStats = .{},
    expand_out_ns: f64,
    expand_out_ns_stats: MetricStats = .{},
    label_scan_ns: f64,
    label_scan_ns_stats: MetricStats = .{},
    checkpoint_ms: f64,
    checkpoint_ms_stats: MetricStats = .{},
    open_ms: f64,
    open_ms_stats: MetricStats = .{},
    mixed_ops_sec: f64,
    mixed_ops_sec_stats: MetricStats = .{},
    skipped: bool = false,
    skip_reason: ?[]const u8 = null,
};

const MetricStats = struct {
    avg: f64 = 0,
    p50: f64 = 0,
    p95: f64 = 0,
    p99: f64 = 0,
    stddev: f64 = 0,
    samples: u32 = 0,
};

const SampleMetrics = struct {
    seed_ops_sec: f64,
    point_lookup_ns: f64,
    prop_read_ns: f64,
    expand_out_ns: f64,
    label_scan_ns: f64,
    checkpoint_ms: f64,
    open_ms: f64,
    mixed_ops_sec: f64,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeConfig() GraphConfig {
    return .{
        .page_size = 8192,
        .buffer_pool_pages = 4096,
        .data_dir = "data",
    };
}

fn graphUuid(tag: u8) [16]u8 {
    return [_]u8{tag} ** 16;
}

fn sampleGraphUuid(tier: Tier, sample_idx: usize) [16]u8 {
    var uuid = [_]u8{0} ** 16;
    uuid[0] = @intCast(sample_idx & 0xFF);
    uuid[1] = tier.name[0];
    uuid[2] = tier.name[tier.name.len - 1];
    uuid[3] = @intCast((tier.cfg.users / 100) & 0xFF);
    return uuid;
}

fn sampleCountForTier(tier: Tier) usize {
    return switch (tier.cfg.users) {
        0...10_000 => 3,
        10_001...24_999 => 2,
        else => 1,
    };
}

fn sortLessThan(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn percentile(sorted: []const f64, pct: f64) f64 {
    if (sorted.len == 0) return 0;
    const rank = @as(usize, @intFromFloat(@ceil((pct / 100.0) * @as(f64, @floatFromInt(sorted.len)))));
    const idx = if (rank == 0) 0 else @min(rank - 1, sorted.len - 1);
    return sorted[idx];
}

fn summarizeSamples(allocator: std.mem.Allocator, samples: []const f64) !MetricStats {
    if (samples.len == 0) return .{};

    const sorted = try allocator.dupe(f64, samples);
    defer allocator.free(sorted);
    std.sort.heap(f64, sorted, {}, sortLessThan);

    var sum: f64 = 0;
    for (samples) |sample| sum += sample;
    const avg = sum / @as(f64, @floatFromInt(samples.len));

    var variance_sum: f64 = 0;
    for (samples) |sample| {
        const delta = sample - avg;
        variance_sum += delta * delta;
    }

    return .{
        .avg = avg,
        .p50 = percentile(sorted, 50),
        .p95 = percentile(sorted, 95),
        .p99 = percentile(sorted, 99),
        .stddev = std.math.sqrt(variance_sum / @as(f64, @floatFromInt(samples.len))),
        .samples = @intCast(samples.len),
    };
}

fn collectStats(allocator: std.mem.Allocator, sample_count: usize, bench_fn: anytype, args: anytype) !MetricStats {
    const samples = try allocator.alloc(f64, sample_count);
    defer allocator.free(samples);

    for (0..sample_count) |i| {
        samples[i] = try @call(.auto, bench_fn, args);
    }
    return summarizeSamples(allocator, samples);
}

/// Maximum wall-clock time for a single tier (15 minutes in ns).
const TIER_TIMEOUT_NS: u64 = 15 * 60 * std.time.ns_per_s;

// ---------------------------------------------------------------------------
// Stdout writer (buffered, for JSON output)
// ---------------------------------------------------------------------------

const StdoutWriter = struct {
    file: std.fs.File,
    buf: [8192]u8 = undefined,
    writer: ?std.fs.File.Writer = null,

    /// Must be called after the struct is in its final stack location.
    fn open(self: *StdoutWriter) void {
        self.writer = self.file.writer(&self.buf);
    }

    fn writeAll(self: *StdoutWriter, data: []const u8) !void {
        try self.writer.?.interface.writeAll(data);
    }

    fn writeFmt(self: *StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.?.interface.print(fmt, args);
    }

    fn flush(self: *StdoutWriter) !void {
        try self.writer.?.interface.flush();
    }
};

// ---------------------------------------------------------------------------
// Individual benchmark functions
// ---------------------------------------------------------------------------

fn benchSeed(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !struct { ops_sec: f64, sr: seed.SeedResult } {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB0), makeConfig());
    errdefer engine.close() catch {};

    var timer = try std.time.Timer.start();
    const sr = try seed.populate(engine, cfg);
    const elapsed = timer.read();

    try engine.checkpoint();
    try engine.close();

    const total: f64 = @floatFromInt(sr.node_count + sr.edge_count);
    const ns: f64 = @floatFromInt(elapsed);
    const ops_sec = if (ns > 0) total / (ns / 1_000_000_000.0) else 0;

    return .{ .ops_sec = ops_sec, .sr = sr };
}

fn benchPointLookup(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
    iterations: usize,
) !f64 {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB1), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iters = @min(iterations, @as(usize, @intCast(sr.node_count)));
    var rng = std.Random.DefaultPrng.init(123);
    const random = rng.random();

    var ids = try allocator.alloc(NodeId, iters);
    defer allocator.free(ids);
    for (0..iters) |i| {
        ids[i] = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
    }

    var timer = try std.time.Timer.start();
    for (ids) |id| {
        _ = try engine.getNode(id);
    }
    const elapsed = timer.read();

    const ns_f: f64 = @floatFromInt(elapsed);
    const count_f: f64 = @floatFromInt(iters);
    return ns_f / count_f;
}

fn benchPropRead(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
    iterations: usize,
) !f64 {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB2), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iters = @min(iterations, @as(usize, @intCast(sr.users.count())));
    var rng = std.Random.DefaultPrng.init(456);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
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

    const ns_f: f64 = @floatFromInt(elapsed);
    const count_f: f64 = @floatFromInt(iters);
    return ns_f / count_f;
}

fn benchExpandOut(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
    iterations: usize,
) !f64 {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB3), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iters = @min(iterations, @as(usize, @intCast(sr.users.count())));
    var rng = std.Random.DefaultPrng.init(789);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        const uid = random.intRangeAtMost(NodeId, sr.users.start, sr.users.end - 1);
        var iter = try engine.expandOutIter(uid, null);
        while (try iter.next()) |_| {}
        iter.deinit();
    }
    const elapsed = timer.read();

    const ns_f: f64 = @floatFromInt(elapsed);
    const count_f: f64 = @floatFromInt(iters);
    return ns_f / count_f;
}

fn benchLabelScan(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
    iterations: usize,
) !f64 {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB4), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const iters = @min(iterations, 50);

    var total_results: usize = 0;
    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        var iter = try engine.scanLabelIter(sr.labels.user);
        while (try iter.next()) |_| {
            total_results += 1;
        }
        iter.deinit();
    }
    const elapsed = timer.read();

    // Return ns per result, not per iteration
    if (total_results == 0) return 0;
    const ns_f: f64 = @floatFromInt(elapsed);
    const results_f: f64 = @floatFromInt(total_results);
    return ns_f / results_f;
}

fn benchCheckpointOp(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !f64 {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB5), makeConfig());
    defer engine.close() catch {};

    _ = try seed.populate(engine, cfg);

    var timer = try std.time.Timer.start();
    try engine.checkpoint();
    const elapsed = timer.read();

    return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
}

fn benchOpen(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
) !f64 {
    const gcfg = makeConfig();
    const uuid = graphUuid(0xB6);

    {
        const engine = try GraphEngine.create(allocator, data_dir, uuid, gcfg);
        _ = try seed.populate(engine, cfg);
        try engine.checkpoint();
        try engine.close();
    }

    const iterations: usize = 3;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const engine = try GraphEngine.open(allocator, data_dir, uuid, gcfg);
        try engine.close();
    }
    const elapsed = timer.read();

    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
}

fn benchMixed(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    cfg: seed.SeedConfig,
    iterations: usize,
) !f64 {
    const engine = try GraphEngine.create(allocator, data_dir, graphUuid(0xB7), makeConfig());
    defer engine.close() catch {};

    const sr = try seed.populate(engine, cfg);

    const total_ops = @min(iterations, @as(usize, @intCast(sr.node_count)));
    var rng = std.Random.DefaultPrng.init(999);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..total_ops) |_| {
        const roll = random.intRangeAtMost(u32, 0, 99);
        if (roll < 80) {
            const nid = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
            _ = try engine.getNode(nid);
        } else if (roll < 95) {
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
        } else {
            const nid = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
            engine.deleteNode(nid) catch {};
        }
    }
    const elapsed = timer.read();

    const count_f: f64 = @floatFromInt(total_ops);
    const ns_f: f64 = @floatFromInt(elapsed);
    return if (ns_f > 0) count_f / (ns_f / 1_000_000_000.0) else 0;
}

fn benchPointLookupOnSeeded(
    allocator: std.mem.Allocator,
    engine: *GraphEngine,
    sr: seed.SeedResult,
    iterations: usize,
) !f64 {
    const iters = @min(iterations, @as(usize, @intCast(sr.node_count)));
    var rng = std.Random.DefaultPrng.init(123);
    const random = rng.random();

    var ids = try allocator.alloc(NodeId, iters);
    defer allocator.free(ids);
    for (0..iters) |i| {
        ids[i] = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
    }

    var timer = try std.time.Timer.start();
    for (ids) |id| {
        _ = try engine.getNode(id);
    }
    const elapsed = timer.read();

    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters));
}

fn benchPropReadOnSeeded(
    allocator: std.mem.Allocator,
    engine: *GraphEngine,
    sr: seed.SeedResult,
    iterations: usize,
) !f64 {
    const iters = @min(iterations, @as(usize, @intCast(sr.users.count())));
    var rng = std.Random.DefaultPrng.init(456);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        const uid = random.intRangeAtMost(NodeId, sr.users.start, sr.users.end - 1);
        const rec = try engine.getNode(uid);
        if (rec) |r| {
            if (r.prop_head != 0) {
                const val = try engine.getProperty(r.prop_head, "display_name", allocator);
                if (val) |v| switch (v) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
            }
        }
    }
    const elapsed = timer.read();

    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters));
}

fn benchExpandOutOnSeeded(
    engine: *GraphEngine,
    sr: seed.SeedResult,
    iterations: usize,
) !f64 {
    const iters = @min(iterations, @as(usize, @intCast(sr.users.count())));
    var rng = std.Random.DefaultPrng.init(789);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        const uid = random.intRangeAtMost(NodeId, sr.users.start, sr.users.end - 1);
        var iter = try engine.expandOutIter(uid, null);
        while (try iter.next()) |_| {}
        iter.deinit();
    }
    const elapsed = timer.read();

    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters));
}

fn benchLabelScanOnSeeded(
    engine: *GraphEngine,
    sr: seed.SeedResult,
    iterations: usize,
) !f64 {
    const iters = @min(iterations, 50);

    var total_results: usize = 0;
    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        var iter = try engine.scanLabelIter(sr.labels.user);
        while (try iter.next()) |_| {
            total_results += 1;
        }
        iter.deinit();
    }
    const elapsed = timer.read();

    if (total_results == 0) return 0;
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total_results));
}

fn benchCheckpointOnSeeded(engine: *GraphEngine) !f64 {
    var timer = try std.time.Timer.start();
    try engine.checkpoint();
    return @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;
}

fn benchOpenFromCheckpoint(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    graph_uuid: [16]u8,
    cfg: GraphConfig,
) !f64 {
    const iterations: usize = 3;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const engine = try GraphEngine.open(allocator, data_dir, graph_uuid, cfg);
        try engine.close();
    }
    return @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
}

fn benchMixedOnSeeded(
    engine: *GraphEngine,
    sr: seed.SeedResult,
    iterations: usize,
) !f64 {
    const total_ops = @min(iterations, @as(usize, @intCast(sr.node_count)));
    var rng = std.Random.DefaultPrng.init(999);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    for (0..total_ops) |_| {
        const roll = random.intRangeAtMost(u32, 0, 99);
        if (roll < 80) {
            const nid = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
            _ = try engine.getNode(nid);
        } else if (roll < 95) {
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
        } else {
            const nid = random.intRangeAtMost(NodeId, 1, @intCast(sr.node_count));
            engine.deleteNode(nid) catch {};
        }
    }
    const elapsed = timer.read();

    return if (elapsed == 0)
        0
    else
        @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
}

fn runTierSample(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    tier: Tier,
    sample_idx: usize,
    iterations: usize,
) !SampleMetrics {
    const sample_dir = try std.fmt.allocPrint(allocator, "{s}/sb_{s}_sample_{d}", .{ base_path, tier.name, sample_idx });
    defer allocator.free(sample_dir);
    try std.fs.cwd().makePath(sample_dir);

    const cfg = makeConfig();
    const uuid = sampleGraphUuid(tier, sample_idx);
    const engine = try GraphEngine.create(allocator, sample_dir, uuid, cfg);

    var timer = try std.time.Timer.start();
    const sr = try seed.populate(engine, tier.cfg);
    const seed_elapsed = timer.read();
    const seeded_items = @as(f64, @floatFromInt(sr.node_count + sr.edge_count));
    const seed_ops_sec = if (seed_elapsed == 0)
        0
    else
        seeded_items / (@as(f64, @floatFromInt(seed_elapsed)) / 1_000_000_000.0);

    const point_lookup_ns = try benchPointLookupOnSeeded(allocator, engine, sr, iterations);
    const prop_read_ns = try benchPropReadOnSeeded(allocator, engine, sr, iterations);
    const expand_out_ns = try benchExpandOutOnSeeded(engine, sr, iterations);
    const label_scan_ns = try benchLabelScanOnSeeded(engine, sr, iterations);
    const checkpoint_ms = try benchCheckpointOnSeeded(engine);
    try engine.close();

    const open_ms = try benchOpenFromCheckpoint(allocator, sample_dir, uuid, cfg);
    const mixed_engine = try GraphEngine.open(allocator, sample_dir, uuid, cfg);
    defer mixed_engine.close() catch {};
    const mixed_ops_sec = try benchMixedOnSeeded(mixed_engine, sr, iterations * 5);

    return .{
        .seed_ops_sec = seed_ops_sec,
        .point_lookup_ns = point_lookup_ns,
        .prop_read_ns = prop_read_ns,
        .expand_out_ns = expand_out_ns,
        .label_scan_ns = label_scan_ns,
        .checkpoint_ms = checkpoint_ms,
        .open_ms = open_ms,
        .mixed_ops_sec = mixed_ops_sec,
    };
}

// ---------------------------------------------------------------------------
// Run a single tier
// ---------------------------------------------------------------------------

fn runTier(allocator: std.mem.Allocator, base_path: []const u8, tier: Tier) TierResult {
    var tier_start = std.time.Timer.start() catch {
        return skipResult(tier, "timer init failed");
    };

    const iters: usize = switch (tier.cfg.users) {
        0...200 => 1000,
        201...2_000 => 500,
        2_001...10_000 => 200,
        10_001...24_999 => 100,
        else => 50,
    };
    const sample_count = sampleCountForTier(tier);

    const node_count = tier.cfg.totalNodes();
    const edge_count = tier.cfg.totalEdges();
    var seed_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc seed samples failed");
    defer allocator.free(seed_samples);
    var point_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc point samples failed");
    defer allocator.free(point_samples);
    var prop_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc prop samples failed");
    defer allocator.free(prop_samples);
    var expand_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc expand samples failed");
    defer allocator.free(expand_samples);
    var label_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc label samples failed");
    defer allocator.free(label_samples);
    var checkpoint_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc checkpoint samples failed");
    defer allocator.free(checkpoint_samples);
    var open_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc open samples failed");
    defer allocator.free(open_samples);
    var mixed_samples = allocator.alloc(f64, sample_count) catch return skipResult(tier, "alloc mixed samples failed");
    defer allocator.free(mixed_samples);

    for (0..sample_count) |sample_idx| {
        const sample = runTierSample(allocator, base_path, tier, sample_idx, iters) catch |err| {
            print("ERROR in runTierSample({s}, {d}): {any}\n", .{ tier.name, sample_idx, err });
            return skipResult(tier, @errorName(err));
        };
        seed_samples[sample_idx] = sample.seed_ops_sec;
        point_samples[sample_idx] = sample.point_lookup_ns;
        prop_samples[sample_idx] = sample.prop_read_ns;
        expand_samples[sample_idx] = sample.expand_out_ns;
        label_samples[sample_idx] = sample.label_scan_ns;
        checkpoint_samples[sample_idx] = sample.checkpoint_ms;
        open_samples[sample_idx] = sample.open_ms;
        mixed_samples[sample_idx] = sample.mixed_ops_sec;

        if (checkTimeout(&tier_start, tier)) |r| return r;
    }

    const seed_ops_sec_stats = summarizeSamples(allocator, seed_samples) catch return skipResult(tier, "summarize seed failed");
    const point_lookup_ns_stats = summarizeSamples(allocator, point_samples) catch return skipResult(tier, "summarize point failed");
    const prop_read_ns_stats = summarizeSamples(allocator, prop_samples) catch return skipResult(tier, "summarize prop failed");
    const expand_out_ns_stats = summarizeSamples(allocator, expand_samples) catch return skipResult(tier, "summarize expand failed");
    const label_scan_ns_stats = summarizeSamples(allocator, label_samples) catch return skipResult(tier, "summarize label failed");
    const checkpoint_ms_stats = summarizeSamples(allocator, checkpoint_samples) catch return skipResult(tier, "summarize checkpoint failed");
    const open_ms_stats = summarizeSamples(allocator, open_samples) catch return skipResult(tier, "summarize open failed");
    const mixed_ops_sec_stats = summarizeSamples(allocator, mixed_samples) catch return skipResult(tier, "summarize mixed failed");

    return TierResult{
        .name = tier.name,
        .node_count = node_count,
        .edge_count = edge_count,
        .seed_ops_sec = seed_ops_sec_stats.avg,
        .seed_ops_sec_stats = seed_ops_sec_stats,
        .point_lookup_ns = point_lookup_ns_stats.avg,
        .point_lookup_ns_stats = point_lookup_ns_stats,
        .prop_read_ns = prop_read_ns_stats.avg,
        .prop_read_ns_stats = prop_read_ns_stats,
        .expand_out_ns = expand_out_ns_stats.avg,
        .expand_out_ns_stats = expand_out_ns_stats,
        .label_scan_ns = label_scan_ns_stats.avg,
        .label_scan_ns_stats = label_scan_ns_stats,
        .checkpoint_ms = checkpoint_ms_stats.avg,
        .checkpoint_ms_stats = checkpoint_ms_stats,
        .open_ms = open_ms_stats.avg,
        .open_ms_stats = open_ms_stats,
        .mixed_ops_sec = mixed_ops_sec_stats.avg,
        .mixed_ops_sec_stats = mixed_ops_sec_stats,
    };
}

fn checkTimeout(tier_start: *std.time.Timer, tier: Tier) ?TierResult {
    const elapsed = tier_start.read();
    if (elapsed > TIER_TIMEOUT_NS) {
        return skipResult(tier, "timeout (>15min)");
    }
    return null;
}

fn skipResult(tier: Tier, reason: []const u8) TierResult {
    return TierResult{
        .name = tier.name,
        .node_count = tier.cfg.totalNodes(),
        .edge_count = tier.cfg.totalEdges(),
        .seed_ops_sec = 0,
        .seed_ops_sec_stats = .{},
        .point_lookup_ns = 0,
        .point_lookup_ns_stats = .{},
        .prop_read_ns = 0,
        .prop_read_ns_stats = .{},
        .expand_out_ns = 0,
        .expand_out_ns_stats = .{},
        .label_scan_ns = 0,
        .label_scan_ns_stats = .{},
        .checkpoint_ms = 0,
        .checkpoint_ms_stats = .{},
        .open_ms = 0,
        .open_ms_stats = .{},
        .mixed_ops_sec = 0,
        .mixed_ops_sec_stats = .{},
        .skipped = true,
        .skip_reason = reason,
    };
}

// ---------------------------------------------------------------------------
// JSON output to stdout
// ---------------------------------------------------------------------------

fn writeMetricStats(out: *StdoutWriter, key: []const u8, stats: MetricStats, trailing_comma: bool) !void {
    try out.writeFmt(
        "      \"{s}_stats\": {{ \"samples\": {d}, \"avg\": {d:.3}, \"p50\": {d:.3}, \"p95\": {d:.3}, \"p99\": {d:.3}, \"stddev\": {d:.3} }}{s}\n",
        .{
            key,
            stats.samples,
            stats.avg,
            stats.p50,
            stats.p95,
            stats.p99,
            stats.stddev,
            if (trailing_comma) "," else "",
        },
    );
}

fn writeJsonOutput(out: *StdoutWriter, results: []const TierResult) !void {
    try out.writeAll("{\n");
    try out.writeAll("  \"version\": 1,\n");

    // Timestamp
    const ts = std.time.timestamp();
    const epoch_secs: u64 = @intCast(ts);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try out.writeFmt("  \"timestamp\": \"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\",\n", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });

    try out.writeAll("  \"git_commit\": \"unknown\",\n");

    // System info
    try out.writeFmt("  \"system\": {{ \"os\": \"{s}\", \"arch\": \"{s}\" }},\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

    try out.writeAll("  \"page_size\": 8192,\n");
    try out.writeAll("  \"buffer_pool_pages\": 4096,\n");

    // Tiers
    try out.writeAll("  \"tiers\": [\n");
    for (results, 0..) |r, i| {
        try out.writeAll("    {\n");
        try out.writeFmt("      \"name\": \"{s}\",\n", .{r.name});
        try out.writeFmt("      \"node_count\": {d},\n", .{r.node_count});
        try out.writeFmt("      \"edge_count\": {d},\n", .{r.edge_count});
        if (r.skipped) {
            try out.writeAll("      \"skipped\": true,\n");
            if (r.skip_reason) |reason| {
                try out.writeFmt("      \"skip_reason\": \"{s}\",\n", .{reason});
            }
        }
        try out.writeFmt("      \"seed_ops_sec\": {d:.0},\n", .{r.seed_ops_sec});
        try writeMetricStats(out, "seed_ops_sec", r.seed_ops_sec_stats, true);
        try out.writeFmt("      \"point_lookup_ns\": {d:.0},\n", .{r.point_lookup_ns});
        try writeMetricStats(out, "point_lookup_ns", r.point_lookup_ns_stats, true);
        try out.writeFmt("      \"prop_read_ns\": {d:.0},\n", .{r.prop_read_ns});
        try writeMetricStats(out, "prop_read_ns", r.prop_read_ns_stats, true);
        try out.writeFmt("      \"expand_out_ns\": {d:.0},\n", .{r.expand_out_ns});
        try writeMetricStats(out, "expand_out_ns", r.expand_out_ns_stats, true);
        try out.writeFmt("      \"label_scan_ns\": {d:.0},\n", .{r.label_scan_ns});
        try writeMetricStats(out, "label_scan_ns", r.label_scan_ns_stats, true);
        try out.writeFmt("      \"checkpoint_ms\": {d:.1},\n", .{r.checkpoint_ms});
        try writeMetricStats(out, "checkpoint_ms", r.checkpoint_ms_stats, true);
        try out.writeFmt("      \"open_ms\": {d:.1},\n", .{r.open_ms});
        try writeMetricStats(out, "open_ms", r.open_ms_stats, true);
        try out.writeFmt("      \"mixed_ops_sec\": {d:.0},\n", .{r.mixed_ops_sec});
        try writeMetricStats(out, "mixed_ops_sec", r.mixed_ops_sec_stats, false);
        if (i < results.len - 1) {
            try out.writeAll("    },\n");
        } else {
            try out.writeAll("    }\n");
        }
    }
    try out.writeAll("  ]\n");
    try out.writeAll("}\n");
    try out.flush();
}

// ---------------------------------------------------------------------------
// Human-readable summary to stderr (via std.debug.print)
// ---------------------------------------------------------------------------

fn writeSummary(results: []const TierResult) void {
    print("\n", .{});
    print("{s}\n", .{"=" ** 110});
    print("  graph-storage incremental scale benchmark\n", .{});
    print("{s}\n\n", .{"=" ** 110});

    print("  {s:<6} {s:>8} {s:>8} {s:>12} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>12}\n", .{
        "Tier", "Nodes", "Edges", "Seed ops/s", "Lookup", "PropRd", "Expand", "LblScan", "Ckpt(ms)", "Open(ms)", "Mixed ops/s",
    });
    print("  {s:<6} {s:>8} {s:>8} {s:>12} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>12}\n", .{
        "-" ** 6, "-" ** 8, "-" ** 8, "-" ** 12, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 12,
    });

    for (results) |r| {
        if (r.skipped) {
            print("  {s:<6} {d:>8} {d:>8} SKIPPED ({s})\n", .{
                r.name, r.node_count, r.edge_count, r.skip_reason orelse "unknown",
            });
        } else {
            print("  {s:<6} {d:>8} {d:>8} {d:>12.0} {d:>10.0} {d:>10.0} {d:>10.0} {d:>10.0} {d:>10.1} {d:>10.1} {d:>12.0}\n", .{
                r.name,
                r.node_count,
                r.edge_count,
                r.seed_ops_sec,
                r.point_lookup_ns,
                r.prop_read_ns,
                r.expand_out_ns,
                r.label_scan_ns,
                r.checkpoint_ms,
                r.open_ms,
                r.mixed_ops_sec,
            });
        }
    }

    print("\n{s}\n\n", .{"=" ** 110});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse optional max-tier argument
    var args = std.process.args();
    _ = args.next(); // skip program name

    var max_tier_count: usize = tiers.len;
    if (args.next()) |arg| {
        for (tiers, 0..) |t, i| {
            if (std.mem.eql(u8, arg, t.name)) {
                max_tier_count = i + 1;
                break;
            }
        }
    }

    var tmp_dir = std.testing.tmpDir(.{});
    defer {
        print("  Cleaning up tmp_dir...\n", .{});
        tmp_dir.cleanup();
        print("  Done cleanup.\n", .{});
    }

    const base_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base_path);

    var results: [tiers.len]TierResult = undefined;
    var completed: usize = 0;

    for (tiers[0..max_tier_count], 0..) |tier, i| {
        print("  Running tier {s} ({d} nodes, {d} edges)...\n", .{
            tier.name, tier.cfg.totalNodes(), tier.cfg.totalEdges(),
        });

        results[i] = runTier(allocator, base_path, tier);
        print("    runTier finished for {s}.\n", .{tier.name});
        completed = i + 1;

        if (results[i].skipped) {
            print("  Tier {s} skipped: {s}\n", .{
                tier.name, results[i].skip_reason orelse "unknown",
            });
        } else {
            print("  Tier {s} complete.\n", .{tier.name});
        }
    }

    writeSummary(results[0..completed]);

    var out = StdoutWriter{ .file = .{ .handle = std.posix.STDOUT_FILENO } };
    out.open();
    try writeJsonOutput(&out, results[0..completed]);
}
