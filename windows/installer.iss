; Fogged VPN Windows Installer (Inno Setup)
; Built automatically by CI — do not compile manually unless testing

#define MyAppName "Fogged VPN"
#define MyAppExeName "orcax.exe"
#define MyAppPublisher "Fogged"
#define MyAppURL "https://fogged.net"

[Setup]
AppId={{F0GGED-VPN-2026}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={localappdata}\Fogged
DefaultGroupName={#MyAppName}
OutputBaseFilename=Fogged-Setup
OutputDir=.
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=lowest
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern
DisableProgramGroupPage=yes
ArchitecturesInstallIn64BitMode=x64compatible

; Code-sign the installer + the uninstaller when a signing profile is
; configured. Inno Setup looks up the tool name by the first token.
; Configure FOGGED_SIGNTOOL on the build host, e.g.:
;   iscc /DSignTool="signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /a $f" installer.iss
; Or put the tool into Inno's [Code] config. Both installer and uninstaller
; will be signed when SignTool= is set.
SignTool=fogged_signtool
SignedUninstaller=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "autostart"; Description: "Start Fogged VPN on Windows login"; GroupDescription: "System:"

[Files]
; Flutter app + all DLLs (relative to repo root where iscc is called)
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "FoggedVPN"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Clean up system proxy on uninstall
Filename: "reg"; Parameters: "add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"" /v ProxyEnable /t REG_DWORD /d 0 /f"; Flags: runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
