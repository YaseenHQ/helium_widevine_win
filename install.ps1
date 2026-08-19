<#
.SYNOPSIS
    One-line bootstrap for helium-widevine-windows.

.DESCRIPTION
    Downloads the latest published release, verifies it against the checksums
    file shipped with that release, and runs the installer.

    Usage:
        irm https://raw.githubusercontent.com/YaseenHQ/helium_widevine_win/main/install.ps1 | iex

    To pass arguments, create a script block instead so they reach the payload:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/YaseenHQ/helium_widevine_win/main/install.ps1))) -InstallScheduledTask

.NOTES
    This bootstrap only fetches release assets over HTTPS from api.github.com
    and github.com, and refuses any asset whose SHA-256 does not match the
    published checksums file.
#>

[CmdletBinding()]
param(
    # Pin a specific release tag instead of taking the latest.
    [string]$Version,

    # Keep the extracted payload instead of removing it after the run.
    [switch]$KeepPayload,

    # Everything else is forwarded verbatim to Install-Widevine.ps1.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InstallerArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$Repository = 'YaseenHQ/helium_widevine_win'
$ProgressPreference = 'SilentlyContinue'

function Get-ReleaseMetadata {
    # "Metadata" is already singular; the analyzer's heuristic disagrees.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    param([string]$Tag)

    $uri = if ($Tag) {
        "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    } else {
        "https://api.github.com/repos/$Repository/releases/latest"
    }

    Write-Host "Resolving release from $uri"
    return Invoke-RestMethod -Uri $uri -Headers @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'helium-widevine-bootstrap'
    } -TimeoutSec 30
}

function Get-AssetUrl {
    param($Release, [string]$Pattern)

    $asset = $Release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) {
        throw "Release '$($Release.tag_name)' has no asset matching '$Pattern'."
    }

    return $asset.browser_download_url
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("helium-widevine-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    $release = Get-ReleaseMetadata -Tag $Version
    Write-Host "Release: $($release.tag_name)"

    $zipUrl = Get-AssetUrl -Release $release -Pattern '*portable*.zip'
    $checksumUrl = Get-AssetUrl -Release $release -Pattern 'checksums*.txt'

    $zipPath = Join-Path $workRoot 'payload.zip'
    $checksumPath = Join-Path $workRoot 'checksums.txt'

    Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zipPath -TimeoutSec 120
    Invoke-WebRequest -UseBasicParsing -Uri $checksumUrl -OutFile $checksumPath -TimeoutSec 30

    $zipName = [System.IO.Path]::GetFileName(([uri]$zipUrl).AbsolutePath)
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        # Format: "<sha256>  <filename>"
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $zipName) {
            $expected = $parts[0].Trim().ToLowerInvariant()
            break
        }
    }

    if (-not $expected) {
        throw "The release checksums file has no entry for '$zipName'."
    }

    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Checksum mismatch for '$zipName'. Expected '$expected', got '$actual'."
    }

    Write-Host "Checksum verified: $actual"

    $payloadRoot = Join-Path $workRoot 'payload'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $payloadRoot)

    $script = Get-ChildItem -LiteralPath $payloadRoot -Recurse -Filter 'Install-Widevine.ps1' |
        Select-Object -First 1
    if (-not $script) {
        throw 'The release payload does not contain Install-Widevine.ps1.'
    }

    Write-Host "Running $($script.Name)`n"
    & $script.FullName @InstallerArguments
} finally {
    if ($KeepPayload) {
        Write-Host "`nPayload kept at $workRoot"
    } elseif (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
