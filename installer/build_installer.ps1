<#
.SYNOPSIS
    Build the MemoNest onedir bundle and the Inno Setup installer.

.DESCRIPTION
    Requires PyInstaller output at dist\MemoNest\ (run with -Build to create it)
    and Inno Setup 6.5+ (ISCC.exe). The version is read from core\config.py.

.EXAMPLE
    .\installer\build_installer.ps1 -Build

.EXAMPLE
    .\installer\build_installer.ps1
#>
param(
    [string]$Version = "",
    [switch]$Build,
    [switch]$SkipDataCheck
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$issPath = Join-Path $PSScriptRoot "MemoNest.iss"
$appDir = Join-Path $root "dist\MemoNest"
$appExe = Join-Path $appDir "MemoNest.exe"
$outDir = Join-Path $root "dist\installer"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Find-Iscc {
    if ($env:ISCC_PATH -and (Test-Path $env:ISCC_PATH)) {
        return (Resolve-Path $env:ISCC_PATH).Path
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

if (-not $Version) {
    $configPath = Join-Path $root "core\config.py"
    $match = Select-String -Path $configPath -Pattern 'APP_VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1
    if (-not $match) { throw "Cannot read APP_VERSION from $configPath" }
    $Version = $match.Matches[0].Groups[1].Value
}

Write-Host "MemoNest installer build" -ForegroundColor Green
Write-Host "  version : $Version"
Write-Host "  project : $root"
Write-Host "  output  : $outDir"

if ($Build) {
    Write-Step "Running PyInstaller (onedir)"
    $python = Join-Path $root ".venv\Scripts\python.exe"
    if (-not (Test-Path $python)) { $python = "python" }
    Push-Location $root
    try {
        & $python -m PyInstaller MemoNest.spec --noconfirm --clean
        if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $appExe)) {
    throw "Missing $appExe. Build first with: .\installer\build_installer.ps1 -Build"
}

if (-not $SkipDataCheck) {
    Write-Step "Checking bundle does not contain user data"
    $leaks = @()
    if (Test-Path (Join-Path $appDir "data")) { $leaks += "data\" }
    if (Test-Path (Join-Path $appDir "config.json")) { $leaks += "config.json" }
    if ($leaks.Count -gt 0) {
        throw ("Refusing to package user data: " + ($leaks -join ", ") + ". Rebuild with --clean or remove them from $appDir.")
    }
}

Write-Step "Locating Inno Setup compiler"
$iscc = Find-Iscc
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6 with: winget install --id JRSoftware.InnoSetup -e"
}
Write-Host "  ISCC    : $iscc"

Write-Step "Compiling installer"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
& $iscc "/DMyAppVersion=$Version" "/Qp" $issPath
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

$setupPath = Join-Path $outDir "MemoNest-Setup-$Version.exe"
if (-not (Test-Path $setupPath)) { throw "Installer was not created: $setupPath" }

$sizeMb = [math]::Round((Get-Item $setupPath).Length / 1MB, 1)
Write-Host ""
Write-Host "Done: $setupPath ($sizeMb MB)" -ForegroundColor Green
