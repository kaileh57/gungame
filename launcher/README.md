# gungame launcher

A small desktop app that talks to the GitHub Releases API for
`kaileh57/gungame`, shows you what is installed against what is published,
downloads and installs the newest build, and starts the game.

```
launcher/
  gungame_launcher.py   the whole app, one file, standard library only
  build.ps1             freezes it into a single GunGameLauncher.exe
  README.md             this
```

---

## Why Python + tkinter

Three things had to be true, and this is the only stack where all three were:

- **Nothing for the end user to install.** PyInstaller turns the single source
  file into one `.exe` with the interpreter and tkinter baked in. Double-click,
  done. No .NET, no Node, no VC++ redistributable, no Python.
- **Nothing for the developer to maintain.** The app imports only the standard
  library — `urllib`, `json`, `zipfile`, `hashlib`, `tkinter`, `ctypes`. There is
  no lockfile to refresh, no transitive dependency to audit, no supply chain.
- **No shared fate with the game.** A launcher written as a second Godot project
  would ship the same engine build it is responsible for replacing, and would
  need export templates and a second CI export just to exist. If the engine
  version it was built against goes bad, the thing that repairs your install goes
  bad with it. Keeping the launcher on a different runtime entirely means a
  broken game build is always still fixable.

Electron and Tauri were the other obvious candidates and both lose on the second
point: a 200 MB toolchain and a dependency tree to babysit, for a window with
four buttons.

---

## Running it

**From source** (any machine with Python 3.8+ that has tkinter, which the
official python.org installers do by default):

```powershell
python launcher/gungame_launcher.py
```

**As a frozen exe** — build it once:

```powershell
pwsh -File launcher/build.ps1
# -> launcher/dist/GunGameLauncher.exe
```

`build.ps1` makes a throwaway virtualenv at `launcher/.venv-build`, installs
PyInstaller into it, and freezes the app. Pass `-Clean` to start over, or
`-Python <path>` to build with a specific interpreter (the exe inherits that
interpreter's architecture — use a 64-bit one).

The exe is **unsigned**, so Windows SmartScreen will show a "protected your PC"
warning the first few times it runs, until it has enough reputation. Signing it
needs a code-signing certificate; that is a purchase, not a code change.

---

## How authentication works

**`kaileh57/gungame` is a private repository, so every request the launcher
makes is authenticated with a token you supply.** There is no token in this
source and there must never be one. A token committed to a repository is a token
that has been leaked, and embedding one in a distributed binary is worse — it is
trivially recoverable with `strings`, and it would hand every player whatever
access that token has.

### What the user does

Click **Token…** in the launcher and paste a GitHub personal access token. The
launcher verifies it against `GET /user` before saving, and tells you which
account it belongs to.

The token that is *right* for this job is a **fine-grained** personal access
token with exactly one permission:

> GitHub → Settings → Developer settings → Personal access tokens →
> Fine-grained tokens → Generate new token
> - Repository access: **Only select repositories** → `kaileh57/gungame`
> - Permissions → Repository permissions → **Contents: Read-only**

That is the minimum that can list releases and download assets, and it can do
nothing else — not read code from other repos, not write, not touch settings.
A classic token with the `repo` scope also works, but `repo` is read *and write*
across *every* repository the account can see, which is a wildly larger blast
radius than downloading a zip warrants.

### Where the token is kept

| | |
|---|---|
| Env var `GUNGAME_GITHUB_TOKEN` | Checked first. Nothing is written to disk. |
| `%LOCALAPPDATA%\GunGameLauncher\config.json` | Windows. Sealed with **DPAPI** (`CryptProtectData`), so the ciphertext only decrypts under your Windows account on this machine. Copying the file to another machine or account yields nothing. |
| `~/.local/share/gungame-launcher/config.json` | Linux/macOS. Mode `0600`. Plaintext — this is what `gh` and `ssh` do, and it is worth being plain about the limit: anything running as you can read it. |

### The two API details that actually matter

1. **Release metadata** comes from
   `GET https://api.github.com/repos/kaileh57/gungame/releases/latest` with an
   `Authorization: Bearer <token>` header. For a private repo, a missing or
   under-scoped token returns **404, not 403** — GitHub refuses to confirm the
   repo exists. The launcher says so in its error message, because otherwise
   "404" reads as "the release is gone" when it means "your token cannot see it".

2. **Asset downloads must go through the API**, not `browser_download_url`.
   That URL is session-authenticated and will 404 for a token. The working
   endpoint is
   `GET /repos/{owner}/{repo}/releases/assets/{asset_id}` with
   `Accept: application/octet-stream`, which 302s to a signed object-store URL —
   and that URL **rejects any request still carrying an `Authorization` header**.
   `urllib` copies headers across redirects by default, so the launcher installs
   a redirect handler that strips `Authorization` whenever the host changes.
   Without it every download fails with an opaque 400. This is the single most
   common way a private-repo downloader gets written wrong.

### Recommendation

If these builds are not secret, **making the repository public would delete this
entire section.** Anonymous downloads, no token, no token storage, no DPAPI, no
support conversations that begin "it says 404". The launcher already works
against a public repo with no changes — `load_token()` simply returns `""` and
the requests go out unauthenticated. It would also make Actions minutes free
(see `.github/workflows/README.md`).

That is a call about whether the source should be visible, not a technical one,
so it has been left alone. If the source needs to stay private but the *builds*
do not, a second public repo holding only releases is the usual split.

---

## What it does on disk

Everything lives under one per-user directory — never Program Files, so
installing never needs an elevation prompt:

```
%LOCALAPPDATA%\GunGameLauncher\        (Windows)
~/.local/share/gungame-launcher/       (Linux/macOS)
  config.json          token
  state.json           {tag, exe, installed_at}
  versions/
    v2026.08.01-853adf4/    the unpacked game
```

Install order is deliberate: extract to `versions/.staging-<tag>`, rename into
place, *then* write `state.json`, *then* delete the old version. A crash at any
point leaves the previous build installed and playable rather than a half-written
directory.

Downloads are verified against the `SHA256SUMS.txt` asset when the release has
one (both the CI workflow and `scripts/release.ps1` publish it). Archive entries
with absolute paths or `..` components are refused rather than extracted.

---

## Known limits

- **No delta updates.** Every update re-downloads the whole zip. For a game this
  size that is a few hundred MB; a patcher is a much larger piece of software and
  is not worth it until the update cadence makes it hurt.
- **No resume.** An interrupted download starts over.
- **The "Play" button does not know if the game is already running.** It will
  happily start a second copy.
- **`releases/latest` skips prereleases**, so a release published with
  `--prerelease` is invisible to the launcher by design.
- **The frozen exe is unsigned** (see above).
