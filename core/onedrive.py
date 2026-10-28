"""OneDrive 账号登录同步（Microsoft Graph + OAuth 设备代码流程）。

不需要安装 OneDrive 客户端：用户在设置里点「登录 Microsoft 账号」，
程序会显示一个设备代码，浏览器授权后即可把备份直接上传到云端。

前提：需要一个 Azure 应用注册（免费，个人 Microsoft 账号即可），
把「应用程序(客户端) ID」填进设置。详见 README 的 OneDrive 章节。
"""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

from . import config as cfgmod

LOG = logging.getLogger("memonest.onedrive")

GRAPH = "https://graph.microsoft.com/v1.0"
SCOPES = "offline_access Files.ReadWrite User.Read"
SIMPLE_UPLOAD_LIMIT = 250 * 1024 * 1024


class GraphError(RuntimeError):
    """OneDrive 接口或登录过程中的可读错误。"""

    def __init__(self, message: str, status: int = 0, payload: dict | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.payload = payload or {}


# --------------------------------------------------------------------------
# HTTP 基础
# --------------------------------------------------------------------------
def _authority(tenant: str) -> str:
    tenant = (tenant or "common").strip() or "common"
    return f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"


def _error_text(payload: dict, status: int) -> str:
    if not isinstance(payload, dict):
        return f"HTTP {status}"
    if payload.get("error_description"):
        return str(payload["error_description"]).split("\r\n")[0]
    error = payload.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or error.get("code") or f"HTTP {status}")
    return str(error or f"HTTP {status}")


def _request(
    method: str,
    url: str,
    *,
    token: str | None = None,
    form: dict | None = None,
    json_body: dict | None = None,
    raw: bytes | None = None,
    headers: dict | None = None,
    timeout: int = 60,
) -> tuple[int, dict]:
    body: bytes | None = None
    final_headers = {"Accept": "application/json", "User-Agent": "MemoNest/1.0"}
    if json_body is not None:
        body = json.dumps(json_body).encode("utf-8")
        final_headers["Content-Type"] = "application/json"
    elif form is not None:
        body = urllib.parse.urlencode(form).encode("utf-8")
        final_headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif raw is not None:
        body = raw
        final_headers["Content-Type"] = "application/octet-stream"
    if token:
        final_headers["Authorization"] = f"Bearer {token}"
    if headers:
        final_headers.update(headers)

    request = urllib.request.Request(url, data=body, headers=final_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
            return response.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = {"error_description": text.strip()}
        raise GraphError(_error_text(parsed, exc.code), exc.code, parsed) from exc
    except urllib.error.URLError as exc:  # 断网、DNS 等
        raise GraphError(f"网络连接失败：{exc.reason}") from exc


# --------------------------------------------------------------------------
# 设备代码登录
# --------------------------------------------------------------------------
def start_device_flow(client_id: str, tenant: str = "common") -> dict:
    if not (client_id or "").strip():
        raise GraphError("请先填写 Azure 应用的客户端 ID")
    _, payload = _request(
        "POST",
        f"{_authority(tenant)}/devicecode",
        form={"client_id": client_id.strip(), "scope": SCOPES},
    )
    return payload


def poll_device_token(
    client_id: str,
    tenant: str,
    device_code: str,
    interval: int = 5,
    expires_in: int = 900,
    should_stop: Callable[[], bool] | None = None,
) -> dict:
    """轮询直到用户完成授权，返回令牌响应。"""
    deadline = time.time() + max(60, expires_in)
    wait = max(3, int(interval or 5))
    token_url = f"{_authority(tenant)}/token"
    while time.time() < deadline:
        if should_stop and should_stop():
            raise GraphError("已取消登录")
        time.sleep(wait)
        try:
            _, payload = _request(
                "POST",
                token_url,
                form={
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": client_id.strip(),
                    "device_code": device_code,
                },
            )
            return payload
        except GraphError as exc:
            code = str((exc.payload or {}).get("error") or "")
            if code == "authorization_pending":
                continue
            if code == "slow_down":
                wait += 5
                continue
            if code in ("authorization_declined", "access_denied"):
                raise GraphError("授权被拒绝") from exc
            if code == "expired_token":
                raise GraphError("登录代码已过期，请重新登录") from exc
            raise
    raise GraphError("登录超时，请重试")


def save_tokens(cfg, payload: dict, account: str = "") -> None:
    cfg.set("onedrive.access_token", str(payload.get("access_token", "") or ""))
    expires = int(payload.get("expires_in", 3600) or 3600)
    cfg.set("onedrive.expires_at", time.time() + max(60, expires - 60))
    refresh = payload.get("refresh_token")
    if refresh:
        cfg.set("onedrive.refresh_token", str(refresh))
    if account:
        cfg.set("onedrive.account", account)
    cfg.save()


def logout(cfg) -> None:
    for key in ("access_token", "refresh_token", "expires_at", "account"):
        cfg.set(f"onedrive.{key}", 0 if key == "expires_at" else "")
    cfg.save()


def is_logged_in(cfg) -> bool:
    return bool(str(cfg.get("onedrive.refresh_token", "") or ""))


def access_token(cfg, force_refresh: bool = False) -> str:
    token = str(cfg.get("onedrive.access_token", "") or "")
    expires_at = float(cfg.get("onedrive.expires_at", 0) or 0)
    if token and not force_refresh and time.time() < expires_at:
        return token

    refresh = str(cfg.get("onedrive.refresh_token", "") or "")
    if not refresh:
        raise GraphError("尚未登录 Microsoft 账号，请先在设置里登录")
    client_id = str(cfg.get("onedrive.client_id", "") or "").strip()
    if not client_id:
        raise GraphError("缺少 Azure 应用 ID，无法刷新登录状态")

    _, payload = _request(
        "POST",
        f"{_authority(str(cfg.get('onedrive.tenant', 'common') or 'common'))}/token",
        form={
            "grant_type": "refresh_token",
            "client_id": client_id,
            "refresh_token": refresh,
            "scope": SCOPES,
        },
    )
    save_tokens(cfg, payload)
    return str(payload.get("access_token", ""))


def _graph(cfg, method: str, path: str, **kwargs) -> dict:
    token = access_token(cfg)
    _, payload = _request(method, GRAPH + path, token=token, **kwargs)
    return payload


def get_profile(cfg) -> str:
    try:
        data = _graph(cfg, "GET", "/me?$select=displayName,userPrincipalName")
    except GraphError:
        return ""
    return str(data.get("displayName") or data.get("userPrincipalName") or "")


# --------------------------------------------------------------------------
# 文件上传
# --------------------------------------------------------------------------
def _quote(path: str) -> str:
    return urllib.parse.quote(path.strip("/"), safe="/")


def ensure_folder(cfg, folder: str) -> None:
    current = ""
    for part in [piece for piece in folder.split("/") if piece]:
        parent = (
            f"/me/drive/root:/{_quote(current)}:/children"
            if current
            else "/me/drive/root/children"
        )
        try:
            _graph(
                cfg,
                "POST",
                parent,
                json_body={
                    "name": part,
                    "folder": {},
                    "@microsoft.graph.conflictBehavior": "fail",
                },
            )
        except GraphError as exc:
            if exc.status != 409:  # 409 = 已存在
                raise
        current = f"{current}/{part}" if current else part


def upload_file(cfg, local: Path, folder: str, name: str | None = None) -> None:
    data = local.read_bytes()
    if len(data) > SIMPLE_UPLOAD_LIMIT:
        raise GraphError(f"{local.name} 超过 250MB，暂不支持上传")
    ensure_folder(cfg, folder)
    target = f"{folder.strip('/')}/{name or local.name}".strip("/")
    _graph(
        cfg,
        "PUT",
        f"/me/drive/root:/{_quote(target)}:/content",
        raw=data,
    )


def list_children(cfg, folder: str) -> list[dict]:
    path = (
        f"/me/drive/root:/{_quote(folder)}:/children"
        if folder
        else "/me/drive/root/children"
    )
    data = _graph(cfg, "GET", f"{path}?$select=id,name,lastModifiedDateTime&$top=200")
    value = data.get("value", [])
    return value if isinstance(value, list) else []


def delete_item(cfg, item_id: str) -> None:
    _graph(cfg, "DELETE", f"/me/drive/items/{urllib.parse.quote(item_id)}")


# --------------------------------------------------------------------------
# 同步
# --------------------------------------------------------------------------
def sync(
    cfg,
    zip_path: Path | None,
    notes_dir: Path = cfgmod.NOTES_DIR,
    index_path: Path = cfgmod.INDEX_PATH,
    vault: bool = False,
) -> str:
    subfolder = str(cfg.get("onedrive.subfolder", "MemoNest备份") or "MemoNest备份")
    subfolder = subfolder.strip("/")
    ensure_folder(cfg, subfolder)

    uploaded = 0
    if cfg.get("onedrive.mirror_notes", True):
        notes_folder = f"{subfolder}/notes"
        ensure_folder(cfg, notes_folder)
        current: set[str] = set()
        for note_file in sorted(notes_dir.glob("*.md")):
            upload_file(cfg, note_file, notes_folder)
            current.add(note_file.name)
            uploaded += 1
        for item in list_children(cfg, notes_folder):
            name = str(item.get("name", ""))
            if name.endswith(".md") and name not in current and item.get("id"):
                delete_item(cfg, str(item["id"]))
        if index_path.exists():
            upload_file(cfg, index_path, subfolder)

        if vault:
            items_folder = f"{subfolder}/vault/items"
            ensure_folder(cfg, items_folder)
            encrypted: set[str] = set()
            for note_file in sorted(cfgmod.VAULT_ITEMS_DIR.glob("*.mdenc")):
                upload_file(cfg, note_file, items_folder)
                encrypted.add(note_file.name)
                uploaded += 1
            for item in list_children(cfg, items_folder):
                name = str(item.get("name", ""))
                if name.endswith(".mdenc") and name not in encrypted and item.get("id"):
                    delete_item(cfg, str(item["id"]))
            # 云端只放包裹后的密钥，绝不包含 dpapi_key（换机即失效的那份）
            meta_path = cfgmod.VAULT_META_PATH
            if meta_path.exists():
                try:
                    payload = json.loads(meta_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    payload = {}
                payload.pop("dpapi_key", None)
                target = f"{subfolder}/vault/vault.json"
                _graph(
                    cfg,
                    "PUT",
                    f"/me/drive/root:/{_quote(target)}:/content",
                    raw=json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"),
                )

    if zip_path and zip_path.exists():
        upload_file(cfg, zip_path, subfolder)
        keep = int(cfg.get("onedrive.keep_backups", 30) or 30)
        _prune(cfg, subfolder, keep)

    account = str(cfg.get("onedrive.account", "") or "") or "Microsoft 账号"
    return f"已用 {account} 上传 {uploaded} 篇笔记"


def _prune(cfg, folder: str, keep: int) -> None:
    if keep <= 0:
        return
    backups = [
        item
        for item in list_children(cfg, folder)
        if str(item.get("name", "")).startswith("memo-backup-")
        and str(item.get("name", "")).endswith(".zip")
    ]
    backups.sort(key=lambda item: str(item.get("name", "")))
    for stale in backups[:-keep]:
        if stale.get("id"):
            try:
                delete_item(cfg, str(stale["id"]))
            except GraphError:
                LOG.warning("无法删除云端旧备份 %s", stale.get("name"))


def test_login(cfg) -> str:
    """验证当前登录是否可用，返回账号名。"""
    token = access_token(cfg, force_refresh=True)
    _, payload = _request(
        "GET",
        GRAPH + "/me?$select=displayName,userPrincipalName",
        token=token,
    )
    name = str(payload.get("displayName") or payload.get("userPrincipalName") or "")
    if name:
        cfg.set("onedrive.account", name)
        cfg.save()
    return name or "已登录"
