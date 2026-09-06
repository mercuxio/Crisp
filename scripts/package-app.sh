#!/bin/bash
# Assembles Crisp.app from the SwiftPM release build.
#
# SwiftPM produces a bare Mach-O executable and has no concept of an
# application bundle, so the bundle is built by hand here. Everything below is
# the minimum macOS needs to treat the result as an app: the directory layout,
# an Info.plist, and a signature.
#
# The signature is ad-hoc (`-`). That is enough for a locally built app the
# user launches themselves, and is NOT enough for distribution — shipping needs
# a Developer ID identity plus notarization (spec §14).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Crisp.app"

cd "$ROOT"
swift build --build-system native -c release --product Crisp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Crisp" "$APP/Contents/MacOS/Crisp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
