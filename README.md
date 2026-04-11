# helium-widevine-windows

Windows Widevine installer for Helium.

It downloads Widevine directly from Google's component update service, verifies
the payload hash, extracts the CRX3, and installs a versioned `WidevineCdm`
directory into Helium's user data profile.

## Quick Start

Install for Helium:

```cmd
install-widevine.cmd
```

Reinstall or repair the current version:

```cmd
install-widevine.cmd -Force
```

Uninstall what this installer manages:

```cmd
install-widevine.cmd -Uninstall
```

Uninstall and remove backups:

```cmd
install-widevine.cmd -Uninstall -PurgeBackups
```

## Options

Use a nonstandard Helium binary path:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\use-from-google-chrome.ps1 `
  -TargetBinaryPath "D:\Apps\Helium\Application\chrome.exe"
```

Store backups somewhere else:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\use-from-google-chrome.ps1 `
  -BackupRoot "$env:LOCALAPPDATA\helium-widevine-backups"
```

Keep the temporary work directory:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\use-from-google-chrome.ps1 `
  -KeepWorkDir
```

## Behavior

- If Helium is installed, the script uses its version for the update request.
- If Helium is missing and no `-ProductVersion` is provided, the script falls
  back to the latest Windows Chrome stable version.
- Replaced installs are moved to `WidevineCdm\_backup` by default.
- Temporary download and extraction files are removed automatically unless
  `-KeepWorkDir` is used.
- If multiple Helium installs are detected, the script refuses to guess and
  requires `-TargetBinaryPath`.
- `-Uninstall` only removes installs managed by this script. It uses a marker
  file and refuses to remove untracked layouts.
- The Omaha update request sends OS version, architecture, and memory info to
  Google as part of the standard update protocol.

## Requirements

- Windows (x64 or x86; ARM64 works via x64 emulation)
- PowerShell 5.1 or later
- Internet access to `clients2.google.com` and `versionhistory.googleapis.com`

## Scope

- This installs Widevine only.
- It does not copy files from Chrome, Edge, or Brave.
- It does not override Helium services or proxy update traffic.
- Helium's own `chrome://components` updater behavior is a separate upstream
  issue.
- PlayReady is not handled here. On Windows, PlayReady is integrated through the
  OS media stack, not a copyable `WidevineCdm`-style folder.
