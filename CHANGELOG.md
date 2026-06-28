# Changelog

All notable changes to cc-handoff are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

The single source of truth for the version number is the `VERSION` file at the repo root. `make release-tag` refuses to tag unless `CHANGELOG.md` has a matching `## [X.Y.Z]` heading.

## [Unreleased]

## [0.6.3] - 2026-06-28

### Fixed

- **codex终端满屏后不滚动、只替换最后一行** — codex renders its transcript in the main buffer with a scroll region that reserves the bottom rows for its composer (`ESC[1;5r`). The vendored xterm's `index()` grew scrollback (inserting a line below the margin) whenever the top margin was 0, which — once scrollback existed — inserted at a non-end index of the circular buffer (silent corruption in release) and pinned output to the last line. A region with a real bottom margin now scrolls in place. (claude was unaffected because it uses the alternate screen.) Guarded by a regression test that replays a real codex byte stream.

## [0.6.2] - 2026-06-28

### Fixed

- **Account-page hook self-check wrongly reported "未安装"** — the desktop hook status (and the reinstall prompt) always showed the bus hook as missing even when it was installed, because the check matched the full shell command against the raw config file, whose embedded quotes and `&&` are JSON-escaped on disk. It now matches the escaping-invariant `cc-handoff bus-hook` invocation. The hook itself always worked — only the status display was wrong.

## [0.6.1] - 2026-06-28

### Fixed

- **Android updates install in place (no more "软件包冲突")** — release APKs are now signed with a stable, committed keystore instead of a per-machine/per-CI debug key, so an update installs over the previous one and the in-app updater works. The APK's versionName/versionCode are derived from the `VERSION` file (e.g. 0.6.1 → versionCode 601) so each release outranks the last. (One-time migration: uninstall the old debug-signed app once, then install this; future updates are seamless.)

## [0.6.0] - 2026-06-28

### Added

- **Exact agent session-id binding & recovery (claude + codex)** — a reopened or restarted session now resumes the *exact* prior conversation instead of guessing. codex's session id (which can't be set at launch) is captured the moment it starts from the rollout file it holds open (asked of the OS via `lsof` on the codex process under the PTY), so it no longer races on file mtimes. On resume with no captured id, the tab picks *this folder's* newest rollout (`codex resume <id>`) instead of the blind `codex resume --last`, so it can't resume a different directory's session.
- **Hook-based session-id capture** — the existing `cc-handoff bus-hook` (PostToolUse/Stop, installed for both Claude Code and Codex) now also records each session's own agent session id to `$CC_BUS_DIR/sessions/<id>.json`, keyed by the tab's `CC_SESSION_ID`. Event-driven and authoritative (the agent reporting its own id via the hook payload), and the only capture path on Windows where `lsof` is unavailable. Writes are skipped when unchanged.
- **Hook self-check (账号 page, desktop)** — shows whether the bus hook is installed in each agent's config (claude `~/.claude/settings.json`, codex `$CODEX_HOME/hooks.json`) with a one-tap reinstall, backed by a new `cc-handoff bus-hook status` so the paths and "installed" criterion have one source of truth in the CLI.

### Fixed

- **Phone-created sessions no longer start blank** — the PTY launches immediately on creation instead of waiting for the desktop to render the terminal pane, so a session created from the phone (while the desktop's terminal panel is collapsed or on another view) starts its agent right away.
- **Desktop restart no longer leaves the phone mirroring a permanently blank terminal** — session ids are persisted and restored, so a phone holding an id still resolves it after the desktop restarts (ids no longer re-mint from zero each launch).
- **codex sessions no longer go blank or resume the wrong conversation** after a desktop restart — fixed by the stable ids plus the exact session-id capture above.

## [0.5.0] - 2026-06-28

### Added

- **Session overview (会话总览)** — a desktop top-level page + a phone grid that lay every open session out flat, grouped by workspace → project → worktree; each card shows the agent's latest-reply preview, status (working / needs-review / idle), and token usage so you can see at a glance which sessions finished and need review. Each session gets a deterministic generated "robot" avatar (consistent across the tab strip, project tree, overview, and phone), and working sessions get a subtle breathing animation.
- **Quick-reply popup** — tapping a session in the overview opens a live, *colored* terminal preview plus confirm/reply controls (↵ / 1·2·3 / y·n / Esc / free text) so you can act without switching to the workspace or the full-screen mirror. The phone pulls the current screen via a new `screen` frame; an 账号 toggle makes the popup the default tap action (else the tap opens the full terminal).
- **Per-session token usage / estimated cost** (claude + codex) — a desktop overlay chip and the phone overview / Live Activity, computed incrementally from each session's on-disk transcript.
- **Phone mirror improvements** — full pre-connect history replay + stick-to-bottom on open + first-frame sizing reported at the phone's width; bidirectional in-session file transfer + terminal sync; an idle session-history cache that re-pulls fresh; an adjustable terminal font size (so a wide full-screen TUI like codex lays out with enough columns to read).
- **Cross-device workspace/project sync** — desktop-side create/remove of a workspace or project now propagates to connected phones, and the `roots` frame carries all workspace names so an empty workspace is visible (and can receive its first project) from the phone's 管理 tab.
- **In-app update** — checks the public GitHub Releases and offers one-tap download + install (Android → system installer; macOS → download + reveal, since an ad-hoc/un-notarized app can't self-install silently). The build's version is injected at build time via `--dart-define=APP_VERSION` (from the `VERSION` file).
- **Three-platform app packaging to Releases** — `package-apps.yml` attaches the macOS / Windows / Android packages to the GitHub Release on a `v*` tag (alongside the Go CLI binaries from `release.yml`).
- **Android AI status** (foreground service + persistent notification, a Live-Activity equivalent) and **iOS** device-info integration.
- **Diff full/changed toggle + read-only code view** on the phone; `msg read` gains a structured `transcript` channel that reads a peer session's on-disk transcript instead of screen-scraping.
- Local session bus **mid-turn interjection** — a peer message sent to a *busy* agent session (mid-turn) no longer just queues behind the running turn. The desktop app now routes by the target's busy/idle state (derived from the existing BEL "turn finished" detector): an **idle** target still gets the message pasted straight into its PTY (immediate turn), while a **busy** target gets it parked in a per-session bus inbox (`$CC_BUS_DIR/inbox/<session-id>/`, `internal/localbus`) that the target's **PostToolUse** hook drains as `additionalContext` at the next tool boundary — surfacing the message inside the running turn without interrupting it — with a **Stop** hook as the turn-end backstop. One `cc-handoff bus-hook` binary serves both Claude Code and Codex (identical hook contract); `cc-handoff bus-hook install` (run on app start) idempotently wires the hooks into `~/.claude/settings.json` and `~/.codex/hooks.json`. The hook command self-gates on `$CC_BUS_DIR`, so it's a sub-millisecond no-op in any session the app didn't spawn — the user's other Claude/Codex sessions are untouched.

### Fixed

- Local-bus subagent hooks no longer steal the parent session's inbox.
- Switching sessions refreshes that session's usage chip immediately (no longer frozen at the previous turn boundary).
- Windows terminal fixes — Chinese IME input (vendored + patched `flutter_pty`), Chinese-path launch failures, and a missing `SystemRoot`/environment on `cmd.exe`.
- `pasteText` auto-submit gains a fallback resend.

## [0.3.0] - 2026-06-05

### Added

- Multi-tenant relay — the relay grows user **accounts + password login + roles + projects** so one shared instance can serve many teams. The bearer-auth middleware becomes a `Resolver` that accepts, in order, a **UI login session**, a **DB-minted machine token**, or the legacy **`tokens.json`** — all resolving to one identity, so the existing CLI / watch / MCP data plane is unchanged and a relay can run with no tokens file at all. New schema (all `CREATE TABLE IF NOT EXISTS`, idempotent in-place upgrade): `users` (bcrypt password, `is_admin`, `disabled`), `sessions`, `machine_tokens`, `projects`, `project_repos` (a repo belongs to one project), `project_members` (role `owner`/`member`/`viewer`). Adds `golang.org/x/crypto` (pure-Go bcrypt; `CGO_ENABLED=0` preserved).
- Accounts & sessions — `POST /v1/login` (issues a session token used as a normal Bearer), `/v1/logout`, `GET /v1/me` (identity + admin flag + project roles), `POST /v1/password`. Admins manage accounts via `GET/POST /v1/users` and `POST /v1/users/{id}/admin|disable|reset-password` (generated passwords shown once). First-admin bootstrap is the `cc-relay useradd --identity <id> --admin [--password P]` host subcommand; operator-seeded admins come from `-admins` / `RELAY_ADMINS` (effective admin = seed ∪ `users.is_admin`, so an operator can't be locked out).
- Projects & self-service — any signed-in user `POST /v1/projects` (becomes `owner`) and manages their own project's repos + members via `PATCH/DELETE /v1/projects/{id}`, `.../repos`, `.../members`; admins manage all. `GET /v1/projects` returns your projects (all for admins).
- Project-scoped read authorization — a single `canViewPackage` gate (admin ‖ legacy participant ‖ member of the project owning the handoff's repo) now backs `GET /v1/handoffs/{id}`, `/status` (de-duping its previously-inlined check), `/prompt`, `/comments`; project members see every handoff in their projects via `GET /v1/handoffs?scope=project[&project=<id>]` (or `?scope=all` for admins). Comment-posting widens to owner/member (not `viewer`); ack / retract / reassign stay restricted to the actual recipient/sender. All additive — a relay with no projects behaves exactly as before.
- Self-service machine tokens — `GET/POST/DELETE /v1/tokens` let any user mint (raw value shown once) and revoke their own bearer tokens for CLI / watch / MCP, replacing hand-edited `tokens.json` entries (which still work). Revocation is owner-scoped.
- Relay Web UI — password login (replacing the paste-a-token form; machine-token paste kept as an advanced option) + sign-out, and role-aware tabs driven by `/v1/me`: **Projects** (create + manage members/repos, browse a project's handoffs), **Account** (change password, mint/revoke machine tokens), **Admin** (account management, admins only). Requires HTTPS (passwords/sessions). See `docs/deployment.md` §1.5.

## [0.2.0] - 2026-06-03

### Added

- Workspace launcher — `cc-handoff workspace create/add/list/open` (alias `ws`) turns a root dir holding one or more git repos into one-click resume targets, so after SSH-ing back you no longer hand-`cd` into projects. A purely local concept driven by the user-level config: top-level `workspace_root` (auto-carve base, defaults to `~/cc-handoff-workspaces`) plus `[[workspace]]` blocks (`name` / `path` / `pre_launch` / `editor` / `agent`) and nested `[[workspace.project]]` (`name` / `path` / `github`). The project list is the union of repos found by scanning the root one level deep and the projects explicitly recorded in config, so a repo cloned into the dir shows up automatically. `cc-handoff desktop` gains a **Workspaces** tab listing each project with a「复制启动命令」copy-to-clipboard button (hidden in a plain browser, which has no local paths to resolve). See `docs/workspaces.md`.
- Branch worktrees — `cc-handoff worktree add/list/open/remove` (alias `wt`) lets each project spawn multiple branch worktrees for parallel agent sessions without collisions. `add` makes the branch from `--start REF` or HEAD (or attaches an existing one); `--open [--window]` jumps straight in; `--workspace NAME` disambiguates a project name shared across workspaces; `remove --force` drops one with uncommitted changes; `remove --prune-merged --base main` sweeps every worktree whose branch is already merged. Worktrees live at `<project>/.worktrees/<branch>` (slashes → `-`), read live from `git worktree list` (nothing persisted), and `workspace list` shows each project's worktrees indented under it (`↳`).
- Project launch execution — `workspace open` / `worktree open` now actually launch instead of only printing the command. The default **in-place** path `exec`s `$SHELL -i -c <command>` so the terminal you're already in becomes the agent session (SSH-friendly, does not return); `--window` opens a new terminal (macOS Terminal.app/iTerm2 per the repo's `[triggers]`, Windows terminal/PowerShell), unavailable over plain SSH. `config.BuildLaunchCommand` (`cd` + `pre_launch` + `editor` + agent) is the single source of truth shared by both the printed command and `open`, so they never diverge; the cmd-layer `launchProject` picks the exec-vs-window strategy.
- `cc-handoff pickup <id> --worktree [--open [--window]]` — integrate a handoff on an isolated branch instead of your main checkout, so parallel handoffs don't collide. Carves a worktree at `<repo>/.worktrees/h_<shortid>_<senderBranch>` (the branch from the handoff's `Repo.Branch`; `h_<shortid>` when unknown) and materializes the inbox **inside** it. The `pickup_handoff` MCP tool takes the same `worktree: true` argument but only creates + materializes — it never launches an agent (no terminal to exec into from a headless MCP server).
- Multi-repo receiving — `cc-handoff pickup --repo PATH` materializes a package into any repo without `cd`-ing, and `cc-handoff watch --no-materialize` makes watch notify-only (no auto-landing on the receiver side), so one identity can route handoffs across multiple receiver repos that share the same `identity.me`. `cc-handoff desktop` auto-discovers the current repo as the default target, so the Web UI pickup button materializes there without manual `--repo`.
- Relay Web UI handoff actions — the inbox detail view gains a **转交** dialog (pick a target user + reason; shown only for pending `bug`-kind handoffs), an **接收并物化** button (pickup + materialize in one click; in `desktop` mode it calls the local pickup directly), a **Prompt** panel that previews the receiver prompt with **复制 Prompt** / **复制 CLI** buttons, and the bug-only **reassign** button — so a bug can be picked up, reassigned, or handed on without leaving the browser.
- Log triage — per-project log source + `cc-handoff logs <project>`. A `[workspace.project.log]` block (`host` / `command` / optional `grep` / `context`) tells cc-handoff how to pull a project's logs: with `host` it runs `ssh <host> <command>`, without it runs `command` locally (kubectl/docker/file). The captured stdout is extracted **locally** — the last line matching the error pattern plus N context lines (no match → trailing `--lines`) — and written to `<project>/.cc-handoff/logs/<ts>.md` as a triage prompt. Default prints the path; `--open` launches the agent one-shot in the project to analyze (`--window` for a new terminal), reusing the `workspace open` launch path. See `docs/logs.md`.
- Push log alerts — server-side error hooks forward alerts to a teammate's `watch`: `POST /v1/alerts` (bearer-auth, fans out a new `log.alert` SSE event to the recipient) plus the `cc-handoff alert --to <id> --project <name> [--message TEXT | --file PATH] [--level LVL] [--grade]` sender that calls it (servers without cc-handoff can `curl` the endpoint). On receipt, `watch` writes the alert as a triage prompt into the named project and pops a desktop notification; the new `[triggers].auto_launch_on_alert` (default `false`) opts into auto-launching the agent in a new terminal window to start triaging. A project that can't be resolved locally degrades to notify-only.
- Local-AI severity grading — an optional user-level `grade_command` (e.g. `ollama run llama3.2`, or a cloud wrapper reading stdin) lets `cc-handoff logs` rate each error `critical`/`high`/`medium`/`low`, recorded in the triage file header. cc-handoff pipes a one-word-answer prompt + the excerpt to the command's stdin and parses the level from stdout (chatty replies tolerated; failures are best-effort and just omit the level). `cc-handoff logs --no-grade` skips it; `cc-handoff alert --grade` reuses the same grader to fill an alert's level.
- Log triage dedup — triage files are now named by a normalized fingerprint of the matched error line instead of a timestamp, so the same failure recurring with a different timestamp / id / `0x…` address / UUID / line number is backed up only once. A repeat reports `duplicate error, already backed up` and leaves the existing file untouched (still `--open`-able); the same dedup applies to pushed `log.alert`s.
- `cc-handoff logs config <project>` — interactively set up (or edit) a project's `[workspace.project.log]` block instead of hand-editing the user config. Prompts for host / command / grep / context (pre-filled with current values when editing), reusing the same config-write path as `workspace add`; an auto-discovered project is pinned to an explicit `[[workspace.project]]` entry on first config.
- `cc-handoff desktop` subcommand — opens the existing Web UI in a native-feeling Chromium app window via [Lorca](https://github.com/zserge/lorca). Pure Go, no CGO, so the main CLI's `CGO_ENABLED=0` Linux/Windows cross-compile path is preserved. Auto-injects the relay token from user config into `localStorage` and sets `:root[data-mode="desktop"]` so the auth panel hides — no token paste required. Probes Chrome → Edge → Brave → Chromium and honors `--chrome PATH` for explicit overrides; falls back with a clear message that points to `cc-handoff ui --open` when no Chromium-based browser is installed.

### Changed

- Web UI visual refresh in `internal/relay/ui/styles.css`: indigo accent palette, system font stack with antialiasing, dark-mode support via `prefers-color-scheme`, dedicated status-badge colors (pending/picked/retracted/expired/reassigned/urgent), distinct kind-badge colors (delivery/request/bug), card hover lift, tighter design tokens (CSS variables for radii / spacing / shadows). Same markup, no JS changes — improvements apply to both the browser UI and the new `cc-handoff desktop` window.

## [0.1.2] - 2026-05-20

### Added

- `[integrations.linear]` config block in `.cc-handoff.toml` (fields: `enabled`, `team_key`, `default_labels`, `mcp_prefix`, `sync_on_submit`, `sync_on_pickup`, `sync_on_comment`, `sync_on_retract`). Disabled by default; when enabled, the five operation MCP tools (`submit_handoff`, `submit_request`, `pickup_handoff`, `comment_handoff`, `retract_handoff`) append a `## 同步到 Linear` section at the end of their result instructing the agent which `mcp__linear__*` calls to make next. cc-handoff itself never calls the Linear API — authentication and HTTP are delegated to whichever Linear MCP server the user already has configured. `mcp_prefix` overrides the wire-name prefix (default `linear`) for installs that namespace their Linear MCP tools differently.
- `cc-handoff link-linear --handoff <id> --issue <ENG-XXX> [--url URL]` CLI subcommand and `mcp__cc-handoff__link_linear` MCP tool. Both record the handoff↔Linear-issue binding to `<inbox-dir>/sent/<handoff>/linear.json` using atomic tmp+rename write. The MCP tool is the loop-closer Claude calls after creating the Linear issue, so the entire Linear outbound flow stays in MCP without dropping to Bash.
- `/handoff-from-linear <issue-id>` slash command — reads a Linear issue via Linear MCP (`mcp__linear__get_issue`), composes a cc-handoff request summary preserving title / description / acceptance / source URL, sends it via `submit_request`, then appends a `<!-- cc-handoff: <id> -->` anchor to the Linear issue description so the binding is recoverable later. Inbound counterpart to the outbound sync block.
- `inbox.LinearLink` struct and `inbox.WriteLinearLink(inboxDir, handoffID, identifier, url) (string, error)` — shared atomic writer used by both the CLI subcommand and the MCP handler. Same tmp+rename pattern as `inbox.SaveCursor`.
- `mcp.CCHandoffMCPPrefix = "mcp__cc-handoff__"` constant and `mcp.ToolLinkLinear = "link_linear"` constant in the tool registry. The prompt template composes the wire name from these instead of hardcoding it, so renaming a tool only requires updating its constant.
- MCP tool count: 12 → 13. Integration test `TestMCPEndToEnd` now compares against `len(mcp.DefaultTools())` instead of a hardcoded literal, so future tool additions don't require updating the assertion.
- Codex workflow skills for the command templates: `cc-handoff init --agent codex --with-commands` now turns each `internal/setup/templates/commands/*.md` workflow into a user-level Codex skill under `$CODEX_HOME/skills/cc-handoff-*/SKILL.md` (`cc-handoff-handoff`, `cc-handoff-pickup`, `cc-handoff-request`, etc.). The actual cc-handoff integration remains MCP-based; the skills are natural-language workflow entry points that instruct Codex to call the cc-handoff MCP tools.

### Changed

- Codex command install no longer generates a repo-local `.codex` plugin marketplace or runs `codex plugin marketplace add` / `codex plugin add`. This avoids relying on unsupported custom slash-command behavior in current Codex CLI versions.
- Non-interactive Codex workflow-skill installs now refresh older stamped skills automatically on binary upgrade, while still skipping newer on-disk versions.
- Upgrades from the previous single `$CODEX_HOME/skills/cc-handoff/` Codex skill remove that legacy stamped skill so Codex does not keep discovering stale catch-all workflow prompts. Unstamped user-authored `cc-handoff` skills are left untouched.
- Codex documentation now describes the stable MCP + workflow-skill path instead of promising `/` slash command visibility.
- `submit_bug` now resolves role aliases such as `frontend`, `backend`, and `both` against configured real identities before submitting. This prevents bug reports from being sent to a literal role name like `frontend` when `.cc-handoff.toml` actually names `alex@frontend`.

## [0.1.1] - 2026-05-08

### Added

- `prd` parameter on `submit_handoff` / `submit_request` MCP tools, `--prd` flag on `cc-handoff submit`, and `BuildOptions.Prd` → `Package.PrdMD` (`prd_md` JSON field, `omitempty`). Carries upstream product-requirement / design-intent markdown as background reference. Renders to receiver prompt as `## 📋 产品需求 / 设计意图 (背景参考)` section between the responds-to banner and the summary; **not** required to be addressed line-by-line in INTEGRATION.md (the distinction vs. `note`, which renders as `(必读)` and is). Slash commands `/handoff`, `/handoff-module`, `/request` ask the user once for PRD before the existing note step, accepting three input modalities: file path, pasted text, verbal description (Claude organizes faithfully without inventing). Backward-compatible: `omitempty` keeps old envelopes byte-identical, and all renderers gate the section on `strings.TrimSpace(p.PrdMD) != ""` so empty/whitespace PRDs are skipped uniformly.
- `/request` slash command and MCP tool `submit_request` — reverse flow for the receiver (typically frontend) to ask the partner (typically backend) to add a missing field / endpoint / capability. Summary IS the request body; no git diff or swagger delta is collected. Picked up via the existing `/pickup`; the materialized prompt switches to a request-specific template (doc mode writes `docs/requests/<id>.md`; direct mode modifies code).
- `responds_to` parameter on `submit_handoff` MCP tool / `BuildOptions.RespondsTo` — when the backend's reply handoff carries it, the receiver prompt and `summary.md` render an "↩️ 回应 r_xxx" banner so frontend can trace the loop back to the original request.
- `handoffschema.Kind` (`KindDelivery` / `KindRequest`) on `Package` and `ListItem`; new `kind` column in the `handoffs` SQLite table (idempotent migration on relay startup). Empty kind on legacy payloads is treated as `KindDelivery` via `Package.EffectiveKind()`.
- `[REQUEST]` / `[handoff]` tag in `list_inbox` / `list_sent` output so the receiver can tell at a glance what's pending.
- `[triggers].auto_launch_normal` option in `.cc-handoff.toml` — when `true` alongside `auto_launch=true`, normal-priority handoffs/requests also spawn a terminal (default `false`: only `urgent` ones do, preserving prior behavior).
- Presence broadcast — relay fans out `user.online` / `user.offline` SSE events to every other connected identity when an identity's first watch session attaches or its last one drops. The receiver's `cc-handoff watch` shows a desktop notification. Reconnect blips can produce offline-then-online; opt out with `[triggers].mute_user_presence = true`.
- Auto-launch options in `[triggers]`: `pre_launch` (shell snippet inserted between `cd <repo>` and the agent invocation — for multi-account OAuth like `clset 6` or env activation), `launch_interactive` (start the agent without `-p`, then inject the prompt body via the terminal app's API after the REPL is ready; bracketed-paste markers preserve multi-line content; macOS only), `launch_mode` (`"window"` default, `"split"` for iTerm2 split-pane / Terminal.app new tab fallback). `Agent.POSIXPromptCmd` / `PowerShellPromptCmd` signatures gained `preLaunch` and `interactive` parameters as a result.

- `[triggers].ack_on_launch` option (`"never"` default / `"after_exit"` / `"on_launch"` / `"slash_pickup"`) wires `/pickup`-equivalent ack into the auto-launch flow. `after_exit` chains `cc-handoff pickup <id>` after the agent exits cleanly (one-shot mode) or appends a postlude line to the injected prompt body asking the agent to call `pickup_handoff` MCP before completing (interactive mode). `on_launch` chains pickup ahead of the agent invocation in a brace group so pickup failure doesn't block the launch — refused with `launch_interactive=true`. `slash_pickup` starts the agent interactively and injects `/pickup` as the first user input so the agent runs the slash-command template (which calls `pickup_handoff` MCP itself) — requires `launch_interactive=true` and Claude (slash commands aren't a Codex feature); macOS only. `ack_on_launch="never"` (the default) preserves the prior behavior of manual `/pickup`.
- `cc-handoff status <id>` and MCP tool `status_handoff` — sender-side visibility into recipient state (pending / picked / retracted), picked_at, comment count, last comment summary.
- `cc-handoff sent [--limit N]` and MCP tool `list_sent` — list handoffs you've sent recently with state.
- `cc-handoff retract <id> [--reason TEXT]` and MCP tool `retract_handoff` — sender-only cancellation of still-pending handoffs. Recipient watch surfaces a `RETRACTED.md` marker + desktop notification via the new `handoff.retracted` SSE event.
- `cc-handoff inbox [--json]` and MCP tool `list_local_inbox` — list handoffs already materialized into the local repo's inbox dir, with retract / comment flags.
- `cc-handoff open <id> [--dry]` — re-launch the configured agent on a previously picked handoff (useful when the auto-launched terminal was closed or the machine rebooted).
- Relay endpoints: `GET /v1/handoffs/{id}/status`, `POST /v1/handoffs/{id}/retract`, `GET /v1/handoffs?as=sender`.
- `handoffschema.StateRetracted` and `RetractEvent` schema additions; `ListItem` gains optional `recipient` field for sender-side listings.

### Changed

- `cc-handoff init` finish message now branches sender vs receiver next steps explicitly instead of a single generic line.
- `cc-handoff pickup` final output points at the new `cc-handoff open <id>` command rather than vague "feed it to your agent session".
- "Summary is empty" error from `submit` now includes a Markdown template the user can paste in.
- `transport.Client` typed errors `ErrNotImplemented` / `ErrConflict`; CLI surfaces "your relay is too old, run `make deploy`" when calling new endpoints against an unupgraded relay.

## [0.1.0] - 2026-04-30

First tagged release. Cuts a baseline before iteration so the MCP server version embedded at build time is no longer hard-coded `"0.1.0"` but driven by `VERSION` + ldflags.

### Added

- `cc-handoff version` subcommand prints the embedded semver, vcs revision, dirty flag, and build time. Helps users compare a long-running MCP process against the binary on disk.
- `cc-handoff-mcp` logs `cc-handoff <ver> (<sha>) built <time>` to stderr at startup, and embeds the same version string in its MCP `serverInfo`.
- Stale-binary detection: when the on-disk `cc-handoff-mcp` binary mtime moves forward after the process started, every tool result is prefixed with a warning telling the user to `/mcp` reconnect.
- `Makefile` targets: `cli`, `mcp`, `relay`, `install`, `version`, `release-tag`. All builds inject the version via `-ldflags`.
- `internal/version` package exposes `Version` (ldflags-overridable) and `Full()` (formatted with vcs metadata).
- `/handoff-module` slash command: composes a self-contained module API brief and submits it via `submit_handoff`'s `module_paths` parameter.

### Changed

- `internal/inbox/materialize.go` `renderPromptMD` detects module-brief mode by content shape (`p.Git == nil`) instead of relying solely on `p.ModulePaths`. An older receiver MCP that strips the `module_paths` JSON field still gets the right prompt template.
- Step 0 of the receiver prompt no longer references "API delta" when there is no api-delta to consume (module mode).
- `internal/rules/engine.go` `Apply` performs a second-pass dedup on `(SuggestEdit, SuggestCreate)`. In module mode where many handler/dto files in the same module route to the same client target, 14 redundant hints collapse to one with `(and N other paths in module)` annotation.

[Unreleased]: https://github.com/gmslll/cc-collaboration/compare/v0.6.3...HEAD
[0.6.3]: https://github.com/gmslll/cc-collaboration/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/gmslll/cc-collaboration/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/gmslll/cc-collaboration/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/gmslll/cc-collaboration/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/gmslll/cc-collaboration/compare/v0.3.0...v0.5.0
[0.3.0]: https://github.com/gmslll/cc-collaboration/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gmslll/cc-collaboration/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/gmslll/cc-collaboration/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/gmslll/cc-collaboration/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gmslll/cc-collaboration/releases/tag/v0.1.0
