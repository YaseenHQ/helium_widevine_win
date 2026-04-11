#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Helium', 'Chromium', 'Custom')]
    [string]$Target = 'Helium',

    [string]$TargetBinaryPath,

    [string]$TargetWidevineRoot,

    [string]$ProductVersion,

    [switch]$Force,

    [switch]$KeepWorkDir,

    [switch]$Uninstall,

    [string]$BackupRoot,

    [switch]$NoBackup,

    [switch]$PurgeBackups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WidevineAppId = 'oimompecagnajdejgnnjijobebaeigek'
$WidevineUpdateUrl = 'https://clients2.google.com/service/update2/json'
$ChromeStableVersionUrl = 'https://versionhistory.googleapis.com/v1/chrome/platforms/win/channels/stable/versions?pageSize=1'
$InstallerName = 'chromium-widevine-windows'
$InstallerMarkerFileName = '.installed-by-chromium-widevine-windows.json'

function Get-TargetBinaryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedTarget,

        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) {
            throw "Explicit target binary path does not exist: '$ExplicitPath'."
        }

        return $ExplicitPath
    }

    $registryCandidates = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $displayNamePattern = switch ($ResolvedTarget) {
        'Helium' { '*Helium*' }
        'Chromium' { '*Chromium*' }
        default { $null }
    }

    $discovered = New-Object System.Collections.Generic.List[string]
    $candidates = switch ($ResolvedTarget) {
        'Helium' {
            @(
                'C:\Program Files\imput\Helium\Application\chrome.exe',
                'C:\Program Files (x86)\imput\Helium\Application\chrome.exe',
                (Join-Path $env:LOCALAPPDATA 'imput\Helium\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Helium\Application\chrome.exe')
            )
        }
        'Chromium' {
            @(
                'C:\Program Files\Chromium\Application\chrome.exe',
                'C:\Program Files (x86)\Chromium\Application\chrome.exe',
                (Join-Path $env:LOCALAPPDATA 'Chromium\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Chromium\Application\chrome.exe')
            )
        }
        default {
            @()
        }
    }

    foreach ($root in $registryCandidates) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($subKey in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            try {
                $item = Get-ItemProperty -LiteralPath $subKey.PSPath
            } catch {
                continue
            }

            $displayName = if ($null -ne $item.PSObject.Properties['DisplayName']) {
                [string]$item.DisplayName
            } else {
                ''
            }

            if (-not $displayNamePattern -or $displayName -notlike $displayNamePattern) {
                continue
            }

            $displayIcon = if ($null -ne $item.PSObject.Properties['DisplayIcon']) {
                [string]$item.DisplayIcon
            } else {
                $null
            }

            $installLocation = if ($null -ne $item.PSObject.Properties['InstallLocation']) {
                [string]$item.InstallLocation
            } else {
                $null
            }

            foreach ($value in @($displayIcon, $installLocation)) {
                if ([string]::IsNullOrWhiteSpace($value)) {
                    continue
                }

                $candidate = $value.Trim('"')
                if ($candidate -like '*.exe' -and (Test-Path -LiteralPath $candidate)) {
                    $discovered.Add($candidate)
                    continue
                }

                $binaryFromDirectory = Join-Path $candidate 'chrome.exe'
                if (Test-Path -LiteralPath $binaryFromDirectory) {
                    $discovered.Add($binaryFromDirectory)
                }
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $discovered.Add($candidate)
        }
    }

    $resolved = @($discovered |
        Where-Object { $_ } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
        Sort-Object -Unique)

    if (-not $resolved) {
        return $null
    }

    if ($resolved.Count -gt 1) {
        $joined = ($resolved -join "', '")
        throw "Multiple $ResolvedTarget installations were found. Pass -TargetBinaryPath explicitly. Candidates: '$joined'."
    }

    return @($resolved)[0]
}

function Get-TargetUserDataRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedTarget
    )

    switch ($ResolvedTarget) {
        'Helium' {
            return (Join-Path $env:LOCALAPPDATA 'imput\Helium\User Data')
        }
        'Chromium' {
            return (Join-Path $env:LOCALAPPDATA 'Chromium\User Data')
        }
        default {
            return $null
        }
    }
}

function Get-TargetWidevineRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedTarget,

        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        return $ExplicitPath
    }

    switch ($ResolvedTarget) {
        'Helium' {
            return (Join-Path $env:LOCALAPPDATA 'imput\Helium\User Data\WidevineCdm')
        }
        'Chromium' {
            return (Join-Path $env:LOCALAPPDATA 'Chromium\User Data\WidevineCdm')
        }
        default {
            throw 'Custom target requires -TargetWidevineRoot.'
        }
    }
}

function Get-BackupRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WidevineRoot,

        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        return $ExplicitPath
    }

    return (Join-Path $WidevineRoot '_backup')
}

function Get-InstallerMarkerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WidevineRoot
    )

    return (Join-Path $WidevineRoot $InstallerMarkerFileName)
}

function Get-FileProductVersion {
    param(
        [string]$Path
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $version = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $null
    }

    return $version
}

function Get-PeArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)

    try {
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset + 4
        $machine = $reader.ReadUInt16()

        switch ($machine) {
            0x014c { return 'x86' }
            0x8664 { return 'x64' }
            0xAA64 { return 'arm64' }
            default { return $null }
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Resolve-WidevineArchitecture {
    param(
        [string]$BinaryPath
    )

    if ($BinaryPath -and (Test-Path -LiteralPath $BinaryPath)) {
        $peArch = Get-PeArchitecture -Path $BinaryPath
        if ($peArch -eq 'arm64') {
            return 'x64'
        }
        if ($peArch) {
            return $peArch
        }
    }

    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x64' }
        'x86'   { return 'x86' }
        'ARM64' { return 'x64' }
        default { return 'x64' }
    }
}

function Test-TargetRunning {
    param(
        [string]$BinaryPath
    )

    if (-not $BinaryPath) {
        return $false
    }

    $normalized = [System.IO.Path]::GetFullPath($BinaryPath)
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -ieq $normalized)
        } catch {
            $false
        }
    }).Count -gt 0
}

function Get-WidevineVersionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WidevineRoot
    )

    if (-not (Test-Path -LiteralPath $WidevineRoot)) {
        return $null
    }

    $candidates = foreach ($directory in Get-ChildItem -LiteralPath $WidevineRoot -Directory -ErrorAction SilentlyContinue) {
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            continue
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        [pscustomobject]@{
            VersionDirectory = $directory.FullName
            Version          = [string]$manifest.version
            ManifestPath     = $manifestPath
            SortKey          = [version][string]$manifest.version
        }
    }

    if (-not $candidates) {
        return $null
    }

    return $candidates | Sort-Object SortKey -Descending | Select-Object -First 1
}

function Test-WidevineLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    $platformDir = "win_$Architecture"
    $requiredPaths = @(
        'LICENSE',
        'manifest.json',
        '_metadata\verified_contents.json',
        "_platform_specific\$platformDir\widevinecdm.dll",
        "_platform_specific\$platformDir\widevinecdm.dll.sig"
    )

    foreach ($relativePath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $VersionDirectory $relativePath))) {
            return $false
        }
    }

    return $true
}

function Get-LatestStableChromeVersion {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $ChromeStableVersionUrl
    $payload = $response.Content | ConvertFrom-Json
    $version = $payload.versions[0].version

    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'Unable to resolve the latest Windows Chrome stable version from the VersionHistory API.'
    }

    return $version
}

function Resolve-ProductVersion {
    param(
        [string]$RequestedVersion,
        [string]$TargetBinaryPath
    )

    if ($RequestedVersion) {
        return $RequestedVersion
    }

    $installedVersion = Get-FileProductVersion -Path $TargetBinaryPath
    if ($installedVersion) {
        return $installedVersion
    }

    return Get-LatestStableChromeVersion
}

function Get-OsVersionString {
    $osVersion = [System.Environment]::OSVersion.Version
    return '{0}.{1}.{2}.{3}' -f $osVersion.Major, $osVersion.Minor, $osVersion.Build, $osVersion.Revision
}

function New-WidevineUpdateRequestBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProductVersion,

        [Parameter(Mandatory = $true)]
        [string]$InstalledWidevineVersion,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [switch]$AllowSameVersionUpdate
    )

    $osArch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'x86'   { 'x86' }
        'ARM64' { 'arm64' }
        default { 'x64' }
    }

    $requestBody = @{
        request = @{
            protocol      = '4.0'
            ismachine     = $false
            dedup         = 'cr'
            acceptformat  = 'crx3,download,puff,run'
            sessionid     = '{' + [guid]::NewGuid().ToString() + '}'
            requestid     = '{' + [guid]::NewGuid().ToString() + '}'
            '@updater'    = 'Chrome'
            prodversion   = $ProductVersion
            updaterversion = $ProductVersion
            '@os'         = 'win'
            arch          = $Architecture
            os            = @{
                platform = 'win'
                version  = Get-OsVersionString
                arch     = $osArch
            }
            hw            = @{
                physmemory = [math]::Max([int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB), 1)
                sse        = $true
                sse2       = $true
                sse3       = $true
                ssse3      = $true
                sse41      = $true
                sse42      = $true
                avx        = $false
            }
            apps          = @(
                @{
                    appid       = $WidevineAppId
                    version     = $InstalledWidevineVersion
                    updatecheck = @{
                        sameversionupdate = [bool]$AllowSameVersionUpdate
                    }
                }
            )
        }
    }

    return $requestBody | ConvertTo-Json -Depth 10 -Compress
}

function Invoke-WidevineUpdateCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProductVersion,

        [Parameter(Mandatory = $true)]
        [string]$InstalledWidevineVersion,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [switch]$AllowSameVersionUpdate
    )

    $headers = @{
        'Content-Type'               = 'application/json'
        'X-Goog-Update-AppId'        = $WidevineAppId
        'X-Goog-Update-Interactivity' = 'fg'
        'X-Goog-Update-Updater'      = "Chrome-$ProductVersion"
    }

    $body = New-WidevineUpdateRequestBody `
        -ProductVersion $ProductVersion `
        -InstalledWidevineVersion $InstalledWidevineVersion `
        -Architecture $Architecture `
        -AllowSameVersionUpdate:$AllowSameVersionUpdate

    $response = Invoke-WebRequest `
        -UseBasicParsing `
        -Method Post `
        -Uri $WidevineUpdateUrl `
        -Headers $headers `
        -Body $body

    $jsonText = (($response.Content -split "`r?`n") | Select-Object -Skip 1) -join "`n"
    $payload = $jsonText | ConvertFrom-Json
    $app = $payload.response.apps[0]

    if (-not $app) {
        throw 'Google update service returned an empty app list for the Widevine request.'
    }

    return $app
}

function Resolve-WidevineDownload {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$UpdateApp
    )

    if ($UpdateApp.updatecheck.status -eq 'noupdate') {
        return $null
    }

    if ($UpdateApp.updatecheck.status -ne 'ok') {
        throw "Widevine update check failed with status '$($UpdateApp.updatecheck.status)'."
    }

    $downloadOperation = $UpdateApp.updatecheck.pipelines[0].operations | Where-Object { $_.type -eq 'download' } | Select-Object -First 1
    if (-not $downloadOperation) {
        throw 'Widevine update response did not include a download operation.'
    }

    $downloadUrl = $downloadOperation.urls |
        ForEach-Object { $_.url } |
        Where-Object { $_ -like 'https://*' } |
        Select-Object -First 1

    if (-not $downloadUrl) {
        throw 'Widevine update response did not include a usable HTTPS download URL.'
    }

    return [pscustomobject]@{
        Version = [string]$UpdateApp.updatecheck.nextversion
        Url     = $downloadUrl
        Sha256  = [string]$downloadOperation.out.sha256
    }
}

function Expand-Crx3Archive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CrxPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $zipPath = Join-Path (Split-Path -Path $CrxPath -Parent) 'payload.zip'
    $inputStream = [System.IO.File]::OpenRead($CrxPath)
    $reader = [System.IO.BinaryReader]::new($inputStream)

    try {
        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'Cr24') {
            throw 'Downloaded file is not a CRX archive.'
        }

        $crxVersion = $reader.ReadUInt32()
        if ($crxVersion -ne 3) {
            throw "Unsupported CRX version '$crxVersion'."
        }

        $headerSize = $reader.ReadUInt32()
        $inputStream.Position = 12 + $headerSize

        $zipStream = [System.IO.File]::Create($zipPath)
        try {
            $inputStream.CopyTo($zipStream)
        } finally {
            $zipStream.Dispose()
        }
    } finally {
        $reader.Dispose()
        $inputStream.Dispose()
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $DestinationPath -Force
}

function Get-WidevineManifestVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    $manifestPath = Join-Path $VersionDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Missing manifest.json under '$VersionDirectory'."
    }

    return [string](Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).version
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash($stream)
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
}

function Backup-VersionDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedBackupRoot
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        return $null
    }

    $leafName = Split-Path -Path $SourceDirectory -Leaf
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destination = Join-Path $ResolvedBackupRoot ($leafName + '-' + $timestamp)

    New-Item -ItemType Directory -Force -Path $ResolvedBackupRoot | Out-Null
    Move-Item -LiteralPath $SourceDirectory -Destination $destination
    return $destination
}

function Write-InstallerMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MarkerPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedTarget,

        [string]$ResolvedBinaryPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedWidevineRoot,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedDestinationDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedWidevineVersion,

        [string]$ResolvedBackupRoot
    )

    $payload = [pscustomobject]@{
        installer            = $InstallerName
        marker_version       = 1
        installed_at_utc     = (Get-Date).ToUniversalTime().ToString('o')
        target               = $ResolvedTarget
        target_binary_path   = $ResolvedBinaryPath
        widevine_root        = $ResolvedWidevineRoot
        destination_directory = $ResolvedDestinationDirectory
        widevine_version     = $ResolvedWidevineVersion
        backup_root          = $ResolvedBackupRoot
    }

    [System.IO.File]::WriteAllText($MarkerPath, (($payload | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Read-InstallerMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MarkerPath
    )

    if (-not (Test-Path -LiteralPath $MarkerPath)) {
        return $null
    }

    return (Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json)
}

function Remove-ManagedWidevine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedTarget,

        [string]$ResolvedBinaryPath,

        [string]$ResolvedUserDataRoot,

        [Parameter(Mandatory = $true)]
        [string]$WidevineRoot,

        [Parameter(Mandatory = $true)]
        [string]$MarkerPath,

        [string]$ResolvedBackupRoot,

        [switch]$RemoveBackups,

        [switch]$WhatIfMode
    )

    $marker = Read-InstallerMarker -MarkerPath $MarkerPath
    if (-not $marker) {
        if (-not (Test-Path -LiteralPath $WidevineRoot)) {
            throw "No Widevine installation found at '$WidevineRoot'. Nothing to uninstall."
        }
        throw "Widevine at '$WidevineRoot' was not installed by this script (no marker file). Remove it manually if needed."
    }

    $removedDirectories = New-Object System.Collections.Generic.List[string]
    $destinationDirectory = [string]$marker.destination_directory

    if ($destinationDirectory -and (Test-Path -LiteralPath $destinationDirectory)) {
        if (-not $WhatIfMode) {
            Remove-Item -LiteralPath $destinationDirectory -Recurse -Force
        }
        $removedDirectories.Add($destinationDirectory)
    }

    $backupRootToUse = if ($ResolvedBackupRoot) { $ResolvedBackupRoot } elseif ($marker.backup_root) { [string]$marker.backup_root } else { $null }
    if ($RemoveBackups -and $backupRootToUse -and (Test-Path -LiteralPath $backupRootToUse)) {
        if (-not $WhatIfMode) {
            Remove-Item -LiteralPath $backupRootToUse -Recurse -Force
        }
        $removedDirectories.Add($backupRootToUse)
    }

    if (-not $WhatIfMode -and (Test-Path -LiteralPath $MarkerPath)) {
        Remove-Item -LiteralPath $MarkerPath -Force
    }

    if (-not $WhatIfMode -and (Test-Path -LiteralPath $WidevineRoot)) {
        $remaining = @(Get-ChildItem -LiteralPath $WidevineRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $WidevineRoot -Force
        }
    }

    return [pscustomobject]@{
        Target            = $ResolvedTarget
        TargetBinaryPath  = $ResolvedBinaryPath
        TargetUserDataRoot = $ResolvedUserDataRoot
        WidevineRoot    = $WidevineRoot
        Uninstalled     = $true
        PurgedBackups   = [bool]$RemoveBackups
        RemovedPaths    = @($removedDirectories)
        Changed         = (-not $WhatIfMode)
    }
}

$resolvedTarget = $Target
$targetBinaryPath = Get-TargetBinaryPath -ResolvedTarget $resolvedTarget -ExplicitPath $TargetBinaryPath
$targetWidevineRoot = Get-TargetWidevineRoot -ResolvedTarget $resolvedTarget -ExplicitPath $TargetWidevineRoot
$targetUserDataRoot = Get-TargetUserDataRoot -ResolvedTarget $resolvedTarget
$resolvedBackupRoot = Get-BackupRoot -WidevineRoot $targetWidevineRoot -ExplicitPath $BackupRoot
$installerMarkerPath = Get-InstallerMarkerPath -WidevineRoot $targetWidevineRoot
$resolvedArchitecture = Resolve-WidevineArchitecture -BinaryPath $targetBinaryPath
$productVersion = Resolve-ProductVersion -RequestedVersion $ProductVersion -TargetBinaryPath $targetBinaryPath
$currentWidevine = Get-WidevineVersionInfo -WidevineRoot $targetWidevineRoot
$installedWidevineVersion = if ($currentWidevine) { $currentWidevine.Version } else { '0.0.0.0' }

if ($targetBinaryPath -and (Test-TargetRunning -BinaryPath $targetBinaryPath)) {
    throw "Close the target browser before installing Widevine. Running binary: '$targetBinaryPath'."
}

if ($Uninstall) {
    $uninstallAction = if ($PurgeBackups) {
        "Uninstall Widevine from '$targetWidevineRoot' and purge backups"
    } else {
        "Uninstall Widevine from '$targetWidevineRoot'"
    }

    if (-not $PSCmdlet.ShouldProcess($targetWidevineRoot, $uninstallAction)) {
        Remove-ManagedWidevine `
            -ResolvedTarget $resolvedTarget `
            -ResolvedBinaryPath $targetBinaryPath `
            -ResolvedUserDataRoot $targetUserDataRoot `
            -WidevineRoot $targetWidevineRoot `
            -MarkerPath $installerMarkerPath `
            -ResolvedBackupRoot $resolvedBackupRoot `
            -RemoveBackups:$PurgeBackups `
            -WhatIfMode:$true
        return
    }

    Remove-ManagedWidevine `
        -ResolvedTarget $resolvedTarget `
        -ResolvedBinaryPath $targetBinaryPath `
        -ResolvedUserDataRoot $targetUserDataRoot `
        -WidevineRoot $targetWidevineRoot `
        -MarkerPath $installerMarkerPath `
        -ResolvedBackupRoot $resolvedBackupRoot `
        -RemoveBackups:$PurgeBackups
    return
}

$updateApp = Invoke-WidevineUpdateCheck `
    -ProductVersion $productVersion `
    -InstalledWidevineVersion $installedWidevineVersion `
    -Architecture $resolvedArchitecture `
    -AllowSameVersionUpdate:$Force

$download = Resolve-WidevineDownload -UpdateApp $updateApp

if (-not $download) {
    if ($currentWidevine -and (Test-WidevineLayout -VersionDirectory $currentWidevine.VersionDirectory -Architecture $resolvedArchitecture) -and -not $Force) {
        [pscustomobject]@{
            Target               = $resolvedTarget
            TargetBinaryPath     = $targetBinaryPath
            TargetUserDataRoot   = $targetUserDataRoot
            ProductVersion       = $productVersion
            WidevineVersion      = $currentWidevine.Version
            Source               = 'Already installed'
            DestinationDirectory = $currentWidevine.VersionDirectory
            Changed              = $false
            BackupDirectory      = $null
        }
        Write-InstallerMarker `
            -MarkerPath $installerMarkerPath `
            -ResolvedTarget $resolvedTarget `
            -ResolvedBinaryPath $targetBinaryPath `
            -ResolvedWidevineRoot $targetWidevineRoot `
            -ResolvedDestinationDirectory $currentWidevine.VersionDirectory `
            -ResolvedWidevineVersion $currentWidevine.Version `
            -ResolvedBackupRoot $resolvedBackupRoot
        return
    }

    throw "Google did not offer a Widevine update for product version '$productVersion' (arch=$resolvedArchitecture). Try -ProductVersion with a current stable Chrome version, or install the target browser first."
}

$destinationVersionDirectory = Join-Path $targetWidevineRoot $download.Version

if ((Test-Path -LiteralPath $destinationVersionDirectory) -and
    (Test-WidevineLayout -VersionDirectory $destinationVersionDirectory -Architecture $resolvedArchitecture) -and
    -not $Force) {
    [pscustomobject]@{
        Target               = $resolvedTarget
        TargetBinaryPath     = $targetBinaryPath
        TargetUserDataRoot   = $targetUserDataRoot
        ProductVersion       = $productVersion
        WidevineVersion      = $download.Version
        Source               = 'Google component update service'
        DownloadUrl          = $download.Url
        DestinationDirectory = $destinationVersionDirectory
        Changed              = $false
        BackupDirectory      = $null
    }
    Write-InstallerMarker `
        -MarkerPath $installerMarkerPath `
        -ResolvedTarget $resolvedTarget `
        -ResolvedBinaryPath $targetBinaryPath `
        -ResolvedWidevineRoot $targetWidevineRoot `
        -ResolvedDestinationDirectory $destinationVersionDirectory `
        -ResolvedWidevineVersion $download.Version `
        -ResolvedBackupRoot $resolvedBackupRoot
    return
}

$workRoot = Join-Path $env:TEMP ("widevine-download-" + [guid]::NewGuid().ToString('N'))
$crxPath = Join-Path $workRoot 'widevine.crx3'
$extractPath = Join-Path $workRoot 'extracted'

$action = "Install Widevine $($download.Version) into '$targetWidevineRoot'"
if (-not $PSCmdlet.ShouldProcess($targetWidevineRoot, $action)) {
    [pscustomobject]@{
        Target               = $resolvedTarget
        TargetBinaryPath     = $targetBinaryPath
        TargetUserDataRoot   = $targetUserDataRoot
        ProductVersion       = $productVersion
        InstalledWidevine    = $installedWidevineVersion
        WidevineVersion      = $download.Version
        Source               = 'Google component update service'
        DownloadUrl          = $download.Url
        DestinationDirectory = $destinationVersionDirectory
        Changed              = $false
        BackupDirectory      = $null
    }
    return
}

New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    Invoke-WebRequest -UseBasicParsing -Uri $download.Url -OutFile $crxPath

    $actualHash = Get-Sha256Hex -Path $crxPath
    $expectedHash = $download.Sha256.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Downloaded Widevine payload hash mismatch. Expected '$expectedHash', got '$actualHash'."
    }

    Expand-Crx3Archive -CrxPath $crxPath -DestinationPath $extractPath

    $manifestVersion = Get-WidevineManifestVersion -VersionDirectory $extractPath
    if ($manifestVersion -ne $download.Version) {
        throw "Widevine manifest version '$manifestVersion' does not match the update response '$($download.Version)'."
    }

    if (-not (Test-WidevineLayout -VersionDirectory $extractPath -Architecture $resolvedArchitecture)) {
        throw 'Extracted Widevine payload is missing required files.'
    }

    New-Item -ItemType Directory -Force -Path $targetWidevineRoot | Out-Null

    $backupDirectory = $null
    if (Test-Path -LiteralPath $destinationVersionDirectory) {
        if ($NoBackup) {
            Remove-Item -LiteralPath $destinationVersionDirectory -Recurse -Force
        } else {
            $backupDirectory = Backup-VersionDirectory -SourceDirectory $destinationVersionDirectory -ResolvedBackupRoot $resolvedBackupRoot
        }
    }

    New-Item -ItemType Directory -Force -Path $destinationVersionDirectory | Out-Null
    Copy-Item -Path (Join-Path $extractPath '*') -Destination $destinationVersionDirectory -Recurse -Force

    Write-InstallerMarker `
        -MarkerPath $installerMarkerPath `
        -ResolvedTarget $resolvedTarget `
        -ResolvedBinaryPath $targetBinaryPath `
        -ResolvedWidevineRoot $targetWidevineRoot `
        -ResolvedDestinationDirectory $destinationVersionDirectory `
        -ResolvedWidevineVersion $download.Version `
        -ResolvedBackupRoot $resolvedBackupRoot

    [pscustomobject]@{
        Target               = $resolvedTarget
        TargetBinaryPath     = $targetBinaryPath
        TargetUserDataRoot   = $targetUserDataRoot
        ProductVersion       = $productVersion
        InstalledWidevine    = $installedWidevineVersion
        WidevineVersion      = $download.Version
        Source               = 'Google component update service'
        DownloadUrl          = $download.Url
        DestinationDirectory = $destinationVersionDirectory
        Changed              = $true
        BackupDirectory      = $backupDirectory
        WorkDirectory        = if ($KeepWorkDir) { $workRoot } else { $null }
    }
} finally {
    if ((Test-Path -LiteralPath $workRoot) -and -not $KeepWorkDir) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
