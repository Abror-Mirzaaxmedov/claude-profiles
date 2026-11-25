# Claude Profiles

Local, open-source profile manager for the official Claude Desktop application.
It starts Claude with a distinct Chromium/Electron `--user-data-dir` for every
profile, letting two accounts keep separate sign-ins, settings and local data.

![Claude Profiles icon](Assets/AppIcon.png)

## Platforms

| Platform | Launcher | Requirements |
| --- | --- | --- |
| macOS 15+ | Native AppKit app | Apple Command Line Tools only — no full Xcode |
| Ubuntu 22.04+ / Debian 12+ | Python/Tkinter desktop app | Python 3, Tkinter and official Claude Desktop |

The project deliberately supports **two profiles**: for example, Personal and
Work. It does not include a server, analytics, cloud sync or paid components.

## Install

Detailed, copy-pasteable steps are in [docs/INSTALL.md](docs/INSTALL.md).

Quick start on macOS:

```zsh
git clone git@github.com:Abror-Mirzaaxmedov/claude-profiles.git
cd claude-profiles
xcode-select --install
./scripts/build-app.sh
open "dist/Claude Profiles.app"
```

Quick start on Ubuntu:

```bash
git clone git@github.com:Abror-Mirzaaxmedov/claude-profiles.git
cd claude-profiles
sudo apt install python3-tk
chmod +x linux/install.sh
./linux/install.sh
```

Install the official Claude Desktop application first. On Ubuntu, Anthropic
provides it through its apt repository; the exact current commands are linked
in the [installation guide](docs/INSTALL.md#ubuntu-2204--debian-12).

## What it does

- create, rename, duplicate, launch, stop and remove profiles;
- keeps every profile in an independent Chromium/Electron data directory;
- keeps profile metadata only on the local computer;
- limits the interface to two profiles;
- moves deleted data to a local recovery folder rather than deleting it
  immediately.

## Where data lives

| Platform | Profile data | Profile list |
| --- | --- | --- |
| macOS | `~/Library/Application Support/ClaudeProfiles/Profiles/` | `~/Library/Application Support/ClaudeProfiles/profiles.json` |
| Linux | `~/.local/share/ClaudeProfiles/Profiles/` | `~/.config/ClaudeProfiles/profiles.json` |

## Staying signed in

Claude can be started without this launcher: from the Dock or Spotlight, by a
`claude://` link, or by Claude itself after an auto-update. Such a start has no
`--user-data-dir` and uses `~/Library/Application Support/Claude`. To keep those
starts signed in, Claude Profiles makes that path a link to the **default**
profile (marked with a star; click the star on the other card to switch). If a
real folder already sits there, it is never touched — the footer then explains
how to fix it.

Claude finishes browser sign-in through a `claude://` link, and macOS delivers
it to any running Claude instance. When you launch a profile that is not signed
in yet while the other one is running, the launcher offers to close the other
one until sign-in is done, so the accounts don't get mixed up.

Running profiles are detected from the real arguments of each Claude process,
so the status stays right after Claude relaunches itself or the launcher restarts.

## Important limitation

This is not an Anthropic-supported multi-profile API. It relies on the
Chromium/Electron `--user-data-dir` flag, so after each Claude Desktop update
open both profiles once and confirm that their accounts remain isolated.

On macOS, all Claude instances share Anthropic's bundle identifier. macOS may
therefore show the same Claude icon for both running instances; the separate
**Claude Profiles** app is the launcher in the Dock.

## Development checks

```zsh
# macOS app
swift build

# Linux launcher syntax and local prerequisite check
python3 -m py_compile linux/claude_profiles.py
python3 linux/claude_profiles.py --diagnose
```

## License

[MIT](LICENSE)
