# Gap Analysis -- Requirements & Implementation

**Last updated:** 2026-04-06 (gap closure pass)
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 22 |
| Won't Do | 1 |
| Blocked | 1 |
| Deferred | 6 |

---

## GAP-0001: CI pipeline has no build or test jobs

- **Status:** Closed
- **Severity:** Critical
- **Requirement:** NFR-MNT-002 (P0)
- **File:** `.gitlab-ci.yml`
- **Description:** `.gitlab-ci.yml` defines `build` and `test` stages but includes no jobs. Only security scans and format checks run.
- **Resolution:** `.gitlab-ci.yml` now has build, test-unit, test-integration, and zig-format jobs.
- **Affected Files:** `.gitlab-ci.yml`

## GAP-0002: Migration bulk-load is stubbed (P0 requirement)

- **Status:** Blocked
- **Severity:** Critical
- **Requirement:** FR-018 (P0)
- **File:** `src/migration.zig:129-141`
- **Description:** `migrate()` returns empty `MigrationResult{}` for all 4 storage states. Documented as blocked on Geode's binary serialization format reader.
- **Blocker:** Requires Geode's binary serialization format reader (external dependency)
- **Affected Files:** `src/migration.zig`

## GAP-0003: Manifest format_version never validated on open/recovery

- **Status:** Closed
- **Severity:** Medium
- **Requirement:** FR-019 (P1)
- **Acceptance Criteria:**
  - [x] `Recovery.recover()` validates `manifest.format_version` against `MANIFEST_VERSION`
  - [x] Returns `StorageError.IncompatibleVersion` on version mismatch
  - [x] Test covers version mismatch rejection
- **Resolution:** Added format_version check after manifest selection in `recovery.zig`. Added `IncompatibleVersion` to `StorageError`. Test writes manifest with version 999 and verifies rejection.
- **Commit:** `b4ddbf4`

## GAP-0004: No metrics/telemetry module

- **Status:** Closed
- **Severity:** Medium
- **Requirement:** NFR-OBS-001, NFR-OBS-002 (P1)
- **Description:** v1 library scope. Enterprise observability is a feature request requiring a new module, not a gap in existing functionality.
- **Resolution:** `metrics.zig` now exists with 17 counters. Remaining observability gaps are tracked as GAP-0016 (missing metric categories) and GAP-0017 (no structured event emission).

## GAP-0005: Crash recovery test suite incomplete

- **Status:** Closed
- **Severity:** High
- **Requirement:** NFR-MNT-002 (P0)
- **Acceptance Criteria:**
  - [x] Test: torn/truncated WAL record is safely skipped
  - [x] Test: manifest A corrupt, B valid -- recovery uses B
  - [x] Test: multiple concurrent transactions (some committed, some not)
  - [x] Test: recovery with many pages (>100)
- **Resolution:** Added 4 comprehensive recovery tests covering torn WAL records, manifest A/B failover, multi-transaction filtering, and 120-page recovery.
- **Commit:** `4c23097`

## GAP-0006: close() returns void, silently swallows errors

- **Status:** Closed
- **Severity:** High
- **Requirement:** NFR-REL-002 (P0)
- **Acceptance Criteria:**
  - [x] `close()` returns `!void`
  - [x] Checkpoint errors propagated
  - [x] Label dict save errors propagated
  - [x] Interface vtable updated
  - [x] Tests verify error propagation
- **Resolution:** Changed `close()` to `!void`, added `cleanupResources()` for guaranteed cleanup, updated vtable signature.
- **Commit:** `3d201a2`

## GAP-0007: Example is a stub referencing non-existent API

- **Status:** Closed
- **Severity:** Low
- **Resolution:** Replaced stub with full working example demonstrating all major API operations. Added `run-example` build step.
- **Commit:** `ae73baf`

## GAP-0008: README claims "Zero Dependencies" (has 2)

- **Status:** Closed
- **Severity:** Low
- **Acceptance Criteria:**
  - [x] README accurately describes dependencies
  - [x] Quick Start snippet uses actual API
  - [x] Feature list is accurate
- **Resolution:** Updated feature list to show "Minimal Dependencies" with links. Replaced fake Quick Start with working `GraphEngine.create()` example.
- **Commit:** `c752f9a`

## GAP-0009: No benchmark harness

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Created `benchmarks/bench.zig` with 8 benchmarks: node insert, edge insert, property write/read, expandOut, scanLabel, checkpoint, cold start. Runnable via `zig build bench` or `make bench`.
- **Commit:** `92035ff`

## GAP-0010: SECURITY.md references GitHub (project is on GitLab)

- **Status:** Closed
- **Severity:** Low
- **Acceptance Criteria:**
  - [x] SECURITY.md references GitLab instead of GitHub
- **Resolution:** Changed "GitHub" to "GitLab" in SECURITY.md.
- **Commit:** `280737b`

---

## GAP-0011: `spice` dependency missing — no parallelism framework

- **Status:** Closed
- **Severity:** Critical
- **Requirement:** Parallelism must use the `spice` heartbeat-scheduling library (devnw/zig/spice)
- **Description:** The `spice` library (`gitlab.com/devnw/zig/spice`) provides a fork/join thread pool with sub-nanosecond overhead via heartbeat scheduling. It is the designated parallelism framework for this project but is not declared in `build.zig.zon` and is not imported anywhere in the codebase. All current concurrency uses raw `std.Thread` primitives instead.
- **Affected Files:** `build.zig.zon`, `build.zig`
- **Acceptance Criteria:**
  - [x] `spice` added as a dependency in `build.zig.zon`
  - [x] `spice` module exposed via `build.zig` (`b.dependency("spice", ...).module("spice")`)
  - [x] Source files that need parallelism import `spice` instead of raw `std.Thread`
- **Resolution:** Added `spice` as a path dependency in `build.zig.zon`, wired the module through `build.zig` into the main library, unit test, and check targets. `buffer_pool.zig` and `engine.zig` now import and use `spice`.

## GAP-0012: Buffer pool uses raw `std.Thread.Mutex` instead of `spice` ThreadPool

- **Status:** Closed
- **Severity:** High
- **Requirement:** Parallelism via `spice`
- **File:** `src/buffer_pool.zig`
- **Description:** `BufferPool` protects concurrent access with a single coarse-grained `std.Thread.Mutex`. This serializes all page pin/unpin/flush operations. With `spice`, dirty page flushes (`flushDirty`, `flushDirtyPages`) could be parallelized using fork/join over the dirty page set, and the I/O window (where the mutex is already temporarily released at lines 276-284) could leverage the thread pool for concurrent `pwriteAll`/`preadAll` calls.
- **Affected Files:** `src/buffer_pool.zig`, `src/engine.zig`
- **Acceptance Criteria:**
  - [x] `BufferPool` accepts a `*spice.ThreadPool` (or optional pointer) via `setThreadPool()`
  - [x] `flushAll()` uses `spice` fork/join to flush pages in parallel when thread pool is set
  - [x] Single-page pin/unpin remains mutex-protected (correctness requirement)
  - [x] Sequential fallback when no thread pool is attached (sub-ns overhead by spice design)
- **Resolution:** Added optional `thread_pool` field to `BufferPool` with `setThreadPool()` method. `flushAll()` uses a parallel path when thread pool is set: collects dirty frames under mutex, copies page data, releases mutex, writes pages concurrently via recursive divide-and-conquer fork/join (`FlushRange`/`parallelFlushFn`), then re-acquires mutex to unpin and handle errors. `GraphEngine` owns and manages a `spice.ThreadPool` lifecycle (init/start in `create()`/`open()`, deinit in `deinit()`/`cleanupResources()`).

## GAP-0013: Checkpoint background thread uses raw `std.Thread.spawn` + detach

- **Status:** Closed
- **Severity:** High
- **Requirement:** Parallelism via `spice`
- **File:** `src/checkpoint.zig`
- **Description:** `Checkpointer.run()` spawned a detached `std.Thread` for background checkpoints. This was fire-and-forget with no join handle. The engine already avoided this path (calling `doCheckpoint()` synchronously) due to write-loss concerns.
- **Affected Files:** `src/checkpoint.zig`, `src/engine.zig`
- **Acceptance Criteria:**
  - [x] Remove `std.Thread.spawn`/`detach` from `Checkpointer`
  - [x] Remove the dead `run()` / `backgroundRun()` code entirely (synchronous-only design)
  - [x] Remove `is_running` atomic field (no longer needed)
  - [x] Update tests to use `doCheckpoint()` directly
- **Resolution:** Removed `run()`, `backgroundRun()`, and `is_running` atomic field from `Checkpointer`. Updated checkpoint tests to call `doCheckpoint()` directly instead of `run()` + spin-wait. Synchronous checkpoint is the intentional design.

## GAP-0014: Transaction ID generation uses raw mutex instead of atomic increment

- **Status:** Won't Do
- **Severity:** Medium
- **Requirement:** Concurrency correctness
- **File:** `src/txn.zig:22, 46-49`
- **Description:** `TxnManager.begin()` uses `txn_id_mutex` to protect the transaction ID increment. While `@atomicRmw(.Add, ...)` would be simpler, commit `516140e` deliberately replaced an earlier `std.atomic.Value(u64)` with a mutex for 32-bit ARM compatibility — atomic u64 operations are not available on all target architectures. The mutex approach is correct and portable.
- **Resolution:** The current mutex-based implementation was an intentional fix for 32-bit ARM support. Reverting to atomics would break cross-platform compatibility.

## GAP-0015: Busy-wait spin loops for checkpoint completion

- **Status:** Closed
- **Severity:** Medium
- **Requirement:** NFR-REL-002, efficient shutdown
- **File:** `src/engine.zig`
- **Description:** `deinit()` and `cleanupResources()` previously spin-looped with `std.Thread.sleep(1ms)` waiting for `checkpointer.is_running` to become false.
- **Affected Files:** `src/engine.zig`
- **Acceptance Criteria:**
  - [x] Remove spin loops (no longer needed since checkpoint is synchronous-only)
  - [x] No `std.Thread.sleep` calls remain for synchronization purposes
  - [x] Shutdown is deterministic (no polling delay)
- **Resolution:** Removed both `while(is_running) sleep` loops from `deinit()` and `cleanupResources()`. With GAP-0013's removal of background checkpoint threading, these spin loops were dead code — `doCheckpoint()` runs synchronously and completes before shutdown proceeds.

---

## GAP-0016: Missing metrics for fragmentation, index progress, recovery duration, WAL growth

- **Status:** Closed
- **Severity:** Medium
- **Requirement:** NFR-OBS-001
- **Description:** `metrics.zig` has 17 counters but 4 of 7 required metric categories are absent: fragmentation ratio, index rebuild progress, recovery duration, and WAL segment growth.
- **Effort:** S
- **Affected Files:** `src/metrics.zig`
- **Resolution:** Added 4 new metric counters covering fragmentation ratio, index rebuild progress, recovery duration, and WAL segment growth.

## GAP-0017: No structured event emission

- **Status:** Closed
- **Severity:** Medium
- **Requirement:** NFR-OBS-002
- **Description:** `config.zig:20` has a `log_fn` callback but it is never invoked. No structured events are emitted for checkpoint, recovery, backup, verify, or migration operations.
- **Effort:** M
- **Affected Files:** `src/config.zig`
- **Resolution:** Added `StorageEvent` tagged union and `emitEvent()` method. Structured events now emitted for checkpoint, recovery, backup, verify, and migration operations.

## GAP-0018: No read-only legacy fallback mode

- **Status:** Closed
- **Severity:** High
- **Requirement:** FR-019
- **Description:** V1 manifests are rejected with `IncompatibleVersion`. There is no `LegacyPolicy` enum or read-only open mode to allow fallback access to older format data.
- **Effort:** M
- **Affected Files:** `src/recovery.zig`, `src/engine.zig`
- **Resolution:** Added `LegacyPolicy` enum with read-only fallback mode. V1 manifests can now be opened in read-only mode when legacy policy is configured.

## GAP-0019: No operational documentation (runbooks, upgrade guides, key management)

- **Status:** Closed
- **Severity:** Medium
- **Requirement:** NFR-CMP-001
- **Description:** No runbooks, upgrade guides, or key management documentation exists. Operators have no reference for day-to-day administration tasks.
- **Effort:** M
- **Affected Files:** `docs/`
- **Resolution:** Created `docs/operations.md` with runbooks, upgrade guides, and key management documentation.

## GAP-0020: B+tree index is in-memory only, not persisted to pages

- **Status:** Closed
- **Severity:** High
- **Requirement:** FR-016, FR-017
- **Description:** `btree.zig` has no serialize/persist logic. Page types `btree_internal` and `btree_leaf` are defined but unused. The B+tree index is rebuilt from scratch on every open.
- **Effort:** L
- **Affected Files:** `src/btree.zig`
- **Resolution:** Added `serialize`/`deserialize` methods for flat binary snapshot of all leaf entries, plus `saveToFile`/`loadFromFile` with magic+version+CRC32 envelope. Internal nodes are rebuilt from sorted leaf data on load. The `PropertyChainIndex` (which is what the engine actually persists for property lookups) already had its own save/load, so no additional engine wiring was needed. The B+tree persistence is ready for when `PropertyIndex`/`IndexCatalog` are wired into the engine checkpoint path.

## GAP-0021: getEdge() always returns error.EdgeIndexNotImplemented

- **Status:** Closed
- **Severity:** High
- **Requirement:** FR-003, FR-008
- **Description:** `getEdge()` always returns `error.EdgeIndexNotImplemented`. No edge-ID index exists; edge lookups by ID are non-functional.
- **Effort:** L
- **Affected Files:** `src/engine.zig`
- **Resolution:** `getEdge()` now uses `self.edge_index.get(edge_id)` via AutoHashMap and returns a proper `EdgeEntry`. No `EdgeIndexNotImplemented` error remains. See `src/engine.zig:480-488`.

## GAP-0022: Per-mutation auto-commit generates excessive WAL traffic

- **Status:** Deferred
- **Severity:** Medium
- **Requirement:** FR-012
- **Description:** Per-mutation auto-commit generates excessive WAL traffic. No multi-operation transaction API exists. Each single mutation produces 3+ WAL records.
- **Effort:** M
- **Affected Files:** `src/txn.zig`, `src/engine.zig`
- **Deferral Reason:** Multi-operation transaction API requires its own branch. Involves transaction batching, rollback support, and WAL protocol changes.

## GAP-0023: No extension mechanism for specialized index types

- **Status:** Deferred
- **Severity:** Low
- **Requirement:** FR-021
- **Description:** `IndexType` is a fixed closed enum. There is no extension mechanism for registering or loading specialized index types.
- **Effort:** M
- **Affected Files:** `src/btree.zig`
- **Deferral Reason:** Post-v1 feature. Index extension points require API design for plugin registration and stable ABI considerations.

## GAP-0024: CI fuzz stage declared but has no jobs

- **Status:** Closed
- **Severity:** Low
- **Requirement:** NFR-MNT-002
- **Description:** CI fuzz stage is declared in `.gitlab-ci.yml` but contains no jobs. Fuzz testing is not executed.
- **Effort:** S
- **Affected Files:** `.gitlab-ci.yml`
- **Resolution:** Added fuzz job to CI pipeline in `.gitlab-ci.yml`.

## GAP-0025: No structured CLI/API output layer (JSON)

- **Status:** Closed
- **Severity:** Low
- **Requirement:** NFR-ACC-001
- **Description:** Result structs exist but have no serialization support. There is no structured output layer (e.g., JSON) for CLI or API consumers.
- **Effort:** S
- **Affected Files:** `src/`
- **Resolution:** Added `writeJson` methods to result structs for structured JSON output.

---

## GAP-0026: 3 metrics counters never wired

- **Status:** Closed / Implemented
- **Severity:** Medium
- **Requirement:** NFR-OBS-001
- **Category:** Observability
- **Description:** `wal_segment_count`, `fragmentation_ratio`, and `index_rebuild_progress` were declared in `src/metrics.zig` but never populated by any subsystem.
- **Resolution:** Wired all three metrics counters: `wal_segment_count` populated by WAL manager during segment tracking, `fragmentation_ratio` populated by FreeSpaceManager, `index_rebuild_progress` populated during index catalog rebuild. TODO comments removed.
- **Evidence:** Commit `1bed851` (feat: close GAP-0026). Files: `src/metrics.zig`, `src/wal.zig`, `src/free_space.zig`, `src/engine_index.zig`.
- **Effort:** S
- **Affected Files:** `src/metrics.zig`, `src/wal.zig`, `src/free_space.zig`, `src/engine_index.zig`

## GAP-0027: B+tree not integrated into engine query/checkpoint path

- **Status:** Deferred
- **Severity:** Medium
- **Requirement:** FR-016, FR-017
- **Category:** Feature
- **Description:** `btree.zig` implements a full B+tree with serialize/deserialize support (GAP-0020), but it is never imported in `engine.zig`. The engine uses `PropertyChainIndex` for property lookups instead. `IndexCatalog` is not wired into the checkpoint or recovery path.
- **Current state (evidence):**
  - `src/engine.zig` -- no `@import("btree.zig")` found
  - `src/engine.zig` -- `PropertyChainIndex` used for all property lookups
  - Checkpoint path does not call `IndexCatalog.save()` or `btree.saveToFile()`
- **Why this is a gap:** FR-016 (range queries) and FR-017 (composite indexes) require B+tree integration. The B+tree is implemented and can persist, but is not reachable from the engine.
- **Impact/Risk:** Range queries and composite index lookups are not available through the engine API. The B+tree implementation is dead code from the engine's perspective.
- **Recommended fix:** Import `btree.zig` in `engine.zig`, wire `IndexCatalog` into checkpoint/recovery, and expose B+tree-backed queries via the engine API.
- **Effort:** L
- **Affected Files:** `src/engine.zig`, `src/btree.zig`, `src/checkpoint.zig`, `src/recovery.zig`
- **Deferral Reason:** Large feature requiring query path redesign. B+tree persistence is implemented (GAP-0020) but engine integration requires wiring IndexCatalog into checkpoint/recovery and exposing range-query APIs. Deferred to a dedicated branch.

## GAP-0028: Edge index not persisted (rebuilt on open)

- **Status:** Deferred
- **Severity:** Low
- **Requirement:** FR-003, FR-008
- **Category:** Performance
- **Description:** The in-memory edge index (`AutoHashMap`) has no save/load path. It is rebuilt from the adjacency store on every `open()` call, adding startup latency proportional to edge count.
- **Current state (evidence):**
  - `src/engine.zig:250-251` -- comment: `// Edge index is in-memory only (no persistence) so always rebuild` followed by `try self.rebuildEdgeIndex();`
- **Why this is a gap:** For large graphs, rebuilding the edge index on every open adds avoidable startup time. Other derived indexes (label index, property chain index) are persisted and loaded from snapshots.
- **Impact/Risk:** Cold-start latency grows linearly with edge count. Acceptable for small datasets but problematic at scale.
- **Recommended fix:** Add `saveEdgeIndex()`/`loadEdgeIndex()` methods following the same pattern used by `PropertyChainIndex`. Persist during checkpoint, load during `open()`.
- **Effort:** M
- **Affected Files:** `src/engine.zig`
- **Deferral Reason:** Medium feature, not a correctness issue. Edge index rebuild on open is functionally correct; persistence is a startup-latency optimization. Deferred to post-v1.

## GAP-0029: 3 files over 800-line guideline

- **Status:** Deferred
- **Severity:** Low
- **Requirement:** Coding style guideline (800-line max)
- **Category:** Code Quality
- **Description:** Three source files exceed the 800-line coding style guideline.
- **Current state (evidence):**
  - `src/recovery.zig` -- 1183 lines
  - `src/prop_store.zig` -- 1147 lines
  - `src/backup.zig` -- 958 lines
- **Why this is a gap:** Large files increase cognitive load and make code review, navigation, and maintenance harder.
- **Impact/Risk:** Low immediate risk. Long-term maintenance burden.
- **Recommended fix:** Extract cohesive subsections into separate modules. For example, recovery test helpers, property encoding/decoding utilities, and backup verification logic could each become separate files.
- **Effort:** M
- **Affected Files:** `src/recovery.zig`, `src/prop_store.zig`, `src/backup.zig`
- **Deferral Reason:** Cosmetic refactor with no correctness or performance impact. Cross-references QUAL-0027. Deferred to post-v1.

## GAP-0030: Recovery two-pass loads entire WAL into memory

- **Status:** Deferred
- **Severity:** Low
- **Requirement:** NFR-PERF-001, NFR-PERF-004
- **Category:** Performance
- **Description:** `recovery.zig:164` calls `wal.readFrom(start_lsn, allocator)` which loads all WAL records from the checkpoint LSN forward into a single allocation. For large WAL backlogs this could cause significant memory pressure.
- **Current state (evidence):**
  - `src/recovery.zig:164` -- `const records = try wal.readFrom(start_lsn, self.allocator);`
  - Cross-reference: PERF-0014 (streaming WAL replay)
- **Why this is a gap:** NFR-PERF-001 targets bounded memory usage. Loading the entire WAL tail into memory violates this for crash recovery after long checkpoint intervals.
- **Impact/Risk:** Memory spike during recovery proportional to WAL size since last checkpoint. Could cause OOM on memory-constrained systems with large WAL backlogs.
- **Recommended fix:** Implement streaming/chunked WAL replay that processes records in fixed-size batches rather than loading all at once. See PERF-0014 for detailed approach.
- **Effort:** M
- **Affected Files:** `src/recovery.zig`, `src/wal.zig`
- **Deferral Reason:** Same scope as PERF-0014 (streaming WAL replay). Requires significant refactor of WAL read path. Deferred to post-v1.
