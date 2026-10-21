#!/bin/bash
# Builds SayControl.app and wraps it in a distributable DMG. Run: ./scripts/make_dmg.sh
#
# The DMG is the app, a shortcut to /Applications, and an arrow between them
# on a painted background: drag, done. The app keeps the signature build.sh
# gave it, the Developer ID, and with SAYCTRL_NOTARIZE=1 the app and then the
# DMG go to Apple's notary service and come back stapled, so a stranger's Mac
# opens it with no warning at all. Needs dmgbuild (pip3 install --user
# dmgbuild) for the Finder layout.
#
# Notarising needs, once per Mac, an app-specific password stored as a
# keychain profile (NOTARY_PROFILE, default "sayctrl-notary"):
#   xcrun notarytool store-credentials sayctrl-notary \
#     --apple-id you@example.com --team-id TEAMID
# (it asks for the app-specific password, so it never lands in shell history).
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP="${SAYCTRL_APP:-SayControl.app}"
# What the app is called on a stranger's Mac: the file in /Applications, the
# disk image's name. SayCtrl.app before the rename.
NAME="SayControl"
VOLNAME="$NAME"
OUTDIR="${SAYCTRL_DIST:-dist}"
STAGE="$(mktemp -d /tmp/sayctrl-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

./scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUTDIR/$NAME-$VERSION.dmg"

echo "Staging…"
cp -R "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

find "$STAGE/$NAME.app" -name '.DS_Store' -delete

# --- Release safety gate -----------------------------------------------------
# Nothing private may ride along to strangers' Macs: no API key, no signing
# certificate or other credential file, and nothing that writes to their privacy
# database. The app is only ever allowed to ASK, through Apple's own prompts.
fail() { echo "ABORT: $1" >&2; exit 1; }

if grep -rqaE 'sk-(ant|proj|or-v1)-[A-Za-z0-9_-]{20}|gsk_[A-Za-z0-9]{20}|xai-[A-Za-z0-9]{20}|csk-[a-z0-9]{20}|AIza[0-9A-Za-z_-]{35}' "$STAGE/$NAME.app"; then
  fail "an API key (OpenAI, Anthropic, OpenRouter, Groq, xAI, Cerebras or Google) is embedded in the app bundle."
fi
# Whatever its shape: every key, token and secret in this Mac's SayControl
# env files (the app's, the dev app's, the cloud's) is looked for byte for
# byte, from a file that is never printed and is gone when the check is.
# Inside $STAGE, so the EXIT trap takes it even when a step below aborts.
SECRETS="$STAGE/.secrets"
{ cat "$HOME"/.config/sayctrl*/.env "$HOME"/.config/sayctrl*/*.env 2>/dev/null || true; } \
  | sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_]*(_KEY|SECRET|TOKEN|PASSWORD)[[:space:]]*=[[:space:]]*//p' \
  | tr -d "\"'\r" | awk 'length >= 16' | sort -u > "$SECRETS"
LEAK=0
[ -s "$SECRETS" ] && grep -rqaF -f "$SECRETS" "$STAGE/$NAME.app" && LEAK=1
rm -f "$SECRETS"
[ "$LEAK" = "0" ] || fail "a key or secret from this Mac's env files is embedded in the app bundle."
if grep -rqa 'BEGIN [A-Z ]*PRIVATE KEY' "$STAGE/$NAME.app"; then
  fail "a private key is embedded in the app bundle."
fi
CREDS=$(find "$STAGE/$NAME.app" \( -name '.env' -o -name '*.p12' -o -name '*.pem' \
        -o -name '*.key' -o -name '*.cer' -o -name '*.mobileprovision' \
        -o -name '*.provisionprofile' \) )
[ -z "$CREDS" ] || fail "credential file(s) in the bundle:"$'\n'"$CREDS"
if grep -rqa 'tccutil' "$STAGE/$NAME.app"; then
  fail "the bundle references tccutil — it must never touch a user's privacy settings."
fi
# Nothing about the person who built it, either: no home directory (the C
# sources stamp their path into asserts unless whisper.sh maps it away), and
# no personal address anywhere in the app's own binary or resources. The
# Developer ID signature carries the developer's legal name by design (it is
# what Gatekeeper shows), so the binary is read with its signature taken off.
BIN="$STAGE/.unsigned-bin"
cp "$STAGE/$NAME.app/Contents/MacOS/SayCtrl" "$BIN"
codesign --remove-signature "$BIN" 2>/dev/null || true
# strings goes to a file first: piped into grep -q, it is cut off at the first
# match, and under pipefail that SIGPIPE turns a hit into a miss.
strings -a "$BIN" > "$BIN.strings"
PERSONAL=""
grep -q '^/Users/' "$BIN.strings" \
  && PERSONAL="a home-directory path is embedded in the binary (rebuild vendor/ with scripts/whisper.sh)."
grep -Eqi '[a-z0-9._-]+@(gmail|icloud|outlook|yahoo|hotmail)\.com' "$BIN.strings" \
  && PERSONAL="a personal email address is embedded in the binary."
{ grep -qai 'sorower' "$BIN" || grep -rqai 'sorower' "$STAGE/$NAME.app/Contents/Resources"; } \
  && PERSONAL="the builder's name is embedded in the bundle."
rm -f "$BIN" "$BIN.strings"
[ -z "$PERSONAL" ] || fail "$PERSONAL"
echo "Safety gate passed: no key or secret, no credentials, no privacy-database writes, nothing personal."
# -----------------------------------------------------------------------------

# The signature that ships is the one build.sh applied: hardened runtime,
# the app's two entitlements, and whichever identity it found. Nothing is
# re-signed here — a second signature over the first is where entitlements
# quietly go missing. What is checked is that it holds together.
codesign --verify --strict --deep "$STAGE/$NAME.app"
AUTHORITY=$(codesign -dvv "$STAGE/$NAME.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
echo "Signed by: ${AUTHORITY:-ad-hoc}"

NOTARIZE="${SAYCTRL_NOTARIZE:-0}"
PROFILE="${NOTARY_PROFILE:-sayctrl-notary}"
if [ "$NOTARIZE" = "1" ]; then
  case "$AUTHORITY" in
    "Developer ID Application"*) ;;
    *) fail "SAYCTRL_NOTARIZE=1 needs a Developer ID signature; this one is '${AUTHORITY:-ad-hoc}'. Set SIGN_IDENTITY." ;;
  esac
  SIG_INFO=$(codesign -dvv "$STAGE/$NAME.app" 2>&1)
  grep -q "^Timestamp=" <<<"$SIG_INFO" \
    || fail "no trusted timestamp on the app signature — the notary service rejects those."

  # The app goes first, on its own, so the ticket is stapled INSIDE the bundle:
  # a copy dragged out of the DMG then verifies offline, and the update zip
  # below carries the same stapled app. The DMG is notarised after, so the
  # disk image itself opens without a warning too.
  echo "Notarising the app…"
  ditto -c -k --keepParent "$STAGE/$NAME.app" "$STAGE/notarize.zip"
  xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$STAGE/$NAME.app"
  spctl --assess --type execute -vv "$STAGE/$NAME.app"
fi

# The window: 660 x 460, the two icons on one line with the path between
# them. Finder counts from the top-left; the background script is told the
# same icon centres, so its pads, path and name tags land on the icons.
# 460 because the title bar and macOS 26's bottom bar take ~60 pt of the
# window, and everything drawn sits in its top 400; an older Finder without
# the bar just shows more paper.
WIN_W=660; WIN_H=460
APP_X=180; FOLDER_X=480; ICON_Y=175
BG="$STAGE/.background.tiff"
swift scripts/dmg_background.swift "$BG" $WIN_W $WIN_H $APP_X $FOLDER_X $ICON_Y

mkdir -p "$OUTDIR"
rm -f "$DMG"
echo "Building ${DMG}…"
# dmgbuild writes the Finder layout (.DS_Store) itself, so no AppleScript and
# no Finder automation prompt. `pip3 install --user dmgbuild` once.
python3 -m dmgbuild -s scripts/dmg_settings.py \
  -D app="$STAGE/$NAME.app" -D background="$BG" -D icon="AppIcon.icns" \
  -D width=$WIN_W -D height=$WIN_H -D appX=$APP_X -D folderX=$FOLDER_X -D iconY=$ICON_Y \
  "$VOLNAME" "$DMG"

# The disk image gets the same Developer ID over it; any other signature
# would mean nothing to Gatekeeper here, so only that one is used.
case "$AUTHORITY" in
  "Developer ID Application"*)
    # By hash: a renewed cert and the old one share a name while both are
    # valid, and codesign refuses an ambiguous name.
    DMG_SIGNER=$(security find-identity -v -p codesigning \
      | awk -v n="\"$AUTHORITY\"" 'index($0, n) { print $2; exit }')
    codesign --force --sign "${DMG_SIGNER:-$AUTHORITY}" --timestamp "$DMG"
    echo "DMG signed." ;;
esac

if [ "$NOTARIZE" = "1" ]; then
  echo "Notarising the DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

# The same app, zipped, for in-app updates (Sparkle wants an archive, not a
# disk image). Made after stapling so the update carries the ticket too.
ZIP="$OUTDIR/$NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE/$NAME.app" "$ZIP"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo "Built $DMG ($SIZE)"
echo "Built $ZIP (update archive)"
if [ "$NOTARIZE" = "1" ]; then
  echo "Notarised and stapled: app, DMG."
else
  echo "Not notarised (SAYCTRL_NOTARIZE=1 with a Developer ID to do that)."
fi
echo "Test it with: open \"$DMG\""
