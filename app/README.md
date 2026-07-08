# Infinite Agent Platform — GUI client (Flutter)

A native cross-platform workspace for Infinite Agent Platform (Windows / macOS /
Linux / Android, iOS buildable). It is the enterprise client for projects,
agent sessions, the coordination queue, account administration, and remote
workspace access.

The app intentionally keeps the legacy Go compatibility layer:

- **Shared data** (coordination queue, delivery docs, comments, projects,
  accounts, tokens, live events) → the enterprise relay HTTP API over
  `Authorization: Bearer` + SSE.
- **Local ops** (desktop only — receive → git worktree → materialize) → it shells
  the `cc-handoff` CLI: `cc-handoff pickup <id> --worktree --json`.
- **Agent terminal** (desktop only) → `xterm` + `flutter_pty` run the agent
  (`cd '<worktree>' && claude`) in an embedded PTY. No Go at terminal time.

The product UI is Infinite Agent Platform. The `cc-handoff` CLI and
`cc-handoff-mcp` names remain the compatibility bridge for existing installs,
scripts, and MCP integrations.

## Platform split

| | Desktop (Win/Mac/Linux) | Android / iOS |
|---|---|---|
| Queue · docs · comments · ack · projects · account · admin | ✅ | ✅ |
| receive/pickup → worktree → embedded agent terminal | ✅ | ❌ (no git/shell/PTY) |

## Prerequisites

- **Flutter SDK** (`flutter --version`; stable channel).
- **A configured `~/.config/cc-handoff/config.toml`** (`relay_url`, `token`,
  `identity`, and `[[workspace]]` entries so a work package's repo resolves to a
  local clone). The app reads the same compatibility config file the CLI uses.
- **Desktop only:** the **`cc-handoff` CLI on your PATH** (the app shells it for
  pickup). Install via the repo's `make install`.
- Android build: Android SDK + NDK (Flutter installs the NDK on first build).

## Run / build

```bash
flutter pub get
flutter run -d macos                 # dev window (also: -d windows / -d linux)
flutter build macos --release        # → build/macos/Build/Products/Release/
flutter build apk --release          # → build/app/outputs/flutter-apk/
```

Convenience wrappers exist in the repo Makefile: `make app-run` / `app-macos` /
`app-apk`.

## Notes

- **macOS sandbox is disabled** (`macos/Runner/*.entitlements`) — the app reads
  `~/.config`, shells the CLI, and runs PTYs, none of which the sandbox allows.
  So this is **not** an App-Store build. Distribution needs `codesign` +
  notarization (not automated here).
- **Android/iOS release signing** needs a keystore / provisioning profile
  (Flutter docs); the debug build is installable as-is for testing.
- Chinese renders via the system font fallback — no bundled font needed.
