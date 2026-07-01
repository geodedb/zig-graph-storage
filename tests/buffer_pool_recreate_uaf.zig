// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// GAP-ENT-0018 REPRODUCER: a property-predicate style query at scale SEGFAULTs
// the server. dmesg: `segfault ... error 4` (user-mode READ of an unmapped
// page); addr2line put the faulting IP inside
// `hash_map.HashMapUnmanaged(PageKey,u32).Metadata.isUsed` reached from
// `BufferPool.pin` — i.e. the lock-free page-table `get` dereferenced a
// page-table `metadata` base that had been freed/moved under it.
//
// This file has two independent reproducers:
//
//  1. `full-engine concurrent pins during first-access materialize` — the
//     FAITHFUL workload: reopen a graph whose derived indexes are DEFERRED
//     (early-ready), then hammer it from many threads. Some threads do pure
//     point `getNode` (the lock-free pin fast path); others call `getProperty`,
//     the FIRST of which triggers the O(graph) derived-index materialization
//     (a heavy `scanNodes` that pins+evicts constantly) while the point-lookup
//     threads keep pinning. This exercises "concurrent lock-free pins racing a
//     heavy structural churner" against a real engine.
//
//  2. `lock-free pin racing a page-table backing-store free` — the MECHANISM:
//     readers pin a hot resident key on a stable `*BufferPool` while another
//     thread frees+recreates that pool's page-table backing store (mirroring
//     the engine.zig open-time `deinit(); pool = BufferPool.init(...)`
//     safety-net). This directly demonstrates the UAF class the crash belongs
//     to. It is GATED behind an env var so it is not run by default (it is an
//     intentional UAF used to characterise the crash, not a normal assertion).
//
// Run:
//   zig build test-recreate-uaf -Doptimize=ReleaseSafe   (invariants armed)

const std = @import("std");
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const GraphConfig = graph_storage.GraphConfig;
const NodeRec = graph_storage.node.NodeRec;
const NodeId = graph_storage.NodeId;
const PropertyValue = graph_storage.PropertyValue;
const TestDataDir = graph_storage.test_support.TestDataDir;

// ---------------------------------------------------------------------------
// Reproducer 1: faithful full-engine concurrent workload.
// ---------------------------------------------------------------------------

const N: usize = 20_000;
const READER_THREADS: u32 = 24;
const PROP_THREADS: u32 = 8;
const ITERS: u64 = 40_000;

const EngShared = struct {
    engine: *GraphEngine,
    max_id: NodeId,
    started: std.atomic.Value(u32),
    go: std.atomic.Value(bool),
    n_threads: u32,
    failure: std.atomic.Value(u32),
};

fn barrier(sh: *EngShared) void {
    _ = sh.started.fetchAdd(1, .acq_rel);
    while (sh.started.load(.acquire) < sh.n_threads) std.atomic.spinLoopHint();
    while (!sh.go.load(.acquire)) std.atomic.spinLoopHint();
}

/// Pure point lookups: exercise the lock-free pin fast path with NO derived
/// index touch, so these run concurrently with the materialize churner.
fn getNodeWorker(sh: *EngShared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    barrier(sh);
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        const id: NodeId = @intCast(r.intRangeAtMost(u64, 1, sh.max_id));
        const rec = sh.engine.getNode(id) catch {
            sh.failure.store(2, .monotonic);
            return;
        };
        std.mem.doNotOptimizeAway(rec);
    }
}

/// Property lookups: the FIRST call triggers `ensureDerivedHydrated`
/// (materialize/rebuild) — a heavy scanNodes that pins+evicts across the whole
/// graph — while other property threads block on the latch and the getNode
/// threads keep pinning.
fn getPropWorker(sh: *EngShared, seed: u64) void {
    const a = std.heap.smp_allocator; // thread-safe: concurrent getProperty
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    barrier(sh);
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        const id: NodeId = @intCast(r.intRangeAtMost(u64, 2, sh.max_id));
        const rec = (sh.engine.getNode(id) catch {
            sh.failure.store(3, .monotonic);
            return;
        }) orelse continue;
        var keybuf: [32]u8 = undefined;
        // Node id k was inserted with property "k{id-2}" (see bulkLoad).
        const key = std.fmt.bufPrint(&keybuf, "k{d}", .{id - 2}) catch continue;
        const val = sh.engine.getProperty(rec.prop_head, key, a) catch {
            sh.failure.store(4, .monotonic);
            return;
        };
        std.mem.doNotOptimizeAway(val);
    }
}

fn bulkLoad(engine: *GraphEngine, n: usize) !NodeId {
    const hub = try engine.allocNode();
    try engine.putNode(hub, graph_storage.test_support.emptyNode(1));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const nid = try engine.allocNode();
        try engine.putNode(nid, graph_storage.test_support.emptyNode(1));
        try engine.addLabel(nid, 7);
        var rec = (try engine.getNode(nid)).?;
        var keybuf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        rec.prop_head = try engine.putProperty(rec.prop_head, key, .{ .int = @intCast(i) });
        try engine.putNode(nid, rec);
        _ = try engine.addEdge(hub, nid, @intCast(i % 4));
    }
    return @intCast(n + 1); // last allocated id
}

test "full-engine: concurrent point pins during first-access derived materialize" {
    const allocator = std.testing.allocator;

    var td = try TestDataDir.init(allocator);
    defer td.deinit();
    const uuid = [_]u8{0x18} ** 16;

    var cfg = graph_storage.test_support.testConfig();
    cfg.buffer_pool_pages = 64; // small pool => constant eviction under the scan

    var max_id: NodeId = 0;
    {
        const engine = try GraphEngine.create(allocator, td.path, uuid, cfg);
        defer engine.close() catch {};
        max_id = try bulkLoad(engine, N);
        try engine.checkpoint(); // clean snapshot so reopen defers derived build
    }

    const engine = try GraphEngine.open(allocator, td.path, uuid, cfg);
    defer engine.close() catch {};
    // Derived indexes are deferred at open (early-ready): the first property/
    // label access below materializes them while point lookups race.
    try std.testing.expectEqual(@as(u32, 0), engine.derived_materialize_runs);

    const n_threads = READER_THREADS + PROP_THREADS;
    var sh = EngShared{
        .engine = engine,
        .max_id = max_id,
        .started = std.atomic.Value(u32).init(0),
        .go = std.atomic.Value(bool).init(false),
        .n_threads = n_threads,
        .failure = std.atomic.Value(u32).init(0),
    };

    const threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);
    var t: u32 = 0;
    while (t < READER_THREADS) : (t += 1)
        threads[t] = try std.Thread.spawn(.{}, getNodeWorker, .{ &sh, 0xAAAA_0000 + @as(u64, t) });
    while (t < n_threads) : (t += 1)
        threads[t] = try std.Thread.spawn(.{}, getPropWorker, .{ &sh, 0xBBBB_0000 + @as(u64, t) });

    while (sh.started.load(.acquire) < n_threads) std.atomic.spinLoopHint();
    sh.go.store(true, .release);
    for (threads) |th| th.join();

    try std.testing.expectEqual(@as(u32, 0), sh.failure.load(.monotonic));
    // Materialization ran exactly once despite the concurrent first-accesses.
    try std.testing.expectEqual(@as(u32, 1), engine.derived_materialize_runs);
}

// ---------------------------------------------------------------------------
// Reproducer 2: MECHANISM demo — a lock-free pin reader dereferencing a
// page-table backing store that another thread frees+recreates. This is an
// intentional use-after-free that characterises the GAP-ENT-0018 crash class
// (segfault at `Metadata.isUsed` inside `BufferPool.pin`'s `page_table.get`).
// GATED behind GS_UAF_DEMO=1 so the normal suite never runs a deliberate UAF.
// ---------------------------------------------------------------------------

const BufferPool = graph_storage.buffer_pool.BufferPool;
const Pager = graph_storage.pager.Pager;
const page_mod = graph_storage.page;
const PageId = graph_storage.PageId;
const PAGE_SIZE: u32 = 4096;

const UafShared = struct {
    pool: *BufferPool,
    pager: *Pager,
    allocator: std.mem.Allocator,
    stop: std.atomic.Value(bool),
};

fn uafReader(sh: *UafShared) void {
    while (!sh.stop.load(.monotonic)) {
        // Hot resident key 0 — a pure lock-free cache-hit pin. The `get` here
        // reads `pool.page_table.metadata` which the recreator frees underneath.
        const frame = sh.pool.pin(.nodes, 0) catch continue;
        sh.pool.unpin(sh.pool.frameIndex(frame), false);
    }
}

test "MECHANISM: lock-free pin racing a page-table backing-store free (gated)" {
    // Intentional UAF demo — off by default. Flip to `true` locally to
    // characterise the GAP-ENT-0018 crash class (segfault in pin's page-table get).
    const RUN_UAF_DEMO = false;
    if (!RUN_UAF_DEMO) return error.SkipZigTest;

    const allocator = std.heap.smp_allocator;
    const file = try std.Io.Dir.cwd().createFile(
        std.Io.Threaded.global_single_threaded.io(),
        ".test_uaf_demo",
        .{ .read = true, .truncate = true },
    );
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), ".test_uaf_demo") catch {};
    var pager = Pager.init(file, PAGE_SIZE);
    var buf: [PAGE_SIZE]u8 = undefined;
    @memset(&buf, 0);
    const header = page_mod.initHeader(0, .node_data, PAGE_SIZE);
    @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
    try pager.writePage(0, &buf);

    var pool = try BufferPool.init(allocator, PAGE_SIZE, 32);
    pool.registerPager(.nodes, &pager);
    { // warm key 0 resident
        const f = try pool.pin(.nodes, 0);
        pool.unpin(pool.frameIndex(f), false);
    }

    var sh = UafShared{ .pool = &pool, .pager = &pager, .allocator = allocator, .stop = std.atomic.Value(bool).init(false) };
    var readers: [8]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, uafReader, .{&sh});

    // Recreate the SAME pool's backing store repeatedly, exactly as the engine
    // open-time safety-net does: deinit() frees page_table.metadata + munmaps
    // page_buf, then init() overwrites the struct — while readers dereference it.
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        pool.deinit();
        pool = try BufferPool.init(allocator, PAGE_SIZE, 32);
        pool.registerPager(.nodes, &pager);
        const f = try pool.pin(.nodes, 0);
        pool.unpin(pool.frameIndex(f), false);
    }
    sh.stop.store(true, .monotonic);
    for (readers) |t| t.join();
    pool.deinit();
}
