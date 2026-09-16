package com.phonetool.live_capsule

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `live_capsule` 通道：正在进行的一件事，显示在挖孔那一圈（ColorOS 叫流体云）。
 *
 * 走的是安卓 16 原生的「实时更新」（Live Updates），不是 OPPO 的 SDK——
 * ColorOS 16 的流体云直接显示按谷歌规范发的通知，所以不用接私有 SDK、
 * 也不用申请白名单。系统要求（缺一条就只是普通通知，不进胶囊）：
 *
 * - manifest 里有 POST_PROMOTED_NOTIFICATIONS（见本插件的 AndroidManifest）
 * - 通知带 `android.requestPromotedOngoing` 这个 extra
 * - 是常驻的（ongoing）、有标题、没有自定义布局、没有 colorized
 * - 频道重要度不能是 IMPORTANCE_MIN
 *
 * 三个方法：
 *
 * - `supported`：系统够不够新、她有没有在设置里把这个 App 的实时更新关掉
 * - `show`：亮一个胶囊，或者改已经亮着的那个（同一个 id 就是改）
 * - `end`：事情做完了，收起来
 *
 * 不抛错：后台（WorkManager 那台引擎）里抛出去没人接得住，回 false 就行。
 */
class LiveCapsulePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    companion object {
        private const val CHANNEL_ID = "live"
        private const val CHANNEL_NAME = "正在进行"

        /** Notification.EXTRA_REQUEST_PROMOTED_ONGOING。写字面量，低版本编译也不碍事。 */
        private const val EXTRA_PROMOTED = "android.requestPromotedOngoing"

        /** 实时更新是安卓 16 才有的。 */
        private const val ANDROID_16 = 36
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "live_capsule")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supported" -> result.success(supported())
            "show" -> result.success(
                show(
                    id = call.argument<Int>("id") ?: 1,
                    title = call.argument<String>("title") ?: "",
                    text = call.argument<String>("text") ?: "",
                    short = call.argument<String>("short"),
                )
            )
            "end" -> {
                manager()?.cancel(call.argument<Int>("id") ?: 1)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun manager(): NotificationManager? =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    /**
     * 能不能亮胶囊。
     *
     * `canPostPromotedNotifications()` 是她在系统设置里给这个 App 的开关——
     * 关了就当没有这个功能，别退回去发一条普通常驻通知：那会在通知栏里赖着不走，
     * 比没有还烦。
     */
    private fun supported(): Boolean {
        if (Build.VERSION.SDK_INT < ANDROID_16) return false
        val nm = manager() ?: return false
        if (!nm.areNotificationsEnabled()) return false
        return try {
            nm.canPostPromotedNotifications()
        } catch (e: Throwable) {
            // 厂商 ROM 把这个方法改了的话，当作不支持，不冒险。
            false
        }
    }

    private fun show(id: Int, title: String, text: String, short: String?): Boolean {
        if (!supported() || title.isBlank()) return false
        val nm = manager() ?: return false
        try {
            // 重要度用 LOW：胶囊本身不需要响，而 IMPORTANCE_MIN 会让它没资格升级。
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "它正在做的事，显示在屏幕上方那一圈" }
            )

            val builder = Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(smallIcon())
                .setContentTitle(title)
                .setContentText(text)
                // 必须是常驻的，否则系统不给升级。
                .setOngoing(true)
                // ⚠️ 不能 setColorized、不能 setCustomContentView、不能当组摘要，
                // 这三样里任何一个都会让它掉回普通通知。
                .setShowWhen(false)
                .setContentIntent(openApp())

            // 胶囊那一小条字。太长系统会自己截，这里不硬截，交给调用方给短的。
            if (!short.isNullOrBlank()) {
                builder.setShortCriticalText(short)
            }

            val n = builder.build()
            n.extras.putBoolean(EXTRA_PROMOTED, true)
            nm.notify(id, n)
            return true
        } catch (e: Throwable) {
            return false
        }
    }

    /**
     * 通知栏小图标。插件拿不到 App 的资源 id，按名字找：主 App 里那个白色墙角
     * （res/drawable/ic_stat_nook）。找不到就退回 App 图标——总比没有强。
     */
    private fun smallIcon(): Int {
        val byName = context.resources.getIdentifier("ic_stat_nook", "drawable", context.packageName)
        return if (byName != 0) byName else context.applicationInfo.icon
    }

    /** 点胶囊回到 App。没有这个的话点了没反应，像坏的。 */
    private fun openApp(): PendingIntent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) ?: return null
        return PendingIntent.getActivity(
            context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }
}
