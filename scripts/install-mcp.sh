#!/usr/bin/env bash
# Fallback: register cc-handoff-mcp with Claude Code as a user-scope MCP server.
#
# Recommended path is `cc-handoff init --with-mcp`, which dispatches per agent
# (claude auto-registers; codex prints a TOML snippet for ~/.codex/config.toml;
# manual prints generic stdio guidance). This script remains for Claude users
# who want a standalone shell-script registration (CI, offline setup) — it
# does NOT do anything useful for Codex or other non-Claude agents.
#
# Run after `make mcp` and `make cli`.
#
# Usage:
#   bash scripts/install-mcp.sh             # user scope
#   bash scripts/install-mcp.sh project     # project scope (.mcp.json in cwd)

set -euo pipefail

SCOPE=${1:-user}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/cc-handoff-mcp"

if [[ ! -x "$BIN" ]]; then
  echo "binary $BIN not found; run \`make build\` first" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found in PATH" >&2
  exit 1
fi

# `claude mcp add` will refuse to add a duplicate; remove first if present.
claude mcp remove cc-handoff --scope "$SCOPE" >/dev/null 2>&1 || true
claude mcp add --scope "$SCOPE" --transport stdio cc-handoff -- "$BIN"

echo
echo "✓ cc-handoff MCP server registered (scope=$SCOPE)."
echo "  Binary: $BIN"
echo "  Restart your Claude Code session for the tools to appear."
echo
echo "Slash commands at $ROOT/.claude/commands/{handoff,pickup}.md can be"
echo "copied into your project's .claude/commands/ to expose /handoff and /pickup."
