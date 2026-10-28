"""加密原语：scrypt 口令派生 + AES-256-GCM 认证加密。"""

from __future__ import annotations

import base64
import hashlib
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# scrypt 参数：约 32 MB 内存、单次 0.1–0.3 秒，兼顾强度与手机/低配机体验
SCRYPT_N = 2**15
SCRYPT_R = 8
SCRYPT_P = 1
SALT_BYTES = 16
KEY_BYTES = 32
NONCE_BYTES = 12

AAD_META = b"memonest-vault-v1"


class CryptoError(RuntimeError):
    """解密失败（口令错误或文件被篡改）。"""


def derive(password: str, salt: bytes, n: int = SCRYPT_N, r: int = SCRYPT_R, p: int = SCRYPT_P) -> bytes:
    if not password:
        raise ValueError("口令不能为空")
    return hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=max(2**12, int(n)),
        r=max(1, int(r)),
        p=max(1, int(p)),
        dklen=KEY_BYTES,
        maxmem=512 * 1024 * 1024,
    )


def new_salt() -> bytes:
    return os.urandom(SALT_BYTES)


def new_key() -> bytes:
    return os.urandom(KEY_BYTES)


def encrypt(key: bytes, plaintext: bytes, aad: bytes = b"") -> bytes:
    nonce = os.urandom(NONCE_BYTES)
    return nonce + AESGCM(key).encrypt(nonce, plaintext, aad or None)


def decrypt(key: bytes, blob: bytes, aad: bytes = b"") -> bytes:
    if len(blob) <= NONCE_BYTES:
        raise CryptoError("密文长度异常")
    nonce, ciphertext = blob[:NONCE_BYTES], blob[NONCE_BYTES:]
    try:
        return AESGCM(key).decrypt(nonce, ciphertext, aad or None)
    except InvalidTag as exc:
        raise CryptoError("口令不正确，或数据已被修改") from exc


def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(text: str) -> bytes:
    return base64.b64decode(text.encode("ascii"))
