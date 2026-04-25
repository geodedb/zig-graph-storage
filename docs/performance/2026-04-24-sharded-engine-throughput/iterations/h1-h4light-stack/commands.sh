#!/usr/bin/env bash
# Baseline reproduction script — sharded engine throughput bench.
# Host: lothiriel (Intel Xeon E5-2680 v4, 28C/56T, governor=schedutil).
#
# Produced: 2026-04-24
# Git SHA:  0ce15769076d7c783c57d674e90182bc073853d1
#
# Protocol: 1 discarded warmup + 10 measured rounds. Each round is a
# fresh process invocation of the bench executable. Workload shape is
# preserved — no source edits to benchmarks/sharded_throughput.zig.
# Output is parsed from the bench's machine-readable stdout one-liners
# (SHARDED_THROUGHPUT / SINGLE_THROUGHPUT / SHARDING_SPEEDUP).

set -euo pipefail

REPO="/data/home/benji/src/devnw/zig/graph-storage"
BASELINE_DIR="$REPO/docs/performance/2026-04-24-sharded-engine-throughput/iterations/h1-h4light-stack"
RAW_DIR="$BASELINE_DIR/raw"
LOG_FILE="$BASELINE_DIR/run.log"

cd "$REPO"

mkdir -p "$RAW_DIR"
: > "$LOG_FILE"

{
  echo "=== Baseline run start: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "=== Host: $(hostname) ==="
  echo "=== Git SHA: $(git rev-parse HEAD) ==="
  echo "=== Zig version: $(zig version) ==="
} | tee -a "$LOG_FILE"

# Clean build — fresh artifacts.
rm -rf zig-out
zig build bench-sharded-throughput --help >/dev/null 2>&1 || true

run_round() {
  local tag="$1"
  local out="$2"
  local started ended log
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$started] starting $tag" | tee -a "$LOG_FILE"
  log=$(zig build bench-sharded-throughput 2>&1)
  ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local sharded_ns sharded_ops_s single_ns single_ops_s ratio
  sharded_ns=$(echo "$log" | awk '/^SHARDED_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^elapsed_ns=/) { sub(/elapsed_ns=/, "", $i); print $i } }')
  sharded_ops_s=$(echo "$log" | awk '/^SHARDED_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^ops_per_s=/) { sub(/ops_per_s=/, "", $i); print $i } }')
  single_ns=$(echo "$log" | awk '/^SINGLE_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^elapsed_ns=/) { sub(/elapsed_ns=/, "", $i); print $i } }')
  single_ops_s=$(echo "$log" | awk '/^SINGLE_THROUGHPUT/ { for (i=1; i<=NF; i++) if ($i ~ /^ops_per_s=/) { sub(/ops_per_s=/, "", $i); print $i } }')
  ratio=$(echo "$log" | awk '/^SHARDING_SPEEDUP/ { for (i=1; i<=NF; i++) if ($i ~ /^ratio=/) { sub(/ratio=/, "", $i); print $i } }')

  if [[ -z "${sharded_ns:-}" || -z "${single_ns:-}" || -z "${ratio:-}" ]]; then
    echo "[$ended] $tag PARSE_FAIL — bench output:" | tee -a "$LOG_FILE"
    echo "$log" | tee -a "$LOG_FILE"
    exit 2
  fi

  cat > "$out" <<JSON
{
  "tag": "$tag",
  "started_utc": "$started",
  "ended_utc": "$ended",
  "sharded_elapsed_ns": ${sharded_ns},
  "sharded_ops_per_s": ${sharded_ops_s},
  "single_elapsed_ns": ${single_ns},
  "single_ops_per_s": ${single_ops_s},
  "sharding_speedup_ratio": ${ratio}
}
JSON
  echo "[$ended] $tag sharded=${sharded_ns}ns single=${single_ns}ns ratio=${ratio}" | tee -a "$LOG_FILE"
}

# Warmup (discarded).
run_round "warmup" "$RAW_DIR/warmup.json"

# Measured rounds.
for i in $(seq -w 1 10); do
  run_round "round_$i" "$RAW_DIR/round_$i.json"
done

echo "=== BASELINE_DONE: $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$LOG_FILE"
