package com.oviewer.oviewer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class UploadLinkOpener(private val activity: () -> Activity?) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "open") { result.notImplemented(); return }
        val uri = (call.arguments as? String)?.let { Uri.parse(it) }
        if (uri == null || uri.scheme != "https" || uri.userInfo != null ||
            (uri.port != -1 && uri.port != 443) || uri.host !in setOf(
                "upld.e-hentai.org", "e-hentai.org", "exhentai.org", "ehwiki.org",
                "forums.e-hentai.org", "developer.android.com", "developer.apple.com")) {
            result.success(false); return
        }
        val host = activity()
        if (host == null || host.isFinishing) { result.success(false); return }
        try {
            host.startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
            result.success(true)
        } catch (_: Exception) { result.success(false) }
    }
}
