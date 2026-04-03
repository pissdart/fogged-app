[Setup]
AppName=Fogged VPN
AppVersion=1.0.0
AppPublisher=Fogged
DefaultDirName={autopf}\Fogged VPN
DefaultGroupName=Fogged VPN
OutputDir=..\..\build\installer
OutputBaseFilename=Fogged-Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Fogged.exe
PrivilegesRequired=lowest
WizardStyle=modern

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs

[Icons]
Name: "{group}\Fogged VPN"; Filename: "{app}\Fogged.exe"
Name: "{autodesktop}\Fogged VPN"; Filename: "{app}\Fogged.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create desktop shortcut"; GroupDescription: "Additional:"; Flags: checked

[Run]
Filename: "{app}\Fogged.exe"; Description: "Launch Fogged VPN"; Flags: nowait postinstall skipifsilent
