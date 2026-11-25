#!/usr/bin/env python3
"""Claude Profiles for Ubuntu.

Small, dependency-free (Python standard library only) launcher for two isolated
Claude Desktop profiles.  It expects the official `claude-desktop` Linux binary
to be installed and starts it with a profile-specific Chromium data directory.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


APP_NAME = "Claude Profiles"
MAX_PROFILES = 2
DATA_HOME = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "ClaudeProfiles"
CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "ClaudeProfiles"
PROFILES_HOME = DATA_HOME / "Profiles"
TRASH_HOME = DATA_HOME / "Trash"
REGISTRY_PATH = CONFIG_HOME / "profiles.json"
CLAUDE_BINARY = os.environ.get("CLAUDE_DESKTOP_BIN", "claude-desktop")


@dataclass
class Profile:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    name: str = ""
    account_label: str = ""
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    @classmethod
    def from_json(cls, value: dict) -> "Profile":
        return cls(
            id=str(value["id"]),
            name=str(value.get("name", "")),
            account_label=str(value.get("account_label", value.get("accountLabel", ""))),
            created_at=str(value.get("created_at", value.get("createdAt", "")))
            or datetime.now(timezone.utc).isoformat(),
        )


class ProfileRepository:
    def __init__(self) -> None:
        self.profiles: list[Profile] = []
        self.load()

    def profile_directory(self, profile: Profile) -> Path:
        return PROFILES_HOME / profile.id

    def load(self) -> None:
        PROFILES_HOME.mkdir(parents=True, exist_ok=True)
        if not REGISTRY_PATH.exists():
            return
        try:
            decoded = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
            if not isinstance(decoded, list):
                raise ValueError("the registry must be a list")
            self.profiles = [Profile.from_json(item) for item in decoded]
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
            raise RuntimeError(f"Could not read {REGISTRY_PATH}: {error}") from error

    def save(self) -> None:
        CONFIG_HOME.mkdir(parents=True, exist_ok=True)
        temporary = REGISTRY_PATH.with_suffix(".json.tmp")
        payload = [asdict(profile) for profile in self.profiles]
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(REGISTRY_PATH)

    def create(self, name: str, account_label: str) -> Profile:
        if len(self.profiles) >= MAX_PROFILES:
            raise ValueError("Claude Profiles is intentionally limited to two profiles.")
        profile = Profile(name=name.strip(), account_label=account_label.strip())
        if not profile.name:
            raise ValueError("Profile name is required.")
        self.profiles.append(profile)
        self.save()
        return profile

    def update(self, profile: Profile, name: str, account_label: str) -> None:
        name = name.strip()
        if not name:
            raise ValueError("Profile name is required.")
        profile.name = name
        profile.account_label = account_label.strip()
        self.save()

    def duplicate(self, profile: Profile) -> Profile:
        if is_running(profile, self):
            raise RuntimeError("Stop this profile before duplicating it.")
        if len(self.profiles) >= MAX_PROFILES:
            raise ValueError("Claude Profiles is intentionally limited to two profiles.")
        duplicate = Profile(name=f"{profile.name} Copy", account_label=profile.account_label)
        source, destination = self.profile_directory(profile), self.profile_directory(duplicate)
        if source.exists():
            shutil.copytree(source, destination, symlinks=True)
            remove_chromium_locks(destination)
        self.profiles.append(duplicate)
        self.save()
        return duplicate

    def archive(self, profile: Profile) -> None:
        if is_running(profile, self):
            raise RuntimeError("Stop this profile before removing it.")
        directory = self.profile_directory(profile)
        if directory.exists():
            TRASH_HOME.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            shutil.move(str(directory), str(TRASH_HOME / f"{profile.id}-{stamp}"))
        self.profiles.remove(profile)
        self.save()


def remove_chromium_locks(directory: Path) -> None:
    for name in ("SingletonCookie", "SingletonLock", "SingletonSocket"):
        (directory / name).unlink(missing_ok=True)


def claude_command() -> str | None:
    candidate = Path(CLAUDE_BINARY)
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return shutil.which(CLAUDE_BINARY)


def running_processes(profile: Profile, repository: ProfileRepository) -> Iterable[int]:
    """Find only processes whose command line contains this exact data directory."""
    target = str(repository.profile_directory(profile).resolve())
    proc = Path("/proc")
    if not proc.exists():
        return []
    found: list[int] = []
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            arguments = (entry / "cmdline").read_bytes().split(b"\0")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        for argument in arguments:
            if not argument.startswith(b"--user-data-dir="):
                continue
            value = argument.split(b"=", 1)[1].decode("utf-8", "surrogateescape")
            try:
                if str(Path(value).resolve()) == target:
                    found.append(int(entry.name))
                    break
            except OSError:
                continue
    return found


def is_running(profile: Profile, repository: ProfileRepository) -> bool:
    return bool(list(running_processes(profile, repository)))


def launch(profile: Profile, repository: ProfileRepository) -> None:
    if is_running(profile, repository):
        return
    binary = claude_command()
    if binary is None:
        raise RuntimeError(
            "Claude Desktop was not found. Install the official package, then make sure "
            "`claude-desktop` is available in PATH."
        )
    directory = repository.profile_directory(profile)
    directory.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.Popen(
            [binary, f"--user-data-dir={directory}"],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as error:
        raise RuntimeError(f"Could not launch Claude Desktop: {error}") from error


def stop(profile: Profile, repository: ProfileRepository) -> None:
    pids = list(running_processes(profile, repository))
    if not pids:
        return
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            raise RuntimeError(f"Could not stop Claude process {pid}: {error}") from error


def diagnose() -> int:
    binary = claude_command()
    print(f"Claude Profiles data: {DATA_HOME}")
    print(f"Profile registry: {REGISTRY_PATH}")
    print(f"Claude Desktop: {binary or 'not found'}")
    print("Tkinter: available" if tkinter_available() else "Tkinter: unavailable")
    return 0 if binary and tkinter_available() else 1


def tkinter_available() -> bool:
    try:
        import tkinter  # noqa: F401
    except ImportError:
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Launch isolated Claude Desktop profiles on Ubuntu.")
    parser.add_argument("--diagnose", action="store_true", help="check local prerequisites without opening a window")
    args = parser.parse_args()
    if args.diagnose:
        return diagnose()
    if not tkinter_available():
        print("Tkinter is missing. Install it with: sudo apt install python3-tk", file=sys.stderr)
        return 1
    try:
        app = ClaudeProfilesApp()
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    app.run()
    return 0


class ClaudeProfilesApp:
    """Tk desktop window kept intentionally small and keyboard-friendly."""

    background = "#171717"
    surface = "#222222"
    card = "#272727"
    border = "#414141"
    text = "#F3F2EF"
    muted = "#AAA9A5"
    accent = "#4D7CFE"
    green = "#40D96A"
    destructive = "#E35D6A"

    def __init__(self) -> None:
        import tkinter as tk
        from tkinter import messagebox, simpledialog, ttk

        self.tk = tk
        self.messagebox = messagebox
        self.simpledialog = simpledialog
        self.ttk = ttk
        self.repository = ProfileRepository()
        self.root = tk.Tk()
        self.root.title(APP_NAME)
        self.root.configure(bg=self.background)
        self.root.minsize(760, 510)
        self.root.geometry("880x610")
        self.root.protocol("WM_DELETE_WINDOW", self.root.destroy)
        self._configure_style()
        self.content = tk.Frame(self.root, bg=self.background, padx=32, pady=28)
        self.content.pack(fill="both", expand=True)
        self.refresh()

    def _configure_style(self) -> None:
        style = self.ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except self.tk.TclError:
            pass
        style.configure("Primary.TButton", font=("Sans", 11, "bold"), padding=(16, 9), foreground="#FFFFFF", background=self.accent, borderwidth=0)
        style.map("Primary.TButton", background=[("active", "#3E6FEB"), ("disabled", "#505050")])
        style.configure("Secondary.TButton", font=("Sans", 10, "bold"), padding=(13, 8), foreground=self.text, background="#383838", borderwidth=0)
        style.map("Secondary.TButton", background=[("active", "#474747"), ("disabled", "#303030")])
        style.configure("Danger.TButton", font=("Sans", 10, "bold"), padding=(10, 8), foreground="#FFFFFF", background="#5A3035", borderwidth=0)
        style.map("Danger.TButton", background=[("active", "#713B42")])

    def run(self) -> None:
        self.root.after(850, self._poll)
        self.root.mainloop()

    def _poll(self) -> None:
        if self.root.winfo_exists():
            self.refresh()
            self.root.after(850, self._poll)

    def refresh(self) -> None:
        for child in self.content.winfo_children():
            child.destroy()
        self._header()
        if not self.repository.profiles:
            self._empty_state()
        else:
            for index, profile in enumerate(self.repository.profiles):
                self._profile_card(profile, index)
        self.tk.Frame(self.content, bg=self.background, height=1).pack(fill="x", expand=True)
        self.tk.Label(
            self.content,
            text="Local only  •  Separate Claude sessions  •  No cloud sync",
            bg=self.background,
            fg="#777777",
            font=("Sans", 9),
        ).pack(anchor="w", pady=(22, 0))

    def _header(self) -> None:
        header = self.tk.Frame(self.content, bg=self.background)
        header.pack(fill="x", pady=(0, 24))
        title_group = self.tk.Frame(header, bg=self.background)
        title_group.pack(side="left")
        self.tk.Label(title_group, text="Claude Profiles", bg=self.background, fg=self.text, font=("Sans", 25, "bold")).pack(anchor="w")
        self.tk.Label(title_group, text="Two isolated Claude spaces. One simple launcher.", bg=self.background, fg=self.muted, font=("Sans", 12)).pack(anchor="w", pady=(5, 0))
        if len(self.repository.profiles) < MAX_PROFILES:
            self.ttk.Button(header, text="+  Add profile", style="Primary.TButton", command=self._add_profile).pack(side="right", pady=(7, 0))

    def _empty_state(self) -> None:
        box = self.tk.Frame(self.content, bg=self.surface, highlightthickness=1, highlightbackground=self.border, padx=34, pady=34)
        box.pack(fill="x")
        self.tk.Label(box, text="Create your first profile", bg=self.surface, fg=self.text, font=("Sans", 17, "bold")).pack(anchor="w")
        self.tk.Label(box, text="Each profile gets its own sign-in, settings and Claude history.", bg=self.surface, fg=self.muted, font=("Sans", 11)).pack(anchor="w", pady=(7, 20))
        self.ttk.Button(box, text="Create profile", style="Primary.TButton", command=self._add_profile).pack(anchor="w")

    def _profile_card(self, profile: Profile, index: int) -> None:
        running = is_running(profile, self.repository)
        card = self.tk.Frame(self.content, bg=self.card, highlightthickness=1, highlightbackground=self.border, padx=24, pady=20)
        card.pack(fill="x", pady=(0, 14))
        card.grid_columnconfigure(1, weight=1)

        colors = ("#48588D", "#785940")
        initial = profile.name[:1].upper() or "C"
        avatar = self.tk.Label(card, text=initial, bg=colors[index % len(colors)], fg="#F4F4F4", width=3, height=1, font=("Sans", 25, "bold"), padx=13, pady=12)
        avatar.grid(row=0, column=0, rowspan=2, sticky="nsw", padx=(0, 18))

        info = self.tk.Frame(card, bg=self.card)
        info.grid(row=0, column=1, rowspan=2, sticky="nsew")
        self.tk.Label(info, text=profile.name, bg=self.card, fg=self.text, font=("Sans", 19, "bold")).pack(anchor="w")
        self.tk.Label(info, text=profile.account_label or "Account label not set", bg=self.card, fg=self.muted, font=("Sans", 11)).pack(anchor="w", pady=(4, 10))
        status = self.tk.Label(
            info,
            text="●  Running" if running else "●  Ready",
            bg="#1D3B29" if running else "#343434",
            fg=self.green if running else "#C6C5C1",
            font=("Sans", 10, "bold"),
            padx=12,
            pady=5,
        )
        status.pack(anchor="w")

        controls = self.tk.Frame(card, bg=self.card)
        controls.grid(row=0, column=2, rowspan=2, sticky="e")
        if running:
            self.ttk.Button(controls, text="Stop", style="Secondary.TButton", command=lambda p=profile: self._stop(p)).grid(row=0, column=0, padx=(0, 8))
        else:
            self.ttk.Button(controls, text="Launch Claude", style="Primary.TButton", command=lambda p=profile: self._launch(p)).grid(row=0, column=0, padx=(0, 8))
        self.ttk.Button(controls, text="Edit", style="Secondary.TButton", command=lambda p=profile: self._edit_profile(p)).grid(row=0, column=1, padx=(0, 8))
        self.ttk.Button(controls, text="Delete", style="Danger.TButton", command=lambda p=profile: self._delete_profile(p)).grid(row=0, column=2)
        if not running and len(self.repository.profiles) < MAX_PROFILES:
            self.ttk.Button(controls, text="Duplicate", style="Secondary.TButton", command=lambda p=profile: self._duplicate(p)).grid(row=1, column=0, columnspan=3, sticky="e", pady=(8, 0))

    def _ask_profile(self, title: str, profile: Profile | None = None) -> tuple[str, str] | None:
        name = self.simpledialog.askstring(title, "Profile name", initialvalue=profile.name if profile else "", parent=self.root)
        if name is None:
            return None
        name = name.strip()
        if not name:
            self.messagebox.showerror(APP_NAME, "Profile name is required.", parent=self.root)
            return None
        label = self.simpledialog.askstring(title, "Account label or email (optional)", initialvalue=profile.account_label if profile else "", parent=self.root)
        if label is None:
            return None
        return name, label.strip()

    def _add_profile(self) -> None:
        values = self._ask_profile("New Claude profile")
        if values is None:
            return
        try:
            self.repository.create(*values)
        except (ValueError, RuntimeError) as error:
            self._show_error(str(error))
        self.refresh()

    def _edit_profile(self, profile: Profile) -> None:
        values = self._ask_profile("Edit Claude profile", profile)
        if values is None:
            return
        try:
            self.repository.update(profile, *values)
        except ValueError as error:
            self._show_error(str(error))
        self.refresh()

    def _duplicate(self, profile: Profile) -> None:
        try:
            self.repository.duplicate(profile)
        except (ValueError, RuntimeError, OSError) as error:
            self._show_error(str(error))
        self.refresh()

    def _launch(self, profile: Profile) -> None:
        try:
            launch(profile, self.repository)
        except RuntimeError as error:
            self._show_error(str(error))
        self.refresh()

    def _stop(self, profile: Profile) -> None:
        try:
            stop(profile, self.repository)
        except RuntimeError as error:
            self._show_error(str(error))
        self.root.after(400, self.refresh)

    def _delete_profile(self, profile: Profile) -> None:
        accepted = self.messagebox.askyesno(
            "Remove profile?",
            f"{profile.name} and its local Claude data will be moved to Claude Profiles/Trash.\n\nThis cannot be undone from the app.",
            icon="warning",
            parent=self.root,
        )
        if not accepted:
            return
        try:
            self.repository.archive(profile)
        except (RuntimeError, OSError) as error:
            self._show_error(str(error))
        self.refresh()

    def _show_error(self, message: str) -> None:
        self.messagebox.showerror(APP_NAME, message, parent=self.root)


if __name__ == "__main__":
    raise SystemExit(main())
