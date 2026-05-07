# Changelog

All notable changes to cc-handoff are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

The single source of truth for the version number is the `VERSION` file at the repo root. `make release-tag` refuses to tag unless `CHANGELOG.md` has a matching `## [X.Y.Z]` heading.

## [Unreleased]

### Added

- `/request` slash command and MCP tool `submit_request` — reverse flow for the receiver (typically frontend) to ask the partner (typically backend) to add a missing field / endpoint / capability. Summary IS the request body; no git diff or swagger delta is collected. Picked up via the existing `/pickup`; the materialized prompt switches to a request-specific template (doc mode writes `docs/requests/<id>.md`; direct mode modifies code).
- `responds_to` parameter on `submit_handoff` MCP tool / `BuildOptions.RespondsTo` — when the backend's reply handoff carries it, the receiver prompt and `summary.md` render an "↩️ 回应 r_xxx" banner so frontend can trace the loop back to the original request.
- `handoffschema.Kind` (`KindDelivery` / `KindRequest`) on `Package` and `ListItem`; new `kind` column in the `handoffs` SQLite table (idempotent migration on relay startup). Empty kind on legacy payloads is treated as `KindDelivery` via `Package.EffectiveKind()`.
- `[REQUEST]` / `[handoff]` tag in `list_inbox` / `list_sent` output so the receiver can tell at a glance what's pending.
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

[Unreleased]: https://github.com/gmslll/cc-collaboration/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gmslll/cc-collaboration/releases/tag/v0.1.0
