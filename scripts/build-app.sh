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
iconset_dir="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root_dir/Assets/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$root_dir/Assets/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
rm -rf "${iconset_dir:h}"
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
