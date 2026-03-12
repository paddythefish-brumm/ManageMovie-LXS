#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Fehler: install_inside_lxc.sh muss als root laufen." >&2
  exit 1
fi

PROJECT_ROOT="${1:-/opt/managemovie}"
PROJECT_TGZ="${2:-/root/managemovie-project.tgz}"
ENV_FILE="${3:-/root/managemovie.env}"
DB_DUMP="${4:-/root/managemovie.sql}"

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFOLD=1
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APT_GET=(apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

configure_apt_transport() {
  mkdir -p /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/99managemovie-network <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "3";
EOF
}

write_debian_13_sources() {
  if [ -d /etc/apt/sources.list.d ]; then
    find /etc/apt/sources.list.d -type f \( -name '*.list' -o -name '*.sources' \) -delete
  fi
  cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
}

upgrade_to_debian_13() {
  local codename=""
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  if [ "$codename" = "trixie" ]; then
    return 0
  fi

  configure_apt_transport
  write_debian_13_sources
  "${APT_GET[@]}" update
  "${APT_GET[@]}" -y dist-upgrade
}

configure_apt_transport
upgrade_to_debian_13

"${APT_GET[@]}" update
"${APT_GET[@]}" install -y \
  bash \
  ca-certificates \
  curl \
  ffmpeg \
  git \
  mariadb-client \
  mariadb-server \
  openssl \
  python3 \
  python3-pip \
  python3-venv \
  rsync

systemctl enable --now mariadb

mkdir -p "$PROJECT_ROOT"
rm -rf "$PROJECT_ROOT"
mkdir -p "$PROJECT_ROOT"
tar -xzf "$PROJECT_TGZ" -C "$PROJECT_ROOT"

install -m 600 "$ENV_FILE" "$PROJECT_ROOT/.env.local"

cd "$PROJECT_ROOT"
./setup.sh
./setup_https.sh
./setup_mariadb.sh

set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/.env.local"
set +a

if [ -s "$DB_DUMP" ]; then
  mysql \
    -h "${MANAGEMOVIE_DB_HOST:-127.0.0.1}" \
    -P "${MANAGEMOVIE_DB_PORT:-3306}" \
    -u "${MANAGEMOVIE_DB_USER:-managemovie}" \
    -p"${MANAGEMOVIE_DB_PASSWORD}" \
    "${MANAGEMOVIE_DB_NAME:-managemovie}" < "$DB_DUMP"
fi

if [ "${MANAGEMOVIE_REQUIRE_INITIAL_SETTINGS:-0}" = "1" ]; then
  mysql \
    -h "${MANAGEMOVIE_DB_HOST:-127.0.0.1}" \
    -P "${MANAGEMOVIE_DB_PORT:-3306}" \
    -u "${MANAGEMOVIE_DB_USER:-managemovie}" \
    -p"${MANAGEMOVIE_DB_PASSWORD}" \
    "${MANAGEMOVIE_DB_NAME:-managemovie}" \
    -e "INSERT INTO app_state (state_key, state_value) VALUES ('settings.initial_setup_done', '0') ON DUPLICATE KEY UPDATE state_value='0';"
fi

./install_systemd_service.sh
systemctl restart managemovie-web.service
systemctl is-active --quiet managemovie-web.service
echo "[systemd] managemovie-web.service active"
for _ in $(seq 1 30); do
  if curl -kfsS --max-time 3 https://127.0.0.1:8126/api/state >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -kfsS --max-time 3 https://127.0.0.1:8126/api/state >/dev/null
echo "[health] https://127.0.0.1:8126/api/state OK"
