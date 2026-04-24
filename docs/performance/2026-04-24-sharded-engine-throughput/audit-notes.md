# Audit Notes — Sharded Graph Engine Throughput

- **Date:** 2026-04-24
- **Slug:** `sharded-engine-throughput`
- **Git SHA at audit:** `db4d9ab`
- **Language:** Zig 0.16 (toolchain pinned via mise)
- **Target repo:** `gitlab.com:devnw/zig/graph-storage`
- **Invocation:** `/bench-optimize:audit the sharding implementation`
- **Status:** read-only audit; no source edits; no bench runs

---

## 1. Target benchmark(s)

The sharding implementation ships one first-class benchmark and one
adjacent benchmark that shares the underlying sharding primitives.

| Bench step | Exe | Source | Optimize mode |
|------------|-----|--------|---------------|
| `zig build bench-sharded-throughput` | `sharded-throughput-bench` | `benchmarks/sharded_throughput.zig:1-138` | `.ReleaseFast` (`build.zig:167`) |
| `zig build bench-sharded-store` | `sharded-store-bench` | `benchmarks/sharded_store_bench.zig` | `.ReleaseFast` |

**Primary target:** `bench-sharded-throughput` — the spec's success-criterion
benchmark. Exact command:

```
zig build bench-sharded-throughput
```

**Secondary target (adjacent):** `bench-sharded-store` — isolates the
in-memory `ShardedStore` primitive. Useful as an A/B control: if a
change improves `bench-sharded-throughput` but regresses
`bench-sharded-store`, the change likely shifted cost into the
in-memory shard routing.

**Wiring:** `build.zig:219-242` declares both steps in
`addBenchmarks`. `bench_optimize` is pinned to `.ReleaseFast`
(`build.zig:167`). Both executables take the `graph_storage` module
and build fresh per invocation (Zig build graph has no shared
artifact between the two when sources differ).

---

## 2. Measured code path

The measured workload is a sequence of `(allocNode → putNode →
addEdge-to-previous)` cycles. Identifying citations:

### 2.1 Sharded variant — `benchmarks/sharded_throughput.zig:77-116`

- `benchSharded` — spawns 16 worker threads; each thread writes to
  its own pre-selected per-shard `GraphEngine` via
  `eng.shards[ctx.shard_idx]`. No cross-shard edges are created in
  this workload.
- **Per-iteration work (hot loop, line 93-101):**
  1. `GraphEngine.allocNode()` → `src/engine.zig:597-610`
     - Stride path: reads `manifest.next_node_id`, bumps by
       `SHARD_COUNT`, increments `node_count` and metrics, marks
       dirty. No allocation; purely arithmetic + writes into
       manifest memory.
  2. `GraphEngine.putNode(id, rec)` → `src/engine.zig:588-595`
     - Wraps `putNodeTxn` → `src/engine.zig:580-586`. Begins a
       per-op txn, updates the node page via `node_store.putNode`,
       logs the dirty page to WAL, and commits. **Every put is a
       single-op txn with a WAL append + fsync (via the
       `commit_txn` record inside `TxnManager.commit`).**
  3. `GraphEngine.addEdge(from, to, rel_type)` → `src/engine.zig:740`
     - Wraps `addEdgeTxn` → `src/engine.zig:679-737`. Per edge this
       writes the outgoing adjacency, incoming adjacency, bumps
       both endpoint node records, logs 3-4 dirty pages to WAL,
       maintains the `edge_index` hashmap, and commits. **Each
       addEdge is also a single-op txn.**

### 2.2 Single-engine baseline — `benchmarks/sharded_throughput.zig:118-137`

- `benchSingle` — identical per-op work but a single thread against a
  plain `GraphEngine`. Goes through the same
  `allocNode/putNode/addEdge` vtable methods.

### 2.3 Facade 2PC path (NOT exercised by this bench)

- `ShardedGraphEngine.crossShardAddEdge` — `src/sharded_engine.zig:226`
  — appends 4 WAL records (2 prepares + 2 commits) each with an
  explicit `wal.sync()` via `sharded_engine_2pc.appendPrepare`
  (line 86-100) and `appendDecision` (line 103-123).
- **Not reached by the bench workload** because workers only touch
  their own shard. If the bench evolves to stress cross-shard edges
  the 2PC path becomes the dominant cost — worth noting when adding
  future scenarios.

### 2.4 WAL manager — `src/wal.zig:32-99`

- `WalManager.appendRecord` at `src/wal.zig:78-96` — every engine
  write op passes through here via the WAL page-log or commit record.
- `WalManager.sync()` at `src/wal.zig:99` — backed by the external
  `wal` library with `manual_sync = true` (`src/wal.zig:55`) and
  `checkpoint = true` (`src/wal.zig:56`).

---

## 3. Dominant metrics expected

The bench emits three machine-readable one-liners to stdout:

```
SHARDED_THROUGHPUT workers=16 ops=20000 elapsed_ns=<E_sh> ops_per_s=<S_sh>
SINGLE_THROUGHPUT  workers=1  ops=20000 elapsed_ns=<E_si> ops_per_s=<S_si>
SHARDING_SPEEDUP ratio=<E_si / E_sh>
```

**Goal metrics (single sample per run):**

- `elapsed_ns` for the sharded variant — primary throughput signal.
- `ops_per_s` for the sharded variant — derived from `elapsed_ns`.
- `ratio` — derived. Used as the spec's pass/fail gate (≥4.0).

**Reference measurement (taken during plan execution, pre-optimization):**

```
SHARDED_THROUGHPUT workers=16 ops=20000 elapsed_ns=43_613_239_872 ops_per_s=458
SINGLE_THROUGHPUT  workers=1  ops=20000 elapsed_ns=688_862_100_085 ops_per_s=29
SHARDING_SPEEDUP ratio=15.79
```

`458 ops/s` for 16 parallel writers = ~29 ops/s/writer — dominated by
fsync latency on every commit. This is the ceiling the optimization
loop is trying to push up.

**Noise characteristics we have not yet measured:**

- Single-run harness. No variance data yet; see §5.
- `nanoTimestamp` granularity is OS monotonic clock — sub-microsecond,
  not a confounder at per-run elapsed of tens of seconds.

---

## 4. Related tests

Correctness / integration / recovery coverage that MUST remain green
when the bench is re-run. Every optimization iteration should re-run
these BEFORE the bench (per workflow rule).

| Suite | Command | Tests |
|-------|---------|-------|
| Unit (engine core + sharding) | `zig build test` | 431 inline tests, includes `src/sharded_engine_test.zig`, `engine_test.zig`, `wal_record.zig`, `shard_count.zig`, `shard_uuid.zig`, `shard_manifest.zig`, `sharded_engine_2pc.zig` |
| Integration (single-engine) | `zig build test-integration` | 14 tests in `tests/integration.zig` — full lifecycle, crash, QUAL regression tests |
| Integration (sharded) | `zig build test-integration-sharded` | 2 tests in `tests/integration_sharded.zig` — "full CRUD + cross-shard edges + reopen", "concurrent writers across shards make forward progress (smoke)" |
| Cross-shard recovery (2PC) | `zig build test-cross-shard-recovery` | 2 tests in `tests/cross_shard_recovery.zig` — crash-after-both-prepares aborts; crash-after-source-commit completes on reopen |
| Deterministic fuzz | `zig build test-fuzz-regression` | regression set in `tests/fuzz_regression.zig` |

**All five suites were green at `db4d9ab` (the audit point).** Any
change that regresses any of them is disqualified regardless of
bench gain.

---

## 5. Likely confounders

Ordered by expected impact on measurement noise / fairness.

### 5.1 fsync latency dominates per-op cost (high impact)

- Every `putNode`, `addEdge`, `allocNode`→`commit` path ends with a
  commit-record WAL append that triggers `fsync` via `manual_sync =
  true` (`src/wal.zig:55`). 20_000 ops × fsync is ~3-4 orders of
  magnitude more than the in-memory work.
- Any optimization that reduces per-op commit count (batching,
  multi-op txns) will show a large delta but is a **semantic change**
  — must be explicitly authorized by `ALLOWED_SCOPE`.
- `manual_sync = true` is intentional (WAL-before-data invariant). A
  change from `true` to `false` is a correctness regression — do not
  propose it.

### 5.2 Shared base `std.heap.page_allocator` across threads (medium impact)

- `benchSharded` at line 78 uses `std.heap.page_allocator` for the
  facade AND every per-shard engine. All 16 workers' allocations
  funnel through `mmap` syscalls. This is the recommended pattern
  per project convention (see `benchmarks/bench.zig:135`) but it
  means the bench measures contention on the process-wide allocator
  as well as the engine.
- A per-shard `ArenaAllocator` on top of the page allocator would
  amortize this but changes the workload shape.

### 5.3 Per-shard buffer pool sizing (medium impact)

- `sharded_engine.zig:104` sets per-shard
  `buffer_pool_pages = cfg.buffer_pool_pages / SHARD_COUNT` = 1024 /
  16 = 64 pages. That's small relative to the working-set of 20k
  nodes touching ~200 pages per shard. Page evictions may be
  happening during the bench; the integration test at 100 nodes
  doesn't stress this.
- Spec §Buffer pool accepts this tradeoff; no change without
  explicit authorization.

### 5.4 Cold I/O: fresh tmpdir per run (medium impact)

- `.zig-cache/tmp/sharded-throughput` is deleted at end and recreated
  at start (lines 53-56). The first run after a reboot pays ext4
  journal warmup; subsequent runs are warmer. Variance between
  first-and-nth runs must be characterized in baseline.

### 5.5 Thread scheduling variance (medium impact)

- 16 workers on a host with `N_hw < 16` cores would oversubscribe
  and inflate elapsed. `nproc` on the target machine must be
  recorded in baseline (host state). The plan executed on a host
  that showed ratio=15.79; bench-optimize should re-confirm the
  baseline on the actual optimization host.

### 5.6 N_OPS / SHARD_COUNT integer divisibility (low impact)

- `N_OPS = 20_000`, `n_workers = 16` → `per_worker = 1250`. 16 × 1250 =
  20_000 exactly. Fine.

### 5.7 Single-run harness — no warmup, no per-round distribution (high impact for validation)

- The harness produces **one** elapsed measurement per variant per
  invocation. No warmup discard. No per-round samples. No median
  computation. For the baseline step and later A/B validation this
  is a **harness-fix requirement** — the workflow's validation stage
  expects "1 warmup discard + 10 alternating rounds + median". The
  existing harness does not support that shape.
- Options (defer decision to `baseline` step): (a) wrap the binary
  in a loop-and-aggregate shell script; (b) extend
  `benchmarks/sharded_throughput.zig` to emit JSON per-round
  samples and accept `--rounds N` / `--warmup N` args. Option (b)
  is a minimal harness fix per `harness-fixes`.

### 5.8 `std.Thread.spawn` cost (low impact)

- Thread create/join overhead runs once per bench; amortized across
  20_000 ops × 16 workers = negligible per-op.

### 5.9 Allocator zero-fill on page reuse (low-medium impact)

- `page_allocator` returns zero-filled pages. Repeated buffer-pool
  eviction / reload patterns pay this cost. Not easily removed
  without changing the page lifecycle.

---

## 6. Known hot paths

Ranked by expected share of the sharded-variant's `elapsed_ns`,
based on static inspection (no profiling data yet — baseline will
populate this). "Share" ranks are relative within the bench, not
absolute fractions.

| Rank | Path | File:line | Share (static) | Notes |
|------|------|-----------|----------------|-------|
| 1 | `TxnManager.commit` → `wal.appendRecord(commit_txn)` → `wal.sync()` (fsync) | `src/wal.zig:78-101` | **High** | 60k+ commits per bench (20k ops × 3 txns average per op cycle: alloc + put + addEdge). Each fsync is ~0.1-1ms → seconds of wall time. |
| 2 | `GraphEngine.addEdgeTxn` page-log loop | `src/engine.zig:713-721` | High | 3-4 `logPage` calls per edge, each touches the buffer pool (`pin`/`unpin`), hashes/writes the WAL. |
| 3 | `AdjStore.addEdge` page-splitting / next-page selection | called from `src/engine.zig:697, 709` | Medium | Bench inserts many edges into the same from-node chain (`prev_node` pattern) — stresses the free-space + paged chain growth. |
| 4 | `BufferPool.pin/unpin` via `logPage` | `src/engine.zig:567-572` | Medium | Amortized across many log-page calls. Lock-based LRU acccounting under per-shard buffer pool. |
| 5 | `NodeStore.putNode` | `src/engine.zig:585, 699, 711` | Medium | Called 3x per addEdge cycle (source rec, target rec, putNode hot op). |
| 6 | `manifest.next_node_id` / `next_edge_id` bump | `src/engine.zig:603, 686` | Low | Pure arithmetic, but frequency is N_OPS × 2. |
| 7 | `edge_index.put` (`std.AutoHashMap`) | `src/engine.zig:724` | Low | One per edge; hashtable growth + bucket collisions. |

**Paths NOT hot in this bench but hot in other scenarios:**

- Cross-shard 2PC at `sharded_engine.zig:226-297` — NOT exercised
  here (no cross-shard edges). Listed for completeness.
- `FanOutNodeIterator` (`sharded_engine.zig:405`) — only used by
  `scanLabelIter`; not on the bench path.
- Recovery / reconciliation (`sharded_recovery.zig`) — open-time
  only; not on the bench path.

---

## Next step

Per workflow: `/bench-optimize:baseline`. The baseline step must
record:

- Host state (core count, clock, load, kernel version, filesystem
  type, disk kind).
- Runtime version (`zig version`, exact toolchain path).
- Git SHA (`db4d9ab` or later).
- Per-round raw samples — requires harness fix (§5.7) first, or an
  external shell loop that invokes the bench N times.

The audit identifies `elapsed_ns` for the sharded variant as the
primary goal metric, with `bench-sharded-store` as the adjacent
control. Dominant cost is fsync-per-commit; any optimization plan
must name a target bounded by correctness constraints (WAL-before-
data invariant, `manual_sync = true`, single-op-per-txn semantics).
