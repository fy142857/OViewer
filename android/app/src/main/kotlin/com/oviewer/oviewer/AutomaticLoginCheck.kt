package com.oviewer.oviewer

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Temporarily aligns the existing login browser with the app's selected route. */
class AutomaticLoginCheck(private val activity: Activity,
    private val lease: BrowserProxyLease = BrowserProxyLease.shared) : MethodChannel.MethodCallHandler {
    private var active: Long? = null
    private var closing = false
    private val instance = UUID.randomUUID().toString()
    private fun owner(id: Long) = "login:$instance:$id"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toLong()
        if (id == null) { result.success(false); return }
        when (call.method) {
            "begin" -> begin(id, call.argument("proxy"), result)
            "close" -> if (id == active) dispose { success ->
                if (success) result.success(null)
                else result.error("proxy_cleanup", "The browser network route could not be restored.", null)
            } else result.success(null)
            else -> result.notImplemented()
        }
    }
    private fun begin(id: Long, proxy: String?, result: MethodChannel.Result) {
        if (active != null || closing) { result.success(false); return }
        active = id
        activity.runOnUiThread {
            lease.acquire(owner(id), proxy) { ready ->
                if (!ready && !lease.heldBy(owner(id)) && active == id) active = null
                result.success(ready && active == id && !closing)
            }
        }
    }
    fun dispose(done: (Boolean) -> Unit = {}) {
        val id = active
        if (id == null) { closing = false; done(true); return }
        closing = true
        activity.runOnUiThread {
            lease.release(owner(id)) { success ->
                if (success && active == id) active = null
                closing = !success
                done(success)
            }
        }
    }
}
