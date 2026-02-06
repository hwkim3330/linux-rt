#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/rt-core-grub"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_FILE="/etc/default/grub.rtcore.bak"
GRUB_FILE="/etc/default/grub"
UPDATE_GRUB_TIMEOUT_SEC="${UPDATE_GRUB_TIMEOUT_SEC:-45}"

usage() {
  cat <<USAGE
Usage:
  sudo ./scripts/grub-rt-kargs.sh apply [--rt-cpus LIST] [--non-rt-cpus LIST]
  sudo ./scripts/grub-rt-kargs.sh revert
  ./scripts/grub-rt-kargs.sh status

Defaults:
  rt-cpus: 15
  non-rt-cpus: all except rt-cpus

This script updates GRUB_CMDLINE_LINUX_DEFAULT and runs update-grub.
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
  local i
  local rt_set=",$(expand_cpu_list "$rt"),"
  for ((i=0;i<total;i++)); do
    if [[ "$rt_set" != *",$i,"* ]]; then
      out+=("$i")
    fi
  done
  (IFS=,; echo "${out[*]}")
}

get_cmdline() {
  awk -F'"' '/^GRUB_CMDLINE_LINUX_DEFAULT=/{print $2}' "$GRUB_FILE"
}

set_cmdline() {
  local new="$1"
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$GRUB_FILE"
}

run_update_grub() {
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "${UPDATE_GRUB_TIMEOUT_SEC}" update-grub >/dev/null; then
      echo "update-grub failed or timed out (${UPDATE_GRUB_TIMEOUT_SEC}s)." >&2
      echo "You can run manually later: sudo update-grub" >&2
      return 1
    fi
  else
    update-grub >/dev/null
  fi
}

strip_rt_tokens() {
  local s="$1"
  # Remove previous RT-related tokens added by this workflow.
  s=$(echo "$s" | sed -E 's/(^| )isolcpus=[^ ]+//g; s/(^| )nohz_full=[^ ]+//g; s/(^| )rcu_nocbs=[^ ]+//g; s/(^| )irqaffinity=[^ ]+//g; s/(^| )threadirqs//g')
  echo "$s" | xargs
}

apply_kargs() {
  local rt_cpus="$1"
  local non_rt_cpus="$2"

  mkdir -p "$STATE_DIR"
  if [[ ! -f "$BACKUP_FILE" ]]; then
    cp "$GRUB_FILE" "$BACKUP_FILE"
  fi

  local old cmdline cleaned new
  old=$(get_cmdline)
  cleaned=$(strip_rt_tokens "$old")
  new="$cleaned isolcpus=${rt_cpus} nohz_full=${rt_cpus} rcu_nocbs=${rt_cpus} irqaffinity=${non_rt_cpus} threadirqs"
  new=$(echo "$new" | xargs)

  {
    echo "RT_CPUS=${rt_cpus}"
    echo "NON_RT_CPUS=${non_rt_cpus}"
    echo "OLD_CMDLINE=${old}"
    echo "NEW_CMDLINE=${new}"
  } > "$STATE_FILE"

  set_cmdline "$new"
  if ! run_update_grub; then
    set_cmdline "$old"
    run_update_grub || true
    echo "Rolled back GRUB cmdline due to update-grub failure." >&2
    exit 1
  fi

  echo "Applied GRUB RT kernel args"
  echo "RT_CPUS=${rt_cpus}"
  echo "NON_RT_CPUS=${non_rt_cpus}"
  echo "Reboot required."
}

revert_kargs() {
  if [[ -f "$BACKUP_FILE" ]]; then
    cp "$BACKUP_FILE" "$GRUB_FILE"
    run_update_grub
    echo "Reverted /etc/default/grub from backup"
    echo "Reboot required."
  else
    echo "Backup not found: $BACKUP_FILE" >&2
    exit 1
  fi
}

status_kargs() {
  echo "kernel: $(uname -r)"
  echo "running cmdline: $(cat /proc/cmdline)"
  echo "grub default cmdline: $(get_cmdline)"
  if [[ -f "$STATE_FILE" ]]; then
    echo "state file: $STATE_FILE"
    cat "$STATE_FILE"
  else
    echo "state file: not found"
  fi
}

main() {
  local cmd="${1:-}"
  shift || true

  local rt_cpus="15"
  local non_rt_cpus=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rt-cpus)
        rt_cpus="$2"; shift 2 ;;
      --non-rt-cpus)
        non_rt_cpus="$2"; shift 2 ;;
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
    apply)
      need_root
      apply_kargs "$rt_cpus" "$non_rt_cpus"
      ;;
    revert)
      need_root
      revert_kargs
      ;;
    status)
      status_kargs
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
