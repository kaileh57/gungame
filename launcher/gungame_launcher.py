#!/usr/bin/env python3
"""gungame launcher -- checks GitHub Releases, installs, updates, launches.

Stdlib only. No pip install, no vendored wheels, nothing to keep in sync. That is
the whole reason this is Python + tkinter rather than Electron or a second Godot
project: the launcher must never be the reason a build cannot be installed, and a
launcher that shares a runtime with the game it installs is a launcher that can
brick itself. PyInstaller turns this file into a single .exe for people who do not
have Python (see build.ps1); it also runs fine straight from source.

The repository is PRIVATE, so every GitHub call here is authenticated with a token
the user supplies. There is no token in this file and there must never be one --
see README.md, "How authentication works".
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import queue
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from tkinter import messagebox, scrolledtext, ttk

APP_NAME = "GunGame Launcher"
REPO = "kaileh57/gungame"
API_ROOT = "https://api.github.com"
API_VERSION = "2022-11-28"
USER_AGENT = "gungame-launcher/1.0"

# Env var checked before the stored token, so CI and power users can inject one
# without touching the config file.
TOKEN_ENV = "GUNGAME_GITHUB_TOKEN"

IS_WINDOWS = sys.platform == "win32"
GAME_EXE = "gungame.exe" if IS_WINDOWS else "gungame.x86_64"
ASSET_KEYWORD = "windows" if IS_WINDOWS else "linux"
CHECKSUM_ASSET = "SHA256SUMS.txt"

CHUNK = 256 * 1024


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


def app_dir() -> Path:
    """Per-user data directory. Never Program Files -- installing must not need
    an elevation prompt, and self-updating into a protected directory is how
    launchers end up asking for admin every launch."""
    if IS_WINDOWS:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return Path(base) / "GunGameLauncher"
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return base / "gungame-launcher"


DATA_DIR = app_dir()
VERSIONS_DIR = DATA_DIR / "versions"
CONFIG_PATH = DATA_DIR / "config.json"
STATE_PATH = DATA_DIR / "state.json"


def read_json(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    tmp.replace(path)
    if not IS_WINDOWS:
        try:
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Token storage
# ---------------------------------------------------------------------------
#
# On Windows the token is sealed with DPAPI (CryptProtectData), which ties the
# ciphertext to the current user account -- another account on the same machine,
# or the file copied elsewhere, cannot unseal it. Elsewhere it is stored in a
# 0600 file, which is what ssh and gh do and is honest about its limits.


def _dpapi(protect: bool, payload: bytes) -> bytes:
    """CryptProtectData / CryptUnprotectData. Both take the same seven arguments
    (pDataIn, descr, entropy, reserved, prompt, flags, pDataOut), so one wrapper
    covers the round trip."""
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    buf = ctypes.create_string_buffer(payload, len(payload))
    blob_in = DATA_BLOB(len(payload), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = DATA_BLOB()

    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    fn.restype = wintypes.BOOL
    ok = fn(ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out))
    if not ok:
        raise OSError(ctypes.get_last_error(), "DPAPI call failed")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def store_token(token: str) -> None:
    cfg = read_json(CONFIG_PATH)
    token = token.strip()
    if not token:
        cfg.pop("token", None)
        cfg.pop("token_dpapi", None)
        write_json(CONFIG_PATH, cfg)
        return
    if IS_WINDOWS:
        try:
            sealed = _dpapi(True, token.encode("utf-8"))
            cfg["token_dpapi"] = base64.b64encode(sealed).decode("ascii")
            cfg.pop("token", None)
            write_json(CONFIG_PATH, cfg)
            return
        except OSError:
            pass  # fall through to plaintext rather than losing the token
    cfg["token"] = token
    cfg.pop("token_dpapi", None)
    write_json(CONFIG_PATH, cfg)


def load_token() -> str:
    env = os.environ.get(TOKEN_ENV, "").strip()
    if env:
        return env
    cfg = read_json(CONFIG_PATH)
    sealed = cfg.get("token_dpapi")
    if sealed and IS_WINDOWS:
        try:
            return _dpapi(False, base64.b64decode(sealed)).decode("utf-8")
        except (OSError, ValueError):
            return ""
    return str(cfg.get("token") or "")


def token_source() -> str:
    if os.environ.get(TOKEN_ENV, "").strip():
        return f"environment ({TOKEN_ENV})"
    cfg = read_json(CONFIG_PATH)
    if cfg.get("token_dpapi"):
        return "config file, DPAPI-sealed"
    if cfg.get("token"):
        return "config file, plaintext"
    return "not set"


# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------


class AuthError(Exception):
    """Token missing, wrong, or lacking access to a private repo."""


class GitHubError(Exception):
    pass


class _StripAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """Release asset downloads 302 from api.github.com to an object store that
    rejects any request carrying an Authorization header (it signs its own URL).
    urllib copies request headers across redirects by default, so the header has
    to be stripped explicitly whenever the host changes -- without this, every
    download fails with a 400 that says nothing useful."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        if urllib.parse.urlsplit(newurl).netloc.lower() != urllib.parse.urlsplit(req.full_url).netloc.lower():
            for name in list(new.headers):
                if name.lower() == "authorization":
                    del new.headers[name]
            new.unredirected_hdrs.pop("Authorization", None)
        return new


_OPENER = urllib.request.build_opener(_StripAuthOnRedirect)


def _open(url: str, token: str, accept: str, timeout: int = 60):
    req = urllib.request.Request(url)
    req.add_header("Accept", accept)
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("X-GitHub-Api-Version", API_VERSION)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        return _OPENER.open(req, timeout=timeout)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", "replace")[:400]
        except Exception:
            pass
        if exc.code in (401, 403):
            if "rate limit" in body.lower():
                raise GitHubError("GitHub rate limit reached. Wait, or set a token.") from exc
            raise AuthError(
                f"GitHub rejected the token (HTTP {exc.code}). "
                "It must be valid and have read access to a private repository."
            ) from exc
        if exc.code == 404:
            raise GitHubError(
                f"HTTP 404 for {url}\n\n"
                f"{REPO} is public, so this is almost certainly 'no release published "
                "yet' rather than a permissions problem. If the repository was made "
                "private again, add a token that can read it."
            ) from exc
        raise GitHubError(f"HTTP {exc.code} from GitHub: {body or exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise GitHubError(f"Network error: {exc.reason}") from exc


@dataclass
class Asset:
    id: int
    name: str
    size: int


@dataclass
class Release:
    tag: str
    name: str
    published: str
    html_url: str
    assets: list


def fetch_latest(token: str) -> Release:
    url = f"{API_ROOT}/repos/{REPO}/releases/latest"
    with _open(url, token, "application/vnd.github+json") as resp:
        data = json.load(resp)
    assets = [Asset(a["id"], a["name"], a.get("size", 0)) for a in data.get("assets", [])]
    return Release(
        tag=data.get("tag_name", "?"),
        name=data.get("name") or data.get("tag_name", "?"),
        published=(data.get("published_at") or "")[:10],
        html_url=data.get("html_url", ""),
        assets=assets,
    )


def check_token(token: str) -> str:
    """Return the login the token belongs to, or raise."""
    with _open(f"{API_ROOT}/user", token, "application/vnd.github+json", timeout=20) as resp:
        return json.load(resp).get("login", "?")


def pick_asset(release: Release) -> Asset:
    zips = [a for a in release.assets if a.name.lower().endswith(".zip")]
    for a in zips:
        if ASSET_KEYWORD in a.name.lower():
            return a
    if len(zips) == 1:
        return zips[0]
    names = ", ".join(a.name for a in release.assets) or "<none>"
    raise GitHubError(
        f"Release {release.tag} has no asset for this platform "
        f"(looking for a .zip whose name contains '{ASSET_KEYWORD}').\nAssets: {names}"
    )


def download_asset(token: str, asset: Asset, dest: Path, progress) -> None:
    """Stream a release asset to disk. Private-repo assets must go through the
    API endpoint with Accept: application/octet-stream; browser_download_url is
    session-authenticated and 404s for a token."""
    url = f"{API_ROOT}/repos/{REPO}/releases/assets/{asset.id}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    done = 0
    started = time.monotonic()
    with _open(url, token, "application/octet-stream", timeout=120) as resp:
        total = int(resp.headers.get("Content-Length") or asset.size or 0)
        with part.open("wb") as fh:
            while True:
                block = resp.read(CHUNK)
                if not block:
                    break
                fh.write(block)
                done += len(block)
                elapsed = max(time.monotonic() - started, 1e-6)
                progress(done, total, done / elapsed)
    if total and done != total:
        part.unlink(missing_ok=True)
        raise GitHubError(f"Download truncated: got {done} of {total} bytes.")
    part.replace(dest)


def fetch_checksums(token: str, release: Release) -> dict:
    """{filename: sha256}. Empty dict if the release has no checksum asset."""
    asset = next((a for a in release.assets if a.name == CHECKSUM_ASSET), None)
    if asset is None:
        return {}
    url = f"{API_ROOT}/repos/{REPO}/releases/assets/{asset.id}"
    with _open(url, token, "application/octet-stream", timeout=60) as resp:
        text = resp.read().decode("utf-8", "replace")
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            out[parts[1].lstrip("*")] = parts[0].lower()
    return out


def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def sha256_file(path: Path, progress=None) -> str:
    h = hashlib.sha256()
    total = path.stat().st_size
    done = 0
    with path.open("rb") as fh:
        while True:
            block = fh.read(CHUNK)
            if not block:
                break
            h.update(block)
            done += len(block)
            if progress:
                progress(done, total)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Install state
# ---------------------------------------------------------------------------


def installed_state() -> dict:
    state = read_json(STATE_PATH)
    exe = state.get("exe")
    if exe and Path(exe).exists():
        return state
    return {}


def install_from_zip(zip_path: Path, tag: str, progress) -> dict:
    """Extract into versions/<tag>, then publish it by writing state.json. The
    old version is only deleted once the new one is live, so a crash mid-install
    leaves the previous build playable."""
    VERSIONS_DIR.mkdir(parents=True, exist_ok=True)
    staging = VERSIONS_DIR / f".staging-{tag}"
    target = VERSIONS_DIR / tag

    if staging.exists():
        shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)

    with zipfile.ZipFile(zip_path) as zf:
        members = zf.infolist()
        total = len(members)
        for i, member in enumerate(members, 1):
            # Refuse absolute paths and ../ escapes rather than trusting the zip.
            name = member.filename.replace("\\", "/")
            if name.startswith("/") or ".." in Path(name).parts:
                raise GitHubError(f"Refusing to extract unsafe path from archive: {member.filename}")
            zf.extract(member, staging)
            progress(i, total)

    exe = next((p for p in staging.rglob(GAME_EXE)), None)
    if exe is None:
        found = ", ".join(sorted({p.name for p in staging.rglob("*") if p.is_file()})[:12])
        shutil.rmtree(staging, ignore_errors=True)
        raise GitHubError(f"Archive contains no {GAME_EXE}. Saw: {found or '<empty>'}")

    if not IS_WINDOWS:
        # zipfile drops the executable bit; without this the game will not start.
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    if target.exists():
        shutil.rmtree(target, ignore_errors=True)
    staging.rename(target)

    state = {
        "tag": tag,
        "exe": str((target / exe.relative_to(staging)).resolve()),
        "installed_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    write_json(STATE_PATH, state)

    for old in VERSIONS_DIR.iterdir():
        if old.is_dir() and old.name != tag:
            shutil.rmtree(old, ignore_errors=True)
    return state


def launch_game(exe: Path) -> None:
    kwargs = {"cwd": str(exe.parent), "close_fds": True}
    if IS_WINDOWS:
        # DETACHED_PROCESS: the game outlives the launcher, and closing the
        # launcher window does not take the game with it.
        kwargs["creationflags"] = 0x00000008 | 0x00000200
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen([str(exe)], **kwargs)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------


class LauncherUI:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.events: "queue.Queue[tuple]" = queue.Queue()
        self.busy = False
        self.latest: Release | None = None
        self.state = installed_state()

        root.title(APP_NAME)
        root.geometry("640x460")
        root.minsize(560, 400)

        pad = {"padx": 12, "pady": 6}
        frame = ttk.Frame(root, padding=12)
        frame.pack(fill="both", expand=True)

        header = ttk.Label(frame, text="gungame", font=("Segoe UI", 20, "bold"))
        header.pack(anchor="w")
        ttk.Label(frame, text=REPO, foreground="#777").pack(anchor="w")

        grid = ttk.Frame(frame)
        grid.pack(fill="x", pady=(14, 4))
        grid.columnconfigure(1, weight=1)

        ttk.Label(grid, text="Installed:").grid(row=0, column=0, sticky="w")
        self.lbl_installed = ttk.Label(grid, text="-")
        self.lbl_installed.grid(row=0, column=1, sticky="w", padx=(8, 0))

        ttk.Label(grid, text="Latest:").grid(row=1, column=0, sticky="w")
        self.lbl_latest = ttk.Label(grid, text="not checked")
        self.lbl_latest.grid(row=1, column=1, sticky="w", padx=(8, 0))

        ttk.Label(grid, text="Token:").grid(row=2, column=0, sticky="w")
        self.lbl_token = ttk.Label(grid, text="-")
        self.lbl_token.grid(row=2, column=1, sticky="w", padx=(8, 0))

        self.progress = ttk.Progressbar(frame, mode="determinate", maximum=1000)
        self.progress.pack(fill="x", pady=(12, 2))
        self.lbl_status = ttk.Label(frame, text="Ready.")
        self.lbl_status.pack(anchor="w")

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(12, 6))
        self.btn_check = ttk.Button(buttons, text="Check for updates", command=self.on_check)
        self.btn_check.pack(side="left")
        self.btn_install = ttk.Button(buttons, text="Install", command=self.on_install, state="disabled")
        self.btn_install.pack(side="left", padx=6)
        self.btn_play = ttk.Button(buttons, text="Play", command=self.on_play, state="disabled")
        self.btn_play.pack(side="left")
        ttk.Button(buttons, text="Token...", command=self.on_token).pack(side="right")
        ttk.Button(buttons, text="Open folder", command=self.on_open_folder).pack(side="right", padx=6)

        self.log_box = scrolledtext.ScrolledText(frame, height=10, wrap="word", state="disabled",
                                                 font=("Consolas", 9))
        self.log_box.pack(fill="both", expand=True, pady=(8, 0))

        self.refresh_labels()
        self.log(f"Data directory: {DATA_DIR}")
        self.root.after(80, self.pump)

        # Always check on startup. The repository is public, so there is nothing to
        # configure before the first install -- which is the whole point of being able
        # to hand this executable to somebody who has never heard of GitHub.
        self.on_check()

    # -- plumbing ---------------------------------------------------------

    def log(self, message: str) -> None:
        self.log_box.configure(state="normal")
        self.log_box.insert("end", message.rstrip() + "\n")
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    def post(self, kind: str, *payload) -> None:
        self.events.put((kind,) + payload)

    def pump(self) -> None:
        try:
            while True:
                kind, *payload = self.events.get_nowait()
                getattr(self, f"_on_{kind}")(*payload)
        except queue.Empty:
            pass
        self.root.after(80, self.pump)

    def run_worker(self, fn, *args) -> None:
        if self.busy:
            return
        self.busy = True
        self.set_buttons(False)

        def wrapper():
            try:
                fn(*args)
            except (AuthError, GitHubError) as exc:
                self.post("error", str(exc))
            except Exception as exc:  # noqa: BLE001 -- surface it, do not vanish
                self.post("error", f"{type(exc).__name__}: {exc}")
            finally:
                self.post("done")

        threading.Thread(target=wrapper, daemon=True).start()

    def set_buttons(self, enabled: bool) -> None:
        state = "normal" if enabled else "disabled"
        self.btn_check.configure(state=state)
        if enabled:
            self.refresh_labels()
        else:
            self.btn_install.configure(state="disabled")
            self.btn_play.configure(state="disabled")

    def refresh_labels(self) -> None:
        self.state = installed_state()
        if self.state:
            self.lbl_installed.configure(text=f"{self.state['tag']}   ({self.state.get('installed_at', '?')})")
            self.btn_play.configure(state="normal" if not self.busy else "disabled")
        else:
            self.lbl_installed.configure(text="nothing installed")
            self.btn_play.configure(state="disabled")

        self.lbl_token.configure(text=token_source())

        if self.latest is None:
            self.btn_install.configure(state="disabled")
            return
        up_to_date = bool(self.state) and self.state.get("tag") == self.latest.tag
        suffix = "  -- up to date" if up_to_date else ""
        self.lbl_latest.configure(text=f"{self.latest.tag}   ({self.latest.published}){suffix}")
        if self.busy:
            self.btn_install.configure(state="disabled")
        else:
            self.btn_install.configure(state="normal")
            self.btn_install.configure(text="Reinstall" if up_to_date else
                                       ("Update" if self.state else "Install"))

    # -- events from workers ---------------------------------------------

    def _on_log(self, message: str) -> None:
        self.log(message)

    def _on_status(self, message: str) -> None:
        self.lbl_status.configure(text=message)

    def _on_progress(self, fraction: float) -> None:
        self.progress.configure(value=max(0.0, min(1.0, fraction)) * 1000)

    def _on_latest(self, release: Release) -> None:
        self.latest = release
        self.refresh_labels()

    def _on_error(self, message: str) -> None:
        self.log("ERROR: " + message)
        self.lbl_status.configure(text="Failed. See log.")
        messagebox.showerror(APP_NAME, message)

    def _on_done(self) -> None:
        self.busy = False
        self.set_buttons(True)
        self.refresh_labels()

    # -- button handlers --------------------------------------------------

    def on_check(self) -> None:
        self.run_worker(self.work_check)

    def on_install(self) -> None:
        if self.latest is None:
            return
        self.run_worker(self.work_install, self.latest)

    def on_play(self) -> None:
        state = installed_state()
        if not state:
            messagebox.showinfo(APP_NAME, "Nothing is installed yet.")
            return
        try:
            launch_game(Path(state["exe"]))
            self.log(f"Launched {state['exe']}")
            self.lbl_status.configure(text=f"Running {state['tag']}.")
        except OSError as exc:
            self._on_error(f"Could not launch the game: {exc}")

    def on_open_folder(self) -> None:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        target = str(DATA_DIR)
        try:
            if IS_WINDOWS:
                os.startfile(target)  # noqa: S606
            elif sys.platform == "darwin":
                subprocess.Popen(["open", target])
            else:
                subprocess.Popen(["xdg-open", target])
        except OSError as exc:
            self._on_error(f"Could not open {target}: {exc}")

    def on_token(self) -> None:
        TokenDialog(self.root, self)

    # -- worker bodies (run off the UI thread; talk back only via post()) --

    def work_check(self) -> None:
        # NO TOKEN REQUIRED. The repository is public, so releases and their assets read
        # anonymously and whoever you handed this to needs no GitHub account at all. A
        # configured token is still used when present, purely to lift the 60-request-an-
        # hour anonymous rate limit.
        token = load_token()
        self.post("status", "Checking GitHub for the latest release...")
        release = fetch_latest(token)
        self.post("latest", release)
        self.post("log", f"Latest release: {release.tag} ({release.published})")
        for a in release.assets:
            self.post("log", f"  asset: {a.name}  {_human(a.size)}")
        self.post("status", "Up to date." if installed_state().get("tag") == release.tag
                  else f"{release.tag} is available.")

    def work_install(self, release: Release) -> None:
        token = load_token()
        asset = pick_asset(release)
        self.post("log", f"Downloading {asset.name} ({_human(asset.size)})")

        with tempfile.TemporaryDirectory(prefix="gungame-dl-") as tmp:
            zip_path = Path(tmp) / asset.name
            last = [0.0]

            def on_bytes(done, total, rate):
                now = time.monotonic()
                if now - last[0] < 0.1 and done != total:
                    return
                last[0] = now
                self.post("progress", done / total if total else 0.0)
                self.post("status",
                          f"Downloading  {_human(done)} / {_human(total)}  ({_human(rate)}/s)")

            download_asset(token, asset, zip_path, on_bytes)
            self.post("progress", 1.0)

            sums = fetch_checksums(token, release)
            expected = sums.get(asset.name)
            if expected:
                self.post("status", "Verifying checksum...")
                actual = sha256_file(zip_path, lambda d, t: self.post("progress", d / t if t else 0))
                if actual != expected:
                    raise GitHubError(
                        f"Checksum mismatch for {asset.name}.\n"
                        f"expected {expected}\nactual   {actual}\n"
                        "The download is corrupt, or the release was tampered with."
                    )
                self.post("log", f"sha256 verified: {actual[:16]}...")
            else:
                self.post("log", f"No {CHECKSUM_ASSET} in this release; "
                                 "skipping checksum verification.")

            self.post("status", "Installing...")
            state = install_from_zip(zip_path, release.tag,
                                     lambda i, n: self.post("progress", i / n if n else 0))

        self.post("log", f"Installed {state['tag']} to {Path(state['exe']).parent}")
        self.post("status", f"{state['tag']} installed. Press Play.")
        self.post("progress", 1.0)


class TokenDialog(tk.Toplevel):
    def __init__(self, parent: tk.Tk, ui: LauncherUI) -> None:
        super().__init__(parent)
        self.ui = ui
        self.title("GitHub token")
        self.transient(parent)
        self.resizable(False, False)
        self.grab_set()

        frame = ttk.Frame(self, padding=14)
        frame.pack(fill="both", expand=True)

        blurb = (
            f"{REPO} is public, so you do NOT need a token to install or\n"
            "play. Leave this blank unless you are told to set one.\n\n"
            "GitHub allows 60 anonymous API requests an hour per address;\n"
            "a token raises that to 5,000. Only worth setting if you check\n"
            "for updates constantly, or share an address with a lot of\n"
            "other traffic.\n\n"
            "A fine-grained token with  Repository -> Contents: Read-only\n"
            "is more than enough.\n\n"
            + ("The token is sealed with Windows DPAPI and can only be read back\n"
               "by your Windows account on this machine."
               if IS_WINDOWS else
               "The token is stored in a 0600 file in your home directory.")
        )
        ttk.Label(frame, text=blurb, justify="left").pack(anchor="w")

        ttk.Label(frame, text="Token:").pack(anchor="w", pady=(12, 2))
        self.entry = ttk.Entry(frame, width=56, show="*")
        self.entry.pack(fill="x")
        self.entry.insert(0, load_token())
        self.entry.focus_set()

        self.status = ttk.Label(frame, text="", foreground="#777")
        self.status.pack(anchor="w", pady=(8, 0))

        row = ttk.Frame(frame)
        row.pack(fill="x", pady=(12, 0))
        ttk.Button(row, text="Verify and save", command=self.save).pack(side="right")
        ttk.Button(row, text="Cancel", command=self.destroy).pack(side="right", padx=6)
        ttk.Button(row, text="Clear", command=self.clear).pack(side="left")

        self.bind("<Return>", lambda _e: self.save())
        self.bind("<Escape>", lambda _e: self.destroy())

    def clear(self) -> None:
        store_token("")
        self.ui.log("Token cleared.")
        self.ui.refresh_labels()
        self.destroy()

    def save(self) -> None:
        token = self.entry.get().strip()
        if not token:
            self.status.configure(text="Enter a token, or press Clear.")
            return
        self.status.configure(text="Verifying...")
        self.update_idletasks()
        try:
            login = check_token(token)
        except (AuthError, GitHubError) as exc:
            self.status.configure(text=str(exc).splitlines()[0], foreground="#b00")
            return
        store_token(token)
        self.ui.log(f"Token saved. Authenticated as {login}.")
        self.ui.refresh_labels()
        self.destroy()
        self.ui.on_check()




# ---------------------------------------------------------------------------


def main() -> int:
    if sys.version_info < (3, 8):
        print("Python 3.8 or newer is required.", file=sys.stderr)
        return 1
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista" if IS_WINDOWS else "clam")
    except tk.TclError:
        pass
    LauncherUI(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
