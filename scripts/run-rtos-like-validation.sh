#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./scripts/run-rtos-like-validation.sh [duration_sec] [rt_cpu] [out_dir]

Runs cyclictest on RT CPU while generating heavy load on non-RT CPUs.
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
OUT_FILE="$OUT_DIR/rtos_like_validation_${TS}.md"

mkdir -p "$OUT_DIR"

if ! command -v cyclictest >/dev/null 2>&1; then
  echo "cyclictest not found. Install: sudo apt-get update && sudo apt-get install -y rt-tests"
  exit 1
fi

TOTAL=$(nproc)
NON_RT=()
for ((i=0;i<TOTAL;i++)); do
  [[ "$i" == "$RT_CPU" ]] && continue
  NON_RT+=("$i")
done
NON_RT_CSV=$(IFS=,; echo "${NON_RT[*]}")

LOAD_PIDS=()
cleanup() {
  for p in "${LOAD_PIDS[@]:-}"; do
    kill "$p" >/dev/null 2>&1 || true
  done
  sudo ./scripts/rtos-like-profile.sh revert >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo ./scripts/rtos-like-profile.sh apply --rt-cpu "$RT_CPU" >/dev/null

# Load non-RT cores using stress-ng if available, otherwise fallback to yes loops.
if command -v stress-ng >/dev/null 2>&1; then
  taskset -c "$NON_RT_CSV" stress-ng --cpu "${#NON_RT[@]}" --timeout "${DURATION}s" --metrics-brief >/tmp/rtos_stress_${TS}.log 2>&1 &
  LOAD_PIDS+=("$!")
else
  for cpu in "${NON_RT[@]}"; do
    taskset -c "$cpu" yes > /dev/null &
    LOAD_PIDS+=("$!")
  done
fi

RAW_OUT="$OUT_DIR/cyclictest_rtos_like_${TS}.txt"
sudo chrt -f 95 taskset -c "$RT_CPU" cyclictest \
  --mlockall \
  --priority=95 \
  --interval=1000 \
  --distance=0 \
  --threads=1 \
  --affinity="$RT_CPU" \
  --duration="$DURATION" \
  --quiet | tee "$RAW_OUT"

STATS=$(grep -E 'Min:.*Avg:.*Max:' "$RAW_OUT" | tail -1)
MIN_US=$(echo "$STATS" | awk '{for(i=1;i<=NF;i++) if($i=="Min:") print $(i+1)}')
AVG_US=$(echo "$STATS" | awk '{for(i=1;i<=NF;i++) if($i=="Avg:") print $(i+1)}')
MAX_US=$(echo "$STATS" | awk '{for(i=1;i<=NF;i++) if($i=="Max:") print $(i+1)}')

cat > "$OUT_FILE" <<REPORT
# RTOS-like Validation

- Timestamp: ${TS}
- Kernel: $(uname -r)
- RT CPU: ${RT_CPU}
- Non-RT CPUs: ${NON_RT_CSV}
- Duration: ${DURATION}s

## cyclictest
- Min: ${MIN_US} us
- Avg: ${AVG_US} us
- Max: ${MAX_US} us

## Raw Files
- ${RAW_OUT}
REPORT

cleanup
trap - EXIT

echo "Saved report: $OUT_FILE"
echo "Saved raw: $RAW_OUT"
