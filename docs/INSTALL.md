# Installation guide

Claude Profiles is a local launcher for **two independent Claude Desktop
profiles**. It does not replace or modify the official Claude app. Install
Claude Desktop first, then install this launcher.

## macOS 15+

### 1. Install Claude Desktop

Install the official Claude Desktop application and leave it at the normal
location:

```text
/Applications/Claude.app
```

The launcher looks for this exact path. If it is not there, drag the official
Claude application into the system `Applications` folder before continuing.

### 2. Install Apple Command Line Tools

The full Xcode download is **not** required. Open Terminal and run:

```zsh
xcode-select --install
```

Complete the macOS dialog, then verify that Swift is available:

```zsh
swift --version
```

### 3. Download and build Claude Profiles

```zsh
git clone git@github.com:Abror-Mirzaaxmedov/claude-profiles.git
cd claude-profiles
./scripts/build-app.sh
open "dist/Claude Profiles.app"
```

The build produces a locally signed application bundle at:

```text
dist/Claude Profiles.app
```

To keep it in the Dock, launch it and choose **Options → Keep in Dock**. You
can also drag the built app to your personal `Applications` folder in Finder.

### 4. Create the two profiles

1. Open **Claude Profiles**.
2. Create `Personal`, click **Launch Claude**, then sign in.
3. Create `Work`, launch it, then sign in with the second account.

The sign-in is stored in each profile directory. You should not need to sign in
again when reopening the same profile.

### macOS troubleshooting

- **“Claude Desktop wasn’t found”** — move the official app to
  `/Applications/Claude.app`.
- **`xcode-select` says the developer directory is invalid** — use
  `xcode-select --install`; do not point it at `/Applications/Xcode.app` unless
  the full Xcode app is actually installed.
- **Both Claude windows have the same Dock icon** — expected macOS behaviour;
  Claude instances have one bundle identifier. Use Claude Profiles as the one
  launcher icon in the Dock.

## Ubuntu 22.04+ / Debian 12+

Claude Desktop for Linux is currently published by Anthropic as a beta. The
launcher requires Ubuntu 22.04+ or Debian 12+, on x64 or arm64.

### 1. Install official Claude Desktop

Use Anthropic's apt repository so Claude receives updates with your normal
system updates:

```bash
sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc https://downloads.claude.ai/claude-desktop/key.asc
echo "deb [signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list
sudo apt update
sudo apt install claude-desktop
```

Confirm that it is available:

```bash
claude-desktop --version
```

### 2. Install the launcher

```bash
git clone git@github.com:Abror-Mirzaaxmedov/claude-profiles.git
cd claude-profiles
sudo apt install python3-tk
chmod +x linux/install.sh
./linux/install.sh
```

The installer does not use `sudo` and writes only to your user account:

- launcher: `~/.local/share/claude-profiles/`;
- app-menu entry: `~/.local/share/applications/claude-profiles.desktop`;
- icon: `~/.local/share/icons/hicolor/512x512/apps/`.

Open **Claude Profiles** from the application menu. Create the Personal and
Work profiles, then sign in to each one once.

### Ubuntu troubleshooting

- **Tkinter is missing** — run `sudo apt install python3-tk`.
- **“Claude Desktop was not found”** — check `command -v claude-desktop` and
  complete the official Claude installation above.
- **Check prerequisites without opening the UI**:

  ```bash
  python3 ~/.local/share/claude-profiles/claude_profiles.py --diagnose
  ```

## Privacy and removal

Claude Profiles never sends profile data anywhere itself. All account data stays
inside the OS paths listed in the main [README](../README.md#where-data-lives).

Removing a profile from the interface moves its folder to a local recovery
directory instead of immediately destroying it:

- macOS: the system Trash;
- Linux: `~/.local/share/ClaudeProfiles/Trash/`.

To remove the launcher on Linux, delete its three installed user-level files
and folders. This does not delete your profiles unless you separately remove
`~/.local/share/ClaudeProfiles/` and `~/.config/ClaudeProfiles/`.
