#!/bin/zsh
# Builds Speak.app (release), signs it with your Apple Development identity so
# macOS keeps Accessibility/Microphone grants across rebuilds, and installs to
# ~/Applications. Usage: scripts/build-app.sh [--no-install]
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Speak
APP=build/Speak.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Speak"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  ICON=build/icon.iconset; mkdir -p $ICON
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out $ICON/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out $ICON/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICON -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" \
  --entitlements Resources/Speak.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
du -sh "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  mkdir -p ~/Applications
  pkill -x Speak 2>/dev/null || true
  rm -rf ~/Applications/Speak.app
  cp -R "$APP" ~/Applications/Speak.app
  echo "Installed: ~/Applications/Speak.app"
  rm -rf "$APP"   # leave only one copy on disk so macOS never launches a stray one
fi
