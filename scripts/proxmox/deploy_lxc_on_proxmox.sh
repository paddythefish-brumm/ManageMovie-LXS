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
TEMPLATE_STORAGE="${MANAGEMOVIE_LXC_TEMPLATE_STORAGE:-}"
LEGACY_TEMPLATE="${MANAGEMOVIE_LXC_LEGACY_TEMPLATE:-}"
CONTAINER_GATEWAY="${MANAGEMOVIE_LXC_GATEWAY:-}"
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
  --gateway IP        IPv4-Gateway (Default: automatisch aus --ip abgeleitet)
  --storage NAME      Proxmox-Storage fuer RootFS
  --template-storage  Proxmox-Storage fuer LXC-Templates (vztmpl)
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
    --gateway) CONTAINER_GATEWAY="$2"; shift 2 ;;
    --storage) CONTAINER_STORAGE="$2"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
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
need_cmd pvesm
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

is_ipv4_address() {
  local value="${1:-}"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local part
  for part in $value; do
    [ "$part" -ge 0 ] 2>/dev/null && [ "$part" -le 255 ] 2>/dev/null || return 1
  done
}

derive_gateway_from_ip() {
  local ip="$1"
  if ! is_ipv4_address "$ip"; then
    return 1
  fi
  local a b c d
  IFS=. read -r a b c d <<EOF
$ip
EOF
  printf '%s.%s.%s.1\n' "$a" "$b" "$c"
}

find_existing_ctid_by_name() {
  pct list 2>/dev/null | awk -v target="$1" 'NR > 1 && $3 == target {print $1; exit}'
}

find_template_storage() {
  if [ -n "$TEMPLATE_STORAGE" ]; then
    printf '%s\n' "$TEMPLATE_STORAGE"
    return
  fi
  pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 && $1 != "" {print $1}'
}

ensure_template_on_storage() {
  local storage="$1"
  local template_name="$2"
  local template_path=""
  if ! pveam download "$storage" "$template_name" >/dev/null 2>&1; then
    return 1
  fi
  template_path="$(pvesm path "${storage}:vztmpl/${template_name}" 2>/dev/null || true)"
  [ -n "$template_path" ] && [ -f "$template_path" ]
}

resolve_template_storage() {
  local template_name="$1"
  local preferred_storage="${TEMPLATE_STORAGE:-}"
  local storage=""
  if [ -n "$preferred_storage" ]; then
    if ensure_template_on_storage "$preferred_storage" "$template_name"; then
      printf '%s\n' "$preferred_storage"
      return 0
    fi
  fi
  while IFS= read -r storage; do
    [ -n "$storage" ] || continue
    [ "$storage" = "$preferred_storage" ] && continue
    if ensure_template_on_storage "$storage" "$template_name"; then
      printf '%s\n' "$storage"
      return 0
    fi
  done <<EOF
$(find_template_storage || true)
EOF
  return 1
}

latest_template_by_pattern() {
  local pattern="$1"
  pveam available | awk -v pattern="$pattern" '$2 ~ pattern {print $2}' | tail -n 1
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

template_volume() {
  local template_name="$1"
  printf '%s\n' "${TEMPLATE_STORAGE}:vztmpl/${template_name}"
}

template_cache_path() {
  local template_name="$1"
  pvesm path "$(template_volume "$template_name")" 2>/dev/null || true
}

create_container_with_template() {
  local template_name="$1"
  pct create "$CONTAINER_CTID" "$(template_volume "$template_name")" \
    --hostname "$CONTAINER_NAME" \
    --cores "$CONTAINER_CORES" \
    --memory "$CONTAINER_MEMORY_MB" \
    --swap "$CONTAINER_SWAP_MB" \
    --rootfs "${CONTAINER_STORAGE}:${CONTAINER_DISK_GB}" \
    --net0 "name=eth0,bridge=vmbr0,gw=${CONTAINER_GATEWAY},ip=${CONTAINER_IP}/24" \
    --onboot 1 \
    --unprivileged 0 \
    --features nesting=1
}

create_container_with_template_fallback() {
  local template_name="$1"
  local create_log="$TMP_DIR/pct-create.log"
  if create_container_with_template "$template_name" >"$create_log" 2>&1; then
    cat "$create_log"
    return 0
  fi

  if grep -q "unsupported debian version '13\\." "$create_log"; then
    local legacy_template_name="${LEGACY_TEMPLATE:-}"
    if [ -z "$legacy_template_name" ]; then
      legacy_template_name="$(latest_template_by_pattern 'debian-12-standard_')"
    fi
    if [ -n "$legacy_template_name" ]; then
      if ! pveam download "$TEMPLATE_STORAGE" "$legacy_template_name" >/dev/null 2>&1; then
        echo "Fehler: Legacy-Fallback-Template ${legacy_template_name} konnte nicht nach '${TEMPLATE_STORAGE}' geladen werden." >&2
        cat "$create_log" >&2
        return 1
      fi
      echo "[template] Proxmox akzeptiert ${template_name} nicht direkt. Nutze Legacy-Fallback ${legacy_template_name}; Upgrade auf Debian 13 erfolgt im Container."
      if create_container_with_template "$legacy_template_name" >"$create_log" 2>&1; then
        cat "$create_log"
        return 0
      fi
    fi
  fi

  cat "$create_log" >&2
  return 1
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
    printf 'MANAGEMOVIE_WEB_PORT=%s\n' "$(shell_quote "8126")"
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

if ! is_ipv4_address "$CONTAINER_IP"; then
  echo "Fehler: --ip muss eine gueltige IPv4-Adresse ohne CIDR sein." >&2
  exit 1
fi

if [ -z "$CONTAINER_GATEWAY" ]; then
  CONTAINER_GATEWAY="$(derive_gateway_from_ip "$CONTAINER_IP" || true)"
fi
if ! is_ipv4_address "$CONTAINER_GATEWAY"; then
  echo "Fehler: Kein gueltiges Gateway gesetzt. Bitte --gateway <IPv4> angeben." >&2
  exit 1
fi

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

TEMPLATE="$(pveam update >/dev/null 2>&1 && latest_template_by_pattern 'debian-13-standard_')"
if [ -z "$TEMPLATE" ]; then
  echo "Fehler: Debian-13-Template auf Proxmox nicht verfuegbar." >&2
  exit 1
fi

TEMPLATE_STORAGE="$(resolve_template_storage "$TEMPLATE" || true)"
if [ -z "$TEMPLATE_STORAGE" ]; then
  echo "Fehler: Debian-13-Template konnte auf keinem Proxmox-Storage mit Content-Typ 'vztmpl' bereitgestellt werden." >&2
  exit 1
fi

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
  create_container_with_template_fallback "$TEMPLATE"
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

internal_ready=0
for _ in $(seq 1 40); do
  if pct exec "$CONTAINER_CTID" -- bash -lc 'curl -kfsS --max-time 5 https://127.0.0.1/api/state >/dev/null' >/dev/null 2>&1; then
    internal_ready=1
    break
  fi
  sleep 3
done

if [ "$internal_ready" -ne 1 ]; then
  echo "Fehler: Container-Webservice antwortet intern nicht unter https://127.0.0.1/api/state" >&2
  exit 1
fi

external_ready=0
for _ in $(seq 1 40); do
  if curl -kfsS --max-time 5 "https://${CONTAINER_IP}/api/state" >/dev/null 2>&1; then
    external_ready=1
    break
  fi
  sleep 3
done

if [ "$external_ready" -ne 1 ]; then
  echo "[warn] Container-Webservice intern gesund, aber vom Proxmox-Host nicht unter https://${CONTAINER_IP}/api/state erreichbar." >&2
fi

echo "LXC bereit:"
echo "  Name:    ${CONTAINER_NAME}"
echo "  CTID:    ${CONTAINER_CTID}"
echo "  IP:      ${CONTAINER_IP}"
echo "  Gateway: ${CONTAINER_GATEWAY}"
echo "  Storage: ${CONTAINER_STORAGE}"
echo "  Template-Storage: ${TEMPLATE_STORAGE}"
echo "  Seed:    ${SEED_MODE}"
echo "  Aktion:  ${CONTAINER_ACTION}"
echo "  URL:     https://${CONTAINER_IP}/"
