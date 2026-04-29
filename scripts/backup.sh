#!/usr/bin/env bash
# Hot-snapshot the relay SQLite DB. Uses `sqlite3 .backup` so WAL files are
# captured consistently without stopping the relay.
#
# Usage:
#   sudo bash backup.sh                 # one-shot, default keep=7
#   sudo KEEP=30 bash backup.sh         # keep last 30 backups
#
# Recommended: hook into cron daily, e.g.
#   0 4 * * * /usr/local/bin/backup.sh >> /var/log/cc-handoff-backup.log 2>&1

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must be run as root" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 required (apt install sqlite3 / dnf install sqlite)" >&2
  exit 1
fi

DB=${DB:-/var/lib/cc-handoff/relay.db}
DEST=${DEST:-/var/lib/cc-handoff/backups}
KEEP=${KEEP:-7}

if [[ ! -f "$DB" ]]; then
  echo "DB not found at $DB" >&2
  exit 1
fi

install -d -m 0750 -o cc-handoff -g cc-handoff "$DEST"

stamp=$(date -u +%Y%m%d-%H%M%SZ)
out="$DEST/relay-$stamp.db"

# .backup copies pages while the WAL is held quiescent — safe on a live DB.
sqlite3 "$DB" ".backup '$out'"
gzip -9 "$out"
chown cc-handoff:cc-handoff "$out.gz"
chmod 0640 "$out.gz"

bytes=$(stat -c %s "$out.gz" 2>/dev/null || stat -f %z "$out.gz")
echo "✓ snapshot $out.gz ($bytes bytes)"

# Prune oldest beyond KEEP.
ls -1t "$DEST"/relay-*.db.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
  rm -f -- "$f"
  echo "  pruned $f"
done
