# helium-widevine-windows

Windows Widevine installer for Helium.

It downloads Widevine directly from Google's component update service, verifies
the payload hash, extracts the CRX3, and installs a versioned `WidevineCdm`
directory into Helium's user data profile.

## What you get, and what you don't

**This restores Widevine L3 playback.** That is the ceiling, and no installer
can raise it.

Helium is built with `enable_widevine=true` but ships no CDM, because it has no
licence to redistribute one. Chromium's component installer scans
`<User Data>\WidevineCdm\` at startup, picks the highest version-named
subdirectory with a valid manifest, and registers it. This script fills that
directory, so the CDM registers exactly as if Chrome's own updater had
installed it.

What it cannot do is get you **L1 / verified media path**. On Windows the CDM
performs *host verification* against Google-signed `.sig` files for the
browser's own binaries. Those come from Google's signing infrastructure and
Helium cannot have them, so the CDM runs unverified and falls back to L3
software decryption.

In practice that means:

- Netflix tops out around 540p-720p
- Disney+, Max and Prime Video behave similarly
- A few services refuse playback outright rather than downgrade

If you need 1080p+ on those services, this is a signing and licensing gate, not
a missing-files problem. Please don't file that as a bug here.

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

## Keeping it up to date

Google ships new Widevine builds periodically, so a one-off install will fall
behind. The installer can register a scheduled task that re-runs it:

```cmd
install-widevine.cmd -InstallScheduledTask
```

The task runs weekly (Sunday 03:00) and at logon, as the current user, with no
window. If Helium is running when it fires, it exits cleanly and retries on the
next trigger instead of reporting a failure.

Remove it with:

```cmd
install-widevine.cmd -RemoveScheduledTask
```

## Options

Use a nonstandard Helium binary path:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\Install-Widevine.ps1 `
  -TargetBinaryPath "D:\Apps\Helium\Application\chrome.exe"
```

Store backups somewhere else:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\Install-Widevine.ps1 `
  -BackupRoot "$env:LOCALAPPDATA\helium-widevine-backups"
```

Keep the temporary work directory:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\Install-Widevine.ps1 `
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

- Windows x64, x86, or ARM64. Google publishes a separate `win_arm64` CDM and
  Helium ships a native ARM64 build; the installer matches the CDM to the
  architecture of the target binary rather than assuming emulation.
- PowerShell 5.1 or later
- Internet access to `clients2.google.com` and `versionhistory.googleapis.com`

## Scope

- This installs Widevine only, at L3. See the ceiling described above.
- It does not copy files from Chrome, Edge, or Brave.
- It does not override Helium services or proxy update traffic.
- Helium's own `chrome://components` updater behavior is a separate upstream
  issue.
- PlayReady is not handled here. On Windows, PlayReady is integrated through the
  OS media stack, not a copyable `WidevineCdm`-style folder.
