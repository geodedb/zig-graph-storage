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

- `baseline.json` -- the current accepted performance baseline
- `<short-sha>.json` -- results saved per commit via `make bench-save`

## Usage

```bash
make scale-bench       # Run benchmark, print results
make bench-save        # Run and save to results/<sha>.json
make bench-baseline    # Run and save as baseline
make bench-compare     # Run and compare against baseline
```
