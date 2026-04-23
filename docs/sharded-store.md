# ShardedStore

An N-way sharded `std.AutoHashMap` wrapper published as a reusable
primitive for consumers that build concurrent in-memory graph
structures on top of the single-threaded `graph-storage` engine.

## Purpose

Consumers of `graph-storage` sometimes maintain in-memory maps
adjacent to the disk-resident engine: node/edge caches, materialised
views, transient staging maps for bulk ingest, adjacency lookup
tables. Under N-way concurrent writers, a single `std.AutoHashMap`
becomes a bottleneck — every insert that triggers a rehash is
incompatible with any concurrent reader or writer, forcing every
mutation behind one exclusive lock.

`ShardedStore(K, V)` exposes the same API surface as
`std.AutoHashMap` but splits storage across `SHARD_COUNT = 16`
independent `AutoHashMap` instances. Consumers pair one
`std.Io.RwLock` per shard (externally, in their own struct) and
serve `N`-way writers concurrently on disjoint key ranges.

This type is **not** used by the `graph-storage` engine itself —
the engine is single-graph, single-threaded by charter. The type
is published for consumers that layer concurrent structures above
the engine.

## API

Every mutating method has the same signature a plain `AutoHashMap`
caller is used to:

```
pub fn ShardedStore(comptime K: type, comptime V: type) type {
    pub const SHARD_COUNT: usize = 16;   // shared module constant
    pub const Shard = std.AutoHashMap(K, V);
    pub const GetOrPutResult = Shard.GetOrPutResult;
    pub const KV = Shard.KV;

    pub fn init(allocator) !Self;
    pub fn deinit(self: *Self) void;

    pub fn put(self: *Self, key: K, value: V) !void;
    pub fn get(self: *const Self, key: K) ?V;
    pub fn getPtr(self: *const Self, key: K) ?*V;
    pub fn contains(self: *const Self, key: K) bool;
    pub fn remove(self: *Self, key: K) ?V;
    pub fn fetchRemove(self: *Self, key: K) ?KV;
    pub fn getOrPut(self: *Self, key: K) !GetOrPutResult;
    pub fn count(self: *const Self) usize;
    pub fn shardLen(self: *const Self, idx: usize) usize;
    pub fn ensureTotalCapacity(self: *Self, total: u32) !void;
    pub fn ensureUnusedCapacity(self: *Self, additional: u32) !void;
    pub fn clearRetainingCapacity(self: *Self) void;
    pub fn iterator(self: *const Self) Iterator;
    pub fn keyIterator(self: *const Self) KeyIterator;
}

pub const SHARD_COUNT: usize = 16;
pub fn shardIndex(key: u64) usize;  // splitmix64 % SHARD_COUNT
```

`K` must be an unsigned integer type fitting in `u64`; a comptime
assertion rejects signed or wide integer keys at compile time.

## Shard routing

Keys route via `shardIndex(key) = splitmix64(key) % SHARD_COUNT`.

Splitmix64 is a full-avalanche mixer — any single bit change in
the input flips on average half the output bits. This matters for
consumers that allocate IDs monotonically (a counter): without
mixing, 16 consecutive IDs would all have different low bits and
land on 16 different shards, but arbitrary IDs (e.g. edge source
IDs reused from external inputs) would cluster. Splitmix64
absorbs both patterns into a uniform distribution.

Measured distribution on sequential `u64` IDs (see
`benchmarks/sharded_store_bench.zig`):

| N | min shard | max shard | stddev / mean |
| ---: | ---: | ---: | ---: |
| 10 000 | 567 | 676 | 4.57% |
| 100 000 | 6 109 | 6 405 | 1.37% |
| 1 000 000 | 62 036 | 63 112 | 0.44% |

At N ≥ 10 000 the worst shard holds less than 120% of the mean;
at N ≥ 100 000 it's below 103%. No hot-shard pathology.

## Concurrency model

**Intentionally single-threaded by itself.** `ShardedStore` holds
no locks. The consumer layers one `std.Io.RwLock` per shard in its
own struct and routes acquisition via `shardIndex`:

```zig
const sharded = @import("graph_storage").sharded_store;

pub const MyStructure = struct {
    store: sharded.ShardedStore(u64, MyValue),
    shard_locks: [sharded.SHARD_COUNT]std.Io.RwLock =
        [_]std.Io.RwLock{std.Io.RwLock.init} ** sharded.SHARD_COUNT,

    pub fn put(self: *MyStructure, key: u64, value: MyValue) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const idx = sharded.shardIndex(key);
        self.shard_locks[idx].lockUncancelable(io);
        defer self.shard_locks[idx].unlock(io);
        try self.store.put(key, value);
    }

    pub fn get(self: *MyStructure, key: u64) ?MyValue {
        const io = std.Io.Threaded.global_single_threaded.io();
        const idx = sharded.shardIndex(key);
        self.shard_locks[idx].lockSharedUncancelable(io);
        defer self.shard_locks[idx].unlockShared(io);
        return self.store.get(key);
    }
};
```

### Lock ordering

Cross-shard atomic operations (e.g. inserting a pair
`(a, b)` into two shards where `shardIndex(a) != shardIndex(b)`)
require acquiring both shard locks in **ascending index order** to
prevent deadlock. A helper pattern:

```zig
const src = sharded.shardIndex(a);
const dst = sharded.shardIndex(b);
if (src == dst) {
    self.shard_locks[src].lockUncancelable(io);
    defer self.shard_locks[src].unlock(io);
    // ... atomic op ...
} else {
    const first = @min(src, dst);
    const second = @max(src, dst);
    self.shard_locks[first].lockUncancelable(io);
    self.shard_locks[second].lockUncancelable(io);
    defer {
        self.shard_locks[second].unlock(io);
        self.shard_locks[first].unlock(io);
    }
    // ... atomic op ...
}
```

### Full-map scans

`iterator()` and `keyIterator()` walk every shard in ascending
order. Consumers that need a consistent snapshot across all
shards must acquire SHARED locks on every shard (ascending order)
before calling `iterator()` and hold them for the scan's duration.
Consumers that tolerate tearing (e.g. approximate stats) can skip
the global locking and iterate directly — shard-local tearing is
still prevented by the inner `AutoHashMap`'s internal invariants.

## Performance characteristics

Measured on x86_64, Zig 0.16, `ReleaseFast`, single thread
(see `benchmarks/sharded_store_bench.zig`):

| Operation | N = 1M | `std.AutoHashMap` | `ShardedStore` | Ratio |
| --- | ---: | ---: | ---: | ---: |
| put | 1 000 000 | 73.5 ms | 69.2 ms | 0.94× |
| get | 1 000 000 | 40.4 ms | 69.2 ms | 1.71× |

`put` throughput is parity with `AutoHashMap` (the per-op
splitmix64 cost is recovered by smaller per-shard maps rehashing
less frequently). `get` is ~1.7× slower due to the extra mix step
and a random cache-line access into the shard array on every
call.

**The single-threaded slowdown on `get` is a tradeoff.** Under
N-way concurrent readers against a consumer that takes per-shard
read locks, `ShardedStore` delivers up to `SHARD_COUNT`× parallelism
against a `std.AutoHashMap` that must serialise every reader
behind one exclusive-writer lock. Use `ShardedStore` when
concurrency matters; use `AutoHashMap` when it doesn't.

## When to use

Use `ShardedStore` when:

* You have ≥ 10 × `SHARD_COUNT` = 160 entries (otherwise the
  per-shard overhead dominates).
* You expect concurrent writers or readers on disjoint key ranges.
* Your keys are `u64` (or any unsigned integer type fitting in 64
  bits — the comptime check enforces this).
* Rehash-under-writer-lock is a measurable problem in your
  workload.

## When NOT to use

* Small maps (< ~160 entries) — straight `std.AutoHashMap` is
  faster and simpler.
* String or non-integer keys — the shard router requires a `u64`.
* Workloads that already serialize every mutation behind a single
  external lock — sharding adds indirection for no gain.
* Workloads that require atomic cross-shard snapshots without
  quiescing writers — `iterator()` holds no global lock.
* Read-dominated workloads on a single thread — the `1.7×` get
  overhead is pure cost without concurrent benefit.

## Versioning

`ShardedStore` landed in `graph-storage` v0.2.0 (2026-04-23). The
`SHARD_COUNT` constant is part of the public API; changing it
would be a breaking change (consumers' shard lock arrays sized at
`[SHARD_COUNT]std.Io.RwLock`).

## See also

* `benchmarks/sharded_store_bench.zig` — the distribution + throughput harness
* `src/sharded_store.zig` — the implementation and inline unit tests
* `docs/architecture.md` — how `graph-storage`'s single-graph engine
  relates to consumer-level concurrent structures
