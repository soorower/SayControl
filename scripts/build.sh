#!/bin/bash
# Builds SayControl.app from Sources/. Run: ./scripts/build.sh
#
# Universal: an arm64 slice with Metal and an x86_64 slice without, lipo'd
# together, so one DMG runs on every Mac that macOS still supports. The local
# speech engines (Whisper and Parakeet from whisper.cpp, Cohere Transcribe
# from CrispASR, all on one ggml) are static libraries compiled into the
# binary — there is no server for a user to start and no runtime for them to
# install.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

# Two builds come out of this script:
#   ./scripts/build.sh                 SayControl.app, the shipping app
#                                      (SayCtrl.app before the rename; the bundle
#                                      id, executable and folders kept the
#                                      old name, so nothing a Mac remembers
#                                      about the app changes)
#   SAYCTRL_DEV=1 ./scripts/build.sh   "SayCtrl Dev.app", bundle id
#                                      com.sayctrl.app.dev, settings in
#                                      ~/.config/sayctrl-dev
# To macOS they are two different apps, so the dev copy can run all day while
# a fresh install of the shipping one is tried next to it: separate privacy
# grants, separate Spotlight entries, and neither ever opens in place of the
# other. SAYCTRL_APP puts the bundle somewhere other than the repo root.
DEV="${SAYCTRL_DEV:-0}"
if [ "$DEV" = "1" ]; then
  APP="${SAYCTRL_APP:-SayCtrl Dev.app}"
else
  APP="${SAYCTRL_APP:-SayControl.app}"
fi
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

# Fetches and builds the ggml static libraries if they aren't already there.
./scripts/whisper.sh
# Fetches the Sparkle framework the app updates itself with.
./scripts/sparkle.sh

INCLUDES=(-I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include
          -I vendor/crispasr/src)

compile() {
  local ARCH="$1"; shift
  echo "Compiling ${ARCH}…"
  # ggml's Metal backend is arm64-only; Intel falls back to Accelerate.
  local BACKEND=()
  if [ "$ARCH" = "arm64" ]; then
    BACKEND=(-lggml-metal
             -Xlinker -framework -Xlinker Metal
             -Xlinker -framework -Xlinker MetalKit)
  fi
  swiftc -O -swift-version 5 Sources/*.swift \
    -target "${ARCH}-apple-macosx13.0" \
    -file-prefix-map "$PWD=SayCtrl" \
    -import-objc-header Sources/Bridging.h \
    "${INCLUDES[@]}" \
    -L "vendor/lib/$ARCH" \
    -lwhisper -lparakeet -lcrispasr -lggml -lggml-cpu -lggml-blas -lggml-base -lc++ \
    ${BACKEND[@]+"${BACKEND[@]}"} \
    -Xlinker -framework -Xlinker Accelerate \
    -Xlinker -framework -Xlinker Foundation \
    -F vendor/sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "build/SayCtrl-$ARCH"
}

compile arm64
compile x86_64
lipo -create build/SayCtrl-arm64 build/SayCtrl-x86_64 -output "$APP/Contents/MacOS/SayCtrl"
echo "Universal binary: $(lipo -archs "$APP/Contents/MacOS/SayCtrl")"

cp Info.plist "$APP/Contents/Info.plist"
# CFBundleVersion is the build number Sparkle compares, so it has to climb on
# every release without anyone remembering to bump it. The commit count does
# that on its own: main only ever grows, and the production clone carries the
# same commits, so the two folders agree. CFBundleShortVersionString (the
# "2.2" people see) stays a hand-set value in Info.plist.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "Build number: $BUILD_NUMBER"
if [ "$DEV" = "1" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.sayctrl.app.dev" \
                          -c "Set :CFBundleName SayControl Dev" \
                          -c "Set :CFBundleDisplayName SayControl Dev" \
                          -c "Set :CFBundleURLTypes:0:CFBundleURLName com.sayctrl.app.dev.signin" \
                          -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 saycontrol-dev" "$APP/Contents/Info.plist"
fi

if [ ! -f AppIcon.icns ] || [ scripts/make_icon.swift -nt AppIcon.icns ]; then
  echo "Generating icon…"
  swift scripts/make_icon.swift
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SayCtrl's own UI sounds (NSSound(named:) finds bundle resources first).
cp Resources/Sounds/*.wav "$APP/Contents/Resources/"
# The agent voice's fixed lines in each cloud voice (scripts/make_voice_clips.py).
ditto Resources/VoiceClips "$APP/Contents/Resources/VoiceClips"

# The website's display face, for the first-run window's headlines
# (Theme.heroFont registers it at launch). SIL Open Font License; the
# licence travels with it.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

# The voice-activity model rides along — it is what keeps silence from being
# transcribed as a word.
cp vendor/ggml-silero-v6.2.0.bin "$APP/Contents/Resources/"

# Sparkle, embedded. The binary looks for it at @rpath = Contents/Frameworks.
# ditto rather than cp: a framework is mostly symlinks, and they must survive.
mkdir -p "$APP/Contents/Frameworks"
ditto vendor/sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"

# Signing. Each build has its own kind of Apple certificate, found in this
# keychain (SIGN_IDENTITY overrides the pick):
#   SayControl.app         Developer ID Application, the release signature.
#   (com.sayctrl.app)      A local build carries the same one a release does,
#                          so a copy in /Applications keeps its grants when
#                          Sparkle installs the next release over it
#   SayCtrl Dev.app        Apple Development. Gatekeeper refuses it on every
#   (com.sayctrl.app.dev)  other Mac, so a dev build can never pass for a
#                          release, and the Developer ID only ever signs the
#                          shipping app
#   ad-hoc (-)             the fallback on a Mac with neither; every rebuild
#                          is a new app to macOS
#
# macOS ties each grant to the app's designated requirement. For a Developer
# ID that names the Team ID, for Apple Development the certificate's name,
# never the certificate itself, so a renewed cert keeps every grant; a build
# signed by another kind of cert loses them, and the switches still read on
# in System Settings while doing nothing.
#
# Every signature enables the hardened runtime (SAYCTRL_HARDENED=0 to drop it
# while debugging): notarisation requires it, and building with it every day
# means a hardened-only failure (a silent mic, a refused Apple Event) shows
# up on this Mac, never on a user's. SayCtrl.entitlements opens exactly the two
# doors the app uses. A trusted timestamp is requested with the Developer ID
# only: notarisation requires one, and a dev build has no use for the round
# trip to Apple's timestamp server.
identity_of() {  # the first valid code-signing identity whose name starts with $1
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^ *[0-9]*) [0-9A-F]* \"\($1[^\"]*\)\"\$/\1/p" | head -1
}
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if [ "$DEV" = "1" ]; then
    IDENTITY=$(identity_of "Apple Development: ")
  else
    IDENTITY=$(identity_of "Developer ID Application: ")
  fi
fi

if [ "$DEV" != "1" ]; then
  case "$IDENTITY" in
    "Developer ID Application"*) ;;
    *) echo "WARNING: SayControl.app signed by '${IDENTITY:-ad-hoc}', not the Developer ID." >&2
       echo "         Put in /Applications, it loses its permissions at the next update." >&2 ;;
  esac
fi

# Library validation (part of the hardened runtime) lets the app load only
# frameworks signed by its own Team ID. Both Apple certs give Sparkle and the
# app the same one. An ad-hoc signature (or a self-signed cert passed in
# SIGN_IDENTITY) has none, so dyld refuses the framework ("different Team
# IDs") and the app dies at launch; such a build switches validation off in a
# derived copy of the entitlements. The file in the repo, the one every
# Apple-signed build uses, never carries that exception.
ENTITLEMENTS=SayCtrl.entitlements
case "$IDENTITY" in
  "Developer ID Application"*|"Apple Development"*) ;;
  *)
    ENTITLEMENTS=build/local.entitlements
    cp SayCtrl.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS" ;;
esac

SIGN_FLAGS=(--force)
if [ "${SAYCTRL_HARDENED:-1}" = "1" ]; then
  SIGN_FLAGS+=(--options runtime --entitlements "$ENTITLEMENTS")
fi
case "$IDENTITY" in
  "Developer ID"*) SIGN_FLAGS+=(--timestamp) ;;
  *)               SIGN_FLAGS+=(--timestamp=none) ;;
esac

# Sparkle ships signed by its own authors; under our identity it must be
# re-signed, innermost first — the two XPC services, the Autoupdate tool and
# the Updater app inside the framework, then the framework, then the app.
# (A --deep sign over the top is the way entitlements and the hardened
# runtime go missing from the pieces inside, so each is signed by name.)
# Downloader.xpc is sandboxed and keeps its own entitlements; the others take
# only the runtime flag. None of them gets the app's entitlements.
# codesign announces every re-sign on stderr; only real errors get through.
sign() { codesign "$@" 2> >(grep -v "replacing existing signature" >&2); }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
NESTED_FLAGS=(--force)
[ "${SAYCTRL_HARDENED:-1}" = "1" ] && NESTED_FLAGS+=(--options runtime)
case "$IDENTITY" in
  "Developer ID"*) NESTED_FLAGS+=(--timestamp) ;;
  *)               NESTED_FLAGS+=(--timestamp=none) ;;
esac
# Signed by hash: a renewed cert and the old one share a name while both are
# valid, and codesign refuses an ambiguous name. Either one is the same team.
SIGN_AS="-"
if [ -n "$IDENTITY" ]; then
  SIGN_AS=$(security find-identity -p codesigning 2>/dev/null \
    | awk -v n="\"$IDENTITY\"" 'index($0, n) { print $2; exit }')
  SIGN_AS="${SIGN_AS:-$IDENTITY}"
fi
sign "${NESTED_FLAGS[@]}" --sign "$SIGN_AS" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign "${NESTED_FLAGS[@]}" --preserve-metadata=entitlements --sign "$SIGN_AS" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "${NESTED_FLAGS[@]}" --sign "$SIGN_AS" "$SPARKLE/Versions/B/Autoupdate"
sign "${NESTED_FLAGS[@]}" --sign "$SIGN_AS" "$SPARKLE/Versions/B/Updater.app"
sign "${NESTED_FLAGS[@]}" --sign "$SIGN_AS" "$SPARKLE"

if [ -n "$IDENTITY" ]; then
  sign "${SIGN_FLAGS[@]}" --sign "$SIGN_AS" "$APP"
  echo "Signed with stable identity: $IDENTITY (permissions survive rebuilds)"
else
  sign "${SIGN_FLAGS[@]}" --sign - "$APP"
  echo "Ad-hoc signed — macOS sees a new app, so re-grant Accessibility and"
  echo "Input Monitoring in System Settings › Privacy & Security after this build."
  # Opt-in only. This clears THIS app's Accessibility entry in your own privacy
  # database so the next launch re-prompts instead of showing a dead ON toggle.
  # Nothing in the shipped app touches privacy settings — it only ever triggers
  # Apple's standard permission prompts.
  if [ "${SAYCTRL_RESET_TCC:-0}" = "1" ]; then
    tccutil reset Accessibility com.sayctrl.app >/dev/null 2>&1 || true
    echo "Reset this app's Accessibility entry (SAYCTRL_RESET_TCC=1)."
  fi
fi
codesign --verify --strict --deep "$APP"
if [ "${SAYCTRL_HARDENED:-1}" = "1" ]; then
  grep -q audio-input <<<"$(codesign -d --entitlements - "$APP" 2>/dev/null)" \
    || { echo "ABORT: the signature carries no entitlements" >&2; exit 1; }
  if [ "$ENTITLEMENTS" = SayCtrl.entitlements ]; then
    echo "Hardened runtime on, entitlements: audio-input, apple-events"
  else
    echo "Hardened runtime on, entitlements: audio-input, apple-events, and library validation off (no Team ID)"
  fi
fi

rm -rf build
echo "Built $APP"
echo "Launch with: open $APP"
