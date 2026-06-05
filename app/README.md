# cc-handoff — GUI client (Flutter)

A native cross-platform GUI for cc-handoff (Windows / macOS / Linux / Android,
iOS buildable). It is a thin front-end over the existing Go work:

- **Shared data** (inbox, handoff docs, comments, projects, accounts, tokens,
  live events) → the relay's HTTP API over `Authorization: Bearer` + SSE.
- **Local ops** (desktop only — pickup → git worktree → materialize) → it shells
  the `cc-handoff` CLI: `cc-handoff pickup <id> --worktree --json`.
- **Agent terminal** (desktop only) → `xterm` + `flutter_pty` run the agent
  (`cd '<worktree>' && claude`) in an embedded PTY. No Go at terminal time.

The relay, the `cc-handoff` CLI, and the agent abstraction are reused as-is; this
app adds no business logic.

## Platform split

| | Desktop (Win/Mac/Linux) | Android / iOS |
|---|---|---|
| Inbox · docs · comments · ack · projects · account · admin | ✅ | ✅ |
| pickup → worktree → embedded agent terminal | ✅ | ❌ (no git/shell/PTY) |

## Prerequisites

- **Flutter SDK** (`flutter --version`; stable channel).
- **A configured `~/.config/cc-handoff/config.toml`** (`relay_url`, `token`,
  `identity`, and `[[workspace]]` entries so a handoff's repo resolves to a local
  clone). The app reads the same file the CLI uses.
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
