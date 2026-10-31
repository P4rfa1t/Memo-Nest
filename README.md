# MemoNest 备忘录

便签应用，一份代码跑 Windows / Linux / Android。Tk 版已经退役，本仓库只剩
Flutter 实现；磁盘数据格式沿用了 Tk 版的布局，所以旧的 `data/` 目录可以直接
拿来用，不用迁移，三个平台之间也能直接拷。

## 导入现有 Markdown

「⋯ → 导入 Markdown…」能一次选一个或多个 `.md`
（也接受 `.markdown` 与 `.txt`），每个文件变成一篇便签。
标题按 `guessTitle()` 的规则猜：第一个标题行（开头的 `#`），
没有就取第一行前 60 字，再没有就用文件名。

正文一字不改。MemoNest 把标题和正文分开存，所以不会把
`# 标题` 那行抽走——抽了就拆了原本的 Markdown 结构，
导出回去就对不上了。导入到哪个库取决于当前选中的「便签 / 私密」：
在私密库里导入就直接落进加密库。

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

## GitHub 备份：双向同步，不是整包覆盖

设置 → GitHub 里配好 `用户名/仓库` 与 Token 后，「备份」按钮做的是**同步**：
先取回云端，跟本地做三方合并，再把合并结果推上去。之前那版是「本地盖掉云端」，
手机上删掉的便签、另一台机器新写的内容，都会在下一次推送里被静默抹掉。

只有「本地 vs 云端」两份状态时，没法区分两种相反的情形：云端没有这篇，
可能是本地新写的（该上传），也可能是云端删掉的（该本地删）。所以每次同步
成功后在 `data/github-sync.json` 留一份基准点（每篇的 `updated` / `filename`），
下次拿它判**哪一边动过**。

合并规则：

- 只有一边有、且基准点里没有 → 新增，往缺的那边送。
- 只有本地有、基准点有且本地没改过 → 云端删的，本地跟着删。
- 只有本地有、但本地改过 → 云端删了而本地又写了新内容，保住本地、重新上传。
- 两边都有：都没改→以本地为准；只一边改→单向推送；都改且内容不同→
  `updated` 新的留在原文件，旧的那份另存成「（本机副本）」「（云端副本）」
  的新便签。宁可多一篇，也不静默丢字。

删除范围只有 `notes/` 与 `vault/`，仓库里的 `README.md`、`.gitignore` 一律不碰；
`vault/` 更是**只有本地确实有私密库时**才会被清理——否则换台机器登录一次
就把别人云端的密文全删了。

首次同步没有基准点，按「取并集」处理，谁的都不丢。

仓库要是**一个提交都没有**，GitHub 会拒绝整个 Git Data API（建 blob 直接
409 `Git Repository is empty.`），所以第一次会先用 Contents API 落一个种子
文件建出初始提交，再跑正常流程。这一步只发生一次。

两种传输方式，设置里的「同步方式」可以强制指定：

- **git**：调用本机 `git` 推一个工作区（`data/github`），合并仍由 Dart 侧完成。
- **HTTP API**：直接走 GitHub 的 Git Data API（blob/tree/commit/ref），
  不需要 `git` 可执行文件，也不需要把仓库 clone 下来。Android 上默认走这条
  ——手机上根本没有 git。`sha` 相同的文件不会重新上传，也不会重复下载。

远端 blob 的 sha 是本地按 `sha1("blob <长度>\0" + 内容)` 算出来的，
与 `git hash-object` 逐字节一致，所以「这个文件到底变没变」不用下载就能判。

## 私密库的系统凭据解锁

主密码始终是唯一的根密钥，系统验证只是让日常解锁少打几次字：

1. 第一次用主密码解锁（或创建）之后，库密钥会被平台密钥库加密存到
   `data/vault/hello.bin`。Windows 用 DPAPI（`CryptProtectData`，绑当前账户），
   Android 用 Keystore 里的设备绑定 AES-256-GCM 密钥（明文不出 TEE）。拷走文件、
   换个账户、换台机器都解不开。两边的验证都不绑在密钥上：Windows 是
   `UserConsentVerifier` 通过后解 DPAPI，Android 是 `BiometricPrompt` 通过后
   用 Keystore 解密。绑定方式的代价是「换指纹就让密钥作废」，而作废之后
   连主密码兜底的路都会更难走，所以宁可让验证站在密钥前面。
2. 之后再打开「私密」，面板上多一个「用 Windows Hello 解锁」/「用指纹 · 面容解锁」
   按钮，验证通过（Windows 走 `UserConsentVerifier`，Android 走 `BiometricPrompt`）
   就把库密钥取回来。

Linux 没有跨桌面环境的统一验证接口，这个功能在 Linux 上直接隐藏，
回到纯主密码。

几条边界：

- 改主密码不换库密钥，所以 Hello 记录继续有效，不用重新录。
- 重置私密库会换新密钥，`hello.bin` 同时删掉。
- 设置 → 私密库里可以关掉这个开关，关掉即删记录，回到纯主密码。
- 没录入 PIN / 指纹 / 面容时，开关是灰的，面板上也不显示解锁按钮。
- 按钮的显示只看设备能力，不看 `hello.bin` 在不在；第一次解锁时
  还没有托管记录，点下去会提示「请先用主密码解锁一次」。
- `hello.bin` **不进** 备份包/GitHub/OneDrive 的同步内容——它是本机凭据，
  传上去也没用（换个账户就解不开）。

## 离开私密库即上锁

从「私密」切回「便签」时，库密钥立刻从内存里清掉
（`vault.lock()` + `vaultStore = null`），不留「已经切走但密钥还在」的窗口；
下次点「私密」必须重新过一次验证（主密码或系统凭据）。
切走之前会先 `saveCurrent(force: true)`，刚改的内容不会丢。

`Ctrl+L` 与菜单里的「锁定私密笔记库」仍然可用，作用相同。

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

## 跨平台

三个平台共用同一套 Dart 代码，平台差异全部收在 `lib/platform/` 里：

| 能力 | Windows | Linux | Android |
| --- | --- | --- | --- |
| 无边框窗口 / 最小化 / 最大化 | window_manager + `WM_NCHITTEST` | window_manager（GTK） | 无窗口概念，按钮不显示 |
| 标题栏拖动 | Win32 命中测试 | Dart 侧 `startDragging()` | — |
| 开机自启 | 注册表 `HKCU\...\Run` | `~/.config/autostart/*.desktop` | — |
| 桌面快捷方式 | PowerShell 建 `.lnk` | `~/.local/share/applications/*.desktop` | — |
| 剪贴板图片 | `CF_DIB` / `CF_DIBV5` | 不支持（右键菜单不出「粘贴图片」） | 不支持 |
| 系统凭据解锁 | DPAPI + Hello | 不支持 | Keystore + 指纹/面容 |
| 数据目录 | `%LOCALAPPDATA%\Programs\MemoNest` 或 exe 旁 | `~/.local/share` 下的可执行文件旁 | 应用私有目录（path_provider） |

`lib/platform/host.dart` 是接口，`lib/platform/host_io.dart` 按
`Platform.isWindows / isAndroid / isLinux` 选实现。UI 只调接口，不认识平台。

几个踩过的坑写在代码注释里，值得单独说一句：Windows 的标题栏拖动必须交给
`WM_NCHITTEST` 返回 `HTCAPTION`，在 Dart 里调 `startDragging()` 会冻结渲染
线程（之前点顶栏必崩就是这个原因）；Linux 的 GTK 没有等价的命中测试，
所以反过来只能在 Dart 里发起，靠 `Host.titleBarDragInDart` 分开。

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

## 构建（Linux）

需要 GTK3 与常规 C++ 工具链：

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
flutter build linux --release
```

产物在 `build/linux/x64/release/bundle/`，整目录拷走就能跑
（`memonest` + `lib/` + `data/`）。中文路径同样会崩，同样复制到 ASCII 目录再编。

## 构建（Android）

需要 Android SDK（`ANDROID_HOME`）与 JDK 17+：

```bash
flutter build apk --release
```

`minSdk` 是 23（`androidx.biometric` 的要求，Flutter 模板默认 21）。
指纹解锁走 `android/app/src/main/kotlin/.../MainActivity.kt` 里的
`memonest/hello` 通道：`BiometricPrompt` 做验证，Keystore 里的 AES-GCM
密钥加密库密钥，明文不出 TEE。

**发布签名随仓库走**（`android/key.properties` + `android/app/memonest-release.jks`）。
一开始 release 沿用 debug 签名，结果每台机器、每次 CI 构建出来的钥匙都不同，
手机上覆盖安装直接 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`（界面只说「应用未安装」）。
这是个个人离线工具，签名只用来保证「同一个应用身份」，所以这两份文件故意提交，
`.gitignore` 里也用 `!` 放行。要换成自己的：

```bash
keytool -genkeypair -v -keystore android/app/memonest-release.jks \
  -alias memonest -keyalg RSA -keysize 2048 -validity 10950 \
  -storetype PKCS12 -storepass <口令> -dname "CN=..., O=..., C=CN"
```

改完记得同步 `android/key.properties`。另外覆盖安装要求 `versionCode` 不降，
发版时把 `pubspec.yaml` 里的 `version: x.y.z+N` 的 `N` 递增。

Android 上没有「数据目录」可打开，「⋯ → 打开数据文件夹」会退化成把路径
显示在右下角浮层里让你复制。

## 状态提示

备份、导入导出、粘贴图片这类一次性消息走右下角的深色浮层，不再挤在底栏
那行 11px 的小字里——底栏只留字数与行数。浮层按结果上色（成功绿、失败红），
几秒后自己消失，点一下立刻关掉；最多同时三条，重复的消息不会叠在一起。
三个平台共用同一套实现，Android 上会避让底部手势条。

## 目录

```
lib/
  main.dart              窗口初始化、退出前落盘
  app_state.dart         两个库、当前便签、搜索、自动保存、备份调度
  core/                  纯 Dart：模型、路径、配置、加密、Markdown、两个库、备份
  platform/              平台差异：宿主接口、Windows FFI、Linux XDG、Android 通道、PNG 编码
  ui/                    主题、主窗口、编辑区、Markdown 预览、各面板、浮层
test/core_test.dart      18 项单元测试（模型、库、加密、备份）
test/onedrive_test.dart  20 项 Graph 客户端测试，打本地假服务器
test/import_md_test.dart 5 项导入 Markdown
test/github_api_test.dart 9 项 GitHub HTTP API 与同步提交
test/github_sync_test.dart 8 项三方合并规则（新增/删除/冲突/私密库保护）
test/vault_lock_test.dart / vault_panel_hello_test.dart
                         7 项私密库上锁与系统凭据按钮
test/toast_test.dart     8 项浮层与系统凭据分支
tool/                    xcompat / backup_demo 这类一次性验证脚本
```
