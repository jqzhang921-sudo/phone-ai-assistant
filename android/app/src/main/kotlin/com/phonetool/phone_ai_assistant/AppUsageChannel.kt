package com.phonetool.phone_ai_assistant

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Process
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 只读「用了哪个 app、用了多久」。
 *
 * 拿到的只有**包名和时长**，拿不到任何内容——它能知道你在微信里待了 40 分钟，
 * 不知道你说了什么。这是这条路和截屏最根本的区别，也是选它的原因。
 *
 * PACKAGE_USAGE_STATS 不是普通权限，requestPermissions 要不来：必须让用户自己
 * 去「设置 → 有权查看使用情况的应用」里开。所以这里分成两个方法——
 * [hasPermission] 问状态，[openSettings] 把人送过去，中间不假装能自动搞定。
 *
 * 判断有没有权限走 AppOpsManager 而不是 checkSelfPermission：这个 op 是用户在
 * 系统设置里逐个 app 打开的，PackageManager 那套对它一律返回未授予。
 */
class AppUsageChannel(private val context: Context) {

    companion object {
        const val CHANNEL = "app_usage"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            "openSettings" -> {
                val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    // 有些定制系统没有这个设置页。报出去，让上层说人话，
                    // 而不是让用户点了没反应。
                    result.error("NO_SETTINGS", "打不开使用情况权限页：${e.message}", null)
                }
            }
            "query" -> query(call, result)
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean {
        val ops = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
            ?: return false
        val mode = ops.unsafeCheckOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            context.packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /**
     * [start]/[end] 是毫秒时间戳。
     *
     * 用 INTERVAL_BEST 而不是 INTERVAL_DAILY：后者按自然日切块，问「最近三小时」
     * 会拿回整天的汇总，时长直接虚高一大截。
     *
     * 时长为 0 的一律丢掉。系统会把一大堆从没进过前台的包也列出来，留着只会让
     * 上层每次都要再滤一遍。
     */
    private fun query(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("NO_PERMISSION", "还没有「查看使用情况」的权限", null)
            return
        }
        val start = call.argument<Number>("start")?.toLong()
        val end = call.argument<Number>("end")?.toLong()
        if (start == null || end == null) {
            result.error("ARGS", "缺少 start / end（毫秒时间戳）", null)
            return
        }

        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
        if (usm == null) {
            result.error("NO_SERVICE", "系统没有 UsageStatsManager", null)
            return
        }

        val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_BEST, start, end)
        if (stats == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }

        // 同一个包在区间里可能有多条记录，按包名合并。
        val merged = HashMap<String, LongArray>() // pkg -> [totalMs, lastUsed]
        for (s in stats) {
            if (s.totalTimeInForeground <= 0) continue
            val cur = merged[s.packageName]
            if (cur == null) {
                merged[s.packageName] = longArrayOf(s.totalTimeInForeground, s.lastTimeUsed)
            } else {
                cur[0] += s.totalTimeInForeground
                if (s.lastTimeUsed > cur[1]) cur[1] = s.lastTimeUsed
            }
        }

        val pm = context.packageManager
        val out = merged.entries
            .sortedByDescending { it.value[0] }
            .map { (pkg, v) ->
                mapOf(
                    "package" to pkg,
                    "label" to labelOf(pm, pkg),
                    "totalMs" to v[0],
                    "lastUsed" to v[1],
                )
            }
        result.success(out)
    }

    /**
     * 包名换成看得懂的名字。查不到就退回包名——不要返回「未知应用」那种占位，
     * 排除名单是按包名存的，界面上至少得让人认出这一条是谁。
     */
    private fun labelOf(pm: PackageManager, pkg: String): String = try {
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        pkg
    }
}
