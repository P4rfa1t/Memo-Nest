; MemoNest 安装包脚本（Inno Setup 6.5+）
; 由 build_installer.ps1 调用，版本号通过 /DMyAppVersion=x.y.z 传入。
;
; 设计要点：
;   * 按用户安装到 %LOCALAPPDATA%\Programs\MemoNest，可写，不需要管理员权限；
;   * 程序目录固定，用户数据仍写在 exe 旁边的 data\ 与 config.json；
;   * 卸载只删除程序文件，默认保留 data\ 和 config.json；
;   * 卸载时清理开机自启写入的 HKCU Run 项。

#ifndef MyAppVersion
  #define MyAppVersion "1.3.2"
#endif

#define MyAppName "MemoNest 备忘录"
#define MyAppShortName "MemoNest"
#define MyAppPublisher "P4rfa1t"
#define MyAppURL "https://github.com/P4rfa1t/Memo-Nest"
#define MyAppExeName "MemoNest.exe"
#define MyAppId "{{6D7B1C2E-6F4A-4B3E-9D20-8A4C5E7F1A92}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppShortName}
DefaultGroupName={#MyAppShortName}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
OutputDir=..\dist\installer
OutputBaseFilename={#MyAppShortName}-Setup-{#MyAppVersion}
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no
AllowNoIcons=yes
VersionInfoVersion={#MyAppVersion}.0
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} 安装程序

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："

[InstallDelete]
; 保证 onedir 升级时不残留旧版本的 _internal 文件；用户数据不在此目录。
Type: filesandordirs; Name: "{app}\_internal"

[Files]
; 只安装程序本体。开发目录里的 data\ 和 config.json 绝不能打进安装包。
Source: "..\dist\MemoNest\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "data\*,config.json,config.json.tmp"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; 程序内“开机自启”写的是 HKCU Run 项，卸载时一并清理。
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "MemoNest"; Flags: dontcreatekey uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 只清理临时文件；data\ 与 config.json 有意保留。
Type: files; Name: "{app}\config.json.tmp"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and (not UninstallSilent) then
    MsgBox('MemoNest 已卸载。' + #13#10 + #13#10 +
      '你的便签数据仍保留在：' + #13#10 + ExpandConstant('{app}') + #13#10 + #13#10 +
      '如需彻底删除，请手动删除该文件夹。',
      mbInformation, MB_OK);
end;
