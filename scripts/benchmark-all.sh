#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./scripts/benchmark-all.sh [duration_sec] [rt_cpu] [out_dir]

Runs two tests on current kernel:
1) baseline (no RT profile)
2) profiled (rt-core-profile apply)

Outputs:
- CSV history: <out_dir>/benchmark_history.csv
- Markdown report: <out_dir>/benchmark_report_<timestamp>.md
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
CSV_FILE="$OUT_DIR/benchmark_history.csv"
REPORT_FILE="$OUT_DIR/benchmark_report_${TS}.md"

mkdir -p "$OUT_DIR"

if ! command -v cyclictest >/dev/null 2>&1; then
  echo "cyclictest not found. Install with: sudo apt-get update && sudo apt-get install -y rt-tests"
  exit 1
fi

if [[ ! -x ./scripts/rt-core-profile.sh || ! -x ./scripts/run-cyclictest.sh ]]; then
  echo "Run this script from repo root: /home/kim/linux-rt"
  exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "timestamp,kernel,hostname,rt_cpu,duration_s,mode,min_us,avg_us,max_us,result_file" > "$CSV_FILE"
fi

run_case() {
  local mode="$1"
  local output save_file stat_line min avg max

  output=$(./scripts/run-cyclictest.sh "$DURATION" "$RT_CPU" "$OUT_DIR")
  echo "$output" >&2

  save_file=$(echo "$output" | awk '/^Saved: /{print $2}' | tail -1)
  [[ -n "$save_file" && -f "$save_file" ]] || {
    echo "Failed to find result file for mode=$mode" >&2
    exit 1
  }

  stat_line=$(grep -E 'Min:.*Avg:.*Max:' "$save_file" | tail -1)
  [[ -n "$stat_line" ]] || {
    echo "Failed to parse cyclictest stats for mode=$mode" >&2
    exit 1
  }

  min=$(echo "$stat_line" | awk '{for(i=1;i<=NF;i++) if($i=="Min:") print $(i+1)}')
  avg=$(echo "$stat_line" | awk '{for(i=1;i<=NF;i++) if($i=="Avg:") print $(i+1)}')
  max=$(echo "$stat_line" | awk '{for(i=1;i<=NF;i++) if($i=="Max:") print $(i+1)}')

  echo "${TS},$(uname -r),$(hostname),${RT_CPU},${DURATION},${mode},${min},${avg},${max},${save_file}" >> "$CSV_FILE"

  echo "$mode,$min,$avg,$max,$save_file"
}

cleanup() {
  sudo ./scripts/rt-core-profile.sh revert >/dev/null 2>&1 || true
}
trap cleanup EXIT

BASELINE=$(run_case baseline)

sudo ./scripts/rt-core-profile.sh apply --rt-cpu "$RT_CPU" >/dev/null
PROFILED=$(run_case profiled)
sudo ./scripts/rt-core-profile.sh revert >/dev/null
trap - EXIT

base_min=$(echo "$BASELINE" | awk -F, '{print $2}')
base_avg=$(echo "$BASELINE" | awk -F, '{print $3}')
base_max=$(echo "$BASELINE" | awk -F, '{print $4}')
base_file=$(echo "$BASELINE" | awk -F, '{print $5}')

prof_min=$(echo "$PROFILED" | awk -F, '{print $2}')
prof_avg=$(echo "$PROFILED" | awk -F, '{print $3}')
prof_max=$(echo "$PROFILED" | awk -F, '{print $4}')
prof_file=$(echo "$PROFILED" | awk -F, '{print $5}')

all_best_max=$(awk -F, 'NR>1 && $9+0>0 {if(min=="" || $9+0<min) min=$9} END{if(min=="") print 0; else print min+0}' "$CSV_FILE")

cat > "$REPORT_FILE" <<REPORT
# RT Benchmark Report

- Timestamp: ${TS}
- Host: $(hostname)
- Kernel: $(uname -r)
- RT CPU: ${RT_CPU}
- Duration: ${DURATION}s

## Current Run

| Mode | Min (us) | Avg (us) | Max (us) |
|---|---:|---:|---:|
| baseline | ${base_min} | ${base_avg} | ${base_max} |
| profiled | ${prof_min} | ${prof_avg} | ${prof_max} |

## Files

- baseline raw: ${base_file}
- profiled raw: ${prof_file}
- history csv: ${CSV_FILE}

## Summary

- Max latency delta (profiled - baseline): $((prof_max - base_max)) us
- Best max latency seen in history: ${all_best_max} us
REPORT

echo "Saved report: $REPORT_FILE"
echo "Saved history: $CSV_FILE"
