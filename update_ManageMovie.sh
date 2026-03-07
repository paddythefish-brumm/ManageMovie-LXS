#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_URL="${MANAGEMOVIE_UPDATE_REPO_URL:-https://github.com/paddythefish-brumm/ManageMovie-LXS.git}"
BRANCH="${MANAGEMOVIE_UPDATE_BRANCH:-main}"
TAG=""
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./update_ManageMovie.sh [--check] [--branch NAME] [--tag TAG]

Optionen:
  --check         nur lokalen und entfernten Stand anzeigen
  --branch NAME   Branch fuer Update (Default: main)
  --tag TAG       optional exakten Tag aktivieren
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

need_cmd git
need_cmd rsync
need_cmd curl

local_version="$(grep -E -m1 '^VERSION = "[0-9]+\.[0-9]+\.[0-9]+"' "$BASE_DIR/managemovie-web/app/managemovie.py" | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' || true)"
remote_head="$(git ls-remote "$REMOTE_URL" "refs/heads/${BRANCH}" | awk '{print $1}' | head -n1)"

echo "Lokal:   ${local_version:-unbekannt}"
echo "Remote:  ${REMOTE_URL}"
echo "Branch:  ${BRANCH}"
echo "HEAD:    ${remote_head:-unbekannt}"

if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 0
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" "$TMP_DIR/repo" >/dev/null
if [ -n "$TAG" ]; then
  git -C "$TMP_DIR/repo" fetch --tags >/dev/null
  git -C "$TMP_DIR/repo" checkout --force "$TAG" >/dev/null
fi

rsync -a --delete \
  --exclude '.git/' \
  --exclude '.venv/' \
  --exclude '.env' \
  --exclude '.env.local' \
  --exclude 'MovieManager/' \
  --exclude 'logs/' \
  --exclude 'work/' \
  --exclude 'temp/' \
  --exclude 'certs/' \
  "$TMP_DIR/repo/" "$BASE_DIR/"

chmod +x \
  "$BASE_DIR/setup.sh" \
  "$BASE_DIR/start.sh" \
  "$BASE_DIR/stop.sh" \
  "$BASE_DIR/install_systemd_service.sh" \
  "$BASE_DIR/setup_https.sh" \
  "$BASE_DIR/setup_mariadb.sh" \
  "$BASE_DIR/update_ManageMovie.sh"

cd "$BASE_DIR"
./setup.sh >/tmp/managemovie-update-setup.log 2>&1
systemctl restart managemovie-web.service
curl -sk https://127.0.0.1/api/state
