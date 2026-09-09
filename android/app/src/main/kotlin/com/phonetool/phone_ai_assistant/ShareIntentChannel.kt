package com.phonetool.phone_ai_assistant

import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 别的 App 分享过来的一段文字。
 *
 * 只有读书版在 manifest 里挂了 ACTION_SEND / ACTION_PROCESS_TEXT（见
 * `src/reading/AndroidManifest.xml`），所以主 App 里这个通道永远返回 null，
 * 白搭一个 handler 而已，不用为它分 flavor。
 *
 * ## 为什么要「存着等人来取」，而不是直接推给 Dart
 *
 * 冷启动时分享的 intent 已经在 onCreate 里了，而那时候 Flutter 引擎刚起来，
 * Dart 那边还没注册 handler——这时候推过去等于扔进虚空。所以：
 *
 * - **存一份**，Dart 起来后自己来 `take` 一次（取走即清，不会重复处理）
 * - App 已经在跑的时候再来一条，走 onNewIntent，那时候 Dart 一定在，
 *   顺手 push 一次让它立刻响应，同时也仍然存着——万一 push 丢了，
 *   下次回到前台 Dart 还会再 take 一遍。
 *
 * 两条路都留着，是因为「分享过去了但 App 没反应」这种 bug 只在真机上偶发，
 * 查起来极贵。宁可多一次空 take。
 */
class ShareIntentChannel(private val activity: android.app.Activity? = null) {
    companion object {
        const val CHANNEL = "share_intent"
    }

    private var pending: String? = null
    private var channel: MethodChannel? = null

    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) = handleCall(call, result)

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 取走即清。Dart 每次回到前台都会问一次，不清的话同一段会反复弹。
            "take" -> {
                val text = pending
                pending = null
                result.success(text)
            }
            // 往外发一段文字，走系统分享面板。
            //
            // 导出讨论用的。不自己写文件是因为：写进 Download 要过 MediaStore
            // 和权限那一套，而**分享面板本来就通向所有地方**——微信、便签、
            // 网盘、Telegram，用户想存哪存哪，还不用给我们任何权限。
            "send" -> {
                val text = call.argument<String>("text")
                if (text.isNullOrBlank()) {
                    result.error("EMPTY", "没有可分享的内容", null)
                    return@handleCall
                }
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "没有可用的界面来发起分享", null)
                    return@handleCall
                }
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                    call.argument<String>("subject")?.let {
                        putExtra(Intent.EXTRA_SUBJECT, it)
                    }
                }
                act.startActivity(Intent.createChooser(send, "分享讨论"))
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** 冷启动：把 intent 里的文字存下来，等 Dart 起来取。 */
    fun onCreate(intent: Intent?) {
        extract(intent)?.let { pending = it }
    }

    /** App 已在前台时又分享过来一条：存一份，同时推一次。 */
    fun onNewIntent(intent: Intent?) {
        val text = extract(intent) ?: return
        pending = text
        channel?.invokeMethod("onShare", text)
    }

    /**
     * 从 intent 里把文字抠出来。
     *
     * EXTRA_SUBJECT 也要：不少阅读器分享一本书时，书名在 subject 里，
     * text 里只有一句推广语和链接。丢了 subject 就等于丢了书名。
     */
    private fun extract(intent: Intent?): String? {
        if (intent == null) return null
        val text = when (intent.action) {
            Intent.ACTION_SEND -> {
                if (intent.type?.startsWith("text/") != true) return null
                val body = intent.getStringExtra(Intent.EXTRA_TEXT)
                val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
                listOfNotNull(subject, body)
                    .filter { it.isNotBlank() }
                    // subject 常常就是 body 的第一行，重复的不要贴两遍
                    .distinct()
                    .joinToString("\n")
            }
            Intent.ACTION_PROCESS_TEXT ->
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            else -> null
        }
        return text?.takeIf { it.isNotBlank() }
    }
}
