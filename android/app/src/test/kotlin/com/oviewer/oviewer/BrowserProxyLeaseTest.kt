package com.oviewer.oviewer

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 35])
class BrowserProxyLeaseTest {
    private class Backend : BrowserProxyBackend {
        var enabled = true
        val addresses = mutableListOf<String>()
        val applies = mutableListOf<(Boolean) -> Unit>()
        val clears = mutableListOf<(Boolean) -> Unit>()
        override fun supported() = enabled
        override fun apply(address: String, done: (Boolean) -> Unit) { addresses.add(address); applies.add(done) }
        override fun clear(done: (Boolean) -> Unit) { clears.add(done) }
    }
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var calls = 0
        override fun success(result: Any?) { value = result; calls++ }
        override fun error(code: String, message: String?, details: Any?) { error = code; calls++ }
        override fun notImplemented() { error = "notImplemented"; calls++ }
    }

    @Test fun closeDuringPendingApplyWaitsForApplyAndClearBeforeAnotherOwner() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        val began = mutableListOf<Boolean>(); val ended = mutableListOf<Boolean>()
        lease.acquire("upload", "127.0.0.1:7890", began::add)
        assertFalse(lease.readyFor("upload"))
        lease.release("upload", ended::add)
        assertTrue(backend.clears.isEmpty())
        backend.applies.single()(true)
        assertEquals(1, backend.clears.size)
        assertTrue(began.isEmpty()); assertTrue(ended.isEmpty())
        var other: Boolean? = null
        lease.acquire("login", null) { other = it }
        assertEquals(false, other)
        backend.clears.single()(true)
        assertEquals(listOf(false), began); assertEquals(listOf(true), ended)
        lease.acquire("login", null) { other = it }
        assertEquals(true, other)
        lease.release("login")
    }

    @Test fun staleCloseNeverClearsAnotherOwnersProxy() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        lease.acquire("upload", "http://127.0.0.1:7890") {}
        backend.applies.single()(true)
        lease.release("old-login")
        assertTrue(backend.clears.isEmpty())
        assertTrue(lease.readyFor("upload"))
        lease.release("upload"); backend.clears.single()(true)
    }

    @Test fun cleanupFailureKeepsRouteBlockedUntilExplicitCleanupSucceeds() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        lease.acquire("upload", "127.0.0.1:7890") {}
        backend.applies.single()(true)
        var closed: Boolean? = null
        lease.release("upload") { closed = it }
        backend.clears[0](false)
        assertEquals(false, closed)
        assertTrue(lease.heldBy("upload")); assertFalse(lease.readyFor("upload"))
        var next: Boolean? = null
        lease.acquire("login", null) { next = it }
        assertEquals(false, next)
        lease.release("upload") { closed = it }
        backend.clears[1](true)
        assertEquals(true, closed)
        lease.acquire("login", null) { next = it }
        assertEquals(true, next)
        backend.clears[0](true) // A late callback from the failed clear cannot release the new owner.
        assertTrue(lease.readyFor("login"))
        lease.release("login")
    }

    @Test fun failedApplyMustCleanUpBeforeReportingUnavailable() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        var began: Boolean? = null
        lease.acquire("upload", "127.0.0.1:7890") { began = it }
        backend.applies.single()(false)
        assertNull(began); assertTrue(lease.heldBy("upload"))
        backend.clears.single()(true)
        assertEquals(false, began); assertFalse(lease.heldBy("upload"))
    }

    @Test fun unavailableOrInvalidProxyNeverFallsBackToSystemAutomatically() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        backend.enabled = false
        var ready: Boolean? = null
        lease.acquire("upload", "127.0.0.1:7890") { ready = it }
        assertEquals(false, ready)
        assertFalse(lease.heldBy("upload")); assertTrue(backend.applies.isEmpty())
        backend.enabled = true
        for (value in listOf("http://user:pass@proxy:80", "http://proxy:80/path", "http://proxy:80?direct=true", "file:///tmp")) {
            lease.acquire("upload", value) { ready = it }
            assertEquals(false, ready)
        }
        lease.acquire("upload", null) { ready = it } // A separate, explicit system-network choice.
        assertEquals(true, ready); assertTrue(backend.applies.isEmpty())
        lease.release("upload")
    }

    @Test fun bridgeRetainsOwnerThroughPendingCleanupAndReportsCleanupFailure() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        val states = mutableListOf<Boolean>()
        val bridge = UploadWebProxyBridge(states::add, lease)
        val begin = Result(); val close = Result()
        bridge.onMethodCall(MethodCall("begin", mapOf("id" to "web_1", "proxy" to "127.0.0.1:7890")), begin)
        bridge.onMethodCall(MethodCall("close", mapOf("id" to "web_1")), close)
        assertEquals(listOf(true), states)
        backend.applies.single()(true); backend.clears[0](false)
        assertEquals(false, begin.value); assertEquals("proxy_cleanup", close.error)
        assertEquals(listOf(true), states)
        val retry = Result()
        bridge.onMethodCall(MethodCall("close", mapOf("id" to "web_1")), retry)
        backend.clears[1](true)
        assertEquals(listOf(true, false), states)
        assertNull(retry.error); assertEquals(1, retry.calls)
        assertEquals(1, begin.calls); assertEquals(1, close.calls)
    }

    @Test fun loginAndUploadBridgesCannotOverwriteOrReleaseEachOther() {
        val backend = Backend(); val lease = BrowserProxyLease(backend)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val login = AutomaticLoginCheck(activity, lease)
        val upload = UploadWebProxyBridge({}, lease)
        val loginResult = Result()
        login.onMethodCall(MethodCall("begin", mapOf("id" to 1)), loginResult)
        assertEquals(true, loginResult.value)
        val blocked = Result()
        upload.onMethodCall(MethodCall("begin", mapOf("id" to "web")), blocked)
        assertEquals(false, blocked.value)
        login.dispose()
        val opened = Result()
        upload.onMethodCall(MethodCall("begin", mapOf("id" to "web")), opened)
        assertEquals(true, opened.value)
        login.dispose()
        val check = Result()
        upload.onMethodCall(MethodCall("check", mapOf("id" to "web")), check)
        assertEquals(true, check.value)
        assertTrue(backend.clears.isEmpty())
        upload.dispose()
    }
}
