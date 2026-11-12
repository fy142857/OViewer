package com.oviewer.oviewer

import android.app.Activity
import android.app.job.JobScheduler
import android.os.Build
import android.os.Bundle
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONArray
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.URL
import java.nio.ByteBuffer
import java.security.cert.Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection

/** Debug-only, non-exported host for OS scheduler tests. Never contacts E-Hentai
 * and refuses physical devices or any existing authenticated upload state. */
class UploadValidationActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply { text = "Upload scheduler validation"; textSize = 20f })
    }

    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private class FixtureConnection(url: URL, private val fixture: ByteArray,
        private val opened: CountDownLatch, private val release: CountDownLatch,
        private val requests: AtomicInteger) : HttpsURLConnection(url) {
        override fun connect() { connected = true }
        override fun disconnect() {}
        override fun usingProxy() = false
        override fun getCipherSuite() = "TEST_FIXTURE_NO_NETWORK"
        override fun getLocalCertificates(): Array<Certificate>? = null
        override fun getServerCertificates(): Array<Certificate> = emptyArray()
        override fun getOutputStream(): OutputStream = ByteArrayOutputStream()
        override fun getResponseCode(): Int {
            requests.incrementAndGet(); opened.countDown()
            check(release.await(30, TimeUnit.SECONDS)) { "Fixture response was not released" }
            return 200
        }
        override fun getHeaderField(name: String): String? = null
        override fun getInputStream(): InputStream = ByteArrayInputStream(fixture)
        override fun getErrorStream(): InputStream = ByteArrayInputStream(fixture)
    }

    private fun invoke(runtime: UploadTransferRuntime, method: String, arguments: Map<String, Any?>? = null): Any? {
        val done = CountDownLatch(1)
        var value: Any? = null
        var failure: String? = null
        runOnUiThread { runtime.onMethodCall(MethodCall(method, arguments), object : MethodChannel.Result {
            override fun success(result: Any?) { value = result; done.countDown() }
            override fun error(code: String, message: String?, details: Any?) { failure = code; done.countDown() }
            override fun notImplemented() { failure = "not_implemented"; done.countDown() }
        }) }
        check(done.await(20, TimeUnit.SECONDS)) { "Native command timed out: $method" }
        check(failure == null) { "Native command failed: $method ($failure)" }
        return value
    }

    fun validate(fixture: ByteArray): Map<String, Any> {
        check(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish") { "Only a dedicated emulator is allowed" }
        check(Build.VERSION.SDK_INT >= 34) { "UIDT requires API 34 or later" }
        val appRoot = File(applicationInfo.dataDir, "app_flutter")
        check(!File(appRoot, ".cookies/ie1_ps1/.domains").exists()) { "Refusing a device with saved site cookies" }
        val root = File(appRoot, "uploads").apply { mkdirs() }
        val journalFile = File(root, "native/android/journal.json")
        check(!journalFile.exists()) { "Use a fresh validation application; existing upload records are preserved" }
        val epoch = "instrumentation-${System.nanoTime()}"
        val sealer = UploadTransferSecrets(this, File(root, "native/android"))
        val probe = "test-only-credential"
        val sealed = sealer.seal(probe)
        check(sealed != probe && sealer.open(sealed) == probe) { "Production AndroidKeyStore round trip failed" }
        sealer.revoke()
        val body = File(root, "validation.multipart")
        body.writeText("--fixture\r\nContent-Disposition: form-data; name=\"test\"\r\n\r\nfixture\r\n--fixture--\r\n")
        val length = body.length()
        val sha = uploadSha256(body) { false }
        val runtime = UploadTransferRuntime.get(applicationContext)
        val opened = CountDownLatch(1)
        val release = CountDownLatch(1)
        val requests = AtomicInteger()
        runOnUiThread {
            runtime.bind(Messenger()) { this }
            runtime.connectionFactory = { url, _ -> FixtureConnection(url, fixture, opened, release, requests) }
        }
        val firstFrame = CountDownLatch(1)
        runOnUiThread { window.decorView.post { firstFrame.countDown() } }
        check(firstFrame.await(10, TimeUnit.SECONDS)) { "Validation Activity did not become visible" }
        try {
            invoke(runtime, "prepareSession", mapOf("accountId" to "101", "epoch" to epoch))
            val items = (1..2).map { index -> mapOf(
                "id" to "item-$index", "url" to "https://upld.e-hentai.org/managegallery?ulgid=12345",
                "bodyPath" to "validation.multipart", "length" to length, "sha256" to sha, "wifiOnly" to false,
                "headers" to mapOf("Content-Type" to "multipart/form-data; boundary=fixture", "User-Agent" to "OViewer-Validation",
                    "Cookie" to "ipb_member_id=101; ipb_pass_hash=fixture-not-an-account"),
                "verification" to mapOf("galleryId" to "12345", "expectedNames" to listOf("000$index.png"),
                    "priorFileIndexes" to emptyList<Int>())) }
            invoke(runtime, "enqueue", mapOf("accountId" to "101", "epoch" to epoch,
                "taskId" to "scheduler-test", "items" to items, "language" to "en"))
            check(opened.await(30, TimeUnit.SECONDS)) { "The OS did not start the scheduled UIDT job" }
            val scheduler = getSystemService(JobScheduler::class.java)
            val job = scheduler.getPendingJob(UploadTransferRuntime.JOB)
            check(job != null && job.isUserInitiated) { "The transfer was not scheduled as UIDT" }
            check(job!!.service.className == UploadTransferJobService::class.java.name)
            val background = CountDownLatch(1)
            runOnUiThread { check(moveTaskToBack(true)); background.countDown() }
            check(background.await(5, TimeUnit.SECONDS))
            // Only the fixture waits here. The native job continues without a Flutter engine.
            release.countDown()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            var completed = false
            while (System.nanoTime() < deadline) {
                val snapshot = invoke(runtime, "snapshot") as Map<*, *>
                val task = (snapshot["tasks"] as List<*>).filterIsInstance<Map<*, *>>().firstOrNull { it["taskId"] == "scheduler-test" }
                if (task?.get("state") == "completed") { completed = true; break }
                Thread.sleep(100)
            }
            check(completed && requests.get() == 2) { "Two native batches did not complete in the background" }
            invoke(runtime, "invalidateSession", mapOf("epoch" to epoch))
            return mapOf("api" to Build.VERSION.SDK_INT, "productionKeystore" to true,
                "osUidtStarted" to true, "backgroundBatches" to requests.get(),
                "flutterEngineRequired" to false, "server" to "fixture; no external requests")
        } finally {
            release.countDown()
            try { invoke(runtime, "invalidateSession", mapOf("epoch" to epoch)) } catch (_: Exception) {}
            runtime.connectionFactory = null
            body.delete()
            runOnUiThread { finish() }
        }
    }
}
