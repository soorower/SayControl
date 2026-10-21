#!/bin/bash
# Installs SayControl from Terminal, the way the website offers it:
#
#   curl -fsSL https://saycontrol.com/install.sh | bash
#
# It reads latest.json on the CDN (the manifest release.sh writes), fetches
# the update zip it names, checks the zip's SHA-256 against the manifest and
# the app's code signature, and puts SayControl.app in /Applications - or in
# ~/Applications when /Applications isn't writable - then opens it. A copy
# from before the rename (SayCtrl.app, the same app by bundle id) is replaced
# rather than left beside the new one.
#
# A file fetched with curl carries no quarantine flag, so Gatekeeper never
# looks at it. This script makes Gatekeeper's check itself instead: the app
# must be signed by SayControl's Developer ID and notarised by Apple, or it
# isn't installed.
#
# Run again to update. Environment, for testing:
#   SAYCTRL_CDN=https://...       another manifest host
#   SAYCTRL_INSTALL_DIR=/path   another Applications folder
#   SAYCTRL_NO_OPEN=1           install without launching
#
# Everything runs inside main(), called on the last line, so a download cut
# off halfway through `curl | bash` runs nothing at all.
#
# ASCII only, and release.sh checks. It runs under the /bin/bash 3.2 macOS
# ships, in whatever locale the Terminal has; in a Latin-1 one, bash reads the
# first byte of a UTF-8 "..." after $VERSION as part of the variable's name,
# and set -u stops on "VERSION?: unbound variable".
set -euo pipefail

main() {
  local CDN="${SAYCTRL_CDN:-https://cdn.sayctrl.com}"
  local BUNDLE_ID="com.sayctrl.app"
  local TEAM_ID="4NYJ3FY3K9"
  local APP_NAME="SayControl.app"
  local LEGACY_NAME="SayCtrl.app"

  if [ -t 1 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
  else
    B=""; DIM=""; RED=""; GRN=""; OFF=""
  fi
  say()  { printf '%s\n' "$*"; }
  step() { printf '%s==>%s %s\n' "$B" "$OFF" "$*"; }
  fail() { printf '%sError:%s %s\n' "$RED$B" "$OFF" "$*" >&2; exit 1; }

  [ "$(uname -s)" = "Darwin" ] || fail "SayControl is a Mac app; this installer only runs on macOS."

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/sayctrl-install.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT

  # --- What is the current release? ----------------------------------------
  step "Checking the latest release..."
  curl -fsSL --proto '=https' --tlsv1.2 "$CDN/latest.json" -o "$TMP/latest.json" \
    || fail "couldn't reach $CDN/latest.json. Check your connection and try again."

  # plutil reads JSON and ships with every Mac, so nothing extra is needed.
  field() { plutil -extract "$1" raw -o - "$TMP/latest.json" 2>/dev/null || true; }
  local VERSION ZIP_URL ZIP_SHA MIN_MACOS
  VERSION=$(field version)
  ZIP_URL=$(field zip.url)
  ZIP_SHA=$(field zip.sha256)
  MIN_MACOS=$(field minMacOS)
  [ -n "$VERSION" ] && [ -n "$ZIP_URL" ] && [ -n "$ZIP_SHA" ] \
    || fail "the release manifest is incomplete. Try again in a few minutes."
  case "$ZIP_URL" in https://*) ;; *) fail "the manifest points at a non-HTTPS download." ;; esac

  local HAVE_MACOS
  HAVE_MACOS=$(sw_vers -productVersion)
  if [ -n "$MIN_MACOS" ] && [ "${HAVE_MACOS%%.*}" -lt "${MIN_MACOS%%.*}" ]; then
    fail "SayControl $VERSION needs macOS $MIN_MACOS or later; this Mac has $HAVE_MACOS."
  fi

  # --- Download and check it ------------------------------------------------
  step "Downloading SayControl ${VERSION}..."
  curl -fL --proto '=https' --tlsv1.2 --progress-bar "$ZIP_URL" -o "$TMP/SayControl.zip" \
    || fail "the download failed. Try again."

  local GOT_SHA
  GOT_SHA=$(shasum -a 256 "$TMP/SayControl.zip" | cut -d' ' -f1)
  [ "$GOT_SHA" = "$ZIP_SHA" ] \
    || fail "the download doesn't match the release checksum, so it wasn't installed. Try again."

  ditto -x -k "$TMP/SayControl.zip" "$TMP/unpacked" || fail "couldn't unpack the download."
  local NEW="$TMP/unpacked/$APP_NAME"
  # A release cut before the rename carries the old name; it is the same app.
  [ -d "$NEW" ] || NEW="$TMP/unpacked/$LEGACY_NAME"
  [ -d "$NEW" ] || fail "the download doesn't contain $APP_NAME."

  codesign --verify --strict --deep "$NEW" 2>/dev/null \
    || fail "the app's code signature doesn't verify, so it wasn't installed."
  local SIGNATURE
  SIGNATURE=$(codesign -dv "$NEW" 2>&1 || true)
  grep -qx "Identifier=$BUNDLE_ID" <<<"$SIGNATURE" \
    || fail "the downloaded app isn't SayControl ($BUNDLE_ID), so it wasn't installed."
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$SIGNATURE" \
    || fail "the downloaded app isn't signed by SayControl's developer, so it wasn't installed."
  spctl --assess --type execute "$NEW" 2>/dev/null \
    || fail "macOS doesn't accept the download as notarised by Apple, so it wasn't installed."

  # --- Where does it go? ----------------------------------------------------
  # An existing copy is replaced where it is, whichever name it has;
  # otherwise /Applications, or the per-user folder for an account that
  # can't write there.
  local DIR="${SAYCTRL_INSTALL_DIR:-}"
  if [ -z "$DIR" ]; then
    if [ -d "/Applications/$APP_NAME" ] || [ -d "/Applications/$LEGACY_NAME" ] || [ -w /Applications ]; then
      DIR=/Applications
    else
      DIR="$HOME/Applications"
    fi
  fi
  mkdir -p "$DIR" || fail "couldn't create $DIR."
  local DEST="$DIR/$APP_NAME"
  # The copy from before the rename - only when it really is this app.
  local LEGACY=""
  if [ -d "$DIR/$LEGACY_NAME" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
       "$DIR/$LEGACY_NAME/Contents/Info.plist" 2>/dev/null || true)" = "$BUNDLE_ID" ]; then
    LEGACY="$DIR/$LEGACY_NAME"
  fi

  # Moving a bundle out needs write access to both the folder and the bundle.
  if [ -e "$DEST" ] && { ! [ -w "$DIR" ] || ! [ -w "$DEST" ]; }; then
    fail "$DEST belongs to another account. Drag it to the Trash, then run this again."
  fi
  if [ -n "$LEGACY" ] && ! [ -w "$LEGACY" ]; then
    fail "$LEGACY belongs to another account. Drag it to the Trash, then run this again."
  fi
  [ -w "$DIR" ] || fail "can't write to $DIR."

  # --- Quit the running copy, swap, reopen ----------------------------------
  # Only the copies being replaced are stopped, each matched by its own path.
  local WAS_RUNNING=0 COPY
  for COPY in "$DEST" "$LEGACY"; do
    [ -n "$COPY" ] || continue
    if pgrep -f "$COPY/Contents/MacOS/" >/dev/null 2>&1; then
      WAS_RUNNING=1
      step "Quitting the running SayControl..."
      pkill -TERM -f "$COPY/Contents/MacOS/" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$COPY/Contents/MacOS/" >/dev/null 2>&1 || break
        sleep 0.5
      done
      pkill -KILL -f "$COPY/Contents/MacOS/" 2>/dev/null || true
    fi
  done

  step "Installing to ${DIR}..."
  if [ -e "$DEST" ]; then
    mv "$DEST" "$TMP/previous.app" || fail "couldn't move the old copy out of the way."
  fi
  if ! ditto "$NEW" "$DEST"; then
    rm -rf "$DEST"
    [ -e "$TMP/previous.app" ] && mv "$TMP/previous.app" "$DEST"
    fail "couldn't copy SayControl into $DIR. The previous copy was put back."
  fi
  # The new copy is in, so the old name goes: one app, not two.
  if [ -n "$LEGACY" ]; then
    mv "$LEGACY" "$TMP/legacy.app" 2>/dev/null \
      || say "${DIM}The old $LEGACY_NAME is still in $DIR; drag it to the Trash.${OFF}"
  fi

  say ""
  say "${GRN}${B}SayControl $VERSION is installed${OFF} in $DIR."
  if [ "${SAYCTRL_NO_OPEN:-0}" != "1" ]; then
    open "$DEST"
    if [ "$WAS_RUNNING" = "0" ]; then
      say "It lives in your menu bar. Grant Microphone, Accessibility and"
      say "Input Monitoring when it asks, then hold fn and talk."
    fi
  else
    say "Open it with: open \"$DEST\""
  fi
  say "${DIM}Run the same command again any time to update.${OFF}"
}

main "$@"
