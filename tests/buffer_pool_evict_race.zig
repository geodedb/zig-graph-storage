// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// Concurrency regression for the buffer-pool dirty-eviction race.
//
// THE BUG (pristine v0.2.5): BufferPool.evictFrame flushes a DIRTY victim to
// disk via flushFrame, which DROPS the pool mutex across the blocking write.
// While the mutex is dropped the victim frame is still in the page table, so a
// concurrent pin() of the SAME page finds it, increments its pin_count, and
// returns it to a reader. When the flush completes, evictFrame repurposes the
// frame for a DIFFERENT page (resetting pin_count to 0 / valid to false). The
// reader is now holding an aliased, repurposed frame, and the bookkeeping is
// corrupt: a later unpin() trips `std.debug.assert(frame.pin_count > 0)` (an
// ABORT under Debug / ReleaseSafe), or the leaked pin/loading state wedges the
// pool so every pin() blocks forever (a HANG). Either outcome is the race.
//
// These tests force constant dirty eviction with a tiny pool whose victims are
// kept dirty by writer threads, while many reader/writer threads pin the SAME
// hot pages (maximising the odds a pin aliases the in-flight eviction). A
// watchdog thread converts the HANG manifestation into a deterministic test
// failure (and protects the suite from hanging). On pristine v0.2.5 the test
// aborts or trips the watchdog; with the evicting-guard fix it completes with
// all invariants intact.
//
// Run repeatedly to shake the window:
//   zig build test-evict-race -Doptimize=ReleaseSafe
//   zig build test-evict-race -Doptimize=Debug

const std = @import("std");
const graph_storage = @import("graph_storage");

const BufferPool = graph_storage.buffer_pool.BufferPool;
const Pager = graph_storage.pager.Pager;
const page_mod = graph_storage.page;
const PageId = graph_storage.PageId;

const PAGE_SIZE: u32 = 4096;

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

/// Write a valid (checksummed) page with a known body pattern so the pager's
/// readPage on a later miss does not fail the CRC check.
fn writeTestPage(p: *Pager, page_id: PageId, pattern: u8) !void {
    var buf: [PAGE_SIZE]u8 = undefined;
    @memset(&buf, 0);
    const header = page_mod.initHeader(page_id, .node_data, PAGE_SIZE);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], header_bytes);
    @memset(buf[page_mod.PAGE_HEADER_SIZE..], pattern);
    try p.writePage(page_id, &buf);
}

const Shared = struct {
    pool: *BufferPool,
    n_pages: u32,
    iters: u64,
    stop: std.atomic.Value(bool),
    started: std.atomic.Value(u32),
    done: std.atomic.Value(u32), // workers that finished their loop
    n_threads: u32,
    failure: std.atomic.Value(u32), // 0 = ok, nonzero = invariant/watchdog failure
};

fn waitForStart(sh: *Shared) void {
    _ = sh.started.fetchAdd(1, .acq_rel);
    // Spin until every worker is live so the race window is hammered by all
    // threads simultaneously, not serially.
    while (sh.started.load(.acquire) < sh.n_threads) {
        std.atomic.spinLoopHint();
    }
}

/// Reader: pin a random page, read a byte (touch the data), unpin clean.
fn readerLoop(sh: *Shared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    waitForStart(sh);
    var i: u64 = 0;
    while (i < sh.iters and !sh.stop.load(.monotonic)) : (i += 1) {
        const page: PageId = r.intRangeLessThan(u32, 0, sh.n_pages);
        const frame = sh.pool.pin(.nodes, page) catch |err| switch (err) {
            // BufferPoolFull is a legitimate transient outcome when every frame
            // is momentarily pinned by other workers; just retry.
            error.BufferPoolFull => continue,
            else => {
                sh.failure.store(2, .monotonic);
                break;
            },
        };
        // Invariant: a freshly pinned frame must be valid and have pin_count>=1.
        // A repurposed/aliased frame violates this.
        if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
        const b = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE];
        std.mem.doNotOptimizeAway(b);
        const idx = sh.pool.frameIndex(frame);
        sh.pool.unpin(idx, false);
    }
    _ = sh.done.fetchAdd(1, .acq_rel);
}

/// Writer: pin a random page, dirty it, unpin dirty -> guarantees the victim of
/// a later eviction is DIRTY, which is the only path that drops the mutex.
fn writerLoop(sh: *Shared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    waitForStart(sh);
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
        const idx = sh.pool.frameIndex(frame);
        sh.pool.unpin(idx, true); // dirty
    }
    _ = sh.done.fetchAdd(1, .acq_rel);
}

/// Watchdog: if the workers do not all finish within the deadline, the pool has
/// wedged. The aliasing bug corrupts pin_count/loading bookkeeping, which on
/// pristine v0.2.5 leaves worker threads parked forever in
/// `cond.waitUncancelable` (a leaked `loading` flag is never cleared / the wake
/// is lost). Parked threads cannot observe a cooperative `stop` flag, and the
/// driver's `thread.join()` would then block forever — so a cooperative stop is
/// not enough to unwedge the process. The watchdog therefore FORCE-TERMINATES
/// the test process with a non-zero exit once the deadline passes: that turns
/// the HANG manifestation of the race into a deterministic RED failure that
/// always exits (and can never wedge the whole test suite).
///
/// The fixed code completes every worker well within the deadline, so the
/// watchdog returns normally and the test passes (GREEN). The deadline is
/// generous relative to the real workload (tens of ms) precisely so a timeout
/// means "wedged", never "slow".
fn watchdogLoop(sh: *Shared, deadline_ms: u64) void {
    const step_ms: u64 = 50;
    var waited: u64 = 0;
    while (waited < deadline_ms) {
        if (sh.done.load(.acquire) >= sh.n_threads) return; // all finished cleanly
        std.Io.Threaded.global_single_threaded.io().sleep(
            std.Io.Duration.fromMilliseconds(step_ms),
            .awake,
        ) catch {};
        waited += step_ms;
    }
    // Deadline exceeded: the pool is wedged (lost-wakeup from the aliasing bug).
    std.debug.print(
        "\nEVICT-RACE WATCHDOG: pool wedged after {d}ms ({d}/{d} workers finished) " ++
            "-- dirty-eviction aliasing race (lost wakeup). FAILING.\n",
        .{ deadline_ms, sh.done.load(.acquire), sh.n_threads },
    );
    std.process.exit(1);
}

/// Core driver: a tiny pool + few HOT pages + N readers + M writers, sustained,
/// with a watchdog. On pristine v0.2.5 this aborts or trips the watchdog; with
/// the fix it completes cleanly.
fn runStress(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    pool_frames: u32,
    n_pages: u32,
    n_readers: u32,
    n_writers: u32,
    iters: u64,
    watchdog_ms: u64,
) !void {
    const file = try createTempFile(file_name);
    defer cleanupTempFile(file, file_name);

    var pager = Pager.init(file, PAGE_SIZE);

    // Pre-write every page so reads on a miss find valid, checksummed data.
    var pg: PageId = 0;
    while (pg < n_pages) : (pg += 1) {
        try writeTestPage(&pager, pg, @intCast(0x40 + (pg & 0x1f)));
    }

    var pool = try BufferPool.init(allocator, PAGE_SIZE, pool_frames);
    defer pool.deinit();
    pool.registerPager(.nodes, &pager);

    const n_threads = n_readers + n_writers;
    var sh = Shared{
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
    while (t < n_readers) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, readerLoop, .{ &sh, 0x1234_0000 + @as(u64, t) });
    }
    while (t < n_threads) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, writerLoop, .{ &sh, 0x9876_0000 + @as(u64, t) });
    }
    const wd = try std.Thread.spawn(.{}, watchdogLoop, .{ &sh, watchdog_ms });

    for (threads) |th| th.join();
    wd.join();

    // No invariant violation and no watchdog timeout must have occurred.
    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));

    // Post-conditions: pool accounting is self-consistent. Every frame is now
    // unpinned and no frame is left in a transient state. `@hasField` keeps this
    // file compilable against BOTH pristine v0.2.5 (no `evicting` field) and the
    // fixed source.
    const has_evicting = @hasField(@TypeOf(pool.frames[0]), "evicting");
    for (pool.frames) |*frame| {
        try std.testing.expectEqual(@as(u32, 0), frame.pin_count);
        try std.testing.expect(!frame.loading);
        if (has_evicting) try std.testing.expect(!@field(frame, "evicting"));
    }
    // resident_counts must equal the page_table size for the nodes class.
    try std.testing.expectEqual(
        @as(u32, @intCast(pool.page_table.count())),
        pool.resident_counts[@intFromEnum(graph_storage.FileId.nodes)],
    );
}

test "DIAG: large pool (no eviction) many threads completes" {
    const allocator = std.testing.allocator;
    // Pool >= pages => NO eviction ever. If this hangs, the harness threading
    // model is broken (not the eviction fix).
    try runStress(allocator, ".test_bp_diag_nopool", 64, 8, 12, 12, 50_000, 30_000);
}

test "DIAG: single page, cache-hit only, many threads completes" {
    const allocator = std.testing.allocator;
    // 1 page, pool of 4 => after first load every pin is a pure cache hit, no
    // eviction, no loading wait. If this hangs the cond/mutex are the problem.
    try runStress(allocator, ".test_bp_diag_onepage", 4, 1, 12, 12, 50_000, 30_000);
}

test "evict-race: tiny pool, hot pages, readers + writers, constant dirty eviction" {
    const allocator = std.testing.allocator;
    // 4 frames over 8 HOT pages: working set just over the pool so eviction is
    // constant AND many threads target the same handful of pages, so a pin
    // frequently lands on the page being evicted. Writers keep victims dirty.
    try runStress(allocator, ".test_bp_evict_race_a", 4, 8, 12, 12, 50_000, 30_000);
}

test "evict-race: minimal 2-frame pool maximises eviction churn" {
    const allocator = std.testing.allocator;
    // 2 frames over 4 hot pages: the LRU victim turns over on essentially every
    // pin, and with only 4 pages a concurrent pin very often targets the victim.
    try runStress(allocator, ".test_bp_evict_race_b", 2, 4, 16, 8, 50_000, 30_000);
}

test "evict-race: heavy writer skew keeps almost every victim dirty" {
    const allocator = std.testing.allocator;
    // Writer-dominant over a few hot pages: nearly every evicted frame is dirty
    // => the mutex-dropping flush window is taken on almost every eviction.
    try runStress(allocator, ".test_bp_evict_race_c", 3, 6, 4, 20, 50_000, 30_000);
}
