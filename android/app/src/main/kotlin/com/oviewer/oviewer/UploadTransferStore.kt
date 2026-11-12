package com.oviewer.oviewer

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.UUID

internal class UploadTransferFailure(val reason: String) : Exception(reason)

internal object UploadTransferPaths {
    fun file(root: File, relative: String): File {
        val normalized = relative.replace('\\', '/')
        val parts = normalized.split('/')
        if (normalized.isEmpty() || normalized.startsWith('/') || normalized.contains(':') ||
            normalized.any { it.code < 32 || it.code == 127 } || parts.any { it.isEmpty() || it == "." || it == ".." }) {
            throw UploadTransferFailure("unsafe_path")
        }
        val canonicalRoot = root.canonicalFile
        var next = canonicalRoot
        for (part in parts) {
            next = File(next, part)
            // Canonical-vs-absolute detects symlinks even on API 21, where NIO
            // Files.isSymbolicLink is unavailable.
            if (next.canonicalFile != next.absoluteFile) throw UploadTransferFailure("unsafe_path")
        }
        if (!next.canonicalPath.startsWith(canonicalRoot.path + File.separator)) throw UploadTransferFailure("unsafe_path")
        return next
    }
    fun id(value: String): String {
        if (!Regex("^[A-Za-z0-9_-]{1,128}$").matches(value)) throw UploadTransferFailure("invalid_identifier")
        return value
    }
}

internal data class UploadTransferRequest(val id: String, val url: URL, val bodyPath: String,
    val length: Long, val sha256: String, val headers: Map<String, String>, val wifiOnly: Boolean,
    val verification: UploadGalleryVerification?) {
    companion object {
        private val hosts = setOf("upld.e-hentai.org")
        fun target(value: String): URL {
            val uri = try { URI(value) } catch (_: Exception) { throw UploadTransferFailure("invalid_upload_url") }
            if (uri.scheme != "https" || uri.host !in hosts || uri.userInfo != null || uri.fragment != null ||
                (uri.port != -1 && uri.port != 443) || uri.path.isNullOrEmpty()) {
                throw UploadTransferFailure("invalid_upload_url")
            }
            return uri.toURL()
        }
        fun from(json: JSONObject): UploadTransferRequest {
            val id = UploadTransferPaths.id(json.getString("id"))
            val url = target(json.getString("url"))
            val path = json.getString("bodyPath")
            val length = json.getLong("length")
            val sha = json.getString("sha256").lowercase()
            if (length <= 0 || length > 128L * 1024 * 1024 || !Regex("^[a-f0-9]{64}$").matches(sha)) {
                throw UploadTransferFailure("invalid_prepared_body")
            }
            val objectHeaders = json.getJSONObject("headers")
            val headers = linkedMapOf<String, String>()
            for (key in objectHeaders.keys()) {
                if (key !in setOf("Content-Type", "User-Agent", "Cookie")) throw UploadTransferFailure("unsupported_header")
                val value = objectHeaders.getString(key)
                if (value.length > 16384 || value.any { it == '\r' || it == '\n' || it == '\u0000' }) {
                    throw UploadTransferFailure("invalid_header")
                }
                headers[key] = value
            }
            if (!headers.getOrDefault("Content-Type", "").startsWith("multipart/form-data; boundary=") ||
                headers.getOrDefault("Cookie", "").isEmpty()) throw UploadTransferFailure("invalid_upload_headers")
            val verification = if (json.has("verification") && !json.isNull("verification")) {
                UploadGalleryVerification.from(json.getJSONObject("verification"))
            } else null
            return UploadTransferRequest(id, url, path, length, sha, headers, json.optBoolean("wifiOnly", false), verification)
        }
        fun proxy(value: String?): Proxy? {
            if (value.isNullOrBlank()) return null // System route, including a system proxy/VPN.
            val uri = try { URI(if (value.contains("://")) value else "http://$value") }
                catch (_: Exception) { throw UploadTransferFailure("unsupported_proxy") }
            if (uri.scheme != "http" || uri.host.isNullOrBlank() || uri.port !in 1..65535 ||
                uri.userInfo != null || uri.rawQuery != null || uri.fragment != null ||
                (!uri.path.isNullOrEmpty() && uri.path != "/")) throw UploadTransferFailure("unsupported_proxy")
            return Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(uri.host, uri.port))
        }
    }
}

/** All callers serialize access with the runtime lock. The journal commits the
 * request phase before network I/O and its receipt before any Dart notification. */
internal class UploadTransferStore(val root: File, private val sealer: UploadTransferSealer) {
    val directory = UploadTransferPaths.file(root, "native/android").apply { mkdirs() }
    private val journal = UploadTransferJournal(File(directory, "journal.json"))
    var data: JSONObject = if (journal.exists()) {
        JSONObject(journal.read().toString(Charsets.UTF_8))
    } else JSONObject().put("version", 1).put("tasks", JSONArray()).put("receipts", JSONArray()).put("revoked", JSONArray())
    val tasks: JSONArray get() = data.getJSONArray("tasks")
    val receipts: JSONArray get() = data.getJSONArray("receipts")
    val account: String? get() = data.optString("accountId").takeIf { it.isNotEmpty() }
    val epoch: String? get() = data.optString("epoch").takeIf { it.isNotEmpty() }

    init {
        if (data.getInt("version") != 1) throw UploadTransferFailure("unsupported_journal")
        var changed = false
        for (task in tasks.objects()) {
            for (item in task.getJSONArray("items").objects()) {
                if (item.optString("state") == "sending") {
                    receipt(task, item, "uncertain", "process_interrupted")
                    changed = true
                }
            }
        }
        for (receipt in receipts.objects()) {
            if (receipt.optInt("responsePrivacyVersion") >= 1) continue
            val path = receipt.optString("responsePath")
            if (!Regex("^native/android/responses/[A-Za-z0-9-]+\\.response$").matches(path)) continue
            val response = UploadTransferPaths.file(root, path)
            if (!response.isFile) continue
            try {
                val original = if (response.length() <= UploadTransferRuntime.RESPONSE_LIMIT)
                    response.readText(Charsets.UTF_8) else null
                val sanitized = if (original != null)
                    UploadReceiptSanitizer.redact(original)
                    else "<html><body>Receipt exceeded the retention limit.</body></html>"
                if (original != sanitized) {
                    UploadTransferJournal(response).write(sanitized.toByteArray(Charsets.UTF_8))
                }
                receipt.put("originalVerified", original != null && UploadGalleryReceiptVerifier().verifyHtml(original, receipt.toMap()))
                    .put("responseSanitized", true).put("responsePrivacyVersion", 1)
                changed = true
            } catch (_: Exception) {
                // If a credential-bearing old response cannot be rewritten,
                // remove only this generated response, never a user's image.
                for (file in listOf(response, File(response.path + ".bak"), File(response.path + ".next"))) {
                    if (file.exists() && !file.delete()) throw UploadTransferFailure("receipt_cleanup_failed")
                }
                receipt.put("responsePath", JSONObject.NULL).put("reason", "receipt_removed_for_privacy")
                changed = true
            }
        }
        if (changed) save()
    }

    fun save() {
        journal.write(data.toString().toByteArray(Charsets.UTF_8))
    }
    fun task(id: String): JSONObject = tasks.objects().firstOrNull { it.getString("taskId") == id }
        ?: throw UploadTransferFailure("unknown_task")
    fun current(task: JSONObject) = task.getString("accountId") == account && task.getString("epoch") == epoch && epoch != null
    fun assertCurrent(task: JSONObject) { if (!current(task)) throw UploadTransferFailure("stale_session") }
    fun prepareSession(accountId: String, value: String) {
        UploadTransferPaths.id(accountId); UploadTransferPaths.id(value)
        if (data.getJSONArray("revoked").strings().contains(value)) throw UploadTransferFailure("revoked_session")
        if (epoch != null && (epoch != value || account != accountId)) invalidate(epoch!!)
        data.put("accountId", accountId).put("epoch", value); save()
    }
    fun invalidate(value: String) {
        // Revoke decryption independently of journal writes. If the disk fills
        // while logging out, a cold process must not replay old credentials.
        if (epoch == value) sealer.revoke()
        val revoked = data.getJSONArray("revoked")
        if (!revoked.strings().contains(value)) revoked.put(value)
        for (task in tasks.objects().filter { it.getString("epoch") == value }) {
            for (item in task.getJSONArray("items").objects()) {
                if (item.optString("state") == "sending") receipt(task, item, "uncertain", "session_invalidated")
                else if (item.optString("state") == "queued") item.put("state", "stopped")
                item.remove("sealed")
            }
            if (task.optString("state") != "completed") task.put("state", "stopped").put("reason", "session_invalidated")
        }
        if (epoch == value) { data.remove("epoch"); data.remove("accountId") }
        save()
    }
    fun enqueue(args: JSONObject) {
        if (args.getString("accountId") != account || args.getString("epoch") != epoch) throw UploadTransferFailure("stale_session")
        val id = UploadTransferPaths.id(args.getString("taskId"))
        if (tasks.objects().any { it.getString("taskId") == id }) throw UploadTransferFailure("task_exists")
        val requests = args.getJSONArray("items")
        if (requests.length() !in 1..2000) throw UploadTransferFailure("invalid_item_count")
        val proxy = args.optString("proxy").takeIf { it.isNotEmpty() && it != "null" }
        UploadTransferRequest.proxy(proxy)
        val ids = mutableSetOf<String>()
        val items = JSONArray()
        for (raw in requests.objects()) {
            val request = UploadTransferRequest.from(raw)
            if (!ids.add(request.id)) throw UploadTransferFailure("duplicate_item")
            val body = UploadTransferPaths.file(root, request.bodyPath)
            if (!body.isFile || body.length() != request.length) throw UploadTransferFailure("body_missing")
            val payload = JSONObject(raw.toString()).put("proxy", proxy ?: JSONObject.NULL)
            items.put(JSONObject().put("id", request.id).put("state", "queued").put("sentBytes", 0L)
                .put("length", request.length).put("sealed", sealer.seal(payload.toString()))
                .put("verification", request.verification?.toJson() ?: JSONObject.NULL))
        }
        val now = System.currentTimeMillis()
        tasks.put(JSONObject().put("taskId", id).put("accountId", account).put("epoch", epoch)
            .put("state", "queued").put("reason", JSONObject.NULL).put("language", args.optString("language", "zh"))
            .put("createdAt", now).put("updatedAt", now).put("items", items))
        save()
    }
    fun request(item: JSONObject): Pair<UploadTransferRequest, Proxy?> {
        val sealed = item.optString("sealed").takeIf { it.isNotEmpty() } ?: throw UploadTransferFailure("credentials_cleared")
        val json = try { JSONObject(sealer.open(sealed)) } catch (_: Exception) { throw UploadTransferFailure("credentials_unavailable") }
        return UploadTransferRequest.from(json) to UploadTransferRequest.proxy(json.optString("proxy").takeIf { it.isNotEmpty() && it != "null" })
    }
    fun receipt(task: JSONObject, item: JSONObject, state: String, reason: String? = null,
        status: Int? = null, finalUrl: String? = null, responsePath: String? = null): JSONObject {
        val id = UUID.randomUUID().toString()
        val value = JSONObject().put("receiptId", id).put("taskId", task.getString("taskId"))
            .put("itemId", item.getString("id")).put("accountId", task.getString("accountId"))
            .put("epoch", task.getString("epoch")).put("state", state).put("reason", reason ?: JSONObject.NULL)
            .put("status", status ?: JSONObject.NULL).put("finalUrl", finalUrl ?: JSONObject.NULL)
            .put("responsePath", responsePath ?: JSONObject.NULL).put("acknowledged", false)
            .put("sentBytes", item.optLong("sentBytes")).put("length", item.getLong("length"))
            .put("verification", item.optJSONObject("verification") ?: JSONObject.NULL)
            .put("createdAt", System.currentTimeMillis())
        receipts.put(value)
        item.put("state", state).put("receiptId", id)
        task.put("state", state).put("reason", reason ?: JSONObject.NULL).put("updatedAt", System.currentTimeMillis())
        return value
    }
    fun acknowledge(receiptId: String, outcome: String) {
        if (outcome !in setOf("confirmed", "retry", "stop")) throw UploadTransferFailure("invalid_outcome")
        val receipt = receipts.objects().firstOrNull { it.getString("receiptId") == receiptId }
            ?: throw UploadTransferFailure("unknown_receipt")
        if (receipt.getString("accountId") != account) throw UploadTransferFailure("stale_session")
        if (receipt.optBoolean("acknowledged")) {
            if (receipt.optString("outcome") != outcome) throw UploadTransferFailure("receipt_already_resolved")
            return
        }
        val task = task(receipt.getString("taskId"))
        val item = task.getJSONArray("items").objects().first { it.getString("id") == receipt.getString("itemId") }
        if (outcome == "retry") {
            assertCurrent(task)
            if (!item.has("sealed")) throw UploadTransferFailure("credentials_cleared")
            item.put("state", "queued").put("sentBytes", 0)
            task.put("state", "paused").put("reason", "retry_ready")
        } else if (outcome == "confirmed") {
            item.put("state", "confirmed").remove("sealed")
            val finished = task.getJSONArray("items").objects().all { it.optString("state") == "confirmed" }
            task.put("state", if (finished) "completed" else if (current(task)) "queued" else "stopped")
                .put("reason", if (finished) "files_confirmed" else JSONObject.NULL)
        } else {
            for (other in task.getJSONArray("items").objects()) {
                if (other.optString("state") != "confirmed") other.put("state", "stopped")
                other.remove("sealed")
            }
            task.put("state", "stopped").put("reason", "verification_stopped")
        }
        receipt.put("acknowledged", true).put("outcome", outcome)
        task.put("updatedAt", System.currentTimeMillis()); save()
    }
    fun snapshot(): Map<String, Any?> {
        val visibleTasks = tasks.objects().filter { it.getString("accountId") == account }.map { task ->
            task.toMap().filterKeys { it != "language" }.toMutableMap().apply {
                this["items"] = task.getJSONArray("items").objects().map { it.toMap().filterKeys { key -> key != "sealed" } }
            }
        }
        return mapOf("tasks" to visibleTasks, "receipts" to receipts.objects().filter { it.getString("accountId") == account }.map { it.toMap() })
    }
}

/** Android's AtomicFile can silently log a failed rename. Upload requests need
 * an observable durable commit before sending, so every rename is checked.
 * A backup bridges the replacement gap on filesystems that cannot overwrite
 * an existing path by rename (also exercised by host-side Windows tests). */
internal class UploadTransferJournal(private val file: File) {
    private val backup = File(file.path + ".bak")
    private val next = File(file.path + ".next")
    fun exists() = file.exists() || backup.exists()
    fun read(): ByteArray {
        val source = if (file.exists()) file else backup
        if (source.length() > 16 * 1024 * 1024) throw UploadTransferFailure("journal_too_large")
        return source.readBytes()
    }
    fun write(bytes: ByteArray) {
        if (bytes.size > 16 * 1024 * 1024) throw UploadTransferFailure("journal_too_large")
        file.parentFile!!.mkdirs()
        next.outputStream().use { it.write(bytes); it.fd.sync() }
        if (file.exists()) {
            if (backup.exists() && !backup.delete()) throw UploadTransferFailure("journal_commit_failed")
            if (!file.renameTo(backup)) throw UploadTransferFailure("journal_commit_failed")
        }
        if (!next.renameTo(file)) {
            if (!file.exists()) backup.renameTo(file)
            throw UploadTransferFailure("journal_commit_failed")
        }
        if (!file.readBytes().contentEquals(bytes)) throw UploadTransferFailure("journal_commit_failed")
        // Retaining an old backup cannot cause a replay: a present main journal
        // always wins; corruption of that main journal fails closed.
        backup.delete()
    }
}

internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
internal fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        is JSONArray -> (0 until value.length()).map { i -> when (val v = value.get(i)) {
            JSONObject.NULL -> null; is JSONObject -> v.toMap(); else -> v
        } }
        else -> value
    }
}

internal fun uploadSha256(file: File, cancelled: () -> Boolean): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(65536)
        while (true) {
            if (cancelled()) throw UploadTransferFailure("paused")
            val count = input.read(buffer); if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
}
