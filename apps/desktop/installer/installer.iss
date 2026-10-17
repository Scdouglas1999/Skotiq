#define MyAppName "Skotiq"
#define MyAppVersion "4.2.0"
#define MyAppPublisher "Skotiq"
#define MyAppExeName "skotiq_desktop.exe"
#define ReleaseDir "..\\build\\windows\\x64\\runner\\Release"

[Setup]
AppId={{301F4A2B-7E43-46E3-B0BB-74EAE26D45A0}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Skotiq
DefaultGroupName=Skotiq
OutputDir=..\build\installer
OutputBaseFilename=SkotiqSetup
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked
Name: "startmenu"; Description: "Create a &Start Menu shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Skotiq"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu
Name: "{commondesktop}\Skotiq"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Skotiq"; Flags: nowait postinstall skipifsilent unchecked









