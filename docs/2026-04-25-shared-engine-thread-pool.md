# Shared Engine Thread Pool — Design & Implementation Report

**Author:** Benji Vesterby (filed via geode investigation)
**Date:** 2026-04-25
**Source incident:** geode `docs/performance/2026-04-25-shared-stream-pool/post-fix-diagnosis.md`
**Status:** PROPOSED — implementation handoff

---

## 1. Executive summary

`GraphEngine.create` and `GraphEngine.open` (`src/engine.zig:202`, `src/engine.zig:318`) each construct a **private** `tp.ThreadPool`. The pool's `Config.max_threads` is left at `0`, which the dependency normalizes to `@min(getCpuCount(), 64)` (`thread_pool/src/types.zig:199-202`). On a 56-core box that is **56 worker threads per engine**.

`ShardedGraphEngine.create` constructs `SHARD_COUNT = 16` sub-engines per graph (`src/sharded_engine.zig:103-109`, `src/sharded_store.zig:75`). The compounded cost is:

| Layer | Pools | Workers each | Threads |
|-------|-------|--------------|---------|
| Per `GraphEngine` (default) | 1 | 56 | 56 |
| Per `ShardedGraphEngine` (16 shards) | 16 | 56 | **896** |
| Two graphs open at once | 32 | 56 | **1792** |

In the geode incident this fan-out drove `NLWP` to **1881** parked threads, starved the QUIC reactor on kernel-scheduler slots, and reproduced an end-to-end ingest cascade (`>5s` server ack delay → client deadline miss). Per-graph pools are the **dominant** structural source of idle worker threads in the geode server today — larger than the per-connection pools that were addressed by geode commit `b52846cc`.

The single consumer of the per-engine pool is `BufferPool.flushAllParallel` (`src/buffer_pool.zig:265-279`), invoked only from `Checkpointer.doCheckpoint` (`src/checkpoint.zig:64`). The pool is otherwise idle; 56 workers per shard to flush dirty pages at checkpoint cadence is wildly oversized.

**Recommended fix:** allow the caller to pass an `external_thread_pool` into `GraphConfig`. When set, the engine borrows the pool (no init, no deinit). When unset, preserve current behaviour but lower the auto-default to `max_threads = 4`. `ShardedGraphEngine` lazily creates a single pool that all 16 sub-engines share, eliminating the per-shard fan-out entirely.

The `thread_pool` dependency was explicitly designed for this pattern (multiple submitters, pool-scoped TLS, 64 submitter slots) — see §3.

---

## 2. Root cause

### 2.1 Where the pool is created

`src/engine.zig:198-210` (create path):

```zig
self.thread_pool = try tp.ThreadPool.init(allocator, .{
    .scheduler_variant = .work_stealing,
    .max_submitter_queues = 1,
});
self.buffer_pool.setThreadPool(&self.thread_pool);
```

The `open` path is identical at `src/engine.zig:314-326`. `max_threads` is unset → `Config.normalized()` (`thread_pool/src/types.zig:197-202`) sets it to `@min(cpu_guess, 64)`.

### 2.2 Where the pool is used

The pool is owned by the engine and exposed in two places:

1. `BufferPool.flushAllParallel` (`src/buffer_pool.zig:279-380`) — the only consumer of `submitBatch` / `WaitGroup`. Hard-capped at `MAX_CHUNKS = 64` (`buffer_pool.zig:341`), so even if 100 dirty pages need flushing, at most 64 batched tasks are submitted.
2. `GraphEngine.ensureSubmitterRegistered` (`src/engine.zig:436-439`) — claims a per-engine submitter slot used by the close/checkpoint path.

`flushAllParallel` is invoked from `BufferPool.flushAll` → `Checkpointer.doCheckpoint` → `engine_persist`. The pool is **idle except during checkpoint** — and even at checkpoint, it submits ≤64 short-lived I/O tasks.

### 2.3 Why per-shard pools are the wrong shape

Each `ShardedGraphEngine` has 16 sub-engines. They all checkpoint independently but never simultaneously enough to need 16 × 56 = 896 dedicated workers. Realistically:

- Checkpoints serialize per-engine (engine-internal mutex)
- A single 4-worker pool can saturate the I/O bandwidth of any one shard's flush
- Background CPU work that is not flush-related does not exist on this pool

A **single pool of 4 workers shared across all 16 shards** would handle every observed workload with idle headroom.

---

## 3. The thread_pool dependency already supports sharing

The vendored `thread_pool-0.2.0` is explicitly designed for shared/multi-tenant use. Evidence from `zig-pkg/thread_pool-.../`:

| Capability | Where | Implication |
|------------|-------|-------------|
| `registerSubmitter()` returns a slot index up to **64 slots** (`pool.zig:496-501`, `pool.zig:648`) | API | 16 shards × 1 slot = 16 — well under the 64 cap |
| TLS state is **pool-scoped** (`docs/api-reference.md:42`, comment "F-001") | Implementation | One thread can register on multiple pools; equivalently, multiple objects can register on one pool |
| `releaseSubmitter` is idempotent and CAS-safe (`pool.zig:662-700`, comment "F-005") | Implementation | Safe even when sub-engines tear down on different threads |
| `submitBatch` + `WaitGroup` per-submitter (`pool.zig:594, 741`) | API | Each shard's flush gets its own wait group; no cross-shard ordering issue |
| `max_submitter_queues` configurable up to 64 (`types.zig:194, 230`) | Config | Sized for shared-pool usage |
| `default_backpressure`, `blocking_backpressure` per-lane (`types.zig:151, 155`) | Config | Server can isolate flush traffic from any future CPU work |

The **current per-engine ownership model is the unidiomatic case** for this dependency. Moving to one shared pool aligns with the dependency's intended usage.

---

## 4. Decision rationale: why this change belongs in graph-storage

The geode investigator framed three options. Here is why the right home for the structural fix is `graph-storage`, not geode.

### Option A (vendored 2-line patch in geode: `max_threads = 4`)

- ✅ Tiny diff; unblocks the cascade investigation immediately.
- ❌ Still creates **64 idle workers per graph** (16 × 4) for a feature only invoked at checkpoint.
- ❌ Vendored patch in geode drifts from upstream graph-storage on every dependency bump.
- ❌ Hides the architectural mistake (per-engine ownership) instead of fixing it.

**Acceptable as a 24-hour mitigation if upstream cannot land in time.** Not the solution.

### Option B (share one pool across all sub-engines; **this report**)

- ✅ Eliminates the fan-out at its source.
- ✅ Per graph: **0 auto-created pools** when caller provides one, otherwise **1 pool of 4 workers** (regardless of shard count).
- ✅ Aligns with the thread_pool dependency's intended sharing model.
- ✅ Matches the just-landed pattern in geode's QUIC layer (commit `b52846cc` hoisted stream + acceptor pools to server lifetime).
- ❌ Requires an upstream API addition (`GraphConfig.external_thread_pool`).
- ❌ Requires a migration window for callers (`engine.zig` must respect "borrowed" vs "owned" pool semantics).

This is the correct fix.

### Option C (lazy pool creation per engine)

- ❌ Most invasive, least value. Lazy creation still produces 16 pools per graph the first time any shard checkpoints. Solves nothing structural.

### Why graph-storage is the right home

1. **`GraphEngine.init` is the API surface that forces per-engine ownership.** Until `GraphConfig` exposes a way to inject an external pool, downstream consumers cannot share — geode is structurally blocked.
2. **`ShardedGraphEngine` lives here.** The 16-way fan-out happens inside graph-storage. Even if geode passes one pool in, geode cannot prevent `ShardedGraphEngine` from creating 16 inner pools without an upstream API change.
3. **The thread_pool consumer (`BufferPool`) lives here.** All knowledge of how the pool is used is upstream; geode should not need to know about it.
4. **Symmetry with `setThreadPool`.** `BufferPool.setThreadPool` already exists (`src/buffer_pool.zig:121`) — the engine layer is the missing piece.

Geode's correct change is downstream and small: build one pool, pass it in. Detailed in §6.

---

## 5. Proposed changes (graph-storage)

### 5.1 `src/config.zig` — add an optional injected pool

```zig
const tp = @import("thread_pool");

pub const GraphConfig = struct {
    // ...existing fields...

    /// Optional caller-owned ThreadPool. When non-null, the engine borrows
    /// this pool for parallel buffer-pool flushes instead of creating its
    /// own. The engine never calls `pool.deinit()` or `pool.shutdown()` on
    /// a borrowed pool — the caller's lifetime must outlive every engine
    /// that borrows it. Used by ShardedGraphEngine (one pool / sharded
    /// graph) and by long-lived servers (one pool / process).
    ///
    /// When null (default), each engine creates and owns its own pool.
    /// The default pool size drops to `default_owned_pool_max_threads`
    /// (4) — see §5.2.
    external_thread_pool: ?*tp.ThreadPool = null,
};
```

This is **additive and source-compatible** — every existing call site that does not set the field gets the current behaviour modulo the default cap change.

### 5.2 `src/engine.zig` — borrow vs own

Lower the auto-default and route through a small helper. The engine struct gains a `owns_thread_pool: bool` flag (or store `?*tp.ThreadPool` and a separate owned `?tp.ThreadPool` slot).

```zig
pub const GraphEngine = struct {
    // ...
    thread_pool: *tp.ThreadPool,            // pointer (borrowed or owned)
    owned_thread_pool: ?tp.ThreadPool,      // backing storage when owned
    // ...
};

const default_owned_pool_max_threads: u32 = 4;

fn initThreadPool(
    self: *GraphEngine,
    allocator: Allocator,
    cfg: GraphConfig,
) !void {
    if (cfg.external_thread_pool) |ext| {
        self.owned_thread_pool = null;
        self.thread_pool = ext;
        return;
    }

    self.owned_thread_pool = try tp.ThreadPool.init(allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .max_threads = default_owned_pool_max_threads,
    });
    self.thread_pool = &self.owned_thread_pool.?;
}
```

Both `create` and `open` call this helper exactly where the existing `tp.ThreadPool.init` lives (`engine.zig:202` and `engine.zig:318`).

`cleanupResources` (`engine.zig:494-509`) becomes:

```zig
if (self.submitter_slot) |idx| {
    self.thread_pool.releaseSubmitter(idx);
    self.submitter_slot = null;
}

// Only drain & deinit a pool we own. Borrowed pools belong to the caller.
if (self.owned_thread_pool != null) {
    self.thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
    self.thread_pool.deinit();
    self.owned_thread_pool = null;
}
```

`buffer_pool.setThreadPool(self.thread_pool)` is unchanged — it always sees a valid pointer.

### 5.3 `src/sharded_engine.zig` — share one pool across all 16 shards

`ShardedGraphEngine` becomes responsible for a graph-scoped pool that all sub-engines share. The pool is created lazily once per graph and torn down in `close`/`deinit`:

```zig
pub const ShardedGraphEngine = struct {
    allocator: Allocator,
    graph_uuid: [16]u8,
    graph_root: []u8,
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: shard_manifest_mod.ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),
    aggregated_metrics: Metrics = .{},

    /// Shared across all sub-engines. Created from cfg.external_thread_pool
    /// when set, otherwise lazily owned by this struct.
    shared_thread_pool: *tp.ThreadPool,
    owned_shared_pool: ?tp.ThreadPool,

    pub fn create(allocator, data_dir, graph_uuid, cfg) !*ShardedGraphEngine {
        // ...existing setup...

        if (cfg.external_thread_pool) |ext| {
            self.owned_shared_pool = null;
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                .max_submitter_queues = SHARD_COUNT, // one slot per shard
                .max_threads = default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = ...;
            per_shard_cfg.external_thread_pool = self.shared_thread_pool;
            self.shards[s] = try GraphEngine.create(...);
        }
    }
};
```

`open` mirrors `create`. `close`/`deinit` tears down the owned pool (if any) **after** all sub-engines have closed, so no shard worker is still draining when the pool dies.

### 5.4 `Config.max_submitter_queues` sizing

The sharded pool sets `max_submitter_queues = SHARD_COUNT` (16). Each sub-engine's `ensureSubmitterRegistered` (`engine.zig:436-439`) consumes one slot. The 64-slot bitmap (`pool.zig:496-501`) leaves comfortable headroom even with caller-side submitters.

If a server opens many graphs sharing the same caller-provided pool (geode), the caller is responsible for sizing `max_submitter_queues` to `(graphs_open × SHARD_COUNT) + caller_submitters`. We expose this in `external_thread_pool` documentation; geode will need to size accordingly (typically `64`, the maximum).

### 5.5 No change to `BufferPool`

`buffer_pool.zig` is unchanged. It already holds `?*tp.ThreadPool` and never owns it. Existing pin/release semantics keep working — flush tasks are scheduled on whichever pool the engine hands it.

---

## 6. Companion changes required in geode (out of scope for this report)

A short handoff is filed at:

`docs/performance/2026-04-25-shared-stream-pool/upstream-handoff.md`

Summary of geode-side work, **only valid after this upstream change lands**:

1. Allocate one `tp.ThreadPool` at server lifetime (`server/main.zig` or alongside the existing shared `stream_pool`/`acceptor_pool` from commit `b52846cc`). Recommended config:
   - `max_threads = @min(8, cpu_count)`
   - `max_submitter_queues = 64` (max — accommodates many sharded graphs)
   - `scheduler_variant = .work_stealing`
2. Pass it via `GraphConfig.external_thread_pool` into every `ShardedGraphEngine.create`/`open` call site in `src/storage/graph_storage_adapter.zig` (locations: `:3140`, `:3208`).
3. Add a regression test that asserts `NLWP < (cpu_count + 16 + N_graphs)` for `N_graphs ≤ 8`. The current run shows 1881 idle workers; post-fix expectation is ≤80.
4. No mutex-tier changes (the shared pool sits below all storage tiers and is lock-free internally).

---

## 7. Backward compatibility

- **Source-compatible:** `external_thread_pool` defaults to `null`. Every existing call site behaves identically except for the pool size.
- **Behaviour change:** owned pools shrink from `min(cpu, 64)` to **4 workers** by default. This affects the worst-case checkpoint flush throughput — see §9 for benchmarks.
- **Test impact:** `engine_test.zig` and `sharded_engine_test.zig` should run with both code paths (owned + borrowed). Existing tests stay green because they exercise the `null` branch.
- **Vendored thread_pool:** no upstream change needed. The dependency already supports the multi-submitter pattern (see §3).

---

## 8. Test plan

### 8.1 Unit (graph-storage)

1. **`engine_test.zig` — borrowed pool lifecycle**
   - Create a `tp.ThreadPool` externally, pass via `external_thread_pool`, open + close engine. Assert pool is still usable after engine close.
   - Open two engines borrowing the same pool. Assert both checkpoint successfully.
   - Assert `cleanupResources` does NOT call `pool.deinit()` on the borrowed path (use a stats snapshot before/after).

2. **`engine_test.zig` — owned pool default size**
   - Default-init engine; snapshot stats. Assert `worker_stats.len == 4`.

3. **`sharded_engine_test.zig` — single shared pool across 16 shards**
   - Default-init `ShardedGraphEngine`. Assert there is exactly one `tp.ThreadPool` instance referenced by all `shards[i].thread_pool`. (Pointer equality.)
   - Run a multi-shard checkpoint; assert all 16 shards complete and `submitter_slot` was claimed once per shard.

4. **`sharded_engine_test.zig` — borrowed pool propagation**
   - Pass `external_thread_pool` to `ShardedGraphEngine.create`. Assert no inner pool was created and that all sub-engines borrow.

### 8.2 Stress (graph-storage)

1. **Concurrent checkpoint across shards** — 16 threads each driving one shard's checkpoint on a 4-worker shared pool. Verify completion within bounded time (no submitter-slot starvation, no deadlock).

### 8.3 Downstream verification (geode side, post-handoff)

1. Reproduce the cascade scenario from `docs/performance/2026-04-25-shared-stream-pool/post-fix-diagnosis.md`. Pre-fix `NLWP = 1881`; expected post-fix `NLWP ≤ 80`.
2. Run `make loadtest-compare` (geode) — must not regress the saved baseline.

---

## 9. Risks & mitigations

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| 4 workers is too few for very large graphs (e.g., 1M+ dirty pages at checkpoint) | Low | `MAX_CHUNKS = 64` already caps fan-out at 64 tasks per flush; 4 workers process them serially in batches. If benchmarks show regression, raise default to 8 — still 7× smaller than today. |
| Caller passes a pool that gets deinit'd before engines close | Medium | Document lifetime requirement explicitly; assert `pool != null` in debug builds before each submit; in tests, attempt a use-after-free scenario and confirm the failure mode is clean (`error.PoolShutdown`, not segfault). |
| Submitter-slot exhaustion when many graphs share one geode-side pool | Low | Geode sizes the shared pool with `max_submitter_queues = 64`. Each shard claims one slot lazily; with 4 graphs × 16 shards = 64 slots, exactly at the cap. If geode grows past 4 simultaneously open graphs, we either pool slot reuse via `releaseSubmitter` after each flush or split into multiple shared pools per "graph cohort". |
| ShardedGraphEngine owns the pool but a sub-engine outlives the parent | Should be impossible — `close`/`deinit` on parent walks `shards` first | Add a `comptime` assertion in `cleanupResources` that the engine's pool pointer is either non-null and owned, or non-null and matches the parent's. |
| Vendored thread_pool doesn't actually tolerate 64 concurrent submitters | Verified against `pool.zig:501` (64-bit free-mask) and `api-reference.md:37-43` (explicit "TLS state is pool-scoped") | None — the dependency was designed for this. |

---

## 10. Rollout

1. **Phase 1 (this PR):** Land §5.1, §5.2, §5.3, §5.4. Default behaviour for callers that do not opt in is "owned pool, max_threads = 4". Ship test suite from §8.1 + §8.2.
2. **Phase 2 (geode follow-up):** Geode adopts `external_thread_pool` per §6. Cascade investigation resumes from the diagnosis doc with a clean thread budget.
3. **Phase 3 (optional, +1 release):** Once the borrowed-pool path is exercised by geode in production, mark the owned-pool default path as legacy in `GraphConfig` doc-comments. Do not remove — small embedded users may still want it.

---

## 11. Out of scope

- Replacing `flushAllParallel` with sync I/O. Parallel flush is a real win for large checkpoints; the bug is pool ownership, not the work pattern.
- Tuning the work_stealing scheduler variant. The current variant is correct for this workload (short bursty tasks with no long blocking).
- Anything related to the QUIC reactor or geode's per-connection pool — those have already been addressed by geode commit `b52846cc`.

---

## 12. References

- Upstream investigation: `geode/docs/performance/2026-04-25-shared-stream-pool/post-fix-diagnosis.md`
- thread_pool API reference: `zig-pkg/thread_pool-0.2.0-.../docs/api-reference.md` (lines 37-48 for submitter contract)
- Per-pool TLS scoping (F-001): `zig-pkg/thread_pool-0.2.0-.../src/pool.zig:1306-1310` (and surrounding comments)
- `Config.normalized` default-`max_threads` logic: `zig-pkg/thread_pool-0.2.0-.../src/types.zig:197-202`
- Geode hoist-pool precedent: `geode` commit `b52846cc` (per-connection QUIC pool → server-lifetime shared pool)
- `BufferPool.flushAllParallel`: `src/buffer_pool.zig:265-380`
- `Checkpointer.doCheckpoint`: `src/checkpoint.zig:64`
- Sharded fan-out: `src/sharded_engine.zig:103-109`, `src/sharded_store.zig:75`
