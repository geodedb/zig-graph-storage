# Optimization Report — Sharded Graph Engine Throughput

- **Date:** 2026-04-24
- **Slug:** `sharded-engine-throughput`
- **Host:** lothiriel (Intel Xeon E5-2680 v4, 28C/56T, 256 GB, ext4, governor=performance for the duration of this work)
- **Git SHA at end:** `0ce15769076d7c783c57d674e90182bc073853d1`
- **Final decision:** **Revert.** No durable win available in the allowed scope on this workload.

> ## Future-pickup pointer (read first if re-attempting)
>
> If you're picking this up on another host or in a future session, **start here**:
>
> 1. **Re-audit:** the static audit at [`audit-notes.md`](audit-notes.md) is bytewise valid for any HEAD where `src/engine.zig` `addEdgeTxn` and `src/wal.zig` `manual_sync` haven't moved — re-verify the file:line citations there before treating it as current.
> 2. **Reproduce baseline using the canonical protocol:** [`baseline-host-lothiriel-30r-pinned/commands.sh`](baseline-host-lothiriel-30r-pinned/commands.sh) is the protocol template — 1 warmup + 30 measured rounds, `taskset -c 0-13,28-41` (single socket + HT), governor=performance. Adapt the taskset mask for your host's topology (`lscpu --extended` to map socket↔CPU). The 30-round protocol gives median CI95 ≈ 3 % on this bench, the bare minimum to detect ≥ 4 % effects cleanly. **10-round runs on this bench give false-positive ~4 % "wins" that vanish under tighter sampling — see iterations 1 vs 3 of this report.**
> 3. **Don't iterate hypotheses unless one of these has changed:**
>    - `manual_sync = true` invariant in `src/wal.zig` (audit §5.1)
>    - per-shard worker isolation in `benchmarks/sharded_throughput.zig` (no concurrent same-WAL commits)
>    - workload shape: per-op autocommit triplet (`allocNode + putNode + addEdge`)
>
>    Source-only optimizations of the addressable ≤ 2 % surface cannot, even stacked, clear the 5 % `target_gain_pct`. This is provable from the audit (≥ 98 % fsync) and was empirically confirmed in iteration 3 (h1 z-score 0.10–0.59 across all drop policies).
> 4. **The big lever requires authorization:** group-commit at the WAL layer (§10.1 below). Becomes unblocked the moment the workload supports concurrent same-WAL commits — cross-shard 2PC traffic, multi-writer-per-shard scenarios, or a workload reshape.
> 5. **Variance regime is host-specific.** This host's `/data` ext4 fsync is ~20× faster than the prior baseline host's, so absolute-time savings would scale with disk fsync latency on a different host. Conclusions about *what fraction of wall is addressable* (≤ 2 %) generalize; absolute milliseconds do not.

---

## 1. Target benchmark summary

- **Primary benchmark:** `zig build bench-sharded-throughput` (exe `sharded-throughput-bench`, `benchmarks/sharded_throughput.zig`, `.ReleaseFast` per `build.zig:167`).
- **Adjacent control:** `zig build bench-sharded-store` (`benchmarks/sharded_store_bench.zig`).
- **Measured code path** (citations re-verified at HEAD `0ce1576`; static audit at `db4d9ab` is bytewise valid since only docs + `.gitignore` changed): per-iteration triplet `allocNode → putNode → addEdge` against worker-private shard. Hot calls: `engine.zig:597 allocNode`, `:580 putNodeTxn` / `:588 putNode`, `:679 addEdgeTxn` / `:740 addEdge`. Each putNode and addEdge wraps a single-op autocommit txn → 1 fsync per op (`wal.zig:55 manual_sync=true`, `:99 sync`).
- **Goal metrics:** primary `sharded_elapsed_ns_median`. Gate `sharding_speedup_ratio_median ≥ 4.0` (spec). Adjacent guardrail: `bench-sharded-store` median.
- **Success thresholds:** `target_gain_pct = 5.0 %`, `max_regression_pct = −3.0 %`, `variance_policy = 5 %` stddev (compiled-micro).
- **Allowed scope:** `src/**/*.zig`. **Forbidden:** `tests/**`, `benchmarks/**` (except harness fix), `build.zig`, `build.zig.zon`, `docs/**`, `.github/**`, `.gitlab-ci.yml`.
- **Authorization not granted (correctness invariants per audit §5.1):** `manual_sync=true` change, commit batching, multi-op txn coalescing.
- **Hot paths (static rank from audit):** WAL fsync via `TxnManager.commit` ≫ `addEdgeTxn` page-log loop > `AdjStore.addEdge` chain growth > `BufferPool.pin/unpin` > `NodeStore.putNode` > manifest bumps > `edge_index.put`.

Full audit: [`audit-notes.md`](audit-notes.md).

---

## 2. Baseline commands and evidence

Two baselines were captured on this host; the 30-round + socket-pinned protocol is the **definitive** one used for accept/reject decisions. The 10-round baseline is preserved as historical evidence of the noise-floor diagnosis.

### 2a. 10-round baseline (preliminary; flagged variance breach)

- Commands: [`baseline-host-lothiriel/commands.sh`](baseline-host-lothiriel/commands.sh)
- Aggregate: [`baseline-host-lothiriel/baseline-aggregate.json`](baseline-host-lothiriel/baseline-aggregate.json)
- Raw rounds: [`baseline-host-lothiriel/raw/`](baseline-host-lothiriel/raw/)
- Host: [`baseline-host-lothiriel/host-state-before.json`](baseline-host-lothiriel/host-state-before.json) (governor=performance, no taskset)
- **Sharded median (drop-worst-2, n=8):** 2.254 s — stddev 4.44 %.
- **Single median (control):** 14.455 s — stddev 0.54 %.
- **Ratio median:** 6.45 (gate ≥ 4.0 ✅).
- **Status:** within budget after dropping rounds 01 & 03 as cold-ext4-journal outliers (audit §5.4).
- Attempt 1 (governor=schedutil, variance breach) archived under [`baseline-host-lothiriel/attempt-1-schedutil-failed/`](baseline-host-lothiriel/attempt-1-schedutil-failed/).

### 2b. 30-round + socket-pinned baseline (definitive)

- Commands: [`baseline-host-lothiriel-30r-pinned/commands.sh`](baseline-host-lothiriel-30r-pinned/commands.sh)
- Aggregate: [`baseline-host-lothiriel-30r-pinned/baseline-aggregate.json`](baseline-host-lothiriel-30r-pinned/baseline-aggregate.json)
- Raw rounds: [`baseline-host-lothiriel-30r-pinned/raw/`](baseline-host-lothiriel-30r-pinned/raw/)
- Host: [`baseline-host-lothiriel-30r-pinned/host-state-before.json`](baseline-host-lothiriel-30r-pinned/host-state-before.json) (governor=performance, `taskset -c 0-13,28-41`)
- **Sharded median (all 30):** 2.262 s — stddev 13.31 %, median CI95 3.04 %.
- **Single median (control, all 30):** 14.415 s — stddev 1.36 %, median CI95 0.31 %.
- **Ratio median:** 6.38 (gate ≥ 4.0 ✅).
- **Variance status:** above the 5 % stddev policy on the sharded path even with single-socket pinning. Median-CI95 of 3.04 % is the relevant signal-detection threshold for hypothesis comparison; a true ≥ 4 % effect would be detectable.
- **Noise diagnosis:** sharded-side variance is dominated by thermal/power-state drift on socket 0 during sustained 16-thread fsync load (visible round-by-round in rounds 14-24 of the raw set). Single-side variance is small (1.36 %) — confirms the noise is multi-thread coordination specific, not test-rig drift.

---

## 3. Ranked hypotheses

| # | Summary | Target files | Expected impact | Risk | Confidence | Status |
|---|---------|-------------|-----------------|------|------------|--------|
| h1 | Pin nodes-page once across `addEdgeTxn` | `src/engine.zig`, `src/node_store.zig` | 2 % | low | medium | **rejected** (no measurable effect under definitive protocol) |
| h2 | BufferPool atomic-CAS fast path on cache hit | `src/buffer_pool.zig` | 2.5 % | medium | medium | not exercised — the h1 result generalizes to all addressable micro-ops |
| h3 | Per-shard arena around WAL `appendRecord` | `src/wal.zig`, `src/engine.zig` | 1.5 % | low | medium | not exercised — same reason |
| h4 | `TxnManager.commit` autocommit fast path (full version) | `src/txn.zig`, `src/engine.zig` | 2 % | medium | medium | **rejected as part of stack** in iteration 2 (see §5) |
| h4-light | `fetchRemove` instead of `get + remove` in `commit()` | `src/txn.zig` | 0.5 % | low | high | **rejected as part of stack** in iteration 2 |
| h5 | Pre-size `edge_index` hashmap in `create()` path | `src/engine.zig` | 0.5 % | low | high | dropped from stack (config-knob change required for default-config bench) |

**Filtered before ranking** (rejection reasons in [`session.json`](.bench-optimize/session.json) `rejected_hypotheses[]`):

- *Group-commit fsync coalescing* — zero impact for this bench (per-shard worker isolation; no concurrent commits on same WAL).
- *Multi-op autocommit (triplet → single txn)* — workload-shape change, disqualifying.
- *`manual_sync=false`* — correctness-invariant violation.
- *Increase `buffer_pool_pages`* — bench working set ≈ 30-50 pages << 64 cap; no eviction pressure.

---

## 4. Changes made

**None merged.** Every accepted-into-iteration change was reverted. `git diff --stat HEAD` is empty in `src/` at end of session.

---

## 5. Validation run matrix

| Iter | Hypothesis | Rounds | Pinned | SHA | Raw | Result |
|------|-----------|--------|--------|-----|-----|--------|
| 1 | h1 alone | 10 | no | `0ce1576` | [`iterations/h1-pin-once/raw/`](iterations/h1-pin-once/raw/) | [`iterations/h1-pin-once/result.json`](iterations/h1-pin-once/result.json) |
| 2 | h1 + h4-light stack | 10 | no | `0ce1576` | [`iterations/h1-h4light-stack/raw/`](iterations/h1-h4light-stack/raw/) | [`iterations/h1-h4light-stack/result.json`](iterations/h1-h4light-stack/result.json) |
| 3 | h1 alone (definitive) | 30 | socket 0 | `0ce1576` | [`iterations/h1-30r-pinned/raw/`](iterations/h1-30r-pinned/raw/) | [`iterations/h1-30r-pinned/result.json`](iterations/h1-30r-pinned/result.json) |

All three iterations: 452/452 tests green across the 5 required suites (`zig build test`, `test-integration`, `test-integration-sharded`, `test-cross-shard-recovery`, `test-fuzz-regression`).

---

## 6. Before vs after metrics

Per the workflow, only medians are decision-grade. CI95 quoted for the definitive protocol so signal vs noise is explicit.

### 6a. Iteration 1 (h1 alone, 10 rounds, not pinned) — preliminary, later refuted

| Metric | Baseline median | h1 median | Δ % | Verdict |
|---|---|---|---|---|
| sharded_elapsed_ns (all-10) | 2.287 s | 2.188 s | −4.32 % | below 5 % target; **variance regressed** (stddev 9.10 % → 12.43 %) |
| sharded_elapsed_ns (drop-worst-2) | 2.254 s | 2.154 s | −4.40 % | below 5 % target; stddev 4.44 % → 5.63 % (over policy) |
| single_elapsed_ns (control, all-10) | 14.477 s | 14.624 s | +1.02 % | within −3 % guardrail (0.65 % stddev); likely noise |

Source: [`iterations/h1-pin-once/result.json`](iterations/h1-pin-once/result.json).

### 6b. Iteration 2 (h1 + h4-light stack, 10 rounds, not pinned)

| Metric | Baseline median | Stack median | Δ % | Verdict |
|---|---|---|---|---|
| sharded_elapsed_ns (all-10) | 2.287 s | 2.240 s | −2.04 % | below 5 % target |
| sharded_elapsed_ns (drop-worst-2) | 2.254 s | 2.231 s | −1.02 % | below 5 % target; stddev tightened to 2.28 % |
| single_elapsed_ns (control, all-10) | 14.477 s | 14.484 s | +0.05 % | within noise |

Source: [`iterations/h1-h4light-stack/result.json`](iterations/h1-h4light-stack/result.json). The stack producing a *smaller* gain than h1-alone was the diagnostic tell that h1-alone's −4.4 % was sampling fluctuation.

### 6c. Iteration 3 (h1 alone, 30 rounds, socket-pinned) — definitive

| Drop policy | n | Baseline median | h1 median | Δ % | z-score | p<0.05? |
|---|---|---|---|---|---|---|
| All-30 | 30 | 2.2620 s | 2.2509 s | −0.49 % | 0.10 | No |
| Drop-worst-4 | 26 | 2.2336 s | 2.2046 s | −1.30 % | 0.41 | No |
| Drop-worst-6 | 24 | 2.2206 s | 2.1911 s | −1.33 % | 0.51 | No |
| Drop-worst-8 | 22 | 2.2077 s | 2.1797 s | −1.27 % | 0.59 | No |
| Drop-worst-10 | 20 | 2.1946 s | 2.1747 s | −0.91 % | 0.50 | No |
| single (control, all-30) | 30 | 14.4155 s | 14.4012 s | −0.10 % | 0.24 | No |

z-score < 1 across every policy. **h1's effect is statistically indistinguishable from zero on this workload.** Source: [`iterations/h1-30r-pinned/result.json`](iterations/h1-30r-pinned/result.json).

---

## 7. Adjacent regression results

`bench-sharded-store` was named in `session.json.adjacent_benchmarks` for collateral monitoring. **Not exercised** in any iteration: every measured iteration showed the primary benchmark below threshold, so adjacent runs would not have changed the accept/reject decision and were not the productive use of compute. Single-engine path within `bench-sharded-throughput` served as a per-iteration in-bench control:

| Iter | Layer | Baseline median (single) | Candidate median (single) | Δ % | Verdict |
|------|-------|--------------------------|---------------------------|-----|---------|
| 1 | in-bench control (all-10) | 14.477 s | 14.624 s | +1.02 % | within −3 % guardrail (noise) |
| 2 | in-bench control (all-10) | 14.477 s | 14.484 s | +0.05 % | within noise |
| 3 | in-bench control (all-30) | 14.4155 s | 14.4012 s | −0.10 % | within noise (z=0.24) |

No adjacent regression observed. Single-engine path is unaffected by the addEdgeTxn / commit changes at any level distinguishable from noise.

---

## 8. Final decision

**Revert.**

All three iterations produced sub-threshold deltas. Iteration 3 under the tightened protocol (30 rounds, socket-pinned, governor=performance) gave a definitive answer: h1's true effect on this workload is < 1 % and not statistically significant (z<1 across every drop policy). The same conclusion generalizes to h2/h3/h4/h5 because the audit's static decomposition (≥ 98 % fsync, ≤ 2 % addressable per micro-opt) bounds them all in the same way.

**Stress follow-up:** skipped. No accepted change to stress-test. The standard 5-suite test gate ran 3 times (once per iteration) — 452/452 green each time, but those were correctness checks of the (subsequently reverted) candidate code, not stress runs of an accepted change.

**Why no win was found** (in plain language):

- ≥ 98 % of wall time is fsync, locked by `manual_sync=true` (correctness invariant).
- The remaining ≤ 2 % is allocator/HashMap/pin-count bookkeeping spread across the addEdge call chain.
- Source-only optimizations within that ≤ 2 % cannot, even stacked, clear a 5 % target.
- Group-commit doesn't apply: per-shard worker isolation means there are no concurrent fsyncs on the same WAL to coalesce.
- Workload reshape (multi-op txn, more N_OPS, different fan-in) was rejected as a workload-shape change.

**What this is *not*:** a regression report, a code-quality finding, or a recommendation to change the spec. The bench is correctly measuring what it was designed to measure, and ratio = 6.45 over the spec gate ≥ 4.0 confirms the sharded engine is delivering on its design promise (~6×). The optimization "no-win" finding is *about the engine's headroom under these constraints*, not about its current performance.

---

## 9. Files changed

**Empty in final accepted state.** `git diff HEAD --stat src/` shows no modifications. All in-flight changes from iterations 1, 2, 3 were reverted via `git checkout -- src/`.

Forbidden-scope touched: **none**. (Within iterations, source-side experimental changes touched only `src/engine.zig`, `src/node_store.zig`, `src/txn.zig` — all inside `allowed_paths`. None are present in the final tree.)

---

## 10. Remaining opportunities, risks, and rollback notes

### Remaining opportunities (not pursued; would require scope or workload changes)

1. **Group commit at the WAL layer.** Becomes the dominant lever the moment the workload supports concurrent commits on a single WAL — i.e., either (a) cross-shard 2PC traffic (currently exercised only by `tests/cross_shard_recovery.zig`, not the throughput bench), or (b) a future multi-writer-per-shard scenario. Implementation surface: `src/wal.zig` group-commit hook + a small `TxnManager` change. Expected: 50–150 % on workloads that exercise it. **Authorization gate from session: open.**

2. **Reshape the throughput bench to surface multi-op headroom.** Either: (a) add a multi-op autocommit path that accepts an `(allocNode, putNode, addEdge)` triplet and commits once (1 fsync vs 2), or (b) introduce concurrent writers per shard (driving WAL group-commit). Both change *what is measured*; the spec's current invariant is "every op is durable individually," and that's exactly what makes the bench fsync-bound. The spec author can authorize a workload-shape change if the question shifts from "can we make per-op durability faster" to "what's the engine's max practical throughput across realistic durability granularities."

3. **Tighter measurement protocol for future passes.** The 30-round + socket-pinned protocol developed in this session ([`baseline-host-lothiriel-30r-pinned/commands.sh`](baseline-host-lothiriel-30r-pinned/commands.sh)) gives median CI95 ≈ 3 % on this bench. Reusable as the canonical protocol for any future bench-optimize run on this code path.

### Risks

- **Variance regime is host-specific.** This host's `/data` ext4 has dramatically faster fsync than the prior baseline host (sharded median ~2.25 s vs ~43.5 s), making the optimization ceiling proportionally smaller in absolute terms. A slower-disk host would have a different addressable headroom; conclusions about *what fraction of wall is addressable* (≤ 2 %) generalize, but absolute time savings would scale with disk fsync latency.
- **Sharded-side variance is intrinsic to the 16-thread fan-out.** Any future bench-optimize run on this benchmark should expect per-round stddev ≥ 5 % on the sharded path even under tight protocol; rely on median CI from N≥30 rounds, not per-round stddev, for accept/reject.
- **The single-engine bench's stability is a useful in-bench control.** Use it (single_elapsed_ns delta) as a sanity check for any future iteration: a real shared-code-path change should affect it; a measurement artifact should not.

### Rollback notes

- **Source:** nothing to roll back. Tree is clean.
- **Governor:** restored to `schedutil` at end of session (was set to `performance` during the bench run for variance control). Restore command if needed in future:

  ```bash
  sudo bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo schedutil > "$f"; done'
  ```

- **Session state:** `.bench-optimize/session.json` is gitignored; not present in the tree. Already encodes the iteration history under `hypotheses[]` and `iteration_2_summary` for any future re-pickup. No action needed.
- **Pushed evidence:** the prior host's baseline at [`baseline-host-lothiriel/`](baseline-host-lothiriel/) and the prior-host audit at [`audit-notes.md`](audit-notes.md) (committed at SHA `0ce1576`) are intact. New evidence under [`baseline-host-lothiriel-30r-pinned/`](baseline-host-lothiriel-30r-pinned/) and [`iterations/`](iterations/) is currently uncommitted; commit if you want it preserved as durable evidence of this null-result session.
