// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Benchmark comparison tool for graph-storage.
//!
//! Reads two JSON result files (baseline and current), compares every tier and
//! every tracked percentile/variance field, and exits non-zero when a tier is
//! missing, skipped, or regressed beyond the configured threshold.

const std = @import("std");

const print = std.debug.print;

const MetricStats = struct {
    samples: f64 = 0,
    avg: f64 = 0,
    p50: f64 = 0,
    p95: f64 = 0,
    p99: f64 = 0,
    stddev: f64 = 0,
};

const TierData = struct {
    name: []const u8 = "",
    node_count: f64 = 0,
    edge_count: f64 = 0,
    seed_ops_sec: f64 = 0,
    seed_ops_sec_stats: ?MetricStats = null,
    point_lookup_ns: f64 = 0,
    point_lookup_ns_stats: ?MetricStats = null,
    prop_read_ns: f64 = 0,
    prop_read_ns_stats: ?MetricStats = null,
    expand_out_ns: f64 = 0,
    expand_out_ns_stats: ?MetricStats = null,
    label_scan_ns: f64 = 0,
    label_scan_ns_stats: ?MetricStats = null,
    checkpoint_ms: f64 = 0,
    checkpoint_ms_stats: ?MetricStats = null,
    open_ms: f64 = 0,
    open_ms_stats: ?MetricStats = null,
    mixed_ops_sec: f64 = 0,
    mixed_ops_sec_stats: ?MetricStats = null,
    skipped: bool = false,
};

const BenchResult = struct {
    version: f64 = 0,
    tiers: []TierData = &[_]TierData{},
};

const MetricKind = enum {
    higher_is_better,
    lower_is_better,
};

const Metric = struct {
    name: []const u8,
    kind: MetricKind,
    get: *const fn (TierData) f64,
};

fn resolvedStats(flat: f64, maybe_stats: ?MetricStats) MetricStats {
    if (maybe_stats) |stats| {
        return .{
            .samples = if (stats.samples != 0) stats.samples else if (flat != 0) 1 else 0,
            .avg = if (stats.avg != 0) stats.avg else flat,
            .p50 = if (stats.p50 != 0) stats.p50 else flat,
            .p95 = if (stats.p95 != 0) stats.p95 else flat,
            .p99 = if (stats.p99 != 0) stats.p99 else flat,
            .stddev = stats.stddev,
        };
    }

    return .{
        .samples = if (flat != 0) 1 else 0,
        .avg = flat,
        .p50 = flat,
        .p95 = flat,
        .p99 = flat,
        .stddev = 0,
    };
}

fn getSeedAvg(t: TierData) f64 {
    return resolvedStats(t.seed_ops_sec, t.seed_ops_sec_stats).avg;
}
fn getSeedP95(t: TierData) f64 {
    return resolvedStats(t.seed_ops_sec, t.seed_ops_sec_stats).p95;
}
fn getSeedP99(t: TierData) f64 {
    return resolvedStats(t.seed_ops_sec, t.seed_ops_sec_stats).p99;
}
fn getSeedStdDev(t: TierData) f64 {
    return resolvedStats(t.seed_ops_sec, t.seed_ops_sec_stats).stddev;
}
fn getPointLookupAvg(t: TierData) f64 {
    return resolvedStats(t.point_lookup_ns, t.point_lookup_ns_stats).avg;
}
fn getPointLookupP95(t: TierData) f64 {
    return resolvedStats(t.point_lookup_ns, t.point_lookup_ns_stats).p95;
}
fn getPointLookupP99(t: TierData) f64 {
    return resolvedStats(t.point_lookup_ns, t.point_lookup_ns_stats).p99;
}
fn getPointLookupStdDev(t: TierData) f64 {
    return resolvedStats(t.point_lookup_ns, t.point_lookup_ns_stats).stddev;
}
fn getPropReadAvg(t: TierData) f64 {
    return resolvedStats(t.prop_read_ns, t.prop_read_ns_stats).avg;
}
fn getPropReadP95(t: TierData) f64 {
    return resolvedStats(t.prop_read_ns, t.prop_read_ns_stats).p95;
}
fn getPropReadP99(t: TierData) f64 {
    return resolvedStats(t.prop_read_ns, t.prop_read_ns_stats).p99;
}
fn getPropReadStdDev(t: TierData) f64 {
    return resolvedStats(t.prop_read_ns, t.prop_read_ns_stats).stddev;
}
fn getExpandOutAvg(t: TierData) f64 {
    return resolvedStats(t.expand_out_ns, t.expand_out_ns_stats).avg;
}
fn getExpandOutP95(t: TierData) f64 {
    return resolvedStats(t.expand_out_ns, t.expand_out_ns_stats).p95;
}
fn getExpandOutP99(t: TierData) f64 {
    return resolvedStats(t.expand_out_ns, t.expand_out_ns_stats).p99;
}
fn getExpandOutStdDev(t: TierData) f64 {
    return resolvedStats(t.expand_out_ns, t.expand_out_ns_stats).stddev;
}
fn getLabelScanAvg(t: TierData) f64 {
    return resolvedStats(t.label_scan_ns, t.label_scan_ns_stats).avg;
}
fn getLabelScanP95(t: TierData) f64 {
    return resolvedStats(t.label_scan_ns, t.label_scan_ns_stats).p95;
}
fn getLabelScanP99(t: TierData) f64 {
    return resolvedStats(t.label_scan_ns, t.label_scan_ns_stats).p99;
}
fn getLabelScanStdDev(t: TierData) f64 {
    return resolvedStats(t.label_scan_ns, t.label_scan_ns_stats).stddev;
}
fn getCheckpointAvg(t: TierData) f64 {
    return resolvedStats(t.checkpoint_ms, t.checkpoint_ms_stats).avg;
}
fn getCheckpointP95(t: TierData) f64 {
    return resolvedStats(t.checkpoint_ms, t.checkpoint_ms_stats).p95;
}
fn getCheckpointP99(t: TierData) f64 {
    return resolvedStats(t.checkpoint_ms, t.checkpoint_ms_stats).p99;
}
fn getCheckpointStdDev(t: TierData) f64 {
    return resolvedStats(t.checkpoint_ms, t.checkpoint_ms_stats).stddev;
}
fn getOpenAvg(t: TierData) f64 {
    return resolvedStats(t.open_ms, t.open_ms_stats).avg;
}
fn getOpenP95(t: TierData) f64 {
    return resolvedStats(t.open_ms, t.open_ms_stats).p95;
}
fn getOpenP99(t: TierData) f64 {
    return resolvedStats(t.open_ms, t.open_ms_stats).p99;
}
fn getOpenStdDev(t: TierData) f64 {
    return resolvedStats(t.open_ms, t.open_ms_stats).stddev;
}
fn getMixedAvg(t: TierData) f64 {
    return resolvedStats(t.mixed_ops_sec, t.mixed_ops_sec_stats).avg;
}
fn getMixedP95(t: TierData) f64 {
    return resolvedStats(t.mixed_ops_sec, t.mixed_ops_sec_stats).p95;
}
fn getMixedP99(t: TierData) f64 {
    return resolvedStats(t.mixed_ops_sec, t.mixed_ops_sec_stats).p99;
}
fn getMixedStdDev(t: TierData) f64 {
    return resolvedStats(t.mixed_ops_sec, t.mixed_ops_sec_stats).stddev;
}

const metrics = [_]Metric{
    .{ .name = "seed.avg", .kind = .higher_is_better, .get = getSeedAvg },
    .{ .name = "seed.p95", .kind = .higher_is_better, .get = getSeedP95 },
    .{ .name = "seed.p99", .kind = .higher_is_better, .get = getSeedP99 },
    .{ .name = "seed.stddev", .kind = .lower_is_better, .get = getSeedStdDev },
    .{ .name = "lookup.avg", .kind = .lower_is_better, .get = getPointLookupAvg },
    .{ .name = "lookup.p95", .kind = .lower_is_better, .get = getPointLookupP95 },
    .{ .name = "lookup.p99", .kind = .lower_is_better, .get = getPointLookupP99 },
    .{ .name = "lookup.stddev", .kind = .lower_is_better, .get = getPointLookupStdDev },
    .{ .name = "prop.avg", .kind = .lower_is_better, .get = getPropReadAvg },
    .{ .name = "prop.p95", .kind = .lower_is_better, .get = getPropReadP95 },
    .{ .name = "prop.p99", .kind = .lower_is_better, .get = getPropReadP99 },
    .{ .name = "prop.stddev", .kind = .lower_is_better, .get = getPropReadStdDev },
    .{ .name = "expand.avg", .kind = .lower_is_better, .get = getExpandOutAvg },
    .{ .name = "expand.p95", .kind = .lower_is_better, .get = getExpandOutP95 },
    .{ .name = "expand.p99", .kind = .lower_is_better, .get = getExpandOutP99 },
    .{ .name = "expand.stddev", .kind = .lower_is_better, .get = getExpandOutStdDev },
    .{ .name = "label.avg", .kind = .lower_is_better, .get = getLabelScanAvg },
    .{ .name = "label.p95", .kind = .lower_is_better, .get = getLabelScanP95 },
    .{ .name = "label.p99", .kind = .lower_is_better, .get = getLabelScanP99 },
    .{ .name = "label.stddev", .kind = .lower_is_better, .get = getLabelScanStdDev },
    .{ .name = "checkpoint.avg", .kind = .lower_is_better, .get = getCheckpointAvg },
    .{ .name = "checkpoint.p95", .kind = .lower_is_better, .get = getCheckpointP95 },
    .{ .name = "checkpoint.p99", .kind = .lower_is_better, .get = getCheckpointP99 },
    .{ .name = "checkpoint.stddev", .kind = .lower_is_better, .get = getCheckpointStdDev },
    .{ .name = "open.avg", .kind = .lower_is_better, .get = getOpenAvg },
    .{ .name = "open.p95", .kind = .lower_is_better, .get = getOpenP95 },
    .{ .name = "open.p99", .kind = .lower_is_better, .get = getOpenP99 },
    .{ .name = "open.stddev", .kind = .lower_is_better, .get = getOpenStdDev },
    .{ .name = "mixed.avg", .kind = .higher_is_better, .get = getMixedAvg },
    .{ .name = "mixed.p95", .kind = .higher_is_better, .get = getMixedP95 },
    .{ .name = "mixed.p99", .kind = .higher_is_better, .get = getMixedP99 },
    .{ .name = "mixed.stddev", .kind = .lower_is_better, .get = getMixedStdDev },
};

fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) !BenchResult {
    const bench_io = std.Io.Threaded.global_single_threaded.io();
    const content = std.Io.Dir.cwd().readFileAlloc(bench_io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        print("Error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(BenchResult, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        print("Error: failed to parse '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    _ = &parsed;
    return parsed.value;
}

fn findTier(result: BenchResult, name: []const u8) ?TierData {
    for (result.tiers) |tier| {
        if (std.mem.eql(u8, tier.name, name)) return tier;
    }
    return null;
}

fn computeDeltaPct(baseline_val: f64, current_val: f64) f64 {
    if (baseline_val == 0) return 0;
    return ((current_val - baseline_val) / baseline_val) * 100.0;
}

fn isRegression(delta_pct: f64, kind: MetricKind, threshold: f64) bool {
    return switch (kind) {
        .higher_is_better => delta_pct < -threshold,
        .lower_is_better => delta_pct > threshold,
    };
}

fn validateTierSets(baseline: BenchResult, current: BenchResult) bool {
    var ok = true;

    if (baseline.tiers.len != current.tiers.len) {
        print("Tier count mismatch: baseline has {d}, current has {d}\n", .{ baseline.tiers.len, current.tiers.len });
        ok = false;
    }

    for (baseline.tiers) |tier| {
        if (findTier(current, tier.name) == null) {
            print("Missing tier in current results: {s}\n", .{tier.name});
            ok = false;
        }
    }

    for (current.tiers) |tier| {
        if (findTier(baseline, tier.name) == null) {
            print("Unexpected extra tier in current results: {s}\n", .{tier.name});
            ok = false;
        }
    }

    return ok;
}

fn validateNoSkippedTiers(result: BenchResult, label: []const u8) bool {
    var ok = true;
    for (result.tiers) |tier| {
        if (tier.skipped) {
            print("{s} tier skipped and cannot be compared: {s}\n", .{ label, tier.name });
            ok = false;
        }
    }
    return ok;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    const argv = try init.args.toSlice(allocator);

    if (argv.len < 3) {
        print("Usage: compare-bench <baseline.json> <current.json> [threshold%]\n", .{});
        std.process.exit(2);
    }
    const baseline_path = argv[1];
    const current_path = argv[2];

    var threshold: f64 = 20.0;
    if (argv.len > 3) {
        threshold = std.fmt.parseFloat(f64, argv[3]) catch 20.0;
    }

    const baseline = readJsonFile(allocator, baseline_path) catch std.process.exit(2);
    const current = readJsonFile(allocator, current_path) catch std.process.exit(2);

    if (!validateTierSets(baseline, current) or !validateNoSkippedTiers(baseline, "Baseline") or !validateNoSkippedTiers(current, "Current")) {
        std.process.exit(1);
    }

    print("\n{s}\n", .{"=" ** 96});
    print("  Benchmark Comparison\n", .{});
    print("  Baseline: {s}\n", .{baseline_path});
    print("  Current:  {s}\n", .{current_path});
    print("  Threshold: {d:.0}%\n", .{threshold});
    print("{s}\n\n", .{"=" ** 96});

    print("  {s:<6} {s:<20} {s:>12} {s:>12} {s:>10} {s:>6}\n", .{
        "Tier", "Metric", "Baseline", "Current", "Delta%", "Status",
    });
    print("  {s:<6} {s:<20} {s:>12} {s:>12} {s:>10} {s:>6}\n", .{
        "-" ** 6, "-" ** 20, "-" ** 12, "-" ** 12, "-" ** 10, "-" ** 6,
    });

    var any_regression = false;

    for (baseline.tiers) |base_tier| {
        const cur_tier = findTier(current, base_tier.name) orelse continue;

        for (metrics) |metric| {
            const base_val = metric.get(base_tier);
            const cur_val = metric.get(cur_tier);
            const delta = computeDeltaPct(base_val, cur_val);
            const regressed = isRegression(delta, metric.kind, threshold);
            if (regressed) any_regression = true;

            const sign = if (delta >= 0) "+" else "";
            print("  {s:<6} {s:<20} {d:>12.2} {d:>12.2} {s}{d:>8.1}% {s:>6}\n", .{
                base_tier.name,
                metric.name,
                base_val,
                cur_val,
                sign,
                delta,
                if (regressed) "FAIL" else "PASS",
            });
        }

        print("\n", .{});
    }

    print("{s}\n", .{"=" ** 96});
    if (any_regression) {
        print("  RESULT: FAIL -- regression(s) detected above threshold\n\n", .{});
        std.process.exit(1);
    }
    print("  RESULT: PASS -- all metrics within threshold\n\n", .{});
}
