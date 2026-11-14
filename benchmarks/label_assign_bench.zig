// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6524: latency of a NEW label name.
//
// Label assignment is not WAL-logged, so a new name is made durable (temp
// file fsync, rename, directory fsync) before its id is returned (SONNY-6491).
// A ShardedGraphEngine keeps one `labels.dict` per shard, so one new name is
// written N times. This times `getOrAssignLabel` for LABELS new names on a
// fresh 16-shard store and on a single GraphEngine, and once more for names
// that already exist (no write). fsync latency is a property of the disk:
// pass a directory on the disk you care about (default: /tmp), e.g.
//
//   zig build bench-label-assign -- /path/on/real/disk
//
// No assertion: this is a measurement, not a gate.

const std = @import("std");
const gs = @import("graph_storage");

const LABELS: usize = 30;

fn nowNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

const Result = struct { median: u64, p90: u64, max: u64, total: u64 };

fn summarize(samples: []u64) Result {
    var total: u64 = 0;
    for (samples) |s| total += s;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .median = samples[samples.len / 2],
        .p90 = samples[(samples.len * 9) / 10],
        .max = samples[samples.len - 1],
        .total = total,
    };
}

fn timeNewNames(engine: anytype, prefix: []const u8) !Result {
    var samples: [LABELS]u64 = undefined;
    var buf: [64]u8 = undefined;
    for (&samples, 0..) |*s, i| {
        const name = try std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, i });
        const t0 = nowNs();
        _ = try engine.getOrAssignLabel(name);
        s.* = nowNs() - t0;
    }
    return summarize(&samples);
}

fn report(what: []const u8, r: Result) void {
    std.debug.print("  {s:<34} median {d:>8.3} ms  p90 {d:>8.3} ms  max {d:>8.3} ms  total {d:>9.3} ms\n", .{ what, ms(r.median), ms(r.p90), ms(r.max), ms(r.total) });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var args = init.args.iterate();
    _ = args.next();
    const base = args.next() orelse "/tmp";

    var dir_buf: [512]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "{s}/label_assign_bench_{d}", .{ base, nowNs() });
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    std.debug.print("SONNY-6524 new label name latency, {d} names, data dir {s}\n", .{ LABELS, data_dir });

    {
        const eng = try gs.ShardedGraphEngine.create(allocator, data_dir, [_]u8{0x65} ** 16, .{});
        defer eng.close() catch {};
        report("ShardedGraphEngine (16 shards) new", try timeNewNames(eng, "L"));
        report("ShardedGraphEngine (16 shards) existing", try timeNewNames(eng, "L"));
    }
    {
        const eng = try gs.GraphEngine.create(allocator, data_dir, [_]u8{0x66} ** 16, .{});
        defer eng.close() catch {};
        report("GraphEngine new", try timeNewNames(eng, "L"));
    }
}
