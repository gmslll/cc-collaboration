#!/usr/bin/env bash
# Package the cc-handoff GUI for distribution.
#
# The desktop GUI shells out to the `cc-handoff` CLI for local git/worktree/
# pickup ops (and that CLI in turn launches `cc-handoff-mcp` for Claude/Codex
# MCP), so this embeds BOTH binaries INSIDE the app bundle (next to the GUI
# executable). cli.dart / setup.ResolveMCPBinary resolve them by path, so the app
# works with no separate install ("内嵌直接用").
#
# Run on macOS. Builds the macOS .app and/or the Android APK, and cross-builds
# the Windows cc-handoff.exe + cc-handoff-mcp.exe for use by scripts/package.ps1.
# Flutter's Windows DESKTOP build only runs on Windows — package the .exe app there.
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

# android_version_code maps a semver to a strictly-increasing integer
# (major*10000 + minor*100 + patch), so each release outranks the last — Android
# refuses to install/update to a lower versionCode. (minor/patch assumed < 100.)
android_version_code() {
  local v="$1"; local IFS=.; set -- $v
  echo $(( ${1:-0} * 10000 + ${2:-0} * 100 + ${3:-0} ))
}

build_macos() {
  need go; need flutter; need lipo; need ditto; need codesign
  echo "==> macOS: building universal cc-handoff CLI + cc-handoff-mcp"
  # Universal (Intel + Apple Silicon) so the embedded binaries run regardless of
  # the arch Flutter built the app for.
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags "$LDFLAGS" -o "$ROOT/bin/cc-handoff-darwin-amd64" ./cmd/cc-handoff
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$LDFLAGS" -o "$ROOT/bin/cc-handoff-darwin-arm64" ./cmd/cc-handoff
  lipo -create -output "$ROOT/bin/cc-handoff-darwin-universal" \
    "$ROOT/bin/cc-handoff-darwin-amd64" "$ROOT/bin/cc-handoff-darwin-arm64"
  # cc-handoff-mcp is the MCP server cc-handoff wires into Claude/Codex sessions;
  # setup.ResolveMCPBinary looks for it next to cc-handoff, so it must be embedded
  # alongside it — else MCP setup fails for users with no separate install.
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags "$LDFLAGS" -o "$ROOT/bin/cc-handoff-mcp-darwin-amd64" ./cmd/cc-handoff-mcp
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$LDFLAGS" -o "$ROOT/bin/cc-handoff-mcp-darwin-arm64" ./cmd/cc-handoff-mcp
  lipo -create -output "$ROOT/bin/cc-handoff-mcp-darwin-universal" \
    "$ROOT/bin/cc-handoff-mcp-darwin-amd64" "$ROOT/bin/cc-handoff-mcp-darwin-arm64"

  # Drop any embedded binaries from a previous run BEFORE building. They live in
  # Contents/MacOS (sealed code); on an incremental rebuild Xcode re-signs the
  # bundle over the stale, now-unsealed binaries and fails with
  #   "code object is not signed at all ... In subcomponent: .../MacOS/cc-handoff".
  # Removing them lets Flutter emit a clean, fully-sealed .app that we re-seal below.
  rm -f "$ROOT"/app/build/macos/Build/Products/Release/*.app/Contents/MacOS/cc-handoff \
        "$ROOT"/app/build/macos/Build/Products/Release/*.app/Contents/MacOS/cc-handoff-mcp
  echo "==> macOS: flutter build macos --release"
  # --dart-define embeds the version so the in-app updater can compare (kAppVersion).
  (cd app && flutter build macos --release --dart-define=APP_VERSION="${VERSION}")

  local appdir
  appdir=$(ls -d "$ROOT"/app/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1)
  [ -n "$appdir" ] || { echo "macOS .app not found under app/build/macos/.../Release" >&2; exit 1; }

  echo "==> macOS: embedding cc-handoff + cc-handoff-mcp into $(basename "$appdir")/Contents/MacOS"
  install -m 0755 "$ROOT/bin/cc-handoff-darwin-universal" "$appdir/Contents/MacOS/cc-handoff"
  install -m 0755 "$ROOT/bin/cc-handoff-mcp-darwin-universal" "$appdir/Contents/MacOS/cc-handoff-mcp"

  # Embedding a Mach-O into Contents/MacOS breaks the bundle's code seal
  # (Contents/_CodeSignature/CodeResources no longer lists every file). Re-sign
  # the embedded CLI, then re-seal the whole .app ad-hoc, re-applying the same
  # entitlements Xcode used (sandbox off + network client — see Release.entitlements)
  # so the rebuilt signature keeps them. Without this, `codesign --verify` reports
  # "a sealed resource is missing or invalid" and the next build's CodeSign fails.
  echo "==> macOS: re-sealing bundle (ad-hoc) after embed"
  codesign --force --sign - "$appdir/Contents/MacOS/cc-handoff"
  codesign --force --sign - "$appdir/Contents/MacOS/cc-handoff-mcp"
  codesign --force --sign - \
    --entitlements "$ROOT/app/macos/Runner/Release.entitlements" "$appdir"
  codesign --verify --strict "$appdir"

  local name zip
  name=$(basename "$appdir" .app)
  zip="$DIST/${name}-macos-v${VERSION}.zip"
  rm -f "$zip"
  # ditto preserves the .app bundle (symlinks, resource forks) — `zip` does not.
  (cd "$(dirname "$appdir")" && ditto -c -k --keepParent "$(basename "$appdir")" "$zip")
  echo "  ✓ $zip"
  if [ "$name" != "app" ]; then
    # Legacy updater compatibility: installed pre-rebrand builds look for the
    # old app-macos-vX.Y.Z.zip asset name. The zip still contains the renamed
    # .app bundle; only the GitHub release asset has the compatibility alias.
    local legacy_zip="$DIST/app-macos-v${VERSION}.zip"
    cp "$zip" "$legacy_zip"
    echo "  ✓ $legacy_zip (legacy updater alias)"
  fi
  echo "  note: the .app is ad-hoc signed (not notarized). For distribution to"
  echo "        other Macs, codesign + notarize with a Developer ID, or recipients run:"
  echo "        xattr -dr com.apple.quarantine /path/to/${name}.app"
}

build_android() {
  need flutter
  # The phone is a remote client (talks to the relay); it never calls the local
  # CLI, so no binary is embedded.
  echo "==> Android: flutter pub get (populates the pub cache cargokit's gradle9 patch targets)"
  (cd app && flutter pub get)
  # cargokit (bundled inside irondash_engine_context/super_native_extensions, both
  # pulled in transitively by super_clipboard) calls the Project#exec(Closure) API
  # Gradle 9 removed outright — see the script for the full story/upstream status.
  "$ROOT/scripts/patch_cargokit_gradle9.sh"
  echo "==> Android: flutter build apk --release"
  # --build-name/-number drive the APK's versionName/versionCode from VERSION
  # (not pubspec's fixed 1.0.0+1), so each release is a proper, higher-versioned
  # update. Signing comes from app/android/key.properties when present (CI writes
  # it from secrets; see scripts notes) — else the debug key.
  local code; code=$(android_version_code "$VERSION")
  (cd app && flutter build apk --release \
    --build-name="${VERSION}" --build-number="${code}" \
    --dart-define=APP_VERSION="${VERSION}")
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
  echo "==> Windows: cross-building cc-handoff.exe + cc-handoff-mcp.exe (amd64 + arm64) via make"
  make windows
  echo "  ✓ bin/cc-handoff-windows-*.exe + bin/cc-handoff-mcp-windows-*.exe"
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
