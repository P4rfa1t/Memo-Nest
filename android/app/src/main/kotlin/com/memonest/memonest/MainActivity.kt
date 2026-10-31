package com.memonest.memonest

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.NonNull
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 平台通道 `memonest/hello` 的 Android 实现。
 *
 * 和 Windows 侧（windows/runner/flutter_window.cpp）一一对应：
 * - available    生物识别能不能用
 * - authenticate 单独弹一次系统验证（Dart 侧的 verify）
 * - protect      用 Keystore 里的 AES 密钥加密一段字节
 * - unprotect    解密
 *
 * ## 为什么 protect / unprotect 要自己弹验证
 *
 * 密钥是用 `setUserAuthenticationRequired(true)` 生成的，Keystore 不允许
 * 在「刚验证过」之外的时间窗口里使用它——`Cipher.init` 会直接抛
 * `UserNotAuthenticatedException`。正确用法是把初始化好的 Cipher 交给
 * `BiometricPrompt` 的 `CryptoObject`，验证通过后系统才把 Cipher 解锁，
 * 这时才能 `doFinal`。
 *
 * 之前的实现没走 CryptoObject，于是 `protect` 在「刚输完主密码、
 * 没有任何生物验证」的时刻必然失败，`hello.bin` 从来没写出来过，
 * 表现就是「明明用主密码解锁过了，还是提示没有可用凭据」。
 *
 * 因为验证已经内置在 protect / unprotect 里，Dart 侧对 Android 不再
 * 单独调 `authenticate`（`Host.secretPromptBuiltIn` 为 true），
 * 否则一次解锁会弹两次指纹框。
 */
// 必须用 FlutterFragmentActivity：androidx.biometric 的 BiometricPrompt
// 构造函数只收 FragmentActivity，用 FlutterActivity 会编译不过。
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "memonest/hello"

        /**
         * 密钥别名。旧版用 `memonest_vault_key`，那把钥匙生成时要求
         * AUTH_BIOMETRIC_STRONG，而验证对话框用的是 BIOMETRIC_WEAK，
         * 两者对不上，验证通过也用不了。换个别名重新生成。
         */
        private const val KEY_ALIAS = "memonest_vault_key_v2"
        private const val LEGACY_ALIAS = "memonest_vault_key"

        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128

        /** 密钥和验证对话框必须用同一档认证强度，否则解锁不了。 */
        private const val AUTHENTICATORS = BiometricManager.Authenticators.BIOMETRIC_WEAK
    }

    /** BiometricPrompt 是异步回调的，这里挂住等待中的 Dart 结果。 */
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(biometricAvailable())
                    "authenticate" -> {
                        val prompt = call.argument<String>("prompt") ?: "解锁私密笔记库"
                        authenticate(prompt, result)
                    }
                    "protect" -> {
                        val data = call.argument<String>("data")
                        if (data == null) {
                            result.error("bad_args", "缺少 data", null)
                        } else {
                            protect(data, result)
                        }
                    }
                    "unprotect" -> {
                        val data = call.argument<String>("data")
                        if (data == null) {
                            result.error("bad_args", "缺少 data", null)
                        } else {
                            unprotect(data, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun biometricAvailable(): Boolean {
        val manager = BiometricManager.from(this)
        return manager.canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS
    }

    // ---------- 验证对话框 ----------

    private fun authenticate(prompt: String, result: MethodChannel.Result) {
        if (!biometricAvailable()) {
            result.success(false)
            return
        }
        if (pendingResult != null) {
            // 同一时间只允许一个验证对话框，重复点按直接拒绝。
            result.success(false)
            return
        }
        onCrypto = null
        onCancel = null
        prompt(null, BiometricPrompt.PromptInfo.Builder()
            .setTitle(prompt)
            .setSubtitle("用指纹或面容验证")
            .setNegativeButtonText("取消")
            .setAllowedAuthenticators(AUTHENTICATORS)
            .build(), result)
    }

    /**
     * 弹验证框。[cipher] 非空时包成 CryptoObject：系统验证通过后
     * 这个 Cipher 才被解锁，[onCrypto] 里才能 doFinal。
     */
    private fun prompt(
        cipher: Cipher?,
        info: BiometricPrompt.PromptInfo,
        result: MethodChannel.Result,
    ) {
        pendingResult = result
        val executor = ContextCompat.getMainExecutor(this)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(
                @NonNull authResult: BiometricPrompt.AuthenticationResult
            ) {
                val pending = takePending() ?: return
                val unlocked = authResult.cryptoObject?.cipher
                if (cipher == null) {
                    // 单纯的验证请求，没有要解锁的 Cipher。
                    pending.success(true)
                    return
                }
                if (unlocked == null) {
                    pending.error("no_cipher", "验证通过但没拿到可用的密钥", null)
                    return
                }
                onCrypto?.invoke(unlocked, pending) ?: pending.success(true)
            }

            override fun onAuthenticationError(code: Int, @NonNull msg: CharSequence) {
                // 用户取消（13 = ERROR_USER_CANCELED，10 = ERROR_NEGATIVE_BUTTON）
                // 也算 false，Dart 侧据此显示「已取消」而不是红字报错。
                val pending = takePending() ?: return
                onCancel?.invoke(pending) ?: pending.success(false)
            }

            override fun onAuthenticationFailed() {
                // 单次指纹不匹配：系统会让用户重试，这里不结束。
            }
        }
        val dialog = BiometricPrompt(this, executor, callback)
        if (cipher != null) {
            dialog.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        } else {
            dialog.authenticate(info)
        }
    }

    /** 只取一次，避免回调重复触发时把同一个 Result 应答两遍。 */
    private fun takePending(): MethodChannel.Result? {
        val pending = pendingResult
        pendingResult = null
        return pending
    }

    /** CryptoObject 验证通过后的回调，拿到已解锁的 Cipher。 */
    private var onCrypto: ((Cipher, MethodChannel.Result) -> Unit)? = null

    /** 用户取消或出错时的回调。 */
    private var onCancel: ((MethodChannel.Result) -> Unit)? = null

    // ---------- Keystore ----------

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

        // 旧别名是错误参数生成的，留着只会让人以为凭据还在，直接删。
        if (store.containsAlias(LEGACY_ALIAS)) {
            try {
                store.deleteEntry(LEGACY_ALIAS)
            } catch (_: Exception) {
                // 删不掉不影响新密钥
            }
        }

        val existing = try {
            store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        } catch (_: UnrecoverableKeyException) {
            // 密钥被系统作废了（换指纹、改锁屏密码）。留着它只会让每次
            // 加解密都失败，删掉重新生成一把。
            try {
                store.deleteEntry(KEY_ALIAS)
            } catch (_: Exception) {
                // 删不掉就交给下面的 generateKey 覆盖
            }
            null
        }
        if (existing != null) return existing.secretKey

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore"
        )
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            // 换新指纹时让旧密钥失效：新录入的指纹不该能解别人的托管密钥。
            .setInvalidatedByBiometricEnrollment(true)

        // 只有在系统验证可用时才要求「每次使用都要验证」——不然在没录指纹的
        // 设备上这把密钥根本用不了，连创建私密库都会失败。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && biometricAvailable()) {
            builder.setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // 0 = 每次使用都要当场验证（Keystore 不留时间窗口）。
                builder.setUserAuthenticationParameters(0, AUTHENTICATORS)
            } else {
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(-1)
            }
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    /** 密钥被新指纹作废、或设备改了锁屏密码之后，只能重新用主密码走一遍。 */
    private fun keyBrokenMessage(e: Throwable): String? = when (e) {
        is KeyPermanentlyInvalidatedException ->
            "系统凭据已失效（指纹或锁屏密码有变动），请用主密码解锁"
        is UnrecoverableKeyException ->
            "系统凭据已失效，请用主密码解锁"
        // 密钥重建过（上面 getEntry 失败后重新生成），旧密文自然解不开。
        is AEADBadTagException ->
            "系统凭据已失效，请用主密码解锁"
        else -> null
    }

    private fun protect(plainBase64: String, result: MethodChannel.Result) {
        if (!biometricAvailable()) {
            result.error("no_biometric", "这台设备还没有录入指纹或面容", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "正在验证，请稍候", null)
            return
        }
        val key: SecretKey
        val cipher: Cipher
        try {
            key = secretKey()
            cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key)
        } catch (e: Exception) {
            val message = keyBrokenMessage(e) ?: "准备加密失败：${e.message}"
            result.error("protect_failed", message, null)
            return
        }

        onCrypto = { unlocked, pending ->
            try {
                val iv = unlocked.iv
                val cipherText = unlocked.doFinal(
                    Base64.decode(plainBase64, Base64.NO_WRAP)
                )
                // 输出 = iv 长度(1 字节) || iv || 密文，全部再 base64 一次。
                val combined = ByteArray(1 + iv.size + cipherText.size)
                combined[0] = iv.size.toByte()
                iv.copyInto(combined, 1)
                cipherText.copyInto(combined, 1 + iv.size)
                pending.success(Base64.encodeToString(combined, Base64.NO_WRAP))
            } catch (e: Exception) {
                pending.error("protect_failed", e.message ?: "加密失败", null)
            }
        }
        onCancel = { pending -> pending.success(null) }
        prompt(cipher, BiometricPrompt.PromptInfo.Builder()
            .setTitle("开启指纹解锁")
            .setSubtitle("验证一次，之后就能用指纹打开私密库")
            .setNegativeButtonText("取消")
            .setAllowedAuthenticators(AUTHENTICATORS)
            .build(), result)
    }

    private fun unprotect(blobBase64: String, result: MethodChannel.Result) {
        if (!biometricAvailable()) {
            result.error("no_biometric", "这台设备还没有录入指纹或面容", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "正在验证，请稍候", null)
            return
        }
        val combined = Base64.decode(blobBase64, Base64.NO_WRAP)
        if (combined.isEmpty()) {
            result.error("bad_data", "托管凭据是空的", null)
            return
        }
        val ivSize = combined[0].toInt()
        if (ivSize <= 0 || 1 + ivSize > combined.size) {
            result.error("bad_data", "托管凭据格式不对", null)
            return
        }
        val iv = combined.copyOfRange(1, 1 + ivSize)
        val cipherText = combined.copyOfRange(1 + ivSize, combined.size)

        val key: SecretKey
        val cipher: Cipher
        try {
            key = secretKey()
            cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                key,
                GCMParameterSpec(GCM_TAG_BITS, iv)
            )
        } catch (e: Exception) {
            val message = keyBrokenMessage(e) ?: "准备解密失败：${e.message}"
            result.error("unprotect_failed", message, null)
            return
        }

        onCrypto = { unlocked, pending ->
            try {
                val plain = unlocked.doFinal(cipherText)
                pending.success(Base64.encodeToString(plain, Base64.NO_WRAP))
            } catch (e: AEADBadTagException) {
                pending.error(
                    "unprotect_failed",
                    keyBrokenMessage(e) ?: "解密失败",
                    null
                )
            } catch (e: Exception) {
                pending.error("unprotect_failed", e.message ?: "解密失败", null)
            }
        }
        onCancel = { pending -> pending.success(null) }
        prompt(cipher, BiometricPrompt.PromptInfo.Builder()
            .setTitle("解锁私密笔记库")
            .setSubtitle("用指纹或面容验证")
            .setNegativeButtonText("取消")
            .setAllowedAuthenticators(AUTHENTICATORS)
            .build(), result)
    }
}
