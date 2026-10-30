# MemoNest 备忘录

桌面便签应用。Tk 版已经退役，本仓库只剩 Flutter 实现；磁盘数据格式沿用了
Tk 版的布局，所以旧的 `data/` 目录可以直接拿来用，不用迁移。

## OneDrive 备份的两种模式

设置 → OneDrive 里可以选同步方式：

- **本地文件夹**：把备份复制进 OneDrive 同步文件夹（`%OneDrive%` 或手填路径），
  由 OneDrive 客户端负责上传，不需要登录。
- **账号登录**：走 Microsoft Graph，直接传到云端，不依赖本机 OneDrive 客户端。
  填一个 Azure 应用（客户端）ID 后点「登录」，会在本机开一个回环端口并调起浏览器，
  授权完自动回调，不用抄设备码；浏览器调不起来时点下面的「改用设备代码登录」兜底。
  令牌存本地 `config.json`，过期自动用 `refresh_token` 续。

Graph 模式的同步逻辑与 Obsidian 的 Remotely Save 一致：本地记一份
`data/onedrive-sync.json` 基线（相对路径 → `大小:mtime`），每次只传变化的文件，
本地上次有、这次没有的就从云端删掉。所以它更接近双向同步而不是整包备份。

同步范围可选两种，在设置里切：

- **App 文件夹**（默认，权限最小）：`Files.ReadWrite.AppFolder`，云端落在
  `Apps/MemoNest/`，微软分配的独立目录，应用看不到云盘其它内容。
- **整个 OneDrive**：`Files.ReadWrite`，落在云盘根目录的 `MemoNest/`（子目录名可改），
  和其它同步来的笔记平级。

上传内容：`notes/*.md` 明文镜像（可在设置里关掉）、`notes/assets/` 里的图片、
`index.json`、`vault/items/*.mdenc` 密文与去掉 `dpapi_key` 的 `vault.json`，
以及 `memo-backup-*.zip` 快照（按「云端保留备份数」清理旧的）。私密库密钥始终留在本机。
超过 250 MB 的单个文件走 `createUploadSession` 分块上传。

## 与 Python 版的兼容点

这些是逐字节对齐的，任何一边改动都要同步另一边：

- 便签文件：`data/notes/<slug>-<id6>.md`，YAML 风格头部 + 正文
- 索引：`data/index.json`，`{"version": 1, "notes": [...]}`
- 回收站：`data/trash/*.md`
- 私密库元数据：`data/vault/vault.json`，scrypt `N=2^15, r=8, p=1`，密钥 32 字节，
  `wrapped_key` 用 `key_tag = sha256(b"memonest-key-tag" + key)[:16]` 校验
- 私密便签密文：`data/vault/items/<id>.mdenc`，`nonce(12) || ciphertext || tag(16)`，
  AAD 为 `memonest-note-v1` + noteId（回收站用 `memonest-trash-v1`）
- 备份包：`memo-backup-<yyyyMMdd-HHmmss>.zip`，内含 `notes/`、`index.json`、
  `vault/items/`、`vault/vault.json`（去掉 `dpapi_key`）
- 配置：`config.json`，三段 `onedrive` / `github` / `general`

`tool/xcompat.dart` 与仓库根的 `tools/xcompat.py` 是一对：一方写、另一方读，
用来验证上面的格式没有走样。

## 开发

```bash
flutter pub get
dart analyze .        # 本机 flutter analyze 会因中文路径崩，用 dart analyze
flutter test
```

`flutter test` 覆盖时间格式、Markdown 解析、明文库读写、加密库加解密与改密码、
备份包布局与目录同步，以及 Graph 客户端（设备代码登录、令牌续期、目录上传、
同步与清理）。Graph 的测试不看网络：用本地 `HttpServer` 模拟微软的端点，
走真实的 HTTP 路径，所以编码、状态码、错误分支都是真在跑。

## 构建（Windows）

**源码目录含中文时直接构建会失败**（`Unable to read file: ...\锟斤拷锟斤拷录\...`，
Dart 内核编译拿到乱码路径，`mklink /J` 也绕不过去）。可行做法是复制到纯 ASCII
目录再构建：

```powershell
$src = 'C:\Users\<you>\Documents\备忘录'
robocopy $src C:\mnbuild /E /XD "$src\build" "$src\.dart_tool" C:\mnbuild\build C:\mnbuild\.dart_tool
Set-Location C:\mnbuild
flutter build windows --release
```

`robocopy` 要在 PowerShell 里跑，bash 会破坏它的参数。

产物在 `build\windows\x64\runner\Release\`，整目录约 28 MB
（`MemoNest.exe` + `flutter_windows.dll` + `data\` + 四个插件 dll）。

`windows/CMakeLists.txt` 里必须有 `target_compile_options(${TARGET} PRIVATE /utf-8)`：
源码里有中文注释与中文窗口标题，MSVC 按 GBK 读会报 `C4819`/`C2001` 并被当成错误。

## 目录

```
lib/
  main.dart              窗口初始化、退出前落盘
  app_state.dart         两个库、当前便签、搜索、自动保存、备份调度
  core/                  纯 Dart：模型、路径、配置、加密、Markdown、两个库、备份
  platform/              FFI：剪贴板图片、注册表自启、桌面快捷方式
  ui/                    主题、主窗口、编辑区、Markdown 预览、各面板
test/core_test.dart      18 项单元测试（模型、库、加密、备份）
test/onedrive_test.dart  20 项 Graph 客户端测试，打本地假服务器
tool/                    xcompat / backup_demo 这类一次性验证脚本
```
