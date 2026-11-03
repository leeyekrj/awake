#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Awake.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/credentials"
COMMON=(-swift-version 5 -O -file-prefix-map "$HOME=~")
TOOL="$ROOT/build/credentials/awake-credentials"
SOURCE_HASH=$(shasum -a 256 "$ROOT/Sources/CredentialTool.swift" | awk '{print $1}')
# Preserve the signed credential tool between unchanged builds.
if [ ! -f "$TOOL" ] || [ "$(cat "$ROOT/build/credentials/source.sha256" 2>/dev/null || true)" != "universal:$SOURCE_HASH" ]; then
  for arch in arm64 x86_64; do
    swiftc "${COMMON[@]}" -target "$arch-apple-macosx14.0" "$ROOT/Sources/CredentialTool.swift" -o "$ROOT/build/credentials/$arch" -framework Security
  done
  lipo -create "$ROOT/build/credentials/arm64" "$ROOT/build/credentials/x86_64" -output "$TOOL"
  codesign --force --sign - --identifier io.paul.awake.credentials "$TOOL"
  printf 'universal:%s' "$SOURCE_HASH" > "$ROOT/build/credentials/source.sha256"
fi
cp "$TOOL" "$APP/Contents/Resources/awake-credentials"
for arch in arm64 x86_64; do
  swiftc "${COMMON[@]}" -target "$arch-apple-macosx14.0" \
    "$ROOT/Sources/PowerController.swift" "$ROOT/Sources/PanelView.swift" "$ROOT/Sources/SetupController.swift" "$ROOT/Sources/SetupView.swift" "$ROOT/Sources/main.swift" \
    -o "$ROOT/build/Awake-$arch" -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement -framework Security -framework LocalAuthentication
done
lipo -create "$ROOT/build/Awake-arm64" "$ROOT/build/Awake-x86_64" -output "$APP/Contents/MacOS/Awake"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Awake</string>
<key>CFBundleIdentifier</key><string>io.paul.awake</string>
<key>CFBundleName</key><string>Awake</string>
<key>CFBundleDisplayName</key><string>Awake</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.3</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
cp "$ROOT/Resources/"* "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/awake-credentials" "$APP/Contents/Resources/awake-lidawake" "$APP/Contents/Resources/awake-watchdog" "$APP/Contents/Resources/awake-install.sh" "$APP/Contents/Resources/awake-uninstall.sh" "$APP/Contents/Resources/lidawake-netguard"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
