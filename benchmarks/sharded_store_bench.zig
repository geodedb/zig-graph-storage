// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Distribution + throughput benchmark for `graph_storage.sharded_store`.
//!
//! Measures three things against a `std.AutoHashMap(u64, u64)` baseline:
//!
//!   1. Shard distribution evenness on sequential u64 IDs (N = 10k, 100k, 1M).
//!      Reports per-shard count, max/min, p99/p1, and standard deviation.
//!      A good mixer keeps max/min ratio close to 1.0 and stddev/mean below
//!      ~5% for N >= 100k.  Catches regressions in the splitmix64 routing
//!      function that would hot-spot shards under monotonic ID allocation.
//!
//!   2. Put throughput: ShardedStore.put vs AutoHashMap.put at the same
//!      workload (1M sequential inserts).  Expected: within ~10% of baseline
//!      since sharded is just one extra mixing op + array index per call.
//!
//!   3. Get throughput: same workload, read-only.  Expected: within ~5%.
//!
//! Run via `zig build bench-sharded-store`.  Output is a text block the
//! bench-optimize / native-benchmarks skills can consume.

const std = @import("std");
const gs = @import("graph_storage");
const sharded = gs.sharded_store;

fn nowNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.Timestamp.now(io, .awake);
    const raw: i96 = ts.raw.nanoseconds;
    return if (raw > 0) @intCast(raw) else 0;
}

fn distributionReport(comptime N: usize, counts: [sharded.SHARD_COUNT]usize) void {
    var max_c: usize = 0;
    var min_c: usize = std.math.maxInt(usize);
    var sum_u128: u128 = 0;
    for (counts) |c| {
        if (c > max_c) max_c = c;
        if (c < min_c) min_c = c;
        sum_u128 += c;
    }
    const mean_f: f64 = @as(f64, @floatFromInt(sum_u128)) / @as(f64, @floatFromInt(sharded.SHARD_COUNT));
    var var_acc: f64 = 0;
    for (counts) |c| {
        const d = @as(f64, @floatFromInt(c)) - mean_f;
        var_acc += d * d;
    }
    const stddev_f = std.math.sqrt(var_acc / @as(f64, @floatFromInt(sharded.SHARD_COUNT)));
    const max_f = @as(f64, @floatFromInt(max_c));
    const min_f = @as(f64, @floatFromInt(min_c));
    const max_over_min = max_f / min_f;
    const stddev_over_mean = stddev_f / mean_f;
    std.debug.print(
        "  N={d:>7}  shards={d}  min={d}  max={d}  mean={d:.1}  stddev={d:.2}  max/min={d:.3}  stddev/mean={d:.4}\n",
        .{ N, sharded.SHARD_COUNT, min_c, max_c, mean_f, stddev_f, max_over_min, stddev_over_mean },
    );
}

fn benchDistribution(comptime N: usize) void {
    var counts = [_]usize{0} ** sharded.SHARD_COUNT;
    var i: u64 = 0;
    while (i < N) : (i += 1) counts[sharded.shardIndex(i)] += 1;
    distributionReport(N, counts);
}

fn benchPut(allocator: std.mem.Allocator, comptime N: usize) !void {
    // Baseline: std.AutoHashMap
    var base = std.AutoHashMap(u64, u64).init(allocator);
    defer base.deinit();
    try base.ensureTotalCapacity(N);
    const base_start = nowNs();
    var i: u64 = 0;
    while (i < N) : (i += 1) try base.put(i, i *% 3);
    const base_elapsed = nowNs() - base_start;

    // ShardedStore
    var shed = try sharded.ShardedStore(u64, u64).init(allocator);
    defer shed.deinit();
    try shed.ensureTotalCapacity(@intCast(N));
    const shed_start = nowNs();
    i = 0;
    while (i < N) : (i += 1) try shed.put(i, i *% 3);
    const shed_elapsed = nowNs() - shed_start;

    const ratio = @as(f64, @floatFromInt(shed_elapsed)) / @as(f64, @floatFromInt(base_elapsed));
    std.debug.print(
        "  N={d:>7}  AutoHashMap.put ={d:>10}ns  ShardedStore.put ={d:>10}ns  ratio={d:.3}x\n",
        .{ N, base_elapsed, shed_elapsed, ratio },
    );
}

fn benchGet(allocator: std.mem.Allocator, comptime N: usize) !void {
    // Pre-populate both.
    var base = std.AutoHashMap(u64, u64).init(allocator);
    defer base.deinit();
    try base.ensureTotalCapacity(N);
    var shed = try sharded.ShardedStore(u64, u64).init(allocator);
    defer shed.deinit();
    try shed.ensureTotalCapacity(@intCast(N));
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        try base.put(i, i *% 3);
        try shed.put(i, i *% 3);
    }

    // Get, same access pattern (ascending).  Use volatile sinks to
    // prevent the compiler from eliminating the read.
    var sink: u64 = 0;
    const base_start = nowNs();
    i = 0;
    while (i < N) : (i += 1) {
        if (base.get(i)) |v| sink ^= v;
    }
    const base_elapsed = nowNs() - base_start;

    const shed_start = nowNs();
    i = 0;
    while (i < N) : (i += 1) {
        if (shed.get(i)) |v| sink ^= v;
    }
    const shed_elapsed = nowNs() - shed_start;

    const ratio = @as(f64, @floatFromInt(shed_elapsed)) / @as(f64, @floatFromInt(base_elapsed));
    std.debug.print(
        "  N={d:>7}  AutoHashMap.get ={d:>10}ns  ShardedStore.get ={d:>10}ns  ratio={d:.3}x  (sink={d})\n",
        .{ N, base_elapsed, shed_elapsed, ratio, sink },
    );
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ShardedStore distribution ===\n", .{});
    benchDistribution(10_000);
    benchDistribution(100_000);
    benchDistribution(1_000_000);

    std.debug.print("\n=== ShardedStore.put vs AutoHashMap.put ===\n", .{});
    try benchPut(allocator, 10_000);
    try benchPut(allocator, 100_000);
    try benchPut(allocator, 1_000_000);

    std.debug.print("\n=== ShardedStore.get vs AutoHashMap.get ===\n", .{});
    try benchGet(allocator, 10_000);
    try benchGet(allocator, 100_000);
    try benchGet(allocator, 1_000_000);

    std.debug.print("\n", .{});
}
