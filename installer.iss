; VM Setup Suite - Inno Setup 6
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "dist"
#endif
#define MyAppName "VM Setup Suite"
#define MyAppExeName "VMSetupSuite.exe"

[Setup]
AppId={{B7D2F3E4-22BB-4C3D-8A1F-6E7F8A9B0C12}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=vm technology
DefaultDirName={autopf}\VM Setup Suite
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputBaseFilename=VMSetupSuite_Setup_{#MyAppVersion}
SetupIconFile={#SourceDir}\app.ico
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
MinVersion=10.0
DisableProgramGroupPage=yes

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\VMSetupSuite.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\VMSetup.Engine.psm1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\VMSetup.CLI.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\GUI.xaml"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\logo.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\app.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\Avvia-CLI.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\Profili"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
