// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Measures ShardedGraphEngine N-way writer throughput vs single
//! GraphEngine. Spec §Measurement: sharded engine at ≥ 4× single-
//! engine throughput on 16 cores.
//!
//! Output (machine-readable one-liners):
//!
//!   SHARDED_THROUGHPUT workers=W ops=OPS elapsed_ns=... ops_per_s=...
//!   SINGLE_THROUGHPUT  workers=1 ops=OPS elapsed_ns=... ops_per_s=...
//!   SHARDING_SPEEDUP ratio=X.XX

const std = @import("std");
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const GraphConfig = graph_storage.GraphConfig;
const NodeRec = graph_storage.node.NodeRec;

const N_OPS: usize = 20_000;

fn nanoTimestamp() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
}

fn emptyNode(seed: u64) NodeRec {
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

fn benchConfig() GraphConfig {
    return .{
        .page_size = 8192,
        .buffer_pool_pages = 1024,
        .data_dir = "data",
    };
}

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var tmp_dir = try cwd.createDirPathOpen(io, ".zig-cache/tmp/sharded-throughput", .{});
    defer {
        tmp_dir.close(io);
        cwd.deleteTree(io, ".zig-cache/tmp/sharded-throughput") catch {};
    }
    const base_path = try tmp_dir.realPathFileAlloc(io, ".", std.heap.page_allocator);
    defer std.heap.page_allocator.free(base_path);

    const sharded_elapsed = try benchSharded(base_path);
    std.debug.print(
        "SHARDED_THROUGHPUT workers={d} ops={d} elapsed_ns={d} ops_per_s={d}\n",
        .{ 16, N_OPS, sharded_elapsed, @divTrunc(N_OPS * std.time.ns_per_s, sharded_elapsed) },
    );

    const single_elapsed = try benchSingle(base_path);
    std.debug.print(
        "SINGLE_THROUGHPUT workers={d} ops={d} elapsed_ns={d} ops_per_s={d}\n",
        .{ 1, N_OPS, single_elapsed, @divTrunc(N_OPS * std.time.ns_per_s, single_elapsed) },
    );

    const ratio = @as(f64, @floatFromInt(single_elapsed)) / @as(f64, @floatFromInt(sharded_elapsed));
    std.debug.print("SHARDING_SPEEDUP ratio={d:.2}\n", .{ratio});
}

fn benchSharded(base_path: []const u8) !u64 {
    const allocator = std.heap.page_allocator;
    const uuid = [_]u8{0xBE} ** 16;
    var eng = try ShardedGraphEngine.create(allocator, base_path, uuid, benchConfig());
    defer eng.close() catch {};

    const n_workers: usize = 16;
    const per_worker: usize = N_OPS / n_workers;

    const Worker = struct {
        engine: *ShardedGraphEngine,
        shard_idx: usize,
        n: usize,
        prev_node: u64 = 0,

        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) {
                const id = ctx.engine.shards[ctx.shard_idx].allocNode() catch return;
                ctx.engine.shards[ctx.shard_idx].putNode(id, emptyNode(1)) catch return;
                if (ctx.prev_node != 0) {
                    _ = ctx.engine.shards[ctx.shard_idx].addEdge(ctx.prev_node, id, 1) catch {};
                }
                ctx.prev_node = id;
            }
        }
    };

    var workers: [16]Worker = undefined;
    for (&workers, 0..) |*w, i| w.* = .{ .engine = eng, .shard_idx = i, .n = per_worker };

    const start_ns = nanoTimestamp();
    var threads: [16]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    for (threads) |t| t.join();
    const end_ns = nanoTimestamp();

    const diff: i96 = end_ns - start_ns;
    return if (diff > 0) @intCast(diff) else 1;
}

fn benchSingle(base_path: []const u8) !u64 {
    const allocator = std.heap.page_allocator;
    const uuid = [_]u8{0xBF} ** 16;
    const eng = try GraphEngine.create(allocator, base_path, uuid, benchConfig());
    defer eng.close() catch {};

    var prev: u64 = 0;
    const start_ns = nanoTimestamp();
    var i: usize = 0;
    while (i < N_OPS) : (i += 1) {
        const id = try eng.allocNode();
        try eng.putNode(id, emptyNode(1));
        if (prev != 0) _ = try eng.addEdge(prev, id, 1);
        prev = id;
    }
    const end_ns = nanoTimestamp();

    const diff: i96 = end_ns - start_ns;
    return if (diff > 0) @intCast(diff) else 1;
}
