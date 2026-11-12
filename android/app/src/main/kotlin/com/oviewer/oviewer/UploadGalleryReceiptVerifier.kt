package com.oviewer.oviewer

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI

/** Public, non-secret expectation attached to the prepared batch. File indexes
 * are the THIRD view_image_init argument, never the cell/page number. */
internal data class UploadGalleryVerification(val galleryId: String,
    val expectedNames: List<String>, val priorFileIndexes: Set<Long>) {
    fun toJson(): JSONObject = JSONObject().put("galleryId", galleryId)
        .put("expectedNames", JSONArray(expectedNames)).put("priorFileIndexes", JSONArray(priorFileIndexes.toList()))
    companion object {
        fun from(value: JSONObject): UploadGalleryVerification {
            val gallery = value.getString("galleryId")
            if (!Regex("^[1-9][0-9]{0,17}$").matches(gallery)) throw UploadTransferFailure("invalid_verification")
            val names = value.getJSONArray("expectedNames").strings()
            if (names.size !in 1..2000 || names.distinct().size != names.size || names.any {
                    it.length > 255 || !Regex("^[A-Za-z0-9_-]+\\.(jpg|png|gif|webp)$").matches(it)
                }) throw UploadTransferFailure("invalid_verification")
            val ids = value.getJSONArray("priorFileIndexes")
            if (ids.length() > 2000) throw UploadTransferFailure("invalid_verification")
            val prior = (0 until ids.length()).map { index ->
                val raw = ids.get(index) as? Number ?: throw UploadTransferFailure("invalid_verification")
                val id = raw.toLong()
                if (id <= 0 || raw.toDouble() != id.toDouble()) throw UploadTransferFailure("invalid_verification")
                id
            }.toSet()
            return UploadGalleryVerification(gallery, names, prior)
        }
    }
}

/** Restricted parser for the observed upload response. It reads markup and
 * literal identity declarations; it never executes script or fetches images.
 * Structural changes, errors, duplicate matches and incomplete replies stop
 * the queue at awaitingVerification instead of claiming success. */
class UploadGalleryReceiptVerifier : UploadTransferReceiptVerifier {
    override fun verify(response: File?, receipt: Map<String, Any?>): Boolean = try {
        if (response == null || !response.isFile || response.length() !in 1..UploadTransferRuntime.RESPONSE_LIMIT.toLong()) false
        else verifyHtml(response.readText(Charsets.UTF_8), receipt)
    } catch (_: Exception) { false }

    internal fun verifyHtml(html: String, receipt: Map<String, Any?>): Boolean {
        try {
            if (receipt["originalVerified"] == false) return false
            if ((receipt["status"] as? Number)?.toLong() != 200L || receipt["state"] != "awaitingVerification") return false
            val sent = (receipt["sentBytes"] as? Number)?.toLong() ?: return false
            val length = (receipt["length"] as? Number)?.toLong() ?: return false
            if (length <= 0 || sent != length || html.length > UploadTransferRuntime.RESPONSE_LIMIT) return false
            val account = receipt["accountId"] as? String ?: return false
            if (!Regex("^[1-9][0-9]*$").matches(account)) return false
            val raw = receipt["verification"] as? Map<*, *> ?: return false
            val expected = UploadGalleryVerification.from(JSONObject(raw))
            val finalUri = galleryUri(receipt["finalUrl"] as? String ?: return false, expected.galleryId) ?: return false
            val document = UploadResponseDocument.parse(html) ?: return false
            val all = document.nodes
            if (all.any { node ->
                    node.tag in setOf("template", "noscript") && node.descendants().any {
                        it.attributes["id"] in setOf("uploadform", "reorderform") ||
                            it.attributes["id"]?.startsWith("cell_") == true
                    }
                }) return false
            val significantIds = all.mapNotNull { it.attributes["id"] }.filter {
                it == "uploadform" || it == "reorderform" || it.startsWith("cell_") || it.startsWith("thumb_")
            }
            if (significantIds.distinct().size != significantIds.size) return false
            if (all.any { it.tag == "input" && it.attributes["type"]?.lowercase() == "password" }) return false
            if (all.any {
                    (it.attributes["id"] in setOf("e", "error") || it.classes.any { value -> value in setOf("e", "error") }) &&
                        it.textContent().isNotBlank()
                }) return false
            val forms = all.filter { it.tag == "form" && it.attributes["id"] == "uploadform" }
            if (forms.size != 1) return false
            val form = forms.single()
            if (!form.closed || form.attributes["method"]?.lowercase() != "post" ||
                form.attributes["enctype"]?.lowercase() != "multipart/form-data") return false
            val action = form.attributes["action"] ?: return false
            if (galleryUri(finalUri.resolve(action).toString(), expected.galleryId) == null) return false
            for (name in listOf("gname_en", "category", "ulcomment", "do_save")) {
                if (form.descendants().none { it.tag in setOf("input", "select", "textarea") && it.attributes["name"] == name }) return false
            }
            val declarations = all.filter { it.tag == "script" && !it.attributes.containsKey("src") && !it.inert() }
                .flatMap { Regex("(?m)(?:^|(?<=;))\\s*var\\s+apiuid\\s*=\\s*([0-9]+)\\s*;")
                    .findAll(maskUploadScriptStrings(it.text.toString())).toList() }
            if (declarations.size != 1 || declarations.single().groupValues[1] != account) return false
            val reorder = all.filter { it.tag == "form" && it.attributes["id"] == "reorderform" }
            if (reorder.size != 1 || !reorder.single().closed || reorder.single().attributes["method"]?.lowercase() != "post") return false
            val reorderAction = reorder.single().attributes["action"] ?: return false
            if (galleryUri(finalUri.resolve(reorderAction).toString(), expected.galleryId, true) == null) return false
            val cells = all.filter { it.attributes["id"]?.startsWith("cell_") == true }
            if (cells.isEmpty() || cells.size > 2000) return false
            val cellIds = mutableSetOf<String>()
            val positions = mutableSetOf<Int>()
            val imageIds = mutableMapOf<Long, Int>()
            val found = mutableMapOf<String, MutableList<Long>>()
            for (cell in cells) {
                val cellId = cell.attributes["id"] ?: return false
                val page = Regex("^cell_([1-9][0-9]*)$").matchEntire(cellId)?.groupValues?.get(1) ?: return false
                if (!cell.closed || !cellIds.add(cellId) || !cell.isDescendantOf(reorder.single())) return false
                val descendants = cell.descendants()
                val pageInputs = descendants.filter { it.tag == "input" && it.attributes["id"] == "pagesel_$page" }
                if (pageInputs.size != 1 || pageInputs.single().attributes["name"] != "pagesel_$page") return false
                val position = pageInputs.single().attributes["value"]?.toIntOrNull() ?: return false
                if (position !in 1..cells.size || !positions.add(position)) return false
                val names = descendants.filter { it.tag == "div" && "n" in it.classes }
                val thumbs = descendants.filter { it.tag == "img" && it.attributes["id"] == "thumb_$page" }
                if (names.size != 1 || thumbs.size != 1) return false
                val name = names.single().textContent().trim()
                val thumb = thumbs.single()
                if (thumb.attributes["alt"] != name || thumb.attributes["title"] != name) return false
                val match = Regex("^\\s*view_image_init\\(\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*\\)\\s*;?\\s*$")
                    .matchEntire(thumb.attributes["onclick"] ?: return false) ?: return false
                if (match.groupValues[1] != expected.galleryId || match.groupValues[2] != page) return false
                val serverFileIndex = match.groupValues[3].toLongOrNull()?.takeIf { it > 0 } ?: return false
                imageIds[serverFileIndex] = (imageIds[serverFileIndex] ?: 0) + 1
                found.getOrPut(name) { mutableListOf() }.add(serverFileIndex)
            }
            for (name in expected.expectedNames) {
                val matched = found[name] ?: return false
                if (matched.size != 1 || matched.single() in expected.priorFileIndexes || imageIds[matched.single()] != 1) return false
            }
            return true
        } catch (_: Exception) { return false }
    }

    private fun galleryUri(value: String, galleryId: String, allowReorderFragment: Boolean = false): URI? {
        val uri = URI(value)
        return uri.takeIf { it.scheme == "https" && it.host == "upld.e-hentai.org" &&
            it.userInfo == null && (it.port == -1 || it.port == 443) &&
            (it.fragment == null || (allowReorderFragment && it.fragment == "reorder")) &&
            it.path == "/managegallery" && it.rawQuery == "ulgid=$galleryId" }
    }
}

private class UploadResponseNode(val tag: String, val attributes: Map<String, String>, val parent: UploadResponseNode?,
    val sourceStart: Int = 0, val openEnd: Int = 0) {
    var sourceEnd = openEnd
    val text = StringBuilder()
    val children = mutableListOf<UploadResponseNode>()
    var closed = false
    val classes = attributes["class"].orEmpty().split(Regex("\\s+")).filter { it.isNotEmpty() }
    fun textContent(): String = decodeUploadEntities(text.toString()) + children.joinToString("") { it.textContent() }
    fun descendants(): List<UploadResponseNode> = children.flatMap { listOf(it) + it.descendants() }
    fun isDescendantOf(ancestor: UploadResponseNode): Boolean {
        var node = parent
        while (node != null) { if (node === ancestor) return true; node = node.parent }
        return false
    }
    fun inert(): Boolean {
        var node = parent
        while (node != null) {
            if (node.tag in setOf("template", "noscript")) return true
            node = node.parent
        }
        return false
    }
}

/** Small bounded HTML tokenizer for the attributes/structure above. Raw script,
 * style and textarea are treated as text, so fake markup inside them cannot
 * produce a gallery cell. Attribute quotes and comments are honored. */
private class UploadResponseDocument(val nodes: List<UploadResponseNode>) {
    companion object {
        fun parse(source: String): UploadResponseDocument? {
            val root = UploadResponseNode("#document", emptyMap(), null)
            val nodes = mutableListOf<UploadResponseNode>()
            val stack = mutableListOf(root)
            var index = 0
            while (index < source.length) {
                if (nodes.size > 40000 || stack.size > 128) return null
                if (source[index] != '<') {
                    val end = source.indexOf('<', index).takeIf { it >= 0 } ?: source.length
                    stack.last().text.append(source, index, end); index = end; continue
                }
                val tagStart = index
                if (source.startsWith("<!--", index)) {
                    val end = source.indexOf("-->", index + 4); if (end < 0) return null
                    index = end + 3; continue
                }
                var end = index + 1
                var quote: Char? = null
                while (end < source.length) {
                    val c = source[end]
                    if (quote == null && (c == '\'' || c == '"')) quote = c
                    else if (quote == c) quote = null
                    else if (quote == null && c == '>') break
                    end++
                }
                if (end >= source.length) return null
                val inside = source.substring(index + 1, end).trim()
                index = end + 1
                if (inside.startsWith('!') || inside.startsWith('?')) continue
                if (inside.startsWith('/')) {
                    val tag = inside.substring(1).trim().lowercase()
                    val open = stack.indexOfLast { it.tag == tag }
                    if (open > 0) {
                        stack[open].closed = true
                        while (stack.size > open) stack.removeAt(stack.lastIndex)
                    }
                    continue
                }
                val tagMatch = Regex("^[A-Za-z][A-Za-z0-9:-]*").find(inside) ?: return null
                val tag = tagMatch.value.lowercase()
                val attrs = attributes(inside.substring(tagMatch.value.length).removeSuffix("/").trim()) ?: return null
                val node = UploadResponseNode(tag, attrs, stack.last(), tagStart, index)
                stack.last().children.add(node); nodes.add(node)
                if (tag in setOf("script", "style", "textarea")) {
                    val close = Regex("</$tag(?=[\\s>])", RegexOption.IGNORE_CASE)
                        .find(source, index)?.range?.first ?: return null
                    node.text.append(source, index, close)
                    val closeEnd = source.indexOf('>', close); if (closeEnd < 0) return null
                    node.closed = true
                    node.sourceEnd = closeEnd + 1
                    index = closeEnd + 1; continue
                }
                if (!inside.endsWith('/') && tag !in setOf("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr")) stack.add(node)
                else node.closed = true
            }
            return UploadResponseDocument(nodes)
        }
        private fun attributes(text: String): Map<String, String>? {
            val result = linkedMapOf<String, String>()
            var index = 0
            while (index < text.length) {
                while (index < text.length && text[index].isWhitespace()) index++
                if (index == text.length) break
                val name = Regex("^[A-Za-z_:][A-Za-z0-9_:.-]*").find(text.substring(index))?.value ?: return null
                index += name.length
                while (index < text.length && text[index].isWhitespace()) index++
                var value = ""
                if (index < text.length && text[index] == '=') {
                    index++
                    while (index < text.length && text[index].isWhitespace()) index++
                    if (index == text.length) return null
                    val quote = text[index]
                    if (quote == '\'' || quote == '"') {
                        val end = text.indexOf(quote, index + 1); if (end < 0) return null
                        value = text.substring(index + 1, end); index = end + 1
                    } else {
                        val start = index
                        while (index < text.length && !text[index].isWhitespace()) index++
                        value = text.substring(start, index)
                    }
                }
                if (result.put(name.lowercase(), decodeUploadEntities(value)) != null) return null
            }
            return result
        }
    }
}

/** A receipt is evidence, not a reusable authenticated page. Raw replies stay
 * within the bounded receive buffer and are never written to temporary files. */
internal object UploadReceiptSanitizer {
    const val LOCAL_KEY = "local-receipt-key"
    private const val unavailable = "<html><body>Receipt could not be safely retained.</body></html><script>var apikey = \"local-receipt-key\";</script>"
    fun redact(source: String): String {
        val document = UploadResponseDocument.parse(source) ?: return unavailable
        data class Replacement(val start: Int, val end: Int, val text: String)
        val changes = mutableListOf<Replacement>()
        val secrets = mutableSetOf<String>()
        for (node in document.nodes) {
            if (node.tag == "script") {
                Regex("\\b(?:apikey|api_key)\\s*=\\s*(['\"])([^'\"]+)\\1", RegexOption.IGNORE_CASE)
                    .findAll(node.text).forEach { secrets.add(it.groupValues[2]) }
                val declarations = if (node.attributes.containsKey("src") || node.inert()) emptyList()
                    else Regex("(?m)(?:^|(?<=;))\\s*var\\s+apiuid\\s*=\\s*([0-9]+)\\s*;")
                        .findAll(maskUploadScriptStrings(node.text.toString())).map { it.groupValues[1] }.toList()
                val text = if (declarations.isEmpty()) "" else
                    declarations.joinToString("\n", "<script>", "</script>") { "var apiuid = $it;" }
                changes.add(Replacement(node.sourceStart, node.sourceEnd, text))
                continue
            }
            if (node.tag == "style") {
                changes.add(Replacement(node.sourceStart, node.sourceEnd, "<style></style>")); continue
            }
            val attrs = node.attributes.toMutableMap()
            attrs.remove("href"); attrs.remove("src"); attrs.remove("style")
            for (key in attrs.keys.toList()) {
                if (key.startsWith("on") && !(node.tag == "img" && key == "onclick" &&
                        Regex("^\\s*view_image_init\\(\\s*[0-9]+\\s*,\\s*[0-9]+\\s*,\\s*[0-9]+\\s*\\)\\s*;?\\s*$").matches(attrs[key].orEmpty()))) attrs.remove(key)
            }
            if (node.tag == "input" && (attrs["type"]?.lowercase() in setOf("hidden", "password") ||
                    Regex("token|password|secret|apikey|session|auth", RegexOption.IGNORE_CASE).containsMatchIn(attrs["name"].orEmpty()))) {
                attrs["value"] = "local-receipt-value"
            }
            if (node.tag == "meta" && Regex("token|password|secret|apikey|session|auth", RegexOption.IGNORE_CASE)
                    .containsMatchIn(attrs["name"].orEmpty())) attrs["content"] = "local-receipt-value"
            if (attrs != node.attributes) {
                val selfClosing = source.substring(node.sourceStart, node.openEnd).endsWith("/>")
                val text = "<${node.tag}" + attrs.entries.joinToString("") { (name, value) -> " $name=\"${escape(value)}\"" } + if (selfClosing) "/>" else ">"
                changes.add(Replacement(node.sourceStart, node.openEnd, text))
            }
        }
        var result = source
        for (change in changes.sortedByDescending { it.start }) {
            result = result.replaceRange(change.start, change.end, change.text)
        }
        result = Regex("<!--[\\s\\S]*?-->").replace(result, "")
        for (secret in secrets.filter { it.length >= 8 && it != LOCAL_KEY }) result = result.replace(secret, LOCAL_KEY)
        result += "<script>var apikey = \"$LOCAL_KEY\";</script>"
        return if (result.toByteArray(Charsets.UTF_8).size <= UploadTransferRuntime.RESPONSE_LIMIT) result else unavailable
    }
    private fun escape(value: String) = value.replace("&", "&amp;").replace("\"", "&quot;")
        .replace("<", "&lt;").replace(">", "&gt;")
}

private fun decodeUploadEntities(value: String): String = Regex("&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);").replace(value) { match ->
    when (val entity = match.groupValues[1]) {
        "amp" -> "&"; "quot" -> "\""; "apos" -> "'"; "lt" -> "<"; "gt" -> ">"; "nbsp" -> "\u00a0"
        else -> {
            val code = if (entity.startsWith("#x")) entity.substring(2).toIntOrNull(16) else entity.substring(1).toIntOrNull()
            if (code == null || !Character.isValidCodePoint(code) || code in 0xd800..0xdfff) match.value else String(Character.toChars(code))
        }
    }
}

/** Ignore comments and quoted/template text when locating the literal uid.
 * This is recognition, not evaluation: expressions never count as identity. */
private fun maskUploadScriptStrings(source: String): String {
    val chars = source.toCharArray()
    var index = 0
    while (index < chars.size) {
        val current = source[index]
        if (current == '\'' || current == '"' || current == '`') {
            val quote = current; chars[index++] = ' '
            while (index < chars.size) {
                val c = source[index]; chars[index++] = if (c == '\n' || c == '\r') c else ' '
                if (c == '\\' && index < chars.size) { chars[index++] = ' '; continue }
                if (c == quote) break
            }
        } else if (source.startsWith("//", index)) {
            while (index < chars.size && source[index] != '\n') chars[index++] = ' '
        } else if (source.startsWith("/*", index)) {
            val end = source.indexOf("*/", index + 2).let { if (it < 0) chars.size else it + 2 }
            while (index < end) { if (chars[index] != '\n' && chars[index] != '\r') chars[index] = ' '; index++ }
        } else index++
    }
    return String(chars)
}
