# Infinite Agent Platform

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go Reference](https://pkg.go.dev/badge/github.com/cc-collaboration.svg)](https://pkg.go.dev/github.com/cc-collaboration)

> **English** | [中文](README.md)

> Infinite Agent Platform is Infinite State Inc's self-hosted internal platform for agent-driven software development. It brings projects, workspaces, agent sessions, coordination queues, delivery briefs, audit history, account administration, and relay operations into one enterprise control plane for teams using Claude Code, OpenAI Codex CLI, and compatible command-line agents.

> ⚙️ **Compatibility note**: existing binaries, config paths, MCP server names, and several API terms still use the legacy `cc-handoff`, `cc-relay`, and `cc-handoff-mcp` names so deployed clients, systemd units, update channels, and scripts keep working. Starting with this release, the product identity, UI, and docs position the system as Infinite Agent Platform; command examples that use `cc-handoff` are the compatibility layer, not the product brand.

## Product Positioning

The hard part of adopting AI coding agents inside a company is not sending a prompt to a model. It is giving teams a governed way to coordinate work across people, agents, repositories, machines, and audit trails:

- Multiple agent sessions may work at once; the team needs to know which session owns which project, branch, workspace, or task.
- Backend, frontend, QA, operations, and product roles need structured delivery context instead of scattered chat messages.
- Internal platforms need accounts, machine tokens, project memberships, permissions, history, and operational controls.
- Engineering leaders need a practical desktop, web, and mobile workspace for coordination, not a pile of local scripts.

Infinite Agent Platform provides that operating layer:

- **Agent workspace**: manage workspaces, projects, worktrees, terminals, git, code editing, and agent sessions in the Flutter desktop app.
- **Coordination queue**: package cross-role delivery as structured work packages with briefs, prompts, API deltas, attachments, comments, status, and audit history.
- **Enterprise relay**: self-hosted HTTP/SSE relay with accounts, machine tokens, project membership, presence, tasks, agent capsules, and a web admin UI.
- **Local session bus**: sibling agent sessions on one machine can message each other, read visible screens, and be coordinated by a supervisor.
- **Web and mobile entry points**: web for relay administration and queue inspection; mobile for remote workspace viewing, lightweight assignment, and status follow-up.

## Common Workflows

- **Cross-team delivery**: one agent submits API changes, diffs, swagger deltas, and implementation notes as a work package; the receiving agent picks it up inside the real local repository.
- **Internal assignment**: product, QA, ops, or engineering leads assign relay projects and todos to people or agent sessions and track progress.
- **Multi-agent development**: a supervisor observes sibling sessions, reads screens, sends messages, distributes work, and summarizes progress.
- **Agent capability reuse**: a productive session can be frozen into an agent capsule with persona, seed context, and skill pack, then published to the internal agent library.
- **Secure operations**: admins create or disable accounts, rotate machine tokens, reset passwords, and keep relay data inside the self-hosted boundary.

## Core Modules

**Desktop / mobile app (`app/`)**

The Flutter app is the primary workspace. Desktop is for execution: workspace/project/worktree tree, Claude/Codex terminals, git panel, code editor, coordination queue, todos, session overview, agent library, and phone mirroring. Mobile focuses on remote viewing, remote control, status, and lightweight assignment.

**Enterprise relay (`cc-relay`)**

The relay is the self-hosted control plane. It provides REST + SSE, SQLite persistence, account and token administration, project authorization, presence, work packages, comments, attachments, todos, agent capsules, and the web management UI. The packaged service listens on `0.0.0.0:8080`; production deployments must restrict that port with a firewall or security group, or bind it to loopback when only a local TLS reverse proxy needs access.

**Compatibility CLI / MCP (`cc-handoff`, `cc-handoff-mcp`)**

The CLI and MCP server are the compatibility entry points for current deployments. `cc-handoff submit/list/pickup/watch/comment`, Claude `/handoff` `/pickup`, Codex skills, and MCP tools continue to work. In the new product language, these commands create, receive, and audit agent work packages.

## Desktop / Mobile App

**Core features**

- **Workspace / project / worktree tree**: spawn Claude or Codex terminals in any project or branch worktree. Terminals restore lazily; git repos can be batch-imported from a folder.
- **Git panel**: changes, staging, commits, branches, log, stash, diff, and JetBrains-style per-file context menus.
- **Built-in code editor**: syntax highlighting, go-to-definition, configurable LSP servers, and formatter plugins.
- **Coordination queue**: inspect assigned work packages, initiated packages, and receive history; pick up work, copy execution prompts, comment, retract, and reassign.
- **Todos and project management**: relay projects, members, personal/team todos, Linear import, and assignment to agent sessions.
- **Agent library**: turn sessions into reusable capsules with persona, seed context, and skills.
- **Remote workspace**: mirror the desktop workspace to mobile for terminal viewing/control, file transfer, and status updates.

**Platforms**: desktop (macOS / Windows) is primary; mobile (iOS / Android) focuses on mirroring and viewing. Local capabilities such as terminals, git, formatting, and LSP are desktop-only.

**Build / run**: `app/` is a standard Flutter project; packaging / signing scripts live in `scripts/`. Desktop features need the corresponding CLI tools installed on the host (git, language servers, formatters); missing tools are shown in the plugin panel with install hints. iOS device build / install steps are in [`app/README.md`](app/README.md#ios-device-build--run).

## Architecture

The minimal production topology is one enterprise relay plus multiple employee clients:

```
Employee desktop / mobile / web    Enterprise VPS / intranet host   Employee agent sessions
────────────────────────────────    ─────────────────────────────   ───────────────────────
Flutter App / Web UI   ──HTTPS──►   TLS reverse proxy   ◄──SSE──   cc-handoff watch
Claude / Codex MCP     ──HTTPS──►          │                       cc-handoff-mcp
cc-handoff CLI         ──HTTPS──►   cc-relay:8080
                                           │
                                 /var/lib/cc-handoff/relay.db
                                 accounts + projects + queue + todos
```

- **`cc-relay`** — enterprise relay systemd service, listening on `0.0.0.0:8080` by default and protected by network policy or a TLS reverse proxy. Provides accounts, projects, queue, todos, comments, attachments, SSE, web UI, and administration.
- **Flutter App** — employee desktop / mobile workspace connected to the relay; desktop also operates local git, terminals, editor, and agent sessions.
- **`cc-handoff` (CLI)** — compatibility entry point. Subcommands include `init` / `submit` / `list` / `pickup` / `watch` / `comment` / `todo` / `workspace`.
- **`cc-handoff-mcp`** — compatibility MCP server launched by Claude Code / Codex over stdio so agents can access relay and work-package operations.
- **`cc-handoff watch`** — receiver-side daemon. Holds an SSE connection to the enterprise relay, materializes work packages under `.cc-handoff/inbox/<id>/`, fires notifications, and can spawn terminals by policy.

Full data flow, SQLite schema, auth model, and failure modes live in [`docs/architecture.md`](docs/architecture.md) (currently Chinese-only).

## Status

v1.0.0 is the enterprise relaunch of Infinite Agent Platform:

- ✓ Product name, Flutter app, relay web UI, docs, and platform display names now use Infinite Agent Platform.
- ✓ Legacy `cc-handoff` / `cc-relay` / `cc-handoff-mcp` compatibility remains for rolling upgrades.
- ✓ Enterprise relay supports accounts, projects, machine tokens, admins, disabled users, registration shutdown, and the coordination queue.
- ✓ Desktop / mobile workspace still includes workspaces, agent sessions, git, editor, queue, todos, agent library, and remote workspace access.

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

Idempotent. The first run is a fresh install; subsequent runs are rolling binary upgrades + restart, with the DB left intact.
The script cross-compiles `cc-relay` for the VPS architecture, installs the systemd unit, creates the `cc-handoff` system user, and initializes `/var/lib/cc-handoff/relay.db`.

Add a reverse proxy on the VPS. One line of caddy is enough — `flush_interval -1` is mandatory for SSE:

```caddyfile
handoff.your-domain.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

### 2. Bootstrap an admin and machine token

After the first deploy, create the first admin account on the VPS:

```bash
sudo -u cc-handoff /usr/local/bin/cc-relay useradd \
  -db /var/lib/cc-handoff/relay.db -identity you@backend -admin
```

From there, register team members in the App / UI and assign them to teams and projects. CLI / watch / MCP bearer credentials should come from the default DB machine token returned at registration or from the account page, not from a hand-edited `tokens.json`.

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
#   --with-mcp          register the MCP server (claude: `claude mcp add`;
#                       codex: `codex mcp add`)
#   --with-commands     install agent workflow helpers (Claude: .claude/commands/;
#                       Codex: $CODEX_HOME/skills/cc-handoff-*/)
#   --with-instructions append cc-handoff usage block to CLAUDE.md / AGENTS.md
cd /path/to/your-repo
cc-handoff init --with-mcp --with-commands --with-instructions
```

All `--with-*` flags are optional. Without them `cc-handoff init` just writes the two toml files; you then run `bash scripts/install-mcp.sh` and copy the commands / skill files yourself — fine for CI or any setup where you want to control every step.

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

You should see the 13 tools listed in the Architecture section above (`submit_handoff` and friends). From the shell:

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

In both modes, Claude will **first ask once for a product brief / PRD** (file path, pasted text, or a verbal description — rendered on the receiving side as background context, **not** required to be addressed line-by-line), then **ask once for cross-cutting hard constraints** (error-code mappings, casing rules, default page sizes, things the UI must not collapse into a single request — rendered as "must address line-by-line" in INTEGRATION.md). If there's nothing for either, just say "no" twice; Claude will skip the corresponding section.

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

`/request` first asks once for a product brief / PRD (the upstream "why" — what product wants, rendered as background context on the backend side), then asks once for cross-end constraints (e.g. "don't break existing callers", "field naming should match X", "stay backward-compatible"), same as `/handoff`. The whole flow is the symmetric reverse of `/handoff` and reuses the same inbox / comment / status / retract machinery.

### Visibility & recovery

After submitting, check what's happened on the other side:

```bash
cc-handoff status <id>     # state / picked_at / comment count / latest-comment summary
cc-handoff sent             # list my recent sent handoffs with state
```

Sent the wrong work package? Retract while it's still pending (after pickup, coordinate via comment):

```bash
cc-handoff retract <id> --reason "wrong branch"   # marks retracted; recipient watch writes RETRACTED.md + notifies
```

Receiver lost the auto-launched terminal or rebooted? Find and re-open the prompt:

```bash
cc-handoff inbox            # list locally materialized handoffs (with RET / C flags)
cc-handoff open <id>        # re-launch the configured agent on a previously picked handoff
```

Equivalent MCP tools (`status_handoff` / `list_sent` / `retract_handoff` / `list_local_inbox`) are exposed for in-session agent use.

### Graphical UI

Don't want everything on the command line? There are two entry points:

```bash
cc-handoff ui --open            # open the relay's built-in Web UI in your default browser
cc-handoff desktop              # same UI, but in a Chrome/Edge app window with the token auto-injected
cc-handoff desktop --width 1400 --height 900
cc-handoff desktop --chrome "/path/to/your/browser"   # pin a specific browser binary
```

`desktop` is a pure-Go Lorca wrapper that probes Chrome → Edge → Brave → Chromium for an installed browser. Windows 10/11 ships Edge, so it works out of the box; most macOS users have Chrome. With no Chromium-based browser installed it falls back with a message pointing to `cc-handoff ui --open`. Both entry points share the same UI assets and are functionally identical (inbox / sent / history / comments / ack / retract / online users); in `desktop` mode the token is auto-injected from local config, so there's nothing to paste.

The inbox detail view can also act on a handoff without dropping back to the CLI:

- **接收并物化 (pick up & materialize)** — pickup + materialize in one click. In `desktop` mode it calls the local pickup directly and lands in the current repo (or the auto-discovered default repo).
- **Prompt panel** — previews the receiver prompt with **复制 Prompt (copy prompt)** and **复制 CLI (copy CLI)** buttons, so you can paste either the prompt text or the matching `cc-handoff` command into a terminal.
- **转交 (hand off)** — opens a dialog to pick a target user + reason and pass the task on; **shown only for pending `bug`-kind handoffs**, alongside the bug-only **reassign** button.

### Multi-repo receiving

One identity backing several receiver repos (e.g. the same frontend teammate maintaining `frontend-project1` and `frontend-project2`, where each backend handoff lands depends on its content).

Setup: give each receiver repo its own `.cc-handoff.toml`, all declaring the same `identity.me` (e.g. `you@frontend`). Only one relay token is registered.

Receiving:

```bash
# Run watch in your most-used repo, but skip pre-materialize (otherwise every handoff lands there)
cc-handoff watch --no-materialize

# After the notification + reading the summary, materialize into the repo you choose
cc-handoff pickup h_xxx --repo ~/work/frontend-project1
cc-handoff pickup h_xxx --repo ~/work/frontend-project2
```

`--no-materialize` makes watch notify-only instead of auto-landing files on the receiver side; `pickup --repo` materializes a package into any repo without `cd`-ing. Together they mean "notifications are just notifications, routing is decided by a human." With a single receiver repo you configure nothing — the default behavior is already correct.

## Command reference

Once installed, use `cc-handoff <subcommand>`; each has `--help`.

**Agent work packages**

| Command | What it does |
|---|---|
| `init` | Initialize a work repo (writes user / repo-level toml; optionally installs MCP, workflow commands, an instructions section) |
| `submit` | (sender) Package git diff + swagger delta + commit log, push to the relay |
| `list` / `inbox` | Pending handoffs on the relay / already-materialized ones locally |
| `pickup <id>` | Fetch + materialize + ack (`--worktree` receives on an isolated branch worktree; `--direct` lands in the current repo) |
| `status` / `sent` / `history` / `open` / `retract` | State / your sent handoffs / receive history / re-launch agent / cancel |
| `comment <id> …` / `check-drift` | Comment / has swagger drifted since the last handoff |
| `watch` | Receiver daemon: SSE → inbox + notifications + auto-open a terminal for urgent tasks (`watch print-unit` emits a launchd / systemd / Windows-task unit) |
| `online` | Registered identities + who is currently watching |

**Local session bus / orchestration** (multi-agent collaboration inside the desktop app)

| Command | What it does |
|---|---|
| `msg send <target> <text>` | Point-to-point message to a sibling agent session on the same machine (no relay; runs in an app-spawned terminal) |
| `msg read <target>` | Pull a plain-text snapshot of another session's screen |
| `msg list` / `msg whoami` | List sessions / who am I |
| `supervisor …` | Supervisor-agent helpers: `overview` / `queue` / `read` / `send` / `decide` |

**Workspace / project / worktree / logs**

| Command | What it does |
|---|---|
| `workspace (ws) list\|create\|add\|open` | Manage and one-click-launch project targets |
| `worktree (wt) add\|list\|open\|remove` | Branch worktrees (`remove --prune-merged` sweeps merged ones) |
| `logs <project>` | Pull the project's logs, extract + grade the latest error (deduped); `--open` to launch an agent to triage |

**Others**: `ui` / `desktop` (relay management UI / Chromium window), `alert` (forward a server log alert to a teammate's watch), `link-linear` / `linear-sync` (Linear integration), `config`, `stop-hook` / `bus-hook` (agent hook entry points), `version`.

## Day-to-day ops

```bash
# On the VPS (deploy installs these into /usr/local/sbin/)
sudo -u cc-handoff /usr/local/bin/cc-relay useradd -db /var/lib/cc-handoff/relay.db -identity <you@example.com> -admin
sudo cc-handoff-backup                       # hot-backup SQLite, KEEP=N to retain N copies
sudo cc-handoff-uninstall [--purge]          # uninstall (--purge wipes DB and config)

# Live audit log
sudo journalctl -u cc-handoff-relay -f
```

Detailed troubleshooting (watch can't connect / token expired / SSE not flowing / upgrade rollback) lives in the troubleshooting section of [`docs/deployment.md`](docs/deployment.md) (currently Chinese-only).

## Linear integration (optional)

Bind cc-handoff's four event kinds (submit / pickup / comment / retract) to Linear issues, in both directions. **Zero secrets**: the cc-handoff binary never calls the Linear API directly — all sync actions are delegated to whichever Linear MCP server (`mcp__linear__*` tools) Claude Code already has configured.

**Configuration**: add this block to your repo's `.cc-handoff.toml`:

```toml
[integrations.linear]
enabled = true
team_key = "ENG"                  # Linear team prefix; used as a placeholder in example issue ids
default_labels = ["cc-handoff"]   # labels applied when an issue is created
mcp_prefix = "linear"             # prefix for the Linear MCP tool names (override if you don't use the default mcp__linear__*)
sync_on_submit = true
sync_on_pickup = true
sync_on_comment = true
sync_on_retract = true
```

`enabled = false` (the default) makes every command output byte-identical to the pre-integration behavior.

**Outbound flow** (any of the five operation MCP tools — `submit_handoff` / `submit_request` / `pickup_handoff` / `comment_handoff` / `retract_handoff`): the tool result appends a `## 同步到 Linear` section telling Claude which `mcp__linear__create_issue` / `update_issue` / `create_comment` calls to make next, then asks Claude to call `mcp__cc-handoff__link_linear` to record the issue identifier into `<inbox>/sent/<id>/linear.json`. The whole chain stays in MCP — no Bash permission prompts.

**Inbound flow** (starting from a Linear issue): run `/handoff-from-linear ENG-123` in Claude Code. The skill reads the issue via Linear MCP, composes a cc-handoff request, and appends a `<!-- cc-handoff: h_xxx -->` anchor to the Linear issue description so future syncs can recover the binding.

**Graceful degradation**: if the Linear MCP server isn't installed, Claude skips the sync section — the underlying handoff still ships normally.

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

| agent | CLI invocation | MCP register | commands | project instructions file |
|---|---|---|---|---|
| `claude` (default) | `claude -p "$(cat prompt.md)"` | auto: `claude mcp add --scope user --transport stdio` | `.claude/commands/{handoff,handoff-module,pickup,request}.md` | appended to `CLAUDE.md` |
| `codex` | `codex exec "$(cat prompt.md)"` | auto: `codex mcp add cc-handoff -- <bin>` | `$CODEX_HOME/skills/cc-handoff-*/` workflow skills; these skills call cc-handoff MCP tools | appended to `AGENTS.md` |
| `manual` | does not auto-launch a terminal | init prints generic stdio MCP guidance | none | none |

**Picking an agent**: `cc-handoff init` defaults to PATH detection (claude > codex > manual). Override with `cc-handoff init --agent codex`. The result is persisted to the `agent` field in `~/.config/cc-handoff/config.toml` (Linux/macOS) or `%AppData%\cc-handoff\config.toml` (Windows); subsequent commands honor it.

**`cc-handoff init` step toggles** (each independent):

- `--with-mcp` / `--no-mcp` — register the MCP server (claude: runs `claude mcp add`; codex: runs `codex mcp add`)
- `--with-commands` / `--no-commands` — install agent workflow helpers (Claude slash commands; Codex workflow skills)
- `--with-instructions` / `--no-instructions` — append cc-handoff usage block to `CLAUDE.md` or `AGENTS.md` (idempotent: skips when the `## cc-handoff` heading is already present)

**For Codex users**: `--with-mcp` writes the Codex MCP entry directly. cc-handoff still executes as MCP tools; `--with-commands` turns each `internal/setup/templates/commands/*.md` workflow into a Codex skill under `$CODEX_HOME/skills/cc-handoff-*/`. Restart Codex afterwards, then say things like "use cc-handoff-handoff for this API change" or "use cc-handoff-pickup".

**Queue materialization path**: new installs use `.cc-handoff/inbox/`; existing repos with `.claude/handoff-inbox/` keep using it (no migration needed). The `[inbox] dir = "..."` override in `.cc-handoff.toml` accepts an absolute or relative path.

## Further reading

| Doc | What's in it |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Conceptual — components, data flow, SQLite schema, auth, threat model, failure modes, extension points |
| [`docs/deployment.md`](docs/deployment.md) | Operational — end-to-end deployment, TLS, monitoring, token rotation, upgrade rollback, troubleshooting |
| [`docs/workspaces.md`](docs/workspaces.md) | Workspace / worktree launcher — one-click launch, branch worktrees, handoff isolation |
| [`docs/logs.md`](docs/logs.md) | Log triage — configure a log source, `cc-handoff logs` pulls the latest error, push alerts auto-triage |
| [`scripts/dogfood.sh`](scripts/dogfood.sh) | Stand up a hermetic local environment to dry-run the whole flow before touching a VPS |
| [`docs/handoff-package.schema.json`](docs/handoff-package.schema.json) | JSON schema for the handoff package |
| [`pkg/handoffschema/package.go`](pkg/handoffschema/package.go) | Same, as Go types |
| [`CHANGELOG.md`](CHANGELOG.md) | Version history |

The deeper docs (`architecture.md`, `deployment.md`) are currently Chinese-only; the README is the bilingual entry point. Translation contributions welcome.

## License

MIT — see [`LICENSE`](LICENSE).
