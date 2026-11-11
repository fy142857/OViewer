package com.oviewer.oviewer

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Keep the existing runtime alive for an in-process cache clear, without a service. */
class ImageCacheWorkBridge(private val app: OViewerApplication) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "retain" -> { app.retainWork("image-cache"); result.success(null) }
            "release" -> { app.releaseWork("image-cache"); result.success(null) }
            else -> result.notImplemented()
        }
    }
}
