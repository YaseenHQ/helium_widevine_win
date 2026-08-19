; Inno Setup script for helium-widevine-windows.
;
; Per-user by design: the installer only ever writes to %LOCALAPPDATA%, so it
; needs no elevation and does not touch machine state.
;
; Build with:  iscc /DAppVersion=1.0.0 packaging\HeliumWidevine.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Helium Widevine"
#define AppPublisher "YaseenHQ"
#define AppUrl "https://github.com/YaseenHQ/helium_widevine_win"
#define ScriptName "Install-Widevine.ps1"

[Setup]
AppId={{8E4B2C71-5F3D-4A96-9C1E-7D0A6B45E832}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=HeliumWidevineSetup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Never require admin: everything lands under the user's profile.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible arm64 x86compatible
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#ScriptName}
SetupMutex=HeliumWidevineSetupMutex

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "installnow"; Description: "Install Widevine into Helium now"; GroupDescription: "Actions:"
Name: "scheduledtask"; Description: "Keep Widevine up to date automatically (weekly)"; GroupDescription: "Actions:"

[Files]
Source: "..\{#ScriptName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install-widevine.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Install Widevine into Helium"; Filename: "{app}\install-widevine.cmd"
Name: "{group}\Uninstall Widevine"; Filename: "{app}\install-widevine.cmd"; Parameters: "-Uninstall"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"

[Run]
; Order matters: install the CDM first, then register the updater, so a first
; run failure is surfaced before a task is scheduled to repeat it.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"""; \
  StatusMsg: "Downloading and installing Widevine..."; \
  Flags: runhidden waituntilterminated; \
  Tasks: installnow

Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"" -InstallScheduledTask"; \
  StatusMsg: "Registering the automatic update task..."; \
  Flags: runhidden waituntilterminated; \
  Tasks: scheduledtask

[UninstallRun]
; Remove the scheduled task before the script it invokes disappears.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"" -RemoveScheduledTask"; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "RemoveWidevineTask"

Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"" -Uninstall"; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "RemoveWidevineCdm"

[Code]
function InitializeSetup(): Boolean;
var
  Version: Cardinal;
begin
  Result := True;

  // The script targets Windows PowerShell 5.1, present on every supported
  // Windows release. Check anyway so the failure is legible if it is missing.
  if not RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine',
                            'PSCompatibleVersion', Version) then
  begin
    if not RegKeyExists(HKLM, 'SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine') then
    begin
      if MsgBox('Windows PowerShell 5.1 could not be detected. Continue anyway?',
                mbConfirmation, MB_YESNO) = IDNO then
        Result := False;
    end;
  end;
end;
