"""备份模块：本地打包 → OneDrive 同步文件夹 → GitHub 仓库。"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from . import config as cfgmod
from . import onedrive

LOG = logging.getLogger("memonest.backup")


class BackupError(RuntimeError):
    """备份过程中的可读错误。"""


@dataclass
class Step:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class BackupReport:
    zip_path: Path | None = None
    steps: list[Step] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.steps) and all(step.ok for step in self.steps)

    @property
    def cloud_steps(self) -> list[Step]:
        return [step for step in self.steps if step.name != "本地打包"]

    def summary(self) -> str:
        return "\n".join(
            f"{'✓' if step.ok else '✗'} {step.name}：{step.detail}" for step in self.steps
        )


# --------------------------------------------------------------------------
# 本地打包
# --------------------------------------------------------------------------
def create_backup_zip(
    notes_dir: Path = cfgmod.NOTES_DIR,
    index_path: Path = cfgmod.INDEX_PATH,
    backup_dir: Path = cfgmod.BACKUP_DIR,
    keep: int = 20,
    vault: bool = False,
) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = backup_dir / f"memo-backup-{stamp}.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for note_file in sorted(notes_dir.glob("*.md")):
            archive.write(note_file, f"notes/{note_file.name}")
        if index_path.exists():
            archive.write(index_path, "index.json")
        if vault:
            for item in sorted(cfgmod.VAULT_ITEMS_DIR.glob("*.mdenc")):
                archive.write(item, f"vault/items/{item.name}")
            meta = cfgmod.VAULT_META_PATH
            if meta.exists():
                try:
                    payload = json.loads(meta.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    payload = {}
                payload.pop("dpapi_key", None)  # 机器绑定的密钥不随备份走
                archive.writestr(
                    "vault/vault.json",
                    json.dumps(payload, ensure_ascii=False, indent=2),
                )
    _prune(path.parent, "memo-backup-*.zip", keep)
    return path


def vault_present() -> bool:
    """是否存在私密笔记库（只看文件，不看配置）。"""
    return cfgmod.VAULT_META_PATH.exists()


def create_zip_for(cfg) -> Path:
    return create_backup_zip(
        keep=int(cfg.get("general.keep_backups", 20) or 20),
        vault=vault_present(),
    )


def _prune(folder: Path, pattern: str, keep: int) -> None:
    if keep <= 0:
        return
    files = sorted(folder.glob(pattern), key=lambda p: p.stat().st_mtime)
    for stale in files[:-keep]:
        try:
            stale.unlink()
        except OSError:
            LOG.warning("无法删除旧备份 %s", stale)


# --------------------------------------------------------------------------
# OneDrive 备份
# --------------------------------------------------------------------------
def resolve_onedrive_folder(cfg) -> Path:
    raw = str(cfg.get("onedrive.folder", "") or "").strip()
    if raw:
        folder = Path(os.path.expandvars(raw)).expanduser()
        if not folder.is_dir():
            raise BackupError(f"OneDrive 文件夹不存在：{folder}")
        return folder

    detected = cfgmod.detect_onedrive_dir()
    if detected is None:
        raise BackupError(
            "未找到 OneDrive 同步文件夹。请安装并登录 OneDrive，"
            "或在设置中手动填写 OneDrive 路径。"
        )
    return detected


def sync_onedrive(
    cfg,
    zip_path: Path | None,
    notes_dir: Path | None = None,
    index_path: Path | None = None,
    vault: bool | None = None,
) -> str:
    """按配置的同步方式备份到 OneDrive（普通笔记 + 私密库密文）。"""
    include_vault = vault_present() if vault is None else vault
    notes_dir = Path(notes_dir or cfgmod.NOTES_DIR)
    index_path = Path(index_path or cfgmod.INDEX_PATH)

    mode = str(cfg.get("onedrive.mode", "folder") or "folder")
    if mode == "graph":
        return onedrive.sync(cfg, zip_path, notes_dir, index_path, vault=include_vault)

    # ---- 文件夹模式：复制到 OneDrive 客户端同步目录 ----
    root = resolve_onedrive_folder(cfg)
    subfolder = str(cfg.get("onedrive.subfolder", "MemoNest备份") or "MemoNest备份")
    target = root / subfolder
    target.mkdir(parents=True, exist_ok=True)

    copied = 0
    if cfg.get("onedrive.mirror_notes", True):
        notes_target = target / "notes"
        notes_target.mkdir(parents=True, exist_ok=True)
        current: set[str] = set()
        for note_file in sorted(notes_dir.glob("*.md")):
            shutil.copy2(note_file, notes_target / note_file.name)
            current.add(note_file.name)
            copied += 1
        for stale in notes_target.glob("*.md"):
            if stale.name not in current:
                try:
                    stale.unlink()
                except OSError:
                    pass
        if index_path.exists():
            shutil.copy2(index_path, target / "index.json")

        if include_vault:
            vault_target = target / "vault"
            items_target = vault_target / "items"
            items_target.mkdir(parents=True, exist_ok=True)
            encrypted: set[str] = set()
            for item in sorted(cfgmod.VAULT_ITEMS_DIR.glob("*.mdenc")):
                shutil.copy2(item, items_target / item.name)
                encrypted.add(item.name)
                copied += 1
            for stale in items_target.glob("*.mdenc"):
                if stale.name not in encrypted:
                    try:
                        stale.unlink()
                    except OSError:
                        pass
            if cfgmod.VAULT_META_PATH.exists():
                try:
                    payload = json.loads(
                        cfgmod.VAULT_META_PATH.read_text(encoding="utf-8")
                    )
                except (OSError, json.JSONDecodeError):
                    payload = {}
                payload.pop("dpapi_key", None)  # 只上传包裹后的密钥
                (vault_target / "vault.json").write_text(
                    json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
                )

    if zip_path and zip_path.exists():
        shutil.copy2(zip_path, target / zip_path.name)

    keep = int(cfg.get("onedrive.keep_backups", 30) or 30)
    _prune(target, "memo-backup-*.zip", keep)
    return f"已同步 {copied} 篇笔记到 {target}"


# --------------------------------------------------------------------------
# GitHub 备份
# --------------------------------------------------------------------------
def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GCM_INTERACTIVE"] = "never"
    process = subprocess.run(
        ["git", "-c", "credential.helper=", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if check and process.returncode != 0:
        message = (process.stderr or process.stdout or "").strip()
        raise BackupError(message.splitlines()[-1] if message else f"git {args[0]} 失败")
    return process


def _remote_url(cfg) -> str:
    custom = str(cfg.get("github.remote_url", "") or "").strip()
    repo = str(cfg.get("github.repo", "") or "").strip().strip("/")
    token = str(cfg.get("github.token", "") or "").strip()
    if custom:
        if "{token}" in custom:
            if not token:
                raise BackupError("请先填写 GitHub Token")
            return custom.replace("{token}", token)
        return custom
    if not repo or "/" not in repo:
        raise BackupError("请填写 GitHub 仓库，格式为 用户名/仓库名")
    if not token:
        raise BackupError("请填写 GitHub Token（需要 repo 权限）")
    return f"https://x-access-token:{token}@github.com/{repo}.git"


def _stage_github_source() -> Path:
    """把普通笔记与私密库密文汇总到一个临时目录，避免污染 data/notes。"""
    staging = cfgmod.DATA_DIR / "github"
    staging.mkdir(parents=True, exist_ok=True)
    current: set[str] = set()
    for note_file in sorted(cfgmod.NOTES_DIR.glob("*.md")):
        shutil.copy2(note_file, staging / note_file.name)
        current.add(note_file.name)
    for stale in staging.glob("*.md"):
        if stale.name not in current:
            try:
                stale.unlink()
            except OSError:
                pass

    items_target = staging / "vault" / "items"
    items_target.mkdir(parents=True, exist_ok=True)
    encrypted: set[str] = set()
    for item in sorted(cfgmod.VAULT_ITEMS_DIR.glob("*.mdenc")):
        shutil.copy2(item, items_target / item.name)
        encrypted.add(item.name)
    for stale in items_target.glob("*.mdenc"):
        if stale.name not in encrypted:
            try:
                stale.unlink()
            except OSError:
                pass
    if cfgmod.VAULT_META_PATH.exists():
        try:
            payload = json.loads(cfgmod.VAULT_META_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}
        payload.pop("dpapi_key", None)
        (staging / "vault" / "vault.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return staging


def push_to_github(cfg, notes_dir: Path | None = None) -> str:
    if shutil.which("git") is None:
        raise BackupError("未检测到 Git，请先安装 https://git-scm.com/download/win")

    if notes_dir is None:
        notes_dir = _stage_github_source() if vault_present() else cfgmod.NOTES_DIR
    notes_dir = Path(notes_dir)
    notes_dir.mkdir(parents=True, exist_ok=True)
    branch = str(cfg.get("github.branch", "main") or "main").strip() or "main"
    url = _remote_url(cfg)

    if not (notes_dir / ".git").exists():
        _git(["init", "-b", branch], notes_dir)
    _git(["config", "user.name", str(cfg.get("github.author_name", "MemoNest"))], notes_dir)
    _git(
        ["config", "user.email", str(cfg.get("github.author_email", "memonest@localhost"))],
        notes_dir,
    )

    remotes = _git(["remote"], notes_dir).stdout.split()
    if "origin" in remotes:
        _git(["remote", "set-url", "origin", url], notes_dir)
    else:
        _git(["remote", "add", "origin", url], notes_dir)

    _git(["add", "-A"], notes_dir)
    staged = _git(["diff", "--cached", "--quiet"], notes_dir, check=False)
    committed = False
    if staged.returncode != 0:
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        _git(["commit", "-m", f"备忘录自动备份 {stamp}"], notes_dir)
        committed = True

    push = _git(["push", "origin", f"HEAD:{branch}"], notes_dir, check=False)
    if push.returncode != 0:
        output = f"{push.stderr}\n{push.stdout}"
        if any(word in output.lower() for word in ("rejected", "fetch first", "non-fast-forward")):
            LOG.info("远端有新提交，尝试合并后重试")
            _git(["fetch", "origin", branch], notes_dir, check=False)
            _git(
                [
                    "merge",
                    "--allow-unrelated-histories",
                    "--no-edit",
                    "-X",
                    "ours",
                    f"origin/{branch}",
                ],
                notes_dir,
                check=False,
            )
            push = _git(["push", "origin", f"HEAD:{branch}"], notes_dir, check=False)
        if push.returncode != 0:
            detail = (push.stderr or push.stdout or "推送失败").strip().splitlines()[-1]
            raise BackupError(f"GitHub 推送失败：{detail}")

    repo = str(cfg.get("github.repo", "") or "GitHub")
    return f"已推送 {repo}（{branch} 分支）" + ("" if committed else "，无新变更")


# --------------------------------------------------------------------------
# 汇总
# --------------------------------------------------------------------------
def run_backup(cfg, create_zip: bool = True) -> BackupReport:
    cfgmod.ensure_dirs()
    report = BackupReport()

    zip_path: Path | None = None
    if create_zip:
        try:
            zip_path = create_zip_for(cfg)
            report.zip_path = zip_path
            report.steps.append(Step("本地打包", True, zip_path.name))
        except Exception as exc:
            LOG.exception("本地打包失败")
            report.steps.append(Step("本地打包", False, str(exc)))

    if cfg.get("onedrive.enabled"):
        try:
            detail = sync_onedrive(cfg, zip_path)
            report.steps.append(Step("OneDrive", True, detail))
        except Exception as exc:
            LOG.exception("OneDrive 备份失败")
            report.steps.append(Step("OneDrive", False, str(exc)))

    if cfg.get("github.enabled"):
        try:
            detail = push_to_github(cfg)
            report.steps.append(Step("GitHub", True, detail))
        except Exception as exc:
            LOG.exception("GitHub 备份失败")
            report.steps.append(Step("GitHub", False, str(exc)))

    return report
