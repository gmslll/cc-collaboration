#!/usr/bin/env bash
# Uninstall cc-handoff relay from a Linux VPS.
#
# Usage:
#   sudo bash uninstall.sh             # stops/removes service+binary, KEEPS data
#   sudo bash uninstall.sh --purge     # also removes data, tokens, and the
#                                      # cc-handoff system user

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must be run as root" >&2
  exit 1
fi

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then PURGE=1; fi

if systemctl list-unit-files | grep -q '^cc-handoff-relay\.service'; then
  systemctl disable --now cc-handoff-relay || true
  rm -f /etc/systemd/system/cc-handoff-relay.service
  systemctl daemon-reload
  echo "✓ stopped + removed cc-handoff-relay.service"
fi

rm -f /usr/local/bin/cc-relay
echo "✓ removed /usr/local/bin/cc-relay"

if [[ $PURGE -eq 1 ]]; then
  rm -rf /var/lib/cc-handoff
  rm -rf /etc/cc-handoff
  if id cc-handoff >/dev/null 2>&1; then
    userdel cc-handoff || true
  fi
  echo "✓ purged data dir, config, and cc-handoff user"
else
  echo
  echo "data preserved at /var/lib/cc-handoff (DB) and /etc/cc-handoff (tokens)."
  echo "to wipe completely: sudo bash uninstall.sh --purge"
fi
