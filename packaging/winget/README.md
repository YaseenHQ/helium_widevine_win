# winget submission

These are templates, not submittable as-is. They live here so the values that
must change per release are in one place.

## Publishing a version

1. Tag the release (`git tag v1.0.0 && git push --tags`). The Release workflow
   builds `HeliumWidevineSetup-<version>.exe` and publishes it with a
   `checksums.txt`.

2. Fill in the placeholders in all three manifests:

   | Placeholder | Source |
   |---|---|
   | `__VERSION__` | The release version, without the `v` |
   | `__SHA256__` | The installer's line in the release `checksums.txt` |
   | `__RELEASE_DATE__` | The release date, `YYYY-MM-DD` |

   ```powershell
   $version = '1.0.0'
   $sha = (Select-String -Path .\dist\checksums.txt -Pattern 'HeliumWidevineSetup').Line.Split(' ')[0]

   Get-ChildItem .\packaging\winget\*.yaml | ForEach-Object {
       (Get-Content $_ -Raw).
           Replace('__VERSION__', $version).
           Replace('__SHA256__', $sha.ToUpperInvariant()).
           Replace('__RELEASE_DATE__', (Get-Date -Format 'yyyy-MM-dd')) |
       Set-Content $_.FullName
   }
   ```

   Note winget expects `InstallerSha256` in uppercase.

3. Validate, then submit:

   ```powershell
   winget validate --manifest .\packaging\winget
   winget install --manifest .\packaging\winget   # optional local install test
   ```

   Open a PR against [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs)
   placing the three files under
   `manifests/y/YaseenHQ/HeliumWidevine/<version>/`.

   [wingetcreate](https://github.com/microsoft/winget-create) can automate both
   the update and the PR:

   ```powershell
   wingetcreate update YaseenHQ.HeliumWidevine `
     --version 1.0.0 `
     --urls https://github.com/YaseenHQ/helium_widevine_win/releases/download/v1.0.0/HeliumWidevineSetup-1.0.0.exe `
     --submit
   ```

## First submission

The first PR for a new package identifier gets more scrutiny than later
updates. Two things are worth pre-empting in the PR description, because a tool
that downloads a DRM binary into a browser directory invites both questions:

- Nothing proprietary is redistributed. The CDM is fetched at run time from
  Google's own component update service, the same endpoint Chrome uses.
- The download is verified twice, by SHA-256 and by Google's CRX3 signature.

## Scope note

`Scope: user` is correct and deliberate. The installer is per-user
(`PrivilegesRequired=lowest`) because everything it writes lands under
`%LOCALAPPDATA%`. Do not change this to `machine`.
