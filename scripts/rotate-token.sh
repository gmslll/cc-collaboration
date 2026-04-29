#!/usr/bin/env bash
# Rotate the bearer token for one identity in /etc/cc-handoff/tokens.json,
# then restart the relay. Prints the new token to stdout — distribute it
# to the affected client and update their ~/.config/cc-handoff/config.toml.
#
# Usage:
#   sudo bash rotate-token.sh <identity>
#   sudo bash rotate-token.sh <identity> --token <new-token>   # bring your own
#
# Examples:
#   sudo bash rotate-token.sh alex@frontend
#   sudo bash rotate-token.sh user@backend --token "$(openssl rand -hex 32)"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must be run as root" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "usage: rotate-token.sh <identity> [--token NEW_TOKEN]" >&2
  exit 2
fi

IDENTITY="$1"
shift

NEW_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)   NEW_TOKEN="$2"; shift 2 ;;
    --token=*) NEW_TOKEN="${1#--token=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$NEW_TOKEN" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl not found and no --token provided" >&2
    exit 1
  fi
  NEW_TOKEN=$(openssl rand -hex 32)
fi

TOKENS_FILE=/etc/cc-handoff/tokens.json
if [[ ! -f "$TOKENS_FILE" ]]; then
  echo "$TOKENS_FILE not found — is the relay installed?" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required to safely edit $TOKENS_FILE" >&2
  exit 1
fi

# Atomic update via python: load, mutate the matching identity (or append),
# write to a temp file, then mv-replace.
python3 - "$TOKENS_FILE" "$IDENTITY" "$NEW_TOKEN" <<'PY'
import json, os, sys, tempfile

path, identity, new_token = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r") as f:
    entries = json.load(f)

found = False
for e in entries:
    if e.get("identity") == identity:
        e["token"] = new_token
        found = True
        break
if not found:
    entries.append({"token": new_token, "identity": identity})

dirpath = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=dirpath, prefix=".tokens.", suffix=".json")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(entries, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o640)
    os.rename(tmp, path)
except Exception:
    os.unlink(tmp)
    raise

print(("APPENDED " if not found else "ROTATED  ") + identity, file=sys.stderr)
PY

# Preserve ownership/perms (root:cc-handoff 0640) the install script set up.
chown root:cc-handoff "$TOKENS_FILE"
chmod 0640 "$TOKENS_FILE"

systemctl restart cc-handoff-relay
sleep 0.5
systemctl is-active --quiet cc-handoff-relay \
  || { echo "✘ relay failed to come back up; check journalctl -u cc-handoff-relay" >&2; exit 1; }

echo
echo "==============================================================="
echo "  identity : $IDENTITY"
echo "  new token: $NEW_TOKEN"
echo "==============================================================="
echo
echo "Update the affected client's ~/.config/cc-handoff/config.toml:"
echo "  token = \"$NEW_TOKEN\""
echo
echo "Existing watch sessions on that client will reconnect within ~30s."
