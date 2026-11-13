# Benchmark Results

This directory stores JSON benchmark results from `scale_bench.zig` for tracking performance over time.

## File Format

Each file is a JSON document with version, timestamp, system info, and per-tier metrics:

```json
{
  "version": 1,
  "timestamp": "2026-03-25T21:30:00Z",
  "git_commit": "abc1234",
  "system": { "os": "linux", "arch": "x86_64" },
  "page_size": 8192,
  "buffer_pool_pages": 4096,
  "tiers": [
    {
      "name": "1K",
      "node_count": 1000,
      "edge_count": 2100,
      "seed_ops_sec": 45000,
      "point_lookup_ns": 500,
      "prop_read_ns": 25000,
      "expand_out_ns": 20000,
      "label_scan_ns": 8000,
      "checkpoint_ms": 50,
      "open_ms": 30,
      "mixed_ops_sec": 1500000
    }
  ]
}
```

## Naming Convention

- `ci-baseline.json` -- authoritative merge-request and default-branch smoke baseline (`1K`)
- `ci-10k-baseline.json` -- authoritative scheduled/manual larger-tier baseline (`1K` + `10K`).
  Re-recorded at ff9d97f on a local ext4 NVMe disk (median-`mixed_ops_sec` run of
  three). Seed, checkpoint and mixed numbers are fsync-bound: record baselines on
  storage that really syncs, never on tmpfs or under eatmydata (the 2026-03-25
  baseline was, and no real disk could meet it).
- `baseline.json` -- local exploratory multi-tier baseline, not the CI source of truth
- `<short-sha>.json` -- results saved per commit via `make bench-save`

## Usage

```bash
make scale-bench       # Run benchmark, print results
make bench-save        # Run and save to results/<sha>.json
make bench-baseline    # Save the 1K CI smoke baseline
make bench-compare     # Compare the 1K CI smoke gate
make bench-baseline-10k  # Save the scheduled/manual 10K CI baseline
make bench-compare-10k   # Compare the scheduled/manual 10K CI gate
# compare-bench gates on each measurement's median (p50); avg/p95/p99/stddev are info.
```
