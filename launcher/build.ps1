<#
.SYNOPSIS
    Freezes gungame_launcher.py into a single self-contained GunGameLauncher.exe.

.DESCRIPTION
    The launcher runs fine from source, but the people you hand a game to do not
    have Python. PyInstaller bundles the interpreter and tkinter into one file
    they can double-click.

    PyInstaller is installed into a throwaway virtualenv under launcher/.venv-build
    so nothing lands in the system site-packages.

.PARAMETER Python
    Interpreter to build with. Defaults to whatever `py -3` resolves to, falling
    back to `python`. The exe is built for the architecture of this interpreter,
    so use a 64-bit Python.

.PARAMETER Clean
    Delete the build venv and intermediates first.

.EXAMPLE
    pwsh -File launcher/build.ps1
#>

[CmdletBinding()]
param(
    [string] $Python,
    # Folder holding upx.exe. Optional: without it the build still succeeds, it is just
    # ~1.3 MB bigger, which is the difference between fitting in a Discord attachment
    # and not. Grab it from https://github.com/upx/upx/releases and unzip anywhere.
    [string] $UpxDir,
    [switch] $Clean
)

$ErrorActionPreference = "Stop"

# Stdlib packages the launcher provably never imports. `email` is deliberately absent
# from this list -- urllib.request needs it to parse response headers.
$ExcludeModules = @(
    "unittest", "pydoc", "doctest", "pdb", "difflib", "lib2to3", "distutils",
    "setuptools", "pip", "sqlite3", "multiprocessing", "asyncio", "xml", "xmlrpc",
    "test", "tkinter.test", "curses", "decimal", "bz2", "lzma", "ftplib",
    "argparse", "pickletools", "tarfile"
)
Set-StrictMode -Version Latest

$Here   = $PSScriptRoot
$Venv   = Join-Path $Here ".venv-build"
$Entry  = Join-Path $Here "gungame_launcher.py"
$OutDir = Join-Path $Here "dist"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }

if (-not (Test-Path $Entry)) { throw "gungame_launcher.py not found next to this script." }

if ($Clean) {
    Write-Step "Cleaning"
    foreach ($p in @($Venv, $OutDir, (Join-Path $Here "build"), (Join-Path $Here "GunGameLauncher.spec"))) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
}

# PREFER A CONCRETE python.exe OVER THE `py` SHIM. Going through the launcher and
# splatting its arguments from an array dropped them on this machine: python opened an
# interactive REPL, read EOF, exited 0, and the venv was silently never created --
# which then surfaced two checks later as "could not find the venv interpreter", a
# message that points nowhere near the cause. Resolving a real interpreter path first
# and calling it with literal arguments removes both the shim and the splatting.
if (-not $Python) {
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) {
        $Python = $found.Source
    }
    elseif (Get-Command py -ErrorAction SilentlyContinue) {
        # Ask the launcher where its interpreter lives, then forget the launcher.
        $Python = (& py -3 -c "import sys; print(sys.executable)" | Select-Object -First 1)
        if ($Python) { $Python = $Python.Trim() }
    }
    if (-not $Python) {
        throw "No Python on PATH. Install Python 3.8+ (with tcl/tk) and re-run."
    }
}
if (-not (Test-Path $Python)) {
    throw "Not a usable interpreter path: '$Python'. Pass -Python <full path to python.exe>."
}

Write-Step "Interpreter"
$probeOut = & $Python -c "import sys, tkinter; print(sys.executable); print(sys.version); print('tk', tkinter.TkVersion)"
if ($LASTEXITCODE -ne 0 -or -not $probeOut) {
    throw "That interpreter cannot import tkinter. Reinstall Python with the tcl/tk option enabled."
}
$probeOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if (-not (Test-Path $Venv)) {
    Write-Step "Creating build virtualenv"
    & $Python -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed." }
}

$VenvPy = Join-Path $Venv "Scripts/python.exe"
if (-not (Test-Path $VenvPy)) { $VenvPy = Join-Path $Venv "bin/python" }
if (-not (Test-Path $VenvPy)) { throw "Could not find the venv interpreter under $Venv." }

Write-Step "Installing PyInstaller"
& $VenvPy -m pip install --upgrade --quiet pip pyinstaller
if ($LASTEXITCODE -ne 0) { throw "pip install pyinstaller failed." }

Write-Step "Freezing"
Push-Location $Here
try {
    # --windowed: no console window behind the GUI.
    # --onefile:  one artifact to hand over; it self-extracts to %TEMP% at start.
    #
    # IT HAS TO FIT IN A DISCORD MESSAGE. Handing someone the launcher is the whole
    # distribution story, and an attachment over 10 MB cannot be sent on a free
    # account. A default freeze of this file is 10.43 MB -- over the line by a
    # rounding error -- so two things bring it down and both are load-bearing:
    #
    #   EXCLUDES strip stdlib packages the launcher never touches. Everything listed
    #   is verified absent from its imports. Note what is NOT excluded: `email` looks
    #   unused but urllib.request parses response headers with it, and dropping it
    #   breaks every download. That takes it to 9.97 MB, which fits only if Discord
    #   means 10 MiB, and is 34 KB of headroom either way.
    #
    #   UPX compresses the Python DLL and the tcl/tk binaries, which are most of what
    #   is left. That takes it to 8.63 MB and is what makes the margin real. UPX is
    #   optional -- if it is not on PATH and -UpxDir was not given, this still builds,
    #   just bigger, and warns.
    $frozenArgs = @(
        "-m", "PyInstaller",
        "--noconfirm", "--onefile", "--windowed",
        "--name", "GunGameLauncher",
        "--distpath", $OutDir,
        "--workpath", (Join-Path $Here "build"),
        "--specpath", $Here
    )
    if ($UpxDir) {
        $frozenArgs += @("--upx-dir", $UpxDir)
    }
    elseif (-not (Get-Command upx -ErrorAction SilentlyContinue)) {
        Write-Host "    No UPX found. The build will be ~1.3 MB larger and may not fit" -ForegroundColor Yellow
        Write-Host "    in a 10 MB Discord attachment. Pass -UpxDir <folder with upx.exe>." -ForegroundColor Yellow
    }
    foreach ($m in $ExcludeModules) { $frozenArgs += @("--exclude-module", $m) }
    $frozenArgs += $Entry
    & $VenvPy @frozenArgs
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed." }
}
finally {
    Pop-Location
}

$exe = Get-ChildItem $OutDir -Filter "GunGameLauncher*" -File | Select-Object -First 1
if (-not $exe) { throw "PyInstaller reported success but produced no binary in $OutDir." }

Write-Step "Built"
Write-Host ("{0}  ({1:N1} MB)" -f $exe.FullName, ($exe.Length / 1MB)) -ForegroundColor Green
Write-Host "Unsigned, so SmartScreen will warn the first few times someone runs it." -ForegroundColor DarkGray
