<#
.SYNOPSIS
    Fills the winget manifest templates for a release.

.DESCRIPTION
    Reads the installer's hash from a release checksums.txt and writes
    submission-ready manifests to an output directory, leaving the templates in
    packaging/winget untouched.

.EXAMPLE
    .\packaging\Update-WingetManifest.ps1 -Version 1.0.0

.EXAMPLE
    # Pull the hash straight from the published release instead of a local build
    .\packaging\Update-WingetManifest.ps1 -Version 1.0.0 -FromRelease
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    # Download checksums.txt from the published GitHub release rather than
    # reading a local dist/checksums.txt.
    [switch]$FromRelease,

    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$templateDir = Join-Path $PSScriptRoot 'winget'

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot "dist\winget\$Version"
}

$installerName = "HeliumWidevineSetup-$Version.exe"

# --- Locate the installer hash ----------------------------------------------

if ($FromRelease) {
    $url = "https://github.com/YaseenHQ/helium_widevine_win/releases/download/v$Version/checksums.txt"
    Write-Host "Fetching $url"
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $checksumText = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30).Content
    } finally {
        $ProgressPreference = $previousProgress
    }
    $checksumLines = $checksumText -split "`r?`n"
} else {
    $checksumPath = Join-Path $repoRoot 'dist\checksums.txt'
    if (-not (Test-Path -LiteralPath $checksumPath)) {
        throw "No checksums at '$checksumPath'. Run Build-Release.ps1 first, or pass -FromRelease."
    }
    $checksumLines = Get-Content -LiteralPath $checksumPath
}

$sha256 = $null
foreach ($line in $checksumLines) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $installerName) {
        $sha256 = $parts[0].Trim()
        break
    }
}

if (-not $sha256) {
    throw "No checksum entry for '$installerName'. Was the installer built (not -SkipInstaller)?"
}

# --- Render templates -------------------------------------------------------

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$replacements = @{
    '__VERSION__'      = $Version
    # winget requires the installer hash in uppercase.
    '__SHA256__'       = $sha256.ToUpperInvariant()
    '__RELEASE_DATE__' = (Get-Date -Format 'yyyy-MM-dd')
}

foreach ($template in Get-ChildItem -LiteralPath $templateDir -Filter '*.yaml') {
    $content = Get-Content -LiteralPath $template.FullName -Raw

    # Strip the template-only comments first. Doing this after substitution
    # would leave them behind, since their placeholders are gone by then.
    $content = $content -replace '(?m)^# Template\..*\r?\n', ''
    $content = $content -replace '(?m)^# __SHA256__ is.*\r?\n', ''

    foreach ($key in $replacements.Keys) {
        $content = $content.Replace($key, $replacements[$key])
    }

    if ($content -match '__[A-Z_]+__') {
        throw "Unreplaced placeholder left in $($template.Name): $($Matches[0])"
    }

    $destination = Join-Path $OutputDirectory $template.Name
    Set-Content -LiteralPath $destination -Value $content.TrimEnd() -Encoding utf8
    Write-Host "  $($template.Name)"
}

Write-Host "`nManifests written to $OutputDirectory"
Write-Host "InstallerSha256: $($replacements['__SHA256__'])"
Write-Host @"

Next:
  winget validate --manifest "$OutputDirectory"
  wingetcreate submit "$OutputDirectory"

Or open a PR against microsoft/winget-pkgs placing these under
manifests/y/YaseenHQ/HeliumWidevine/$Version/
"@
