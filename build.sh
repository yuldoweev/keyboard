#!/bin/bash
# UzEnPopup'ni yig'ish: Terminal'da  bash build.sh
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc topilmadi. Avval shuni ishga tushiring:  xcode-select --install"
  exit 1
fi

APP="UzEnPopup.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/UzEnPopup" main.swift -framework Cocoa

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UzEnPopup</string>
    <key>CFBundleIdentifier</key><string>local.uzenpopup</string>
    <key>CFBundleName</key><string>UzEnPopup</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"

echo ""
echo "Tayyor: $(pwd)/$APP"
echo "Ishga tushirish:  open \"$(pwd)/$APP\""
