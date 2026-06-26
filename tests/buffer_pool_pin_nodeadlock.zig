// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// FIX #2 of the edge-ingest wedge: BufferPool.pin must NEVER deadlock under high
// concurrency when the working set vastly exceeds the pool.
//
// THE PRODUCTION WEDGE (geode 14.27M edge ingest): gdb showed all 16 server
// handler threads parked in
//   ...getProperty -> PageChainCursor.next -> BufferPool.pin -> Io.Condition.waitUncancelable
// (buffer_pool.zig:403/420) waiting for a free/evictable frame that never comes.
// The engine buffer pool is ~512MB (65536 pages / 16 shards); at 14.27M the
// property-page working set vastly exceeds it, and 16 concurrent workers
// resolving endpoints (each walking a property-page CHAIN, i.e. pinning a
// SEQUENCE of distinct pages) exhaust frames -> the pin slow path waits
// Uncancelable forever. "Restart pod to recover."
//
// These tests reproduce that mechanism at the BufferPool layer directly:
//   * a SMALL pool (few frames)
//   * MANY concurrent threads (>> frames)
//   * each thread walking a CHAIN of distinct pages over a working set far
//     larger than the pool (so eviction is constant and every walk both evicts
//     and is a candidate eviction victim for others)
//   * a watchdog that turns the HANG manifestation into a deterministic RED
//     failure (and protects the suite from hanging forever).
//
// They also stress the EDGE-APPLY shape: a thread that holds ONE pin while
// pinning a SECOND page (the composite write pattern) to prove the slow path
// does not hold-and-wait deadlock.
//
// Run repeatedly to shake the window:
//   zig build test-pin-nodeadlock -Doptimize=ReleaseSafe
//   zig build test-pin-nodeadlock -Doptimize=ReleaseFast

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

/// Write a valid (checksummed) page with a known body pattern so a pin miss
/// reads back clean, CRC-valid data.
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
    chain_len: u32,
    iters: u64,
    started: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    n_threads: u32,
    failure: std.atomic.Value(u32), // 0 = ok
    // PERF: total successful pin operations, to confirm forward progress.
    pins: std.atomic.Value(u64),
};

fn barrier(sh: *Shared) void {
    _ = sh.started.fetchAdd(1, .acq_rel);
    while (sh.started.load(.acquire) < sh.n_threads) std.atomic.spinLoopHint();
}

/// CHAIN-WALK worker: models PageChainCursor / getProperty endpoint resolution.
/// Each "walk" pins a SEQUENCE of `chain_len` distinct pages starting at a
/// random offset, unpinning each before pinning the next (one pin at a time,
/// exactly like PageChainCursor.next). With many threads and a working set far
/// larger than the pool, this drives constant eviction; if pin can lose a wakeup
/// or starve, the threads park forever and the watchdog fires.
fn chainWalkLoop(sh: *Shared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    barrier(sh);
    var done_pins: u64 = 0;
    var i: u64 = 0;
    while (i < sh.iters) : (i += 1) {
        const start: u32 = r.intRangeLessThan(u32, 0, sh.n_pages);
        var hop: u32 = 0;
        while (hop < sh.chain_len) : (hop += 1) {
            const page: PageId = (start + hop) % sh.n_pages;
            const frame = sh.pool.pin(.nodes, page) catch |err| switch (err) {
                // BufferPoolFull is a legitimate transient outcome when every
                // frame is momentarily pinned/claimed by other workers. The
                // caller must be able to RETRY and eventually make progress.
                // (A wedge manifests as parking in pin, NOT as BufferPoolFull.)
                error.BufferPoolFull => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                else => |e| {
                    std.debug.print("\nchainWalk pin error: {s}\n", .{@errorName(e)});
                    sh.failure.store(2, .monotonic);
                    _ = sh.done.fetchAdd(1, .acq_rel);
                    return;
                },
            };
            if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
            const b = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE];
            std.mem.doNotOptimizeAway(b);
            sh.pool.unpin(sh.pool.frameIndex(frame), false);
            done_pins += 1;
        }
    }
    _ = sh.pins.fetchAdd(done_pins, .acq_rel);
    _ = sh.done.fetchAdd(1, .acq_rel);
}

/// HOLD-TWO worker: models the EDGE-APPLY composite write, which pins a second
/// page while still holding the first (out-adj + node, in-adj + in-dir). Proves
/// the slow path does not hold-and-wait deadlock when steady-state pinned frames
/// per worker is > 1.
fn holdTwoLoop(sh: *Shared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    barrier(sh);
    var done_pins: u64 = 0;
    var i: u64 = 0;
    while (i < sh.iters) : (i += 1) {
        const a: PageId = r.intRangeLessThan(u32, 0, sh.n_pages);
        const f1 = sh.pool.pin(.nodes, a) catch |err| switch (err) {
            error.BufferPoolFull => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => {
                sh.failure.store(2, .monotonic);
                _ = sh.done.fetchAdd(1, .acq_rel);
                return;
            },
        };
        // While holding f1, pin a DIFFERENT page. With a tiny pool this is the
        // exact hold-and-wait shape: the second pin may need to evict, and the
        // only frames left could be the ones other hold-two threads are holding.
        const b: PageId = (a + 1 + r.intRangeLessThan(u32, 0, sh.n_pages - 1)) % sh.n_pages;
        const f2 = sh.pool.pin(.nodes, b) catch |err| switch (err) {
            error.BufferPoolFull => {
                // Release the first pin and retry the whole pair: a correct
                // caller avoids hold-and-wait by not blocking while holding f1.
                sh.pool.unpin(sh.pool.frameIndex(f1), false);
                std.atomic.spinLoopHint();
                continue;
            },
            else => {
                sh.pool.unpin(sh.pool.frameIndex(f1), false);
                sh.failure.store(2, .monotonic);
                _ = sh.done.fetchAdd(1, .acq_rel);
                return;
            },
        };
        if (!f1.valid or !f2.valid) sh.failure.store(3, .monotonic);
        sh.pool.unpin(sh.pool.frameIndex(f2), true); // dirty: force flush-on-evict
        sh.pool.unpin(sh.pool.frameIndex(f1), true);
        done_pins += 2;
    }
    _ = sh.pins.fetchAdd(done_pins, .acq_rel);
    _ = sh.done.fetchAdd(1, .acq_rel);
}

/// Watchdog: converts a HANG (parked-forever pin) into a deterministic RED
/// failure. The fixed code finishes every worker well within the deadline, so a
/// timeout means "wedged", never "slow". Parked threads cannot observe a
/// cooperative stop and thread.join() would block forever, so the watchdog
/// FORCE-TERMINATES the process with a non-zero exit on timeout.
fn watchdogLoop(sh: *Shared, deadline_ms: u64) void {
    const step_ms: u64 = 50;
    var waited: u64 = 0;
    var last_pins: u64 = 0;
    var stalls: u32 = 0;
    while (waited < deadline_ms) {
        if (sh.done.load(.acquire) >= sh.n_threads) return; // all finished cleanly
        std.Io.Threaded.global_single_threaded.io().sleep(
            std.Io.Duration.fromMilliseconds(step_ms),
            .awake,
        ) catch {};
        waited += step_ms;
        // Liveness diagnostic: if pins stop advancing for a long stretch while
        // workers are unfinished, that IS the wedge — report it explicitly.
        const now_pins = sh.pins.load(.acquire);
        if (now_pins == last_pins) stalls += 1 else stalls = 0;
        last_pins = now_pins;
    }
    std.debug.print(
        "\nPIN-NODEADLOCK WATCHDOG: pool wedged after {d}ms ({d}/{d} workers finished, " ++
            "{d} pins, {d} consecutive stalls). pin() lost a wakeup or starved. FAILING.\n",
        .{ deadline_ms, sh.done.load(.acquire), sh.n_threads, last_pins, stalls },
    );
    std.process.exit(1);
}

const WorkerKind = enum { chain, hold_two };

fn runStress(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    pool_frames: u32,
    n_pages: u32,
    chain_len: u32,
    n_threads: u32,
    iters: u64,
    kind: WorkerKind,
    watchdog_ms: u64,
) !void {
    const file = try createTempFile(file_name);
    defer cleanupTempFile(file, file_name);

    var pager = Pager.init(file, PAGE_SIZE);
    var pg: PageId = 0;
    while (pg < n_pages) : (pg += 1) try writeTestPage(&pager, pg, @intCast(0x40 + (pg & 0x3f)));

    var pool = try BufferPool.init(allocator, PAGE_SIZE, pool_frames);
    defer pool.deinit();
    pool.registerPager(.nodes, &pager);

    var sh = Shared{
        .pool = &pool,
        .n_pages = n_pages,
        .chain_len = chain_len,
        .iters = iters,
        .started = std.atomic.Value(u32).init(0),
        .done = std.atomic.Value(u32).init(0),
        .n_threads = n_threads,
        .failure = std.atomic.Value(u32).init(0),
        .pins = std.atomic.Value(u64).init(0),
    };

    const threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);

    for (threads, 0..) |*t, k| {
        const seed = 0xC0DE_0000 + @as(u64, k);
        t.* = switch (kind) {
            .chain => try std.Thread.spawn(.{}, chainWalkLoop, .{ &sh, seed }),
            .hold_two => try std.Thread.spawn(.{}, holdTwoLoop, .{ &sh, seed }),
        };
    }
    const wd = try std.Thread.spawn(.{}, watchdogLoop, .{ &sh, watchdog_ms });

    for (threads) |th| th.join();
    wd.join();

    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));

    // Post-conditions: every frame unpinned, none transient, resident_counts in
    // lockstep with the page table (no leaked pin / no double-free).
    for (pool.frames) |*frame| {
        try std.testing.expectEqual(@as(u32, 0), frame.pin_count);
        try std.testing.expect(!frame.loading);
        try std.testing.expect(!frame.evicting);
    }
    try std.testing.expectEqual(
        @as(u32, @intCast(pool.page_table.count())),
        pool.resident_counts[@intFromEnum(graph_storage.FileId.nodes)],
    );
}

// ===========================================================================
// The wedge repro: tiny pool, working set >> pool, MANY chain-walking threads.
// ===========================================================================

test "pin-nodeadlock: many chain-walkers over a working set far exceeding the pool" {
    const allocator = std.testing.allocator;
    // 8 frames; 4096 distinct pages (working set 512x the pool); 32 threads each
    // walking 16-page chains. Mirrors 16+ endpoint resolvers walking property
    // chains when the dataset massively exceeds the 512MB engine pool.
    try runStress(allocator, ".test_bp_nodl_chain", 8, 4096, 16, 32, 4_000, .chain, 60_000);
}

test "pin-nodeadlock: extreme over-subscription (threads >> frames) chain walk" {
    const allocator = std.testing.allocator;
    // 4 frames, 48 threads: 12x more concurrent pinners than frames, so at any
    // instant the pinned set can equal the pool and eviction is forced under
    // maximal contention. The single most likely shape to expose a lost wakeup.
    try runStress(allocator, ".test_bp_nodl_oversub", 4, 2048, 24, 48, 3_000, .chain, 60_000);
}

test "pin-nodeadlock: edge-apply hold-two shape does not hold-and-wait deadlock" {
    const allocator = std.testing.allocator;
    // 6 frames, 32 threads each holding ONE pin while acquiring a SECOND over a
    // 1024-page working set. Models the composite edge write (out-adj+node,
    // in-adj+in-dir). Dirty unpins force the mutex-dropping flush window.
    try runStress(allocator, ".test_bp_nodl_holdtwo", 6, 1024, 0, 32, 3_000, .hold_two, 60_000);
}

test "pin-nodeadlock: HOT pages + tiny pool maximise loading/evicting cond pile-up" {
    const allocator = std.testing.allocator;
    // 3 frames over only 6 HOT pages, 48 threads: every thread targets the same
    // tiny set, so when one frame is loading/evicting MANY threads pile onto its
    // cond var simultaneously — the exact shape where a single lost wakeup parks
    // a whole crowd forever. chain_len 4 keeps each thread cycling fast.
    try runStress(allocator, ".test_bp_nodl_hot", 3, 6, 4, 48, 5_000, .chain, 60_000);
}

// ===========================================================================
// Reserved-floor + concurrent-flush variant: the production engine reserves
// capacity/4 frames for .nodes and runs background checkpoints (flushAll) while
// readers pin. Multiple file classes compete for the non-reserved frames.
// ===========================================================================

const ResShared = struct {
    pool: *BufferPool,
    n_pages: u32,
    iters: u64,
    started: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    n_threads: u32, // workers only (not the flusher/watchdog)
    failure: std.atomic.Value(u32),
    pins: std.atomic.Value(u64),
    stop_flush: std.atomic.Value(bool),
};

fn resBarrier(sh: *ResShared) void {
    _ = sh.started.fetchAdd(1, .acq_rel);
    while (sh.started.load(.acquire) < sh.n_threads) std.atomic.spinLoopHint();
}

/// Worker that walks BOTH a node-class chain and a props-class chain (two file
/// classes competing for frames), dirtying as it goes so the flusher and evictor
/// both have work. file_id alternates by thread parity.
fn resWorker(sh: *ResShared, seed: u64, use_props: bool) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const fid: graph_storage.FileId = if (use_props) .props else .nodes;
    resBarrier(sh);
    var done_pins: u64 = 0;
    var i: u64 = 0;
    while (i < sh.iters) : (i += 1) {
        const start: u32 = r.intRangeLessThan(u32, 0, sh.n_pages);
        var hop: u32 = 0;
        while (hop < 8) : (hop += 1) {
            const page: PageId = (start + hop) % sh.n_pages;
            const frame = sh.pool.pin(fid, page) catch |err| switch (err) {
                error.BufferPoolFull => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                else => {
                    sh.failure.store(2, .monotonic);
                    _ = sh.done.fetchAdd(1, .acq_rel);
                    return;
                },
            };
            if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
            const b = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE];
            std.mem.doNotOptimizeAway(b);
            // Dirty every few pins to feed the flusher + dirty-eviction window.
            const dirty = (page & 3) == 0;
            if (dirty) @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], @intCast(0x40 + (page & 0x3f)));
            sh.pool.unpin(sh.pool.frameIndex(frame), dirty);
            done_pins += 1;
        }
    }
    _ = sh.pins.fetchAdd(done_pins, .acq_rel);
    _ = sh.done.fetchAdd(1, .acq_rel);
}

/// Background flusher: hammers flushAll concurrently with the readers, modelling
/// the checkpointer. Stops when told.
fn flusherLoop(sh: *ResShared) void {
    while (!sh.stop_flush.load(.acquire)) {
        sh.pool.flushAll() catch {};
        std.Io.Threaded.global_single_threaded.io().sleep(
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        ) catch {};
    }
}

fn resWatchdog(sh: *ResShared, deadline_ms: u64) void {
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
        "\nPIN-NODEADLOCK RES WATCHDOG: pool wedged after {d}ms ({d}/{d} done, {d} pins). FAILING.\n",
        .{ deadline_ms, sh.done.load(.acquire), sh.n_threads, sh.pins.load(.acquire) },
    );
    std.process.exit(1);
}

test "pin-nodeadlock: reserved floor + two file classes + concurrent flush" {
    const allocator = std.testing.allocator;

    const pool_frames: u32 = 8;
    const n_pages: u32 = 512; // working set >> pool, per class
    const n_threads: u32 = 32;
    const iters: u64 = 3_000;
    const watchdog_ms: u64 = 60_000;

    const node_file = try createTempFile(".test_bp_nodl_res_nodes");
    defer cleanupTempFile(node_file, ".test_bp_nodl_res_nodes");
    const prop_file = try createTempFile(".test_bp_nodl_res_props");
    defer cleanupTempFile(prop_file, ".test_bp_nodl_res_props");

    var node_pager = Pager.init(node_file, PAGE_SIZE);
    var prop_pager = Pager.init(prop_file, PAGE_SIZE);
    var pg: PageId = 0;
    while (pg < n_pages) : (pg += 1) {
        try writeTestPage(&node_pager, pg, @intCast(0x40 + (pg & 0x3f)));
        try writeTestPage(&prop_pager, pg, @intCast(0x80 + (pg & 0x3f)));
    }

    var pool = try BufferPool.init(allocator, PAGE_SIZE, pool_frames);
    defer pool.deinit();
    pool.registerPager(.nodes, &node_pager);
    pool.registerPager(.props, &prop_pager);
    // Mirror the engine: reserve a quarter of the pool for .nodes.
    pool.setReservedFrames(.nodes, pool_frames / 4);

    var sh = ResShared{
        .pool = &pool,
        .n_pages = n_pages,
        .iters = iters,
        .started = std.atomic.Value(u32).init(0),
        .done = std.atomic.Value(u32).init(0),
        .n_threads = n_threads,
        .failure = std.atomic.Value(u32).init(0),
        .pins = std.atomic.Value(u64).init(0),
        .stop_flush = std.atomic.Value(bool).init(false),
    };

    const threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);
    for (threads, 0..) |*t, k| {
        // Even threads pin .nodes, odd threads pin .props.
        t.* = try std.Thread.spawn(.{}, resWorker, .{ &sh, 0xBEEF_0000 + @as(u64, k), (k & 1) == 1 });
    }
    const flusher = try std.Thread.spawn(.{}, flusherLoop, .{&sh});
    const wd = try std.Thread.spawn(.{}, resWatchdog, .{ &sh, watchdog_ms });

    for (threads) |th| th.join();
    sh.stop_flush.store(true, .release);
    flusher.join();
    wd.join();

    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));

    for (pool.frames) |*frame| {
        try std.testing.expectEqual(@as(u32, 0), frame.pin_count);
        try std.testing.expect(!frame.loading);
        try std.testing.expect(!frame.evicting);
    }
    const resident_total = pool.resident_counts[@intFromEnum(graph_storage.FileId.nodes)] +
        pool.resident_counts[@intFromEnum(graph_storage.FileId.props)];
    try std.testing.expectEqual(@as(u32, @intCast(pool.page_table.count())), resident_total);
}

// ===========================================================================
// LOST-WAKEUP self-heal: the pin loading/evicting wait must make bounded
// progress even if a state transition that should have woken it DROPS the
// wakeup. This is the robustness guarantee FIX #2 provides: pin can NEVER
// sleep forever waiting on a wakeup that may never fire.
//
// We deliberately induce a lost wakeup: a frame is published `loading`, a
// helper thread later flips it to valid/resident WITHOUT signalling the pool's
// frame-wait (simulating any path — present or future — that frees/loads a
// frame but fails to wake the parked pinner). On the pristine code the pinner
// waits Uncancelable forever (watchdog FAILS = RED). With the bounded timed-
// wait re-check the pinner wakes on its own, re-evaluates the now-valid frame,
// and pins it (GREEN).
// ===========================================================================

const LostWakeShared = struct {
    pool: *BufferPool,
    reserved_idx: u32,
    pinned: std.atomic.Value(bool),
    failure: std.atomic.Value(u32),
    flipped: std.atomic.Value(bool),
};

fn lostWakePinner(sh: *LostWakeShared) void {
    // This pin finds page 7 in the table but `loading` -> parks in the slow-path
    // frame wait. It must eventually return WITHOUT anyone waking it.
    const frame = sh.pool.pin(.nodes, 7) catch {
        sh.failure.store(2, .monotonic);
        return;
    };
    if (!frame.valid or frame.pin_count == 0) sh.failure.store(3, .monotonic);
    sh.pinned.store(true, .release);
    sh.pool.unpin(sh.pool.frameIndex(frame), false);
}

fn lostWakeFlipper(sh: *LostWakeShared) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    // Give the pinner time to park in the frame wait.
    io.sleep(std.Io.Duration.fromMilliseconds(60), .awake) catch {};
    // Flip the frame to resident/valid under the mutex but DO NOT wake: this is
    // the dropped wakeup. (Mirrors a load/evict completing without signalling
    // the parked waiter.)
    sh.pool.mutex.lockUncancelable(io);
    sh.pool.frames[sh.reserved_idx].loading = false;
    sh.pool.frames[sh.reserved_idx].valid = true;
    // The notional loader also drops its pin (load complete); model that so the
    // pinner's pin/unpin returns the frame to 0.
    sh.pool.frames[sh.reserved_idx].pin_count = 0;
    sh.pool.mutex.unlock(io);
    sh.flipped.store(true, .release);
    // Intentionally NO wake here (no wakeFrameWaiters): the dropped-wakeup case.
}

fn lostWakeWatchdog(sh: *LostWakeShared, deadline_ms: u64) void {
    const step_ms: u64 = 50;
    var waited: u64 = 0;
    while (waited < deadline_ms) {
        if (sh.pinned.load(.acquire)) return;
        std.Io.Threaded.global_single_threaded.io().sleep(
            std.Io.Duration.fromMilliseconds(step_ms),
            .awake,
        ) catch {};
        waited += step_ms;
    }
    std.debug.print(
        "\nLOST-WAKEUP WATCHDOG: pin parked {d}ms after the frame became valid " ++
            "(flipped={}) with no broadcast — pin slept on a lost wakeup. FAILING.\n",
        .{ deadline_ms, sh.flipped.load(.acquire) },
    );
    std.process.exit(1);
}

test "pin-nodeadlock: pin self-heals from a DROPPED wakeup on a loading frame" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, PAGE_SIZE, 2);
    defer pool.deinit();

    // Publish page 7 into the table as `loading` (as the slow-path load would),
    // pinned once by a notional loader, so a concurrent pin(7) parks on the cond.
    const reserved = pool.free_list.pop() orelse unreachable;
    pool.frames[reserved].file_id = .nodes;
    pool.frames[reserved].page_id = 7;
    pool.frames[reserved].pin_count = 1;
    pool.frames[reserved].dirty = false;
    pool.frames[reserved].loading = true;
    pool.frames[reserved].valid = false;
    try pool.page_table.put(.{ .file_id = .nodes, .page_id = 7 }, reserved);

    var sh = LostWakeShared{
        .pool = &pool,
        .reserved_idx = reserved,
        .pinned = std.atomic.Value(bool).init(false),
        .failure = std.atomic.Value(u32).init(0),
        .flipped = std.atomic.Value(bool).init(false),
    };

    const pinner = try std.Thread.spawn(.{}, lostWakePinner, .{&sh});
    const flipper = try std.Thread.spawn(.{}, lostWakeFlipper, .{&sh});
    const wd = try std.Thread.spawn(.{}, lostWakeWatchdog, .{ &sh, 30_000 });

    pinner.join();
    flipper.join();
    wd.join();

    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));
    try std.testing.expect(sh.pinned.load(.acquire));
    // The notional loader's pin (1) + the pinner's transient pin were both
    // released; frame must end unpinned and resident.
    try std.testing.expectEqual(@as(u32, 0), pool.frames[reserved].pin_count);
}

test {
    std.testing.refAllDecls(@This());
}
