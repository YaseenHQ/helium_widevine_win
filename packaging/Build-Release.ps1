<#
.SYNOPSIS
    Builds the release artifacts: a portable zip, an Inno Setup installer, and
    a checksums file covering both.

.EXAMPLE
    .\packaging\Build-Release.ps1 -Version 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    # Skip the installer when Inno Setup is unavailable (portable zip only).
    [switch]$SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$distRoot = Join-Path $repoRoot 'dist'

if (Test-Path -LiteralPath $distRoot) {
    Remove-Item -LiteralPath $distRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $distRoot | Out-Null

# --- Portable zip -----------------------------------------------------------

$payloadName = "helium-widevine-$Version-portable"
$payloadRoot = Join-Path $distRoot $payloadName
New-Item -ItemType Directory -Path $payloadRoot | Out-Null

foreach ($file in @('Install-Widevine.ps1', 'install-widevine.cmd', 'README.md', 'LICENSE')) {
    $source = Join-Path $repoRoot $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Missing required file for the portable payload: $file"
    }
    Copy-Item -LiteralPath $source -Destination $payloadRoot
}

$zipPath = Join-Path $distRoot "$payloadName.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($payloadRoot, $zipPath)
Remove-Item -LiteralPath $payloadRoot -Recurse -Force
Write-Host "Portable zip: $zipPath"

# --- Inno Setup installer ---------------------------------------------------

if (-not $SkipInstaller) {
    $iscc = Get-Command -Name 'iscc.exe' -ErrorAction SilentlyContinue
    if (-not $iscc) {
        foreach ($candidate in @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                $iscc = Get-Item -LiteralPath $candidate
                break
            }
        }
    }

    if (-not $iscc) {
        throw 'Inno Setup (ISCC.exe) was not found. Install it, or pass -SkipInstaller.'
    }

    $script = Join-Path $PSScriptRoot 'HeliumWidevine.iss'
    & $iscc.Source "/DAppVersion=$Version" $script
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }

    Write-Host "Installer: $(Join-Path $distRoot "HeliumWidevineSetup-$Version.exe")"
}

# --- Checksums --------------------------------------------------------------

# Two spaces between hash and filename, matching sha256sum output so the
# bootstrap and any external tooling can parse it.
$lines = foreach ($artifact in Get-ChildItem -LiteralPath $distRoot -File | Sort-Object Name) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),
                  $artifact.Name
}

$checksumPath = Join-Path $distRoot 'checksums.txt'
Set-Content -LiteralPath $checksumPath -Value $lines -Encoding ascii
Write-Host "`nchecksums.txt:"
$lines | ForEach-Object { "  $_" }
