#define MyAppName "MemoNest 备忘录"
#define MyAppVersion "2.1.0"
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
OutputDir=..\dist\installer
OutputBaseFilename=MemoNest-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
; choco 装的 Inno Setup 6 不带简体中文（官方仓库里它在 Languages 下，但安装包只
; 分发 Default.isl）。这份 isl 随仓库走，相对路径引它，CI 与本机都不依赖外部下载。
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"
Name: "autostart"; Description: "开机自动启动"; GroupDescription: "附加任务:"

[Files]
; 相对 iss 自己所在的 installer\ 目录，..\build 才是 Flutter 的产物目录。
;
; Excludes 里的几项是用户数据：Release\data 下除了 Flutter 自己的 flutter_assets
; 和 icudtl.dat，还会被运行中的应用写成数据根目录（它按 exe 旁边有没有 data\
; 来判断应用根）。本地构建时跑过一次就有 notes\、backups\、index.json 了，
; 不打掉的话这些笔记会被装到每个用户的机器上。
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "data\notes\*,data\trash\*,data\backups\*,data\index.json,data\memo.log,data\vault\*,data\trace.txt,data\quit-trace.txt"

[Icons]
Name: "{group}\MemoNest 备忘录"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 MemoNest"; Filename: "{uninstallexe}"
Name: "{autodesktop}\MemoNest 备忘录"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "MemoNest"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 MemoNest"; Flags: nowait postinstall skipifsilent