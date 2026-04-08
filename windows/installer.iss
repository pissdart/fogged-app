; Fogged VPN Windows Installer (Inno Setup)
; Compile with: iscc installer.iss

[Setup]
AppId={{F0GGED-VPN-2026}
AppName=Fogged VPN
AppVersion=1.1.0
AppPublisher=Fogged
AppPublisherURL=https://fogged.net
DefaultDirName={autopf}\Fogged
DefaultGroupName=Fogged VPN
OutputBaseFilename=Fogged-Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
SetupIconFile=..\assets\logo.ico
UninstallDisplayIcon={app}\fogged.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "Start Fogged on Windows login"; GroupDescription: "System:"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\target\release\orcax-connect.exe"; DestDir: "{app}\bin"; Flags: ignoreversion

[Icons]
Name: "{group}\Fogged VPN"; Filename: "{app}\fogged.exe"
Name: "{autodesktop}\Fogged VPN"; Filename: "{app}\fogged.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "FoggedVPN"; ValueData: """{app}\fogged.exe"""; Tasks: autostart

[Run]
Filename: "{app}\fogged.exe"; Description: "Launch Fogged VPN"; Flags: nowait postinstall skipifsilent
