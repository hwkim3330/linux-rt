#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/rtos-like-profile"
STATE_FILE="$STATE_DIR/state.env"
IRQ_BACKUP_DIR="$STATE_DIR/irq-before"

usage() {
  cat <<USAGE
Usage:
  sudo ./scripts/rtos-like-profile.sh apply [--rt-cpu N]
  sudo ./scripts/rtos-like-profile.sh revert
  ./scripts/rtos-like-profile.sh status [--rt-cpu N]

Intent:
- Reserve one CPU as RT island at runtime.
- Push almost all IRQs to non-RT CPUs.
- Force performance governor and tighten kernel runtime knobs.
USAGE
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run with sudo." >&2
    exit 1
  fi
}

default_rt_cpu() {
  echo $(( $(nproc) - 1 ))
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

default_non_rt_cpus() {
  local rt_cpu="$1"
  local out=()
  local i total
  total=$(nproc)
  for ((i=0;i<total;i++)); do
    [[ "$i" == "$rt_cpu" ]] && continue
    out+=("$i")
  done
  (IFS=,; echo "${out[*]}")
}

save_governors() {
  : > "$STATE_DIR/governors.before"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$f" ]] || continue
    echo "$f=$(cat "$f")" >> "$STATE_DIR/governors.before"
  done
}

set_governors_performance() {
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$f" ]] || continue
    echo performance > "$f" || true
  done
}

restore_governors() {
  [[ -f "$STATE_DIR/governors.before" ]] || return 0
  while IFS='=' read -r f v; do
    [[ -w "$f" ]] || continue
    echo "$v" > "$f" || true
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

restore_irq_affinity() {
  [[ -d "$IRQ_BACKUP_DIR" ]] || return 0
  local b irq target
  for b in "$IRQ_BACKUP_DIR"/*; do
    [[ -f "$b" ]] || continue
    irq=$(basename "$b")
    target="/proc/irq/${irq}/smp_affinity_list"
    [[ -w "$target" ]] || continue
    cat "$b" > "$target" 2>/dev/null || true
  done
}

set_irq_non_rt() {
  local non_rt="$1"
  local f
  for f in /proc/irq/*/smp_affinity_list; do
    [[ -w "$f" ]] || continue
    echo "$non_rt" > "$f" 2>/dev/null || true
  done
}

save_sysctls() {
  : > "$STATE_DIR/sysctl.before"
  for key in kernel.sched_rt_runtime_us kernel.timer_migration kernel.nmi_watchdog vm.stat_interval; do
    if sysctl -n "$key" >/dev/null 2>&1; then
      echo "$key=$(sysctl -n "$key")" >> "$STATE_DIR/sysctl.before"
    fi
  done
}

apply_sysctls() {
  sysctl -w kernel.sched_rt_runtime_us=-1 >/dev/null || true
  sysctl -w kernel.timer_migration=0 >/dev/null || true
  sysctl -w kernel.nmi_watchdog=0 >/dev/null || true
  sysctl -w vm.stat_interval=120 >/dev/null || true
}

restore_sysctls() {
  [[ -f "$STATE_DIR/sysctl.before" ]] || return 0
  while IFS='=' read -r k v; do
    sysctl -w "$k=$v" >/dev/null || true
  done < "$STATE_DIR/sysctl.before"
}

save_state() {
  local rt_cpu="$1"
  local non_rt="$2"
  mkdir -p "$STATE_DIR"
  {
    echo "RT_CPU=$rt_cpu"
    echo "NON_RT_CPUS=$non_rt"
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
  [[ -f "$STATE_FILE" ]] || { echo "No state file: $STATE_FILE" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

apply_profile() {
  local rt_cpu="$1"
  local non_rt
  non_rt=$(default_non_rt_cpus "$rt_cpu")

  mkdir -p "$STATE_DIR"
  save_state "$rt_cpu" "$non_rt"
  save_governors
  save_sysctls
  backup_irq_affinity

  set_governors_performance
  apply_sysctls
  set_irq_non_rt "$non_rt"

  if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
    systemctl stop irqbalance || true
    systemctl disable irqbalance || true
  fi

  echo "Applied RTOS-like runtime profile"
  echo "RT_CPU=${rt_cpu}"
  echo "NON_RT_CPUS=${non_rt}"
  echo "Run RT task on isolated runtime CPU:"
  echo "  sudo chrt -f 95 taskset -c ${rt_cpu} <your_rt_binary>"
}

revert_profile() {
  load_state
  restore_irq_affinity
  restore_governors
  restore_sysctls

  if [[ "${IRQBALANCE_WAS_ACTIVE:-missing}" == "1" ]]; then
    systemctl enable irqbalance || true
    systemctl start irqbalance || true
  fi

  echo "Reverted RTOS-like runtime profile"
}

status_profile() {
  local rt_cpu="$1"
  local non_rt
  non_rt=$(default_non_rt_cpus "$rt_cpu")
  echo "kernel: $(uname -r)"
  echo "rt_cpu: $rt_cpu"
  echo "non_rt_cpus: $non_rt"
  echo "isolated (boot): $(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo none)"
  for key in kernel.sched_rt_runtime_us kernel.timer_migration kernel.nmi_watchdog vm.stat_interval; do
    if sysctl -n "$key" >/dev/null 2>&1; then
      echo "$key=$(sysctl -n "$key")"
    fi
  done
  if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
    echo "irqbalance=$(systemctl is-active irqbalance 2>/dev/null || true)"
  else
    echo "irqbalance=not-installed"
  fi
}

main() {
  local cmd="${1:-}"
  shift || true
  local rt_cpu
  rt_cpu=$(default_rt_cpu)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rt-cpu)
        rt_cpu="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Unknown arg: $1" >&2
        usage
        exit 1 ;;
    esac
  done

  case "$cmd" in
    apply)
      need_root
      apply_profile "$rt_cpu"
      ;;
    revert)
      need_root
      revert_profile
      ;;
    status)
      status_profile "$rt_cpu"
      ;;
    *)
      usage
      exit 1 ;;
  esac
}

main "$@"
