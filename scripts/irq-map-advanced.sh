#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/rt-irq-map"
BACKUP_DIR="$STATE_DIR/before"

usage() {
  cat <<USAGE
Usage:
  sudo ./scripts/irq-map-advanced.sh apply --rt-cpus LIST [--rt-pattern REGEX] [--non-rt-cpus LIST] [--dry-run]
  sudo ./scripts/irq-map-advanced.sh restore
  ./scripts/irq-map-advanced.sh show [--rt-pattern REGEX]

Behavior:
- All IRQs are pinned to non-RT CPUs.
- IRQs whose action/name matches --rt-pattern are pinned to RT CPUs.
Default --rt-pattern: 'eth|enp|eno|can|igc|ixgbe|mlx|tsn|ptp'
USAGE
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run with sudo." >&2
    exit 1
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

default_non_rt() {
  local rt="$1"
  local total
  total=$(nproc)
  local out=()
  local rt_set=",$(expand_cpu_list "$rt"),"
  local i
  for ((i=0;i<total;i++)); do
    if [[ "$rt_set" != *",$i,"* ]]; then
      out+=("$i")
    fi
  done
  (IFS=,; echo "${out[*]}")
}

irq_action() {
  local irq="$1"
  local f="/proc/irq/${irq}/actions"
  if [[ -r "$f" ]]; then
    local v
    v=$(tr '\n' ' ' < "$f" | xargs)
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  fi
  # Fallback: last column in /proc/interrupts for this IRQ.
  local line
  line=$(awk -v n="${irq}:" '$1==n {print $0}' /proc/interrupts 2>/dev/null || true)
  if [[ -n "$line" ]]; then
    echo "$line" | awk '{print $NF}'
  else
    echo ""
  fi
}

show_irqs() {
  local pattern="$1"
  printf "%-6s %-18s %-40s %s\n" "IRQ" "AFFINITY" "ACTION" "MATCH"
  for f in /proc/irq/*/smp_affinity_list; do
    [[ -r "$f" ]] || continue
    local irq aff act match
    irq=$(echo "$f" | awk -F/ '{print $(NF-1)}')
    aff=$(cat "$f" 2>/dev/null || echo "-")
    act=$(irq_action "$irq")
    [[ -z "$act" ]] && act="(none)"
    if echo "$act" | grep -Eiq "$pattern"; then
      match="yes"
    else
      match="no"
    fi
    printf "%-6s %-18s %-40s %s\n" "$irq" "$aff" "${act:0:40}" "$match"
  done
}

backup_all() {
  mkdir -p "$BACKUP_DIR"
  rm -f "$BACKUP_DIR"/*
  for f in /proc/irq/*/smp_affinity_list; do
    [[ -r "$f" ]] || continue
    local irq
    irq=$(echo "$f" | awk -F/ '{print $(NF-1)}')
    cat "$f" > "$BACKUP_DIR/$irq"
  done
}

set_affinity() {
  local target="$1"
  local pattern="$2"
  local rt_cpus="$3"
  local non_rt_cpus="$4"
  local dry_run="$5"

  local f irq act wanted
  for f in /proc/irq/*/smp_affinity_list; do
    [[ -w "$f" ]] || continue
    irq=$(echo "$f" | awk -F/ '{print $(NF-1)}')
    act=$(irq_action "$irq")
    wanted="$non_rt_cpus"
    if echo "$act" | grep -Eiq "$pattern"; then
      wanted="$rt_cpus"
    fi
    if [[ "$dry_run" == "1" ]]; then
      echo "irq=$irq action='${act:0:60}' -> $wanted"
    else
      echo "$wanted" > "$f" 2>/dev/null || true
    fi
  done
  [[ "$dry_run" == "1" ]] || echo "Applied IRQ affinity map"
}

restore_all() {
  local b irq target
  [[ -d "$BACKUP_DIR" ]] || { echo "No backup found: $BACKUP_DIR" >&2; exit 1; }
  for b in "$BACKUP_DIR"/*; do
    [[ -f "$b" ]] || continue
    irq=$(basename "$b")
    target="/proc/irq/${irq}/smp_affinity_list"
    [[ -w "$target" ]] || continue
    cat "$b" > "$target" 2>/dev/null || true
  done
  echo "Restored IRQ affinity from backup"
}

main() {
  local cmd="${1:-}"
  shift || true

  local rt_cpus="15"
  local non_rt_cpus=""
  local pattern='eth|enp|eno|can|igc|ixgbe|mlx|tsn|ptp'
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rt-cpus)
        rt_cpus="$2"; shift 2 ;;
      --non-rt-cpus)
        non_rt_cpus="$2"; shift 2 ;;
      --rt-pattern)
        pattern="$2"; shift 2 ;;
      --dry-run)
        dry_run=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Unknown arg: $1" >&2
        usage
        exit 1 ;;
    esac
  done

  rt_cpus=$(expand_cpu_list "$rt_cpus")
  if [[ -z "$non_rt_cpus" ]]; then
    non_rt_cpus=$(default_non_rt "$rt_cpus")
  else
    non_rt_cpus=$(expand_cpu_list "$non_rt_cpus")
  fi

  case "$cmd" in
    show)
      show_irqs "$pattern"
      ;;
    apply)
      need_root
      backup_all
      set_affinity "/proc/irq" "$pattern" "$rt_cpus" "$non_rt_cpus" "$dry_run"
      ;;
    restore)
      need_root
      restore_all
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
