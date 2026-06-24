#!/usr/bin/env bash
# Package the cc-handoff GUI for distribution.
#
# The desktop GUI shells out to the `cc-handoff` CLI for local git/worktree/
# pickup ops, so this embeds a copy of that binary INSIDE the app bundle (next
# to the GUI executable). cli.dart resolves it by absolute path, so the app
# works with no separate `cc-handoff` install ("内嵌直接用").
#
# Run on macOS. Builds the macOS .app and/or the Android APK, and cross-builds
# the Windows cc-handoff.exe for use by scripts/package.ps1. Flutter's Windows
# DESKTOP build only runs on Windows — package the .exe app there.
#
# Usage:
#   scripts/package.sh [macos|android|windows-cli|all]   # default: all
#
# Output: dist/
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(cat VERSION)
LDFLAGS="-X 'github.com/cc-collaboration/internal/version.Version=${VERSION}'"
DIST="$ROOT/dist"
target="${1:-all}"

mkdir -p "$DIST" "$ROOT/bin"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }

build_macos() {
  need go; need flutter; need lipo; need ditto
  echo "==> macOS: building universal cc-handoff CLI"
  # Universal (Intel + Apple Silicon) so the embedded CLI runs regardless of the
  # arch Flutter built the app for.
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags "$LDFLAGS" -o "$ROOT/bin/cc-handoff-darwin-amd64" ./cmd/cc-handoff
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$LDFLAGS" -o "$ROOT/bin/cc-handoff-darwin-arm64" ./cmd/cc-handoff
  lipo -create -output "$ROOT/bin/cc-handoff-darwin-universal" \
    "$ROOT/bin/cc-handoff-darwin-amd64" "$ROOT/bin/cc-handoff-darwin-arm64"

  echo "==> macOS: flutter build macos --release"
  (cd app && flutter build macos --release)

  local appdir
  appdir=$(ls -d "$ROOT"/app/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1)
  [ -n "$appdir" ] || { echo "macOS .app not found under app/build/macos/.../Release" >&2; exit 1; }

  echo "==> macOS: embedding cc-handoff into $(basename "$appdir")/Contents/MacOS"
  install -m 0755 "$ROOT/bin/cc-handoff-darwin-universal" "$appdir/Contents/MacOS/cc-handoff"

  local name zip
  name=$(basename "$appdir" .app)
  zip="$DIST/${name}-macos-v${VERSION}.zip"
  rm -f "$zip"
  # ditto preserves the .app bundle (symlinks, resource forks) — `zip` does not.
  (cd "$(dirname "$appdir")" && ditto -c -k --keepParent "$(basename "$appdir")" "$zip")
  echo "  ✓ $zip"
  echo "  note: the embedded CLI is unsigned. For distribution to other Macs,"
  echo "        codesign + notarize the .app, or recipients run:"
  echo "        xattr -dr com.apple.quarantine /path/to/${name}.app"
}

build_android() {
  need flutter
  # The phone is a remote client (talks to the relay); it never calls the local
  # CLI, so no binary is embedded.
  echo "==> Android: flutter build apk --release"
  (cd app && flutter build apk --release)
  local apk="$ROOT/app/build/app/outputs/flutter-apk/app-release.apk"
  [ -f "$apk" ] || { echo "APK not found at $apk" >&2; exit 1; }
  cp "$apk" "$DIST/cc-handoff-android-v${VERSION}.apk"
  echo "  ✓ $DIST/cc-handoff-android-v${VERSION}.apk"
}

windows_cli() {
  need go; need make
  # Reuse the Makefile's cross-build targets so build flags / output names have a
  # single source. (The macOS build above is inline because the Makefile has no
  # universal-darwin target — it's lipo'd here, which is packaging-specific.)
  echo "==> Windows: cross-building cc-handoff.exe (amd64 + arm64) via make"
  make cli-windows-amd64 cli-windows-arm64
  echo "  ✓ bin/cc-handoff-windows-*.exe"
  echo "  next: copy the repo (incl. bin/) to a Windows box and run scripts/package.ps1"
}

case "$target" in
  macos)        build_macos ;;
  android)      build_android ;;
  windows-cli)  windows_cli ;;
  all)          build_macos; build_android; windows_cli ;;
  *) echo "usage: $0 [macos|android|windows-cli|all]" >&2; exit 2 ;;
esac

echo
echo "done → $DIST"
