#!/bin/zsh
set -euo pipefail

version="${1:?Usage: scripts/package-release.sh <version>}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Version must use MAJOR.MINOR.PATCH (for example, 0.2.0)."
  exit 2
fi

root="${0:A:h:h}"
cd "$root"
dist="$root/.build/dist/$version"
arm_scratch="$root/.build/release-arm64"
x86_scratch="$root/.build/release-x86_64"

swift build --configuration release --scratch-path "$arm_scratch" --triple arm64-apple-macosx14.0
swift build --configuration release --scratch-path "$x86_scratch" --triple x86_64-apple-macosx14.0

mkdir -p "$dist/Token Meter.app/Contents/MacOS"
lipo -create \
  "$arm_scratch/out/Products/Release/TokenMeter" \
  "$x86_scratch/out/Products/Release/TokenMeter" \
  -output "$dist/Token Meter.app/Contents/MacOS/TokenMeter"

cat > "$dist/Token Meter.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Token Meter</string>
  <key>CFBundleExecutable</key><string>TokenMeter</string>
  <key>CFBundleIdentifier</key><string>com.lightframe.TokenMeter</string>
  <key>CFBundleName</key><string>Token Meter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$dist/Token Meter.app/Contents/Info.plist"
codesign --force --deep --sign - "$dist/Token Meter.app"
ditto -c -k --sequesterRsrc --keepParent "$dist/Token Meter.app" \
  "$root/.build/dist/TokenMeter-$version-macOS-universal.zip"
print "Packaged .build/dist/TokenMeter-$version-macOS-universal.zip"
