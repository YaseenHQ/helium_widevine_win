# winget submission

These are templates, not submittable as-is. They live here so the values that
must change per release are in one place.

## Publishing a version

1. Tag the release (`git tag v1.0.0 && git push --tags`). The Release workflow
   builds `HeliumWidevineSetup-<version>.exe` and publishes it with a
   `checksums.txt`.

2. Render the manifests. This reads the installer's hash from the release,
   uppercases it as winget requires, and writes submission-ready files to
   `dist/winget/<version>/`, leaving the templates here untouched:

   ```powershell
   .\packaging\Update-WingetManifest.ps1 -Version 1.0.0 -FromRelease
   ```

   Drop `-FromRelease` to use a local `dist/checksums.txt` from
   `Build-Release.ps1` instead. The script fails rather than emitting a
   half-filled manifest if any placeholder is left unreplaced.

3. Validate, then submit:

   ```powershell
   winget validate --manifest .\dist\winget\1.0.0
   winget install --manifest .\dist\winget\1.0.0   # optional local install test
   ```

   Open a PR against [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs)
   placing the three files under
   `manifests/y/YaseenHQ/HeliumWidevine/<version>/`.

   [wingetcreate](https://github.com/microsoft/winget-create) can submit the
   rendered manifests, or handle both the update and the PR in one step:

   ```powershell
   wingetcreate submit .\dist\winget\1.0.0
   ```

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
