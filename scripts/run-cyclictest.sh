#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./scripts/run-cyclictest.sh [duration_sec] [rt_cpu] [out_dir]

Examples:
  ./scripts/run-cyclictest.sh
  ./scripts/run-cyclictest.sh 60 15
  ./scripts/run-cyclictest.sh 120 14 results
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DURATION="${1:-30}"
RT_CPU="${2:-15}"
OUT_DIR="${3:-results}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="$OUT_DIR/cyclictest_${TS}.txt"

mkdir -p "$OUT_DIR"

if ! command -v cyclictest >/dev/null 2>&1; then
  echo "cyclictest not found. Install with:"
  echo "  sudo apt-get update && sudo apt-get install -y rt-tests"
  exit 1
fi

echo "Running cyclictest for ${DURATION}s on CPU ${RT_CPU}"
sudo chrt -f 95 taskset -c "$RT_CPU" cyclictest \
  --mlockall \
  --priority=95 \
  --interval=1000 \
  --distance=0 \
  --threads=1 \
  --affinity="$RT_CPU" \
  --duration="$DURATION" \
  --quiet | tee "$OUT_FILE"

echo "Saved: $OUT_FILE"
grep -E "Min:|Avg:|Max:" "$OUT_FILE" || true
