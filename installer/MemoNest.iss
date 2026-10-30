#define MyAppName "MemoNest 备忘录"
#define MyAppVersion "2.0.0"
#define MyAppPublisher "P4rfa1t"
#define MyAppExeName "MemoNest.exe"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\MemoNest
DefaultGroupName=MemoNest
DisableProgramGroupPage=yes
OutputDir=dist\installer
OutputBaseFilename=MemoNest-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"
Name: "autostart"; Description: "开机自动启动"; GroupDescription: "附加任务:"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MemoNest 备忘录"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\MemoNest 备忘录"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 MemoNest"; Flags: nowait postinstall skipifsilent
EOF