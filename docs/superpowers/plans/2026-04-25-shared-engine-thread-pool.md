# Shared Engine Thread Pool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Phase 1 of the shared-engine-thread-pool design (`docs/2026-04-25-shared-engine-thread-pool.md`): an additive `GraphConfig.external_thread_pool` field, borrow-vs-own pool semantics in `GraphEngine`, a single shared pool across all 16 sub-engines in `ShardedGraphEngine`, and lowering the owned-pool default from `min(cpu, 64)` to **4** workers. Net effect: a default sharded graph drops from `16 × min(cpu, 64) = up to 1024` worker threads to `4`, and a caller-provided pool drops it to `0`.

**Architecture:** Make `GraphEngine.thread_pool` a `*tp.ThreadPool` and add `owned_thread_pool: ?tp.ThreadPool` as backing storage when the engine creates its own. Route both `create` and `open` through a single `initThreadPool(self, allocator, cfg)` helper that picks borrowed-vs-owned. Branch `cleanupResources` so it only shuts down + deinits when the pool is owned. Hoist this same pattern up one level: `ShardedGraphEngine` owns or borrows **one** pool, then passes it to every sub-engine via `per_shard_cfg.external_thread_pool`. Teardown ordering: sub-engines first, then the parent's owned pool. No `BufferPool` change needed (`setThreadPool` already takes `*tp.ThreadPool`). The vendored `thread_pool-0.2.0` already supports this multi-submitter pattern via a 64-slot `registerSubmitter` bitmap (see source design doc §3).

**Tech Stack:** Zig 0.16+, vendored `thread_pool-0.2.0` (`zig-pkg/thread_pool-0.2.0-...`), existing `BufferPool.setThreadPool(*tp.ThreadPool)` plumbing, existing `Checkpointer.doCheckpoint` consumer of `flushAllParallel`.

---

## Reference

- Source design: `docs/2026-04-25-shared-engine-thread-pool.md` (read this first; it carries §3 dependency-capability evidence and §9 risk table that this plan does not duplicate)
- Pool consumer: `src/buffer_pool.zig:264-380` (`flushAll`, `flushAllParallel`)
- Pool owner today: `src/engine.zig:106` (field), `src/engine.zig:202` (create), `src/engine.zig:318` (open), `src/engine.zig:436-439` (submitter), `src/engine.zig:494-509` (cleanup)
- 16-way fan-out: `src/sharded_engine.zig:103-109` (create), `src/sharded_engine.zig:136-147` (open), `src/sharded_engine.zig:154-170` (close/deinit)
- Existing test that exercises the submitter contract: `src/engine_test.zig:821-843` (`"GraphEngine auto-registers a submitter slot on first flush"`)
- Build wiring: `build.zig:79-90` (unit-test root module already imports `thread_pool`); `src/testing_support.zig` provides `testConfig()` and `TestDataDir`

---

## File Structure

| File | Change | Responsibility after change |
|------|--------|------------------------------|
| `src/config.zig` | Modify | Add `external_thread_pool: ?*tp.ThreadPool = null` field to `GraphConfig` and one default-value test |
| `src/engine.zig` | Modify | Make `thread_pool: *tp.ThreadPool`; add `owned_thread_pool: ?tp.ThreadPool`; add `default_owned_pool_max_threads` constant + `initThreadPool` helper; route `create` and `open` through it; branch `cleanupResources` so borrowed pools are not deinit'd |
| `src/sharded_engine.zig` | Modify | Add `shared_thread_pool: *tp.ThreadPool` and `owned_shared_pool: ?tp.ThreadPool`; create or borrow one pool per sharded graph; propagate via `per_shard_cfg.external_thread_pool`; teardown owned pool **after** all sub-engines in `close`/`deinit` |
| `src/engine_test.zig` | Modify | New unit tests: owned-default worker count == 4; borrowed pool survives engine close; two engines share the same borrowed pool |
| `src/sharded_engine_test.zig` | Modify | New unit tests: pointer equality of pool across all 16 shards (owned path); borrowed-pool propagation; 16-thread concurrent checkpoint on a 4-worker shared pool |

No `build.zig` change. No `BufferPool` change (already takes `*tp.ThreadPool`).

---

## Migration note for the implementing engineer

This change converts `GraphEngine.thread_pool` from a value (`tp.ThreadPool`) to a pointer (`*tp.ThreadPool`). The only direct field access in the source tree is the four call sites listed under "Reference" above. Method calls (`self.thread_pool.registerSubmitter()`, `…releaseSubmitter()`, `…shutdown()`, `…deinit()`) are syntactically unchanged because Zig auto-derefs pointer-to-struct on method invocation. The one syntactic edit is `setThreadPool(&self.thread_pool)` → `setThreadPool(self.thread_pool)` at `engine.zig:210` and `engine.zig:326`.

`GraphEngine` is always heap-allocated via `allocator.create(GraphEngine)` (`engine.zig:122`, `engine.zig:218`), so taking `&self.owned_thread_pool.?` is safe — the struct never moves after init. Do **not** reassign `owned_thread_pool` after the pointer is taken; that would invalidate `self.thread_pool`.

---

## Tasks

### Task 1: Add `external_thread_pool` field to `GraphConfig`

**Files:**

- Modify: `src/config.zig` (add field; add `tp` import)
- Test: `src/config.zig` (extend the existing `test "default config values"` test or add a new `test "external_thread_pool defaults to null"`)

- [ ] **Step 1: Write the failing test**

Append to `src/config.zig` after the existing `test "default config values"` block (around line 109):

```zig
test "external_thread_pool defaults to null" {
    const cfg = GraphConfig{};
    try std.testing.expectEqual(@as(?*tp.ThreadPool, null), cfg.external_thread_pool);
}
```

Add to the imports at the top of `src/config.zig` (immediately after `const std = @import("std");`):

```zig
const tp = @import("thread_pool");
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test --summary all`
Expected: compile error in `src/config.zig` — `no field named 'external_thread_pool'` (the `expectEqual` line cannot resolve the field).

- [ ] **Step 3: Add the field to `GraphConfig`**

Insert the field at the end of `GraphConfig`'s field list (just before the `pub fn effectiveBufferPoolPages` method, around line 71 in the current file):

```zig
    /// Optional caller-owned ThreadPool. When non-null, the engine borrows
    /// this pool for parallel buffer-pool flushes instead of creating its
    /// own. The engine never calls `pool.deinit()` or `pool.shutdown()` on
    /// a borrowed pool — the caller's lifetime must outlive every engine
    /// that borrows it. Used by ShardedGraphEngine (one pool / sharded
    /// graph) and by long-lived servers (one pool / process). When null
    /// (default), each engine creates and owns a pool of
    /// `default_owned_pool_max_threads` workers (4 — see engine.zig).
    external_thread_pool: ?*tp.ThreadPool = null,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS — all `config.zig` tests green; full unit suite still green (no behavior change yet).

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "$(cat <<'EOF'
feat(config): add GraphConfig.external_thread_pool field

Additive opt-in for callers to inject a thread pool that the engine
borrows instead of creating. Default null preserves current behaviour.

See docs/2026-04-25-shared-engine-thread-pool.md §5.1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Convert `GraphEngine.thread_pool` to pointer + lower owned default to 4 workers

This task changes the field type, introduces `owned_thread_pool` storage, the `default_owned_pool_max_threads` constant, and the `initThreadPool` helper. It re-wires `create` and `open` to use the helper. It does **not** yet branch `cleanupResources` for borrowed pools — Task 3 does that. After this task, every existing call still owns its pool, but the worker count drops from `min(cpu, 64)` to 4.

**Files:**

- Modify: `src/engine.zig` (field type, new field, helper, constant, two call-site rewrites, two `setThreadPool` updates)
- Test: `src/engine_test.zig` (new test asserting `worker_stats.len == 4`)

- [ ] **Step 1: Write the failing test**

Append to `src/engine_test.zig` (after the existing `"GraphEngine auto-registers a submitter slot on first flush"` test, around line 843):

```zig
test "GraphEngine owned thread pool defaults to 4 workers" {
    var td = try testDataDir();
    defer td.deinit();

    const uuid = [_]u8{0x77} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, testConfig());
    defer engine.close() catch {};

    const stats = engine.thread_pool.statsSnapshot();
    try testing.expectEqual(@as(usize, 4), stats.worker_stats.len);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `worker_stats.len` is `min(cpu_count, 64)` (likely 16, 32, 56, or similar depending on the build host), not 4.

- [ ] **Step 3: Add the constant and the `initThreadPool` helper to `GraphEngine`**

In `src/engine.zig`, immediately above the `pub const GraphEngine = struct {` declaration (around line 79), add:

```zig
/// Default worker count for the owned (no-`external_thread_pool`) path.
/// Sized for the only consumer — `BufferPool.flushAllParallel`, capped at
/// `MAX_CHUNKS = 64` short-lived I/O tasks per checkpoint. Four workers
/// saturate any one shard's flush bandwidth; larger graphs that need more
/// throughput inject a caller-owned pool via `GraphConfig.external_thread_pool`.
/// See docs/2026-04-25-shared-engine-thread-pool.md §5.2 and §9.
pub const default_owned_pool_max_threads: u32 = 4;
```

In the `GraphEngine` struct field list (around line 106), replace the existing `thread_pool: tp.ThreadPool,` with:

```zig
    /// Pointer to the active pool. Either points into `owned_thread_pool`
    /// (engine created it) or to a caller-supplied pool from
    /// `GraphConfig.external_thread_pool`. Always non-null after init.
    thread_pool: *tp.ThreadPool,
    /// Backing storage for the owned-pool path. `null` when the engine is
    /// borrowing an external pool. Never reassigned after init — that would
    /// invalidate `thread_pool`.
    owned_thread_pool: ?tp.ThreadPool,
```

Add a private helper as a method on `GraphEngine`. Place it next to the other `init*`/`cleanup*` helpers; immediately above `ensureSubmitterRegistered` (around line 436) is a good location:

```zig
    /// Initializes `thread_pool` to either the caller-supplied pool (when
    /// `cfg.external_thread_pool` is set — borrowed) or a fresh
    /// `default_owned_pool_max_threads`-worker pool stored in
    /// `owned_thread_pool`. Both `create` and `open` route through this.
    fn initThreadPool(self: *GraphEngine, allocator: Allocator, cfg: GraphConfig) !void {
        if (cfg.external_thread_pool) |ext| {
            self.owned_thread_pool = null;
            self.thread_pool = ext;
            return;
        }
        // Pin .work_stealing explicitly and propagate init errors instead of
        // panicking — GraphEngine.create/open already return error unions, and
        // pool-init failure (OOM, spawn-failure) is a recoverable condition the
        // caller can retry or surface.
        self.owned_thread_pool = try tp.ThreadPool.init(allocator, .{
            .scheduler_variant = .work_stealing,
            // One submitter slot for the per-engine registerSubmitter
            // adoption (ensureSubmitterRegistered). Without this,
            // registerSubmitter returns error.NoSubmitterSlots because the
            // library default is 0.
            .max_submitter_queues = 1,
            .max_threads = default_owned_pool_max_threads,
        });
        self.thread_pool = &self.owned_thread_pool.?;
    }
```

- [ ] **Step 4: Re-wire `GraphEngine.create` to use the helper**

In `src/engine.zig`, in `GraphEngine.create`, replace lines 198-210 (the `// Pin .work_stealing explicitly …` comment block through `self.buffer_pool.setThreadPool(&self.thread_pool);`) with:

```zig
        // Initialize owned-or-borrowed thread pool (see initThreadPool).
        try self.initThreadPool(allocator, cfg);
        self.buffer_pool.setThreadPool(self.thread_pool);
```

Also ensure `self.owned_thread_pool = null;` is set early in `create` so the field is initialized before any errdefer that might run cleanup. The cleanest spot is alongside the other early-init field assignments, around line 133 (right after `self.submitter_slot = null;`):

```zig
        self.submitter_slot = null;
        self.owned_thread_pool = null;
```

- [ ] **Step 5: Re-wire `GraphEngine.open` to use the helper**

In `src/engine.zig`, in `GraphEngine.open`, replace lines 314-326 (same comment block through `setThreadPool`) with:

```zig
        // Initialize owned-or-borrowed thread pool (see initThreadPool).
        try self.initThreadPool(allocator, cfg);
        self.buffer_pool.setThreadPool(self.thread_pool);
```

Add the early init alongside the other field assignments around line 229 (right after `self.submitter_slot = null;`):

```zig
        self.submitter_slot = null;
        self.owned_thread_pool = null;
```

- [ ] **Step 6: Run the new test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS — `worker_stats.len == 4`. All previously-passing tests still pass; no new failures (the existing flush, checkpoint, and submitter tests still own the pool, just with 4 workers instead of `min(cpu, 64)`).

If a long-running test now times out (none expected — `flushAllParallel` is `MAX_CHUNKS = 64` short tasks, easily handled by 4 workers), increase the test's checkpoint count or split it across multiple checkpoints rather than reverting the default.

- [ ] **Step 7: Commit**

```bash
git add src/engine.zig src/engine_test.zig
git commit -m "$(cat <<'EOF'
refactor(engine): borrow-or-own thread pool, default 4 workers

Hoist GraphEngine.thread_pool to a *tp.ThreadPool with optional
backing storage in owned_thread_pool. Both create() and open() now
route through initThreadPool(). Default owned pool drops from
min(cpu, 64) workers to 4 — the only consumer is flushAllParallel
which caps at MAX_CHUNKS = 64 short I/O tasks per checkpoint.

External-pool branch and borrowed-pool teardown follow in the next
commit.

See docs/2026-04-25-shared-engine-thread-pool.md §5.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Branch `cleanupResources` so borrowed pools are not deinit'd

This task adds the borrowed-pool teardown contract: if `owned_thread_pool` is null, the engine must **not** call `shutdown` or `deinit` on the pool — the caller owns its lifetime.

**Files:**

- Modify: `src/engine.zig` (`cleanupResources`)
- Test: `src/engine_test.zig` (two new tests)

- [ ] **Step 1: Write the first failing test — borrowed pool survives engine close**

Append to `src/engine_test.zig` (after the test added in Task 2):

```zig
test "GraphEngine borrows external thread pool — pool stays alive after engine close" {
    const tp = @import("thread_pool");

    var td = try testDataDir();
    defer td.deinit();

    var caller_pool = try tp.ThreadPool.init(testing.allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 16,
        .max_threads = 4,
    });
    defer {
        caller_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        caller_pool.deinit();
    }

    var cfg = testConfig();
    cfg.external_thread_pool = &caller_pool;

    const uuid = [_]u8{0x88} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
    try engine.close();

    // Pool must still be usable after the engine closed. registerSubmitter
    // will return error.PoolShutdown if the engine ran shutdown on us.
    const slot = try caller_pool.registerSubmitter();
    caller_pool.releaseSubmitter(slot);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — current `cleanupResources` calls `self.thread_pool.shutdown(.drain, ...)` and `self.thread_pool.deinit()` unconditionally; the second `caller_pool.shutdown` in the test's `defer` will then run on a deinit'd pool. The most likely visible failure is a segfault or a use-after-free panic; if the deinit happens to be a no-op for an already-shut pool, the `caller_pool.registerSubmitter` line returns `error.PoolShutdown`.

- [ ] **Step 3: Branch `cleanupResources` to skip borrowed-pool teardown**

In `src/engine.zig`, replace the existing block at lines 494-509 (the `cleanupResources` body, from `if (self.submitter_slot) |idx| { ... }` through `self.thread_pool.deinit();`) with:

```zig
    fn cleanupResources(self: *GraphEngine, allocator: Allocator) void {
        // Release the submitter slot before draining the pool. The TLS-
        // owner check inside releaseSubmitter (F-005) handles the case
        // where the engine was torn down from a thread other than the one
        // that first called ensureSubmitterRegistered — it becomes a free-
        // mask CAS with no cache drain, which is correct because the
        // pool's deinit path will scrub any residual cache entries.
        //
        // For borrowed pools (owned_thread_pool == null) we MUST still
        // release the slot — the slot belongs to this engine's lifecycle,
        // not the pool's. The caller may keep using other slots after we
        // close.
        if (self.submitter_slot) |idx| {
            self.thread_pool.releaseSubmitter(idx);
            self.submitter_slot = null;
        }

        // Only shut down + deinit a pool we own. Borrowed pools belong to
        // the caller, who is responsible for their lifetime (must outlive
        // every engine that borrows them — see GraphConfig docs).
        if (self.owned_thread_pool != null) {
            self.thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.thread_pool.deinit();
            self.owned_thread_pool = null;
        }
```

Keep the rest of the function (`self.txn_manager.deinit();` through the final `allocator.destroy(self);`) unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS — borrowed pool stays alive after engine close. All existing tests still pass (they all use the owned-pool path, which retains shutdown+deinit).

- [ ] **Step 5: Write the second failing test — two engines borrow the same pool**

Append to `src/engine_test.zig`:

```zig
test "two GraphEngines can borrow the same external thread pool" {
    const tp = @import("thread_pool");

    var td = try testDataDir();
    defer td.deinit();

    var caller_pool = try tp.ThreadPool.init(testing.allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 8,
        .max_threads = 4,
    });
    defer {
        caller_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        caller_pool.deinit();
    }

    var cfg = testConfig();
    cfg.external_thread_pool = &caller_pool;

    const uuid_a = [_]u8{0x91} ** 16;
    const uuid_b = [_]u8{0x92} ** 16;

    const eng_a = try GraphEngine.create(testing.allocator, td.path, uuid_a, cfg);
    defer eng_a.close() catch {};
    const eng_b = try GraphEngine.create(testing.allocator, td.path, uuid_b, cfg);
    defer eng_b.close() catch {};

    // Both engines must point at the same pool.
    try testing.expectEqual(&caller_pool, eng_a.thread_pool);
    try testing.expectEqual(&caller_pool, eng_b.thread_pool);
    try testing.expect(eng_a.owned_thread_pool == null);
    try testing.expect(eng_b.owned_thread_pool == null);

    // Force each to claim a submitter slot — must each get a distinct slot.
    eng_a.ensureSubmitterRegistered();
    eng_b.ensureSubmitterRegistered();
    try testing.expect(eng_a.submitter_slot != null);
    try testing.expect(eng_b.submitter_slot != null);
    try testing.expect(eng_a.submitter_slot.? != eng_b.submitter_slot.?);
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS — borrowing logic from Task 2 already supports this; this test confirms the contract.

If submitter-slot allocation collides (it shouldn't — `registerSubmitter` returns distinct slots while bits remain in the free-mask), recheck the helper in Task 2: it sets `max_submitter_queues = 1` for *owned* pools, but this test passes a caller pool with `max_submitter_queues = 8`, so two distinct slots are available.

- [ ] **Step 7: Commit**

```bash
git add src/engine.zig src/engine_test.zig
git commit -m "$(cat <<'EOF'
feat(engine): borrowed thread pool — skip shutdown/deinit on close

cleanupResources now branches on owned_thread_pool: borrowed pools
are released-only (submitter slot freed), never shut down or
deinit'd. Adds two tests: borrowed-pool survives engine close, and
two engines can borrow the same pool with distinct submitter slots.

See docs/2026-04-25-shared-engine-thread-pool.md §5.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Single shared pool across all 16 sub-engines in `ShardedGraphEngine`

This task hoists pool ownership to `ShardedGraphEngine`. Each sharded graph creates **one** pool (4 workers, 16 submitter slots) and propagates it to all 16 sub-engines via `per_shard_cfg.external_thread_pool`. When a caller passes `cfg.external_thread_pool`, the parent borrows that pool and propagates the same pointer instead.

**Files:**

- Modify: `src/sharded_engine.zig` (struct fields, `create`, `open`, `close`, `deinit`; new `tp` import)
- Test: `src/sharded_engine_test.zig` (one new test)

- [ ] **Step 1: Write the failing test — owned shared pool, pointer equality across shards**

Append to `src/sharded_engine_test.zig` (after the last existing test):

```zig
test "ShardedGraphEngine creates one shared pool across all shards" {
    const tp = @import("thread_pool");

    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0x99} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Parent owns its pool (no external pool was injected).
    try testing.expect(eng.owned_shared_pool != null);

    // Every sub-engine borrows the parent's pool — same pointer.
    const shared: *tp.ThreadPool = eng.shared_thread_pool;
    try testing.expectEqual(&eng.owned_shared_pool.?, shared);
    for (0..shard_count_mod.SHARD_COUNT) |i| {
        try testing.expectEqual(shared, eng.shards[i].thread_pool);
        try testing.expect(eng.shards[i].owned_thread_pool == null);
    }
}
```

`sharded_engine_mod` and `shard_count_mod` are already imported at the top of the file; `test_support` is too. No import edit needed for this step.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `ShardedGraphEngine` has no `owned_shared_pool` or `shared_thread_pool` field. Compile error.

- [ ] **Step 3: Add the fields and `tp` import to `ShardedGraphEngine`**

In `src/sharded_engine.zig`, add the import alongside the existing imports (right after `const builtin = @import("builtin");` near line 9):

```zig
const tp = @import("thread_pool");
```

In the `ShardedGraphEngine` struct (lines 57-65 in the current file), add two fields immediately after `aggregated_metrics: Metrics = .{},`:

```zig
    /// Shared across all sub-engines. Either points into
    /// `owned_shared_pool` (parent created it) or to a caller-supplied
    /// pool from `cfg.external_thread_pool`.
    shared_thread_pool: *tp.ThreadPool,
    /// Backing storage for the owned shared-pool path. `null` when the
    /// caller injected an external pool. Never reassigned after init.
    owned_shared_pool: ?tp.ThreadPool,
```

- [ ] **Step 4: Wire shared-pool init into `ShardedGraphEngine.create`**

In `src/sharded_engine.zig`, replace the `for (0..SHARD_COUNT) |s| { ... }` block at lines 100-109 (i.e., the `var created: usize = 0;` declaration through the closing brace of the loop) with:

```zig
        // Init or borrow the shared thread pool BEFORE creating sub-engines.
        // Errdefer ensures we drain the owned pool if any sub-engine create fails.
        self.owned_shared_pool = null;
        if (cfg.external_thread_pool) |ext| {
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                // One submitter slot per shard; SHARD_COUNT is 16 today
                // and the pool's hard cap is 64 slots.
                .max_submitter_queues = SHARD_COUNT,
                .max_threads = engine_mod.default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }
        errdefer if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        };

        var created: usize = 0;
        errdefer for (self.shards[0..created]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            per_shard_cfg.external_thread_pool = self.shared_thread_pool;
            self.shards[s] = try GraphEngine.create(allocator, self.graph_root, per_shard[s], per_shard_cfg);
            created += 1;
        }
```

- [ ] **Step 5: Wire shared-pool init into `ShardedGraphEngine.open`**

In `src/sharded_engine.zig`, in `ShardedGraphEngine.open` (currently at lines 114-152), apply the same shape: init or borrow the pool right after `self.shard_manifest = ...` (around line 131) and propagate it inside the loop. Replace the block from `var opened: usize = 0;` (line 133) through the closing `}` of the loop (line 147) with:

```zig
        // Init or borrow the shared thread pool BEFORE opening sub-engines.
        self.owned_shared_pool = null;
        if (cfg.external_thread_pool) |ext| {
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                .max_submitter_queues = SHARD_COUNT,
                .max_threads = engine_mod.default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }
        errdefer if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        };

        var opened: usize = 0;
        errdefer for (self.shards[0..opened]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            per_shard_cfg.external_thread_pool = self.shared_thread_pool;
            self.shards[s] = try GraphEngine.open(
                allocator,
                self.graph_root,
                self.shard_manifest.per_shard_uuids[s],
                per_shard_cfg,
            );
            opened += 1;
        }
```

- [ ] **Step 6: Tear down the owned shared pool *after* all sub-engines in `close` and `deinit`**

In `src/sharded_engine.zig`, replace the existing `pub fn close` (lines 154-164) with:

```zig
    pub fn close(self: *ShardedGraphEngine) !void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.close() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        // Tear down the owned shared pool ONLY after every sub-engine has
        // released its submitter slot and stopped submitting. Borrowed
        // pools (owned_shared_pool == null) belong to the caller.
        if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
        if (first_err) |err| return err;
    }
```

Replace the existing `pub fn deinit` (lines 166-170) with:

```zig
    pub fn deinit(self: *ShardedGraphEngine) void {
        for (self.shards) |eng| eng.deinit();
        if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS — `eng.shards[i].thread_pool` is the same pointer for all `i`; `eng.owned_shared_pool` is non-null; `eng.shards[i].owned_thread_pool` is null. All previously-passing tests still pass.

If a sub-engine's `cleanupResources` somehow shuts the shared pool (it should not — Task 3's branch keys on the per-engine `owned_thread_pool`, which is null when borrowing), `close` on the parent will then call `shutdown` on a dead pool. Investigate Task 3's branch wiring before changing this task.

- [ ] **Step 8: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "$(cat <<'EOF'
feat(sharded): single shared thread pool across all 16 shards

ShardedGraphEngine.create and .open now init one pool (4 workers,
SHARD_COUNT submitter slots) and propagate it to every sub-engine
via per_shard_cfg.external_thread_pool. If the caller injects
cfg.external_thread_pool, the parent borrows it and propagates the
same pointer. close()/deinit() tear down the owned shared pool AFTER
every sub-engine has closed.

A default sharded graph drops from 16 × min(cpu, 64) ≈ 256-1024
worker threads to 4. With a caller-injected pool, the per-graph cost
is zero.

See docs/2026-04-25-shared-engine-thread-pool.md §5.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Borrowed-pool propagation test for `ShardedGraphEngine`

This task is test-only and locks the contract that a caller-injected pool propagates unchanged through every layer.

**Files:**

- Test: `src/sharded_engine_test.zig` (one new test)

- [ ] **Step 1: Write the test**

Append to `src/sharded_engine_test.zig`:

```zig
test "ShardedGraphEngine.create propagates external_thread_pool to all shards" {
    const tp = @import("thread_pool");

    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();

    var caller_pool = try tp.ThreadPool.init(testing.allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 64,
        .max_threads = 4,
    });
    defer {
        caller_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        caller_pool.deinit();
    }

    var cfg = test_support.testConfig();
    cfg.external_thread_pool = &caller_pool;

    const uuid = [_]u8{0xAA} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        cfg,
    );
    defer eng.close() catch {};

    // Parent did not allocate its own pool.
    try testing.expect(eng.owned_shared_pool == null);
    try testing.expectEqual(&caller_pool, eng.shared_thread_pool);

    // Every sub-engine borrows the caller's pool — same pointer, no owned storage.
    for (0..shard_count_mod.SHARD_COUNT) |i| {
        try testing.expectEqual(&caller_pool, eng.shards[i].thread_pool);
        try testing.expect(eng.shards[i].owned_thread_pool == null);
    }
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS on the first run — Task 4 already implemented the propagation. This test guards against a future change that drops the propagation.

If it FAILS, recheck Task 4 Step 4 / Step 5 — specifically `per_shard_cfg.external_thread_pool = self.shared_thread_pool;` inside the loop.

- [ ] **Step 3: Commit**

```bash
git add src/sharded_engine_test.zig
git commit -m "$(cat <<'EOF'
test(sharded): lock external_thread_pool propagation contract

When the caller passes cfg.external_thread_pool, the parent borrows
and every sub-engine borrows the same pointer. No owned pools are
allocated anywhere in the sharded graph.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Concurrent multi-shard checkpoint stress test on the shared 4-worker pool

This task verifies that 16 shards driving independent checkpoints on a 4-worker shared pool complete without submitter-slot starvation or deadlock. It's the only stress-shaped test in this plan; covers risk row #3 from the source design's §9 risk table.

**Files:**

- Test: `src/sharded_engine_test.zig` (one new test; new local `engine_mod` import)

- [ ] **Step 1: Write the failing test**

Add to imports at the top of `src/sharded_engine_test.zig` (just below `const sharded_engine_mod = @import("sharded_engine.zig");`):

```zig
const engine_mod = @import("engine.zig");
```

Append to `src/sharded_engine_test.zig`:

```zig
test "ShardedGraphEngine: 16 concurrent shard checkpoints complete on a 4-worker shared pool" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();

    const uuid = [_]u8{0xBB} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Seed each shard with at least one dirty page so the per-shard
    // checkpoint actually has work to flush.
    for (0..shard_count_mod.SHARD_COUNT) |s| {
        const id = try eng.shards[s].allocNode();
        try eng.shards[s].putNode(id, test_support.emptyNode(1));
    }

    const Worker = struct {
        fn run(shard_eng: *engine_mod.GraphEngine, out_err: *?anyerror) void {
            shard_eng.checkpoint() catch |err| {
                out_err.* = err;
            };
        }
    };

    var thread_errs: [shard_count_mod.SHARD_COUNT]?anyerror = .{null} ** shard_count_mod.SHARD_COUNT;
    var threads: [shard_count_mod.SHARD_COUNT]std.Thread = undefined;

    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ eng.shards[i], &thread_errs[i] });
    }
    for (threads) |t| t.join();

    for (thread_errs) |maybe_err| {
        if (maybe_err) |err| {
            std.debug.print("shard checkpoint failed: {}\n", .{err});
            return error.ShardCheckpointFailed;
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS — the 16 worker threads concurrently invoke `checkpoint()` on their shard. Each shard's `ensureSubmitterRegistered` claims a slot from the shared pool's 16-slot pool; flush tasks are submitted to the shared 4-worker pool and processed in batches. No deadlock because the pool's submit path is non-blocking when the queue has room (and any unsubmitted chunks fall back to inline execution — see `flushAllParallel` at `buffer_pool.zig:370-376`).

If it FAILS with `error.NoSubmitterSlots`, the shared pool's `max_submitter_queues = SHARD_COUNT` is being exceeded — likely a regression in Task 4 Step 4.
If it HANGS for >30s, the test runner will eventually time out; suspect a deadlock between submitter-slot CAS and checkpoint mutex. Re-examine `ensureSubmitterRegistered` and `cleanupResources` — both must stay outside any per-engine mutex.

- [ ] **Step 3: Commit**

```bash
git add src/sharded_engine_test.zig
git commit -m "$(cat <<'EOF'
test(sharded): 16 concurrent shard checkpoints on a 4-worker pool

Spawns one thread per shard; each invokes checkpoint() on its
sub-engine. All must complete without submitter-slot starvation or
deadlock. Covers risk row #3 of §9 in the design doc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Final verification — full test suite + integration + fuzz regressions

This task is the safety check before declaring Phase 1 done. No code changes; only running the whole suite.

**Files:** none

- [ ] **Step 1: Run unit tests**

Run: `zig build test --summary all`
Expected: PASS for every test in `src/`, including all newly added tests from Tasks 1–6.

- [ ] **Step 2: Run integration tests**

Run: `zig build test-integration --summary all`
Expected: PASS — particularly the existing `tests/integration_sharded.zig` `"concurrent writers across shards make forward progress (smoke)"` test, which now runs on the new shared-pool plumbing.

- [ ] **Step 3: Run sharded integration tests**

Run: `zig build test-integration-sharded --summary all`
Expected: PASS.

- [ ] **Step 4: Run cross-shard recovery tests**

Run: `zig build test-cross-shard-recovery --summary all`
Expected: PASS — exercises the 2PC paths which run on top of the same `GraphEngine` instances and therefore the new pool.

- [ ] **Step 5: Run fuzz regressions**

Run: `zig build test-fuzz-regression --summary all`
Expected: PASS.

- [ ] **Step 6: If everything is green, no commit needed**

This task is verification only; do not commit if no files changed. If a test was unexpectedly red and required a fix, commit the fix separately as `fix(...): <root-cause>` rather than amending Task 1–6 commits.

---

## Out of scope for this plan

These items are explicitly deferred per the source design's §10 (Rollout) and §11 (Out of scope):

- **Geode-side adoption** (Phase 2). The geode call-sites at `src/storage/graph_storage_adapter.zig:3140` and `:3208` are tracked separately in `geode/docs/performance/2026-04-25-shared-stream-pool/upstream-handoff.md`. Land this plan first; geode picks up the API in a follow-up.
- **Removing the owned-pool path** (Phase 3). The owned-pool default stays for embedded users; deprecation is at least one release away.
- **Tuning `flushAllParallel` itself.** The bug is pool ownership, not the work pattern. `MAX_CHUNKS = 64` and the `submitBatch` + `WaitGroup` shape are correct.
- **Lifting `max_threads = 4` higher.** Risk row #1 in §9 reserves "raise default to 8" as a documented escape hatch if benchmarks show regression. Do not preempt that — measure first.
