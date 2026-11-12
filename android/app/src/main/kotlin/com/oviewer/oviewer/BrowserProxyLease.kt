package com.oviewer.oviewer

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import java.util.concurrent.Executor

interface BrowserProxyBackend {
    fun supported(): Boolean
    fun apply(address: String, done: (Boolean) -> Unit)
    fun clear(done: (Boolean) -> Unit)
}

/** ProxyController is process-global. Login and upload browsers share this owner-aware lease. */
class BrowserProxyLease(private val backend: BrowserProxyBackend) {
    companion object {
        val shared by lazy { BrowserProxyLease(AndroidBrowserProxyBackend()) }

        fun address(value: String): String? = runCatching {
            val uri = Uri.parse(if (value.contains("://")) value else "http://$value")
            if (uri.host.isNullOrEmpty() || uri.port !in 1..65535 || uri.userInfo != null ||
                uri.query != null || uri.fragment != null || !uri.path.isNullOrEmpty() && uri.path != "/" ||
                uri.scheme !in setOf("http", "https", "socks5")) null
            else "http://${uri.encodedAuthority}" // Same effective HTTP CONNECT policy as NetworkProxy.
        }.getOrNull()
    }

    private class Lease(val owner: String, var begin: ((Boolean) -> Unit)?) {
        var applied = false
        var applying = false
        var ready = false
        var closing = false
        var clearing = false
        var clearSerial = 0
        val closers = mutableListOf<(Boolean) -> Unit>()
    }
    private var current: Lease? = null

    fun heldBy(owner: String): Boolean = current?.owner == owner
    fun readyFor(owner: String): Boolean = current?.let { it.owner == owner && it.ready && !it.closing } == true

    fun acquire(owner: String, proxy: String?, done: (Boolean) -> Unit) {
        if (current != null) { done(false); return }
        val route = if (proxy.isNullOrEmpty()) null else address(proxy)
        if (!proxy.isNullOrEmpty() && (route == null || !runCatching { backend.supported() }.getOrDefault(false))) {
            done(false); return
        }
        val lease = Lease(owner, done)
        current = lease
        if (route == null) {
            lease.ready = true; lease.begin = null; done(true)
            return
        }
        lease.applying = true
        lease.applied = true // An apply exception can still leave a partially applied override.
        val finished: (Boolean) -> Unit = callback@ { success ->
            if (current !== lease || !lease.applying) return@callback
            lease.applying = false
            if (!success) lease.closing = true
            if (lease.closing) clear(lease)
            else {
                lease.ready = true
                val callback = lease.begin; lease.begin = null; callback?.invoke(true)
            }
        }
        try { backend.apply(route, finished) } catch (_: Exception) { finished(false) }
    }

    fun release(owner: String, done: (Boolean) -> Unit = {}) {
        val lease = current
        if (lease == null || lease.owner != owner) { done(true); return }
        lease.closing = true
        lease.ready = false
        lease.closers.add(done)
        // A pending apply must finish before clearing; no later callback may restore its proxy.
        if (!lease.applying) clear(lease)
    }

    private fun clear(lease: Lease) {
        if (current !== lease || lease.clearing) return
        lease.clearing = true
        val serial = ++lease.clearSerial
        val finished: (Boolean) -> Unit = callback@ { success ->
            if (current !== lease || !lease.clearing || lease.clearSerial != serial) return@callback
            lease.clearing = false
            if (success) current = null // Failure keeps the lease blocked until explicit cleanup succeeds.
            val begin = lease.begin; lease.begin = null
            val callbacks = lease.closers.toList(); lease.closers.clear()
            begin?.invoke(false)
            callbacks.forEach { it(success) }
        }
        if (!lease.applied) { finished(true); return }
        try { backend.clear(finished) } catch (_: Exception) { finished(false) }
    }
}

private class AndroidBrowserProxyBackend : BrowserProxyBackend {
    private val handler = Handler(Looper.getMainLooper())
    private val main = Executor { task -> if (Looper.myLooper() == Looper.getMainLooper()) task.run() else handler.post(task) }
    override fun supported() = WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)
    override fun apply(address: String, done: (Boolean) -> Unit) {
        ProxyController.getInstance().setProxyOverride(
            ProxyConfig.Builder().addProxyRule(address).removeImplicitRules().build(), main) { done(true) }
    }
    override fun clear(done: (Boolean) -> Unit) {
        ProxyController.getInstance().clearProxyOverride(main) { done(true) }
    }
}
