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

    [switch]$PurgeBackups,

    [switch]$InstallScheduledTask,

    [switch]$RemoveScheduledTask,

    [switch]$SkipIfBrowserRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 5.1 inherits .NET's legacy default on some Windows builds, which
# can still negotiate TLS 1.0. Google's endpoints require 1.2 or better.
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Load up front with -WhatIf suppressed: lazy autoload would otherwise run the
# module's own Set-Alias calls under -WhatIf and flood dry-run output.
if (-not (Get-Module -Name CimCmdlets)) {
    $previousWhatIfPreference = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        Import-Module CimCmdlets -ErrorAction SilentlyContinue | Out-Null
    } finally {
        $WhatIfPreference = $previousWhatIfPreference
    }
}

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

function Get-HostArchitecture {
    $processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($processor) {
        switch ([int]$processor.Architecture) {
            0 { return 'x86' }
            9 { return 'x64' }
            12 { return 'arm64' }
        }
    }

    $envArch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($envArch) {
        'AMD64' { return 'x64' }
        'x86'   { return 'x86' }
        'ARM64' { return 'arm64' }
        default { return 'x64' }
    }
}

function Resolve-WidevineArchitecture {
    param(
        [string]$BinaryPath
    )

    # Google publishes a distinct win_arm64 Widevine package, and Helium ships a
    # native ARM64 build. Resolving arm64 to x64 installs a CDM the browser
    # cannot load, so mirror the target binary's real architecture.
    if ($BinaryPath -and (Test-Path -LiteralPath $BinaryPath)) {
        $peArch = Get-PeArchitecture -Path $BinaryPath
        if ($peArch) {
            return $peArch
        }
    }

    switch (Get-HostArchitecture) {
        'x86'   { return 'x86' }
        'arm64' { return 'arm64' }
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

        # One unreadable or malformed manifest must not abort discovery of the
        # other installed versions.
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifestVersion = [string]$manifest.version
            [pscustomobject]@{
                VersionDirectory = $directory.FullName
                Version          = $manifestVersion
                ManifestPath     = $manifestPath
                SortKey          = [version]$manifestVersion
            }
        } catch {
            Write-Verbose "Skipping unreadable Widevine manifest '$manifestPath': $($_.Exception.Message)"
            continue
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

    # Chromium's WidevineCdmComponentInstallerPolicy::VerifyInstallation rejects
    # a CDM whose manifest lacks these keys, and a rejected component registers
    # nothing at all -- silently, with no browser-side error. Catch it here
    # instead, where we can say why.
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $VersionDirectory 'manifest.json') -Raw | ConvertFrom-Json
    } catch {
        return $false
    }

    foreach ($key in @('x-cdm-interface-versions', 'x-cdm-module-versions', 'x-cdm-codecs')) {
        $property = $manifest.PSObject.Properties[$key]
        if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $false
        }
    }

    return $true
}

function Get-LatestStableChromeVersion {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $ChromeStableVersionUrl -TimeoutSec 30
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
    # Builds and returns a JSON string; the New- verb implies no state change.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProductVersion,

        [Parameter(Mandatory = $true)]
        [string]$InstalledWidevineVersion,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [switch]$AllowSameVersionUpdate
    )

    $osArch = Get-HostArchitecture

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
        -Body $body `
        -TimeoutSec 30

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

    # Google returns each mirror twice (http then https). Keep every HTTPS
    # mirror so a single unreachable host does not fail the install.
    $downloadUrls = @($downloadOperation.urls |
        ForEach-Object { $_.url } |
        Where-Object { $_ -like 'https://*' })

    if ($downloadUrls.Count -eq 0) {
        throw 'Widevine update response did not include a usable HTTPS download URL.'
    }

    $expectedSha256 = [string]$downloadOperation.out.sha256
    if ([string]::IsNullOrWhiteSpace($expectedSha256)) {
        throw 'Widevine update response did not include a SHA-256 for the payload.'
    }

    return [pscustomobject]@{
        Version = [string]$UpdateApp.updatecheck.nextversion
        Urls    = $downloadUrls
        Url     = $downloadUrls[0]
        Sha256  = $expectedSha256
    }
}

function Read-Asn1Length {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data,

        [Parameter(Mandatory = $true)]
        [ref]$Offset
    )

    $first = $Data[$Offset.Value]
    $Offset.Value++

    if ($first -lt 0x80) {
        return [int]$first
    }

    $byteCount = $first -band 0x7F
    if ($byteCount -eq 0 -or $byteCount -gt 4) {
        throw 'Unsupported ASN.1 length encoding in the CRX public key.'
    }

    $length = 0
    for ($i = 0; $i -lt $byteCount; $i++) {
        $length = ($length -shl 8) -bor $Data[$Offset.Value]
        $Offset.Value++
    }

    return $length
}

function Read-Asn1Tag {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data,

        [Parameter(Mandatory = $true)]
        [ref]$Offset,

        [Parameter(Mandatory = $true)]
        [byte]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$What
    )

    if ($Data[$Offset.Value] -ne $Expected) {
        throw ("Malformed CRX public key: expected {0} (tag 0x{1:X2}) but found 0x{2:X2}." -f
            $What, $Expected, $Data[$Offset.Value])
    }

    $Offset.Value++
    return (Read-Asn1Length -Data $Data -Offset $Offset)
}

function ConvertFrom-DerUnsignedInteger {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    # DER stores a leading zero byte to keep the value positive; RSAParameters
    # wants the raw magnitude without it.
    $start = 0
    while ($start -lt ($Bytes.Length - 1) -and $Bytes[$start] -eq 0) {
        $start++
    }

    return $Bytes[$start..($Bytes.Length - 1)]
}

function Get-RsaParametersFromSpki {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$SubjectPublicKeyInfo
    )

    # .NET Framework (which drives PowerShell 5.1) has no
    # RSA.ImportSubjectPublicKeyInfo, so unwrap the DER by hand:
    #   SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
    #   RSAPublicKey ::= SEQUENCE { INTEGER modulus, INTEGER publicExponent }
    $offset = 0
    [void](Read-Asn1Tag -Data $SubjectPublicKeyInfo -Offset ([ref]$offset) -Expected 0x30 -What 'SubjectPublicKeyInfo')

    $algorithmLength = Read-Asn1Tag -Data $SubjectPublicKeyInfo -Offset ([ref]$offset) -Expected 0x30 -What 'AlgorithmIdentifier'
    $offset += $algorithmLength

    [void](Read-Asn1Tag -Data $SubjectPublicKeyInfo -Offset ([ref]$offset) -Expected 0x03 -What 'subjectPublicKey BIT STRING')
    if ($SubjectPublicKeyInfo[$offset] -ne 0) {
        throw 'Malformed CRX public key: unexpected unused-bit count in the BIT STRING.'
    }
    $offset++

    [void](Read-Asn1Tag -Data $SubjectPublicKeyInfo -Offset ([ref]$offset) -Expected 0x30 -What 'RSAPublicKey')

    $modulusLength = Read-Asn1Tag -Data $SubjectPublicKeyInfo -Offset ([ref]$offset) -Expected 0x02 -What 'modulus'
    $modulus = $SubjectPublicKeyInfo[$offset..($offset + $modulusLength - 1)]
    $offset += $modulusLength

    $exponentLength = Read-Asn1Tag -Data $SubjectPublicKeyInfo -Offset ([ref]$offset) -Expected 0x02 -What 'publicExponent'
    $exponent = $SubjectPublicKeyInfo[$offset..($offset + $exponentLength - 1)]

    $parameters = New-Object System.Security.Cryptography.RSAParameters
    $parameters.Modulus = ConvertFrom-DerUnsignedInteger -Bytes $modulus
    $parameters.Exponent = ConvertFrom-DerUnsignedInteger -Bytes $exponent
    return $parameters
}

function ConvertTo-CrxExtensionId {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$SubjectPublicKeyInfo
    )

    # A Chromium extension/component ID is the first 16 bytes of the SHA-256 of
    # the DER public key, with each nibble mapped 0-f onto a-p.
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($SubjectPublicKeyInfo)
    } finally {
        $sha256.Dispose()
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $digest[0..15]) {
        [void]$builder.Append([char](97 + ($byte -shr 4)))
        [void]$builder.Append([char](97 + ($byte -band 0x0F)))
    }

    return $builder.ToString()
}

function Read-ProtobufFields {
    # Plural is deliberate: this returns every field in the message.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    $fields = New-Object System.Collections.Generic.List[psobject]
    $offset = 0

    while ($offset -lt $Data.Length) {
        # Field key varint: (fieldNumber << 3) | wireType
        $key = [uint64]0
        $shift = 0
        do {
            if ($offset -ge $Data.Length) {
                throw 'Truncated CRX header: incomplete field key.'
            }
            $current = $Data[$offset]
            $offset++
            $key = $key -bor ([uint64]($current -band 0x7F) -shl $shift)
            $shift += 7
        } while ($current -band 0x80)

        $fieldNumber = [int]($key -shr 3)
        $wireType = [int]($key -band 0x07)

        switch ($wireType) {
            0 {
                # Varint value; skip it.
                do {
                    $current = $Data[$offset]
                    $offset++
                } while ($current -band 0x80)
            }
            2 {
                $length = [int]0
                $shift = 0
                do {
                    $current = $Data[$offset]
                    $offset++
                    $length = $length -bor (($current -band 0x7F) -shl $shift)
                    $shift += 7
                } while ($current -band 0x80)

                if (($offset + $length) -gt $Data.Length) {
                    throw 'Truncated CRX header: length-delimited field overruns the buffer.'
                }

                $value = if ($length -eq 0) { , [byte[]]@() } else { , [byte[]]$Data[$offset..($offset + $length - 1)] }
                $offset += $length

                $fields.Add([pscustomobject]@{
                    FieldNumber = $fieldNumber
                    Value       = $value
                })
            }
            5 { $offset += 4 }
            1 { $offset += 8 }
            default {
                throw "Unsupported protobuf wire type '$wireType' in the CRX header."
            }
        }
    }

    return $fields
}

function Test-Crx3Signature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CrxPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedExtensionId
    )

    $stream = [System.IO.File]::OpenRead($CrxPath)
    $reader = [System.IO.BinaryReader]::new($stream)

    try {
        if ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'Cr24') {
            throw 'Downloaded file is not a CRX archive.'
        }

        $crxVersion = $reader.ReadUInt32()
        if ($crxVersion -ne 3) {
            throw "Unsupported CRX version '$crxVersion'."
        }

        $headerSize = $reader.ReadUInt32()
        $headerBytes = $reader.ReadBytes($headerSize)
        if ($headerBytes.Length -ne $headerSize) {
            throw 'Truncated CRX header.'
        }

        $payloadOffset = 12 + $headerSize
        $fields = Read-ProtobufFields -Data $headerBytes

        # CrxFileHeader field 10000 is signed_header_data (a SignedData message
        # whose field 1 is the 16-byte crx_id); field 2 is the repeated
        # sha256_with_rsa proof list.
        $signedHeaderData = ($fields | Where-Object { $_.FieldNumber -eq 10000 } | Select-Object -First 1).Value
        if ($null -eq $signedHeaderData) {
            throw 'CRX header does not contain signed header data.'
        }

        $rsaProofs = @($fields | Where-Object { $_.FieldNumber -eq 2 })
        if ($rsaProofs.Count -eq 0) {
            throw 'CRX header does not contain an RSA signature proof.'
        }

        # The signature covers a domain-separated prefix, then the signed header
        # data, then the ZIP payload.
        $prefix = [System.Collections.Generic.List[byte]]::new()
        $prefix.AddRange([System.Text.Encoding]::ASCII.GetBytes('CRX3 SignedData'))
        $prefix.Add(0)
        $prefix.AddRange([System.BitConverter]::GetBytes([uint32]$signedHeaderData.Length))
        $prefix.AddRange($signedHeaderData)

        $matchedId = $false
        foreach ($proof in $rsaProofs) {
            $proofFields = Read-ProtobufFields -Data $proof.Value
            $publicKey = ($proofFields | Where-Object { $_.FieldNumber -eq 1 } | Select-Object -First 1).Value
            $signature = ($proofFields | Where-Object { $_.FieldNumber -eq 2 } | Select-Object -First 1).Value

            if ($null -eq $publicKey -or $null -eq $signature) {
                continue
            }

            $extensionId = ConvertTo-CrxExtensionId -SubjectPublicKeyInfo $publicKey
            if ($extensionId -ne $ExpectedExtensionId) {
                continue
            }

            $matchedId = $true

            # Hash incrementally: the payload is ~22 MB and need not be buffered.
            $hasher = [System.Security.Cryptography.IncrementalHash]::CreateHash(
                [System.Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                $hasher.AppendData($prefix.ToArray())

                $stream.Position = $payloadOffset
                $buffer = New-Object byte[] 1048576
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $hasher.AppendData($buffer, 0, $read)
                }

                $digest = $hasher.GetHashAndReset()
            } finally {
                $hasher.Dispose()
            }

            $rsa = [System.Security.Cryptography.RSA]::Create()
            try {
                $rsa.ImportParameters((Get-RsaParametersFromSpki -SubjectPublicKeyInfo $publicKey))
                $verified = $rsa.VerifyHash(
                    $digest,
                    $signature,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            } finally {
                $rsa.Dispose()
            }

            if (-not $verified) {
                throw "CRX signature verification failed for extension ID '$ExpectedExtensionId'."
            }

            return $true
        }

        if (-not $matchedId) {
            throw ("No CRX signature was issued by the expected publisher. " +
                "Extension ID '$ExpectedExtensionId' was not among the signing keys.")
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    return $false
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

    Expand-ZipArchive -ZipPath $zipPath -DestinationPath $DestinationPath
}

function Expand-ZipArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    $destinationRoot = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $DestinationPath).Path.TrimEnd('\') + '\')

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        # Validate every entry before writing anything: a crafted archive must
        # not be able to place files outside the destination (zip slip).
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) {
                continue
            }

            $target = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($destinationRoot, $entry.FullName))

            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry '$($entry.FullName)' resolves outside the destination directory."
            }
        }

        foreach ($entry in $archive.Entries) {
            $target = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($destinationRoot, $entry.FullName))

            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }

            $parent = [System.IO.Path]::GetDirectoryName($target)
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
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

function Invoke-WidevineDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Urls,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    $expected = $ExpectedSha256.ToLowerInvariant()
    $failures = New-Object System.Collections.Generic.List[string]

    # Invoke-WebRequest renders a progress bar per chunk on PowerShell 5.1,
    # which dominates runtime on multi-megabyte downloads.
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        foreach ($url in $Urls) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $DestinationPath -TimeoutSec 120
            } catch {
                $failures.Add("$url : $($_.Exception.Message)")
                continue
            }

            $actual = Get-Sha256Hex -Path $DestinationPath
            if ($actual -eq $expected) {
                return $url
            }

            $failures.Add("$url : hash mismatch (expected '$expected', got '$actual')")
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $ProgressPreference = $previousProgress
    }

    throw "Widevine download failed from all $($Urls.Count) mirror(s):`n  " + ($failures -join "`n  ")
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
    # Dry-run support is threaded through the caller's own ShouldProcess result
    # and passed in as -WhatIfMode, so this does not declare SupportsShouldProcess.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
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

$ScheduledTaskName = 'HeliumWidevineUpdate'

function Register-WidevineUpdateTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedTarget,

        [string]$ResolvedBinaryPath
    )

    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'The ScheduledTasks module is unavailable, so the update task cannot be registered.'
    }

    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-WindowStyle'
        'Hidden'
        '-File'
        ('"{0}"' -f $ScriptPath)
        '-Target'
        $ResolvedTarget
        '-SkipIfBrowserRunning'
    )

    if ($ResolvedBinaryPath) {
        $argumentList += @('-TargetBinaryPath', ('"{0}"' -f $ResolvedBinaryPath))
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argumentList -join ' ')

    # Weekly, plus a logon trigger so a machine that was off still catches up.
    $triggers = @(
        (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '03:00')
        (New-ScheduledTaskTrigger -AtLogOn)
    )

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $ScheduledTaskName `
        -Action $action `
        -Trigger $triggers `
        -Settings $settings `
        -Principal $principal `
        -Description 'Keeps the Widevine CDM in Helium current with Google component releases.' `
        -Force | Out-Null

    return $ScheduledTaskName
}

function Unregister-WidevineUpdateTask {
    if (-not (Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        return $false
    }

    if (-not (Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue)) {
        return $false
    }

    Unregister-ScheduledTask -TaskName $ScheduledTaskName -Confirm:$false
    return $true
}

# Dot-sourcing this file loads its functions for testing without running the
# installer. Everything above this line is declarations; everything below acts.
if ($MyInvocation.InvocationName -eq '.') {
    return
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

if ($RemoveScheduledTask) {
    [pscustomobject]@{
        ScheduledTask = $ScheduledTaskName
        Removed       = (Unregister-WidevineUpdateTask)
    }

    if (-not $InstallScheduledTask) {
        return
    }
}

if (-not $WhatIfPreference -and $targetBinaryPath -and (Test-TargetRunning -BinaryPath $targetBinaryPath)) {
    # The scheduled task runs unattended, where a running browser is an ordinary
    # "try again later" rather than a failure worth reporting to Task Scheduler.
    if ($SkipIfBrowserRunning) {
        [pscustomobject]@{
            Target           = $resolvedTarget
            TargetBinaryPath = $targetBinaryPath
            Changed          = $false
            Skipped          = 'Target browser is running.'
        }
        return
    }

    throw "Close the target browser before installing Widevine. Running binary: '$targetBinaryPath'."
}

if ($InstallScheduledTask) {
    $registeredTask = Register-WidevineUpdateTask `
        -ScriptPath $PSCommandPath `
        -ResolvedTarget $resolvedTarget `
        -ResolvedBinaryPath $targetBinaryPath

    [pscustomobject]@{
        ScheduledTask = $registeredTask
        Registered    = $true
        RunsAs        = ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        Schedule      = 'Weekly (Sunday 03:00) and at logon'
    }
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
New-Item -ItemType Directory -Force -Path $targetWidevineRoot | Out-Null

# Stage inside the target root so the final swap is a same-volume rename.
# %TEMP% is frequently on a different drive, which would make Move fail.
$stagePath = Join-Path $targetWidevineRoot ('.stage-' + [guid]::NewGuid().ToString('N'))

try {
    $downloadUrl = Invoke-WidevineDownload `
        -Urls $download.Urls `
        -DestinationPath $crxPath `
        -ExpectedSha256 $download.Sha256

    # The SHA-256 above only proves the bytes match what the update server
    # described. This proves Google actually signed them.
    [void](Test-Crx3Signature -CrxPath $crxPath -ExpectedExtensionId $WidevineAppId)

    Expand-Crx3Archive -CrxPath $crxPath -DestinationPath $stagePath

    $manifestVersion = Get-WidevineManifestVersion -VersionDirectory $stagePath
    if ($manifestVersion -ne $download.Version) {
        throw "Widevine manifest version '$manifestVersion' does not match the update response '$($download.Version)'."
    }

    if (-not (Test-WidevineLayout -VersionDirectory $stagePath -Architecture $resolvedArchitecture)) {
        throw "Extracted Widevine payload is missing required files for architecture '$resolvedArchitecture'."
    }

    $backupDirectory = $null
    if (Test-Path -LiteralPath $destinationVersionDirectory) {
        if ($NoBackup) {
            Remove-Item -LiteralPath $destinationVersionDirectory -Recurse -Force
        } else {
            $backupDirectory = Backup-VersionDirectory -SourceDirectory $destinationVersionDirectory -ResolvedBackupRoot $resolvedBackupRoot
        }
    }

    # Atomic within the volume: the destination never exists in a partial state.
    [System.IO.Directory]::Move($stagePath, $destinationVersionDirectory)

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
        DownloadUrl          = $downloadUrl
        DestinationDirectory = $destinationVersionDirectory
        Changed              = $true
        BackupDirectory      = $backupDirectory
        WorkDirectory        = if ($KeepWorkDir) { $workRoot } else { $null }
    }
} finally {
    if (Test-Path -LiteralPath $stagePath) {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $workRoot) -and -not $KeepWorkDir) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
