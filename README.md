# MemoNest 便签

一个像便签纸一样贴在桌面角落的 Markdown 备忘录：小窗口、黄色纸面、自动保存、
支持 OneDrive 云备份、GitHub 同步和开机自启。

界面使用 [CustomTkinter](https://github.com/TomSchimansky/CustomTkinter) 绘制，
圆角卡片 + 与纸面同色的标题栏，运行时内存约 40–60 MB，不需要 Electron 或 Qt。

![MemoNest 便签](docs/screenshot.png)

<details>
<summary>Markdown 预览效果</summary>

![预览模式](docs/screenshot-preview.png)

</details>

## 功能

- **小便签窗口**：默认 420×620，单条笔记视图，可置顶、记忆窗口位置和大小
- **Markdown**：编辑 + 应用内渲染预览，支持标题、列表、任务列表、表格、代码块、引用、链接
- **基础备忘录**：新建、下拉切换、搜索、标签、置顶笔记、删除（进回收站）、导出 `.md`
- **自动保存**：停止输入约 1 秒后写入磁盘，关闭窗口时也会保存
- **OneDrive 云备份**：把备份包与 Markdown 笔记镜像到 OneDrive 同步文件夹，由 OneDrive 客户端自动上传
- **GitHub 同步**：把笔记以 Markdown 文件提交并推送到你的仓库，网页上可查看历史
- **备份策略**：手动、定时（分钟）、退出前自动备份
- **开机自启**：写入当前用户注册表 `Run` 项，可在设置中开关
- **本地优先**：笔记就是 `data/notes/*.md`，任何编辑器都能打开

## 环境要求

- Windows 10 / 11
- Python 3.10+（安装时勾选 tcl/tk，默认已包含）
- 可选：OneDrive 客户端、Git（用于 GitHub 同步）

## 快速开始

直接双击 **`start.bat`** 即可。首次运行会自动：

1. 在项目内创建 `.venv` 虚拟环境（不污染系统 Python）
2. 安装 `requirements.txt` 里的 CustomTkinter
3. 用 `pythonw.exe` 启动，不留控制台窗口

手动启动：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\pythonw.exe app.py
```

> 若你的 Python 来自 MSYS2 / Git Bash，虚拟环境目录是 `.venv\bin\` 而不是
> `.venv\Scripts\`，`start.bat` 会自动识别两种布局。

首次启动会自动创建 `data/notes/` 和一篇欢迎便签。

## 界面

```
┌────────────────────────────────────────────┐
│ MemoNest 便签                    ─  □  ×  │  ← 标题栏配色随纸面
├────────────────────────────────────────────┤
│ MemoNest 便签            预览  备份  置顶 ⋯ │
│ [ 欢迎使用 MemoNest                      ⌄ ] + │
│ 标题                                        │
│ # 标签                    更新于 今天 04:24 │
│ ┌────────────────────────────────────────┐ │
│ │ 正文（Markdown）                       │ │
│ └────────────────────────────────────────┘ │
│ 就绪                            513 字 · 35 行 │
└────────────────────────────────────────────┘
```

- **预览 / 备份 / 置顶**：常用操作放在顶栏，一眼可见
- **⋯ 菜单**：新建、保存、导出、搜索、删除、设置、退出等都在这里
- 没有传统的「文件 / 编辑 / 视图」菜单栏，窗口更像一张便签

## 使用

| 操作 | 方式 |
| --- | --- |
| 新建便签 | 顶部 `+` 或 `Ctrl+N` |
| 切换便签 | 顶部下拉框 |
| 搜索 | `Ctrl+F`，回车打开第一条，Esc 关闭 |
| 删除 | `Ctrl+D`，文件移动到 `data/trash/` |
| 置顶笔记 | `⋯` 菜单 → 置顶笔记 |
| 编辑 / 预览 | 顶部「预览」按钮或 `Ctrl+E` |
| 保存 | 自动保存，`Ctrl+S` 手动 |
| 云备份 | 顶部「备份」或 `F5` |
| 窗口置顶 | 顶部「置顶」 |
| 设置 | `⋯` 菜单 → 设置，或 `Ctrl+,` |

## 数据与目录

```
备忘录/
├─ app.py                 主界面（CustomTkinter）
├─ core/
│  ├─ config.py           配置、路径、OneDrive 检测
│  ├─ storage.py          笔记读写、索引、搜索
│  ├─ markdown.py         Markdown 解析与预览渲染
│  ├─ backup.py           zip 打包、OneDrive 同步、GitHub 推送
│  ├─ autostart.py        开机自启（注册表）
│  └─ winstyle.py         Windows 11 标题栏配色
├─ assets/icon.ico        应用图标
├─ docs/                  截图
├─ tools/make_icon.py     图标生成脚本（纯标准库）
├─ data/                  运行后生成
│  ├─ notes/              每篇笔记一个 .md 文件
│  ├─ trash/              删除的笔记
│  ├─ backups/            本地 zip 备份
│  ├─ index.json          笔记元数据
│  └─ memo.log            运行日志
├─ config.json            本地配置（含 Token，已被 .gitignore 排除）
├─ config.example.json    配置示例
├─ start.bat              一键启动（自动建 venv、装依赖）
├─ upload_to_github.ps1   一键上传本项目到 GitHub
└─ tests/test_core.py     单元测试
```

## OneDrive 云备份

原理：把备份复制进 OneDrive 的本地同步文件夹，由 OneDrive 客户端负责上传。
这样不需要账号密码，也不依赖额外的开放接口。

1. 确认 OneDrive 客户端已安装并登录（任务栏有 OneDrive 云图标）
2. 打开「设置 → OneDrive」，勾选「启用 OneDrive 备份」
3. 文件夹留空会自动使用检测到的 OneDrive 目录，也可点「检测 / 浏览」手动指定
4. 「立即同步」可马上备份；之后可用 F5、定时备份或退出时备份

备份内容（默认位于 `OneDrive/MemoNest备份/`）：

- `memo-backup-时间戳.zip`：全部笔记 + `index.json`
- `notes/*.md`：Markdown 笔记镜像，手机 OneDrive 里可直接查看
- `index.json`：笔记清单

> 本机若未安装 OneDrive，程序会提示找不到目录。此时请安装并登录 OneDrive，
> 或把「OneDrive 文件夹」指向任意已同步到云端的目录。

## GitHub 同步

1. 在 GitHub 新建一个仓库（也可以让 `upload_to_github.ps1` 自动创建）
2. 打开 <https://github.com/settings/tokens> 生成 Personal Access Token，勾选 `repo` 权限
3. 「设置 → GitHub」填写 `用户名/仓库名`、分支（默认 `main`）、Token，勾选启用
4. 点「立即推送」，笔记会以 `.md` 文件出现在仓库根目录

说明：

- 笔记目录 `data/notes` 会被初始化为独立 Git 仓库，每次备份自动提交
- Token 保存在本地 `config.json` 和 `data/notes/.git/config`，不会进入项目仓库
- 首次推送空仓库即可；若远端已有提交，程序会先合并再推送

## 上传本项目到 GitHub

项目已初始化为 Git 仓库并完成首次提交。拿到 Token 后运行：

```powershell
.\upload_to_github.ps1 -Repo "你的用户名/memo-nest" -Token "ghp_xxxxxxxx"
```

脚本会：

1. 通过 GitHub API 检查仓库，不存在则创建（默认私有）
2. 提交当前代码
3. 推送到指定分支

> Token 只用于本次推送，`origin` 地址不会保存 Token。

## 开机自启

在「设置 → 通用」勾选「开机自动启动」并保存即可。实现方式：

```
HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run
值名：MemoNest
值：  "…\pythonw.exe" "…\app.py"
```

可在「任务管理器 → 启动应用」中查看或禁用；取消勾选会删除该项。

## 测试

```powershell
python -m unittest discover -s tests -v
```

覆盖笔记 CRUD、搜索、回收站、孤立 md 导入、Markdown 解析、
zip 备份、OneDrive 镜像、GitHub 推送（本地 bare 仓库）等。

## 安全提示

- `config.json` 内含 GitHub Token，已在 `.gitignore` 中排除，请勿提交或分享
- 备份 zip 未加密，OneDrive 云端安全性依赖你的 Microsoft 账号
- 删除笔记只是移动到 `data/trash/`，确认无用后可手动清理

## 常见问题

**找不到 OneDrive 文件夹？**
确认 OneDrive 已登录，或在设置里手动选择同步目录。

**GitHub 推送失败？**
检查 Token 是否过期、是否有 `repo` 权限、仓库名是否为 `用户名/仓库名`、
分支是否被保护。

**便签窗口太小 / 位置不对？**
拖动边缘调整大小，关闭时会记住位置；也可删除 `config.json` 中的
`general.window_geometry` 恢复默认。

**标题栏不是便签色？**
标题栏配色依赖 Windows 11 的 DWM 接口；Windows 10 上会保留系统默认颜色，
其余界面不受影响。

**想用其他编辑器编辑笔记？**
直接编辑 `data/notes/*.md`，重新打开程序会自动导入未登记的文件。
