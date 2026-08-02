<#
.SYNOPSIS
    Builds gungame locally and publishes a GitHub Release.

.DESCRIPTION
    The offline twin of .github/workflows/release.yml. Same tag scheme, same
    asset names, same checksum file, so a release cut by hand is indistinguishable
    from one cut by CI and the launcher cannot tell the difference.

    Steps: safety checks -> import -> export -> package -> publish.

    MACHINE SAFETY
    Godot is run --headless and one process at a time, and the script refuses to
    start if another Godot process is already alive. Exporting is CPU-heavy but
    single-process; do not run two of these at once.

.PARAMETER Godot
    Path to the Godot 4.7.1 editor binary. Defaults to the Steam install.

.PARAMETER Platforms
    Which presets to export. Default: Windows only. "Windows","Linux" for both.

.PARAMETER NoPublish
    Build and package, but do not touch GitHub. Artifacts land in dist/.

.PARAMETER Prerelease
    Mark the created release as a prerelease.

.PARAMETER Force
    Skip the "another Godot is running" guard. You are on your own.

.EXAMPLE
    pwsh -File scripts/release.ps1 -NoPublish
    Build a Windows zip into dist/ and stop.

.EXAMPLE
    pwsh -File scripts/release.ps1 -Platforms Windows,Linux
    Build both and publish a release.
#>

[CmdletBinding()]
param(
    [string]   $Godot = "C:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe",
    [ValidateSet("Windows", "Linux")]
    [string[]] $Platforms = @("Windows"),
    [switch]   $NoPublish,
    [switch]   $Prerelease,
    [switch]   $Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Repo root is the parent of scripts/.
$Root = Split-Path -Parent $PSScriptRoot
$Repo = "kaileh57/gungame"

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Fail      { param([string]$Message) Write-Host "`nFAILED: $Message" -ForegroundColor Red; exit 1 }

# Run the engine and ACTUALLY WAIT FOR IT.
#
# Two separate Windows problems, both of which made a successful build look broken.
#
# 1. IT DOES NOT WAIT. Godot ships one Windows binary and it is built for the GUI
#    subsystem, so when it is started from a console it relaunches itself attached to
#    one and the process you started exits immediately. `& $Godot ...` therefore
#    returned while the export had not written a single byte, the very next line
#    tested for the .exe, found nothing, and failed the build -- and then Godot went
#    on to finish the export perfectly and drop a 336 MB binary on disk after the
#    script had already given up. There is no `.console.exe` in the Steam install to
#    use instead, so the wait is done by hand: start it, wait on that process, then
#    wait for the whole engine to be gone. The preflight refuses to run at all while
#    another Godot is alive, so anything still running here is ours.
#
# 2. ITS CHATTER IS FATAL. Godot writes to stderr on every run -- "N ObjectDB
#    instances were leaked at exit", "N resources still in use at exit" -- and none of
#    it means the run failed. Windows PowerShell 5.1 wraps a native command's stderr
#    in an ErrorRecord, which under $ErrorActionPreference = "Stop" terminates the
#    script. The preference is relaxed for exactly the duration of the engine call.
#
# Callers still gate on whether a binary actually appeared, which is the real signal.
function Invoke-Godot {
    param([string[]]$GodotArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # QUOTE ANYTHING WITH A SPACE. Start-Process joins -ArgumentList with spaces and
        # quotes nothing, so the preset name "Windows Desktop" arrived as two separate
        # arguments: Godot could not match a preset, printed the list of the ones it has,
        # and exported nothing. The exe path is quoted for the same reason -- it does not
        # contain a space today, but a checkout under "Program Files" would.
        $quoted = $GodotArgs | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }
        $proc = Start-Process -FilePath $Godot -ArgumentList $quoted -NoNewWindow -Wait -PassThru
        $engine = [System.IO.Path]::GetFileNameWithoutExtension($Godot)
        while (@(Get-Process -Name $engine -ErrorAction SilentlyContinue).Count -gt 0) {
            Start-Sleep -Milliseconds 500
        }
        $script:GodotExit = $proc.ExitCode
    }
    finally { $ErrorActionPreference = $prev }
}

# --------------------------------------------------------------------------
# 1. Preflight
# --------------------------------------------------------------------------

Write-Step "Preflight"

if (-not (Test-Path $Godot)) {
    Fail "Godot not found at '$Godot'. Pass -Godot <path to the editor binary>."
}
if (-not (Test-Path (Join-Path $Root "project.godot"))) {
    Fail "No project.godot under '$Root'. This script must live in <repo>/scripts/."
}
if (-not (Test-Path (Join-Path $Root "export_presets.cfg"))) {
    Fail "No export_presets.cfg. Nothing to export."
}

# One Godot at a time. A second concurrent instance has hard-crashed this machine.
$running = @(Get-Process -Name "godot*" -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -notlike "godot-mcp*" })
if ($running.Count -gt 0 -and -not $Force) {
    $names = ($running | ForEach-Object { "$($_.ProcessName) (pid $($_.Id))" }) -join ", "
    Fail @"
A Godot process is already running: $names
Exporting would put a second engine on the CPU at the same time. Close it and
re-run, or pass -Force if you are certain that process is idle.
"@
}

$versionLine = (& $Godot --headless --version 2>&1 | Select-Object -Last 1).ToString().Trim()
Write-Note "Godot reports: $versionLine"
if ($versionLine -notmatch '^4\.7\.') {
    Write-Host "    WARNING: expected Godot 4.7.x, got '$versionLine'. Templates must match exactly." -ForegroundColor Yellow
}

# Export templates live in <editor data>\export_templates\<VERSION_FULL_CONFIG>.
# For an official stable build that is "<major>.<minor>.<patch>.stable"; the
# trailing build name a Steam or distro build appends is not part of the folder.
#
# WHERE "<editor data>" IS DEPENDS ON THE INSTALL, and this checked only one of the
# two. A Godot that finds a `._sc_` file beside its binary is SELF-CONTAINED: it
# keeps everything in `editor_data/` next to the executable and never reads
# %APPDATA% at all, which is exactly what the Steam build does. So this failed with
# "templates are not installed" and a 1.3 GB download instruction on a machine that
# had them installed and could export fine — the templates were simply in the other
# directory. Both roots are searched now, self-contained first, because when the
# marker is present that is the only one the engine itself will look in.
$tplName = ($versionLine -split '\.' | Select-Object -First 3) -join '.'
$tplName = "$tplName.stable"

$tplRoots = @()
$godotDir = Split-Path -Parent (Resolve-Path $Godot)
if (Test-Path (Join-Path $godotDir "._sc_")) {
    $tplRoots += (Join-Path $godotDir "editor_data/export_templates")
}
$tplRoots += (Join-Path $env:APPDATA "Godot/export_templates")

# NOT `foreach ($root in ...)`. PowerShell variable names are CASE-INSENSITIVE, so
# `$root` and `$Root` are one variable, and that loop quietly overwrote the repo root
# with a templates directory. Everything downstream then ran `git` from inside the
# Godot install and reported "not a git repository", which reads as a broken checkout.
$tplRoot = $tplRoots[0]
$tplDir  = $null
foreach ($tplCandidateRoot in $tplRoots) {
    $candidate = Join-Path $tplCandidateRoot $tplName
    if (Test-Path $candidate) { $tplRoot = $tplCandidateRoot; $tplDir = $candidate; break }
}

if (-not $tplDir) {
    $tplDir = Join-Path $tplRoot $tplName
    $have = if (Test-Path $tplRoot) { (Get-ChildItem $tplRoot -Directory | ForEach-Object Name) -join ", " } else { "<none>" }
    Fail @"
Export templates for '$tplName' are not installed.
  Looked in: $tplDir
  Installed: $have

Templates are a ~1.3 GB download. Install them one of these ways:
  * In the Godot editor: Editor > Manage Export Templates > Download and Install
  * By hand: download
      https://github.com/godotengine/godot-builds/releases/download/$tplName/Godot_v$tplName`_export_templates.tpz
    (it is a zip), and extract the contents of its templates/ folder into
      $tplDir

Searched: $($tplRoots -join "; ")
"@
}
Write-Note "Templates: $tplDir"

foreach ($tool in @("git", "gh")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        if ($tool -eq "gh" -and $NoPublish) { continue }
        Fail "'$tool' is not on PATH."
    }
}

# CHECK WHO gh IS BEFORE SPENDING TEN MINUTES ON A BUILD.
#
# `gh` can hold several accounts at once and publishes as whichever is ACTIVE, which is
# not necessarily the one that owns this repo -- switch to a work account for an
# afternoon and the next release exports fine, packages fine, and then dies on the
# upload with a 404 that reads like the release is missing rather than like the wrong
# person is asking. One API call up front turns that into an instant, actionable stop.
if (-not $NoPublish) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $who  = (& gh api user --jq .login 2>$null)
    $perm = (& gh api "repos/$Repo" --jq .permissions.push 2>$null)
    $ErrorActionPreference = $prevEap
    if (-not $who) {
        Fail "gh is not logged in. Run: gh auth login   (or set GH_TOKEN)"
    }
    if ("$perm" -ne "true") {
        $owner = $Repo.Split("/")[0]
        Fail @"
gh is signed in as '$who', which cannot publish to $Repo.

Switch to the account that owns it and re-run:
  gh auth switch --user $owner

Or publish as a one-off without changing your active account:
  `$env:GH_TOKEN = "<token with repo scope on $Repo>"

Or build without publishing:
  pwsh -File scripts/release.ps1 -NoPublish
"@
    }
    Write-Note "gh: $who (can publish to $Repo)"
}

Push-Location $Root
try {
    $sha = (& git rev-parse --short=7 HEAD).Trim()
    # The FULL sha as well, for --target. GitHub's release API rejects an abbreviated
    # commitish with "Release.target_commitish is invalid" -- it takes a branch name or
    # a complete 40-character sha and nothing in between. The short one still names the
    # tag, which is where a human reads it.
    $shaFull = (& git rev-parse HEAD).Trim()
    $tag = "v{0}-{1}" -f (Get-Date).ToUniversalTime().ToString("yyyy.MM.dd"), $sha
    $dirty = (& git status --porcelain) -ne $null

    Write-Note "Commit: $sha"
    Write-Note "Tag:    $tag"
    if ($dirty) {
        Write-Host "    WARNING: working tree is dirty. The build will include uncommitted changes," -ForegroundColor Yellow
        Write-Host "             but the tag will point at $sha, which does not contain them." -ForegroundColor Yellow
    }

    # ----------------------------------------------------------------------
    # 2. Import
    # ----------------------------------------------------------------------

    Write-Step "Importing resources"
    Write-Note "Skipped if .godot/imported already exists; delete it to force a clean import."
    if (-not (Test-Path (Join-Path $Root ".godot/imported"))) {
        # Exit code is not a reliable signal -- Godot returns non-zero for import
        # warnings. The export step is the real gate.
        Invoke-Godot @("--headless", "--import", "--path", $Root)
        Invoke-Godot @("--headless", "--import", "--path", $Root)
    }

    # ----------------------------------------------------------------------
    # 3. Export
    # ----------------------------------------------------------------------

    $presets = @{
        Windows = @{ Preset = "Windows Desktop"; OutDir = "build/windows"; OutFile = "gungame.exe";      Slug = "windows-x86_64" }
        Linux   = @{ Preset = "Linux";           OutDir = "build/linux";   OutFile = "gungame.x86_64";   Slug = "linux-x86_64"   }
    }

    $built = @()
    foreach ($platform in $Platforms) {
        $p       = $presets[$platform]
        $outDir  = Join-Path $Root $p.OutDir
        $outPath = Join-Path $outDir $p.OutFile

        Write-Step "Exporting $($p.Preset)"
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null

        Invoke-Godot @("--headless", "--path", $Root, "--export-release", $p.Preset, $outPath)

        if (-not (Test-Path $outPath) -or (Get-Item $outPath).Length -eq 0) {
            Fail "Export of '$($p.Preset)' produced no binary at $outPath. Scroll up for Godot's error."
        }
        $mb = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
        Write-Note "$($p.OutFile) -- $mb MB"
        $built += @{ Platform = $platform; Dir = $outDir; Slug = $p.Slug }
    }

    # ----------------------------------------------------------------------
    # 4. Package
    # ----------------------------------------------------------------------

    Write-Step "Packaging"
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $dist = Join-Path $Root "dist"
    if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dist | Out-Null

    $zips = @()
    foreach ($b in $built) {
        # Zip the directory, not the file: the Windows export drops the D3D12
        # Agility SDK DLLs beside the exe and they have to keep their layout.
        $zipName = "gungame-$($b.Slug)-$tag.zip"
        $zipPath = Join-Path $dist $zipName
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $b.Dir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $mb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-Note "$zipName -- $mb MB"
        $zips += $zipPath
    }

    # Same format `sha256sum` writes, so CI and local output are interchangeable.
    $sumFile = Join-Path $dist "SHA256SUMS.txt"
    $lines = foreach ($z in $zips) {
        "{0}  {1}" -f (Get-FileHash $z -Algorithm SHA256).Hash.ToLower(), (Split-Path $z -Leaf)
    }
    [System.IO.File]::WriteAllText($sumFile, ($lines -join "`n") + "`n")
    $zips += $sumFile
    Write-Note "SHA256SUMS.txt"

    # ----------------------------------------------------------------------
    # 5. Publish
    # ----------------------------------------------------------------------

    if ($NoPublish) {
        Write-Step "Done (not published)"
        Write-Host "Artifacts in $dist" -ForegroundColor Green
        Write-Host "To publish these later:" -ForegroundColor DarkGray
        Write-Host "  gh release create $tag $dist/* --repo $Repo --title ""gungame $tag"" --target $shaFull" -ForegroundColor DarkGray
        exit 0
    }

    Write-Step "Publishing $tag to $Repo"

    $notesFile = Join-Path $env:TEMP "gungame-release-notes-$tag.md"
    $subject = (& git log -1 --pretty=format:"%s")
    $body = @"
Local build of ``$sha`` on ``$(& git rev-parse --abbrev-ref HEAD)``.

| Platform | Asset |
| --- | --- |
$(($built | ForEach-Object { "| $($_.Platform) x86_64 | ``gungame-$($_.Slug)-$tag.zip`` |" }) -join "`n")

Built with Godot $versionLine. Checksums in ``SHA256SUMS.txt``.

### Commit

$subject
"@
    [System.IO.File]::WriteAllText($notesFile, $body)

    # Windows PowerShell 5.1 turns a native command's redirected stderr into an
    # ErrorRecord, which $ErrorActionPreference='Stop' would then throw on -- even
    # though a missing release is the expected, non-exceptional answer here.
    # Relax the preference for exactly this probe.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & gh release view $tag --repo $Repo 2>&1 | Out-Null
    $exists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap

    if ($exists) {
        Write-Note "Release $tag already exists -- replacing its assets."
        & gh release upload $tag @zips --repo $Repo --clobber
        if ($LASTEXITCODE -ne 0) { Fail "gh release upload failed." }
        & gh release edit $tag --repo $Repo --notes-file $notesFile
        if ($LASTEXITCODE -ne 0) { Fail "gh release edit failed." }
    }
    else {
        $ghArgs = @("release", "create", $tag) + $zips + @(
            "--repo", $Repo,
            "--title", "gungame $tag",
            "--notes-file", $notesFile,
            "--target", $shaFull
        )
        if ($Prerelease) { $ghArgs += "--prerelease" }
        & gh @ghArgs
        if ($LASTEXITCODE -ne 0) { Fail "gh release create failed." }
    }

    Remove-Item $notesFile -Force -ErrorAction SilentlyContinue

    Write-Step "Released"
    Write-Host "https://github.com/$Repo/releases/tag/$tag" -ForegroundColor Green
}
finally {
    Pop-Location
}
