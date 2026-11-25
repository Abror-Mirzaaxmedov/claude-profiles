# Claude Profiles for Ubuntu

This is a local two-profile launcher for the official Linux Claude Desktop app.
Each profile has a distinct Electron/Chromium `--user-data-dir`, so its sign-in,
settings and local history are stored separately.

## Requirements

- Ubuntu 22.04 LTS or newer (or Debian 12+), x64 or arm64;
- official Claude Desktop for Linux installed; the expected executable is
  `claude-desktop`;
- Python 3 with Tkinter. If Tkinter is absent, install it with
  `sudo apt install python3-tk`.

Install Claude Desktop first using Anthropic's repository:

```bash
sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc https://downloads.claude.ai/claude-desktop/key.asc
echo "deb [signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list
sudo apt update && sudo apt install claude-desktop
```

## Install the launcher

From the extracted project folder:

```bash
chmod +x linux/install.sh
./linux/install.sh
```

It installs only in the current user's home directory:

- launcher code: `~/.local/share/claude-profiles/`;
- desktop shortcut: `~/.local/share/applications/claude-profiles.desktop`;
- profiles: `~/.local/share/ClaudeProfiles/Profiles/`;
- profile list: `~/.config/ClaudeProfiles/profiles.json`.

No account data is sent by the launcher. Deleting a profile moves its data to
`~/.local/share/ClaudeProfiles/Trash/`, rather than immediately deleting it.

## Verify before first launch

```bash
python3 linux/claude_profiles.py --diagnose
```

The launcher is intentionally limited to two profiles. Create both profiles and
sign into each one once. On subsequent launches the saved session should remain
in that profile's own data directory.

## Important limitation

This uses Chromium's `--user-data-dir` flag rather than an Anthropic-supported
multi-profile API. After a Claude Desktop update, launch both profiles once and
verify that each account remains isolated.
