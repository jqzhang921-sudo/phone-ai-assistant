package com.phonetool.screen_glance

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Display
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * `screen_glance` 通道。四个方法：
 *
 * - `status`：系统版本够不够、她在设置里开没开、服务现在绑没绑上
 * - `openSettings`：把她送到无障碍设置页（这个开关只能她自己开）
 * - `check`：现在能不能看——**不截**，只回答为什么不能。给「先问模型想不想看」
 *   之前用：锁着屏就别白花一次模型调用
 * - `capture`：截一张，缩小、压成 WebP 交回去
 *
 * 不能看的时候不抛错，回 `{miss: 原因}`。在后台里抛出去没人接得住。
 */
class ScreenGlancePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "screen_glance")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(
                mapOf(
                    "supported" to supported(),
                    "enabled" to enabledInSettings(),
                    "bound" to (GlanceService.instance != null),
                )
            )
            "openSettings" -> {
                try {
                    context.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
            "check" -> result.success(precheck(excludedOf(call), allowInAppOf(call)))
            "capture" -> capture(call, result)
            else -> result.notImplemented()
        }
    }

    private fun supported() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    /** 设置里开了没有。和「绑没绑上」分开：刚开完、进程还没被系统拉起来的时候两者不一样。 */
    private fun enabledInSettings(): Boolean {
        val me = ComponentName(context, GlanceService::class.java).flattenToString()
        val list = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return list.split(':').any { it.equals(me, ignoreCase = true) }
    }

    @Suppress("UNCHECKED_CAST")
    private fun excludedOf(call: MethodCall): Set<String> =
        ((call.argument<List<String>>("excluded")) ?: emptyList()).toSet()

    private fun allowInAppOf(call: MethodCall): Boolean =
        call.argument<Boolean>("allowInApp") ?: false

    /**
     * 现在能不能看。能看回 `{package, label}`，不能看回 `{miss, package?}`。
     *
     * 顺序是从「最不该看」往下排：锁屏 > 在我们自己 App 里 > 在排除名单里。
     *
     * [allowInApp]：她开着悬浮窗聊天，屏幕大半是底下那个 App。这时前台虽然是
     * 我们，照样能看——但排除名单和 App 名字改用 [GlanceService.lastOther]，
     * 那才是屏幕上真正在放的东西。
     */
    private fun precheck(excluded: Set<String>, allowInApp: Boolean = false): Map<String, Any?> {
        if (!supported()) return mapOf("miss" to "unsupported")
        if (GlanceService.instance == null) return mapOf("miss" to "off")

        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!power.isInteractive) return mapOf("miss" to "screen_off")
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (keyguard.isKeyguardLocked) return mapOf("miss" to "locked")

        val foreground = GlanceService.foreground
        // 主 App 和读书版都算「在我们这儿」：她就在跟它说话，全屏的话截到的只是聊天页。
        val mine = foreground != null && foreground.startsWith(GlanceService.SELF_PREFIX)
        if (mine && !allowInApp) {
            return mapOf("miss" to "in_app", "package" to foreground)
        }
        // 悬浮窗：屏幕上真正在放的是底下那个 App。
        val pkg = if (mine) GlanceService.lastOther else foreground
        if (pkg != null && pkg in excluded) {
            // 排除名单里的，连名字都不往回传——名单的意思就是「当它不存在」。
            return mapOf("miss" to "excluded")
        }
        return mapOf("package" to pkg, "label" to labelOf(pkg))
    }

    private fun labelOf(pkg: String?): String? {
        if (pkg == null) return null
        return try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) {
            null
        }
    }

    private fun capture(call: MethodCall, result: MethodChannel.Result) {
        val pre = precheck(excludedOf(call), allowInAppOf(call))
        if (pre.containsKey("miss")) {
            result.success(pre)
            return
        }
        val service = GlanceService.instance
        if (service == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(mapOf("miss" to "off"))
            return
        }
        val maxSide = call.argument<Int>("maxSide") ?: 1280
        val quality = call.argument<Int>("quality") ?: 70

        service.takeScreenshot(
            Display.DEFAULT_DISPLAY,
            service.mainExecutor,
            object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(shot: AccessibilityService.ScreenshotResult) {
                    // 缩图和压缩挪出主线程：一张 1080×2400 的图压 WebP 要上百毫秒。
                    Thread {
                        val reply: Map<String, Any?> = try {
                            val bytes = encode(shot, maxSide, quality)
                            pre + mapOf("bytes" to bytes)
                        } catch (e: Exception) {
                            mapOf("miss" to "failed", "detail" to (e.message ?: "$e"))
                        }
                        main.post { result.success(reply) }
                    }.start()
                }

                override fun onFailure(errorCode: Int) {
                    val miss = when (errorCode) {
                        // 支付页、输密码的页面（FLAG_SECURE）：系统不让截，这是对的。
                        AccessibilityService.ERROR_TAKE_SCREENSHOT_SECURE_WINDOW -> "secure"
                        AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT -> "too_fast"
                        else -> "failed"
                    }
                    result.success(mapOf("miss" to miss, "detail" to "code $errorCode"))
                }
            },
        )
    }

    private fun encode(
        shot: AccessibilityService.ScreenshotResult,
        maxSide: Int,
        quality: Int,
    ): ByteArray {
        val buffer = shot.hardwareBuffer
        try {
            val hardware = Bitmap.wrapHardwareBuffer(buffer, shot.colorSpace)
                ?: throw IllegalStateException("截图缓冲区转不成图")
            // 硬件位图不能缩放也不能压缩，先拷成普通的。
            val soft = hardware.copy(Bitmap.Config.ARGB_8888, false)
            hardware.recycle()

            val longest = maxOf(soft.width, soft.height)
            val scaled = if (longest > maxSide) {
                val k = maxSide.toFloat() / longest
                Bitmap.createScaledBitmap(
                    soft,
                    (soft.width * k).toInt(),
                    (soft.height * k).toInt(),
                    true,
                ).also { soft.recycle() }
            } else {
                soft
            }

            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.WEBP_LOSSY, quality, out)
            scaled.recycle()
            return out.toByteArray()
        } finally {
            buffer.close()
        }
    }
}
