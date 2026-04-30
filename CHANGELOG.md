# Changelog

All notable changes to cc-handoff are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

The single source of truth for the version number is the `VERSION` file at the repo root. `make release-tag` refuses to tag unless `CHANGELOG.md` has a matching `## [X.Y.Z]` heading.

## [Unreleased]

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
