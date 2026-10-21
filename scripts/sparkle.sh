#!/bin/bash
# Fetches the Sparkle release build.sh links and embeds — the framework the
# app updates itself with — plus Sparkle's command-line tools (generate_keys,
# sign_update, generate_appcast). Pinned to one version and one checksum, so
# a release is built against the same bytes every time. Run by build.sh;
# idempotent, and vendor/ is git-ignored.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
DEST="vendor/sparkle"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

if [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$SPARKLE_VERSION" ] \
   && [ -d "$DEST/Sparkle.framework" ]; then
  echo "Sparkle $SPARKLE_VERSION ready in $DEST"
  exit 0
fi

echo "Fetching Sparkle $SPARKLE_VERSION…"
TMP=$(mktemp -d /tmp/sparkle.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/sparkle.tar.xz"
ACTUAL=$(shasum -a 256 "$TMP/sparkle.tar.xz" | cut -d' ' -f1)
if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
  echo "ABORT: Sparkle download checksum mismatch" >&2
  echo "  expected $SPARKLE_SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$TMP/sparkle.tar.xz" -C "$DEST" ./Sparkle.framework ./bin
echo "$SPARKLE_VERSION" > "$DEST/VERSION"
echo "Sparkle $SPARKLE_VERSION ready in $DEST"
