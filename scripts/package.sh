#!/bin/zsh
# Builds a shareable zip: universal (Apple Silicon + Intel), signed, with install notes.
# Usage: scripts/package.sh   ->  build/Speak-<version>.zip
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Speak
STAGE=build/share/Speak
rm -rf build/share && mkdir -p "$STAGE/Speak.app/Contents/MacOS" "$STAGE/Speak.app/Contents/Resources"
cp "$BIN" "$STAGE/Speak.app/Contents/MacOS/Speak"
cp Resources/Info.plist "$STAGE/Speak.app/Contents/Info.plist"
[[ -f build/AppIcon.icns ]] || scripts/build-app.sh --no-install >/dev/null
cp build/AppIcon.icns "$STAGE/Speak.app/Contents/Resources/AppIcon.icns"

# Prefer Developer ID (no warning after notarization); else Apple Development.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
[[ -n "$IDENTITY" ]] || IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" \
  --entitlements Resources/Speak.entitlements "$STAGE/Speak.app"
codesign --verify --strict "$STAGE/Speak.app"

cat > "$STAGE/How to install.txt" <<TXT
Speak ${VERSION} — hold a key, talk, let go. Text appears wherever you're typing.
On-device: your voice never leaves your Mac. Requires macOS 26 (Tahoe).

INSTALL
1. Drag Speak.app into your Applications folder.
2. Double-click Speak. macOS will say it "cannot be verified" — click Done.
3. Open System Settings > Privacy & Security, scroll down, click "Open Anyway" next to Speak, then "Open Anyway" again.
4. Allow Microphone and Speech Recognition when asked.
5. When asked for Accessibility, click Open System Settings and switch Speak on.
6. A waveform icon appears in the menu bar. Click it and choose
   "Stop 🌐 key opening emoji/dictation" (or pick another key under "Dictation key").

USE
- Hold fn and talk; let go to type it.
- Double-tap fn for hands-free; tap fn again to finish. Esc cancels.
- Say "new line", "new paragraph", or "scratch that".
TXT

OUT=build/Speak-${VERSION}.zip
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"
echo "Signed with: ${IDENTITY:-ad-hoc}"
ls -lh "$OUT"
