#Requires -Modules Pester

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-Widevine.ps1'
    . $script:ScriptPath
}

Describe 'Resolve-WidevineArchitecture' {
    It 'keeps arm64 rather than downgrading it to x64' {
        # Google publishes a distinct win_arm64 CDM and Helium ships a native
        # ARM64 build, so downgrading here installs an unloadable binary.
        Mock Get-PeArchitecture { 'arm64' }
        Mock Test-Path { $true }
        Resolve-WidevineArchitecture -BinaryPath 'C:\fake\chrome.exe' | Should -Be 'arm64'
    }

    It 'mirrors the target binary architecture for x64' {
        Mock Get-PeArchitecture { 'x64' }
        Mock Test-Path { $true }
        Resolve-WidevineArchitecture -BinaryPath 'C:\fake\chrome.exe' | Should -Be 'x64'
    }

    It 'mirrors the target binary architecture for x86' {
        Mock Get-PeArchitecture { 'x86' }
        Mock Test-Path { $true }
        Resolve-WidevineArchitecture -BinaryPath 'C:\fake\chrome.exe' | Should -Be 'x86'
    }

    It 'falls back to the host architecture when no binary is given' {
        Resolve-WidevineArchitecture -BinaryPath $null |
            Should -BeIn @('x64', 'x86', 'arm64')
    }
}

Describe 'Resolve-WidevineDownload' {
    BeforeAll {
        function New-UpdateApp {
            # Test fixture builder; returns an object, changes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param([object[]]$Urls, [string]$Sha256 = ('a' * 64), [string]$Status = 'ok')

            [pscustomobject]@{
                updatecheck = [pscustomobject]@{
                    status      = $Status
                    nextversion = '4.10.3050.0'
                    pipelines   = @(
                        [pscustomobject]@{
                            operations = @(
                                [pscustomobject]@{
                                    type = 'download'
                                    urls = $Urls
                                    out  = [pscustomobject]@{ sha256 = $Sha256 }
                                }
                            )
                        }
                    )
                }
            }
        }
    }

    It 'keeps every HTTPS mirror and discards the plaintext duplicates' {
        # Google returns each mirror twice, http first.
        $app = New-UpdateApp -Urls @(
            [pscustomobject]@{ url = 'http://edgedl.me.gvt1.com/a.crx3' }
            [pscustomobject]@{ url = 'https://edgedl.me.gvt1.com/a.crx3' }
            [pscustomobject]@{ url = 'http://dl.google.com/a.crx3' }
            [pscustomobject]@{ url = 'https://dl.google.com/a.crx3' }
            [pscustomobject]@{ url = 'http://www.google.com/dl/a.crx3' }
            [pscustomobject]@{ url = 'https://www.google.com/dl/a.crx3' }
        )

        $result = Resolve-WidevineDownload -UpdateApp $app
        $result.Urls.Count | Should -Be 3
        $result.Urls | ForEach-Object { $_ | Should -BeLike 'https://*' }
    }

    It 'refuses a response offering only plaintext mirrors' {
        $app = New-UpdateApp -Urls @([pscustomobject]@{ url = 'http://dl.google.com/a.crx3' })
        { Resolve-WidevineDownload -UpdateApp $app } | Should -Throw '*HTTPS*'
    }

    It 'refuses a response with no SHA-256, rather than installing unverified' {
        $app = New-UpdateApp `
            -Urls @([pscustomobject]@{ url = 'https://dl.google.com/a.crx3' }) `
            -Sha256 ''
        { Resolve-WidevineDownload -UpdateApp $app } | Should -Throw '*SHA-256*'
    }

    It 'returns nothing when Google reports no update' {
        $app = New-UpdateApp `
            -Urls @([pscustomobject]@{ url = 'https://dl.google.com/a.crx3' }) `
            -Status 'noupdate'
        Resolve-WidevineDownload -UpdateApp $app | Should -BeNullOrEmpty
    }
}

Describe 'Get-Sha256Hex' {
    It 'matches a known digest' {
        $file = Join-Path $TestDrive 'sample.bin'
        [System.IO.File]::WriteAllBytes($file, [byte[]]@(0x61, 0x62, 0x63))  # "abc"
        Get-Sha256Hex -Path $file |
            Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
}

Describe 'Test-WidevineLayout' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $platform = Join-Path $script:Dir '_platform_specific\win_x64'
        New-Item -ItemType Directory -Force -Path $platform | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Dir '_metadata') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'LICENSE') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:Dir '_metadata\verified_contents.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $platform 'widevinecdm.dll') -Value 'x'
        Set-Content -LiteralPath (Join-Path $platform 'widevinecdm.dll.sig') -Value 'x'
    }

    It 'accepts a complete layout' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'manifest.json') -Value (@{
            version                    = '4.10.3050.0'
            'x-cdm-interface-versions' = '10'
            'x-cdm-module-versions'    = '4'
            'x-cdm-codecs'             = 'vp8,vp09,avc1,av01'
        } | ConvertTo-Json)

        Test-WidevineLayout -VersionDirectory $script:Dir -Architecture 'x64' | Should -BeTrue
    }

    It 'rejects a manifest missing the x-cdm keys Chromium requires' {
        # Chromium rejects such a component silently, registering nothing.
        Set-Content -LiteralPath (Join-Path $script:Dir 'manifest.json') -Value (@{
            version = '4.10.3050.0'
        } | ConvertTo-Json)

        Test-WidevineLayout -VersionDirectory $script:Dir -Architecture 'x64' | Should -BeFalse
    }

    It 'rejects a layout for a different architecture' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'manifest.json') -Value (@{
            version                    = '4.10.3050.0'
            'x-cdm-interface-versions' = '10'
            'x-cdm-module-versions'    = '4'
            'x-cdm-codecs'             = 'vp8'
        } | ConvertTo-Json)

        Test-WidevineLayout -VersionDirectory $script:Dir -Architecture 'arm64' | Should -BeFalse
    }
}

Describe 'Expand-ZipArchive' {
    It 'extracts a well-formed archive' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $source = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Force -Path (Join-Path $source 'nested') | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'nested\file.txt') -Value 'payload'

        $zip = Join-Path $TestDrive 'good.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $zip)

        $dest = Join-Path $TestDrive 'out'
        Expand-ZipArchive -ZipPath $zip -DestinationPath $dest
        Get-Content -LiteralPath (Join-Path $dest 'nested\file.txt') | Should -Be 'payload'
    }

    It 'refuses an entry that escapes the destination (zip slip)' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $TestDrive 'evil.zip'
        $stream = [System.IO.File]::Create($zip)
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream, [System.IO.Compression.ZipArchiveMode]::Create)
        $entry = $archive.CreateEntry('..\..\escaped.txt')
        $writer = [System.IO.StreamWriter]::new($entry.Open())
        $writer.Write('pwned')
        $writer.Dispose()
        $archive.Dispose()
        $stream.Dispose()

        $dest = Join-Path $TestDrive 'out-evil'
        { Expand-ZipArchive -ZipPath $zip -DestinationPath $dest } |
            Should -Throw '*outside the destination*'
    }
}

Describe 'Get-WidevineVersionInfo' {
    It 'skips a malformed manifest instead of aborting discovery' {
        $root = Join-Path $TestDrive 'root'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '4.10.3050.0') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root '4.10.2830.0') | Out-Null
        Set-Content -LiteralPath (Join-Path $root '4.10.3050.0\manifest.json') `
            -Value '{ this is not json'
        Set-Content -LiteralPath (Join-Path $root '4.10.2830.0\manifest.json') `
            -Value (@{ version = '4.10.2830.0' } | ConvertTo-Json)

        $info = Get-WidevineVersionInfo -WidevineRoot $root
        $info.Version | Should -Be '4.10.2830.0'
    }

    It 'selects the highest version numerically, not lexically' {
        $root = Join-Path $TestDrive 'root2'
        foreach ($v in @('4.10.9.0', '4.10.10.0')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $v) | Out-Null
            Set-Content -LiteralPath (Join-Path $root "$v\manifest.json") `
                -Value (@{ version = $v } | ConvertTo-Json)
        }

        (Get-WidevineVersionInfo -WidevineRoot $root).Version | Should -Be '4.10.10.0'
    }

    It 'returns nothing for an empty root' {
        $root = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Get-WidevineVersionInfo -WidevineRoot $root | Should -BeNullOrEmpty
    }
}
