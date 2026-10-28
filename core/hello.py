"""Windows Hello 验证（WinRT UserConsentVerifier）。

只用于“确认是本人”，真正的密钥仍由 DPAPI + 主密码保护。
WinRT 不可用（非 Windows / 未安装依赖 / 未设置 Hello）时调用方应退回主密码。
"""

from __future__ import annotations

import asyncio
import logging

LOG = logging.getLogger("memonest.hello")

try:  # pragma: no cover - 取决于系统与依赖
    from winrt.windows.security.credentials.ui import (
        UserConsentVerificationResult,
        UserConsentVerifier,
        UserConsentVerifierAvailability,
    )

    HAS_WINRT = True
except Exception:  # pragma: no cover
    HAS_WINRT = False


_TEXTS = {
    "VERIFIED": "验证通过",
    "DEVICE_NOT_PRESENT": "此设备没有可用的 Windows Hello 硬件",
    "NOT_CONFIGURED_FOR_USER": "尚未设置 Windows Hello，请先在系统设置中录入指纹 / 人脸 / PIN",
    "DISABLED_BY_POLICY": "Windows Hello 已被组策略禁用",
    "DEVICE_BUSY": "Windows Hello 正忙，请稍后重试",
    "RETRIES_EXHAUSTED": "尝试次数过多，请改用主密码",
    "CANCELED": "已取消验证",
    "UNAVAILABLE": "Windows Hello 不可用",
}


def available() -> bool:
    """Windows Hello 是否可用（不弹窗）。"""
    if not HAS_WINRT:
        return False
    try:
        return asyncio.run(_check()) == UserConsentVerifierAvailability.AVAILABLE
    except Exception:  # pragma: no cover
        LOG.exception("检测 Windows Hello 失败")
        return False


async def _check():
    return await UserConsentVerifier.check_availability_async()


def verify(reason: str = "解锁 MemoNest 加密笔记") -> tuple[bool, str]:
    """弹出 Windows Hello 验证，返回 (是否通过, 说明)。"""
    if not HAS_WINRT:
        return False, _TEXTS["UNAVAILABLE"]
    try:
        result = asyncio.run(_request(reason))
    except Exception as exc:  # pragma: no cover
        LOG.exception("Windows Hello 验证异常")
        return False, f"Windows Hello 出错：{exc}"
    name = getattr(result, "name", str(result))
    return result == UserConsentVerificationResult.VERIFIED, _TEXTS.get(name, name)


async def _request(reason: str):
    return await UserConsentVerifier.request_verification_async(reason)
