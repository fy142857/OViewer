package com.oviewer.oviewer

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Proxy
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection

/** The verifier must prove the site's receipt means files were accepted. The
 * default deliberately cannot turn an HTTP 200 into gallery-level success. */
interface UploadTransferReceiptVerifier {
    fun verify(response: File?, receipt: Map<String, Any?>): Boolean
}

class UploadTransferRuntime private constructor(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "gallery_uploads"
        const val NOTIFICATION = 7783
        const val JOB = 7783
        const val OPEN = "com.oviewer.oviewer.OPEN_UPLOADS"
        const val PAUSE = "com.oviewer.oviewer.PAUSE_UPLOADS"
        const val RESPONSE_LIMIT = 2 * 1024 * 1024
        @Volatile private var instance: UploadTransferRuntime? = null
        fun get(context: Context): UploadTransferRuntime = instance ?: synchronized(this) {
            instance ?: UploadTransferRuntime(context.applicationContext).also { instance = it }
        }
        internal fun clearForTest() {
            instance?.let { it.interruptActive(); it.activeWifiGate?.close(); it.commands.shutdownNow(); it.worker.shutdownNow(); it.detach() }
            instance = null
        }
    }
    private val lock = Any()
    private val commands = Executors.newSingleThreadExecutor()
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val root = File(context.applicationInfo.dataDir, "app_flutter/uploads").apply { mkdirs() }
    private val logoutMarker = File(context.applicationInfo.dataDir, "app_flutter/.cookies/logout-pending")
    private val defaultJournal by lazy {
        UploadTransferStore(root, UploadTransferSecrets(context, UploadTransferPaths.file(root, "native/android")))
    }
    internal var storeOverride: UploadTransferStore? = null
    internal var connectionFactory: ((URL, Proxy?) -> HttpsURLConnection)? = null
    internal var wifiGateFactory: ((Context, (String) -> Unit) -> UploadWifiGate)? = null
    private val journal get() = storeOverride ?: defaultJournal
    private var channel: MethodChannel? = null
    private var foreground: (() -> Activity?)? = null
    @Volatile private var running = false
    @Volatile private var activeTask: String? = null
    @Volatile private var stop = AtomicBoolean(false)
    @Volatile private var connection: HttpsURLConnection? = null
    @Volatile private var activeWifiGate: UploadWifiGate? = null
    var receiptVerifier: UploadTransferReceiptVerifier? = UploadGalleryReceiptVerifier()

    fun bind(messenger: BinaryMessenger, foregroundActivity: () -> Activity?) {
        detach()
        foreground = foregroundActivity
        channel = MethodChannel(messenger, "oviewer/upload_transport").also { it.setMethodCallHandler(this) }
        ensureNotificationChannel()
    }
    fun detach() { channel?.setMethodCallHandler(null); channel = null; foreground = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val supported = setOf("prepareSession", "enqueue", "snapshot", "pause", "resume", "cancel", "invalidateSession", "acknowledge")
        if (call.method !in supported) { result.notImplemented(); return }
        // A visible Activity is checked while handling the UI request. It is
        // not needed when an already accepted native job continues in background.
        val canStart = foreground?.invoke()?.let { !it.isFinishing } == true
        commands.execute {
            try {
                @Suppress("UNCHECKED_CAST")
                val args = JSONObject(call.arguments as? Map<String, Any?> ?: emptyMap<String, Any?>())
                val answer: Any? = when (call.method) {
                    "prepareSession" -> { prepareSession(args.getString("accountId"), args.getString("epoch")); null }
                    "enqueue" -> {
                        if (!canStart) throw UploadTransferFailure("foreground_required")
                        synchronized(lock) { requireNoPendingLogout(); journal.enqueue(args) }
                        schedule()
                        requestUploadNotifications()
                        null
                    }
                    "snapshot" -> synchronized(lock) { journal.snapshot() }
                    "pause", "cancel" -> { pause(args.getString("taskId"), call.method == "cancel"); null }
                    "resume" -> {
                        if (!canStart) throw UploadTransferFailure("foreground_required")
                        synchronized(lock) {
                            requireNoPendingLogout()
                            val task = journal.task(args.getString("taskId")); journal.assertCurrent(task)
                            if (task.optString("state") !in setOf("paused", "queued") || task.getJSONArray("items").objects().none { it.optString("state") == "queued" }) {
                                throw UploadTransferFailure("verification_required")
                            }
                            task.put("state", "queued").put("reason", JSONObject.NULL); journal.save()
                        }
                        schedule(); null
                    }
                    "invalidateSession" -> synchronized(lock) {
                        if (journal.epoch == args.getString("epoch")) interruptActive()
                        journal.invalidate(args.getString("epoch")); null
                    }
                    "acknowledge" -> {
                        acknowledgeFromUi(args.getString("receiptId"), args.getString("outcome"))
                        // Retry acknowledgement only prepares the item; resume is
                        // separately requested in foreground. Confirmed receipts
                        // can continue queued work while this native job lives.
                        if (args.getString("outcome") == "confirmed" && canStart) schedule()
                        null
                    }
                    else -> null
                }
                changed()
                main.post { result.success(answer) }
            } catch (error: Exception) {
                val reason = (error as? UploadTransferFailure)?.reason ?: "transport_storage_error"
                main.post { result.error(reason, "Upload transfer could not complete this operation", null) }
            }
        }
    }

    private fun requestUploadNotifications() {
        // Only a newly accepted foreground upload may ask. Recovery/resume and
        // native continuation do not open permission UI. Recheck after the
        // asynchronous journal write, because the Activity may have paused.
        main.post {
            try {
                val activity = foreground?.invoke()?.takeIf { !it.isFinishing && !it.isDestroyed }
                    ?: return@post
                (context as? OViewerApplication)?.requestNotifications(activity)
            } catch (_: Exception) {
                // Notification permission is optional; denial or a platform
                // request failure must not cancel an accepted upload.
            }
        }
    }

    internal fun acknowledgeFromUi(receiptId: String, outcome: String) = synchronized(lock) {
        val receipt = journal.receipts.objects().firstOrNull { it.getString("receiptId") == receiptId }
            ?: throw UploadTransferFailure("unknown_receipt")
        if (running && activeTask == receipt.getString("taskId")) {
            throw UploadTransferFailure("transfer_still_stopping")
        }
        journal.acknowledge(receiptId, outcome)
    }

    internal fun prepareSession(accountId: String, epoch: String) = synchronized(lock) {
        requireNoPendingLogout()
        if (journal.epoch != epoch || journal.account != accountId) interruptActive()
        journal.prepareSession(accountId, epoch)
    }

    /** CookieManager writes this marker before beginning logout. Reading only
     * its existence closes the process-death gap before native invalidation.
     * The persistent random epoch remains the primary request identity. */
    private fun requireNoPendingLogout() {
        if (!logoutMarker.exists()) return
        interruptActive()
        journal.epoch?.let { journal.invalidate(it) }
        throw UploadTransferFailure("logout_in_progress")
    }

    internal fun pause(taskId: String, cancelled: Boolean = false) {
        synchronized(lock) {
            val task = journal.task(taskId)
            if (task.getString("accountId") != journal.account) throw UploadTransferFailure("stale_session")
            if (activeTask == taskId) interruptActive()
            for (item in task.getJSONArray("items").objects()) {
                if (item.optString("state") == "sending") journal.receipt(task, item, "uncertain", if (cancelled) "cancelled_after_send" else "paused_after_send")
                if (cancelled) {
                    if (item.optString("state") == "queued") item.put("state", "stopped")
                    item.remove("sealed")
                }
            }
            val uncertain = task.getJSONArray("items").objects().any { it.optString("state") in setOf("uncertain", "awaitingVerification") }
            if (task.optString("state") != "completed") task.put("state", if (uncertain) "uncertain" else if (cancelled) "stopped" else "paused")
                .put("reason", if (cancelled) "cancelled" else "user_paused").put("updatedAt", System.currentTimeMillis())
            journal.save()
        }
        changed()
    }
    fun pauseFromNotification() {
        commands.execute {
            try {
                val target = activeTask ?: synchronized(lock) { journal.tasks.objects().firstOrNull { journal.current(it) && it.optString("state") == "queued" }?.getString("taskId") }
                if (target != null) pause(target)
            } catch (_: Exception) { interruptActive() }
        }
    }
    private fun interruptActive() { stop.set(true); connection?.disconnect() }
    fun stoppedBySystem() {
        interruptActive()
        commands.execute {
            try {
                synchronized(lock) {
                    for (task in journal.tasks.objects().filter { journal.current(it) }) {
                        for (item in task.getJSONArray("items").objects()) {
                            if (item.optString("state") == "sending") journal.receipt(task, item, "uncertain", "system_interrupted")
                        }
                        if (task.optString("state") == "queued") task.put("state", "paused").put("reason", "system_interrupted")
                    }
                    journal.save()
                }
            } catch (_: Exception) { /* No further transmission. */ }
            changed()
        }
    }

    private fun schedule() {
        if (running) return
        val pending = synchronized(lock) { next() } ?: return
        ensureNotificationChannel()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                val request = synchronized(lock) { journal.request(pending.second).first }
                val info = JobInfo.Builder(JOB, ComponentName(context, UploadTransferJobService::class.java))
                    .setUserInitiated(true).setRequiredNetwork(requiredNetwork(request.wifiOnly))
                    .setEstimatedNetworkBytes(0, request.length).build()
                val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
                if (scheduler.allPendingJobs.any { it.id == JOB }) return
                if (scheduler.schedule(info) != JobScheduler.RESULT_SUCCESS) throw UploadTransferFailure("background_unavailable")
            } else {
                ContextCompat.startForegroundService(context, Intent(context, UploadTransferService::class.java))
            }
        } catch (error: Exception) {
            synchronized(lock) {
                pending.first.put("state", "paused").put("reason", "background_unavailable"); journal.save()
            }
            throw if (error is UploadTransferFailure) error else UploadTransferFailure("background_unavailable")
        }
    }

    internal fun requiredNetwork(wifiOnly: Boolean): NetworkRequest {
        val builder = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        if (wifiOnly) builder.addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        return builder.build()
    }

    /** UIDT network callbacks supplement, rather than replace, the default-route guard. */
    fun onJobNetworkChanged() { activeWifiGate?.onNetworkChanged() }

    private fun next(): Pair<JSONObject, JSONObject>? {
        requireNoPendingLogout()
        if (journal.epoch == null) return null
        if (journal.receipts.objects().any { it.getString("accountId") == journal.account && !it.optBoolean("acknowledged") }) return null
        for (task in journal.tasks.objects().filter { journal.current(it) && it.optString("state") == "queued" }) {
            val item = task.getJSONArray("items").objects().firstOrNull { it.optString("state") == "queued" }
            if (item != null) return task to item
        }
        return null
    }

    /** Invoked by the OS service, not by Flutter; works after a cold process start. */
    fun runAcceptedJob(finished: () -> Unit) {
        synchronized(lock) {
            if (running) { main.post(finished); return }
            running = true; stop = AtomicBoolean(false)
        }
        worker.execute {
            try {
                while (!stop.get()) {
                    val pending = synchronized(lock) { next() } ?: break
                    activeTask = pending.first.getString("taskId")
                    transfer(pending.first, pending.second)
                }
            } catch (_: Exception) {
                stop.set(true)
            } finally {
                running = false; activeTask = null; connection = null
                changed()
                main.post(finished)
            }
        }
    }

    private fun transfer(task: JSONObject, item: JSONObject) {
        var responsePath: String? = null
        var status: Int? = null
        var finalUrl: String? = null
        val readbackDiagnostics = linkedMapOf<String, Any>()
        var wifiGate: UploadWifiGate? = null
        val guardedConnection = AtomicReference<HttpsURLConnection?>(null)
        fun checkWifi() {
            wifiGate?.check()?.let { throw UploadTransferFailure(it) }
        }
        try {
            val config = synchronized(lock) { requireNoPendingLogout(); journal.assertCurrent(task); journal.request(item) }
            val request = config.first
            if (request.wifiOnly) {
                val onViolation: (String) -> Unit = { guardedConnection.get()?.disconnect() }
                wifiGate = wifiGateFactory?.invoke(context, onViolation) ?: UploadWifiGate(context, onViolation)
                activeWifiGate = wifiGate
                wifiGate.start()?.let { throw UploadTransferFailure(it) }
            }
            val body = UploadTransferPaths.file(root, request.bodyPath)
            if (!body.isFile || body.length() != request.length || uploadSha256(body) {
                stop.get() || logoutMarker.exists() || wifiGate?.currentViolation() != null
            } != request.sha256) {
                throw UploadTransferFailure("prepared_body_changed")
            }
            if (stop.get()) throw UploadTransferFailure("paused")
            checkWifi()
            synchronized(lock) {
                requireNoPendingLogout()
                journal.assertCurrent(task)
                if (task.optString("state") != "queued" || item.optString("state") != "queued") throw UploadTransferFailure("paused")
                item.put("state", "sending").put("sentBytes", 0L)
                task.put("state", "sending").put("updatedAt", System.currentTimeMillis())
                journal.save() // Durable before opening/sending the request.
            }
            changed()
            checkWifi()
            var conn = open(request.url, config.second)
            guardedConnection.set(conn)
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setFixedLengthStreamingMode(request.length)
            request.headers.forEach { (key, value) -> conn.setRequestProperty(key, value) }
            var sent = 0L
            var lastSaved = 0L
            val transmittedDigest = MessageDigest.getInstance("SHA-256")
            synchronized(lock) { requireNoPendingLogout() }
            checkWifi()
            conn.outputStream.use { output -> body.inputStream().use { input ->
                val buffer = ByteArray(65536)
                while (true) {
                    if (stop.get()) throw UploadTransferFailure("paused_after_send")
                    if (logoutMarker.exists()) synchronized(lock) { requireNoPendingLogout() }
                    val count = input.read(buffer); if (count < 0) break
                    if (sent + count > request.length) throw UploadTransferFailure("prepared_body_changed_after_send")
                    transmittedDigest.update(buffer, 0, count)
                    checkWifi()
                    output.write(buffer, 0, count); sent += count
                    synchronized(lock) { item.put("sentBytes", sent) }
                    val now = System.currentTimeMillis()
                    if (now - lastSaved >= 1000) {
                        synchronized(lock) { journal.save() }; changed(); lastSaved = now
                    }
                }
                checkWifi()
                output.flush()
            } }
            val transmittedHash = transmittedDigest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            if (sent != request.length || transmittedHash != request.sha256) throw UploadTransferFailure("prepared_body_changed_after_send")
            checkWifi()
            status = conn.responseCode
            finalUrl = request.url.toString()
            // A redirect does not prove acceptance. Independently read the
            // original known gallery once, rather than following Location.
            // Upload-only fragments/parameters and URI resolution differences
            // cannot change this destination or cause the POST to be replayed.
            if (status == 302 || status == 303) {
                readbackDiagnostics["postStatus"] = status
                readbackDiagnostics["readbackStage"] = "source_check"
                val target = canonicalGalleryReadback(request.url, request.verification?.galleryId)
                conn.disconnect()
                readbackDiagnostics["readbackStage"] = "read_start"
                checkWifi()
                conn = open(target, config.second)
                guardedConnection.set(conn)
                conn.requestMethod = "GET"
                // Reuse only this task's authentication. Do not merge response
                // cookies, create a global jar, or persist cookie diagnostics.
                request.headers.filterKeys { it != "Content-Type" }.forEach { (key, value) -> conn.setRequestProperty(key, value) }
                synchronized(lock) {
                    requireNoPendingLogout()
                    journal.assertCurrent(task)
                    if (stop.get() || item.optString("state") != "sending") throw UploadTransferFailure("paused_after_send")
                }
                checkWifi()
                status = conn.responseCode; finalUrl = target.toString()
                readbackDiagnostics["readbackStatus"] = status
                readbackDiagnostics["readbackStage"] = if (status in 300..399) "read_redirect" else "read_headers"
            }
            if (status in 300..399) throw UploadTransferFailure("redirect_requires_verification")
            responsePath = "native/android/responses/${UUID.randomUUID()}.response"
            val response = UploadTransferPaths.file(root, responsePath)
            response.parentFile!!.mkdirs()
            checkWifi()
            val source = if (status >= 400) conn.errorStream else conn.inputStream
            val receivedBytes = ByteArrayOutputStream()
            receivedBytes.use { output ->
                var received = 0
                source?.use { input ->
                    val buffer = ByteArray(16384)
                    while (true) {
                        if (stop.get()) throw UploadTransferFailure("paused_after_send")
                        checkWifi()
                        val count = input.read(buffer); if (count < 0) break
                        received += count
                        if (received > RESPONSE_LIMIT) throw UploadTransferFailure("response_too_large")
                        output.write(buffer, 0, count)
                    }
                }
            }
            val raw = receivedBytes.toString(Charsets.UTF_8.name())
            if (readbackDiagnostics.isNotEmpty()) readbackDiagnostics["readbackStage"] = "read_complete"
            val verifier = receiptVerifier
            val rawContext = mapOf<String, Any?>("state" to "awaitingVerification", "status" to status,
                "accountId" to task.getString("accountId"), "finalUrl" to finalUrl,
                "sentBytes" to item.optLong("sentBytes"), "length" to item.getLong("length"),
                "verification" to item.optJSONObject("verification")?.toMap())
            val rawVerified = verifier !is UploadGalleryReceiptVerifier || verifier.verifyHtml(raw, rawContext)
            val sanitized = UploadReceiptSanitizer.redact(raw).toByteArray(Charsets.UTF_8)
            if (stop.get()) throw UploadTransferFailure("paused_after_send")
            checkWifi()
            UploadTransferJournal(response).write(sanitized)
            val receipt = synchronized(lock) {
                // A pause/logout may have already recorded the uncertain
                // outcome. Its receipt remains authoritative; no new work starts.
                if (item.optString("state") != "sending" || !journal.current(task)) return
                val receipt = journal.receipt(task, item, "awaitingVerification",
                    if (safeReceiptUrl(finalUrl) == null) "unexpected_final_url" else if (status in 200..299) null else "http_error",
                    status, safeReceiptUrl(finalUrl), responsePath)
                receipt.put("originalVerified", rawVerified).put("responseSanitized", true).put("responsePrivacyVersion", 1)
                readbackDiagnostics.forEach { (key, value) -> receipt.put(key, value) }
                journal.save()
                receipt.toMap()
            }
            if (verifier != null && rawVerified && status in 200..299 && !stop.get()) {
                val confirmed = try { verifier.verify(response, receipt) } catch (_: Exception) { false }
                if (confirmed) synchronized(lock) {
                    if (!stop.get() && journal.current(task) && item.optString("state") == "awaitingVerification") {
                        journal.acknowledge(receipt.getValue("receiptId") as String, "confirmed")
                    }
                }
            }
        } catch (error: Exception) {
            synchronized(lock) {
                val networkFailure = wifiGate?.currentViolation()
                val reason = if (networkFailure != null) {
                    if (item.optString("state") == "sending") "wifi_changed_after_send" else networkFailure
                } else (error as? UploadTransferFailure)?.reason ?: "network_interrupted"
                if (item.optString("state") == "sending") {
                    val receipt = journal.receipt(task, item, "uncertain", reason,
                        status, safeReceiptUrl(finalUrl), responsePath)
                    readbackDiagnostics.forEach { (key, value) -> receipt.put(key, value) }
                } else if (item.optString("state") == "queued" && journal.current(task)) {
                    task.put("state", "paused").put("reason", networkFailure ?: (error as? UploadTransferFailure)?.reason ?: "transport_error")
                }
                try { journal.save() } catch (_: Exception) { stop.set(true) }
            }
        } finally {
            guardedConnection.set(null)
            if (activeWifiGate === wifiGate) activeWifiGate = null
            wifiGate?.close()
            connection?.disconnect(); connection = null
            responsePath?.let { path ->
                val referenced = synchronized(lock) { journal.receipts.objects().any { it.optString("responsePath") == path } }
                if (!referenced) {
                    try { UploadTransferPaths.file(root, path).delete() } catch (_: Exception) {}
                }
            }
            changed()
        }
    }

    private fun safeReceiptUrl(value: String?): String? = try {
        val uri = java.net.URI(value ?: "")
        if (uri.scheme == "https" && uri.host == "upld.e-hentai.org" && uri.userInfo == null &&
            uri.port in setOf(-1, 443) && uri.fragment == null && uri.path == "/managegallery" &&
            Regex("^ulgid=[1-9][0-9]*$").matches(uri.rawQuery.orEmpty())) uri.toString() else null
    } catch (_: Exception) { null }

    private fun open(url: URL, proxy: Proxy?): HttpsURLConnection {
        if (stop.get()) throw UploadTransferFailure("paused")
        val conn = connectionFactory?.invoke(url, proxy) ?:
            (if (proxy == null) url.openConnection() else url.openConnection(proxy)) as HttpsURLConnection
        // Keep the platform certificate verifier, hostname verifier, and TLS.
        conn.instanceFollowRedirects = false
        conn.connectTimeout = 30000; conn.readTimeout = 60000; conn.useCaches = false
        connection = conn
        return conn
    }
    internal fun canonicalGalleryReadback(original: URL, expectedGalleryId: String? = null): URL {
        try {
            val validated = safeReceiptUrl(original.toString())
                ?: throw UploadTransferFailure("redirect_requires_verification")
            val gallery = java.net.URI(validated).rawQuery.removePrefix("ulgid=")
            if (expectedGalleryId != null && gallery != expectedGalleryId) {
                throw UploadTransferFailure("redirect_requires_verification")
            }
            // Derive the read only from the original authenticated upload
            // target. Location and Set-Cookie are intentionally not inputs.
            return URL("https://upld.e-hentai.org/managegallery?ulgid=$gallery")
        } catch (_: Exception) {
            throw UploadTransferFailure("redirect_requires_verification")
        }
    }

    private fun changed() {
        main.post {
            channel?.invokeMethod("changed", null)
            UploadTransferService.instance?.keepAwake()
            if (running) try { manager().notify(NOTIFICATION, notification()) } catch (_: Exception) { /* Permission denial is not transfer success/failure. */ }
        }
    }
    private fun manager() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) manager().createNotificationChannel(NotificationChannel(CHANNEL,
            "Gallery uploads", NotificationManager.IMPORTANCE_LOW).apply { lockscreenVisibility = Notification.VISIBILITY_PRIVATE })
    }
    fun notification(): Notification {
        val state = synchronized(lock) {
            val task = activeTask?.let { id -> journal.tasks.objects().firstOrNull { it.getString("taskId") == id } }
            val items = task?.getJSONArray("items")?.objects().orEmpty()
            Triple(task?.optString("language") ?: "zh", items.sumOf { it.optLong("sentBytes") }, items.sumOf { it.optLong("length") })
        }
        val zh = state.first != "en"
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(context, NOTIFICATION,
            Intent(context, MainActivity::class.java).setAction(OPEN)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), flags)
        val pause = PendingIntent.getBroadcast(context, NOTIFICATION,
            Intent(context, UploadTransferPauseReceiver::class.java).setAction(PAUSE), flags)
        val percent = if (state.third > 0) (state.second * 100 / state.third).toInt().coerceIn(0, 100) else 0
        return NotificationCompat.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(if (zh) "画廊上传" else "Gallery uploads")
            .setContentText(if (percent == 100) { if (zh) "等待站点确认" else "Waiting for site confirmation" }
                else if (zh) "已发送 $percent%" else "$percent% sent")
            .setContentIntent(open).setProgress(100, percent, state.third == 0L)
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(android.R.drawable.ic_media_pause, if (zh) "暂停" else "Pause", pause).build()
    }
}
