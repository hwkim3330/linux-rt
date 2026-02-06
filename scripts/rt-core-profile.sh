#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/rt-core-profile"
STATE_FILE="$STATE_DIR/state.env"
IRQ_BACKUP_DIR="$STATE_DIR/irq-affinity-before"

usage() {
  cat <<USAGE
Usage:
  sudo $0 apply [--rt-cpu N] [--no-sibling]
  sudo $0 revert
  $0 status [--rt-cpu N] [--no-sibling]

Notes:
- apply: runtime tuning only (no reboot). It does not edit GRUB.
- By default, a physical core is reserved by including the selected CPU's SMT sibling.
USAGE
}

ensure_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "This command requires root. Run with sudo." >&2
    exit 1
  fi
}

cpu_count() { nproc; }

default_rt_cpu() {
  local last
  last=$(( $(cpu_count) - 1 ))
  echo "$last"
}

build_rt_cpu_list() {
  local base_cpu="$1"
  local include_sibling="$2"
  local sibling_file="/sys/devices/system/cpu/cpu${base_cpu}/topology/thread_siblings_list"

  if [[ "$include_sibling" == "1" && -r "$sibling_file" ]]; then
    cat "$sibling_file"
  else
    echo "$base_cpu"
  fi
}

expand_cpu_list() {
  local list="$1"
  local out=()
  IFS=',' read -ra parts <<< "$list"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      local start end
      start=${part%-*}
      end=${part#*-}
      for ((i=start;i<=end;i++)); do out+=("$i"); done
    else
      out+=("$part")
    fi
  done
  printf '%s\n' "${out[@]}" | awk 'NF' | sort -n | uniq | paste -sd, -
}

contains_cpu() {
  local csv="$1"
  local needle="$2"
  IFS=',' read -ra arr <<< "$csv"
  for c in "${arr[@]}"; do
    if [[ "$c" == "$needle" ]]; then return 0; fi
  done
  return 1
}

build_non_rt_cpu_list() {
  local rt_csv="$1"
  local out=()
  local total
  total=$(cpu_count)
  for ((i=0;i<total;i++)); do
    if ! contains_cpu "$rt_csv" "$i"; then
      out+=("$i")
    fi
  done
  (IFS=,; echo "${out[*]}")
}

save_governors() {
  : > "$STATE_DIR/governors.before"
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov_file" ]] || continue
    echo "$gov_file=$(cat "$gov_file")" >> "$STATE_DIR/governors.before"
  done
}

set_all_governors_performance() {
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$gov_file" ]] || continue
    echo performance > "$gov_file" || true
  done
}

restore_governors() {
  [[ -f "$STATE_DIR/governors.before" ]] || return 0
  while IFS='=' read -r gov_file value; do
    [[ -n "$gov_file" && -w "$gov_file" ]] || continue
    echo "$value" > "$gov_file" || true
  done < "$STATE_DIR/governors.before"
}

backup_irq_affinity() {
  mkdir -p "$IRQ_BACKUP_DIR"
  rm -f "$IRQ_BACKUP_DIR"/*
  for f in /proc/irq/*/smp_affinity_list; do
    [[ -r "$f" ]] || continue
    local irq
    irq=$(echo "$f" | awk -F/ '{print $(NF-1)}')
    cat "$f" > "$IRQ_BACKUP_DIR/$irq"
  done
}

set_irq_affinity_non_rt() {
  local non_rt="$1"
  for f in /proc/irq/*/smp_affinity_list; do
    [[ -w "$f" ]] || continue
    echo "$non_rt" > "$f" 2>/dev/null || true
  done
}

restore_irq_affinity() {
  [[ -d "$IRQ_BACKUP_DIR" ]] || return 0
  for backup in "$IRQ_BACKUP_DIR"/*; do
    [[ -f "$backup" ]] || continue
    local irq
    irq=$(basename "$backup")
    local target="/proc/irq/$irq/smp_affinity_list"
    [[ -w "$target" ]] || continue
    cat "$backup" > "$target" 2>/dev/null || true
  done
}

save_state() {
  local rt_cpu="$1"
  local rt_csv="$2"
  local non_rt_csv="$3"
  local include_sibling="$4"

  mkdir -p "$STATE_DIR"
  {
    echo "RT_CPU=$rt_cpu"
    echo "RT_CPUS=$rt_csv"
    echo "NON_RT_CPUS=$non_rt_csv"
    echo "INCLUDE_SIBLING=$include_sibling"
    echo "SCHED_RT_RUNTIME_BEFORE=$(sysctl -n kernel.sched_rt_runtime_us 2>/dev/null || echo unknown)"
    if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
      if systemctl is-active --quiet irqbalance; then
        echo "IRQBALANCE_WAS_ACTIVE=1"
      else
        echo "IRQBALANCE_WAS_ACTIVE=0"
      fi
    else
      echo "IRQBALANCE_WAS_ACTIVE=missing"
    fi
  } > "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || {
    echo "No state file: $STATE_FILE" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

apply_profile() {
  local rt_cpu="$1"
  local include_sibling="$2"
  local rt_csv non_rt_csv

  rt_csv=$(expand_cpu_list "$(build_rt_cpu_list "$rt_cpu" "$include_sibling")")
  non_rt_csv=$(build_non_rt_cpu_list "$rt_csv")

  mkdir -p "$STATE_DIR"
  save_governors
  backup_irq_affinity
  save_state "$rt_cpu" "$rt_csv" "$non_rt_csv" "$include_sibling"

  set_all_governors_performance
  set_irq_affinity_non_rt "$non_rt_csv"

  if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
    systemctl stop irqbalance || true
    systemctl disable irqbalance || true
  fi

  sysctl -w kernel.sched_rt_runtime_us=-1 >/dev/null || true

  echo "Applied RT runtime profile"
  echo "RT_CPUS=$rt_csv"
  echo "NON_RT_CPUS=$non_rt_csv"
  echo "Run workload pinned to RT core with:"
  echo "  sudo chrt -f 95 taskset -c ${rt_cpu} <your_rt_binary>"
}

revert_profile() {
  load_state
  restore_irq_affinity
  restore_governors

  if [[ "${SCHED_RT_RUNTIME_BEFORE:-unknown}" != "unknown" ]]; then
    sysctl -w kernel.sched_rt_runtime_us="$SCHED_RT_RUNTIME_BEFORE" >/dev/null || true
  fi

  if [[ "${IRQBALANCE_WAS_ACTIVE:-missing}" == "1" ]]; then
    systemctl enable irqbalance || true
    systemctl start irqbalance || true
  fi

  echo "Reverted RT runtime profile"
}

status_profile() {
  local rt_cpu="$1"
  local include_sibling="$2"
  local rt_csv non_rt_csv

  rt_csv=$(expand_cpu_list "$(build_rt_cpu_list "$rt_cpu" "$include_sibling")")
  non_rt_csv=$(build_non_rt_cpu_list "$rt_csv")

  echo "Kernel: $(uname -r)"
  echo "RT_CPU(base): $rt_cpu"
  echo "RT_CPUS(effective): $rt_csv"
  echo "NON_RT_CPUS: $non_rt_csv"
  echo "isolated (kernel cmdline): $(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo none)"
  echo "sched_rt_runtime_us: $(sysctl -n kernel.sched_rt_runtime_us 2>/dev/null || echo unknown)"

  if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
    echo "irqbalance: $(systemctl is-active irqbalance 2>/dev/null || true)"
  else
    echo "irqbalance: not installed"
  fi

  echo "CPU governors:"
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov_file" ]] || continue
    local cpu
    cpu=$(basename "$(dirname "$(dirname "$gov_file")")")
    echo "  $cpu=$(cat "$gov_file")"
  done
}

main() {
  local cmd="${1:-}"
  shift || true

  local rt_cpu
  rt_cpu=$(default_rt_cpu)
  local include_sibling=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rt-cpu)
        rt_cpu="$2"; shift 2 ;;
      --no-sibling)
        include_sibling=0; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1 ;;
    esac
  done

  case "$cmd" in
    apply)
      ensure_root
      apply_profile "$rt_cpu" "$include_sibling"
      ;;
    revert)
      ensure_root
      revert_profile
      ;;
    status)
      status_profile "$rt_cpu" "$include_sibling"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
