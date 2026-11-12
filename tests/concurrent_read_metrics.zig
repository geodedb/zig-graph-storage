// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Concurrent readers must not race on the engine's read counters (SONNY-6375).
//!
//! `GraphEngine.getProperty` and `getPropertyNoDerived` are read paths that
//! callers run from many threads at once (geode's parallel UNION arms hydrate
//! properties concurrently). Both bump `metrics.properties_read`. A plain
//! `+= 1` there is an unsynchronised read-modify-write on shared memory: a
//! data race under ThreadSanitizer, and lost counts without it.
//!
//! The lookups use `prop_head == 0`, the "node has no properties" case, which
//! returns right after the counter bump. That keeps the buffer pool and the
//! derived indexes out of the picture, so the only shared write is the counter.
//!
//! Run:
//!   zig build test-concurrent-read-metrics
//!   zig build test-concurrent-read-metrics-tsan

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");

const GraphEngine = graph_storage.GraphEngine;
const TestDataDir = graph_storage.test_support.TestDataDir;

const THREADS: usize = 8;
const READS_PER_THREAD: usize = 50_000;

const Lookup = enum { derived, no_derived };

fn reader(engine: *GraphEngine, lookup: Lookup, failed: *std.atomic.Value(bool)) void {
    var i: usize = 0;
    while (i < READS_PER_THREAD) : (i += 1) {
        const got = switch (lookup) {
            .derived => engine.getProperty(0, "k", testing.allocator),
            .no_derived => engine.getPropertyNoDerived(0, "k", testing.allocator),
        } catch {
            failed.store(true, .release);
            return;
        };
        if (got != null) {
            failed.store(true, .release);
            return;
        }
    }
}

fn expectEveryReadCounted(lookup: Lookup) !void {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xC7} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, graph_storage.test_support.testConfig());
    defer engine.close() catch {};

    const before = engine.metrics.properties_read;
    var failed = std.atomic.Value(bool).init(false);

    var threads: [THREADS]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    while (spawned < THREADS) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, reader, .{ engine, lookup, &failed });
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;

    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(
        before + THREADS * READS_PER_THREAD,
        @atomicLoad(u64, &engine.metrics.properties_read, .monotonic),
    );
}

test "concurrent getProperty counts every read" {
    try expectEveryReadCounted(.derived);
}

test "concurrent getPropertyNoDerived counts every read" {
    try expectEveryReadCounted(.no_derived);
}
