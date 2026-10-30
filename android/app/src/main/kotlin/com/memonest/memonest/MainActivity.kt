package com.memonest.memonest

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.annotation.NonNull
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 平台通道 `memonest/hello` 的 Android 实现。
 *
 * 和 Windows 侧（windows/runner/flutter_window.cpp）一一对应：
 * - available    生物识别能不能用
 * - authenticate 弹系统验证对话框
 * - protect      用 Keystore 里的 AES 密钥加密一段字节
 * - unprotect    解密
 *
 * 密钥由 Android Keystore 生成并保管，明文永远不出 TEE；
 * 换机、恢复出厂、清数据都会让它消失，`hello.bin` 就再也解不开——
 * 这正是我们要的语义，主密码始终是唯一的根密钥。
 */
// 必须用 FlutterFragmentActivity：androidx.biometric 的 BiometricPrompt
// 构造函数只收 FragmentActivity，用 FlutterActivity 会编译不过。
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "memonest/hello"
        private const val KEY_ALIAS = "memonest_vault_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
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
                            try {
                                result.success(protect(data))
                            } catch (e: Exception) {
                                result.error("protect_failed", e.message ?: "加密失败", null)
                            }
                        }
                    }
                    "unprotect" -> {
                        val data = call.argument<String>("data")
                        if (data == null) {
                            result.error("bad_args", "缺少 data", null)
                        } else {
                            try {
                                result.success(unprotect(data))
                            } catch (e: Exception) {
                                result.error("unprotect_failed", e.message ?: "解密失败", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun biometricAvailable(): Boolean {
        val manager = BiometricManager.from(this)
        val allowed = BiometricManager.Authenticators.BIOMETRIC_WEAK
        return manager.canAuthenticate(allowed) == BiometricManager.BIOMETRIC_SUCCESS
    }

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
        pendingResult = result

        val executor = ContextCompat.getMainExecutor(this)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(
                @NonNull authResult: BiometricPrompt.AuthenticationResult
            ) {
                finish(true)
            }

            override fun onAuthenticationError(code: Int, @NonNull msg: CharSequence) {
                // 用户取消（13 = ERROR_USER_CANCELED，10 = ERROR_NEGATIVE_BUTTON）
                // 也算 false，Dart 侧据此显示「已取消」而不是红字报错。
                finish(false)
            }

            override fun onAuthenticationFailed() {
                // 单次指纹不匹配：系统会让用户重试，这里不结束。
            }

            private fun finish(ok: Boolean) {
                val pending = pendingResult
                pendingResult = null
                pending?.success(ok)
            }
        }

        val dialog = BiometricPrompt(this, executor, callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(prompt)
            .setSubtitle("用指纹或面容验证")
            .setNegativeButtonText("取消")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            .build()
        dialog.authenticate(info)
    }

    // ---------- Keystore ----------

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
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

        // 只有在系统验证可用时才要求「每次使用都要验证」——不然在没录指纹的
        // 设备上这把密钥根本用不了，连创建私密库都会失败。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && biometricAvailable()) {
            builder.setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setUserAuthenticationParameters(
                    0, KeyProperties.AUTH_BIOMETRIC_STRONG
                )
            }
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun protect(plainBase64: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val cipherText = cipher.doFinal(Base64.getDecoder().decode(plainBase64))
        // 输出 = iv 长度(1 字节) || iv || 密文，全部再 base64 一次。
        val combined = ByteArray(1 + iv.size + cipherText.size)
        combined[0] = iv.size.toByte()
        iv.copyInto(combined, 1)
        cipherText.copyInto(combined, 1 + iv.size)
        return Base64.getEncoder().encodeToString(combined)
    }

    private fun unprotect(blobBase64: String): String {
        val combined = Base64.getDecoder().decode(blobBase64)
        val ivSize = combined[0].toInt()
        val iv = combined.copyOfRange(1, 1 + ivSize)
        val cipherText = combined.copyOfRange(1 + ivSize, combined.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(GCM_TAG_BITS, iv)
        )
        val plain = cipher.doFinal(cipherText)
        return Base64.getEncoder().encodeToString(plain)
    }
}
