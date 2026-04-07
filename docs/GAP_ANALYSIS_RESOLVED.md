# Gap Analysis Resolved

GitLab issues are the authoritative record for requirements and gaps. This file mirrors the non-open gap IDs moved out of `docs/GAP_ANALYSIS.md` during the 2026-04-07 re-audit.

`GAP-0002`, `GAP-0017`, `GAP-0018`, `GAP-0023`, `GAP-0025`, `GAP-0027`, `GAP-0031`, `GAP-0033`, `GAP-0038`, `GAP-0039`, `GAP-0042`, `GAP-0043`, and `GAP-0044` remain open.

## Resolved / Invalidated Gaps

### GAP-0001: CI pipeline has no build or test jobs
- **GitLab issue:** [#50](https://gitlab.com/devnw/zig/graph-storage/-/work_items/50)
- **Disposition:** Resolved
- **Resolution evidence:** The 2026-04-06 flatfile audit recorded the build/test job addition, and the current `.gitlab-ci.yml` no longer triggered a re-open during the 2026-04-07 re-audit.

### GAP-0003: Manifest format_version never validated on open/recovery
- **GitLab issue:** [#51](https://gitlab.com/devnw/zig/graph-storage/-/work_items/51)
- **Disposition:** Resolved
- **Resolution evidence:** `src/recovery.zig:112-126` now validates manifest format compatibility, matching the earlier flatfile closure.

### GAP-0004: No metrics/telemetry module
- **GitLab issue:** [#52](https://gitlab.com/devnw/zig/graph-storage/-/work_items/52)
- **Disposition:** Resolved
- **Resolution evidence:** `src/metrics.zig` exists and the remaining observability shortfall is narrower and tracked separately under open `GAP-0017`.

### GAP-0005: Crash recovery test suite incomplete
- **GitLab issue:** [#53](https://gitlab.com/devnw/zig/graph-storage/-/work_items/53)
- **Disposition:** Resolved
- **Resolution evidence:** The 2026-04-07 local run of `zig build test --summary all` and `zig build test-integration --summary all` passed, preserving the earlier recovery-coverage closure.

### GAP-0006: close() returns void, silently swallows errors
- **GitLab issue:** [#54](https://gitlab.com/devnw/zig/graph-storage/-/work_items/54)
- **Disposition:** Resolved
- **Resolution evidence:** `src/interface.zig:104-105` defines `close` as `anyerror!void`, so the public interface no longer swallows close-path errors.

### GAP-0007: Example is a stub referencing non-existent API
- **GitLab issue:** [#55](https://gitlab.com/devnw/zig/graph-storage/-/work_items/55)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 requirements re-audit found no evidence requiring a re-open.

### GAP-0008: README claims "Zero Dependencies" (has 2)
- **GitLab issue:** [#56](https://gitlab.com/devnw/zig/graph-storage/-/work_items/56)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 requirements re-audit found no evidence requiring a re-open.

### GAP-0009: No benchmark harness
- **GitLab issue:** [#57](https://gitlab.com/devnw/zig/graph-storage/-/work_items/57)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 requirements re-audit found no evidence requiring a re-open.

### GAP-0010: SECURITY.md references GitHub (project is on GitLab)
- **GitLab issue:** [#58](https://gitlab.com/devnw/zig/graph-storage/-/work_items/58)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 requirements re-audit found no evidence requiring a re-open.

### GAP-0011: `spice` dependency missing -- no parallelism framework
- **GitLab issue:** [#59](https://gitlab.com/devnw/zig/graph-storage/-/work_items/59)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the current build/runtime still include the `spice` integration that originally closed the item.

### GAP-0012: Buffer pool uses raw `std.Thread.Mutex` instead of `spice` ThreadPool
- **GitLab issue:** [#60](https://gitlab.com/devnw/zig/graph-storage/-/work_items/60)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 re-audit did not find evidence that required reopening the parallel-flush item.

### GAP-0013: Checkpoint background thread uses raw `std.Thread.spawn` + detach
- **GitLab issue:** [#61](https://gitlab.com/devnw/zig/graph-storage/-/work_items/61)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the current checkpoint design did not trigger a re-open.

### GAP-0014: Transaction ID generation uses raw mutex instead of atomic increment
- **GitLab issue:** [#62](https://gitlab.com/devnw/zig/graph-storage/-/work_items/62)
- **Disposition:** Won't Do
- **Resolution evidence:** The prior audit recorded the portability rationale for keeping mutex-based txn-id generation, and the 2026-04-07 re-audit found no requirement that overrode that decision.

### GAP-0015: Busy-wait spin loops for checkpoint completion
- **GitLab issue:** [#63](https://gitlab.com/devnw/zig/graph-storage/-/work_items/63)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 re-audit did not find evidence requiring a re-open.

### GAP-0016: Missing metrics for fragmentation, index progress, recovery duration, WAL growth
- **GitLab issue:** [#64](https://gitlab.com/devnw/zig/graph-storage/-/work_items/64)
- **Disposition:** Resolved
- **Resolution evidence:** The counters exist today, and the remaining gap is narrower engine-path/event wiring tracked under open `GAP-0017`.

### GAP-0019: No operational documentation
- **GitLab issue:** [#65](https://gitlab.com/devnw/zig/graph-storage/-/work_items/65)
- **Disposition:** Resolved
- **Resolution evidence:** `docs/operations.md` exists and was used as supporting evidence during the 2026-04-07 requirements re-audit.

### GAP-0020: B+tree index is in-memory only, not persisted to pages
- **GitLab issue:** [#66](https://gitlab.com/devnw/zig/graph-storage/-/work_items/66)
- **Disposition:** Resolved
- **Resolution evidence:** The standalone B+tree persistence work remained closed; the remaining unmet work is the separate engine-integration gap tracked under open `GAP-0027`.

### GAP-0021: getEdge() always returns error.EdgeIndexNotImplemented
- **GitLab issue:** [#67](https://gitlab.com/devnw/zig/graph-storage/-/work_items/67)
- **Disposition:** Resolved
- **Resolution evidence:** `src/engine.zig:508` and `src/engine_test.zig` show working `getEdge()` behavior, so the earlier functional gap stays closed.

### GAP-0022: Per-mutation auto-commit generates excessive WAL traffic
- **GitLab issue:** [#68](https://gitlab.com/devnw/zig/graph-storage/-/work_items/68)
- **Disposition:** Invalidated
- **Resolution evidence:** `src/interface.zig:95-97,169-176` and `src/engine.zig:461-474,485-503,542-603,654-719` already expose explicit transaction APIs; the 2026-04-07 re-audit concluded this is an optimization opportunity, not an unmet repository requirement.

### GAP-0024: CI fuzz stage declared but has no jobs
- **GitLab issue:** [#69](https://gitlab.com/devnw/zig/graph-storage/-/work_items/69)
- **Disposition:** Resolved
- **Resolution evidence:** The 2026-04-06 flatfile audit recorded the fuzz-job addition, and the 2026-04-07 requirements re-audit found no evidence requiring a re-open.

### GAP-0026: 3 metrics counters never wired
- **GitLab issue:** [#70](https://gitlab.com/devnw/zig/graph-storage/-/work_items/70)
- **Disposition:** Resolved
- **Resolution evidence:** This remained closed from the 2026-04-06 flatfile audit; the 2026-04-07 re-audit did not find evidence requiring a re-open.

### GAP-0028: Edge index not persisted (rebuilt on open)
- **GitLab issue:** [#71](https://gitlab.com/devnw/zig/graph-storage/-/work_items/71)
- **Disposition:** Invalidated
- **Resolution evidence:** `src/engine.zig:246-253` still rebuilds the in-memory edge index on open, but FR-003 and FR-008 are already satisfied; the 2026-04-07 re-audit classified this as a non-required startup-latency optimization.

### GAP-0029: 3 files over 800-line guideline
- **GitLab issue:** [#72](https://gitlab.com/devnw/zig/graph-storage/-/work_items/72)
- **Disposition:** Invalidated
- **Resolution evidence:** `wc -l src/recovery.zig src/prop_store.zig src/backup.zig` still reports large files, but `rg -n "800-line|coding style|line guideline|max lines" docs/storage-requirements.md docs/operations.md docs/format-spec.md README.md` returned no matches on 2026-04-07, so this is not a repository requirement gap.

### GAP-0030: Recovery loads the full WAL tail into memory
- **GitLab issue:** [#46](https://gitlab.com/devnw/zig/graph-storage/-/work_items/46)
- **Disposition:** Resolved
- **Resolution evidence:** `src/wal.zig:123-148` adds streaming replay via `forEachFrom()`, `src/recovery.zig:169-237` replays WAL records without materializing the full tail, and `src/recovery.zig` now includes the large-tail regression test `GAP-0030: recovery replays a large committed WAL tail`.

### GAP-0032: Graph UUID bindings are not validated during open, verify, or restore
- **GitLab issue:** [#48](https://gitlab.com/devnw/zig/graph-storage/-/work_items/48)
- **Disposition:** Resolved
- **Resolution evidence:** `src/recovery.zig:110-113`, `src/verify.zig:109-140`, `src/backup.zig:289-291`, and `src/wal.zig:166-185` now enforce graph UUID bindings across recovery, verify, restore, and WAL initialization, with regression coverage in `src/recovery.zig`, `src/verify.zig`, `src/backup.zig`, and `src/wal.zig`.

### GAP-0034: validateBackup accepts version-2 backups without an HMAC key
- **GitLab issue:** [#73](https://gitlab.com/devnw/zig/graph-storage/-/work_items/73)
- **Disposition:** Resolved
- **Resolution evidence:** `src/backup.zig:263-278` now fails closed when a version-2 backup requires HMAC validation but no key is configured, and `src/backup.zig:704-726` covers the rejection path.

### GAP-0035: free.store deserialization trusts total_pages and can allocate unbounded bitmap memory
- **GitLab issue:** [#74](https://gitlab.com/devnw/zig/graph-storage/-/work_items/74)
- **Disposition:** Resolved
- **Resolution evidence:** `src/free_space.zig:175-199` validates persisted counts before resizing the bitmap, `src/engine_persist.zig:109-118` rejects impossible metadata on load, and `src/free_space.zig:477-508` covers the bounded-deserialize cases.

### GAP-0036: AES-GCM page write counter saturates and can reuse nonces after u24 exhaustion
- **GitLab issue:** [#75](https://gitlab.com/devnw/zig/graph-storage/-/work_items/75)
- **Disposition:** Resolved
- **Resolution evidence:** `src/pager.zig:80-83` now returns `error.WriteCountExhausted` before nonce reuse can occur, and `src/pager.zig:352-369` verifies the saturation behavior.

### GAP-0037: createBackup buffers entire graph contents in memory
- **GitLab issue:** [#76](https://gitlab.com/devnw/zig/graph-storage/-/work_items/76)
- **Disposition:** Resolved
- **Resolution evidence:** `src/backup.zig:428-458` streams file payloads in chunks instead of materializing whole graph files, and `src/backup.zig:1073-1111` covers the large-file streaming path.

### GAP-0040: CI fuzz failures are suppressed and cannot block merges
- **GitLab issue:** [#79](https://gitlab.com/devnw/zig/graph-storage/-/work_items/79)
- **Disposition:** Resolved
- **Resolution evidence:** `build.zig:110-117` exposes `test-fuzz-regression`, `.gitlab-ci.yml:140-168` adds the non-optional `fuzz-regression` job, `tests/fuzz_regression.zig` provides deterministic coverage, and `zig build test-fuzz-regression --summary all` passed `3/3 tests` on 2026-04-07.

### GAP-0041: CI imports external components by tag instead of immutable commit pinning
- **GitLab issue:** [#80](https://gitlab.com/devnw/zig/graph-storage/-/work_items/80)
- **Disposition:** Won't Do
- **Resolution evidence:** `.gitlab-ci.yml:8-12` explicitly records that repo-local CI component SHA pinning stays out of scope while protected release tags are governed upstream, and `docs/SECURITY_REVIEW_NOTES.md:102` tells future audits not to reopen the item unless platform policy changes.
