package com.oviewer.oviewer

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ReleaseLinkOpener(private val activity: Activity) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "open") { result.notImplemented(); return }
        val uri = (call.arguments as? String)?.let { Uri.parse(it) }
        if (uri == null || uri.scheme != "https" || uri.host != "github.com" ||
            uri.userInfo != null || (uri.port != -1 && uri.port != 443) ||
            uri.query != null || uri.fragment != null ||
            !Regex("^/fy142857/OViewer/releases/tag/[^/]+$").matches(uri.path ?: "")) {
            result.success(false)
            return
        }
        try {
            // CATEGORY_APP_BROWSER targets a browser rather than a GitHub app link.
            val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
            intent.selector = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_BROWSER)
            activity.startActivity(intent)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        } catch (_: SecurityException) {
            result.success(false)
        }
    }
}
