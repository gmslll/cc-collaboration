#!/usr/bin/env bash
# One-shot deploy of the relay to a Linux VPS.
#
# Usage:
#   bash scripts/deploy.sh user@your-vps
#
# Optional env:
#   ARCH=amd64|arm64  override; default = autodetect via ssh
#   SSH_OPTS="-i ~/.ssh/id_ed25519 -p 2222"
#
# Idempotent: first run installs, subsequent runs upgrade the binary +
# restart. Tokens, DB, and operational scripts are only seeded if absent.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: bash scripts/deploy.sh <user@host>" >&2
  exit 2
fi

HOST="$1"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_OPTS=${SSH_OPTS:-}
# shellcheck disable=SC2086
SSH() { ssh $SSH_OPTS "$HOST" "$@"; }
# shellcheck disable=SC2086
SCP() { scp $SSH_OPTS "$@"; }

say() { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }

say "detect remote arch"
if [[ -n "${ARCH:-}" ]]; then
  arch="$ARCH"
else
  uname_m=$(SSH 'uname -m')
  case "$uname_m" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported remote arch: $uname_m" >&2; exit 1 ;;
  esac
fi
echo "  → linux/$arch"

say "build cc-relay for linux/$arch"
( cd "$ROOT" && GOOS=linux GOARCH="$arch" CGO_ENABLED=0 \
  go build -o "bin/cc-relay-linux-$arch" ./cmd/relay )
local_bin="$ROOT/bin/cc-relay-linux-$arch"

say "stage payload to remote /tmp/cc-handoff-deploy"
remote_stage="/tmp/cc-handoff-deploy"
SSH "rm -rf $remote_stage && mkdir -p $remote_stage/scripts/systemd"
SCP "$local_bin"                                "$HOST:$remote_stage/cc-relay"
SCP "$ROOT/scripts/install.sh"                  "$HOST:$remote_stage/install.sh"
SCP "$ROOT/scripts/uninstall.sh"                "$HOST:$remote_stage/uninstall.sh"
SCP "$ROOT/scripts/rotate-token.sh"             "$HOST:$remote_stage/rotate-token.sh"
SCP "$ROOT/scripts/backup.sh"                   "$HOST:$remote_stage/backup.sh"
SCP "$ROOT/scripts/systemd/cc-handoff-relay.service" \
    "$HOST:$remote_stage/scripts/systemd/cc-handoff-relay.service"

say "install + restart on $HOST"
SSH "bash -se" <<'REMOTE'
set -euo pipefail
cd /tmp/cc-handoff-deploy
chmod +x cc-relay install.sh uninstall.sh backup.sh

# install.sh is idempotent: creates user/dirs/unit; always copies the binary
# and enables the service.
sudo BIN_SRC=./cc-relay bash install.sh

# Drop the operational scripts where they're easy to invoke later.
sudo install -m 0755 uninstall.sh    /usr/local/sbin/cc-handoff-uninstall
sudo install -m 0755 backup.sh       /usr/local/sbin/cc-handoff-backup

sudo systemctl restart cc-handoff-relay
sleep 0.5
sudo systemctl is-active --quiet cc-handoff-relay \
  || { echo "relay not active after restart"; sudo journalctl -u cc-handoff-relay -n 30; exit 1; }

echo
echo "✓ deployed"
echo
sudo systemctl status cc-handoff-relay --no-pager | head -5 || true
echo
echo "binary  : /usr/local/bin/cc-relay"
echo "data    : /var/lib/cc-handoff/relay.db"
echo
echo "ops:"
echo "  sudo -u cc-handoff /usr/local/bin/cc-relay useradd -db /var/lib/cc-handoff/relay.db -identity <you@example.com> -admin"
echo "  sudo cc-handoff-backup"
echo "  sudo cc-handoff-uninstall [--purge]"
REMOTE

say "done — point your reverse proxy at 127.0.0.1:8080 if not already"
