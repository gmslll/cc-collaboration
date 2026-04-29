#!/usr/bin/env bash
# Dogfood cc-handoff against real test-backend ↔ test-frontend repos.
#
# Modes:
#   bash scripts/dogfood.sh setup     # build, start local relay, write configs
#   bash scripts/dogfood.sh cleanup   # kill relay, remove $DOGFOOD_DIR, undo configs
#   bash scripts/dogfood.sh status    # show running state
#
# Env overrides (defaults shown):
#   test_BACKEND  ../test-backend
#   test_FRONTEND ../test-frontend
#   BACKEND_BASE    origin/main          # ref to diff against in backend
#   FRONTEND_BASE   origin/main
#   RELAY_PORT      18080
#   DOGFOOD_DIR     ${TMPDIR:-/tmp}/cc-handoff-dogfood
#
# After setup, follow docs/dogfood-runbook.md.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

test_BACKEND=${test_BACKEND:-$ROOT/../test-backend}
test_FRONTEND=${test_FRONTEND:-$ROOT/../test-frontend}
BACKEND_BASE=${BACKEND_BASE:-origin/main}
FRONTEND_BASE=${FRONTEND_BASE:-origin/main}
RELAY_PORT=${RELAY_PORT:-18080}
DOGFOOD_DIR=${DOGFOOD_DIR:-${TMPDIR:-/tmp}/cc-handoff-dogfood}
DOGFOOD_DIR=${DOGFOOD_DIR%/}

# Resolve to absolute paths early — every subshell that uses them benefits.
test_BACKEND=$(cd "$test_BACKEND" 2>/dev/null && pwd || echo "$test_BACKEND")
test_FRONTEND=$(cd "$test_FRONTEND" 2>/dev/null && pwd || echo "$test_FRONTEND")

DOGFOOD_MARKER='# cc-handoff dogfood marker'

say()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$*" >&2; }
fail() { printf "\033[1;31m✘ %s\033[0m\n" "$*" >&2; exit 1; }

PIDFILE="$DOGFOOD_DIR/relay.pid"

usage() {
  cat <<'EOF'
Dogfood cc-handoff against real test-backend ↔ test-frontend repos.

Modes:
  bash scripts/dogfood.sh setup     # build, start local relay, write configs
  bash scripts/dogfood.sh cleanup   # kill relay, remove $DOGFOOD_DIR, undo configs
  bash scripts/dogfood.sh status    # show running state

Env overrides (defaults shown):
  test_BACKEND  ../test-backend
  test_FRONTEND ../test-frontend
  BACKEND_BASE    origin/main          # ref to diff against in backend
  FRONTEND_BASE   origin/main
  RELAY_PORT      18080
  DOGFOOD_DIR     ${TMPDIR:-/tmp}/cc-handoff-dogfood

After setup, follow docs/dogfood-runbook.md.
EOF
  exit 2
}

# ---------- preflight (used by setup) ----------

preflight() {
  say "preflight"

  [[ -d "$test_BACKEND/.git" ]] || fail "test_BACKEND not found or not a git repo: $test_BACKEND"
  [[ -d "$test_FRONTEND/.git" ]] || fail "test_FRONTEND not found or not a git repo: $test_FRONTEND"

  git -C "$test_BACKEND"  rev-parse --verify "$BACKEND_BASE"  >/dev/null 2>&1 \
    || fail "BACKEND_BASE '$BACKEND_BASE' not resolvable in $test_BACKEND (try BACKEND_BASE=master)"
  git -C "$test_FRONTEND" rev-parse --verify "$FRONTEND_BASE" >/dev/null 2>&1 \
    || fail "FRONTEND_BASE '$FRONTEND_BASE' not resolvable in $test_FRONTEND"

  if lsof -nP -iTCP:"$RELAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $RELAY_PORT already in use; set RELAY_PORT=... to override"
  fi

  ( cd "$ROOT" && go test ./... >/dev/null ) \
    || fail "go test failed — fix tests before dogfood"

  echo "  ✓ repos exist, base refs resolvable, port $RELAY_PORT free, tests green"
}

# ---------- setup ----------

setup() {
  # Reap any leftover relay from a previous setup before nuking DOGFOOD_DIR;
  # otherwise the orphaned process keeps holding RELAY_PORT and we'll fail
  # preflight with no clue why.
  cleanup_quiet

  preflight

  say "build binaries"
  ( cd "$ROOT" && make build >/dev/null )

  say "init dogfood dir at $DOGFOOD_DIR"
  rm -rf "$DOGFOOD_DIR"
  mkdir -p "$DOGFOOD_DIR" \
           "$DOGFOOD_DIR/home-backend/.config/cc-handoff" \
           "$DOGFOOD_DIR/home-frontend/.config/cc-handoff"

  TOK_BACK=$(openssl rand -hex 16)
  TOK_FRONT=$(openssl rand -hex 16)

  cat > "$DOGFOOD_DIR/tokens.json" <<JSON
[
  {"token": "$TOK_BACK",  "identity": "user@backend"},
  {"token": "$TOK_FRONT", "identity": "alex@frontend"}
]
JSON

  cat > "$DOGFOOD_DIR/home-backend/.config/cc-handoff/config.toml" <<TOML
relay_url = "http://127.0.0.1:$RELAY_PORT"
token     = "$TOK_BACK"
identity  = "user@backend"
TOML

  cat > "$DOGFOOD_DIR/home-frontend/.config/cc-handoff/config.toml" <<TOML
relay_url = "http://127.0.0.1:$RELAY_PORT"
token     = "$TOK_FRONT"
identity  = "alex@frontend"
TOML

  say "stamp .cc-handoff.toml into test-* repos"
  for pair in "$test_BACKEND:cc-handoff.test-backend.toml" \
              "$test_FRONTEND:cc-handoff.test-frontend.toml"; do
    repo="${pair%%:*}"
    template="${pair##*:}"
    target="$repo/.cc-handoff.toml"

    if [[ -f "$target" ]] && ! is_stamped "$target"; then
      warn "$target already exists without dogfood marker — leaving it alone."
      warn "  back it up and rerun, or run cleanup first to remove a previous dogfood stamp."
      continue
    fi
    cp "$ROOT/configs/$template" "$target"
    echo "  ✓ wrote $target"
  done

  say "start local relay on 127.0.0.1:$RELAY_PORT"
  "$ROOT/bin/cc-relay" \
    -addr "127.0.0.1:$RELAY_PORT" \
    -db "$DOGFOOD_DIR/relay.db" \
    -tokens "$DOGFOOD_DIR/tokens.json" \
    >"$DOGFOOD_DIR/relay.log" 2>&1 &
  echo $! > "$PIDFILE"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null; then break; fi
    sleep 0.2
  done
  curl -sf "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null \
    || { tail -20 "$DOGFOOD_DIR/relay.log"; fail "relay did not start"; }

  cat <<BANNER

═══════════════════════════════════════════════════════════════
  dogfood ready — follow docs/dogfood-runbook.md from here
═══════════════════════════════════════════════════════════════

  test_BACKEND  : $test_BACKEND
  test_FRONTEND : $test_FRONTEND
  RELAY           : http://127.0.0.1:$RELAY_PORT (pid $(cat "$PIDFILE"))
  RELAY LOG       : $DOGFOOD_DIR/relay.log

  在每个终端开头先 export，省得每条命令都加：
    BACKEND  > export HOME=$DOGFOOD_DIR/home-backend
    FRONTEND > export HOME=$DOGFOOD_DIR/home-frontend

  完事跑：  bash $0 cleanup

BANNER
}

# ---------- status ----------

status() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "relay : up (pid $(cat "$PIDFILE"))  http://127.0.0.1:$RELAY_PORT"
  else
    echo "relay : down"
  fi
  for repo in "$test_BACKEND" "$test_FRONTEND"; do
    target="$repo/.cc-handoff.toml"
    if is_stamped "$target"; then
      echo "config: stamped  $target"
    elif [[ -f "$target" ]]; then
      echo "config: foreign  $target  (NOT a dogfood stamp; cleanup will skip)"
    else
      echo "config: absent   $target"
    fi
  done
  echo "dir   : $DOGFOOD_DIR  ($([[ -d $DOGFOOD_DIR ]] && echo present || echo absent))"
}

# ---------- cleanup ----------

# is_stamped checks the marker on the first line of $1. Used by both setup
# (refuse to overwrite foreign configs) and cleanup (refuse to delete them).
is_stamped() { [[ -f "$1" ]] && head -1 "$1" | grep -q "$DOGFOOD_MARKER"; }

# kill_relay terminates the dogfood relay process if PIDFILE points at one.
# The pidfile content is validated as numeric to avoid `kill garbage`.
kill_relay() {
  [[ -f "$PIDFILE" ]] || return 0
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "✓ stopped relay (pid $pid)"
}

# cleanup_quiet is the silent form used by setup() to reap leftovers before
# rebuilding DOGFOOD_DIR. Skips the user-facing tip at the end.
cleanup_quiet() {
  kill_relay
  for repo in "$test_BACKEND" "$test_FRONTEND"; do
    local target="$repo/.cc-handoff.toml"
    is_stamped "$target" && rm -f "$target"
  done
  rm -rf "$DOGFOOD_DIR"
}

cleanup() {
  # Short-circuit when there's truly nothing to clean — second invocations
  # otherwise look like silent no-ops with only the trailing tip.
  if [[ ! -f "$PIDFILE" && ! -d "$DOGFOOD_DIR" ]] \
     && ! is_stamped "$test_BACKEND/.cc-handoff.toml" \
     && ! is_stamped "$test_FRONTEND/.cc-handoff.toml"; then
    echo "✓ already clean"
    return 0
  fi

  kill_relay

  for repo in "$test_BACKEND" "$test_FRONTEND"; do
    target="$repo/.cc-handoff.toml"
    if is_stamped "$target"; then
      rm -f "$target"
      echo "✓ removed $target (had dogfood marker)"
    elif [[ -f "$target" ]]; then
      warn "kept $target (no dogfood marker — looks like prod config)"
    fi
  done

  if [[ -d "$DOGFOOD_DIR" ]]; then
    rm -rf "$DOGFOOD_DIR"
    echo "✓ removed $DOGFOOD_DIR"
  fi

  echo
  echo "tip: in each repo, run  git status  to see if any handoff inboxes"
  echo "remain under .claude/handoff-inbox/  — those aren't auto-cleaned."
}

case "${1:-}" in
  setup)   setup ;;
  cleanup) cleanup ;;
  status)  status ;;
  -h|--help|"") usage ;;
  *) usage ;;
esac
