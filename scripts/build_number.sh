#!/bin/bash
# Prints the build number for HEAD: CFBundleVersion, the number Sparkle
# compares, so it has to climb on every release without anyone remembering
# to bump it. The commit count does that on its own, since main only ever
# grows. build.sh stamps it and release.sh publishes it; both ask here.
#
# This repository began on 2026-10-21 as a fresh copy of the private one at
# its 148th commit, and until then that count was the build number (0.1.8
# went out as build 144). Counting on from it keeps every build above the
# ones people already have: a lower number is one the updater never offers.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
HISTORY=148
echo $(( $(git rev-list --count HEAD 2>/dev/null || echo 0) + HISTORY ))
