package com.oviewer.oviewer

import android.app.Activity
import android.content.ActivityNotFoundException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class SponsorBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val exporter = PageImageExporter(activity,
        executor = Executors.newFixedThreadPool(2), allowConcurrent = true,
        permissionRequest = 7315,
        namePattern = Regex("OViewer_sponsor_(wechat_[0-9]+\\.png|alipay_[0-9]+\\.jpg)"))

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveImage" -> exporter.onMethodCall(call, result)
            "openApp" -> {
                val packageName = when (call.arguments as? String) {
                    "wechat" -> "com.tencent.mm"
                    "alipay" -> "com.eg.android.AlipayGphone"
                    else -> { result.success(false); return }
                }
                try {
                    val intent = activity.packageManager.getLaunchIntentForPackage(packageName)
                    if (intent == null) { result.success(false); return }
                    activity.startActivity(intent)
                    result.success(true)
                } catch (_: ActivityNotFoundException) { result.success(false) }
                catch (_: SecurityException) { result.success(false) }
            }
            else -> result.notImplemented()
        }
    }

    fun permissionResult(code: Int, results: IntArray) = exporter.permissionResult(code, results)
    fun dispose() = exporter.dispose()
}
