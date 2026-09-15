package com.phonetool.screen_glance

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.view.accessibility.AccessibilityEvent
import android.view.inputmethod.InputMethodManager

/**
 * 看一眼屏幕用的无障碍服务。**自己什么都不做**，只是在那儿等着被调用。
 *
 * ## 为什么走无障碍，不走录屏（MediaProjection）
 *
 * 录屏从安卓 14 起每次开始都要她点一次「开始录制或投放」，而且录着的时候
 * 状态栏一直挂着图标。「后台醒来想看一眼」这件事，她人不在手机前面点不了。
 *
 * 无障碍的 [takeScreenshot]（安卓 11+）只要她在系统设置里开一次，之后随时能截，
 * 不弹框。代价是这个开关权限大，所以 xml 里只要了截屏，没要读界面内容。
 *
 * ## 前台是哪个 App
 *
 * 排除名单要靠它：她在名单里的 App 里，就不截。从窗口切换事件的包名里拿，
 * **输入法除外**——键盘弹出来也算一次窗口变化，不滤的话她一打字，
 * 「前台」就变成了搜狗输入法，排除名单形同虚设。
 */
class GlanceService : AccessibilityService() {

    companion object {
        /** 系统绑上了才有。进程被杀、她关了开关，都会变回 null。 */
        @Volatile
        var instance: GlanceService? = null
            private set

        /** 最近一次切到前台的包名。服务刚连上、还没切过窗口时是 null。 */
        @Volatile
        var foreground: String? = null
            private set

        /**
         * 最近一个**不是我们自己**的前台包名。
         *
         * 悬浮窗要用：她开着小窗和它聊天、底下全屏刷小红书时，[foreground] 是
         * 我们（焦点在小窗上），可屏幕上大半是小红书。排除名单得拿它来比，
         * 不然小窗往被排除的 App 上一盖，名单就绕过去了。
         */
        @Volatile
        var lastOther: String? = null
            private set

        const val SELF_PREFIX = "com.phonetool.phone_ai_assistant"
    }

    private var imePackages: Set<String> = emptySet()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        imePackages = try {
            (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                .inputMethodList.map { it.packageName }.toSet()
        } catch (_: Exception) {
            emptySet()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg in imePackages) return
        foreground = pkg
        if (!pkg.startsWith(SELF_PREFIX)) lastOther = pkg
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }
}
