// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// GAP-0900 WAL-batch A/B microbenchmark.
//
// Drives the exact code path the deferred-WAL bulk-ingest profile flagged:
// many multi-page transactions in deferred sync mode, where each txn logs
// several page-update WAL records (a "19-prop node insert" touches the node
// page + one props page per property). Reports wall-clock ops/s.
//
// Run under `strace -c -f` to measure the WAL write-syscall count, which is
// the lever this change targets (per-record append -> one batched append per
// txn). Same binary is used for baseline vs. patched (the code path differs
// only by graph-storage's batching).
//
// Usage: wal-batch-ab [num_txns] [props_per_txn]

const std = @import("std");
const gs = @import("graph_storage");

// Zig 0.16 compat: Timer was removed; use the monotonic clock directly.
fn nanoNow() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const allocator = std.heap.page_allocator;

    const num_txns: usize = 2000;
    const props_per_txn: usize = 19;

    // Fresh temp data dir (GraphEngine.create makes the path).
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp_buf: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&tmp_buf, "/tmp/wal_batch_ab_{d}", .{nanoNow()});
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const uuid = [_]u8{0xAB} ** 16;
    var cfg = gs.GraphConfig{};
    cfg.sync_mode = .deferred; // deferred bulk-ingest mode (no per-commit fsync)

    const engine = try gs.GraphEngine.create(allocator, data_dir, uuid, cfg);
    defer engine.close() catch {};

    var key_buf: [32]u8 = undefined;

    const start = nanoNow();
    var t: usize = 0;
    while (t < num_txns) : (t += 1) {
        const txn = try engine.beginTxn();
        const node_id = try engine.allocNode();
        const rec = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 0,
        };
        try engine.putNodeTxn(node_id, rec, txn);

        var head: u64 = 0;
        var p: usize = 0;
        while (p < props_per_txn) : (p += 1) {
            const key = try std.fmt.bufPrint(&key_buf, "prop_{d}", .{p});
            head = try engine.putPropertyTxn(head, key, .{ .int = @intCast(t * 100 + p) }, txn);
        }
        try engine.commitTxn(txn);
    }
    const elapsed_ns: u64 = @intCast(nanoNow() - start);

    const ops: f64 = @floatFromInt(num_txns);
    const secs: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    std.debug.print(
        "wal-batch-ab: txns={d} props/txn={d} elapsed_ms={d:.1} txns/s={d:.0} pages/txn~={d}\n",
        .{ num_txns, props_per_txn, secs * 1000.0, ops / secs, props_per_txn + 1 },
    );
}
