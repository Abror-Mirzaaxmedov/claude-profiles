#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/claude-profiles"
applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"

mkdir -p "$install_dir" "$applications_dir" "$icons_dir"
install -m 755 "$root_dir/linux/claude_profiles.py" "$install_dir/claude_profiles.py"
install -m 644 "$root_dir/Assets/AppIcon.png" "$icons_dir/claude-profiles.png"

desktop_file="$applications_dir/claude-profiles.desktop"
printf '%s\n' \
  '[Desktop Entry]' \
  'Type=Application' \
  'Name=Claude Profiles' \
  'Comment=Launch two isolated Claude Desktop profiles' \
  "Exec=/usr/bin/env python3 $install_dir/claude_profiles.py" \
  'Icon=claude-profiles' \
  'Terminal=false' \
  'Categories=Utility;Office;' \
  'StartupNotify=true' > "$desktop_file"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi

printf 'Installed Claude Profiles. Open it from the Applications menu.\n'
printf 'Diagnostic command: python3 %s/claude_profiles.py --diagnose\n' "$install_dir"
