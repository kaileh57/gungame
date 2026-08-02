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
    [switch] $Clean
)

$ErrorActionPreference = "Stop"
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

if (-not $Python) {
    if (Get-Command py -ErrorAction SilentlyContinue) { $Python = "py" }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { $Python = "python" }
    else { throw "No Python on PATH. Install Python 3.8+ (with tcl/tk) and re-run." }
}
$pyArgs = if ($Python -eq "py") { @("-3") } else { @() }

Write-Step "Interpreter"
& $Python @pyArgs -c "import sys, tkinter; print(sys.version); print('tk', tkinter.TkVersion)"
if ($LASTEXITCODE -ne 0) {
    throw "That interpreter cannot import tkinter. Reinstall Python with the tcl/tk option enabled."
}

if (-not (Test-Path $Venv)) {
    Write-Step "Creating build virtualenv"
    & $Python @pyArgs -m venv $Venv
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
    & $VenvPy -m PyInstaller `
        --noconfirm `
        --onefile `
        --windowed `
        --name GunGameLauncher `
        --distpath $OutDir `
        --workpath (Join-Path $Here "build") `
        --specpath $Here `
        $Entry
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
