#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
build_dir="$root_dir/.build/release"
app_dir="$root_dir/dist/Claude Profiles.app"

cd "$root_dir"
swift build -c release
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$build_dir/ClaudeProfiles" "$app_dir/Contents/MacOS/ClaudeProfiles"
node "$root_dir/scripts/make-icns.mjs" "$root_dir/Assets/AppIcon.png" "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ClaudeProfiles</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.claudeprofiles.manager</string>
  <key>CFBundleName</key><string>Claude Profiles</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
print "Built: $app_dir"
