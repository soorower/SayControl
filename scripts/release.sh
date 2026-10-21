#!/bin/bash
# Cuts a release: the notarised DMG, the update zip, the manifest the website
# reads, the signed appcast the in-app updater reads, and the git tag — from
# one clean commit.
#
#   ./scripts/release.sh          the real thing: Developer ID, notarised, uploaded
#   ./scripts/release.sh --local  a dry run: Developer ID but not notarised,
#                                 nothing tagged or uploaded
#
# Signs with the Developer ID Application cert in this keychain (or
# SIGN_IDENTITY, from the environment or ~/.config/sayctrl-release.env, which
# is sourced if present) and notarises with the keychain profile make_dmg.sh
# describes. The cert's Team ID is the app's identity to macOS: the manifest
# records who signed each release, and the next one refuses to go out under a
# different Developer ID, since users would lose Accessibility and Input
# Monitoring. Run it from the production clone: the tag goes on the commit
# that was built, and `git push origin vX.Y` is the deliberate last step,
# printed rather than done.
#
# With SAYCTRL_R2_BUCKET set (and `wrangler login` done), the files go up to
# R2 behind cdn.sayctrl.com as the last step; without it they stay in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

LOCAL=0
case "${1:-}" in
  --local) LOCAL=1 ;;
  "")      ;;
  *)       echo "Usage: $0 [--local]" >&2; exit 2 ;;
esac

[ -f "$HOME/.config/sayctrl-release.env" ] && . "$HOME/.config/sayctrl-release.env"

fail() { echo "ABORT: $1" >&2; exit 1; }

# A release is a commit, not a working tree: anything uncommitted would ship
# without being in the history the tag points at. A dry run is allowed to be
# messy — it is for trying the pipeline, and nothing it makes is published.
if [ "$LOCAL" = "0" ] && [ -n "$(git status --porcelain)" ]; then
  fail "the working tree has uncommitted changes. Commit or stash them first."
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
TAG="v$VERSION"
CDN="${SAYCTRL_CDN:-https://cdn.sayctrl.com}"
OUTDIR="${SAYCTRL_DIST:-dist}"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Developer ID Application: [^"]*\)"$/\1/p' | head -1)
fi
[ -n "$SIGN_IDENTITY" ] || fail "no Developer ID Application cert in this keychain. Set SIGN_IDENTITY."
case "$SIGN_IDENTITY" in
  "Developer ID Application"*) ;;
  *) fail "SIGN_IDENTITY must be a 'Developer ID Application' certificate, not '$SIGN_IDENTITY'." ;;
esac
export SIGN_IDENTITY
# The identity users already trust must not change under them. The releases
# before the Developer ID were self-signed and went to no one, so only a
# Developer ID on record is held to. A dry run is checked too: it is where a
# wrong cert should show up.
# The live manifest has to be read, not guessed at: a fetch that failed would
# otherwise skip both checks below without a word, while the upload (through
# Cloudflare's API, not the CDN) still went through.
LIVE_JSON=$(curl -fsS "$CDN/latest.json?check=$(date +%s)" 2>/dev/null) \
  || [ "${SAYCTRL_FIRST_RELEASE:-0}" = "1" ] \
  || fail "couldn't read $CDN/latest.json, so this release can't be checked against the live one. Try again, or SAYCTRL_FIRST_RELEASE=1 if nothing has been published yet."
LIVE_JSON="${LIVE_JSON:-}"
PREVIOUS=$(printf '%s' "$LIVE_JSON" | plutil -extract signedBy raw -o - - 2>/dev/null || true)
case "$PREVIOUS" in
  "Developer ID Application"*)
    if [ "$PREVIOUS" != "$SIGN_IDENTITY" ] && [ "${SAYCTRL_ALLOW_IDENTITY_CHANGE:-0}" != "1" ]; then
      fail "the live release is signed by '$PREVIOUS', this one would be '$SIGN_IDENTITY'. Users would lose their permissions. SAYCTRL_ALLOW_IDENTITY_CHANGE=1 to do it anyway."
    fi ;;
esac
if [ "$LOCAL" = "0" ]; then
  # The same version twice would be two different apps under one name.
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] \
      || fail "tag $TAG already exists on another commit. Bump CFBundleShortVersionString in Info.plist."
  fi
fi

# install.sh runs on strangers' Macs under /bin/bash 3.2 in any locale; a
# non-ASCII byte after a variable becomes part of its name there.
perl -ne 'exit 1 if /[^\x00-\x7F]/' scripts/install.sh \
  || fail "scripts/install.sh has non-ASCII characters; it must be plain ASCII."
/bin/bash -n scripts/install.sh || fail "scripts/install.sh has a syntax error."

echo "Release $VERSION (build $BUILD, $COMMIT), signed by $SIGN_IDENTITY$([ "$LOCAL" = "1" ] && echo ", local dry run")"

# The app, the DMG and the zip. Built into a scratch folder so no copy of the
# app is left in the repo root next to the one in /Applications.
SCRATCH=$(mktemp -d /tmp/sayctrl-release.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
SAYCTRL_APP="$SCRATCH/SayControl.app" SAYCTRL_DIST="$OUTDIR" \
  SAYCTRL_NOTARIZE=$([ "$LOCAL" = "1" ] && echo 0 || echo 1) \
  ./scripts/make_dmg.sh

DMG="$OUTDIR/SayControl-$VERSION.dmg"
ZIP="$OUTDIR/SayControl-$VERSION.zip"
[ -f "$DMG" ] && [ -f "$ZIP" ] || fail "make_dmg.sh did not leave both $DMG and $ZIP behind."
SIGNED_BY=$(codesign -dvv "$SCRATCH/SayControl.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[ "$SIGNED_BY" = "$SIGN_IDENTITY" ] || fail "the app came out signed by '${SIGNED_BY:-ad-hoc}', not '$SIGN_IDENTITY'."

# A user's Accessibility, Input Monitoring and Screen Recording grants are
# kept against the designated requirement of the copy they granted, and tccd
# lets an update keep them only if it satisfies that requirement. So the
# check is that one, run on the live release's own bytes, not inferred from
# the cert's name: fetch its zip, read its requirement, test this build
# against it.
case "$PREVIOUS" in
  "Developer ID Application"*)
    PREV_ZIP=$(printf '%s' "$LIVE_JSON" | plutil -extract zip.url raw -o - - 2>/dev/null || true)
    [ -n "$PREV_ZIP" ] || fail "the live latest.json names no zip to check this update against."
    curl -fsSL "$PREV_ZIP" -o "$SCRATCH/previous.zip" || fail "could not fetch the live release ($PREV_ZIP)."
    mkdir -p "$SCRATCH/previous"
    ditto -x -k "$SCRATCH/previous.zip" "$SCRATCH/previous"
    PREV_REQ=$(codesign -d -r- "$SCRATCH/previous/SayControl.app" 2>/dev/null | sed -n 's/^designated => //p')
    [ -n "$PREV_REQ" ] || fail "the live release carries no designated requirement to check against."
    codesign --verify -R="$PREV_REQ" "$SCRATCH/SayControl.app" \
      || fail "this build does not satisfy the live release's designated requirement; every user would lose their permissions."
    echo "Permissions carry over: this build satisfies the live release's requirement."
    ;;
esac

# The manifest. One file, read by the website's download button and by the
# app's update check, so the version on the page and the one on offer can
# never drift apart. Sizes and hashes are of the files as they will be served.
MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size() { stat -f %z "$1"; }
sha()  { shasum -a 256 "$1" | cut -d' ' -f1; }
cat > "$OUTDIR/latest.json" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "commit": "$COMMIT",
  "publishedAt": "$NOW",
  "minMacOS": "$MIN_MACOS",
  "notarized": $([ "$LOCAL" = "1" ] && echo false || echo true),
  "signedBy": "$SIGNED_BY",
  "dmg": {
    "url": "$CDN/SayControl-$VERSION.dmg",
    "size": $(size "$DMG"),
    "sha256": "$(sha "$DMG")"
  },
  "zip": {
    "url": "$CDN/SayControl-$VERSION.zip",
    "size": $(size "$ZIP"),
    "sha256": "$(sha "$ZIP")"
  }
}
JSON
python3 -m json.tool "$OUTDIR/latest.json" >/dev/null || fail "latest.json is not valid JSON"
echo "Wrote $OUTDIR/latest.json"

# The appcast: what the app's own updater reads. generate_appcast signs the
# zip with the EdDSA key in this Mac's keychain (the public half is
# SUPublicEDKey in Info.plist), so only a release cut here will ever install.
# It is pointed at a folder holding just the zip — given dist/ it would list
# the DMG as a second, identical update.
FEED="$SCRATCH/feed"
mkdir -p "$FEED"
cp "$ZIP" "$FEED/"
vendor/sparkle/bin/generate_appcast --download-url-prefix "$CDN/" --link "https://saycontrol.com" \
  -o "$OUTDIR/appcast.xml" "$FEED" >/dev/null
grep -q "sparkle:edSignature=" "$OUTDIR/appcast.xml" || fail "appcast.xml carries no EdDSA signature — is the Sparkle key in this keychain?"
echo "Wrote $OUTDIR/appcast.xml"

if [ "$LOCAL" = "1" ]; then
  echo "Dry run done — nothing tagged, nothing uploaded. $OUTDIR/ holds a Developer ID build, not notarised."
  exit 0
fi

# Upload. The versioned DMG and zip are immutable — one name, one set of
# bytes, cached for a year. SayControl.dmg is the same DMG under a name that
# never changes, so the website has a link that works even while the
# manifest is unreachable; SayCtrl.dmg, the name before the rename, gets it too, so
# an old link still downloads the current app. The manifest and the appcast go LAST: until they
# change, nobody is pointed at anything that isn't already there.
BUCKET="${SAYCTRL_R2_BUCKET:-}"
if [ -n "$BUCKET" ]; then
  wrangler whoami >/dev/null 2>&1 || fail "wrangler is not logged in — run \`wrangler login\` first."
  put() {  # put <file> <key> <content-type> <cache-control>
    wrangler r2 object put "$BUCKET/$2" --file "$1" --content-type "$3" --cache-control "$4" --remote >/dev/null \
      || fail "upload of $2 failed"
    echo "  ↑ $2"
  }
  FOREVER="public, max-age=31536000, immutable"
  SOON="public, max-age=300"
  echo "Uploading to r2://$BUCKET…"
  put "$DMG" "SayControl-$VERSION.dmg" application/x-apple-diskimage "$FOREVER"
  put "$ZIP" "SayControl-$VERSION.zip" application/zip "$FOREVER"
  put "$DMG" "SayControl.dmg" application/x-apple-diskimage "$SOON"
  put "$DMG" "SayCtrl.dmg" application/x-apple-diskimage "$SOON"
  put "$OUTDIR/latest.json" latest.json application/json "$SOON"
  put "$OUTDIR/appcast.xml" appcast.xml application/rss+xml "$SOON"
  # The Terminal installer behind the old one-liner (saycontrol.com/install.sh
  # redirects here), after the manifest: a new script reading a manifest the
  # edge still holds from before could refuse that older release. text/plain
  # so a browser shows it rather than saving it.
  put scripts/install.sh install.sh "text/plain; charset=utf-8" "$SOON"
  # Read it back from the public edge before calling it live. The query
  # string is a cache-buster: the edge holds latest.json for five minutes,
  # and this must see the copy just written, not the one before it.
  LIVE=$(curl -fsS "$CDN/latest.json?release=$BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)
  [ "$LIVE" = "$VERSION" ] || fail "$CDN/latest.json does not say $VERSION yet (got '${LIVE:-nothing}'). Check the bucket's custom domain."
  echo "Live: $CDN/latest.json says $VERSION"
else
  echo "SAYCTRL_R2_BUCKET not set — nothing uploaded. dist/ is ready to put on the CDN."
fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || git tag -a "$TAG" -m "SayControl $VERSION (build $BUILD)"
echo
echo "Release $VERSION is in $OUTDIR/:"
ls -la "$OUTDIR"/SayControl-"$VERSION".dmg "$OUTDIR"/SayControl-"$VERSION".zip "$OUTDIR"/latest.json "$OUTDIR"/appcast.xml
echo
echo "Tagged $TAG on $COMMIT. Last step, by hand:"
echo "  git push origin main $TAG"
