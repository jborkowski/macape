#!/usr/bin/env bash
# Build macape release binaries and upload them to a GitHub Release.
#
# Usage:
#   ./scripts/publish-release.sh [OPTIONS] [TAG]
#
# TAG defaults to the newest local git tag (e.g. v0.2.0).
#
# Options:
#   --skip-tests     Do not run `swift test` before building
#   --draft          Create the release as a draft (when creating)
#   --create         Create the GitHub release if it does not exist
#   --notes-file F   Release notes file (used with --create)
#   --dry-run        Build and package only; do not call `gh release`
#
# Requirements: swift, gh (authenticated), tar, shasum
#
# Artifacts (under dist/):
#   macape-<tag>-darwin-<arch>.tar.gz
#   macape-<tag>-darwin-<arch>.tar.gz.sha256
#
# Tarball layout:
#   macape-<tag>-darwin-<arch>/
#     bin/macape
#     bin/macape-bar
#     share/macape.conf.example
#     INSTALL.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_TESTS=0
DRAFT=0
CREATE=0
DRY_RUN=0
NOTES_FILE=""

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests) SKIP_TESTS=1; shift ;;
    --draft) DRAFT=1; CREATE=1; shift ;;
    --create) CREATE=1; shift ;;
    --notes-file)
      [[ $# -ge 2 ]] || { echo "error: --notes-file requires a path" >&2; exit 2; }
      NOTES_FILE="$2"
      CREATE=1
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage 2 ;;
    *)
      if [[ -n "${TAG:-}" ]]; then
        echo "error: unexpected argument: $1" >&2
        usage 2
      fi
      TAG="$1"
      shift
      ;;
  esac
done

if [[ -z "${TAG:-}" ]]; then
  TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi
if [[ -z "$TAG" ]]; then
  echo "error: no TAG provided and no git tags found" >&2
  exit 1
fi
if [[ "$TAG" != v* ]]; then
  TAG="v${TAG}"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ARCH_SLUG="arm64" ;;
  x86_64) ARCH_SLUG="x86_64" ;;
  *)
    echo "error: unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

PKG_NAME="macape-${TAG}-darwin-${ARCH_SLUG}"
DIST_DIR="$ROOT/dist"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/macape-release.XXXXXX")"
PKG_ROOT="$STAGING/$PKG_NAME"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd swift
require_cmd gh
require_cmd tar
require_cmd shasum

echo "==> Publishing ${TAG} (${ARCH_SLUG})"

if [[ "$SKIP_TESTS" -eq 0 ]]; then
  echo "==> Running tests"
  swift test
fi

echo "==> Building release binaries"
swift build \
  --configuration release \
  --disable-sandbox \
  --product macape \
  -Xswiftc -Osize
swift build \
  --configuration release \
  --disable-sandbox \
  --product macape-bar \
  -Xswiftc -Osize

mkdir -p "$PKG_ROOT/bin" "$PKG_ROOT/share" "$DIST_DIR"

cp ".build/release/macape" "$PKG_ROOT/bin/"
cp ".build/release/macape-bar" "$PKG_ROOT/bin/"
cp "macape.conf.example" "$PKG_ROOT/share/"
chmod 755 "$PKG_ROOT/bin/macape" "$PKG_ROOT/bin/macape-bar"

cat >"$PKG_ROOT/INSTALL.txt" <<EOF
macape ${TAG} (${ARCH_SLUG})
=======================

1. Copy binaries to a directory on your PATH, e.g.:

   sudo cp bin/macape bin/macape-bar /usr/local/bin/

2. Copy the example config:

   mkdir -p ~/.config/macape
   cp share/macape.conf.example ~/.config/macape/macape.conf

3. Grant Accessibility to the macape binary:

   System Settings → Privacy & Security → Accessibility
   Add: /usr/local/bin/macape  (or wherever you installed it)

4. Run the daemon:

   macape

   Optional menu-bar controller (needs a GUI session):

   macape-bar

IPC socket: ~/.config/macape/macape.sock
Stats:       macape --stats

Homebrew install (alternative):
  brew tap jborkowski/macape https://github.com/jborkowski/macape.git
  brew install jborkowski/macape/macape
EOF

ARCHIVE="$DIST_DIR/${PKG_NAME}.tar.gz"
CHECKSUM_FILE="${ARCHIVE}.sha256"

echo "==> Packaging ${ARCHIVE}"
tar -C "$STAGING" -czf "$ARCHIVE" "$PKG_NAME"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM_FILE")"
)

echo "==> Artifact"
ls -lh "$ARCHIVE"
cat "$CHECKSUM_FILE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> Dry run complete (not uploading)"
  exit 0
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
  if [[ "$CREATE" -eq 0 ]]; then
    echo "error: GitHub release ${TAG} does not exist. Re-run with --create or create it manually." >&2
    exit 1
  fi
  echo "==> Creating GitHub release ${TAG}"
  CREATE_ARGS=(release create "$TAG" --title "$TAG")
  if [[ "$DRAFT" -eq 1 ]]; then
    CREATE_ARGS+=(--draft)
  fi
  if [[ -n "$NOTES_FILE" ]]; then
    CREATE_ARGS+=(--notes-file "$NOTES_FILE")
  else
    PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
    if [[ -n "$PREV_TAG" ]]; then
      NOTES="$(git log "${PREV_TAG}..HEAD" --pretty=format:'- %s')"
    else
      NOTES="Release ${TAG}"
    fi
    CREATE_ARGS+=(--notes "$NOTES")
  fi
  gh "${CREATE_ARGS[@]}"
fi

echo "==> Uploading assets to ${TAG}"
gh release upload "$TAG" "$ARCHIVE" "$CHECKSUM_FILE" --clobber

echo "==> Done: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/${TAG}"
