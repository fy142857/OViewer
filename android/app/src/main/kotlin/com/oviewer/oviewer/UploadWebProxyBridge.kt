package com.oviewer.oviewer

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Application-owned so an Activity recreation cannot clear a live upload browser's proxy. */
class UploadWebProxyBridge(
    private val onActiveChanged: (Boolean) -> Unit,
    private val lease: BrowserProxyLease = BrowserProxyLease.shared,
) : MethodChannel.MethodCallHandler {
    private var active: String? = null
    private fun owner(id: String) = "upload-web:$id"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id == null || !id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) {
            result.error("invalid_id", "Invalid browser session.", null); return
        }
        when (call.method) {
            "begin" -> {
                if (active != null) { result.success(false); return }
                active = id
                onActiveChanged(true)
                lease.acquire(owner(id), call.argument("proxy")) { ready ->
                    if (!ready && !lease.heldBy(owner(id)) && active == id) {
                        active = null; onActiveChanged(false)
                    }
                    result.success(ready && active == id)
                }
            }
            "check" -> result.success(active == id && lease.readyFor(owner(id)))
            "close" -> close(id) { success ->
                if (success) result.success(null)
                else result.error("proxy_cleanup", "The browser network route could not be restored.", null)
            }
            else -> result.notImplemented()
        }
    }

    private fun close(id: String, done: (Boolean) -> Unit) {
        if (active != id) { done(true); return }
        lease.release(owner(id)) { success ->
            if (success && active == id) { active = null; onActiveChanged(false) }
            done(success)
        }
    }

    fun dispose() { active?.let { close(it) {} } }
}
