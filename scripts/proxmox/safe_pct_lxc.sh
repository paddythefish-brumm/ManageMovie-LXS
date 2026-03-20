#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Fehler: safe_pct_lxc.sh muss als root auf dem Proxmox-Host laufen." >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: safe_pct_lxc.sh <status|start|stop|restart|destroy|cleanup> <CTID>

Zweck:
  Erkennt den LXC-Zombie-Zustand "running ohne PID" und räumt stale
  lxc-start/lxc-console/dtach/lock-Reste weg, bevor die normale pct-Aktion
  ausgeführt wird.
EOF
}

ACTION="${1:-}"
CTID="${2:-}"

if [[ -z "$ACTION" || -z "$CTID" || "$ACTION" == "--help" || "$ACTION" == "-h" ]]; then
  usage
  exit $([[ -n "$ACTION" && "$ACTION" =~ ^(--help|-h)$ ]] && echo 0 || echo 1)
fi

if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
  echo "Fehler: CTID muss numerisch sein." >&2
  exit 1
fi

status_state() {
  pct status "$CTID" 2>/dev/null | awk '{print $2; exit}'
}

lxc_state() {
  lxc-info -n "$CTID" 2>/dev/null | awk '/^State:/ {print $2; exit}'
}

has_pid() {
  pct status "$CTID" 2>&1 | grep -qv 'unable to get PID'
}

mount_ct_rootfs() {
  local rootfs="/var/lib/lxc/${CTID}/rootfs"
  if [ -f "$rootfs/etc/debian_version" ]; then
    printf '%s\n' "$rootfs"
    return 0
  fi
  if pct mount "$CTID" >/dev/null 2>&1; then
    if [ -f "$rootfs/etc/debian_version" ]; then
      printf '%s\n' "$rootfs"
      return 0
    fi
  fi
  return 1
}

normalize_legacy_debian_version() {
  local rootfs version
  rootfs="$(mount_ct_rootfs || true)"
  [ -n "$rootfs" ] || return 0

  version="$(head -n 1 "$rootfs/etc/debian_version" 2>/dev/null || true)"
  if [[ "$version" =~ ^13\.[0-9]+$ ]]; then
    echo "[safe-pct] normalisiere Debian-Version für Legacy-Proxmox: $version -> 13"
    printf '13\n' > "$rootfs/etc/debian_version"
  fi
}

is_zombie_state() {
  local pct_state lxc_state_val
  pct_state="$(status_state || true)"
  lxc_state_val="$(lxc_state || true)"
  if [[ "$pct_state" == "running" ]] && ! has_pid; then
    return 0
  fi
  if [[ "$pct_state" == "running" && "$lxc_state_val" == "STOPPED" ]]; then
    return 0
  fi
  return 1
}

cleanup_runtime() {
  echo "[safe-pct] bereinige Runtime-Reste für CT $CTID"
  local pid
  for pid in $(ps -eo pid,cmd | awk -v ctid="$CTID" '
    $0 ~ ("lxc-start -F -n " ctid) ||
    $0 ~ ("lxc-stop -n " ctid) ||
    $0 ~ ("lxc-console -n " ctid) ||
    $0 ~ ("vzctlconsole" ctid) ||
    $0 ~ ("pct stop " ctid) ||
    $0 ~ ("pct shutdown " ctid) {print $1}'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $(ps -eo pid,cmd | awk -v ctid="$CTID" '
    $0 ~ ("lxc-start -F -n " ctid) ||
    $0 ~ ("lxc-stop -n " ctid) ||
    $0 ~ ("lxc-console -n " ctid) ||
    $0 ~ ("vzctlconsole" ctid) ||
    $0 ~ ("pct stop " ctid) ||
    $0 ~ ("pct shutdown " ctid) {print $1}'); do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -f "/run/lock/lxc/pve-config-${CTID}.lock" || true
  rm -f "/var/run/dtach/vzctlconsole${CTID}" || true
  rm -f "/run/pve/ct-${CTID}.stderr" || true
}

ensure_clean_state() {
  if is_zombie_state; then
    echo "[safe-pct] Zombie-Zustand erkannt: pct=$(status_state || true) lxc=$(lxc_state || true)"
    cleanup_runtime
  fi
}

case "$ACTION" in
  status)
    echo "pct: $(status_state || true)"
    echo "lxc: $(lxc_state || true)"
    if is_zombie_state; then
      echo "zombie: yes"
    else
      echo "zombie: no"
    fi
    ;;
  cleanup)
    cleanup_runtime
    ;;
  stop)
    ensure_clean_state
    pct shutdown "$CTID" --forceStop 1 --timeout 30 || {
      cleanup_runtime
      pct stop "$CTID" || true
    }
    ;;
  start)
    ensure_clean_state
    normalize_legacy_debian_version
    pct start "$CTID"
    ;;
  restart)
    ensure_clean_state
    pct shutdown "$CTID" --forceStop 1 --timeout 30 || {
      cleanup_runtime
      pct stop "$CTID" || true
    }
    ensure_clean_state
    normalize_legacy_debian_version
    pct start "$CTID"
    ;;
  destroy)
    ensure_clean_state
    pct destroy "$CTID" --purge 1 || {
      cleanup_runtime
      pct destroy "$CTID" --purge 1
    }
    ;;
  *)
    usage
    exit 1
    ;;
esac
