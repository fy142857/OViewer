package com.oviewer.oviewer

import android.app.Activity
import android.net.Uri
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/** Temporarily aligns the existing login browser with the app's selected route. */
class AutomaticLoginCheck(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var active: Long? = null
    private var proxyApplied = false
    private var closing = false
    private val main = Executor { task -> activity.runOnUiThread(task) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toLong()
        if (id == null) { result.success(false); return }
        when (call.method) {
            "begin" -> begin(id, call.argument("proxy"), result)
            "close" -> if (id == active) dispose { result.success(null) } else result.success(null)
            else -> result.notImplemented()
        }
    }
    private fun begin(id: Long, proxy: String?, result: MethodChannel.Result) {
        if (active != null || closing) { result.success(false); return }
        active = id
        if (proxy.isNullOrEmpty()) { result.success(true); return }
        try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
                active = null; result.success(false); return
            }
            val uri = Uri.parse(if (proxy.contains("://")) proxy else "http://$proxy")
            if (uri.host.isNullOrEmpty() || uri.port !in 1..65535 || uri.userInfo != null ||
                uri.query != null || uri.fragment != null || uri.scheme !in setOf("http", "https", "socks5")) {
                active = null; result.success(false); return
            }
            // Match NetworkProxy's HTTP CONNECT policy, without a DIRECT fallback.
            val address = "http://${uri.encodedAuthority}"
            proxyApplied = true
            ProxyController.getInstance().setProxyOverride(
                ProxyConfig.Builder().addProxyRule(address).build(), main) { result.success(active == id) }
        } catch (_: Exception) { dispose { result.success(false) } }
    }
    fun dispose(done: () -> Unit = {}) {
        active = null
        closing = true
        if (proxyApplied) {
            proxyApplied = false
            ProxyController.getInstance().clearProxyOverride(main) { closing = false; done() }
        } else { closing = false; done() }
    }
}
