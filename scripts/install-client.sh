#!/usr/bin/env bash
# One-shot install for cc-handoff client (cli + mcp; cc-relay on linux too)
# from prebuilt GitHub release archives.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/gmslll/cc-collaboration/main/scripts/install-client.sh | bash
#
#   # pin a version + override install dir:
#   curl -fsSL ...install-client.sh | INSTALL_DIR=$HOME/.local/bin VERSION=v0.1.2 bash
#
# Env overrides:
#   REPO         GitHub slug          (default: gmslll/cc-collaboration)
#   VERSION      tag to install       (default: latest; e.g. v0.1.2)
#   INSTALL_DIR  install destination  (default: /usr/local/bin if writable, else $HOME/.local/bin)
#   SKIP_RELAY   non-empty to skip cc-relay even on linux
#
# Windows: download the .zip from the Releases page manually and unpack into
# a directory on PATH; this script is POSIX-only.

set -euo pipefail

REPO=${REPO:-gmslll/cc-collaboration}
VERSION=${VERSION:-latest}

# 1. Detect OS / arch
case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=darwin ;;
  *)      echo "unsupported OS: $(uname -s) — grab the archive manually from https://github.com/${REPO}/releases" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *)             echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# 2. Resolve VERSION → tag
if [[ "$VERSION" == "latest" ]]; then
  tag=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  if [[ -z "$tag" ]]; then
    echo "could not resolve latest release tag from https://api.github.com/repos/${REPO}/releases/latest" >&2
    echo "(rate-limited? pass VERSION=vX.Y.Z to skip the API lookup)" >&2
    exit 1
  fi
else
  tag=$VERSION
fi
ver=${tag#v}

archive="cc-handoff_v${ver}_${os}_${arch}.tar.gz"
base_url="https://github.com/${REPO}/releases/download/${tag}"

# 3. Pick INSTALL_DIR
if [[ -z "${INSTALL_DIR:-}" ]]; then
  if [[ -w /usr/local/bin ]]; then
    INSTALL_DIR=/usr/local/bin
  else
    if [[ -z "${HOME:-}" ]]; then
      echo "HOME is not set; cannot pick a fallback install dir — pass INSTALL_DIR=/path/to/bin" >&2
      exit 1
    fi
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
  fi
fi

echo "→ installing cc-handoff $tag ($os/$arch) into $INSTALL_DIR"

# 4. Download archive + checksums
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/$archive"      "$base_url/$archive"
curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base_url/checksums.txt"

# 5. Verify sha256 (sha256sum on linux, shasum -a 256 on macOS)
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "no sha256 tool available (need sha256sum or shasum)" >&2
  exit 1
fi

expected=$(awk -v f="$archive" '$2==f || $2=="*"f {print $1; exit}' "$tmp/checksums.txt")
if [[ -z "$expected" ]]; then
  echo "checksum for $archive not found in checksums.txt" >&2
  exit 1
fi
actual=$(sha256 "$tmp/$archive")
if [[ "$expected" != "$actual" ]]; then
  echo "checksum mismatch for $archive" >&2
  echo "  expected: $expected" >&2
  echo "  actual:   $actual"   >&2
  exit 1
fi

# 6. Extract + install
tar -xzf "$tmp/$archive" -C "$tmp"

binaries=(cc-handoff cc-handoff-mcp)
if [[ "$os" == "linux" && -z "${SKIP_RELAY:-}" && -f "$tmp/cc-relay" ]]; then
  binaries+=(cc-relay)
fi

for bin in "${binaries[@]}"; do
  if [[ ! -f "$tmp/$bin" ]]; then
    echo "warning: $bin not in archive — skipping" >&2
    continue
  fi
  install -m 0755 "$tmp/$bin" "$INSTALL_DIR/$bin"
  echo "  ✓ $INSTALL_DIR/$bin"
done

echo
echo "Done. Verify with: $INSTALL_DIR/cc-handoff version"

# 7. PATH hint
case ":${PATH:-}:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo
     echo "warning: $INSTALL_DIR is not on your PATH."
     echo "         add this line to your shell rc, then reopen the terminal:"
     echo
     echo "         export PATH=\"$INSTALL_DIR:\$PATH\""
     ;;
esac
