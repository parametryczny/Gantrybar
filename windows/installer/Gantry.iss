; Compile with /DLITE to build the Gantry LITE installer instead (iscc /DLITE Gantry.iss). LITE has
; its own AppId, exe and Run entry, so it installs and updates independently of the full Gantry.
#ifdef LITE
  #define MyAppName "Gantry LITE"
  #define MyAppExeName "GantryLite.exe"
  #define MyAppId "{{310C91F4-6ACC-47B2-B50B-8BA450D1269B}"
  #define MyOutputBase "Gantry-LITE-Setup-Windows-x64"
  #define MyRunValue "GantryLite"
#else
  #define MyAppName "Gantry"
  #define MyAppExeName "Gantry.exe"
  #define MyAppId "{{D83CD1A0-DC31-4A57-A152-8B7EE75046F1}"
  #define MyOutputBase "Gantry-Setup-Windows-x64"
  #define MyRunValue "Gantry"
#endif
#define MyAppVersion "0.11.0"
#define MyAppPublisher "Kamil Grzegorczyk"
#define MyAppURL "https://github.com/parametryczny/gantrybar"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion} Windows Beta
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\installer-output
OutputBaseFilename={#MyOutputBase}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\Gantry.Windows\gantry.ico
CloseApplications=yes
RestartApplications=no
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion=0.11.0.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Windows Beta Installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoCopyright=Copyright (C) 2026 Kamil Grzegorczyk
LicenseFile=..\..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"

[Files]
; Package the whole self-contained folder (not a self-extracting single-file exe) — the self-extract
; pattern is the main trigger for Avast/SmartScreen false positives (issue #20).
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyRunValue}"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue
; Remove the pre-rebrand autostart entry so upgrades don't leave a duplicate BambuBar launch.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "BambuBar"; Flags: deletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
