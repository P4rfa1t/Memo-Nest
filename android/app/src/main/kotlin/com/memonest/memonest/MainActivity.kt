package com.memonest.memonest

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
 * ## 设计：与 Windows 的 DPAPI 同构
 *
 * Windows 上托管用的是 `CryptProtectData`——密钥由系统按当前用户派生，
 * 加解密本身**不要求**先通过 Hello 验证，Hello 只是另一道门（Dart 侧
 * `HelloUnlock.retrieve()` 先 `verify()` 再 DPAPI 解密）。
 *
 * Android 早期实现走的是另一条路：`setUserAuthenticationRequired(true)`
 * 把生物验证焊死在密钥上，加解密必须用 `BiometricPrompt.CryptoObject`。
 * 这条路在真机上极脆——`Cipher.init` 就可能抛 `UserNotAuthenticatedException`
 * （不在已知异常列表里，于是 UI 只看到「准备加密失败」），密钥一旦因为
 * 换指纹、改锁屏密码被作废就更没法兜底。结果是 `hello.bin` 从来没被写出来，
 * 用户明明用主密码解锁过，界面还是提示「没有可用的系统凭据」。
 *
 * 现在改成和 Windows 一致的模型：Keystore 里放一把**设备绑定**的
 * AES-256-GCM 密钥（受 TEE/StrongBox 保护，出不了这台设备），
 * 生物验证由 `BiometricPrompt` 在加解密之前单独做一次。安全性不降级
 * （明文库密钥仍然只以密文形式落盘），但整类 Keystore 认证强制失败消失了。
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
         * 密钥别名。
         *
         * - `memonest_vault_key`   最初版本，要求 AUTH_BIOMETRIC_STRONG
         * - `memonest_vault_key_v2` 要求「每次使用都当场验证」，但没有走
         *   CryptoObject，加解密必然抛 UserNotAuthenticatedException
         * - `_v3` 就是现在这把：设备绑定、不要求认证，验证交给 BiometricPrompt
         *
         * 旧的两把都留着当遗物，解析密钥时顺手删掉——它们永远用不了了，
         * 留着只会让人以为凭据还在。
         */
        private const val KEY_ALIAS = "memonest_vault_key_v3"
        private val LEGACY_ALIASES = listOf(
            "memonest_vault_key",
            "memonest_vault_key_v2",
        )

        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }

    /** BiometricPrompt 是异步回调的，这里挂住等待中的 Dart 结果。 */
    private var pendingResult: MethodChannel.Result? = null

    /** 验证通过后要做的加解密。 */
    private var onVerified: ((MethodChannel.Result) -> Unit)? = null

    /** 用户取消或出错时的回调。 */
    private var onCancel: ((MethodChannel.Result) -> Unit)? = null

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

    // ---------- 能力探测 ----------

    /**
     * 能用的认证方式。指纹/面容优先，没有生物识别时退回锁屏密码——
     * 后者在很多国产 ROM 上反而是唯一可用的那一档。
     */
    private fun authenticators(): Int {
        val manager = BiometricManager.from(this)
        val success = BiometricManager.BIOMETRIC_SUCCESS
        if (manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) == success) {
            return BiometricManager.Authenticators.BIOMETRIC_WEAK
        }
        if (manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == success) {
            return BiometricManager.Authenticators.BIOMETRIC_STRONG
        }
        if (manager.canAuthenticate(BiometricManager.Authenticators.DEVICE_CREDENTIAL) == success) {
            return BiometricManager.Authenticators.DEVICE_CREDENTIAL
        }
        return 0
    }

    private fun biometricAvailable(): Boolean = authenticators() != 0

    private fun promptInfo(title: String, subtitle: String): BiometricPrompt.PromptInfo {
        val allowed = authenticators()
        val builder = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
        if (allowed == BiometricManager.Authenticators.DEVICE_CREDENTIAL) {
            // 用锁屏密码时不能再设「取消」按钮，否则 Builder.build() 直接抛
            // IllegalArgumentException（系统自己提供返回键）。
            builder.setAllowedAuthenticators(allowed)
        } else {
            builder.setNegativeButtonText("取消").setAllowedAuthenticators(allowed)
        }
        return builder.build()
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
        onVerified = { pending -> pending.success(true) }
        onCancel = { pending -> pending.success(false) }
        show(promptInfo(prompt, "用指纹或面容验证"), result)
    }

    private fun show(info: BiometricPrompt.PromptInfo, result: MethodChannel.Result) {
        pendingResult = result
        val executor = ContextCompat.getMainExecutor(this)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(
                @NonNull authResult: BiometricPrompt.AuthenticationResult
            ) {
                val pending = takePending() ?: return
                val action = onVerified
                onVerified = null
                onCancel = null
                if (action == null) {
                    pending.success(true)
                } else {
                    action(pending)
                }
            }

            override fun onAuthenticationError(code: Int, @NonNull msg: CharSequence) {
                // 用户取消（13 = ERROR_USER_CANCELED，10 = ERROR_NEGATIVE_BUTTON）
                // 也算 false，Dart 侧据此显示「已取消」而不是红字报错。
                val pending = takePending() ?: return
                val action = onCancel
                onVerified = null
                onCancel = null
                action?.invoke(pending) ?: pending.success(false)
            }

            override fun onAuthenticationFailed() {
                // 单次指纹不匹配：系统会让用户重试，这里不结束。
            }
        }
        BiometricPrompt(this, executor, callback).authenticate(info)
    }

    /** 只取一次，避免回调重复触发时把同一个 Result 应答两遍。 */
    private fun takePending(): MethodChannel.Result? {
        val pending = pendingResult
        pendingResult = null
        return pending
    }

    // ---------- Keystore ----------

    private fun keystore(): KeyStore =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun secretKey(): SecretKey {
        val store = keystore()
        for (legacy in LEGACY_ALIASES) {
            if (!store.containsAlias(legacy)) continue
            try {
                store.deleteEntry(legacy)
            } catch (_: Exception) {
                // 删不掉不影响新密钥
            }
        }

        val existing = try {
            store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        } catch (_: Exception) {
            // 密钥被系统作废（换指纹、改锁屏密码、恢复出厂后残留的别名）。
            // 留着只会让每次加解密都失败，删掉重新生成一把。
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
        val spec = KeyGenParameterSpecHolder.build(KEY_ALIAS)
        generator.init(spec)
        return generator.generateKey()
    }

    /**
     * 生成参数单独放一个对象里，纯粹是为了让上面的逻辑保持线性。
     *
     * 注意**不设** `setUserAuthenticationRequired`：认证交给 BiometricPrompt，
     * 密钥只保证「绑在这台设备的 TEE 里、拷不走」。设了它，`Cipher.init`
     * 就会在没有当场验证的情况下抛异常，那是之前一直失败的根因。
     */
    private object KeyGenParameterSpecHolder {
        fun build(alias: String): android.security.keystore.KeyGenParameterSpec =
            android.security.keystore.KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // 随机 IV，由系统在 Cipher.init 时生成，一次一密。
                .setRandomizedEncryptionRequired(true)
                .build()
    }

    /** 失败时给一句能对得上号的说明，别把异常类名藏起来。 */
    private fun describe(e: Throwable, prefix: String): String {
        val name = e.javaClass.simpleName
        val detail = e.message?.trim().orEmpty()
        return when {
            detail.isEmpty() -> "$prefix：$name"
            detail.startsWith(name) -> "$prefix：$detail"
            else -> "$prefix：$name（$detail）"
        }
    }

    // ---------- 加解密 ----------

    private fun protect(plainBase64: String, result: MethodChannel.Result) {
        if (!biometricAvailable()) {
            result.error("no_biometric", "这台设备还没有录入指纹、面容或锁屏密码", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "正在验证，请稍候", null)
            return
        }
        val plain = try {
            Base64.decode(plainBase64, Base64.NO_WRAP)
        } catch (e: Exception) {
            result.error("bad_data", "待托管的密钥不是合法的 Base64", null)
            return
        }

        onVerified = { pending ->
            try {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.ENCRYPT_MODE, secretKey())
                val iv = cipher.iv
                val cipherText = cipher.doFinal(plain)
                // 输出 = iv 长度(1 字节) || iv || 密文，整体再 base64 一次。
                val combined = ByteArray(1 + iv.size + cipherText.size)
                combined[0] = iv.size.toByte()
                iv.copyInto(combined, 1)
                cipherText.copyInto(combined, 1 + iv.size)
                pending.success(Base64.encodeToString(combined, Base64.NO_WRAP))
            } catch (e: Exception) {
                pending.error("protect_failed", describe(e, "加密失败"), null)
            }
        }
        onCancel = { pending -> pending.success(null) }
        show(promptInfo("开启指纹解锁", "验证一次，之后就能用指纹打开私密库"), result)
    }

    private fun unprotect(blobBase64: String, result: MethodChannel.Result) {
        if (!biometricAvailable()) {
            result.error("no_biometric", "这台设备还没有录入指纹、面容或锁屏密码", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "正在验证，请稍候", null)
            return
        }
        val combined = try {
            Base64.decode(blobBase64, Base64.NO_WRAP)
        } catch (e: Exception) {
            result.error("bad_data", "托管凭据不是合法的 Base64", null)
            return
        }
        if (combined.isEmpty()) {
            result.error("bad_data", "托管凭据是空的", null)
            return
        }
        val ivSize = combined[0].toInt()
        if (ivSize <= 0 || 1 + ivSize >= combined.size) {
            result.error("bad_data", "托管凭据格式不对", null)
            return
        }
        val iv = combined.copyOfRange(1, 1 + ivSize)
        val cipherText = combined.copyOfRange(1 + ivSize, combined.size)

        onVerified = { pending ->
            try {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    secretKey(),
                    GCMParameterSpec(GCM_TAG_BITS, iv)
                )
                val plain = cipher.doFinal(cipherText)
                pending.success(Base64.encodeToString(plain, Base64.NO_WRAP))
            } catch (e: AEADBadTagException) {
                // 密钥重建过（旧别名被清掉后生成的新密钥），旧密文自然解不开。
                pending.error(
                    "unprotect_failed",
                    "系统凭据已失效，请用主密码解锁",
                    null
                )
            } catch (e: Exception) {
                pending.error("unprotect_failed", describe(e, "解密失败"), null)
            }
        }
        onCancel = { pending -> pending.success(null) }
        show(promptInfo("解锁私密笔记库", "用指纹或面容验证"), result)
    }
}