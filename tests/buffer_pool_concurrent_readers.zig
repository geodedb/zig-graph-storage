// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Concurrent readers over a store far larger than the buffer pool (SONNY-6438).
//
// Every read is a pin: most hit the lock-free fast path of BufferPool.pin
// while other readers miss, evict a frame and publish a new page into the
// page table under the pool mutex. This is the shape of geode's parallel
// UNION arms, whose ThreadSanitizer run reported the fast path's page-table
// lookup racing the slow path's insert. Each reader checks every node and
// property it reads, so a pin that hands back the wrong frame (or a frame
// recycled under it) fails the test, and the TSan step
// (`test-buffer-pool-concurrent-readers-tsan`) must report no race.
//
// Run:
//   zig build test-buffer-pool-concurrent-readers -Doptimize=ReleaseSafe
//   zig build test-buffer-pool-concurrent-readers-tsan

const std = @import("std");
const builtin = @import("builtin");
const gs = @import("graph_storage");

const testing = std.testing;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const THREADS: usize = 8;
const NODES: usize = 3000;
/// ThreadSanitizer slows every access ~10x; it needs coverage of the
/// interleavings, not volume.
const READS_PER_THREAD: usize = if (builtin.sanitize_thread) 3_000 else 50_000;

const Shared = struct {
    eng: *GraphEngine,
    ids: []const u64,
    failures: std.atomic.Value(u32) = .init(0),
};

fn fail(sh: *Shared, k: usize, what: []const u8, detail: anytype) void {
    const n = sh.failures.fetchAdd(1, .monotonic);
    if (n < 8) std.debug.print("reader: node #{d} (id {d}): {s} {any}\n", .{ k, sh.ids[k], what, detail });
}

fn reader(sh: *Shared, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..READS_PER_THREAD) |_| {
        const k = r.uintLessThan(usize, sh.ids.len);
        const maybe = sh.eng.getNode(sh.ids[k]) catch |err| {
            fail(sh, k, "getNode failed:", err);
            continue;
        };
        const rec = maybe orelse {
            fail(sh, k, "getNode returned no node", {});
            continue;
        };
        if (rec.txn_stamp != k + 1) {
            fail(sh, k, "wrong record, txn_stamp:", rec.txn_stamp);
            continue;
        }
        const got = sh.eng.getPropertyNoDerived(rec.prop_head, "i", testing.allocator) catch |err| {
            fail(sh, k, "getProperty failed:", err);
            continue;
        };
        const v = got orelse {
            fail(sh, k, "property 'i' missing, prop_head:", rec.prop_head);
            continue;
        };
        switch (v) {
            .int => |x| if (x != @as(i64, @intCast(k))) fail(sh, k, "wrong property value:", x),
            else => fail(sh, k, "property 'i' has the wrong type", {}),
        }
    }
}

fn run(key: ?[32]u8) !void {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x6c} ** 16;
    const cfg: gs.GraphConfig = .{
        .page_size = 4096,
        // Far below the store (~36 node pages plus property pages), so readers
        // miss and evict constantly, yet above THREADS x the 2 pins a property
        // read can hold: a smaller pool legitimately answers BufferPoolFull.
        .buffer_pool_pages = 3 * THREADS,
        .buffer_pool_auto_size = false,
        .encryption_key = key,
        .sync_mode = .deferred,
        .data_dir = "data",
    };

    const ids = try alloc.alloc(u64, NODES);
    defer alloc.free(ids);
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (ids, 0..) |*id, k| {
            id.* = try eng.allocNode();
            try eng.putNode(id.*, test_support.emptyNode(k + 1));
            var rec = (try eng.getNode(id.*)).?;
            rec.prop_head = try eng.putProperty(rec.prop_head, "i", .{ .int = @intCast(k) });
            try eng.putNode(id.*, rec);
        }
        try eng.checkpoint();
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    var sh = Shared{ .eng = eng, .ids = ids };
    var threads: [THREADS]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    while (spawned < THREADS) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, reader, .{ &sh, 0x6438 + spawned });
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;

    try testing.expectEqual(@as(u32, 0), sh.failures.load(.monotonic));
    // The pool really was too small: readers missed and evicted constantly.
    try testing.expect(eng.metrics.buffer_misses > THREADS * READS_PER_THREAD / 4);
}

test "concurrent readers over a store larger than the pool read every node and property correctly" {
    try run(null);
}

test "concurrent readers over an encrypted store larger than the pool read every node and property correctly" {
    try run([_]u8{0x6c} ** 32);
}
