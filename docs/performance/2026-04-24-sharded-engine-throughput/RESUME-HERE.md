# Resume here — `/bench-optimize` users

Quick pointer for anyone re-running `/bench-optimize:audit` or
`/bench-optimize:baseline` on this benchmark in a future session.

## TL;DR

- **Latest decision:** REVERT (2026-04-24). See [`optimize-report.md`](optimize-report.md).
- **Conclusion:** no source-only optimization in the allowed scope can clear
  the 5 % `target_gain_pct` on this bench. Per-shard worker isolation +
  `manual_sync=true` puts ≥ 98 % of wall in fsync; addressable surface is
  ≤ 2 % and cannot stack to a 5 % win.
- **Don't trust 10-round runs on this bench.** They produce false-positive
  ~4 % "wins" (see iteration 1 of `optimize-report.md` §6a) that disappear
  under tighter sampling (iteration 3 §6c, z<1).

## Canonical protocol (use for all future runs)

```bash
# 1 warmup + 30 measured rounds, single-socket pinned, governor=performance.
# Adapt the taskset mask for your host: lscpu --extended to map socket↔CPU.
bash baseline-host-lothiriel-30r-pinned/commands.sh
```

Median CI95 ≈ 3 % at n=30 — the bare minimum to detect ≥ 4 % real effects.

## What's in this directory

| Path | Status | What it is |
|------|--------|-----------|
| [`audit-notes.md`](audit-notes.md) | committed | Static audit at SHA `db4d9ab` (six required sections). Re-verify file:line citations before treating as current. |
| [`baseline/`](baseline/) | committed | Prior-host (Threadripper) 10-round baseline. Reference only — host-specific fsync characteristics. |
| [`baseline-host-lothiriel/`](baseline-host-lothiriel/) | this session | This-host 10-round baseline (preliminary). `attempt-1-schedutil-failed/` documents the variance-budget breach diagnosis. |
| [`baseline-host-lothiriel-30r-pinned/`](baseline-host-lothiriel-30r-pinned/) | this session | **Definitive baseline** — 30 rounds, socket-pinned, governor=performance. Use as the reference protocol. |
| [`iterations/h1-pin-once/`](iterations/h1-pin-once/) | this session | Iteration 1: h1 (pin-once in `addEdgeTxn`), 10 rounds. Apparent −4.4 % win was sampling fluctuation. |
| [`iterations/h1-h4light-stack/`](iterations/h1-h4light-stack/) | this session | Iteration 2: h1 + `fetchRemove` in `TxnManager.commit`, 10 rounds. Stack collapsed apparent gain to −1 %, the diagnostic tell. |
| [`iterations/h1-30r-pinned/`](iterations/h1-30r-pinned/) | this session | Iteration 3 (definitive): h1 alone, 30 rounds + socket-pinned. z-score 0.10–0.59 across drop policies — not significant. |
| [`optimize-report.md`](optimize-report.md) | this session | The 10-section session report (final decision: REVERT). |

## When to re-attempt

Re-iterate hypotheses **only** when one of these has moved:

1. `manual_sync = true` invariant in `src/wal.zig` is renegotiated.
2. The bench workload becomes multi-writer-per-shard (group-commit becomes a real lever).
3. Cross-shard 2PC traffic becomes the throughput target instead of per-shard isolated writes.
4. The spec's `target_gain_pct` is lowered to ≤ 2 % (the realistic ceiling under current constraints).

If none of those moved, you'll re-derive the same null result. Save the
compute and read [`optimize-report.md`](optimize-report.md) §10 instead.
