// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! N-way sharded HashMap wrapper.  Each shard is an independent
//! `std.AutoHashMap` with its own allocator backing.  Keys route to
//! shard `shardIndex(key) = splitmix64(key) % SHARD_COUNT`.
//!
//! ## When to use
//!
//! `ShardedStore` is an in-memory primitive for consumers that need to
//! serve concurrent writers on disjoint key ranges without stacking
//! every mutation behind a single `HashMap` rehash critical section.
//! The intended usage pattern is:
//!
//!   1. Hold `N` independent `std.Io.RwLock` instances, one per shard,
//!      somewhere in your own structure (NOT in this file — keeping
//!      the locks separate lets this type stay allocator-only and
//!      testable without a thread runtime).
//!   2. Route every mutation to `shardIndex(key)` and acquire
//!      `shard_locks[idx]` EXCLUSIVE before calling any `*Self`
//!      method.  Point reads acquire `shard_locks[idx]` SHARED and
//!      call `get` / `getPtr` / `contains`.
//!   3. Full-graph scans (`iterator`, `keyIterator`) require the
//!      caller to hold SHARED locks on EVERY shard in a fixed order
//!      (ascending `shardIndex`) for the duration of the scan.
//!
//! Cross-shard atomic operations (e.g. insert a pair `(a, b)` into
//! two shards where `shardIndex(a) != shardIndex(b)`) require the
//! caller to acquire both shard locks in ascending index order to
//! avoid deadlock.
//!
//! ## When NOT to use
//!
//! * Small maps (< ~10 × SHARD_COUNT entries).  The per-shard
//!   overhead dominates and straight `std.AutoHashMap` is faster.
//! * String keys or any key type that doesn't fit in a `u64`.  The
//!   shard routing function takes a `u64` and the comptime check
//!   rejects non-unsigned-integer K.
//! * Workloads where the entire map is mutated behind a single
//!   external lock already.  Sharding adds indirection for no gain.
//! * Workloads that require a consistent atomic snapshot across all
//!   shards without quiescing writers (iteration holds no global
//!   lock — concurrent writers to different shards are visible
//!   mid-scan unless the caller takes every shard lock first).
//!
//! ## Concurrency model
//!
//! This type is single-threaded by itself.  Every per-shard rwlock
//! lives in the consumer's data structure, which means:
//!
//! * Tests can exercise sharding logic without spawning threads.
//! * The same type works in thread-per-graph, actor, and global-
//!   rwlock consumers — each picks its own locking policy.
//! * Cache-line false sharing between shard entries is controlled
//!   by the consumer (typically by putting per-shard locks + the
//!   shard map on separate cache lines via `@alignOf` padding).
//!
//! ## Relationship to graph-storage's engine
//!
//! `graph-storage` itself is single-graph and single-threaded by
//! charter — the disk-resident engine (pager, WAL, buffer pool)
//! does not use `ShardedStore`.  This type is published as a
//! reusable primitive for consumers that build in-memory graph
//! representations on top of the engine (e.g. caches, materialised
//! views, transient staging maps for bulk ingest).
//!
//! CANARY: REQ=REQ-SHARDED-STORE-001; FEATURE="ShardedStore"; ASPECT=DataStructure; STATUS=TESTED; TEST=src/sharded_store.zig; OWNER=graph-storage; UPDATED=2026-04-23

const std = @import("std");

/// Number of shards.  Powers of two are fastest (bitmask route) but
/// any value works.  16 is chosen to match the typical worker count
/// on a modern server and the target fan-in for dense graph
/// adjacency workloads.
pub const SHARD_COUNT: usize = 16;

/// Fast integer mixing (splitmix64) — avalanches both low and high
/// bits so consecutive IDs spread across shards.  This matters when
/// the consumer allocates IDs monotonically (counter-based):
/// without mixing, 16 consecutive IDs would land on 16 distinct
/// shards for the naive low-bits-modulo case, but arbitrary IDs
/// (e.g. edge source IDs reused from external inputs) would cluster.
/// Splitmix64 avalanches both ends so any integer distribution
/// spreads roughly uniformly across shards.
pub fn shardIndex(key: u64) usize {
    var z = key +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    return @as(usize, @intCast(z % SHARD_COUNT));
}

/// Generic sharded store over comptime-known K/V.  K must be an
/// unsigned integer type fitting in u64 — enforced at comptime so
/// a future accidental use with `i64` or `i32` fails to compile
/// rather than panicking at runtime on negative values.
pub fn ShardedStore(comptime K: type, comptime V: type) type {
    comptime {
        const info = @typeInfo(K);
        if (info != .int) @compileError("ShardedStore: K must be an integer type");
        if (info.int.bits > 64) @compileError("ShardedStore: K must fit in u64");
        if (info.int.signedness != .unsigned) @compileError("ShardedStore: K must be unsigned");
    }
    return struct {
        const Self = @This();
        pub const Shard = std.AutoHashMap(K, V);
        /// Re-export so callers can spell it the same way they would
        /// with a plain `AutoHashMap`: `GetOrPutResult { found_existing, value_ptr, key_ptr }`.
        pub const GetOrPutResult = Shard.GetOrPutResult;
        /// Entry returned by `fetchRemove` — `{ key, value }`.
        pub const KV = Shard.KV;

        allocator: std.mem.Allocator,
        shards: [SHARD_COUNT]Shard,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var shards: [SHARD_COUNT]Shard = undefined;
            for (&shards) |*s| s.* = Shard.init(allocator);
            return .{ .allocator = allocator, .shards = shards };
        }

        pub fn deinit(self: *Self) void {
            for (&self.shards) |*s| s.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            const idx = shardIndex(@as(u64, key));
            try self.shards[idx].put(key, value);
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].get(key);
        }

        pub fn getPtr(self: *const Self, key: K) ?*V {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].getPtr(key);
        }

        /// Remove and return the prior value, or null if not present.
        /// Mirrors `AutoHashMap.fetchRemove(k).?.value`.
        pub fn remove(self: *Self, key: K) ?V {
            const idx = shardIndex(@as(u64, key));
            if (self.shards[idx].fetchRemove(key)) |kv| return kv.value;
            return null;
        }

        /// Mirror of `AutoHashMap.fetchRemove` returning the full
        /// `?KV` entry.  Kept separate from `remove` because callers
        /// that need to release `kv.value.deinit()` (e.g. ArrayList
        /// values in adjacency indexes) want direct access to the
        /// entry, not just the value.
        pub fn fetchRemove(self: *Self, key: K) ?KV {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].fetchRemove(key);
        }

        pub fn contains(self: *const Self, key: K) bool {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].contains(key);
        }

        /// Mirror of `AutoHashMap.getOrPut`.  Returns the underlying
        /// shard's `GetOrPutResult` — the caller reads / writes
        /// `result.value_ptr.*` in the usual way.
        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].getOrPut(key);
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (&self.shards) |*s| total += s.count();
            return total;
        }

        /// Number of entries in the shard at `idx`.  Used by tests
        /// and by distribution diagnostics.  Named `shardLen`
        /// (not `shardCount`) to avoid ambiguity with "number of
        /// shards" which is `SHARD_COUNT`.
        pub fn shardLen(self: *const Self, idx: usize) usize {
            return self.shards[idx].count();
        }

        /// Pre-size every shard to hold `total_capacity / SHARD_COUNT`
        /// entries (rounded up).  Matches the bulk-load reservation
        /// pattern used by consumers that pre-allocate space ahead of
        /// a batched insert.
        pub fn ensureTotalCapacity(self: *Self, total_capacity: u32) !void {
            const per_shard: u32 = (total_capacity + @as(u32, @intCast(SHARD_COUNT)) - 1) /
                @as(u32, @intCast(SHARD_COUNT));
            for (&self.shards) |*s| try s.ensureTotalCapacity(per_shard);
        }

        /// Pre-reserve additional capacity proportionally across all
        /// shards.  Each shard gets `ceil(additional / SHARD_COUNT)`
        /// reserved.  Mirrors `AutoHashMap.ensureUnusedCapacity`.
        pub fn ensureUnusedCapacity(self: *Self, additional: u32) !void {
            const per_shard: u32 = (additional + @as(u32, @intCast(SHARD_COUNT)) - 1) /
                @as(u32, @intCast(SHARD_COUNT));
            for (&self.shards) |*s| try s.ensureUnusedCapacity(per_shard);
        }

        /// Clear every shard in place, retaining each shard's backing
        /// capacity.  Used by persistence / snapshot-restore paths.
        pub fn clearRetainingCapacity(self: *Self) void {
            for (&self.shards) |*s| s.clearRetainingCapacity();
        }

        /// Iterate every (k, v) pair across every shard, in shard
        /// order.  Consumers that need a consistent snapshot must
        /// take a read lock on EVERY shard before calling.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .owner = self, .shard_idx = 0, .inner = self.shards[0].iterator() };
        }

        /// Iterate every key across every shard, in shard order.
        /// Equivalent to `iterator()` but yields `*K` instead of full
        /// `Entry` structs.
        pub fn keyIterator(self: *const Self) KeyIterator {
            return .{ .owner = self, .shard_idx = 0, .inner = self.shards[0].keyIterator() };
        }

        pub const Iterator = struct {
            owner: *const Self,
            shard_idx: usize,
            inner: Shard.Iterator,

            pub fn next(it: *Iterator) ?Shard.Entry {
                while (true) {
                    if (it.inner.next()) |entry| return entry;
                    it.shard_idx += 1;
                    if (it.shard_idx >= SHARD_COUNT) return null;
                    it.inner = it.owner.shards[it.shard_idx].iterator();
                }
            }
        };

        pub const KeyIterator = struct {
            owner: *const Self,
            shard_idx: usize,
            inner: Shard.KeyIterator,

            pub fn next(it: *KeyIterator) ?*K {
                while (true) {
                    if (it.inner.next()) |k| return k;
                    it.shard_idx += 1;
                    if (it.shard_idx >= SHARD_COUNT) return null;
                    it.inner = it.owner.shards[it.shard_idx].keyIterator();
                }
            }
        };
    };
}

// ============================================================================
// Unit tests
// ============================================================================

test "ShardedStore: put/get round-trip across all shards" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    // Put enough keys that at least one lands in every shard by
    // virtue of the mixing function.
    var i: u64 = 0;
    while (i < 1024) : (i += 1) {
        try store.put(i, @as(u32, @intCast(i * 3)));
    }
    i = 0;
    while (i < 1024) : (i += 1) {
        try testing.expectEqual(@as(u32, @intCast(i * 3)), store.get(i).?);
    }

    // Every shard got at least one key.
    var populated: usize = 0;
    for (0..SHARD_COUNT) |s| {
        if (store.shardLen(s) > 0) populated += 1;
    }
    try testing.expect(populated == SHARD_COUNT);
}

test "ShardedStore: shardIndex is stable for the same key" {
    const testing = std.testing;
    try testing.expectEqual(shardIndex(42), shardIndex(42));
    try testing.expectEqual(shardIndex(0), shardIndex(0));
}

test "ShardedStore: shardIndex routes within [0, SHARD_COUNT)" {
    const testing = std.testing;
    var i: u64 = 0;
    while (i < 10000) : (i += 1) {
        try testing.expect(shardIndex(i) < SHARD_COUNT);
    }
}

test "ShardedStore: remove returns the prior value" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.put(7, 99);
    const removed = store.remove(7);
    try testing.expectEqual(@as(?u32, 99), removed);
    try testing.expect(store.get(7) == null);
}

test "ShardedStore: total count sums the shards" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.put(1, 1);
    try store.put(2, 2);
    try store.put(3, 3);
    try testing.expectEqual(@as(usize, 3), store.count());
}

test "ShardedStore: fetchRemove returns the full entry" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.put(11, 22);
    const kv = store.fetchRemove(11).?;
    try testing.expectEqual(@as(u64, 11), kv.key);
    try testing.expectEqual(@as(u32, 22), kv.value);
    try testing.expect(store.fetchRemove(11) == null);
}

test "ShardedStore: getOrPut gives the right slot" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    const first = try store.getOrPut(7);
    try testing.expect(!first.found_existing);
    first.value_ptr.* = 100;

    const second = try store.getOrPut(7);
    try testing.expect(second.found_existing);
    try testing.expectEqual(@as(u32, 100), second.value_ptr.*);
    second.value_ptr.* = 200;

    try testing.expectEqual(@as(u32, 200), store.get(7).?);
}

test "ShardedStore: ensureTotalCapacity spreads capacity across shards" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.ensureTotalCapacity(1024);
    // Capacity per shard is at least 1024 / SHARD_COUNT = 64, so
    // inserting 64 into one shard should not rehash under AutoHashMap
    // semantics.  Insert and confirm correctness.
    var i: u64 = 0;
    while (i < 64) : (i += 1) {
        try store.put(i * @as(u64, @intCast(SHARD_COUNT)), @as(u32, @intCast(i)));
    }
    try testing.expectEqual(@as(usize, 64), store.count());
}

test "ShardedStore: ensureUnusedCapacity accepts additional count" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    // Pre-populate, then reserve more.
    var i: u64 = 0;
    while (i < 50) : (i += 1) try store.put(i, @as(u32, @intCast(i)));
    try store.ensureUnusedCapacity(500);
    while (i < 550) : (i += 1) try store.put(i, @as(u32, @intCast(i)));
    try testing.expectEqual(@as(usize, 550), store.count());
}

test "ShardedStore: clearRetainingCapacity empties every shard" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    var i: u64 = 0;
    while (i < 100) : (i += 1) try store.put(i, @as(u32, @intCast(i)));
    try testing.expectEqual(@as(usize, 100), store.count());
    store.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), store.count());
    for (0..SHARD_COUNT) |s| try testing.expectEqual(@as(usize, 0), store.shardLen(s));
}

test "ShardedStore: keyIterator visits every key exactly once" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();

    var i: u64 = 1;
    while (i <= 200) : (i += 1) try store.put(i, @as(u32, @intCast(i)));

    var it = store.keyIterator();
    while (it.next()) |k| {
        try testing.expect(!seen.contains(k.*));
        try seen.put(k.*, {});
    }
    try testing.expectEqual(@as(usize, 200), seen.count());
}

test "ShardedStore: iterator visits every entry exactly once" {
    const testing = std.testing;
    var store = try ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    var i: u64 = 1;
    while (i <= 50) : (i += 1) try store.put(i, @as(u32, @intCast(i * 10)));

    var sum: u64 = 0;
    var visited: usize = 0;
    var it = store.iterator();
    while (it.next()) |entry| {
        sum += entry.value_ptr.*;
        visited += 1;
    }
    try testing.expectEqual(@as(usize, 50), visited);
    // Σ(10*k for k=1..50) = 10 * (50*51/2) = 12750
    try testing.expectEqual(@as(u64, 12750), sum);
}

test "ShardedStore: shardIndex distribution is reasonably uniform over sequential IDs" {
    const testing = std.testing;
    const N: usize = 10_000;
    var counts = [_]usize{0} ** SHARD_COUNT;
    var i: u64 = 0;
    while (i < N) : (i += 1) counts[shardIndex(i)] += 1;

    const expected_per_shard = N / SHARD_COUNT;
    // Chebyshev-style coarse check: every shard is within 15% of the
    // expected mean for N=10k.  Tight enough to catch mixer bugs,
    // loose enough to absorb natural variance.
    const lower = expected_per_shard * 85 / 100;
    const upper = expected_per_shard * 115 / 100;
    for (counts) |c| {
        try testing.expect(c >= lower);
        try testing.expect(c <= upper);
    }
}
