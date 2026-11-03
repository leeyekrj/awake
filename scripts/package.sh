#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" != --skip-build ]; then bash "$ROOT/scripts/build.sh"; fi
APP="$ROOT/build/Awake.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p "$ROOT/dist"
for binary in "$APP/Contents/MacOS/Awake" "$APP/Contents/Resources/awake-credentials"; do
  lipo "$binary" -verify_arch arm64 x86_64
  if strings "$binary" | grep -F "$HOME/" >/dev/null; then echo 'Developer path detected; refusing release' >&2; exit 1; fi
done
codesign --verify --deep --strict "$APP"
ZIP="$ROOT/dist/Awake-$VERSION-macOS-universal.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "Awake-$VERSION-macOS-universal.zip" > SHA256SUMS.txt)
printf '%s\n' "$ZIP"
