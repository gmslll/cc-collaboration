# Changelog

All notable changes to cc-handoff are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

The single source of truth for the version number is the `VERSION` file at the repo root. `make release-tag` refuses to tag unless `CHANGELOG.md` has a matching `## [X.Y.Z]` heading.

## [Unreleased]

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

[Unreleased]: https://github.com/gmslll/cc-collaboration/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/gmslll/cc-collaboration/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/gmslll/cc-collaboration/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gmslll/cc-collaboration/releases/tag/v0.1.0
