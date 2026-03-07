#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/common.sh"
mm_cd_project_root
mm_load_project_env

if [ "$(id -u)" -ne 0 ]; then
  echo "Fehler: Dieses Skript muss direkt auf dem Proxmox-Host als root laufen." >&2
  exit 1
fi

PROJECT_ROOT="$(mm_project_root)"
BOOTSTRAP_DIR="$PROJECT_ROOT/bootstrap"
PROXMOX_ENV_FILE="${MANAGEMOVIE_LXC_PROXMOX_ENV:-$BOOTSTRAP_DIR/proxmox.env}"
SEED_ENV="${MANAGEMOVIE_LXC_SEED_ENV:-$BOOTSTRAP_DIR/managemovie.env}"
SEED_SQL="${MANAGEMOVIE_LXC_SEED_SQL:-$BOOTSTRAP_DIR/managemovie.sql}"

if [ -f "$PROXMOX_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$PROXMOX_ENV_FILE"
  set +a
fi

CONTAINER_NAME="${MANAGEMOVIE_LXC_NAME:-managemovie-lxs}"
CONTAINER_IP="${MANAGEMOVIE_LXC_IP:-192.168.52.152}"
CONTAINER_STORAGE="${MANAGEMOVIE_LXC_STORAGE:-nvme1TB}"
CONTAINER_GATEWAY="${MANAGEMOVIE_LXC_GATEWAY:-192.168.52.1}"
CONTAINER_CORES="${MANAGEMOVIE_LXC_CORES:-4}"
CONTAINER_MEMORY_MB="${MANAGEMOVIE_LXC_MEMORY_MB:-4096}"
CONTAINER_SWAP_MB="${MANAGEMOVIE_LXC_SWAP_MB:-1024}"
CONTAINER_DISK_GB="${MANAGEMOVIE_LXC_DISK_GB:-32}"
CONTAINER_CTID="${MANAGEMOVIE_LXC_CTID:-}"
RECREATE=0
ACTION_MODE="auto"

usage() {
  cat <<'EOF'
Usage: scripts/proxmox/deploy_lxc_on_proxmox.sh [options]

Options:
  --name NAME         Container-Name
  --ip IP             IPv4-Adresse ohne CIDR
  --storage NAME      Proxmox-Storage fuer RootFS
  --ctid ID           Explizite CTID
  --update            Vorhandenen Container aktualisieren (Standard bei Treffer)
  --recreate          Vorhandenen Container neu erzeugen
  --help              Hilfe anzeigen
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    --ip) CONTAINER_IP="$2"; shift 2 ;;
    --storage) CONTAINER_STORAGE="$2"; shift 2 ;;
    --ctid) CONTAINER_CTID="$2"; shift 2 ;;
    --update) ACTION_MODE="update"; shift ;;
    --recreate) RECREATE=1; ACTION_MODE="recreate"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

need_cmd pct
need_cmd pveam
need_cmd pvesh
need_cmd tar
need_cmd curl
need_cmd openssl

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_TGZ="$TMP_DIR/managemovie-project.tgz"
REMOTE_TMP="/root/managemovie-lxc-build"
SEED_MODE="migrate"
CONTAINER_ACTION="create"

shell_quote() {
  local value="${1-}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

find_existing_ctid_by_name() {
  pct list 2>/dev/null | awk -v target="$1" 'NR > 1 && $3 == target {print $1; exit}'
}

current_rootfs_size_gb() {
  local ctid="$1"
  pct config "$ctid" 2>/dev/null | awk -F'[:,=]' '/^rootfs:/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+G$/) {gsub(/G/, "", $i); print $i; exit}}'
}

current_lock_state() {
  local ctid="$1"
  pct config "$ctid" 2>/dev/null | awk '/^lock:/ {print $2; exit}'
}

current_status_state() {
  local ctid="$1"
  pct status "$ctid" 2>/dev/null | awk '{print $2; exit}'
}

apply_container_config() {
  local ctid="$1"
  pct set "$ctid" \
    --hostname "$CONTAINER_NAME" \
    --cores "$CONTAINER_CORES" \
    --memory "$CONTAINER_MEMORY_MB" \
    --swap "$CONTAINER_SWAP_MB" \
    --net0 "name=eth0,bridge=vmbr0,gw=${CONTAINER_GATEWAY},ip=${CONTAINER_IP}/24" \
    --onboot 1 \
    --features nesting=1 >/dev/null

  local current_size=""
  current_size="$(current_rootfs_size_gb "$ctid" || true)"
  if [ -n "$current_size" ] && [ "$CONTAINER_DISK_GB" -gt "$current_size" ]; then
    local delta_gb=$((CONTAINER_DISK_GB - current_size))
    pct resize "$ctid" rootfs "+${delta_gb}G" >/dev/null
    echo "[update] RootFS erweitert: ${current_size}G -> ${CONTAINER_DISK_GB}G"
  fi
}

write_blank_seed_env() {
  local env_file="$1"
  local db_password
  local state_key
  db_password="$(openssl rand -hex 18)"
  state_key="$(openssl rand -hex 32)"
  {
    printf 'MANAGEMOVIE_DATA_ROOT=%s\n' "$(shell_quote "/opt/managemovie/MovieManager")"
    printf 'MANAGEMOVIE_WEB_BIND=%s\n' "$(shell_quote "0.0.0.0")"
    printf 'MANAGEMOVIE_WEB_PORT=%s\n' "$(shell_quote "443")"
    printf 'MANAGEMOVIE_WEB_TLS=%s\n' "$(shell_quote "1")"
    printf 'MANAGEMOVIE_WEB_UI_ONLY=%s\n' "$(shell_quote "1")"
    printf 'MANAGEMOVIE_TERMINAL_UI=%s\n' "$(shell_quote "0")"
    printf 'MANAGEMOVIE_AUTOSTART=%s\n' "$(shell_quote "1")"
    printf 'MANAGEMOVIE_SKIP_CONFIRM=%s\n' "$(shell_quote "1")"
    printf 'MANAGEMOVIE_DEFAULT_FOLDER=%s\n' "$(shell_quote "/mnt")"
    printf 'MANAGEMOVIE_BROWSE_ROOT=%s\n' "$(shell_quote "/")"
    printf 'MANAGEMOVIE_SITE_TITLE=%s\n' "$(shell_quote "ManageMovie LXS")"
    printf 'MANAGEMOVIE_REQUIRE_INITIAL_SETTINGS=%s\n' "$(shell_quote "1")"
    printf 'MANAGEMOVIE_DB_HOST=%s\n' "$(shell_quote "127.0.0.1")"
    printf 'MANAGEMOVIE_DB_PORT=%s\n' "$(shell_quote "3306")"
    printf 'MANAGEMOVIE_DB_NAME=%s\n' "$(shell_quote "managemovie")"
    printf 'MANAGEMOVIE_DB_USER=%s\n' "$(shell_quote "managemovie")"
    printf 'MANAGEMOVIE_DB_PASSWORD=%s\n' "$(shell_quote "$db_password")"
    printf 'MANAGEMOVIE_DB_APP_HOST=%s\n' "$(shell_quote "localhost")"
    printf 'MANAGEMOVIE_DB_ROOT_USER=%s\n' "$(shell_quote "root")"
    printf 'MANAGEMOVIE_DB_ROOT_PASSWORD=%s\n' "$(shell_quote "")"
    printf 'MANAGEMOVIE_DB_RETENTION_DAYS=%s\n' "$(shell_quote "365")"
    printf 'MANAGEMOVIE_STATE_CRYPT_KEY=%s\n' "$(shell_quote "$state_key")"
    printf 'MANAGEMOVIE_SETTINGS_CRYPT_KEY=%s\n' "$(shell_quote "$state_key")"
    printf 'MANAGEMOVIE_WEB_USER=%s\n' "$(shell_quote "")"
    printf 'MANAGEMOVIE_WEB_PASSWORD=%s\n' "$(shell_quote "")"
    printf 'MANAGEMOVIE_SYSTEMD_SERVICE_NAME=%s\n' "$(shell_quote "managemovie-web.service")"
    printf 'MANAGEMOVIE_SYSTEMD_USER=%s\n' "$(shell_quote "root")"
    printf 'MANAGEMOVIE_SYSTEMD_GROUP=%s\n' "$(shell_quote "root")"
  } > "$env_file"
  chmod 600 "$env_file"
}

prepare_seed_bundle() {
  local generated_env="$TMP_DIR/managemovie.generated.env"
  local generated_sql="$TMP_DIR/managemovie.generated.sql"

  if [ ! -f "$SEED_ENV" ]; then
    write_blank_seed_env "$generated_env"
    SEED_ENV="$generated_env"
    SEED_MODE="blank"
    echo "[seed] Keine bootstrap/managemovie.env gefunden. Verwende leere Kunden-Konfiguration mit Erststart-Sperre."
  fi

  if [ ! -f "$SEED_SQL" ]; then
    : > "$generated_sql"
    chmod 600 "$generated_sql"
    SEED_SQL="$generated_sql"
    if [ "$SEED_MODE" = "migrate" ]; then
      SEED_MODE="blank"
    fi
    echo "[seed] Keine bootstrap/managemovie.sql gefunden. Verwende leere Datenbank ohne importierte Historie."
  fi
}

prepare_seed_bundle

tar \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='.DS_Store' \
  --exclude='MovieManager' \
  --exclude='logs' \
  --exclude='work' \
  --exclude='temp' \
  --exclude='certs' \
  --exclude='.env.local' \
  --exclude='.env' \
  --exclude='bootstrap/managemovie.env' \
  --exclude='bootstrap/managemovie.sql' \
  --exclude='bootstrap/proxmox.env' \
  -czf "$PROJECT_TGZ" \
  -C "$PROJECT_ROOT" .

EXISTING_CTID_BY_NAME="$(find_existing_ctid_by_name "$CONTAINER_NAME" || true)"

if [ -n "$CONTAINER_CTID" ] && [ -n "$EXISTING_CTID_BY_NAME" ] && [ "$EXISTING_CTID_BY_NAME" != "$CONTAINER_CTID" ]; then
  echo "Fehler: Name ${CONTAINER_NAME} existiert bereits als CTID ${EXISTING_CTID_BY_NAME}. Entweder --ctid ${EXISTING_CTID_BY_NAME} nutzen oder Namen aendern." >&2
  exit 1
fi

if [ -z "$CONTAINER_CTID" ]; then
  if [ -n "$EXISTING_CTID_BY_NAME" ]; then
    CONTAINER_CTID="$EXISTING_CTID_BY_NAME"
  else
    CONTAINER_CTID="$(pvesh get /cluster/nextid)"
  fi
fi

TEMPLATE="$(pveam update >/dev/null 2>&1 && pveam available | awk '/debian-12-standard_/ {print $2}' | tail -n 1)"
if [ -z "$TEMPLATE" ]; then
  echo "Fehler: Debian-12-Template auf Proxmox nicht verfügbar." >&2
  exit 1
fi

pveam download local "$TEMPLATE" >/dev/null 2>&1 || true

if pct status "$CONTAINER_CTID" >/dev/null 2>&1; then
  EXISTING_LOCK_STATE="$(current_lock_state "$CONTAINER_CTID" || true)"
  EXISTING_STATUS_STATE="$(current_status_state "$CONTAINER_CTID" || true)"
  if [ "$EXISTING_LOCK_STATE" = "create" ] && [ "$EXISTING_STATUS_STATE" = "stopped" ]; then
    echo "[lock] CTID ${CONTAINER_CTID} hat einen stale create-Lock. Unvollstaendigen Container bereinigen und neu erzeugen."
    pct unlock "$CONTAINER_CTID" >/dev/null 2>&1 || true
    pct destroy "$CONTAINER_CTID" --purge 1 >/dev/null 2>&1 || true
    CONTAINER_ACTION="create"
  elif [ -n "$EXISTING_LOCK_STATE" ] && [ "$EXISTING_STATUS_STATE" = "stopped" ]; then
    echo "[lock] CTID ${CONTAINER_CTID} hat Lock=${EXISTING_LOCK_STATE}. Unlock fuer Update/Recreate."
    pct unlock "$CONTAINER_CTID" >/dev/null 2>&1 || true
  elif [ -n "$EXISTING_LOCK_STATE" ]; then
    echo "Fehler: CTID ${CONTAINER_CTID} ist aktiv gelockt (${EXISTING_LOCK_STATE}, Status=${EXISTING_STATUS_STATE}). Bitte laufende Proxmox-Operation beenden." >&2
    exit 1
  fi
fi

if pct status "$CONTAINER_CTID" >/dev/null 2>&1; then
  if [ "$ACTION_MODE" = "recreate" ] || [ "$RECREATE" -eq 1 ]; then
    CONTAINER_ACTION="recreate"
    pct stop "$CONTAINER_CTID" >/dev/null 2>&1 || true
    pct destroy "$CONTAINER_CTID" --purge 1
  else
    CONTAINER_ACTION="update"
  fi
fi

mkdir -p "$REMOTE_TMP"
install -m 600 "$SEED_ENV" "$REMOTE_TMP/managemovie.env"
install -m 600 "$SEED_SQL" "$REMOTE_TMP/managemovie.sql"
install -m 755 "$PROJECT_ROOT/scripts/proxmox/install_inside_lxc.sh" "$REMOTE_TMP/install_inside_lxc.sh"
install -m 600 "$PROJECT_TGZ" "$REMOTE_TMP/managemovie-project.tgz"

if [ "$CONTAINER_ACTION" = "create" ] || [ "$CONTAINER_ACTION" = "recreate" ]; then
  pct create "$CONTAINER_CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$CONTAINER_NAME" \
    --cores "$CONTAINER_CORES" \
    --memory "$CONTAINER_MEMORY_MB" \
    --swap "$CONTAINER_SWAP_MB" \
    --rootfs "${CONTAINER_STORAGE}:${CONTAINER_DISK_GB}" \
    --net0 "name=eth0,bridge=vmbr0,gw=${CONTAINER_GATEWAY},ip=${CONTAINER_IP}/24" \
    --onboot 1 \
    --unprivileged 0 \
    --features nesting=1
else
  apply_container_config "$CONTAINER_CTID"
fi

pct start "$CONTAINER_CTID" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  if pct exec "$CONTAINER_CTID" -- bash -lc 'test -d /run/systemd/system'; then
    break
  fi
  sleep 2
done

pct push "$CONTAINER_CTID" "$REMOTE_TMP/managemovie-project.tgz" /root/managemovie-project.tgz
pct push "$CONTAINER_CTID" "$REMOTE_TMP/managemovie.sql" /root/managemovie.sql
pct push "$CONTAINER_CTID" "$REMOTE_TMP/managemovie.env" /root/managemovie.env
pct push "$CONTAINER_CTID" "$REMOTE_TMP/install_inside_lxc.sh" /root/install_inside_lxc.sh
pct exec "$CONTAINER_CTID" -- chmod +x /root/install_inside_lxc.sh
pct exec "$CONTAINER_CTID" -- bash /root/install_inside_lxc.sh /opt/managemovie /root/managemovie-project.tgz /root/managemovie.env /root/managemovie.sql

for _ in $(seq 1 40); do
  if curl -kfsS --max-time 5 "https://${CONTAINER_IP}/api/state" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

if ! curl -kfsS --max-time 5 "https://${CONTAINER_IP}/api/state" >/dev/null; then
  echo "Fehler: Container-Webservice antwortet nicht unter https://${CONTAINER_IP}/api/state" >&2
  exit 1
fi

echo "LXC bereit:"
echo "  Name:    ${CONTAINER_NAME}"
echo "  CTID:    ${CONTAINER_CTID}"
echo "  IP:      ${CONTAINER_IP}"
echo "  Storage: ${CONTAINER_STORAGE}"
echo "  Seed:    ${SEED_MODE}"
echo "  Aktion:  ${CONTAINER_ACTION}"
echo "  URL:     https://${CONTAINER_IP}/"
