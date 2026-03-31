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
    point_lookup_ns: f64,
    prop_read_ns: f64,
    expand_out_ns: f64,
    label_scan_ns: f64,
    checkpoint_ms: f64,
    open_ms: f64,
    mixed_ops_sec: f64,
    skipped: bool = false,
    skip_reason: ?[]const u8 = null,
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
        const edges = try engine.expandOut(uid, null, std.heap.page_allocator);
        defer std.heap.page_allocator.free(edges);
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
        const users = try engine.scanLabel(sr.labels.user, allocator);
        total_results += users.len;
        allocator.free(users);
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
                .label_set = 0,
                .flags = 0,
                ._pad = 0,
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
        else => 100,
    };

    const node_count = tier.cfg.totalNodes();
    const edge_count = tier.cfg.totalEdges();

    // Helper to create a sub-directory for each bench in this tier
    const makeSub = struct {
        fn f(alloc: std.mem.Allocator, base: []const u8, name: []const u8, suffix: []const u8) ?[]const u8 {
            const path = std.fmt.allocPrint(alloc, "{s}/sb_{s}_{s}", .{ base, name, suffix }) catch return null;
            std.fs.cwd().makePath(path) catch {
                alloc.free(path);
                return null;
            };
            return path;
        }
    }.f;

    // --- Seed ---
    var seed_ops_sec: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "seed")) |sub| {
        defer allocator.free(sub);
        if (benchSeed(allocator, sub, tier.cfg)) |r| {
            seed_ops_sec = r.ops_sec;
        } else |err| {
            print("ERROR in benchSeed: {any}\n", .{err});
        }
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Point lookup ---
    var point_lookup_ns: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "lookup")) |sub| {
        defer allocator.free(sub);
        if (benchPointLookup(allocator, sub, tier.cfg, iters)) |r| {
            point_lookup_ns = r;
        } else |err| {
            print("ERROR in benchPointLookup: {any}\n", .{err});
        }
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Property read ---
    var prop_read_ns: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "prop")) |sub| {
        defer allocator.free(sub);
        if (benchPropRead(allocator, sub, tier.cfg, iters)) |r| {
            prop_read_ns = r;
        } else |_| {}
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Expand out ---
    var expand_out_ns: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "expand")) |sub| {
        defer allocator.free(sub);
        if (benchExpandOut(allocator, sub, tier.cfg, iters)) |r| {
            expand_out_ns = r;
        } else |_| {}
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Label scan ---
    var label_scan_ns: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "label")) |sub| {
        defer allocator.free(sub);
        if (benchLabelScan(allocator, sub, tier.cfg, iters)) |r| {
            label_scan_ns = r;
        } else |_| {}
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Checkpoint ---
    var checkpoint_ms: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "ckpt")) |sub| {
        defer allocator.free(sub);
        if (benchCheckpointOp(allocator, sub, tier.cfg)) |r| {
            checkpoint_ms = r;
        } else |_| {}
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Open ---
    var open_ms: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "open")) |sub| {
        defer allocator.free(sub);
        if (benchOpen(allocator, sub, tier.cfg)) |r| {
            open_ms = r;
        } else |_| {}
    }

    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Mixed workload ---
    var mixed_ops_sec: f64 = 0;
    if (makeSub(allocator, base_path, tier.name, "mixed")) |sub| {
        defer allocator.free(sub);
        if (benchMixed(allocator, sub, tier.cfg, iters * 5)) |r| {
            mixed_ops_sec = r;
        } else |_| {}
    }

    return TierResult{
        .name = tier.name,
        .node_count = node_count,
        .edge_count = edge_count,
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
        .point_lookup_ns = 0,
        .prop_read_ns = 0,
        .expand_out_ns = 0,
        .label_scan_ns = 0,
        .checkpoint_ms = 0,
        .open_ms = 0,
        .mixed_ops_sec = 0,
        .skipped = true,
        .skip_reason = reason,
    };
}

// ---------------------------------------------------------------------------
// JSON output to stdout
// ---------------------------------------------------------------------------

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
        try out.writeFmt("      \"point_lookup_ns\": {d:.0},\n", .{r.point_lookup_ns});
        try out.writeFmt("      \"prop_read_ns\": {d:.0},\n", .{r.prop_read_ns});
        try out.writeFmt("      \"expand_out_ns\": {d:.0},\n", .{r.expand_out_ns});
        try out.writeFmt("      \"label_scan_ns\": {d:.0},\n", .{r.label_scan_ns});
        try out.writeFmt("      \"checkpoint_ms\": {d:.1},\n", .{r.checkpoint_ms});
        try out.writeFmt("      \"open_ms\": {d:.1},\n", .{r.open_ms});
        try out.writeFmt("      \"mixed_ops_sec\": {d:.0}\n", .{r.mixed_ops_sec});
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
