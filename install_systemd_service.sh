#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/scripts/lib/common.sh"
mm_cd_project_root
mm_load_project_env

if [ "$(id -u)" -ne 0 ]; then
  echo "Fehler: Dieses Skript muss als root laufen." >&2
  exit 1
fi

SERVICE_NAME="${MANAGEMOVIE_SYSTEMD_SERVICE_NAME:-managemovie-web.service}"
SERVICE_USER="${MANAGEMOVIE_SYSTEMD_USER:-managemovie-web}"
SERVICE_PRIVATE_GROUP_DEFAULT="managemovie-web"
SERVICE_NFS_GROUP_DEFAULT="${MANAGEMOVIE_SYSTEMD_NFS_PRIMARY_GROUP:-users}"
SERVICE_GROUP="${MANAGEMOVIE_SYSTEMD_GROUP:-$SERVICE_PRIVATE_GROUP_DEFAULT}"
SERVICE_EXTRA_GROUPS_RAW="${MANAGEMOVIE_SYSTEMD_SUPPLEMENTARY_GROUPS:-}"
PROJECT_ROOT="$(mm_project_root)"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
START_SCRIPT="${PROJECT_ROOT}/start.sh"
BOOT_CHECK_SCRIPT="${PROJECT_ROOT}/scripts/check_start_on_boot.sh"
DATA_ROOT="$(mm_normalize_data_root "${MANAGEMOVIE_DATA_ROOT:-}")"
SERVICE_EXTRA_GROUPS=()

if [ ! -x "$START_SCRIPT" ]; then
  echo "Fehler: Startskript nicht gefunden oder nicht ausfuehrbar: $START_SCRIPT" >&2
  exit 1
fi
if [ ! -x "$BOOT_CHECK_SCRIPT" ]; then
  echo "Fehler: Boot-Check-Skript nicht gefunden oder nicht ausfuehrbar: $BOOT_CHECK_SCRIPT" >&2
  exit 1
fi

if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
  groupadd --system "$SERVICE_GROUP"
fi

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --gid "$SERVICE_GROUP" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi

if [ -z "${MANAGEMOVIE_SYSTEMD_GROUP:-}" ] \
  && [ -n "$SERVICE_NFS_GROUP_DEFAULT" ] \
  && [ -d "/mnt/NFS/GK-Filer" ] \
  && getent group "$SERVICE_NFS_GROUP_DEFAULT" >/dev/null 2>&1; then
  SERVICE_GROUP="$SERVICE_NFS_GROUP_DEFAULT"
fi

if [ -z "${MANAGEMOVIE_SYSTEMD_SUPPLEMENTARY_GROUPS:-}" ]; then
  if [ "$SERVICE_GROUP" != "$SERVICE_PRIVATE_GROUP_DEFAULT" ] && getent group "$SERVICE_PRIVATE_GROUP_DEFAULT" >/dev/null 2>&1; then
    SERVICE_EXTRA_GROUPS_RAW="$SERVICE_PRIVATE_GROUP_DEFAULT"
  fi
  if [ "$SERVICE_GROUP" != "users" ] && getent group "users" >/dev/null 2>&1; then
    if [ -n "$SERVICE_EXTRA_GROUPS_RAW" ]; then
      SERVICE_EXTRA_GROUPS_RAW="${SERVICE_EXTRA_GROUPS_RAW},users"
    else
      SERVICE_EXTRA_GROUPS_RAW="users"
    fi
  fi
fi

for raw_group in $SERVICE_EXTRA_GROUPS_RAW; do
  group_name="${raw_group//,/ }"
  for candidate in $group_name; do
    if [ -n "$candidate" ] && getent group "$candidate" >/dev/null 2>&1; then
      SERVICE_EXTRA_GROUPS+=("$candidate")
    fi
  done
done

mkdir -p "$DATA_ROOT"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_ROOT"
chmod -R u+rwX,go-rwx "$DATA_ROOT"
mm_fix_runtime_permissions "$DATA_ROOT" "$SERVICE_USER" "$SERVICE_GROUP"

chmod -R a+rX "$PROJECT_ROOT/managemovie-web" "$PROJECT_ROOT/mariadb" "$PROJECT_ROOT/scripts"
chmod a+rx "$START_SCRIPT"
chmod a+rx "$BOOT_CHECK_SCRIPT"

if [ -f "$PROJECT_ROOT/.env.local" ]; then
  chown root:"$SERVICE_GROUP" "$PROJECT_ROOT/.env.local"
  chmod 640 "$PROJECT_ROOT/.env.local"
fi

cat >"$UNIT_PATH" <<EOF
[Unit]
Description=ManageMovie Web Service
Wants=network-online.target mariadb.service
After=network-online.target mariadb.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
$(if [ "${#SERVICE_EXTRA_GROUPS[@]}" -gt 0 ]; then printf 'SupplementaryGroups=%s\n' "${SERVICE_EXTRA_GROUPS[*]}"; fi)
WorkingDirectory=${PROJECT_ROOT}
ExecStart=${START_SCRIPT}
ExecCondition=${BOOT_CHECK_SCRIPT}
Restart=on-failure
RestartSec=3
TimeoutStartSec=40
TimeoutStopSec=20
Environment=PYTHONUNBUFFERED=1
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
LockPersonality=true
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "[systemd] aktiviert: $SERVICE_NAME"
echo "[systemd] user/group: $SERVICE_USER:$SERVICE_GROUP"
if [ "${#SERVICE_EXTRA_GROUPS[@]}" -gt 0 ]; then
  echo "[systemd] supplementary groups: ${SERVICE_EXTRA_GROUPS[*]}"
fi
systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,15p'
