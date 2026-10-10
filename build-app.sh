#!/bin/zsh
set -eu
cd "${0:A:h}"
swift build -c release
app="$PWD/dist/Herdr Notch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/HerdrNotch "$app/Contents/MacOS/HerdrNotch"
cp Resources/monitor.py "$app/Contents/Resources/monitor.py"
cp Resources/claude_statusline.py "$app/Contents/Resources/claude_statusline.py"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.herdr.notch</string>
<key>CFBundleName</key><string>Herdr Notch</string>
<key>CFBundleExecutable</key><string>HerdrNotch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>NSAppleEventsUsageDescription</key><string>在現有 Ghostty Herdr terminal 中切換指定 pane。</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
if xattr -p com.apple.FinderInfo "$app" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$app"
fi
# Keep the development app's designated identity stable across rebuilds.
# A cdhash-only requirement makes Accessibility approval stale every build.
codesign --force --sign - --identifier dev.herdr.notch --requirements '=designated => identifier "dev.herdr.notch"' "$app"
print "Built: $app"
