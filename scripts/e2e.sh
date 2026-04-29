#!/usr/bin/env bash
# End-to-end smoke test for cc-handoff (M1 + M2).
# Spins up a relay, simulates a backend dev submit and a frontend dev pickup
# in two temporary git repos. Cleans up on exit.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d -t cc-handoff-e2e.XXXXXX)
RELAY_PORT=${RELAY_PORT:-18080}
RELAY_URL="http://127.0.0.1:${RELAY_PORT}"

say() { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
fail() { printf "\033[1;31m✘ %s\033[0m\n" "$*"; exit 1; }

cleanup() {
  if [[ -n "${WATCH_PID:-}" ]] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  if [[ -n "${RELAY_PID:-}" ]] && kill -0 "$RELAY_PID" 2>/dev/null; then
    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

say "build binaries"
( cd "$ROOT" && make build >/dev/null )
CLI="$ROOT/bin/cc-handoff"
RELAY="$ROOT/bin/cc-relay"

say "prepare relay state in $TMP"
cat > "$TMP/tokens.json" <<JSON
[
  {"token": "tok-backend",  "identity": "user@backend"},
  {"token": "tok-frontend", "identity": "alex@frontend"}
]
JSON

say "start relay on $RELAY_URL"
"$RELAY" -addr "127.0.0.1:${RELAY_PORT}" -db "$TMP/relay.db" -tokens "$TMP/tokens.json" >"$TMP/relay.log" 2>&1 &
RELAY_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf "$RELAY_URL/healthz" >/dev/null; then break; fi
  sleep 0.2
done
curl -sf "$RELAY_URL/healthz" >/dev/null || { echo "relay did not start"; cat "$TMP/relay.log"; exit 1; }

# ---- backend repo ----
BACK="$TMP/backend"
mkdir -p "$BACK/docs"
git -C "$BACK" -c init.defaultBranch=main init -q
git -C "$BACK" config user.email "user@example.com"
git -C "$BACK" config user.name  "user"
echo "# backend" > "$BACK/README.md"
# Initial swagger (baseline, before the change being submitted).
cat > "$BACK/docs/swagger.yaml" <<'YAML'
openapi: 3.0.0
info: { title: test, version: 0.0.1 }
paths:
  /customers:
    get:
      operationId: listCustomers
      summary: list customers
YAML
git -C "$BACK" add . && git -C "$BACK" commit -qm "init"
git -C "$BACK" update-ref refs/remotes/origin/main HEAD

# Make a meaningful change so HEAD != origin/main: new module + new endpoint.
mkdir -p "$BACK/internal/module/customers/handler"
mkdir -p "$BACK/internal/module/customers/dto"
cat > "$BACK/internal/module/customers/handler/routes.go" <<'GO'
package handler
func Register() {} // POST /customers/export added
GO
cat > "$BACK/internal/module/customers/dto/request.go" <<'GO'
package dto
type ExportRequest struct{ Format string }
GO
cat > "$BACK/docs/swagger.yaml" <<'YAML'
openapi: 3.0.0
info: { title: test, version: 0.0.1 }
paths:
  /customers:
    get:
      operationId: listCustomers
      summary: list customers
  /customers/export:
    post:
      operationId: exportCustomers
      summary: export customers
YAML
git -C "$BACK" add . && git -C "$BACK" commit -qm "feat(customers): export endpoint"

mkdir -p "$BACK/.claude/handoff-inbox"
cat > "$BACK/.claude/handoff-inbox/.draft-summary.md" <<'MD'
新增 POST /customers/export，导出客户列表为 CSV。

- 入参: { format: "csv"|"xlsx", fields: string[] }
- 出参: 二进制文件流
- 错误: 401 未登录, 403 无权限, 422 字段非法
MD

HOME="$TMP/home-backend"
mkdir -p "$HOME"
say "backend: write user config + repo config (with partner_mapping rules)"
mkdir -p "$HOME/.config/cc-handoff"
cat > "$HOME/.config/cc-handoff/config.toml" <<TOML
relay_url = "$RELAY_URL"
token     = "tok-backend"
identity  = "user@backend"
TOML
cat > "$BACK/.cc-handoff.toml" <<'TOML'
[identity]
partner = "alex@frontend"

[paths]
swagger = "docs/swagger.yaml"
base    = "origin/main"
repo    = "backend-demo"

[partner_mapping]
[[partner_mapping.rule]]
when_path_matches         = "^internal/module/(?P<domain>[^/]+)/dto/"
suggest_edit              = ["types/{domain}.ts"]

[[partner_mapping.rule]]
when_path_matches         = "^internal/module/(?P<domain>[^/]+)/"
suggest_edit              = ["lib/api/{domain}.ts"]
suggest_create_if_missing = true

[triggers]
auto_launch = false
TOML

# Prime the swagger cache with the *baseline* spec by checking out the parent
# commit's swagger.yaml, running a throwaway submit (which writes the baseline
# to ~/.cache/cc-handoff/...), then restoring the head version. The real submit
# below then produces a delta that only contains the new endpoint.
git -C "$BACK" checkout -q HEAD~1 -- docs/swagger.yaml
( cd "$BACK" && HOME="$HOME" "$CLI" submit --to alex@frontend >"$TMP/prime.log" 2>&1 ) || { echo "priming submit failed:"; cat "$TMP/prime.log"; exit 1; }
git -C "$BACK" checkout -q HEAD -- docs/swagger.yaml

# ---- frontend repo ----
FRONT="$TMP/frontend"
mkdir -p "$FRONT"
git -C "$FRONT" -c init.defaultBranch=main init -q
git -C "$FRONT" config user.email "alex@example.com"
git -C "$FRONT" config user.name  "alex"
echo "# frontend" > "$FRONT/README.md"
git -C "$FRONT" add . && git -C "$FRONT" commit -qm "init"
git -C "$FRONT" update-ref refs/remotes/origin/main HEAD

HOME_F="$TMP/home-frontend"
mkdir -p "$HOME_F/.config/cc-handoff"
say "frontend: write user config + repo config"
cat > "$HOME_F/.config/cc-handoff/config.toml" <<TOML
relay_url = "$RELAY_URL"
token     = "tok-frontend"
identity  = "alex@frontend"
TOML
cat > "$FRONT/.cc-handoff.toml" <<'TOML'
[identity]
partner = "user@backend"

[paths]
base = "origin/main"
repo = "frontend-demo"
TOML

say "frontend: start cc-handoff watch (will exit after 1 event)"
( cd "$FRONT" && HOME="$HOME_F" "$CLI" watch --no-notify --stop-after 1 ) >"$TMP/watch.log" 2>&1 &
WATCH_PID=$!
sleep 0.5  # give watch a moment to subscribe

say "backend: cc-handoff submit"
SUBMIT_OUT=$( cd "$BACK" && HOME="$HOME" "$CLI" submit )
echo "$SUBMIT_OUT"
HID=$(echo "$SUBMIT_OUT" | awk '/submitted handoff/{print $4}')
[[ -n "$HID" ]] || fail "could not extract handoff id"
echo "$SUBMIT_OUT" | grep -q "targeting_hints=" || fail "no targeting_hints in submit output"
echo "$SUBMIT_OUT" | grep -q "api_delta:"        || fail "no api_delta in submit output"

say "wait for watch to process"
for _ in $(seq 1 50); do
  if [[ -d "$FRONT/.claude/handoff-inbox/$HID" ]]; then break; fi
  sleep 0.1
done
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
INBOX="$FRONT/.claude/handoff-inbox/$HID"
[[ -d "$INBOX" ]] || { cat "$TMP/watch.log"; fail "watch did not materialize $INBOX"; }

# Assertions on materialized files
say "verify materialized files in $INBOX"
for f in package.json summary.md prompt.md full.diff api-delta.md; do
  [[ -f "$INBOX/$f" ]] || fail "missing $f"
done
grep -q "POST /customers/export"   "$INBOX/summary.md"  || fail "summary content lost"
grep -q "lib/api/customers.ts"     "$INBOX/prompt.md"   || fail "rules engine did not produce hint for lib/api/customers.ts"
grep -q "types/customers.ts"       "$INBOX/prompt.md"   || fail "rules engine did not produce hint for types/customers.ts"
grep -q "POST /customers/export"   "$INBOX/api-delta.md" || fail "swagger delta did not include new endpoint"

say "M1+M2 e2e PASS  (handoff $HID)"

# ---------------------------------------------------------------------------
# M4.1 — urgent + auto_launch=true ⇒ watch should "auto-launch" a terminal
# Use --no-launch so we exercise the build-script path without actually
# opening a window; assert the would-launch line lands in stderr.
# ---------------------------------------------------------------------------

say "M4.1: flip frontend to auto_launch=true and re-watch with --no-launch"
cat > "$FRONT/.cc-handoff.toml" <<'TOML'
[identity]
partner = "user@backend"

[paths]
base = "origin/main"
repo = "frontend-demo"

[triggers]
auto_launch  = true
terminal_app = "terminal"
TOML

# Make a second backend commit so submit produces a fresh handoff (the diff
# context isn't important for this assertion; reuse summary).
mkdir -p "$BACK/internal/module/orders/handler"
echo "package handler // POST /orders/export" > "$BACK/internal/module/orders/handler/routes.go"
git -C "$BACK" add . && git -C "$BACK" commit -qm "feat(orders): export"

cat > "$BACK/.claude/handoff-inbox/.draft-summary.md" <<'MD'
新增 POST /orders/export，紧急任务。
MD

( cd "$FRONT" && HOME="$HOME_F" "$CLI" watch --no-notify --no-launch --stop-after 1 ) >"$TMP/watch-urgent.log" 2>&1 &
WATCH_PID=$!
sleep 0.5

say "backend: cc-handoff submit --urgent"
URG_OUT=$( cd "$BACK" && HOME="$HOME" "$CLI" submit --urgent )
echo "$URG_OUT"
HID2=$(echo "$URG_OUT" | awk '/submitted handoff/{print $4}')
[[ -n "$HID2" ]] || fail "could not extract second handoff id"

say "wait for watch to process urgent handoff"
for _ in $(seq 1 50); do
  if [[ -d "$FRONT/.claude/handoff-inbox/$HID2" ]]; then break; fi
  sleep 0.1
done
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

INBOX2="$FRONT/.claude/handoff-inbox/$HID2"
[[ -d "$INBOX2" ]] || { cat "$TMP/watch-urgent.log"; fail "watch did not materialize $INBOX2"; }

# The dry-run line is emitted by internal/notify/mac_launch.go on darwin.
# On other OSes the launch helper returns an error which the watch surfaces
# as a "warning: auto-launch failed" line — accept either.
if [[ "$(uname -s)" == "Darwin" ]]; then
  grep -q "would launch terminal=terminal" "$TMP/watch-urgent.log" \
    || { cat "$TMP/watch-urgent.log"; fail "M4.1: missing would-launch line"; }
  grep -q "$INBOX2/prompt.md" "$TMP/watch-urgent.log" \
    || fail "M4.1: would-launch line missing prompt path"
else
  grep -q "auto-launch failed" "$TMP/watch-urgent.log" \
    || { cat "$TMP/watch-urgent.log"; fail "M4.1: expected unsupported-platform warning"; }
fi

say "M4.1 e2e PASS  (handoff $HID2)"

# ---------------------------------------------------------------------------
# M4.2 — back-channel comments: frontend → backend, then backend → frontend.
# Each direction starts a fresh `watch --stop-after 1` on the receiving side
# before the comment is posted, so the SSE event lands.
# ---------------------------------------------------------------------------

say "M4.2: frontend → backend comment"
( cd "$BACK" && HOME="$HOME" "$CLI" watch --no-notify --no-launch --stop-after 1 ) >"$TMP/watch-back-comment.log" 2>&1 &
WATCH_PID=$!
sleep 0.5

( cd "$FRONT" && HOME="$HOME_F" "$CLI" comment "$HID2" "Q: what's the export response shape?" ) \
  | grep -q "posted comment" || fail "M4.2: frontend post comment failed"

wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
BACK_INBOX="$BACK/.claude/handoff-inbox/$HID2"
[[ -f "$BACK_INBOX/comments.md" ]] || { cat "$TMP/watch-back-comment.log"; fail "M4.2: backend comments.md missing"; }
grep -q "alex@frontend" "$BACK_INBOX/comments.md" || fail "M4.2: backend comments.md missing sender"
grep -q "export response shape" "$BACK_INBOX/comments.md" || fail "M4.2: backend comments.md missing body"

say "M4.2: backend → frontend comment"
( cd "$FRONT" && HOME="$HOME_F" "$CLI" watch --no-notify --no-launch --stop-after 1 ) >"$TMP/watch-front-comment.log" 2>&1 &
WATCH_PID=$!
sleep 0.5

( cd "$BACK" && HOME="$HOME" "$CLI" comment "$HID2" "Returns binary blob with Content-Type set." ) \
  | grep -q "posted comment" || fail "M4.2: backend post comment failed"

wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
FRONT_COMMENTS="$FRONT/.claude/handoff-inbox/$HID2/comments.md"
[[ -f "$FRONT_COMMENTS" ]] || { cat "$TMP/watch-front-comment.log"; fail "M4.2: frontend comments.md missing"; }
grep -q "user@backend" "$FRONT_COMMENTS" || fail "M4.2: frontend comments.md missing sender"
grep -q "binary blob" "$FRONT_COMMENTS" || fail "M4.2: frontend comments.md missing body"

# `--list` should round-trip what was posted via /v1/handoffs/{id}/comments.
LIST_OUT=$( cd "$BACK" && HOME="$HOME" "$CLI" comment --list "$HID2" )
echo "$LIST_OUT" | grep -q "alex@frontend" || fail "M4.2: comment --list missing alex"
echo "$LIST_OUT" | grep -q "user@backend"   || fail "M4.2: comment --list missing user"

say "M4.2 e2e PASS"

# ---------------------------------------------------------------------------
# M4.3 — large diff overflows into attachments/full.diff. Generate a >250KB
# fixture, ensure the diff inline preview is truncated, and verify the
# attachment is present + sha256 matches.
# ---------------------------------------------------------------------------

say "M4.3: large-diff fixture (≥250KB) → attachment"

# Frontend back to non-urgent + auto_launch off so this submit doesn't fire
# the launch path and the watch from this section reads its own handoff.
cat > "$FRONT/.cc-handoff.toml" <<'TOML'
[identity]
partner = "user@backend"

[paths]
base = "origin/main"
repo = "frontend-demo"

[triggers]
auto_launch = false
TOML

# Generate ~260KB of pseudo-randomish text the git diff will carry whole.
mkdir -p "$BACK/internal/module/bigfile"
python3 -c "
import os, random
random.seed(0)
with open('$BACK/internal/module/bigfile/data.go','w') as f:
    f.write('package bigfile\n\nvar Data = []string{\n')
    for _ in range(8000):
        s = ''.join(random.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(30))
        f.write('  \"'+s+'\",\n')
    f.write('}\n')
"

git -C "$BACK" add . && git -C "$BACK" commit -qm "feat(bigfile): bulk data"

cat > "$BACK/.claude/handoff-inbox/.draft-summary.md" <<'MD'
新增大数据文件，diff 会触发附件上传路径。
MD

( cd "$FRONT" && HOME="$HOME_F" "$CLI" watch --no-notify --no-launch --stop-after 1 ) >"$TMP/watch-attach.log" 2>&1 &
WATCH_PID=$!
sleep 0.5

say "backend: cc-handoff submit (large diff)"
ATT_OUT=$( cd "$BACK" && HOME="$HOME" "$CLI" submit )
echo "$ATT_OUT"
HID3=$(echo "$ATT_OUT" | awk '/submitted handoff/{print $4}')
[[ -n "$HID3" ]] || fail "M4.3: could not extract handoff id"
echo "$ATT_OUT" | grep -q "attachments=1 (full.diff)" \
  || fail "M4.3: submit output missing attachments line"

say "wait for watch to download attachment"
for _ in $(seq 1 80); do
  if [[ -f "$FRONT/.claude/handoff-inbox/$HID3/attachments/full.diff" ]]; then break; fi
  sleep 0.1
done
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

INBOX3="$FRONT/.claude/handoff-inbox/$HID3"
[[ -f "$INBOX3/attachments/full.diff" ]] || { cat "$TMP/watch-attach.log"; fail "M4.3: attachments/full.diff missing"; }

# Inline preview must be truncated, not full.
INLINE_BYTES=$(wc -c < "$INBOX3/full.diff")
[[ $INLINE_BYTES -lt 250000 ]] || fail "M4.3: inline full.diff still has $INLINE_BYTES bytes (expected truncation)"
grep -q "truncated" "$INBOX3/full.diff" || fail "M4.3: inline full.diff missing 'truncated' marker"

# sha256(attachments/full.diff) must match package.json metadata.
EXPECTED=$(python3 -c "import json,sys; p=json.load(open('$INBOX3/package.json')); print(p['attachments'][0]['sha256'])")
ACTUAL=$(shasum -a 256 "$INBOX3/attachments/full.diff" | awk '{print $1}')
[[ "$EXPECTED" == "$ACTUAL" ]] || fail "M4.3: sha256 mismatch (expected=$EXPECTED actual=$ACTUAL)"

say "M4.3 e2e PASS  (handoff $HID3, attachment $ACTUAL)"

# ---------------------------------------------------------------------------
# M4.4 — relay emits structured JSON audit log on stderr.
# ---------------------------------------------------------------------------

say "M4.4: structured audit log on relay stderr"
echo "--- relay.log tail ---"
tail -5 "$TMP/relay.log"

# At minimum every request should be one JSON line with msg=relay.request.
grep -q '"msg":"relay.request"' "$TMP/relay.log" \
  || { tail -20 "$TMP/relay.log"; fail "M4.4: relay.log missing JSON request lines"; }

# Submit lines should carry identity=user@backend.
grep -E '"path":"/v1/handoffs",' "$TMP/relay.log" | grep -q '"identity":"user@backend"' \
  || { grep -E '"path":"/v1/handoffs",' "$TMP/relay.log" | head -3; fail "M4.4: submit log missing identity=user@backend"; }

# Comment/attachment paths should expose handoff_id.
grep -E '/v1/handoffs/h_[^/]+/(comment|attachments)' "$TMP/relay.log" | grep -q '"handoff_id":"h_' \
  || fail "M4.4: comment/attachment log missing handoff_id"

# Status and ms fields must be present on every line.
grep -q '"status":' "$TMP/relay.log" || fail "M4.4: missing status field"
grep -q '"ms":'     "$TMP/relay.log" || fail "M4.4: missing ms field"

say "M4.4 e2e PASS"
