#!/usr/bin/env bash

MM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MM_PROJECT_ROOT="$(cd "$MM_LIB_DIR/../.." && pwd)"

mm_project_root() {
  printf '%s\n' "$MM_PROJECT_ROOT"
}

mm_load_project_env() {
  local env_file
  for env_file in "$MM_PROJECT_ROOT/.env.local" "$MM_PROJECT_ROOT/.env"; do
    if [ -f "$env_file" ]; then
      set -a
      # shellcheck disable=SC1090
      source "$env_file"
      set +a
    fi
  done
}

mm_cd_project_root() {
  cd "$MM_PROJECT_ROOT"
}

mm_join_project_path() {
  local rel="$1"
  rel="${rel#./}"
  printf '%s/%s\n' "$MM_PROJECT_ROOT" "$rel"
}

mm_normalize_data_root() {
  local raw="${1:-${MANAGEMOVIE_DATA_ROOT:-./MovieManager}}"
  local legacy_root="$MM_PROJECT_ROOT/MovieMaager"
  local normalized="$raw"

  if [ "${normalized##*/}" = "MovieMaager" ]; then
    normalized="${normalized%MovieMaager}MovieManager"
  fi

  if [ "${normalized#/}" = "$normalized" ]; then
    normalized="$(mm_join_project_path "$normalized")"
  fi

  if [ "${normalized##*/}" = "MovieManager" ] && [ ! -e "$normalized" ] && [ -e "$legacy_root" ]; then
    mv "$legacy_root" "$normalized"
  fi

  printf '%s\n' "$normalized"
}

mm_detect_default_folder() {
  if [ -d "/mnt/NFS/GK-Filer" ]; then
    printf '%s\n' "/mnt/NFS/GK-Filer"
    return
  fi
  if [ -d "/mnt" ]; then
    printf '%s\n' "/mnt"
    return
  fi
  printf '%s\n' "$HOME"
}

mm_ensure_data_layout() {
  local data_root="$1"
  mkdir -p \
    "$data_root/work" \
    "$data_root/temp" \
    "$data_root/logs" \
    "$data_root/certs/server" \
    "$data_root/certs/ca"
}

mm_fix_runtime_permissions() {
  local data_root="$1"
  local service_user="${2:-${MANAGEMOVIE_SYSTEMD_USER:-managemovie-web}}"
  local service_group="${3:-${MANAGEMOVIE_SYSTEMD_GROUP:-$service_user}}"

  mkdir -p "$data_root/work" "$data_root/temp" "$data_root/logs"

  if ! id -u "$service_user" >/dev/null 2>&1; then
    return 0
  fi
  if ! getent group "$service_group" >/dev/null 2>&1; then
    return 0
  fi

  chown -R "$service_user:$service_group" \
    "$data_root/work" \
    "$data_root/temp" \
    "$data_root/logs"
  chmod -R u+rwX,go-rwx \
    "$data_root/work" \
    "$data_root/temp" \
    "$data_root/logs"
}

mm_init_state_files() {
  local data_root="$1"
  local _default_folder="$2"
  [ -f "$data_root/VERSION.current" ] || printf '1\n' > "$data_root/VERSION.current"
}

mm_seed_secret_file() {
  # Legacy no-op: API-Keys werden in MariaDB verwaltet.
  return 0
}

mm_require_file() {
  local file_path="$1"
  local label="$2"
  if [ ! -f "$file_path" ]; then
    echo "Fehler: ${label} nicht gefunden unter $file_path" >&2
    exit 1
  fi
}

mm_venv_python() {
  printf '%s\n' "$MM_PROJECT_ROOT/.venv/bin/python"
}

mm_ensure_venv() {
  local venv_dir="$MM_PROJECT_ROOT/.venv"
  local venv_py="$venv_dir/bin/python"

  if [ ! -x "$venv_py" ]; then
    echo "[setup] Erstelle virtuelle Umgebung..."
    python3 -m venv "$venv_dir"
  fi

  if ! "$venv_py" -c "import pip" >/dev/null 2>&1; then
    echo "[setup] venv ist unvollstaendig (pip fehlt), erstelle neu..."
    rm -rf "$venv_dir"
    python3 -m venv "$venv_dir"
  fi

  "$venv_py" -m ensurepip --upgrade >/dev/null 2>&1 || true
}
