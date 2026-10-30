# MemoNest 备忘录 · Flutter 版

同一份便签应用的 Flutter 重写版，与仓库根目录的 Python/Tk 版**并行维护**，
共用同一份磁盘数据格式——两版可以指向同一个 `data/` 目录，随时换版本不丢数据。

## 为什么单独一份

Python 版用 Tk + 原生 RichEdit 接 TSF，中文输入走系统候选窗，体积小、启动快；
Flutter 版换来更少的运行依赖、跨平台余地和更现代的排版能力，
代价是要重写全部界面逻辑，并且失去 Tk 版那套原生 RichEdit 光标/菜单定制。

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
备份包布局与目录同步。

## 构建（Windows）

**源码目录含中文时直接构建会失败**（`Unable to read file: ...\锟斤拷锟斤拷录\...`，
Dart 内核编译拿到乱码路径，`mklink /J` 也绕不过去）。可行做法是复制到纯 ASCII
目录再构建：

```powershell
$src = 'C:\Users\<you>\Documents\备忘录\flutter'
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
test/core_test.dart      18 项单元测试
tool/                    xcompat / backup_demo 这类一次性验证脚本
```
