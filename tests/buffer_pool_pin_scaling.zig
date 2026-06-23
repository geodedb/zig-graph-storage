// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// Concurrency SCALING regression for the buffer-pool cache-HIT pin/unpin path.
//
// THE BOTTLENECK (pristine v0.2.6): BufferPool.pin and BufferPool.unpin take the
// pool-wide `self.mutex` on EVERY call -- including a pure cache HIT (page already
// resident: just bump/decrement pin_count and touch recency). Under many reader
// threads each doing getNode->pin+unpin on ONE shard's pool over a HOT working set
// that fits in the pool (so every pin is a hit, no eviction, no disk I/O), all
// readers serialize on that single mutex. Aggregate throughput (pins/sec) then does
// NOT scale with thread count -- it collapses to single-mutex-serialized throughput,
// which is exactly what starves the edge-ingest endpoint lookups under 48 concurrent
// analytical scanners at 14.27M scale.
//
// This file measures aggregate pins/sec for a HOT, fully-resident working set at
// 1 thread vs N threads and asserts the N-thread run delivers a real speedup over
// the serialized 1-thread baseline. On pristine v0.2.6 (mutex on every pin) the
// speedup is ~1x (contention-bound) and the threshold assertion FAILS (RED). With
// the shared-lock + atomic-pin_count fast path it scales and the assertion PASSES
// (GREEN).
//
// It also runs a mixed read + write + EVICTION stress (working set > pool) reusing
// the evict-race invariants, asserting no crash and self-consistent accounting --
// so the fast path cannot regress the v0.2.6 dirty-eviction race fix.
//
// Run:
//   zig build test-pin-scaling -Doptimize=ReleaseFast   (scaling signal is clean here)
//   zig build test-pin-scaling -Doptimize=ReleaseSafe   (invariants + asserts armed)

const std = @import("std");
const graph_storage = @import("graph_storage");

const BufferPool = graph_storage.buffer_pool.BufferPool;
const Pager = graph_storage.pager.Pager;
const page_mod = graph_storage.page;
const PageId = graph_storage.PageId;

const PAGE_SIZE: u32 = 4096;

// Zig 0.16 compat: std.time.Timer was removed; read the monotonic clock
// directly (same approach as benchmarks/bench.zig, but on the monotonic
// `.awake` clock so elapsed measurement is immune to wall-clock jumps).
fn nowNs() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn createTempFile(name: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), name, .{
        .read = true,
        .truncate = true,
    });
}

fn cleanupTempFile(file: std.Io.File, name: []const u8) void {
    file.close(std.Io.Threaded.global_single_threaded.io());
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), name) catch {};
}

/// Write a valid (checksummed) page so a pin miss reads back clean data.
fn writeTestPage(p: *Pager, page_id: PageId, pattern: u8) !void {
    var buf: [PAGE_SIZE]u8 = undefined;
    @memset(&buf, 0);
    const header = page_mod.initHeader(page_id, .node_data, PAGE_SIZE);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], header_bytes);
    @memset(buf[page_mod.PAGE_HEADER_SIZE..], pattern);
    try p.writePage(page_id, &buf);
}

// ===========================================================================
// HIT-path scaling harness
// ===========================================================================

const HitShared = struct {
    pool: *BufferPool,
    n_pages: u32,
    iters_per_thread: u64,
    started: std.atomic.Value(u32),
    n_threads: u32,
    go: std.atomic.Value(bool),
    failure: std.atomic.Value(u32), // 0 = ok
    total_pins: std.atomic.Value(u64),
};

fn hitBarrier(sh: *HitShared) void {
    _ = sh.started.fetchAdd(1, .acq_rel);
    while (sh.started.load(.acquire) < sh.n_threads) std.atomic.spinLoopHint();
    // Released together by the driver so all threads run concurrently.
    while (!sh.go.load(.acquire)) std.atomic.spinLoopHint();
}

/// Each worker hammers pin+unpin on a HOT working set that fits in the pool, so
/// every pin after warmup is a pure cache hit (no eviction, no disk I/O). This is
/// the path that must scale with threads instead of serializing on one mutex.
fn hitWorker(sh: *HitShared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    hitBarrier(sh);
    var i: u64 = 0;
    while (i < sh.iters_per_thread) : (i += 1) {
        const page: PageId = r.intRangeLessThan(u32, 0, sh.n_pages);
        const frame = sh.pool.pin(.nodes, page) catch {
            sh.failure.store(2, .monotonic);
            return;
        };
        // A freshly pinned resident frame must be valid with pin_count>=1.
        if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
        const b = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE];
        std.mem.doNotOptimizeAway(b);
        sh.pool.unpin(sh.pool.frameIndex(frame), false);
    }
    _ = sh.total_pins.fetchAdd(sh.iters_per_thread, .acq_rel);
}

/// Run `n_threads` workers over a hot resident working set and return ns elapsed
/// for the concurrent phase (barrier-released).
fn runHitPhase(
    allocator: std.mem.Allocator,
    pool: *BufferPool,
    n_pages: u32,
    n_threads: u32,
    iters_per_thread: u64,
) !u64 {
    var sh = HitShared{
        .pool = pool,
        .n_pages = n_pages,
        .iters_per_thread = iters_per_thread,
        .started = std.atomic.Value(u32).init(0),
        .n_threads = n_threads,
        .go = std.atomic.Value(bool).init(false),
        .failure = std.atomic.Value(u32).init(0),
        .total_pins = std.atomic.Value(u64).init(0),
    };

    const threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);

    for (threads, 0..) |*t, k| {
        t.* = try std.Thread.spawn(.{}, hitWorker, .{ &sh, 0xABCD_0000 + @as(u64, k) });
    }

    // Wait until every worker is parked on the `go` gate, then release + time.
    while (sh.started.load(.acquire) < n_threads) std.atomic.spinLoopHint();
    const t0 = nowNs();
    sh.go.store(true, .release);
    for (threads) |t| t.join();
    const t1 = nowNs();
    const elapsed: u64 = if (t1 > t0) @intCast(t1 - t0) else 0;

    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));
    return elapsed;
}

fn pinsPerSec(iters: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    return @as(f64, @floatFromInt(iters)) * 1_000_000_000.0 / @as(f64, @floatFromInt(ns));
}

test "PERF: cache-hit pin/unpin throughput scales with thread count" {
    const allocator = std.testing.allocator;

    // HOT working set that FITS in the pool => every pin is a pure cache hit (no
    // eviction, no disk I/O). The page count models the real workload: many
    // concurrent scanners doing O(N) getNode spread across a shard's resident
    // node pages (thousands), so two threads rarely hit the SAME page's
    // pin_count cacheline at the same instant. A too-small working set would
    // instead measure per-frame refcount cacheline ping-pong (inherent to ANY
    // atomic refcount), not the lock-contention this fix targets.
    const n_pages: u32 = 1024;
    const pool_frames: u32 = 2048;
    const iters_per_thread: u64 = 300_000;

    const file = try createTempFile(".test_bp_pin_scaling");
    defer cleanupTempFile(file, ".test_bp_pin_scaling");
    var pager = Pager.init(file, PAGE_SIZE);
    var pg: PageId = 0;
    while (pg < n_pages) : (pg += 1) try writeTestPage(&pager, pg, @intCast(0x40 + (pg & 0x3f)));

    var pool = try BufferPool.init(allocator, PAGE_SIZE, pool_frames);
    defer pool.deinit();
    pool.registerPager(.nodes, &pager);

    // Warm the whole working set resident (single-threaded) so the timed phase
    // is hits-only.
    pg = 0;
    while (pg < n_pages) : (pg += 1) {
        const f = try pool.pin(.nodes, pg);
        pool.unpin(pool.frameIndex(f), false);
    }

    const mid_threads: u32 = 8;
    const high_threads: u32 = 16;

    // Baseline: single-threaded throughput (no contention possible).
    const ns_1 = try runHitPhase(allocator, &pool, n_pages, 1, iters_per_thread);
    const tput_1 = pinsPerSec(iters_per_thread, ns_1);

    // Concurrent: many threads. With per-pin MUTEX serialization (pristine
    // v0.2.6) aggregate throughput does NOT grow with cores — it collapses to AT
    // OR BELOW the single-thread rate (the mutex + its shared cacheline ping-pong
    // make 16 cores slower than 1: measured ~0.06x). With the PERF-0058 lock-free
    // fast path concurrent hits proceed in parallel and aggregate throughput
    // scales WELL above the single-thread baseline.
    const ns_8 = try runHitPhase(allocator, &pool, n_pages, mid_threads, iters_per_thread);
    const tput_8 = pinsPerSec(iters_per_thread * mid_threads, ns_8);

    const ns_n = try runHitPhase(allocator, &pool, n_pages, high_threads, iters_per_thread);
    const tput_n = pinsPerSec(iters_per_thread * high_threads, ns_n);

    const speedup8 = tput_8 / tput_1;
    const speedup16 = tput_n / tput_1;
    std.debug.print(
        "\n[pin-scaling] 1t={d:.0} pins/s | {d}t={d:.0} ({d:.2}x) | {d}t={d:.0} ({d:.2}x)\n",
        .{ tput_1, mid_threads, tput_8, speedup8, high_threads, tput_n, speedup16 },
    );

    // A serialized (single-mutex) hit path cannot exceed its single-thread rate
    // no matter how many cores pile on (speedup <= ~1x, typically << 1x once
    // mutex contention is added). The lock-free fast path must clear a
    // conservative multiple of the baseline. 2.0x is far above the
    // contention-bound ceiling yet comfortably below what the fix delivers on
    // this working set, so it is a robust RED-on-pristine / GREEN-on-fixed
    // discriminator that is not flaky under CI core-count/scheduling variance.
    try std.testing.expect(speedup16 >= 2.0);
}

// ===========================================================================
// Mixed read+write+EVICTION stress: the fast path must not regress the
// v0.2.6 dirty-eviction race fix. (Working set > pool => constant eviction.)
// ===========================================================================

const MixShared = struct {
    pool: *BufferPool,
    n_pages: u32,
    iters: u64,
    stop: std.atomic.Value(bool),
    started: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    n_threads: u32,
    failure: std.atomic.Value(u32),
};

fn mixBarrier(sh: *MixShared) void {
    _ = sh.started.fetchAdd(1, .acq_rel);
    while (sh.started.load(.acquire) < sh.n_threads) std.atomic.spinLoopHint();
}

fn mixReader(sh: *MixShared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    mixBarrier(sh);
    var i: u64 = 0;
    while (i < sh.iters and !sh.stop.load(.monotonic)) : (i += 1) {
        const page: PageId = r.intRangeLessThan(u32, 0, sh.n_pages);
        const frame = sh.pool.pin(.nodes, page) catch |err| switch (err) {
            error.BufferPoolFull => continue,
            else => {
                sh.failure.store(2, .monotonic);
                break;
            },
        };
        if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
        const b = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE];
        std.mem.doNotOptimizeAway(b);
        sh.pool.unpin(sh.pool.frameIndex(frame), false);
    }
    _ = sh.done.fetchAdd(1, .acq_rel);
}

fn mixWriter(sh: *MixShared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    mixBarrier(sh);
    var i: u64 = 0;
    while (i < sh.iters and !sh.stop.load(.monotonic)) : (i += 1) {
        const page: PageId = r.intRangeLessThan(u32, 0, sh.n_pages);
        const frame = sh.pool.pin(.nodes, page) catch |err| switch (err) {
            error.BufferPoolFull => continue,
            else => {
                sh.failure.store(2, .monotonic);
                break;
            },
        };
        if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
        @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], @intCast(0x40 + (page & 0x1f)));
        sh.pool.unpin(sh.pool.frameIndex(frame), true); // dirty
    }
    _ = sh.done.fetchAdd(1, .acq_rel);
}

fn mixWatchdog(sh: *MixShared, deadline_ms: u64) void {
    const step_ms: u64 = 50;
    var waited: u64 = 0;
    while (waited < deadline_ms) {
        if (sh.done.load(.acquire) >= sh.n_threads) return;
        std.Io.Threaded.global_single_threaded.io().sleep(
            std.Io.Duration.fromMilliseconds(step_ms),
            .awake,
        ) catch {};
        waited += step_ms;
    }
    std.debug.print(
        "\nPIN-SCALING MIX WATCHDOG: pool wedged after {d}ms ({d}/{d} done). FAILING.\n",
        .{ deadline_ms, sh.done.load(.acquire), sh.n_threads },
    );
    std.process.exit(1);
}

test "PERF: fast path holds invariants under mixed read+write+eviction churn" {
    const allocator = std.testing.allocator;

    // 6 frames over 24 hot pages => constant eviction; writers keep victims dirty
    // so the mutex-dropping flush window (the v0.2.6 race window) is exercised on
    // almost every eviction while readers race pins against it.
    const n_pages: u32 = 24;
    const pool_frames: u32 = 6;
    const n_readers: u32 = 16;
    const n_writers: u32 = 8;
    const iters: u64 = 60_000;
    const watchdog_ms: u64 = 30_000;

    const file = try createTempFile(".test_bp_pin_scaling_mix");
    defer cleanupTempFile(file, ".test_bp_pin_scaling_mix");
    var pager = Pager.init(file, PAGE_SIZE);
    var pg: PageId = 0;
    while (pg < n_pages) : (pg += 1) try writeTestPage(&pager, pg, @intCast(0x40 + (pg & 0x1f)));

    var pool = try BufferPool.init(allocator, PAGE_SIZE, pool_frames);
    defer pool.deinit();
    pool.registerPager(.nodes, &pager);

    const n_threads = n_readers + n_writers;
    var sh = MixShared{
        .pool = &pool,
        .n_pages = n_pages,
        .iters = iters,
        .stop = std.atomic.Value(bool).init(false),
        .started = std.atomic.Value(u32).init(0),
        .done = std.atomic.Value(u32).init(0),
        .n_threads = n_threads,
        .failure = std.atomic.Value(u32).init(0),
    };

    const threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);

    var t: u32 = 0;
    while (t < n_readers) : (t += 1)
        threads[t] = try std.Thread.spawn(.{}, mixReader, .{ &sh, 0x1111_0000 + @as(u64, t) });
    while (t < n_threads) : (t += 1)
        threads[t] = try std.Thread.spawn(.{}, mixWriter, .{ &sh, 0x2222_0000 + @as(u64, t) });
    const wd = try std.Thread.spawn(.{}, mixWatchdog, .{ &sh, watchdog_ms });

    for (threads) |th| th.join();
    wd.join();

    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));

    // Post-conditions: every frame unpinned, none left transient, and
    // resident_counts in lockstep with the page table.
    const has_evicting = @hasField(@TypeOf(pool.frames[0]), "evicting");
    for (pool.frames) |*frame| {
        try std.testing.expectEqual(@as(u32, 0), frame.pin_count);
        try std.testing.expect(!frame.loading);
        if (has_evicting) try std.testing.expect(!@field(frame, "evicting"));
    }
    try std.testing.expectEqual(
        @as(u32, @intCast(pool.page_table.count())),
        pool.resident_counts[@intFromEnum(graph_storage.FileId.nodes)],
    );
}
