#!/usr/bin/env bash
# Baseline reproduction script — sharded engine throughput bench.
#
# Produced: 2026-04-24T19:28:25Z
# Git SHA:  db4d9ab21ea3c2ade9b72a842886ae6b56256c8c
# Host:     AMD Threadripper Pro 3955WX, 16c/32t, 256 GB, governor=performance, kernel 6.17.0-20
#
# Protocol: 1 discarded warmup + 10 measured rounds. Each round is a
# fresh process invocation of the bench executable (binary itself is
# cached by Zig after the first build).

set -euo pipefail

REPO="/home/benji/src/devnw/zig/graph-storage"
BASELINE_DIR="$REPO/docs/performance/2026-04-24-sharded-engine-throughput/baseline"
RAW_DIR="$BASELINE_DIR/raw"

cd "$REPO"

# Clean build of the bench exe.
rm -rf zig-out
zig build bench-sharded-throughput --help 2>&1 | head -1 || true  # no-op to warm build graph

mkdir -p "$RAW_DIR"

run_round() {
  local tag="$1"
  local out="$2"
  local log
  log=$(zig build bench-sharded-throughput 2>&1)
  local sharded_ns sharded_ops_s single_ns single_ops_s ratio
  sharded_ns=$(echo "$log" | awk '/^SHARDED_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^elapsed_ns=/) { sub(/elapsed_ns=/, "", $i); print $i } }')
  sharded_ops_s=$(echo "$log" | awk '/^SHARDED_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^ops_per_s=/) { sub(/ops_per_s=/, "", $i); print $i } }')
  single_ns=$(echo "$log" | awk '/^SINGLE_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^elapsed_ns=/) { sub(/elapsed_ns=/, "", $i); print $i } }')
  single_ops_s=$(echo "$log" | awk '/^SINGLE_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^ops_per_s=/) { sub(/ops_per_s=/, "", $i); print $i } }')
  ratio=$(echo "$log" | awk '/^SHARDING_SPEEDUP/ { for (i=1; i<=NF; i++) if ($i ~ /^ratio=/) { sub(/ratio=/, "", $i); print $i } }')
  cat > "$out" <<JSON
{
  "tag": "$tag",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sharded_elapsed_ns": ${sharded_ns},
  "sharded_ops_per_s": ${sharded_ops_s},
  "single_elapsed_ns": ${single_ns},
  "single_ops_per_s": ${single_ops_s},
  "sharding_speedup_ratio": ${ratio}
}
JSON
  echo "[$tag] sharded=${sharded_ns}ns single=${single_ns}ns ratio=${ratio}"
}

# Warmup (discarded).
run_round "warmup" "$RAW_DIR/warmup.json"

# Measured rounds.
for i in $(seq -w 1 10); do
  run_round "round_$i" "$RAW_DIR/round_$i.json"
done

echo "BASELINE_DONE"
