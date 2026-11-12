package com.oviewer.oviewer

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Looper
import android.net.NetworkCapabilities
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Assume
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetworkCapabilities
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.Closeable
import java.net.Proxy
import java.net.URL
import java.nio.ByteBuffer
import java.security.cert.Certificate
import java.security.Security
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 28, 35], application = Application::class)
class UploadTransferRuntimeTest {
    class NotificationActivity : Activity() {
        var permissionChecks = 0
        var failPermissionCheck = false
        override fun checkSelfPermission(permission: String): Int {
            if (permission != android.Manifest.permission.POST_NOTIFICATIONS) return super.checkSelfPermission(permission)
            check(Looper.myLooper() == Looper.getMainLooper()) { "Permission UI must run on the main thread" }
            permissionChecks++
            if (failPermissionCheck) throw SecurityException("Test-only notification request failure")
            return PackageManager.PERMISSION_DENIED
        }
    }
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { callback?.reply(null) }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }
    private class Result : MethodChannel.Result {
        val done = AtomicBoolean(false)
        var errorCode: String? = null
        override fun success(result: Any?) { done.set(true) }
        override fun error(code: String, message: String?, details: Any?) { errorCode = code; done.set(true) }
        override fun notImplemented() { errorCode = "notImplemented"; done.set(true) }
    }
    private class WifiHarness(state: UploadWifiGate.State = UploadWifiGate.State.ALLOWED) {
        @Volatile var observation = UploadWifiGate.Observation(state, "wifi-route")
        var changed: (() -> Unit)? = null
        var closed = 0
        var created = 0
        fun gate(onViolation: (String) -> Unit): UploadWifiGate {
            created++
            return UploadWifiGate({ observation }, UploadWifiGate.Observer { callback ->
                changed = callback
                Closeable { closed++ }
            }, onViolation)
        }
        fun update(state: UploadWifiGate.State, route: Any? = "wifi-route") {
            observation = UploadWifiGate.Observation(state, route)
            changed?.invoke()
        }
    }
    private class Sealer : UploadTransferSealer {
        var generation = 0
        override fun seal(value: String) = "$generation:" + Base64.encodeToString(value.toByteArray(), Base64.NO_WRAP)
        override fun open(value: String): String {
            require(value.startsWith("$generation:"))
            return Base64.decode(value.substringAfter(':'), Base64.NO_WRAP).toString(Charsets.UTF_8)
        }
        override fun revoke() { generation++ }
    }
    private class Connection(url: URL, private val responseStatus: Int = 200,
        private val response: ByteArray = "received, but not yet verified".toByteArray(),
        private val location: String? = null, private val onSend: (() -> Unit)? = null,
        private val readFailure: Boolean = false, private val onResponse: (() -> Unit)? = null,
        private val responseCookies: List<String> = emptyList(),
        private val onDisconnect: (() -> Unit)? = null) : HttpsURLConnection(url) {
        val sent = ByteArrayOutputStream()
        val requestHeaders = mutableMapOf<String, String>()
        var disconnected = false
        var locationReads = 0
        var responseHeaderReads = 0
        override fun connect() { connected = true }
        override fun disconnect() { disconnected = true; onDisconnect?.invoke() }
        override fun usingProxy() = false
        override fun getCipherSuite() = "TLS_FAKE_TEST_ONLY"
        override fun getLocalCertificates(): Array<Certificate>? = null
        override fun getServerCertificates(): Array<Certificate> = emptyArray()
        override fun setRequestProperty(key: String, value: String) { requestHeaders[key] = value }
        override fun getOutputStream(): OutputStream = object : OutputStream() {
            override fun write(value: Int) { sent.write(value); onSend?.invoke() }
            override fun write(bytes: ByteArray, offset: Int, length: Int) { sent.write(bytes, offset, length); onSend?.invoke() }
        }
        override fun getResponseCode(): Int { onResponse?.invoke(); return responseStatus }
        override fun getHeaderField(name: String): String? {
            if (name.equals("Location", ignoreCase = true)) { locationReads++; return location }
            return null
        }
        override fun getHeaderFields(): Map<String, List<String>> {
            responseHeaderReads++
            return mapOf("Set-Cookie" to responseCookies)
        }
        override fun getInputStream(): InputStream {
            if (readFailure) throw IOException("Simulated lost response")
            return ByteArrayInputStream(response)
        }
        override fun getErrorStream(): InputStream = ByteArrayInputStream(response)
    }
    private lateinit var root: File
    private lateinit var store: UploadTransferStore
    private lateinit var vault: Sealer
    private lateinit var runtime: UploadTransferRuntime
    private val opened = mutableListOf<Connection>()
    private val payload = "--boundary\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\nexample\r\n--boundary--\r\n".toByteArray()

    @Before fun prepare() {
        UploadTransferRuntime.clearForTest()
        val context = RuntimeEnvironment.getApplication()
        root = File(context.applicationInfo.dataDir, "app_flutter/uploads").apply { mkdirs() }
        vault = Sealer()
        store = UploadTransferStore(root, vault)
        store.prepareSession("123", "epoch-one")
        File(root, "body.multipart").writeBytes(payload)
        runtime = UploadTransferRuntime.get(context)
        runtime.storeOverride = store
        runtime.connectionFactory = { url, _ -> Connection(url).also { opened.add(it) } }
        opened.clear()
    }
    @After fun finish() { UploadTransferRuntime.clearForTest() }

    private fun request(id: String = "item1", url: String = "https://upld.e-hentai.org/manage") =
        JSONObject().put("id", id).put("url", url).put("bodyPath", "body.multipart")
            .put("length", File(root, "body.multipart").length()).put("sha256", uploadSha256(File(root, "body.multipart")) { false })
            .put("wifiOnly", false).put("headers", JSONObject().put("Content-Type", "multipart/form-data; boundary=boundary")
                .put("User-Agent", "OViewer-Test").put("Cookie", "ipb_member_id=123; ipb_pass_hash=secret-test-cookie"))
    private fun enqueue(count: Int = 1, taskId: String = "task1", proxy: String? = null,
        url: String = "https://upld.e-hentai.org/manage", wifiOnly: Boolean = false) {
        val items = JSONArray()
        repeat(count) { items.put(request("item${it+1}", url).put("wifiOnly", wifiOnly)) }
        store.enqueue(JSONObject().put("accountId", "123").put("epoch", "epoch-one").put("taskId", taskId)
            .put("items", items).put("proxy", proxy ?: JSONObject.NULL).put("language", "en"))
    }
    private fun runJob() {
        val done = AtomicBoolean(false)
        runtime.runAcceptedJob { done.set(true) }
        val until = System.nanoTime() + 10_000_000_000L
        while (!done.get() && System.nanoTime() < until) {
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertTrue("Native transfer did not finish", done.get())
    }
    private fun reason(expected: String, block: () -> Unit) {
        try { block(); fail("Expected $expected") }
        catch (error: UploadTransferFailure) { assertEquals(expected, error.reason) }
    }

    private fun enqueueFromUi(taskId: String = "task1", invalidBody: Boolean = false): Result {
        val item = request().apply { if (invalidBody) put("bodyPath", "missing.multipart") }
        val args = JSONObject().put("accountId", "123").put("epoch", "epoch-one").put("taskId", taskId)
            .put("items", JSONArray().put(item)).put("language", "en")
        val result = Result()
        runtime.onMethodCall(MethodCall("enqueue", args.toMap()), result)
        val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (!result.done.get() && System.nanoTime() < until) {
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertTrue("Upload command did not finish", result.done.get())
        return result
    }
    private fun notificationPreferences() = RuntimeEnvironment.getApplication()
        .getSharedPreferences("offline_service", Context.MODE_PRIVATE)

    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun firstUploadRequestsNotificationsOnceAndDenialDoesNotBlockQueue() {
        val activity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        runtime.bind(Messenger()) { activity }
        assertFalse(notificationPreferences().getBoolean("notification_requested", false))
        assertNull(enqueueFromUi().errorCode)
        val permission = requireNotNull(Shadows.shadowOf(activity).lastRequestedPermission)
        assertEquals(7701, permission.requestCode)
        assertArrayEquals(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), permission.requestedPermissions)
        assertEquals(1, activity.permissionChecks)
        assertEquals("queued", store.task("task1").getString("state"))
        activity.onRequestPermissionsResult(permission.requestCode, permission.requestedPermissions,
            intArrayOf(PackageManager.PERMISSION_DENIED))
        assertNull(enqueueFromUi("task2").errorCode)
        assertSame("Denial must not cause a second prompt", permission, Shadows.shadowOf(activity).lastRequestedPermission)
        assertTrue(notificationPreferences().getBoolean("notification_requested", false))
        assertTrue(store.tasks.objects().all { it.getString("state") == "queued" })
        assertTrue(opened.isEmpty())
    }
    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun uploadReusesNotificationRequestPreferenceFromDownloads() {
        val app = RuntimeEnvironment.getApplication() as OViewerApplication
        val previousActivity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        app.requestNotifications(previousActivity)
        assertNotNull(Shadows.shadowOf(previousActivity).lastRequestedPermission)
        val uploadActivity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        runtime.bind(Messenger()) { uploadActivity }
        assertNull(enqueueFromUi().errorCode)
        assertNull(Shadows.shadowOf(uploadActivity).lastRequestedPermission)
        assertEquals("queued", store.task("task1").getString("state"))
    }
    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun notificationRequestFailureDoesNotFailAcceptedUpload() {
        val activity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        activity.failPermissionCheck = true
        runtime.bind(Messenger()) { activity }
        assertNull(enqueueFromUi().errorCode)
        assertEquals(1, activity.permissionChecks)
        assertNull(Shadows.shadowOf(activity).lastRequestedPermission)
        assertEquals("queued", store.task("task1").getString("state"))
    }
    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun backgroundEnqueueDoesNotRequestNotifications() {
        runtime.bind(Messenger()) { null }
        assertEquals("foreground_required", enqueueFromUi().errorCode)
        assertEquals(0, store.tasks.length())
        assertFalse(notificationPreferences().getBoolean("notification_requested", false))
    }
    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun leavingForegroundBeforeAcceptedUploadCallbackDoesNotRequestNotifications() {
        val activity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        var foregroundChecks = 0
        runtime.bind(Messenger()) { if (++foregroundChecks == 1) activity else null }
        assertNull(enqueueFromUi().errorCode)
        assertEquals(2, foregroundChecks)
        assertNull(Shadows.shadowOf(activity).lastRequestedPermission)
        assertEquals("queued", store.task("task1").getString("state"))
        assertFalse(notificationPreferences().getBoolean("notification_requested", false))
    }
    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun recoveringAcceptedWorkNeverStartsFirstNotificationRequest() {
        val activity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        runtime.bind(Messenger()) { activity }
        enqueue()
        runJob()
        assertEquals("awaitingVerification", store.task("task1").getString("state"))
        assertEquals(0, activity.permissionChecks)
        assertNull(Shadows.shadowOf(activity).lastRequestedPermission)
        assertFalse(notificationPreferences().getBoolean("notification_requested", false))
    }
    @Test @Config(sdk = [33], application = OViewerApplication::class)
    fun rejectedUploadDoesNotSpendNotificationPermissionRequest() {
        val activity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        runtime.bind(Messenger()) { activity }
        assertEquals("body_missing", enqueueFromUi(invalidBody = true).errorCode)
        assertEquals(0, activity.permissionChecks)
        assertNull(Shadows.shadowOf(activity).lastRequestedPermission)
        assertEquals(0, store.tasks.length())
        assertFalse(notificationPreferences().getBoolean("notification_requested", false))
    }
    @Test @Config(sdk = [21, 28], application = OViewerApplication::class)
    fun olderAndroidUploadsDoNotRequestNotificationRuntimePermission() {
        val activity = Robolectric.buildActivity(NotificationActivity::class.java).setup().get()
        runtime.bind(Messenger()) { activity }
        assertNull(enqueueFromUi().errorCode)
        assertEquals(0, activity.permissionChecks)
        assertNull(Shadows.shadowOf(activity).lastRequestedPermission)
        assertEquals("queued", store.task("task1").getString("state"))
        assertFalse(notificationPreferences().getBoolean("notification_requested", false))
    }

    @Test fun currentNetworkUploadDoesNotCreateOrWaitForWifiGate() {
        runtime.wifiGateFactory = { _, _ -> error("Current-network upload must not create a Wi-Fi gate") }
        enqueue()
        runJob()
        assertEquals(1, opened.size)
        assertArrayEquals(payload, opened.single().sent.toByteArray())
        assertEquals("awaitingVerification", store.task("task1").getString("state"))
    }
    @Test fun wifiOnlyRejectsNonWifiAndUnknownBeforeAnyRequest() {
        for (state in listOf(UploadWifiGate.State.NON_WIFI, UploadWifiGate.State.UNKNOWN)) {
            val harness = WifiHarness(state)
            runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
            val taskId = "wifi" + state.name
            enqueue(taskId = taskId, wifiOnly = true)
            runJob()
            assertTrue(opened.isEmpty())
            assertEquals("paused", store.task(taskId).getString("state"))
            assertEquals(if (state == UploadWifiGate.State.UNKNOWN) "wifi_network_unknown" else "waiting_wifi",
                store.task(taskId).getString("reason"))
            assertEquals("queued", store.task(taskId).getJSONArray("items").getJSONObject(0).getString("state"))
            assertEquals(0, store.receipts.length())
            assertEquals(1, harness.closed)
        }
    }
    @Test fun verifiedWifiTransferKeepsExistingProxyAndClosesItsGate() {
        val harness = WifiHarness()
        runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
        enqueue(proxy = "http://127.0.0.1:7890", wifiOnly = true)
        runtime.connectionFactory = { url, proxy ->
            assertEquals(Proxy.Type.HTTP, proxy?.type())
            Connection(url).also { opened.add(it) }
        }
        runJob()
        assertEquals(1, opened.size)
        assertArrayEquals(payload, opened.single().sent.toByteArray())
        assertEquals("awaitingVerification", store.task("task1").getString("state"))
        assertEquals(1, harness.created)
        assertEquals(1, harness.closed)
    }
    @Test fun wifiChangeAtConnectionOpenPreventsBodyAndDoesNotReplay() {
        val harness = WifiHarness()
        runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
        enqueue(wifiOnly = true)
        runtime.connectionFactory = { url, _ ->
            Connection(url).also {
                opened.add(it)
                harness.update(UploadWifiGate.State.NON_WIFI)
            }
        }
        runJob()
        assertEquals(1, opened.size)
        assertEquals(0, opened.single().sent.size())
        assertTrue(opened.single().disconnected)
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("wifi_changed_after_send", store.receipts.getJSONObject(0).getString("reason"))
        harness.update(UploadWifiGate.State.ALLOWED)
        runJob()
        assertEquals(1, opened.size)
        assertEquals(1, harness.closed)
    }
    @Test fun wifiLossInterruptsBlockedWriteAndKeepsPartialBodyUncertain() {
        val harness = WifiHarness()
        runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
        val larger = ByteArray(150_000) { (it % 251).toByte() }
        File(root, "body.multipart").writeBytes(larger)
        enqueue(wifiOnly = true)
        val entered = CountDownLatch(1)
        val released = CountDownLatch(1)
        val done = AtomicBoolean(false)
        runtime.connectionFactory = { url, _ -> Connection(url,
            onSend = { entered.countDown(); check(released.await(10, TimeUnit.SECONDS)) },
            onDisconnect = { released.countDown() }).also { opened.add(it) } }
        runtime.runAcceptedJob { done.set(true) }
        assertTrue(entered.await(10, TimeUnit.SECONDS))
        harness.update(UploadWifiGate.State.NON_WIFI)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (!done.get() && System.nanoTime() < deadline) {
            Shadows.shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10)
        }
        assertTrue(done.get())
        assertEquals(1, opened.size)
        assertTrue(opened.single().disconnected)
        assertTrue(opened.single().sent.size() in 1 until larger.size)
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("wifi_changed_after_send", store.receipts.getJSONObject(0).getString("reason"))
        harness.update(UploadWifiGate.State.ALLOWED)
        runJob()
        assertEquals(1, opened.size)
        assertEquals(1, harness.closed)
    }
    @Test fun jobNetworkChangeRechecksDefaultRouteBeforeCanonicalReadback() {
        val harness = WifiHarness()
        runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
        enqueue(wifiOnly = true, url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
        runtime.connectionFactory = { url, _ -> Connection(url, 302, onResponse = {
            harness.observation = UploadWifiGate.Observation(UploadWifiGate.State.UNKNOWN)
            runtime.onJobNetworkChanged()
        }).also { opened.add(it) } }
        runJob()
        assertEquals(1, opened.size)
        assertArrayEquals(payload, opened.single().sent.toByteArray())
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("wifi_changed_after_send", store.receipts.getJSONObject(0).getString("reason"))
        assertTrue(opened.single().disconnected)
    }
    @Test fun returningWifiDoesNotResumePausedWorkWithoutExplicitQueueRequest() {
        val harness = WifiHarness(UploadWifiGate.State.UNKNOWN)
        runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
        enqueue(wifiOnly = true)
        runJob()
        assertEquals("paused", store.task("task1").getString("state"))
        harness.update(UploadWifiGate.State.ALLOWED)
        runJob()
        assertTrue(opened.isEmpty())
        store.task("task1").put("state", "queued")
        store.save() // Represents an explicit resume; no sent request existed.
        runJob()
        assertEquals(1, opened.size)
        assertEquals(2, harness.created)
        assertEquals(2, harness.closed)
    }
    @Test fun closedWifiObserverCannotDisconnectTheFollowingCurrentNetworkTask() {
        val harness = WifiHarness()
        runtime.wifiGateFactory = { _, callback -> harness.gate(callback) }
        enqueue(taskId = "wifi", wifiOnly = true)
        enqueue(taskId = "current")
        runtime.receiptVerifier = object : UploadTransferReceiptVerifier {
            override fun verify(response: File?, receipt: Map<String, Any?>) = true
        }
        runtime.connectionFactory = { url, _ -> Connection(url, onSend = {
            if (opened.size == 2) {
                harness.update(UploadWifiGate.State.NON_WIFI)
                assertFalse(opened.last().disconnected)
            }
        }).also { opened.add(it) } }
        runJob()
        assertEquals(2, opened.size)
        assertArrayEquals(payload, opened.last().sent.toByteArray())
        assertEquals("completed", store.task("wifi").getString("state"))
        assertEquals("completed", store.task("current").getString("state"))
        assertEquals(1, harness.created)
        assertEquals(1, harness.closed)
    }
    @Test @Config(sdk = [35])
    fun uidtRequiresWifiTransportRatherThanUnmeteredAndDoesNotExcludeVpn() {
        val request = runtime.requiredNetwork(true)
        assertTrue(request.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))
        assertFalse(request.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
        assertFalse(request.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
        assertFalse(request.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN))
        fun network(vararg transports: Int) = ShadowNetworkCapabilities.newInstance().also { capabilities ->
            val shadow = Shadows.shadowOf(capabilities)
            shadow.clearCapabilities()
            request.capabilities.forEach { shadow.addCapability(it) }
            transports.forEach { shadow.addTransportType(it) }
        }
        val wifiVpn = network(NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_VPN)
        assertTrue(request.canBeSatisfiedBy(wifiVpn))
        val freeCellular = network(NetworkCapabilities.TRANSPORT_CELLULAR)
        Shadows.shadowOf(freeCellular).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        assertFalse(request.canBeSatisfiedBy(freeCellular))
        assertTrue(runtime.requiredNetwork(false).canBeSatisfiedBy(freeCellular))
    }

    @Test fun http200PersistsReceiptAndStopsUntilVerificationWithoutFlutter() {
        enqueue(2)
        runtime.connectionFactory = { url, _ ->
            assertEquals("sending", store.task("task1").getJSONArray("items").getJSONObject(0).getString("state"))
            assertTrue(File(store.directory, "journal.json").readText().contains("sending"))
            Connection(url).also { opened.add(it) }
        }
        runJob()
        assertEquals(1, opened.size)
        assertArrayEquals(payload, opened.single().sent.toByteArray())
        assertFalse(opened.single().instanceFollowRedirects)
        assertEquals("awaitingVerification", store.task("task1").getString("state"))
        val receipt = store.receipts.getJSONObject(0)
        assertEquals(200, receipt.getInt("status"))
        assertTrue(File(root, receipt.getString("responsePath")).readText().contains("received, but not yet verified"))
        assertTrue(receipt.getBoolean("responseSanitized"))
        runJob()
        assertEquals("Reading/restarting must not resend an ambiguous write", 1, opened.size)
        assertFalse(store.snapshot().toString().contains("secret-test-cookie"))
        assertFalse(File(store.directory, "journal.json").readText().contains("secret-test-cookie"))
    }
    @Test fun injectedNativeVerifierCanAdvanceMultipleBatchesWithoutDart() {
        enqueue(2)
        runtime.receiptVerifier = object : UploadTransferReceiptVerifier {
            override fun verify(response: File?, receipt: Map<String, Any?>): Boolean {
                assertTrue(response!!.isFile)
                val saved = JSONObject(File(store.directory, "journal.json").readText())
                assertTrue(saved.getJSONArray("receipts").objects().any { it.getString("receiptId") == receipt["receiptId"] })
                return true // Test-only site confirmation, never the default.
            }
        }
        runJob()
        assertEquals(2, opened.size)
        assertEquals("completed", store.task("task1").getString("state"))
        assertEquals("files_confirmed", store.task("task1").getString("reason"))
        assertTrue(store.task("task1").getJSONArray("items").objects().all { !it.has("sealed") })
    }
    @Test fun defaultVerifierAdvancesUsingObservedHtmlAndFreshFileIds() {
        store.prepareSession("101", "verified-epoch")
        val names = (1..8).map { it.toString().padStart(4, '0') + ".png" }
        val previous = listOf(279367042L, 279367044L, 279367045L, 279367046L, 279367047L, 279367048L, 279367049L, 279367050L)
        val first = request("batch1", "https://upld.e-hentai.org/managegallery?ulgid=12345")
            .put("verification", JSONObject().put("galleryId", "12345").put("expectedNames", JSONArray(names))
                .put("priorFileIndexes", JSONArray()))
        val second = request("batch2", "https://upld.e-hentai.org/managegallery?ulgid=12345")
            .put("verification", JSONObject().put("galleryId", "12345").put("expectedNames", JSONArray(listOf("0009.png")))
                .put("priorFileIndexes", JSONArray(previous)))
        store.enqueue(JSONObject().put("accountId", "101").put("epoch", "verified-epoch").put("taskId", "verified-task")
            .put("items", JSONArray(listOf(first, second))))
        val candidates = listOf(File("../../test/fixtures/uploads/uploaded.html"), File("../test/fixtures/uploads/uploaded.html"), File("test/fixtures/uploads/uploaded.html"))
        val html = candidates.first { it.isFile }.readText()
        val newCell = "<div id=\"cell_9\"><input id=\"pagesel_9\" name=\"pagesel_9\" value=\"9\" readonly=\"readonly\"/><div class=\"n\">0009.png</div><img id=\"thumb_9\" alt=\"0009.png\" title=\"0009.png\" onclick=\"view_image_init(12345,9,279367051)\"/></div>"
        val end = html.lastIndexOf("</form>")
        val withNext = html.substring(0, end) + newCell + html.substring(end)
        runtime.connectionFactory = { url, _ -> Connection(url,
            response = (if (opened.isEmpty()) html else withNext).toByteArray()).also { opened.add(it) } }
        runJob()
        assertEquals(2, opened.size)
        assertEquals("completed", store.task("verified-task").getString("state"))
        assertTrue(store.receipts.objects().all { it.optString("outcome") == "confirmed" })
        assertTrue(store.receipts.objects().all { it.getLong("sentBytes") == it.getLong("length") })
        assertTrue(store.receipts.objects().all { it.has("verification") })
    }
    @Test fun lostResponseIsUncertainAndCannotAutomaticallyReplay() {
        enqueue()
        runtime.connectionFactory = { url, _ -> Connection(url, readFailure = true).also { opened.add(it) } }
        runJob(); runJob()
        assertEquals(1, opened.size)
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("network_interrupted", store.receipts.getJSONObject(0).getString("reason"))
    }
    @Test fun pauseAfterSendingPreservesUncertaintyAndQueuedItems() {
        enqueue(2)
        var paused = false
        runtime.connectionFactory = { url, _ -> Connection(url, onSend = {
            if (!paused) { paused = true; runtime.pause("task1") }
        }).also { opened.add(it) } }
        runJob()
        val items = store.task("task1").getJSONArray("items")
        assertEquals("uncertain", items.getJSONObject(0).getString("state"))
        assertEquals("queued", items.getJSONObject(1).getString("state"))
        assertEquals(1, opened.size)
        assertEquals(1, store.receipts.length())
    }
    @Test fun processInterruptionRecoversAsUncertainWithoutReplaying() {
        enqueue()
        val task = store.task("task1")
        task.put("state", "sending")
        task.getJSONArray("items").getJSONObject(0).put("state", "sending")
        store.save()
        val recovered = UploadTransferStore(root, vault)
        assertEquals("uncertain", recovered.task("task1").getString("state"))
        assertEquals("process_interrupted", recovered.receipts.getJSONObject(0).getString("reason"))
        runtime.storeOverride = recovered
        runJob()
        assertTrue(opened.isEmpty())
    }
    @Test fun revokedSessionHidesOldAccountAndCannotBeReactivated() {
        enqueue()
        store.invalidate("epoch-one")
        assertTrue((store.snapshot()["tasks"] as List<*>).isEmpty())
        assertTrue(store.task("task1").getJSONArray("items").objects().all { !it.has("sealed") })
        assertEquals(1, vault.generation)
        reason("revoked_session") { store.prepareSession("123", "epoch-one") }
        store.prepareSession("456", "epoch-two")
        assertTrue((store.snapshot()["tasks"] as List<*>).isEmpty())
        runJob(); assertTrue(opened.isEmpty())
    }
    @Test fun changedBodyIsRejectedBeforeAnyNetworkRequest() {
        enqueue()
        File(root, "body.multipart").writeText("changed")
        runJob()
        assertEquals("prepared_body_changed", store.task("task1").getString("reason"))
        assertTrue(opened.isEmpty())
    }
    @Test fun durableLogoutMarkerRevokesColdQueuedWorkBeforeAnyRequest() {
        enqueue()
        val marker = File(root.parentFile, ".cookies/logout-pending")
        marker.parentFile!!.mkdirs(); marker.writeText("")
        runJob()
        assertTrue(opened.isEmpty())
        assertNull(store.epoch)
        assertEquals("stopped", store.task("task1").getString("state"))
        assertTrue(store.task("task1").getJSONArray("items").objects().all { !it.has("sealed") })
        reason("logout_in_progress") { runtime.prepareSession("123", "epoch-new") }
        marker.delete()
        reason("revoked_session") { runtime.prepareSession("123", "epoch-one") }
        runtime.prepareSession("123", "epoch-new")
        assertEquals("epoch-new", store.epoch)
    }
    @Test fun logoutMarkerAppearingAtOpenPreventsSendingPreparedBody() {
        enqueue()
        runtime.connectionFactory = { url, _ ->
            val marker = File(root.parentFile, ".cookies/logout-pending")
            marker.parentFile!!.mkdirs(); marker.writeText("")
            Connection(url).also { opened.add(it) }
        }
        runJob()
        assertEquals(1, opened.size)
        assertEquals(0, opened.single().sent.size())
        assertNull(store.epoch)
        assertEquals("uncertain", store.receipts.getJSONObject(0).getString("state"))
        File(root.parentFile, ".cookies/logout-pending").delete()
    }
    @Test fun sourceChangeAfterHashCheckCannotBecomeVerifiedSuccess() {
        enqueue()
        runtime.connectionFactory = { url, _ ->
            val changed = payload.copyOf().apply { this[25] = (this[25].toInt() xor 1).toByte() }
            File(root, "body.multipart").writeBytes(changed)
            Connection(url).also { opened.add(it) }
        }
        runtime.receiptVerifier = object : UploadTransferReceiptVerifier {
            override fun verify(response: File?, receipt: Map<String, Any?>): Boolean {
                fail("Changed body must not reach business confirmation"); return true
            }
        }
        runJob()
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("prepared_body_changed_after_send", store.receipts.getJSONObject(0).getString("reason"))
    }
    @Test fun journalReplacementFailureIsObservableAndOldDataRemainsReadable() {
        val folder = File(root, "journal-test").apply { mkdirs() }
        val file = File(folder, "state")
        val journal = UploadTransferJournal(file)
        journal.write("before".toByteArray())
        val backup = File(folder, "state.bak").apply { mkdir() }
        File(backup, "prevent-removal").writeText("owned-test")
        reason("journal_commit_failed") { journal.write("after".toByteArray()) }
        assertEquals("before", journal.read().toString(Charsets.UTF_8))
    }
    @Test fun unverified301AndMethodPreserving307Or308NeverReplayPost() {
        for (status in listOf(301, 307, 308)) {
            val taskId = "redirect$status"
            enqueue(taskId = taskId, url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
            val before = opened.size
            runtime.connectionFactory = { url, _ ->
                Connection(url, status, location = "/managegallery?ulgid=12345").also { opened.add(it) }
            }
            runJob()
            assertEquals(before + 1, opened.size)
            assertEquals("POST", opened.last().requestMethod)
            assertArrayEquals(payload, opened.last().sent.toByteArray())
            assertFalse(opened.last().instanceFollowRedirects)
            assertEquals("uncertain", store.task(taskId).getString("state"))
            val receipt = store.receipts.objects().last()
            assertEquals("redirect_requires_verification", receipt.getString("reason"))
            assertEquals(status, receipt.getInt("status"))
            runJob()
            assertEquals("Restarting an unknown redirect must not resend POST", before + 1, opened.size)
            store.acknowledge(receipt.getString("receiptId"), "stop")
        }
    }
    @Test fun response303ReadsOriginalGalleryOnceWithNoBody() {
        enqueue(url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
        runtime.connectionFactory = { url, _ ->
            (if (opened.isEmpty()) Connection(url, 303, location = "/managegallery?ulgid=12345") else Connection(url)).also { opened.add(it) }
        }
        runJob()
        assertEquals(listOf("POST", "GET"), opened.map { it.requestMethod })
        assertArrayEquals(payload, opened[0].sent.toByteArray())
        assertEquals(0, opened[1].sent.size())
        assertFalse(opened[1].doOutput)
        assertFalse(opened[1].requestHeaders.containsKey("Content-Type"))
        assertEquals("awaitingVerification", store.task("task1").getString("state"))
        assertEquals(0, opened[0].locationReads)
        assertEquals("read_complete", store.receipts.getJSONObject(0).getString("readbackStage"))
    }
    @Test fun independent302ReadbackRequiresFreshServerProofWithoutAnotherPost() {
        store.prepareSession("101", "observed-epoch")
        val item = request("images", "https://upld.e-hentai.org/managegallery?ulgid=12345")
            .put("verification", JSONObject().put("galleryId", "12345")
                .put("expectedNames", JSONArray((1..8).map { it.toString().padStart(4, '0') + ".png" }))
                .put("priorFileIndexes", JSONArray()))
        val authentication = "ipb_member_id=101; ipb_pass_hash=secret-test-cookie; PHPSESSID=existing-session"
        item.getJSONObject("headers").put("Cookie", authentication)
        store.enqueue(JSONObject().put("accountId", "101").put("epoch", "observed-epoch")
            .put("taskId", "observed302").put("items", JSONArray(listOf(item))))
        val candidates = listOf(File("../../test/fixtures/uploads/uploaded.html"), File("../test/fixtures/uploads/uploaded.html"), File("test/fixtures/uploads/uploaded.html"))
        val html = candidates.first { it.isFile }.readBytes()
        runtime.connectionFactory = { url, _ ->
            (if (opened.isEmpty()) Connection(url, 302,
                location = "https://example.org/unsafe?token=redirect-test-secret",
                responseCookies = listOf("PHPSESSID=response-cookie-secret; Path=/; Secure",
                    "ipb_member_id=999; Path=/; Secure"))
             else Connection(url, response = html)).also { opened.add(it) }
        }
        runJob()
        assertEquals(listOf("POST", "GET"), opened.map { it.requestMethod })
        assertArrayEquals(payload, opened[0].sent.toByteArray())
        assertEquals(0, opened[1].sent.size())
        assertFalse(opened[1].doOutput)
        assertFalse(opened[1].requestHeaders.containsKey("Content-Type"))
        assertEquals(opened[0].requestHeaders["Cookie"], opened[1].requestHeaders["Cookie"])
        assertEquals(authentication, opened[1].requestHeaders["Cookie"])
        assertEquals(0, opened[0].locationReads)
        assertEquals(0, opened[0].responseHeaderReads)
        assertEquals("https://upld.e-hentai.org/managegallery?ulgid=12345", opened[1].url.toString())
        assertTrue(opened.all { !it.instanceFollowRedirects })
        assertEquals("completed", store.task("observed302").getString("state"))
        val receipt = store.receipts.getJSONObject(0)
        assertEquals("confirmed", receipt.getString("outcome"))
        assertEquals(200, receipt.getInt("status"))
        assertEquals(payload.size.toLong(), receipt.getLong("sentBytes"))
        assertTrue(receipt.getBoolean("originalVerified"))
        assertEquals(302, receipt.getInt("postStatus"))
        assertEquals(200, receipt.getInt("readbackStatus"))
        assertEquals("read_complete", receipt.getString("readbackStage"))
        val persisted = File(store.directory, "journal.json").readText()
        for (secret in listOf("redirect-test-secret", "response-cookie-secret", "existing-session")) {
            assertFalse(persisted.contains(secret))
            assertFalse(store.snapshot().toString().contains(secret))
        }
        runJob()
        assertEquals("A confirmed PRG receipt must not restart the upload", 2, opened.size)
    }
    @Test fun readbackNeverUsesLocationEvenWhenMissingMalformedOrUnsafe() {
        var number = 0
        for (status in listOf(302, 303)) for (location in listOf(null, "", "https://", "?ulgid=12345",
            "https://example.org/managegallery?ulgid=12345", "/managegallery?ulgid=54321",
            "/managegallery?ulgid=12345&act=delete", "/managegallery?ulgid=12345#upload",
            "/managegallery?ulgid=12345&firstsave=1")) {
            val taskId = "unsafe${++number}"
            enqueue(taskId = taskId, url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
            val before = opened.size
            runtime.connectionFactory = { url, _ ->
                (if (opened.size == before) Connection(url, status, location = location)
                 else Connection(url)).also { opened.add(it) }
            }
            runJob()
            assertEquals(listOf("POST", "GET"), opened.drop(before).map { it.requestMethod })
            assertEquals("https://upld.e-hentai.org/managegallery?ulgid=12345", opened.last().url.toString())
            assertArrayEquals(payload, opened[before].sent.toByteArray())
            assertEquals(0, opened[before].locationReads)
            assertEquals(0, opened.last().sent.size())
            val receipt = store.receipts.objects().last()
            assertEquals("awaitingVerification", receipt.getString("state"))
            assertFalse("HTTP 200 without valid new file evidence is not confirmation", receipt.optBoolean("acknowledged"))
            assertEquals(status, receipt.getInt("postStatus"))
            assertEquals(200, receipt.getInt("readbackStatus"))
            runJob()
            assertEquals(before + 2, opened.size)
            store.acknowledge(receipt.getString("receiptId"), "stop")
        }
    }
    @Test fun independentReadbackCannotConfirmImagesAlreadyPresentBeforeThePost() {
        store.prepareSession("101", "prior-epoch")
        val item = request("images", "https://upld.e-hentai.org/managegallery?ulgid=12345")
            .put("verification", JSONObject().put("galleryId", "12345")
                .put("expectedNames", JSONArray(listOf("0001.png")))
                .put("priorFileIndexes", JSONArray(listOf(279367042L))))
        item.getJSONObject("headers").put("Cookie", "ipb_member_id=101; ipb_pass_hash=secret-test-cookie")
        store.enqueue(JSONObject().put("accountId", "101").put("epoch", "prior-epoch")
            .put("taskId", "priorImages").put("items", JSONArray(listOf(item))))
        val candidates = listOf(File("../../test/fixtures/uploads/uploaded.html"), File("../test/fixtures/uploads/uploaded.html"), File("test/fixtures/uploads/uploaded.html"))
        val html = candidates.first { it.isFile }.readBytes()
        runtime.connectionFactory = { url, _ ->
            (if (opened.isEmpty()) Connection(url, 302)
             else Connection(url, response = html)).also { opened.add(it) }
        }
        runJob()
        assertEquals(listOf("POST", "GET"), opened.map { it.requestMethod })
        val receipt = store.receipts.getJSONObject(0)
        assertEquals("awaitingVerification", store.task("priorImages").getString("state"))
        assertFalse(receipt.getBoolean("originalVerified"))
        assertFalse(receipt.optBoolean("acknowledged"))
        assertEquals("read_complete", receipt.getString("readbackStage"))
        runJob()
        assertEquals(2, opened.size)
    }
    @Test fun canonicalReadbackRequiresAnOriginalKnownGalleryWithoutActionsOrAmbiguity() {
        val source = URL("https://upld.e-hentai.org/managegallery?ulgid=12345")
        for (original in listOf("https://upld.e-hentai.org/manage",
            "https://upld.e-hentai.org/managegallery", "https://upld.e-hentai.org/managegallery?ulgid=0",
            "https://upld.e-hentai.org/managegallery?ulgid=12345&ulgid=12345",
            "https://upld.e-hentai.org/managegallery?ulgid=12345&token=secret",
            "https://upld.e-hentai.org/managegallery?act=new",
            "https://upld.e-hentai.org/managegallery?ulgid=12345&%61ct=delete",
            "https://upld.e-hentai.org/managegallery?ulgid=12345#fragment",
            "https://example.org/managegallery?ulgid=12345",
            "http://upld.e-hentai.org/managegallery?ulgid=12345",
            "https://upld.e-hentai.org:444/managegallery?ulgid=12345",
            "https://user@upld.e-hentai.org/managegallery?ulgid=12345")) {
            reason("redirect_requires_verification") { runtime.canonicalGalleryReadback(URL(original)) }
        }
        reason("redirect_requires_verification") {
            runtime.canonicalGalleryReadback(source, "54321")
        }
        assertEquals(source.toString(), runtime.canonicalGalleryReadback(source, "12345").toString())
        assertEquals(source.toString(), runtime.canonicalGalleryReadback(
            URL("https://upld.e-hentai.org:443/managegallery?ulgid=12345"), "12345").toString())
        enqueue()
        runtime.connectionFactory = { url, _ -> Connection(url, 302,
            location = source.toString()).also { opened.add(it) } }
        runJob()
        assertEquals("Location cannot supply a missing original gallery identity", 1, opened.size)
        val receipt = store.receipts.getJSONObject(0)
        assertEquals("source_check", receipt.getString("readbackStage"))
        assertEquals(302, receipt.getInt("postStatus"))
        assertFalse(receipt.has("readbackStatus"))
    }
    @Test fun redirectReadFailureAndFurtherRedirectStayUncertainWithoutReposting() {
        for (readFailure in listOf(false, true)) {
            val taskId = if (readFailure) "getLost" else "redirectChain"
            enqueue(taskId = taskId, url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
            val before = opened.size
            runtime.connectionFactory = { url, _ ->
                (if (opened.size == before) Connection(url, 302, location = "/managegallery?ulgid=12345")
                 else if (readFailure) Connection(url, readFailure = true)
                 else Connection(url, 302, location = "/managegallery?ulgid=12345")).also { opened.add(it) }
            }
            runJob()
            assertEquals(listOf("POST", "GET"), opened.drop(before).map { it.requestMethod })
            assertEquals(0, opened.last().sent.size())
            assertEquals("uncertain", store.task(taskId).getString("state"))
            val receipt = store.receipts.objects().last()
            assertEquals(if (readFailure) "read_headers" else "read_redirect", receipt.getString("readbackStage"))
            assertEquals(if (readFailure) 200 else 302, receipt.getInt("readbackStatus"))
            runJob()
            assertEquals(before + 2, opened.size)
            store.acknowledge(store.receipts.objects().last().getString("receiptId"), "stop")
        }
    }
    @Test fun pauseAfterPostResponseDoesNotStartRedirectRead() {
        enqueue(url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
        runtime.connectionFactory = { url, _ -> Connection(url, 302, location = "/managegallery?ulgid=12345",
            onResponse = { runtime.pause("task1") }).also { opened.add(it) } }
        runJob()
        assertEquals(1, opened.size)
        assertArrayEquals(payload, opened.single().sent.toByteArray())
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("paused_after_send", store.receipts.getJSONObject(0).getString("reason"))
    }
    @Test fun confirmedReceiptClearsPriorTaskFailureAndKeepsOnlyReceiptHistory() {
        enqueue(url = "https://upld.e-hentai.org/managegallery?ulgid=12345")
        runtime.connectionFactory = { url, _ ->
            Connection(url, 307, location = "/managegallery?ulgid=12345").also { opened.add(it) }
        }
        runJob()
        assertEquals("uncertain", store.task("task1").getString("state"))
        assertEquals("redirect_requires_verification", store.task("task1").getString("reason"))
        val id = store.receipts.getJSONObject(0).getString("receiptId")
        runtime.acknowledgeFromUi(id, "confirmed") // Explicit remote reconciliation.
        val reopened = UploadTransferStore(root, vault)
        assertEquals("completed", reopened.task("task1").getString("state"))
        assertEquals("files_confirmed", reopened.task("task1").getString("reason"))
        assertEquals("confirmed", reopened.task("task1").getJSONArray("items").getJSONObject(0).getString("state"))
        assertEquals("confirmed", reopened.receipts.getJSONObject(0).getString("outcome"))
        assertEquals("redirect_requires_verification", reopened.receipts.getJSONObject(0).getString("reason"))
        runtime.acknowledgeFromUi(id, "confirmed")
        runJob()
        assertEquals("Reconciliation must not send another POST", 1, opened.size)
    }
    @Test fun explicitHttpProxyIsKeptAndUnsupportedProxiesNeverFallBack() {
        enqueue(proxy = "http://127.0.0.1:7890")
        runtime.connectionFactory = { url, proxy ->
            assertNotNull(proxy); assertEquals(Proxy.Type.HTTP, proxy!!.type())
            Connection(url).also { opened.add(it) }
        }
        runJob()
        for (value in listOf("socks5://127.0.0.1:7890", "https://127.0.0.1:7890", "http://user:pass@host:8080")) {
            reason("unsupported_proxy") { UploadTransferRequest.proxy(value) }
        }
    }
    @Test fun boundedResponseCannotBeMistakenForSuccess() {
        enqueue()
        runtime.connectionFactory = { url, _ -> Connection(url, response = ByteArray(UploadTransferRuntime.RESPONSE_LIMIT + 1)).also { opened.add(it) } }
        runJob()
        assertEquals("response_too_large", store.receipts.getJSONObject(0).getString("reason"))
        assertEquals("uncertain", store.task("task1").getString("state"))
    }
    @Test fun explicitRetryNeedsResumeAndAcknowledgementIsIdempotent() {
        enqueue()
        runtime.connectionFactory = { url, _ -> Connection(url, readFailure = true).also { opened.add(it) } }
        runJob()
        val id = store.receipts.getJSONObject(0).getString("receiptId")
        store.acknowledge(id, "retry")
        store.acknowledge(id, "retry")
        assertEquals("paused", store.task("task1").getString("state"))
        runJob(); assertEquals(1, opened.size)
        reason("receipt_already_resolved") { store.acknowledge(id, "confirmed") }
    }
    @Test fun uiCannotAcknowledgeWhilePausedRequestThreadIsStillStopping() {
        enqueue()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val done = AtomicBoolean(false)
        runtime.connectionFactory = { url, _ -> Connection(url, onSend = {
            entered.countDown()
            check(release.await(10, TimeUnit.SECONDS))
        }) }
        runtime.runAcceptedJob { done.set(true) }
        assertTrue(entered.await(10, TimeUnit.SECONDS))
        try {
            runtime.pause("task1")
            val id = store.receipts.getJSONObject(0).getString("receiptId")
            reason("transfer_still_stopping") { runtime.acknowledgeFromUi(id, "retry") }
            assertFalse(store.receipts.getJSONObject(0).getBoolean("acknowledged"))
        } finally { release.countDown() }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (!done.get() && System.nanoTime() < deadline) {
            Shadows.shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10)
        }
        assertTrue(done.get())
        runtime.acknowledgeFromUi(store.receipts.getJSONObject(0).getString("receiptId"), "retry")
        assertEquals("paused", store.task("task1").getString("state"))
    }
    @Test fun rejectsUnsafePathsOriginsAndHeaderInjection() {
        for (path in listOf("../secret", "/outside", "C:\\secret", "native/../body")) {
            reason("unsafe_path") { UploadTransferPaths.file(root, path) }
        }
        for (url in listOf("http://upld.e-hentai.org/manage", "https://upld.e-hentai.org.evil.org/manage", "https://user@upld.e-hentai.org/manage", "https://exhentai.org/manage")) {
            reason("invalid_upload_url") { UploadTransferRequest.from(request(url = url)) }
        }
        val raw = request()
        raw.getJSONObject("headers").put("Cookie", "valid\r\nX-Injected: bad")
        reason("invalid_header") { UploadTransferRequest.from(raw) }
    }
    @Test fun productionKeystoreRoundTripAndRevocationWhenProviderIsAvailable() {
        // Robolectric normally has no platform AndroidKeyStore provider. Do
        // not replace it with a fake and present that as encryption validation.
        Assume.assumeTrue("AndroidKeyStore unavailable on this host; physical-device verification required",
            Security.getProvider("AndroidKeyStore") != null)
        val context = RuntimeEnvironment.getApplication()
        val real = UploadTransferSecrets(context, File(root, "native/android"))
        val sealed = real.seal("private test credential")
        assertFalse(sealed.contains("private test credential"))
        assertEquals("private test credential", real.open(sealed))
        val reopened = UploadTransferSecrets(context, File(root, "native/android"))
        assertEquals("private test credential", reopened.open(sealed))
        reopened.revoke()
        try { reopened.open(sealed); fail("Revocation must invalidate old ciphertext") }
        catch (_: Exception) { /* Decryption is expected to fail after revocation. */ }
        val fresh = reopened.seal("new session")
        assertEquals("new session", reopened.open(fresh))
        reopened.revoke()
    }
}
