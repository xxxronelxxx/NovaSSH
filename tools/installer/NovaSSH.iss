#define MyAppName "Nova SSH"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef RepoRoot
  #define RepoRoot "..\.."
#endif
#ifndef SourceDir
  #define SourceDir RepoRoot + "\dist\NovaSSH"
#endif
#ifndef OutputDir
  #define OutputDir RepoRoot + "\dist"
#endif

[Setup]
AppId={{9F7A3C52-1B4E-4D7A-8E2F-3A6C5B9D1E40}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=NovaSSH
AppPublisherURL=https://github.com/xxxronelxxx/NovaSSH
AppSupportURL=https://github.com/xxxronelxxx/NovaSSH
AppUpdatesURL=https://github.com/xxxronelxxx/NovaSSH
DefaultDirName={localappdata}\Programs\NovaSSH
DefaultGroupName=Nova SSH
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=NovaSSH-{#MyAppVersion}-windows-x64-installer
SetupIconFile={#RepoRoot}\icons\icon.ico
UninstallDisplayIcon={app}\NovaSSH.exe
UninstallDisplayName={#MyAppName} {#MyAppVersion}
VersionInfoVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoCompany=NovaSSH
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "profile,profile\*"

[Icons]
Name: "{group}\Nova SSH"; Filename: "{app}\NovaSSH.exe"
Name: "{group}\Удалить Nova SSH"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Nova SSH"; Filename: "{app}\NovaSSH.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\NovaSSH.exe"; Description: "{cm:LaunchProgram,Nova SSH}"; Flags: nowait postinstall skipifsilent
