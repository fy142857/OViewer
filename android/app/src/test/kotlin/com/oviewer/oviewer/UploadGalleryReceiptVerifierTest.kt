package com.oviewer.oviewer

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 28, 35])
class UploadGalleryReceiptVerifierTest {
    private val verifier = UploadGalleryReceiptVerifier()
    private val names = (1..8).map { it.toString().padStart(4, '0') + ".png" }
    private fun fixture(): String {
        val candidates = listOf(File("../../test/fixtures/uploads/uploaded.html"),
            File("../test/fixtures/uploads/uploaded.html"), File("test/fixtures/uploads/uploaded.html"))
        return candidates.firstOrNull { it.isFile }?.readText() ?: error("Missing actual sanitized upload fixture")
    }
    private fun receipt(names: List<String> = this.names, prior: List<Long> = emptyList()): MutableMap<String, Any?> = mutableMapOf(
        "status" to 200, "state" to "awaitingVerification", "sentBytes" to 1000L, "length" to 1000L,
        "accountId" to "101", "finalUrl" to "https://upld.e-hentai.org/managegallery?ulgid=12345",
        "verification" to mapOf("galleryId" to "12345", "expectedNames" to names, "priorFileIndexes" to prior))

    @Test fun confirmsActualResponseWithFreshServerIdsAndExactGalleryIdentity() {
        assertTrue(verifier.verifyHtml(fixture(), receipt()))
        assertTrue(verifier.verifyHtml(fixture(), receipt(names.take(3))))
        assertTrue(verifier.verifyHtml(fixture(), receipt(prior = listOf(1L, 2L, 3L))))
        // The third onclick parameter is the server file ID, not the second
        // page number; the prior cell/page indexes above do not block it.
        assertFalse(verifier.verifyHtml(fixture(), receipt(prior = listOf(279367042L))))
    }
    @Test fun sanitizedReceiptsKeepProofButNeverRetainApiKeysOrProgressTokens() {
        val original = fixture().replace("fixture-api-key", "private-api-secret-123456")
            .replace("fixture-progress", "private-progress-secret-123456")
            .replace("Fixture upload verification", "İstanbul gallery")
        assertTrue(verifier.verifyHtml(original, receipt()))
        val sanitized = UploadReceiptSanitizer.redact(original)
        assertFalse(sanitized.contains("private-api-secret-123456"))
        assertFalse(sanitized.contains("private-progress-secret-123456"))
        assertTrue(sanitized.contains(UploadReceiptSanitizer.LOCAL_KEY))
        assertTrue(verifier.verifyHtml(sanitized, receipt()))
        assertEquals(sanitized, UploadReceiptSanitizer.redact(sanitized))
        assertFalse(verifier.verifyHtml(sanitized, receipt().apply { put("originalVerified", false) }))
    }
    @Test fun receiptRedactionDoesNotPromoteInertOrConflictingIdentity() {
        val invalid = fixture().replace("var apiuid = 101;", "var apiuid = 101; var apiuid = 102;")
        assertFalse(verifier.verifyHtml(invalid, receipt()))
        assertFalse(verifier.verifyHtml(UploadReceiptSanitizer.redact(invalid), receipt()))
        val inert = fixture().replace("var apiuid = 101;", "") + "<template><script>var apiuid = 101;</script></template>"
        assertFalse(verifier.verifyHtml(inert, receipt()))
        assertFalse(verifier.verifyHtml(UploadReceiptSanitizer.redact(inert), receipt()))
    }
    @Test fun missingDuplicateOrPreviouslyPresentFilesCannotBeConfirmed() {
        assertFalse(verifier.verifyHtml(fixture(), receipt(names + "0009.png")))
        assertFalse(verifier.verifyHtml(fixture(), receipt(listOf("0001.png", "0001.png"))))
        assertFalse(verifier.verifyHtml(fixture().replace("0002.png", "0001.png"), receipt(listOf("0001.png"))))
        assertFalse(verifier.verifyHtml(fixture().replace("279367044", "279367042"), receipt(names.take(1))))
    }
    @Test fun wrongAccountGalleryAndFinalOriginAreRejected() {
        val html = fixture()
        assertFalse(verifier.verifyHtml(html, receipt().apply { put("accountId", "102") }))
        for (url in listOf("https://upld.e-hentai.org/managegallery?ulgid=99999",
            "https://upld.e-hentai.org/managegallery?ulgid=12345&act=delete",
            "https://example.org/managegallery?ulgid=12345",
            "http://upld.e-hentai.org/managegallery?ulgid=12345")) {
            assertFalse(url, verifier.verifyHtml(html, receipt().apply { put("finalUrl", url) }))
        }
        assertFalse(verifier.verifyHtml(html.replace("view_image_init(12345,1,", "view_image_init(99999,1,"), receipt()))
        assertFalse(verifier.verifyHtml(html.replace("action=\"https://upld.e-hentai.org/managegallery?ulgid=12345\"",
            "action=\"https://upld.e-hentai.org/managegallery?ulgid=99999\""), receipt()))
    }
    @Test fun errorLoginAndIncompleteTransfersNeverPassDespiteVisibleImages() {
        val html = fixture()
        assertFalse(verifier.verifyHtml(html.replace("<body>", "<body><p class=\"e\">Upload failed</p>"), receipt()))
        assertFalse(verifier.verifyHtml(html.replace("<body>", "<body><input type=\"password\"/>"), receipt()))
        assertFalse(verifier.verifyHtml(html, receipt().apply { put("status", 403) }))
        assertFalse(verifier.verifyHtml(html, receipt().apply { put("sentBytes", 999L) }))
        assertFalse(verifier.verifyHtml(html, receipt().apply { put("state", "uncertain") }))
        assertFalse(verifier.verifyHtml(html, receipt().apply { remove("verification") }))
    }
    @Test fun ambiguousIdentifiersChangedMarkupAndTruncationFailClosed() {
        val html = fixture()
        assertFalse(verifier.verifyHtml(html.replace("id=\"thumb_2\"", "id=\"thumb_1\""), receipt()))
        assertFalse(verifier.verifyHtml(html.replace("view_image_init(12345,1,", "view_image_init(12345,2,"), receipt()))
        assertFalse(verifier.verifyHtml(html.replace("class=\"n\">0001.png", "class=\"renamed\">0001.png"), receipt()))
        assertFalse(verifier.verifyHtml(html.replace("var apiuid = 101;", "var apiuid = 101;\nvar apiuid = 101;"), receipt()))
        assertFalse(verifier.verifyHtml(html.replace("</form>", ""), receipt()))
    }
    @Test fun scriptCommentsAndTextareasCannotInventGalleryCells() {
        val html = fixture()
        val cell = "<div id=\"cell_99\"><div class=\"n\">0099.png</div><img id=\"thumb_99\" alt=\"0099.png\" title=\"0099.png\" onclick=\"view_image_init(12345,99,999999)\"/></div>"
        val additions = listOf("<!--$cell-->", "<script>var text = '$cell';</script>", "<textarea>$cell</textarea>")
        for (addition in additions) {
            assertFalse(verifier.verifyHtml(html.replace("</body>", "$addition</body>"), receipt(names + "0099.png")))
        }
        val fakeIdentity = html.replace("var apiuid = 101;", "var unrelated = 101; /* var apiuid = 101; */ var text = 'var apiuid = 101;';")
        assertFalse(verifier.verifyHtml(fakeIdentity, receipt()))
        assertFalse(verifier.verifyHtml(html.replace("var apiuid = 101;", "var apiuid = 101; var apiuid = 102;"), receipt()))
        assertFalse(verifier.verifyHtml("<template>" + html + "</template>", receipt()))
        assertFalse(verifier.verifyHtml("<noscript>" + html + "</noscript>", receipt()))
        assertFalse(verifier.verifyHtml(html.replace("ulgid=12345#reorder", "ulgid=99999#reorder"), receipt()))
    }
    @Test fun verificationContractValidatesTypesAndDoesNotPersistCredentials() {
        val input = JSONObject().put("galleryId", "12345").put("expectedNames", JSONArray(names))
            .put("priorFileIndexes", JSONArray(listOf(279367042L)))
        val model = UploadGalleryVerification.from(input)
        assertEquals(setOf(279367042L), model.priorFileIndexes)
        assertEquals(names, model.expectedNames)
        assertFalse(model.toJson().toString().contains("apikey"))
        try {
            UploadGalleryVerification.from(JSONObject(input.toString()).put("priorFileIndexes", JSONArray(listOf(1.5))))
            fail("Fractional identifiers must be rejected")
        } catch (_: UploadTransferFailure) { }
    }
}
