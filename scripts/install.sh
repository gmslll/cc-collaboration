#!/usr/bin/env bash
# Install cc-handoff relay on a Linux VPS.
# Usage:  sudo bash install.sh
# Run from the repo root after building (`make relay` or `go build -o cc-relay ./cmd/relay`).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must be run as root" >&2
  exit 1
fi

BIN_SRC=${BIN_SRC:-./cc-relay}
if [[ ! -x "$BIN_SRC" ]]; then
  echo "binary $BIN_SRC not found; build first: GOOS=linux GOARCH=amd64 go build -o cc-relay ./cmd/relay" >&2
  exit 1
fi

id cc-handoff >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin cc-handoff

install -m 0755 "$BIN_SRC" /usr/local/bin/cc-relay

install -d -m 0755 -o cc-handoff -g cc-handoff /var/lib/cc-handoff
install -d -m 0750 -o root      -g cc-handoff /etc/cc-handoff

if [[ ! -f /etc/cc-handoff/tokens.json ]]; then
  cat > /etc/cc-handoff/tokens.json <<'JSON'
[
  {"token": "REPLACE_ME_WITH_A_LONG_RANDOM_STRING", "identity": "you@backend"},
  {"token": "REPLACE_ME_TOO",                       "identity": "alex@frontend"}
]
JSON
  chown root:cc-handoff /etc/cc-handoff/tokens.json
  chmod 0640 /etc/cc-handoff/tokens.json
  echo "wrote sample /etc/cc-handoff/tokens.json — edit it and SIGHUP cc-handoff-relay (M2) or restart for now."
fi

install -m 0644 scripts/systemd/cc-handoff-relay.service /etc/systemd/system/cc-handoff-relay.service
systemctl daemon-reload
systemctl enable --now cc-handoff-relay

systemctl status cc-handoff-relay --no-pager
echo
echo "Done. Put cc-handoff-relay behind a TLS-terminating reverse proxy (caddy / nginx)."
