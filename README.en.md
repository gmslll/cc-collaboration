# cc-handoff

[![CI](https://github.com/gmslll/cc-collaboration/actions/workflows/ci.yml/badge.svg)](https://github.com/gmslll/cc-collaboration/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go Reference](https://pkg.go.dev/badge/github.com/cc-collaboration.svg)](https://pkg.go.dev/github.com/cc-collaboration)

> **English** | [中文](README.md)

> Cross-machine handoff for AI coding agents — turn "backend ships an API, frontend has to integrate it" from "paste a blurb in chat + read the swagger yourself" into "`/handoff` to push, `/pickup` to receive." First-class support for Claude Code and OpenAI Codex CLI; other agents work via manual mode (pure CLI flow).

## What problem does it solve

When backend and frontend live in separate repos with separate developers, the real flow for API integration is usually:

1. Backend writes the endpoint, merges the PR
2. Backend posts a blurb in chat: which endpoints are new, field names, error codes, gotchas
3. Frontend dev copies it back, then has to dig through swagger / read backend code / ping in chat for every detail
4. Frontend writes the client code; if anything breaks, repeat step 3

The pain is that **the integration context is scattered across chat, PR descriptions, and the backend dev's memory**, and every new integration forces the frontend to re-read backend code from scratch.

cc-handoff turns that conversation into a structured handoff:

- **Backend** runs `/handoff` inside Claude Code. Claude reads git diff + swagger delta + commit log, drafts the integration writeup, and ships it to your own VPS.
- **Frontend** machine has a daemon already running: it inboxes the handoff, fires a desktop notification, and for urgent ones can spin up a fresh terminal with `claude -p`.
- **Frontend** runs `/pickup`. Claude reads the inbound package **+ the actual local frontend code**, and produces an `INTEGRATION.md` draft.
- **Human review** of `INTEGRATION.md` happens before code lands. By design, the receiving Claude **stops and waits for review; it does not edit code on its own**.

Compared to "post a blurb in chat" or "share one Claude session between us," what this gets you:

| | Chat blurb + DIY | Shared Claude session | cc-handoff |
|---|---|---|---|
| Structured handoff | ✗ | △ (only the current prompt) | ✓ (handoff package + schema) |
| Receiver reads real code | ✗ (relies on backend's memory) | △ (one session can't truly ground in two repos) | ✓ (receiving Claude runs on the frontend machine) |
| Cross-machine, cross-timezone | △ (async chat) | ✗ (need to overlap) | ✓ (SSE + persistent inbox) |
| Contexts don't pollute each other | ✓ | ✗ (shared session) | ✓ (each side has its own Claude session) |
| Searchable history | ✗ | ✗ | ✓ (SQLite + comments + attachments) |
| Auto-wake the other side for urgent work | ✗ | ✗ | ✓ (opt-in, off by default) |

Design principles:

- **Manual control over magic.** MVP has no Stop-hook auto-trigger, no automatic retries, no "we'll just go ahead and edit your files for you." Every action prints what it's about to do and waits for a key press.
- **Receiving Claude writes; humans review.** The sender doesn't know the receiver's directory layout, so any cross-repo guidance is heuristic at best. The actual integration decisions belong to the Claude on the receiving side (which can see the real code) — and that Claude is told, by default, to stop after writing the doc.
- **Boundaries beat reuse.** The three binaries (CLI / MCP / relay) each own a single thing. They talk over HTTP+SSE; they do not share a database.

## Architecture

Three Go binaries, three machines:

```
Backend dev's Mac                  Your VPS                    Frontend dev's Mac
─────────────────                  ────────                    ──────────────────
Claude Code (backend)                                          Claude Code (frontend)
  ↓ /handoff                                                     ↑ /pickup
cc-handoff-mcp ──HTTPS──►       caddy:443                  ──► cc-handoff-mcp
                                   ↓                              ↑
                                cc-relay:8080 ◄──SSE──── cc-handoff watch (launchd/systemd)
                                   ↓
                                /var/lib/cc-handoff/relay.db
                                   + comments + attachments
```

- **`cc-relay`** — VPS-side systemd service, listens on loopback only; reverse proxy terminates TLS. HTTP REST + SSE, persisted to SQLite.
- **`cc-handoff` (CLI)** — installed on both machines. Subcommands: `init` / `submit` / `list` / `pickup` / `watch` / `comment`.
- **`cc-handoff-mcp`** — MCP server that Claude Code launches over stdio. Exposes the CLI's actions as MCP tools (`submit_handoff` / `submit_request` / `list_inbox` / `pickup_handoff` / `comment_handoff` and friends).
- **`cc-handoff watch`** — receiver-side daemon. Holds an SSE long connection, materializes incoming handoffs into `.cc-handoff/inbox/<id>/`, fires desktop notifications, can spawn a terminal for urgent items.

Full data flow, SQLite schema, auth model, and failure modes live in [`docs/architecture.md`](docs/architecture.md) (currently Chinese-only).

## Status

All four milestones shipped, v0.1.0 released:

- ✓ **M1** — manual submit / list / pickup
- ✓ **M2** — SSE + watch daemon + osascript notifications + partner_mapping rule engine + swagger delta
- ✓ **M3** — MCP server (`/handoff` and `/pickup` slash commands)
- ✓ **M4** — auto terminal launch + back-channel comments + attachment channel + structured audit log

## Quick deploy

End-to-end takes about 30 minutes; see **[`docs/deployment.md`](docs/deployment.md)** for the full ops manual.

### Prerequisites

| Side | What you need |
|---|---|
| VPS | A Linux box (amd64 or arm64), sudo access, ports 80/443 open |
| Domain | A subdomain for the relay, e.g. `handoff.your-domain.com` |
| Reverse proxy | caddy or nginx pre-installed on the VPS (TLS termination) |
| Mac/Linux client | Go 1.22+ for local builds, git, `claude` CLI logged in |

### 1. Stand up the relay on the VPS

From your Mac, in the cc-collaboration repo root:

```bash
make deploy HOST=user@your-vps
# Custom SSH:
make deploy HOST=user@your-vps SSH_OPTS="-p 2222 -i ~/.ssh/id_ed25519"
```

Idempotent. The first run is a fresh install; subsequent runs are rolling binary upgrades + restart, with config and DB left intact.
The script cross-compiles `cc-relay` for the VPS architecture, installs the systemd unit, creates the `cc-handoff` system user, and seeds `/etc/cc-handoff/tokens.json` and `/var/lib/cc-handoff/relay.db`.

Add a reverse proxy on the VPS. One line of caddy is enough — `flush_interval -1` is mandatory for SSE:

```caddyfile
handoff.your-domain.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

### 2. Mint tokens

`/etc/cc-handoff/tokens.json` ships with one example identity/token pair. In production, mint one per side:

```bash
sudo cc-handoff-rotate-token user@backend
sudo cc-handoff-rotate-token alex@frontend
```

Hand each token to the right person. `cc-handoff init` will ask for it next.

### 3. Install on each client (backend and frontend, once each)

**A. One-shot install of the prebuilt binaries (recommended on macOS / Linux)**

No repo clone, no Go toolchain — pull the latest GitHub Release straight to your PATH:

```bash
curl -fsSL https://raw.githubusercontent.com/gmslll/cc-collaboration/main/scripts/install-client.sh | bash
```

Optional env: `INSTALL_DIR=$HOME/.local/bin` (target dir), `VERSION=v0.1.2` (pin a version, default `latest`), `SKIP_RELAY=1` (linux: skip `cc-relay`, only install `cc-handoff` + `cc-handoff-mcp`). The script verifies sha256 against `checksums.txt`. After install: `cc-handoff version` should print the embedded semver.

Windows: grab `cc-handoff_v*_windows_<arch>.zip` from the [Releases page](https://github.com/gmslll/cc-collaboration/releases/latest), unpack the `.exe` files onto your PATH, or run `scripts/install.ps1` (see the Windows support section below).

**B. Build from source**

Needs this repo + Go 1.22+:

```bash
make build && sudo install bin/cc-handoff bin/cc-handoff-mcp /usr/local/bin/
```

---

Once the binaries are installed (A or B), init your working repo:

```bash
# In your working repo, init wires the agent up:
#   writes the user-level + repo-level toml configs,
#   --agent <name>      default: detect on PATH (claude > codex > manual)
#   --with-mcp          register the MCP server (claude: auto `claude mcp add`;
#                       codex: prints a TOML snippet for ~/.codex/config.toml)
#   --with-commands     Claude only: install /handoff /handoff-module /pickup /request
#                       into .claude/commands/ (codex / manual skip)
#   --with-instructions append cc-handoff usage block to CLAUDE.md / AGENTS.md
cd /path/to/your-repo
cc-handoff init --with-mcp --with-commands --with-instructions
```

All `--with-*` flags are optional. Without them `cc-handoff init` just writes the two toml files; you then run `bash scripts/install-mcp.sh` and `cp .claude/commands/*.md` (or paste the Codex TOML yourself) — fine for CI or any setup where you want to control every step.

### 4. Run the watch daemon (receiver only)

The side that's *waiting* for handoffs needs a daemon. **macOS** uses launchd:

```bash
cc-handoff watch print-unit --workdir=$(pwd) > ~/Library/LaunchAgents/com.cc-handoff.watch.plist
launchctl load ~/Library/LaunchAgents/com.cc-handoff.watch.plist
```

**Linux** uses a systemd user unit:

```bash
cc-handoff watch print-unit --platform=systemd --workdir=$(pwd) \
  > ~/.config/systemd/user/cc-handoff-watch.service
systemctl --user daemon-reload
systemctl --user enable --now cc-handoff-watch
```

`print-unit` only prints the template; loading and enabling it is your job. We deliberately don't reach into your launchd or systemd config.

### 5. Verify

Inside a backend Claude Code session:

```
> What MCP tools do I have right now?
```

You should see `submit_handoff` / `submit_request` / `list_inbox` / `pickup_handoff` / `comment_handoff`. From the shell:

```bash
claude mcp list
# cc-handoff: /usr/local/bin/cc-handoff-mcp  - ✓ Connected
```

---

Want to dry-run the whole thing on one machine before touching a VPS? `bash scripts/dogfood.sh setup` spins up a hermetic local environment with a test-backend / test-frontend pair. The script's header has the full instructions; `cleanup` and `status` subcommands too.

## Using inside Claude Code

### Backend: sending

Pick the slash command that fits your moment:

- **`/handoff` (diff mode)** — you just finished a chunk of changes and want to push them out. Claude reads the branch diff, drafts the integration notes, calls `submit_handoff`.
- **`/handoff-module <module-path> [more...]` (module-brief mode)** — a module landed long ago and the frontend is now starting fresh integration. Claude reads `routes/handlers/dto/swagger` under that module, assembles a self-contained API contract document, then calls `submit_handoff` with `module_paths`. The receiving side automatically switches to the "module integration" prompt template. You can pass several module paths at once, space-separated.

In both modes, Claude will **ask you once** for any cross-cutting requirements or constraints (error-code mappings, casing rules, default page sizes, things the UI must not collapse into a single request, etc.). If there's nothing, just say "no" — Claude will skip the note section.

### Frontend: receiving

```
/pickup
```

Claude calls `list_inbox`; if there are several, it'll let you pick. Then it `pickup_handoff`s the chosen one, materializes it under `.cc-handoff/inbox/<id>/`, and produces an `INTEGRATION.md` draft for you to review.

To ask the backend something mid-integration: the `comment_handoff` MCP tool (or `cc-handoff comment <id> "your question"` from the shell). The backend's watch daemon picks it up via SSE and appends it to `.cc-handoff/inbox/<id>/comments.md`.

### Frontend: filing a reverse request `/request`

When the frontend hits something the backend needs to add — a missing field, an unexposed capability, a wrong response shape — file a request from inside Claude Code with `/request`:

- Claude reads the relevant frontend code, drafts a clear "what's needed / why / what 'done' looks like" summary, and calls `submit_request`. There's no git diff; the summary IS the request body.
- On the backend side, `list_inbox` shows the pending item tagged `[REQUEST]`. Running `/pickup` materializes it under the same inbox dir, but the prompt automatically switches to a request-specific template — guiding the backend Claude to read the request, scan the relevant handler/dto/router/swagger, and (default) write a response plan to `docs/requests/<id>.md` for review (or, in direct mode, modify code and stop for diff review).
- When the backend ships the result back via `/handoff`, the prompt asks it to set `responds_to=<original request id>`. The frontend's pickup prompt then renders an "↩️ 这次 handoff 是在回应你之前发起的需求 r_xxx" banner so you can trace the loop.

`/request` asks once for cross-end constraints (e.g. "don't break existing callers", "field naming should match X", "stay backward-compatible"), same as `/handoff`. The whole flow is the symmetric reverse of `/handoff` and reuses the same inbox / comment / status / retract machinery.

### Visibility & recovery

After submitting, check what's happened on the other side:

```bash
cc-handoff status <id>     # state / picked_at / comment count / latest-comment summary
cc-handoff sent             # list my recent sent handoffs with state
```

Sent the wrong thing? Retract while it's still pending (after pickup, coordinate via comment):

```bash
cc-handoff retract <id> --reason "wrong branch"   # marks retracted; recipient watch writes RETRACTED.md + notifies
```

Receiver lost the auto-launched terminal or rebooted? Find and re-open the prompt:

```bash
cc-handoff inbox            # list locally materialized handoffs (with RET / C flags)
cc-handoff open <id>        # re-launch the configured agent on a previously picked handoff
```

Equivalent MCP tools (`status_handoff` / `list_sent` / `retract_handoff` / `list_local_inbox`) are exposed for in-session agent use.

## Day-to-day ops

```bash
# On the VPS (deploy installs these into /usr/local/sbin/)
sudo cc-handoff-rotate-token <identity>     # rotate a token
sudo cc-handoff-backup                       # hot-backup SQLite, KEEP=N to retain N copies
sudo cc-handoff-uninstall [--purge]          # uninstall (--purge wipes DB and config)

# Live audit log
sudo journalctl -u cc-handoff-relay -f
```

Detailed troubleshooting (watch can't connect / token expired / SSE not flowing / upgrade rollback) lives in the troubleshooting section of [`docs/deployment.md`](docs/deployment.md) (currently Chinese-only).

## Windows support

Windows is a first-class platform — CLI, MCP, watch, toast notifications, urgent-handoff terminal launch, and the daemon all work.

**Prerequisites**: Windows 10 1809+ or Windows 11; PowerShell 5.1+ (preinstalled); `claude` CLI on PATH.

**Install**:

```powershell
# from the repo root, cross-compile first (produces amd64 + arm64 cli/mcp, 4 .exe total)
make windows

# one-shot install: copies to %LOCALAPPDATA%\Programs\cc-handoff, adds PATH,
# registers the watch task
.\scripts\install.ps1 -RegisterTask
```

**Manual daemon registration** (after cc-handoff.exe is on PATH):

```powershell
# PowerShell 5.1's `>` writes UTF-16 LE with BOM, which mismatches the
# template's <?xml encoding="UTF-8"?> declaration and schtasks rejects it.
# Use WriteAllText to force UTF-8 without BOM.
$xml = cc-handoff watch print-unit
[System.IO.File]::WriteAllText("cc-handoff-watch.xml", ($xml -join "`n"), [System.Text.UTF8Encoding]::new($false))
schtasks /Create /XML cc-handoff-watch.xml /TN cc-handoff-watch
schtasks /Run /TN cc-handoff-watch
```

**Paths and config**:

| Item | Location |
|---|---|
| User config | `%AppData%\cc-handoff\config.toml` |
| Repo config | `<repo>\.cc-handoff.toml` (same as macOS / Linux) |
| `terminal_app` values | `windows-terminal` (default, falls back to powershell if `wt.exe` is missing), `powershell` |

**Uninstall**:

```powershell
schtasks /Delete /TN cc-handoff-watch /F
Remove-Item -Recurse "$env:LOCALAPPDATA\Programs\cc-handoff"
```

## Multi-agent support

| agent | CLI invocation | MCP register | slash commands | project instructions file |
|---|---|---|---|---|
| `claude` (default) | `claude -p "$(cat prompt.md)"` | auto: `claude mcp add --scope user --transport stdio` | `.claude/commands/{handoff,handoff-module,pickup,request}.md` | appended to `CLAUDE.md` |
| `codex` | `codex exec "$(cat prompt.md)"` | init prints a TOML snippet to paste into `~/.codex/config.toml`, then restart codex | none (call MCP tools directly by name) | appended to `AGENTS.md` |
| `manual` | does not auto-launch a terminal | init prints generic stdio MCP guidance | none | none |

**Picking an agent**: `cc-handoff init` defaults to PATH detection (claude > codex > manual). Override with `cc-handoff init --agent codex`. The result is persisted to the `agent` field in `~/.config/cc-handoff/config.toml` (Linux/macOS) or `%AppData%\cc-handoff\config.toml` (Windows); subsequent commands honor it.

**`cc-handoff init` step toggles** (each independent):

- `--with-mcp` / `--no-mcp` — register the MCP server (claude: runs `claude mcp add`; codex: prints snippet)
- `--with-commands` / `--no-commands` — install slash commands (Claude only)
- `--with-instructions` / `--no-instructions` — append cc-handoff usage block to `CLAUDE.md` or `AGENTS.md` (idempotent: skips when the `## cc-handoff` heading is already present)

**For Codex users**: paste the snippet init prints into `~/.codex/config.toml`:

```toml
[mcp_servers.cc-handoff]
command = "/usr/local/bin/cc-handoff-mcp"
args = []
```

Then restart codex and call `submit_handoff` / `pickup_handoff` / etc. directly — semantically equivalent to Claude's `/handoff` `/pickup` slash commands.

**Inbox path**: new installs use `.cc-handoff/inbox/`; existing repos with `.claude/handoff-inbox/` keep using it (no migration needed). The `[inbox] dir = "..."` override in `.cc-handoff.toml` accepts an absolute or relative path.

## Further reading

| Doc | What's in it |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Conceptual — components, data flow, SQLite schema, auth, threat model, failure modes, extension points |
| [`docs/deployment.md`](docs/deployment.md) | Operational — end-to-end deployment, TLS, monitoring, token rotation, upgrade rollback, troubleshooting |
| [`scripts/dogfood.sh`](scripts/dogfood.sh) | Stand up a hermetic local environment to dry-run the whole flow before touching a VPS |
| [`docs/handoff-package.schema.json`](docs/handoff-package.schema.json) | JSON schema for the handoff package |
| [`pkg/handoffschema/package.go`](pkg/handoffschema/package.go) | Same, as Go types |
| [`CHANGELOG.md`](CHANGELOG.md) | Version history |

The deeper docs (`architecture.md`, `deployment.md`) are currently Chinese-only; the README is the bilingual entry point. Translation contributions welcome.

## License

MIT — see [`LICENSE`](LICENSE).
