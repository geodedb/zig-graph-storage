# Gap Analysis Resolved

GitLab issues are the authoritative record for requirements and gaps. This file mirrors the non-open gap IDs moved out of `docs/GAP_ANALYSIS.md` during the 2026-04-07 re-audit.

`GAP-0002`, `GAP-0017`, `GAP-0018`, `GAP-0023`, `GAP-0025`, `GAP-0027`, `GAP-0030`, `GAP-0031`, `GAP-0032`, and `GAP-0033` remain open.

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
