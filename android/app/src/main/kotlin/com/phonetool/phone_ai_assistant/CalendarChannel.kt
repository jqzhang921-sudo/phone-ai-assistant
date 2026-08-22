package com.phonetool.phone_ai_assistant

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 只读日历。
 *
 * 本来用的是 device_calendar 插件，但它的 arePermissionsGranted() 是
 * `WRITE_CALENDAR && READ_CALENDAR`，而且挡在 retrieveEvents 前面——
 * 想读就必须连写权限一起要。这个 App 写日历走的是 intent（打开系统日历的
 * 新建页，用户自己点保存），根本用不上写权限，为了读而声明写是多余的授权。
 *
 * 所以自己查一遍 ContentProvider，只要 READ_CALENDAR。
 */
class CalendarChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "calendar_reader"
        private const val REQ_CODE = 9137
    }

    private var pending: MethodChannel.Result? = null
    private var pendingRange: Pair<Long, Long>? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listEvents" -> {
                val start = call.argument<Number>("start")?.toLong()
                val end = call.argument<Number>("end")?.toLong()
                if (start == null || end == null) {
                    result.error("ARGS", "缺少 start / end（毫秒时间戳）", null)
                    return
                }
                if (hasPermission()) {
                    result.success(query(start, end))
                } else {
                    // 权限申请是异步的，把 result 挂起来等回调
                    pending = result
                    pendingRange = Pair(start, end)
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(Manifest.permission.READ_CALENDAR),
                        REQ_CODE
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    /** 返回 true 表示这个 requestCode 是我们的，已经处理掉了 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQ_CODE) return false
        val r = pending
        val range = pendingRange
        pending = null
        pendingRange = null
        if (r == null || range == null) return true

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            r.success(query(range.first, range.second))
        } else {
            r.error("PERMISSION", "用户没给日历权限", null)
        }
        return true
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED

    /**
     * 查 Instances 而不是 Events。
     *
     * Events 表里存的是规则（「每周三 19:00」这种 RRULE），要自己按范围展开；
     * Instances 是系统已经展开好的一条条实例，直接给时间区间就行，
     * 重复日程不会漏也不用自己算。
     */
    private fun query(start: Long, end: Long): List<Map<String, Any?>> {
        val builder = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(builder, start)
        ContentUris.appendId(builder, end)

        val projection = arrayOf(
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.EVENT_LOCATION
        )

        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(
            builder.build(),
            projection,
            null,
            null,
            CalendarContract.Instances.BEGIN + " ASC"
        )?.use { c ->
            while (c.moveToNext()) {
                out.add(
                    mapOf(
                        "title" to (c.getString(0) ?: ""),
                        "begin" to c.getLong(1),
                        "end" to c.getLong(2),
                        "allDay" to (c.getInt(3) == 1),
                        "location" to c.getString(4)
                    )
                )
            }
        }
        return out
    }
}
