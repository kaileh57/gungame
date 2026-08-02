# Release pipeline

`release.yml` builds gungame and publishes a GitHub Release on every push to
`main`, and on demand via **Actions → Release → Run workflow**.

`scripts/release.ps1` does the same thing on your own machine and produces
byte-for-byte the same asset layout, so a hand-cut release and a CI-cut release
are interchangeable as far as the launcher is concerned. Use it if Actions is off,
if you are offline, or to test a build before pushing.

---

## Versioning

```
v<YYYY.MM.DD>-<short sha>          e.g.  v2026.08.01-853adf4
```

Date first so releases sort chronologically in every UI that sorts by name. Sha
last so two pushes on the same day cannot collide, and so any release traces back
to an exact commit with `git show 853adf4`. Nothing to bump by hand, nothing to
forget. If you later want marketing versions, add a *second*, manually-tagged
workflow rather than making this one guess.

Re-running the workflow for a commit that already has a release replaces that
release's assets instead of failing on the existing tag.

## Assets

| Asset | Contents |
|---|---|
| `gungame-windows-x86_64-<tag>.zip` | `gungame.exe` with the PCK embedded, plus whatever the Windows exporter puts beside it (the D3D12 Agility SDK, since this project renders through D3D12 on Windows) |
| `gungame-linux-x86_64-<tag>.zip` | `gungame.x86_64`, PCK embedded |
| `SHA256SUMS.txt` | `sha256sum` format; the launcher verifies against it |

---

## What the workflow actually does

1. **Checkout.**
2. **apt-get** the X11/GL/ALSA libraries. The official Linux *editor* build links
   them at load time even when it is going to run `--headless`, so without them
   the binary will not start at all.
3. **Download Godot 4.7.1 + export templates** from `godotengine/godot-builds`
   (~76 MB + ~1.3 GB), rather than pulling `barichello/godot-ci:4.7.1` (~2.6 GB).
   Smaller, and it pins the exact engine build instead of trusting an image tag.
   The whole `.tpz` is extracted rather than cherry-picked, because the Windows
   D3D12 files are loose and their names are an engine implementation detail.
4. **Strip `[editor_plugins]` from `project.godot` in the CI checkout.**
   `godot_mcp` opens a TCP bridge and `gut` installs editor UI; neither is part of
   the shipped game, and both get instantiated by the headless editor during
   `--import`, where a plugin that blocks or errors takes the build with it. This
   edits the throwaway checkout only — the committed file is untouched.
5. **`--headless --import`, twice.** A fresh clone has no `.godot/` (it is
   gitignored), so every mesh, texture and scene has to be imported before
   anything can be exported. Twice because resources depending on a generated
   `.import` file resolve on the second sweep.
6. **Export both presets.** Godot returns a non-zero exit code for benign export
   warnings, so the step checks that the binary exists and is non-empty rather
   than trusting `$?`.
7. **Zip, checksum, publish** with `gh release create`.

There is deliberately **no `upload-artifact` step**. Release assets are free
storage; workflow artifacts are billed per GB-day on private repositories, so
uploading both would roughly double the cost of a run in order to keep a second
copy of something published two steps later.

---

## Cost — this repository is PRIVATE

Public repos get Actions for free. Private repos do not: minutes come out of the
account's monthly allowance and are billed once that runs out.

- Standard `ubuntu-latest` (2-core Linux) bills at **1x**, about **$0.008 per
  minute** beyond the included allowance.
- Included minutes per month: **2,000** on Free, **3,000** on Pro/Team.
  (Windows runners bill at **2x** and macOS at **10x** — one more reason this
  cross-exports Windows from Linux instead of using a Windows runner.)

A run of this workflow should land around **10–20 minutes**, dominated by the
asset import. Call it:

| | |
|---|---|
| Per push to `main` | **~10–20 min ≈ $0.08–$0.16** |
| Against a 2,000-min allowance | **~100–200 builds/month before anything is billed** |
| A busy day, 10 pushes | ~2–3 hours of the allowance |

**Decide before you turn it on**, because it fires on *every* push to `main`:

- If that is more releases than you want, change the trigger to
  `on: workflow_dispatch` only, or to `on: push: tags: ['v*']`, and cut releases
  deliberately. One line, at the top of `release.yml`.
- If the builds do not need to be private, **making the repository public makes
  all of this free** and simplifies the launcher at the same time (see
  `launcher/README.md`). That is a visibility decision, not a technical one, so
  it has been left alone.
- `scripts/release.ps1` costs nothing but your own CPU and is a complete
  substitute.

---

## What could break it on the first run

Honest list, roughly by likelihood:

1. **The import step.** This is the least predictable part of any Godot CI job.
   Projects that import cleanly in the editor can still emit errors headlessly,
   and a project with 77 MB of baked data has plenty of surface. If an export
   produces no binary, the failure is almost always here — read the `--import`
   log, not the export log.
2. **Runner-image drift in the apt list.** `libasound2` was renamed
   `libasound2t64` in Ubuntu 24.04; the step tries both, but a future rename
   would need the same treatment.
3. **An export option this project needs that the sparse `export_presets.cfg`
   leaves at its default.** The preset only overrides what it must; if the
   Windows build comes out wrong (missing D3D12 files, wrong texture format), the
   fix is to add the specific key rather than to regenerate the whole file.
4. **`godot-builds` asset naming.** The URLs are constructed from
   `GODOT_VERSION`/`GODOT_RELEASE`. Bumping to a version whose assets are named
   differently breaks the download step loudly and immediately.
5. **Release size.** GitHub's per-asset limit is 2 GB. With the PCK embedded,
   each zip should be a few hundred MB, but that is a ceiling worth knowing about.

None of this has been executed — see the delivery notes. The workflow's YAML and
the shell inside it have been parsed and checked; the build itself has never run.

## Bumping the engine version

Edit `env.GODOT_VERSION` / `env.GODOT_RELEASE` at the top of `release.yml`, and
`config/features` in `project.godot`. Nothing else references the version.
