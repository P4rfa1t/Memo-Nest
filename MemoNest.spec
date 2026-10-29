# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller 打包配置：目录模式（onedir），配合 Inno Setup 生成安装包。

用法：
    pyinstaller MemoNest.spec
生成：
    dist/MemoNest/MemoNest.exe
    dist/MemoNest/_internal/...

安装包由 installer/build_installer.ps1 生成；不再使用单文件 onefile。
"""

from PyInstaller.utils.hooks import collect_all, collect_submodules

datas = [("assets/icon.ico", "assets")]
binaries = []
hiddenimports = list(collect_submodules("winrt.windows"))

for package in ("customtkinter", "winrt"):
    pkg_datas, pkg_binaries, pkg_hidden = collect_all(package)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hidden

hiddenimports += [
    "winrt.system",
    "winrt.windows.foundation",
    "winrt.windows.foundation.collections",
    "winrt.windows.storage.streams",
    "winrt.windows.security.credentials.ui",
]

a = Analysis(
    ["app.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter.test", "pydoc_data"],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="MemoNest",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon="assets/icon.ico",
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="MemoNest",
)
