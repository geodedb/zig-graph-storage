# Gap Analysis -- Resolved

**Last updated:** 2026-04-06
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

> Items in this file have been closed or invalidated. The platform issue tracker is authoritative.

---

### GAP-0001: CI pipeline has no build or test jobs [RESOLVED]

- **Issue:** Closed
- **Category:** CI-CD
- **Resolution:** `.gitlab-ci.yml` now has build, test-unit, test-integration, and zig-format jobs.
- **Evidence:** `.gitlab-ci.yml` contains complete job definitions.
- **Resolved date:** 2026-04-06

### GAP-0003: Manifest format_version never validated on open/recovery [RESOLVED]

- **Issue:** Closed
- **Category:** Bug
- **Resolution:** Added format_version check after manifest selection in `recovery.zig`. Added `IncompatibleVersion` to `StorageError`. Test covers version mismatch rejection.
- **Evidence:** Commit `b4ddbf4`.
- **Resolved date:** 2026-04-06

### GAP-0004: No metrics/telemetry module [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** `metrics.zig` now exists with 17 counters. Remaining observability gaps tracked as GAP-0016 and GAP-0017.
- **Evidence:** `src/metrics.zig` exists with counter definitions.
- **Resolved date:** 2026-04-06

### GAP-0005: Crash recovery test suite incomplete [RESOLVED]

- **Issue:** Closed
- **Category:** Test
- **Resolution:** Added 4 comprehensive recovery tests covering torn WAL records, manifest A/B failover, multi-transaction filtering, and 120-page recovery.
- **Evidence:** Commit `4c23097`.
- **Resolved date:** 2026-04-06

### GAP-0006: close() returns void, silently swallows errors [RESOLVED]

- **Issue:** Closed
- **Category:** Bug
- **Resolution:** Changed `close()` to `!void`, added `cleanupResources()` for guaranteed cleanup, updated vtable signature.
- **Evidence:** Commit `3d201a2`.
- **Resolved date:** 2026-04-06

### GAP-0007: Example is a stub referencing non-existent API [RESOLVED]

- **Issue:** Closed
- **Category:** Docs
- **Resolution:** Replaced stub with full working example demonstrating all major API operations. Added `run-example` build step.
- **Evidence:** Commit `ae73baf`.
- **Resolved date:** 2026-04-06

### GAP-0008: README claims "Zero Dependencies" (has 2) [RESOLVED]

- **Issue:** Closed
- **Category:** Docs
- **Resolution:** Updated feature list to show "Minimal Dependencies" with links. Replaced fake Quick Start with working example.
- **Evidence:** Commit `c752f9a`.
- **Resolved date:** 2026-04-06

### GAP-0009: No benchmark harness [RESOLVED]

- **Issue:** Closed
- **Category:** Performance
- **Resolution:** Created `benchmarks/bench.zig` with 8 benchmarks. Runnable via `zig build bench` or `make bench`.
- **Evidence:** Commit `92035ff`.
- **Resolved date:** 2026-04-06

### GAP-0010: SECURITY.md references GitHub (project is on GitLab) [RESOLVED]

- **Issue:** Closed
- **Category:** Docs
- **Resolution:** Changed "GitHub" to "GitLab" in SECURITY.md.
- **Evidence:** Commit `280737b`.
- **Resolved date:** 2026-04-06

### GAP-0011: `spice` dependency missing -- no parallelism framework [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** Added `spice` as a path dependency in `build.zig.zon`, wired the module through `build.zig`. `buffer_pool.zig` and `engine.zig` now import and use `spice`.
- **Evidence:** `build.zig.zon` and `build.zig` contain spice dependency; `src/buffer_pool.zig` and `src/engine.zig` import spice.
- **Resolved date:** 2026-04-06

### GAP-0012: Buffer pool uses raw `std.Thread.Mutex` instead of `spice` ThreadPool [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** Added optional `thread_pool` field to `BufferPool` with `setThreadPool()` method. `flushAll()` uses parallel path when thread pool is set.
- **Evidence:** `src/buffer_pool.zig` contains `FlushRange`/`parallelFlushFn` fork/join implementation.
- **Resolved date:** 2026-04-06

### GAP-0013: Checkpoint background thread uses raw `std.Thread.spawn` + detach [RESOLVED]

- **Issue:** Closed
- **Category:** Bug
- **Resolution:** Removed `run()`, `backgroundRun()`, and `is_running` atomic field from `Checkpointer`. Synchronous checkpoint is the intentional design.
- **Evidence:** `src/checkpoint.zig` no longer contains `std.Thread.spawn`.
- **Resolved date:** 2026-04-06

### GAP-0014: Transaction ID generation uses raw mutex instead of atomic increment [WON'T DO]

- **Issue:** Closed (Won't Do)
- **Category:** Code Quality
- **Resolution:** The current mutex-based implementation was an intentional fix for 32-bit ARM support (commit `516140e`). Reverting to atomics would break cross-platform compatibility.
- **Resolved date:** 2026-04-06

### GAP-0015: Busy-wait spin loops for checkpoint completion [RESOLVED]

- **Issue:** Closed
- **Category:** Bug
- **Resolution:** Removed both `while(is_running) sleep` loops from `deinit()` and `cleanupResources()`. With GAP-0013's removal of background checkpoint threading, these were dead code.
- **Evidence:** `src/engine.zig` no longer contains `std.Thread.sleep` calls for synchronization.
- **Resolved date:** 2026-04-06

### GAP-0016: Missing metrics for fragmentation, index progress, recovery duration, WAL growth [RESOLVED]

- **Issue:** Closed
- **Category:** Observability
- **Resolution:** Added 4 new metric counters covering fragmentation ratio, index rebuild progress, recovery duration, and WAL segment growth.
- **Evidence:** `src/metrics.zig` contains `fragmentation_ratio`, `index_rebuild_progress`, `recovery_duration_ns`, `wal_segment_count` fields.
- **Resolved date:** 2026-04-06

### GAP-0017: No structured event emission [RESOLVED]

- **Issue:** Closed
- **Category:** Observability
- **Resolution:** Added `StorageEvent` tagged union and `emitEvent()` method. Structured events now emitted for checkpoint, recovery, backup, verify, and migration operations.
- **Evidence:** `src/config.zig` contains `StorageEvent` definition.
- **Resolved date:** 2026-04-06

### GAP-0018: No read-only legacy fallback mode [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** Added `LegacyPolicy` enum with read-only fallback mode. V1 manifests can now be opened in read-only mode when legacy policy is configured.
- **Evidence:** `src/recovery.zig` and `src/engine.zig` contain `LegacyPolicy` handling.
- **Resolved date:** 2026-04-06

### GAP-0019: No operational documentation [RESOLVED]

- **Issue:** Closed
- **Category:** Docs
- **Resolution:** Created `docs/operations.md` with runbooks, upgrade guides, and key management documentation.
- **Evidence:** `docs/operations.md` exists.
- **Resolved date:** 2026-04-06

### GAP-0020: B+tree index is in-memory only, not persisted to pages [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** Added `serialize`/`deserialize` methods for flat binary snapshot, plus `saveToFile`/`loadFromFile` with magic+version+CRC32 envelope. Internal nodes rebuilt from sorted leaf data on load.
- **Evidence:** `src/btree.zig` contains `serialize`, `deserialize`, `saveToFile`, `loadFromFile` methods.
- **Resolved date:** 2026-04-06

### GAP-0021: getEdge() always returns error.EdgeIndexNotImplemented [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** `getEdge()` now uses `self.edge_index.get(edge_id)` via AutoHashMap and returns a proper `EdgeEntry`. No `EdgeIndexNotImplemented` error remains.
- **Evidence:** `src/engine.zig:480-488` -- `getEdge()` calls `self.edge_index.get(edge_id)` and returns structured `EdgeEntry`.
- **Resolved date:** 2026-04-06

### GAP-0024: CI fuzz stage declared but has no jobs [RESOLVED]

- **Issue:** Closed
- **Category:** CI-CD
- **Resolution:** Added fuzz job to CI pipeline in `.gitlab-ci.yml`.
- **Evidence:** `.gitlab-ci.yml` contains fuzz job definition.
- **Resolved date:** 2026-04-06

### GAP-0025: No structured CLI/API output layer (JSON) [RESOLVED]

- **Issue:** Closed
- **Category:** Feature
- **Resolution:** Added `writeJson` methods to result structs for structured JSON output.
- **Evidence:** Result structs in `src/` contain `writeJson` methods.
- **Resolved date:** 2026-04-06
