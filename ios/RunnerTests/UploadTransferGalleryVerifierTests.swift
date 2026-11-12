import XCTest
@testable import UploadValidationHost

final class UploadTransferGalleryVerifierTests: XCTestCase {
  private let verifier = UploadGalleryReceiptVerifier()

  private func fixture() throws -> String {
    let bundle = Bundle(for: UploadTransferGalleryVerifierTests.self)
    let url = try XCTUnwrap(bundle.url(forResource: "uploaded", withExtension: "html"))
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func receipt() -> UploadTransferReceipt {
    var value = UploadTransferReceipt(receiptId: "r", taskId: "t", itemId: "i", accountId: "101", epoch: "epoch",
      state: "awaitingVerification", status: 200, finalUrl: "https://upld.e-hentai.org/managegallery?ulgid=12345", responsePath: nil, reason: nil)
    value.length = 100; value.sentBytes = 100
    value.verification = UploadGalleryVerification(galleryId: "12345", expectedNames: (1...8).map { String(format: "%04d.png", $0) }, priorFileIndexes: [])
    return value
  }

  func testObservedResponseRequiresNewServerFileIdentifiers() throws {
    let html = try fixture()
    XCTAssertTrue(verifier.confirms(receipt(), html: html))
    var old = receipt(); old.verification?.priorFileIndexes = [279367042]
    XCTAssertFalse(verifier.confirms(old, html: html))
    var pageNumbersAreNotServerIds = receipt(); pageNumbersAreNotServerIds.verification?.priorFileIndexes = [1, 2, 3]
    XCTAssertTrue(verifier.confirms(pageNumbersAreNotServerIds, html: html))
  }

  func testPartialBodyAndUncertainCompletionNeverAutoConfirm() throws {
    let html = try fixture()
    var partial = receipt(); partial.sentBytes = 99
    XCTAssertFalse(verifier.confirms(partial, html: html))
    var unknown = receipt(); unknown.state = "uncertain"
    XCTAssertFalse(verifier.confirms(unknown, html: html))
    var absent = receipt(); absent.verification = nil
    XCTAssertFalse(verifier.confirms(absent, html: html))
  }

  func testWrongAccountWrongGalleryAndOffsiteRedirectRemainPending() throws {
    let html = try fixture()
    var account = receipt(); account.accountId = "102"
    XCTAssertFalse(verifier.confirms(account, html: html))
    var url = receipt(); url.finalUrl = "https://other.example/managegallery?ulgid=12345"
    XCTAssertFalse(verifier.confirms(url, html: html))
    var gallery = receipt(); gallery.verification?.galleryId = "54321"
    XCTAssertFalse(verifier.confirms(gallery, html: html))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "view_image_init(12345,1,", with: "view_image_init(54321,1,")))
  }

  func testDuplicateNamesMissingImagesAndChangedCellAssociationsRemainPending() throws {
    let html = try fixture()
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "0008.png", with: "0007.png")))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "thumb_1", with: "thumb_9")))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "alt=\"0001.png\"", with: "alt=\"different.png\"")))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "279367044", with: "279367042")))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "</script>", with: "")))
  }

  func testLoginErrorsAndMarkupInRawDescriptionsCannotSpoofConfirmation() throws {
    let html = try fixture()
    XCTAssertFalse(verifier.confirms(receipt(), html: html + "<input type=\"password\">"))
    XCTAssertFalse(verifier.confirms(receipt(), html: html + "<p class=\"e\">Upload failed</p>"))
    XCTAssertFalse(verifier.confirms(receipt(), html: "<textarea>" + html + "</textarea>"))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "var apiuid = 101;", with: "/* var apiuid = 101; */")))
  }

  func testConflictingIdentityAndInertMarkupCannotConfirm() throws {
    let html = try fixture()
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "var apiuid = 101;", with: "var apiuid = 101; var apiuid = 102;")))
    XCTAssertFalse(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "var apiuid = 101;", with: "var apiuid = 101; apiuid = 102;")))
    XCTAssertTrue(verifier.confirms(receipt(), html: html.replacingOccurrences(of: "var apiuid = 101;", with: "var fake = 'var apiuid = 999;'; /*var apiuid = 888;*/ var apiuid = 101;")))
    XCTAssertFalse(verifier.confirms(receipt(), html: "<template>" + html + "</template>"))
    XCTAssertFalse(verifier.confirms(receipt(), html: "<noscript>" + html + "</noscript>"))
    XCTAssertFalse(verifier.confirms(receipt(), html: html + String(repeating: "<b></b>", count: 40_001)))
  }

  func testSanitizationRemovesCredentialsAndSignedLinksButKeepsImageEvidence() throws {
    let raw = try fixture() + """
      <script>var privateToken = "test-only-token";</script>
      <input type="hidden" name="private-token" value="test-only-hidden-value">
      <a href="https://example.invalid/?signature=test-only-signature" onclick="secretAction()">private-link-text</a>
      <img src="https://example.invalid/test-only-image-token" onerror="secretAction()">
      """
    let result = verifier.sanitize(receipt(), html: raw)
    XCTAssertTrue(result.originalVerified)
    XCTAssertTrue(verifier.confirms(receipt(), html: result.html))
    for secret in ["fixture-api-key", "test-only-token", "test-only-hidden-value", "test-only-signature",
                   "test-only-image-token", "secretAction", "private-link-text", " src=", " href="] {
      XCTAssertFalse(result.html.contains(secret), secret)
    }
    XCTAssertTrue(result.html.contains("var apiuid = 101;"))
    XCTAssertTrue(result.html.contains("local-receipt-key"))
    for field in ["gname_en", "category", "ulcomment", "do_save"] {
      XCTAssertTrue(result.html.contains("name=\"\(field)\""))
    }
    XCTAssertTrue(result.html.contains("id=\"pagesel_1\""))
    XCTAssertTrue(result.html.contains("name=\"pagesel_1\""))
    XCTAssertTrue(result.html.contains("view_image_init(12345,1,279367042)"))
  }

  func testSanitizationOnlyExtractsLexicalIdentityFromRealScripts() throws {
    let html = try fixture()
    let decorated = html.replacingOccurrences(of: "var apiuid = 101;", with:
      "var fake = 'var apiuid = 999;'; /* var apiuid = 888; */ var apiuid = 101;") +
      "<!-- <script>var apiuid = 777;</script> --><textarea>var apiuid = 666;</textarea>"
    let result = verifier.sanitize(receipt(), html: decorated)
    XCTAssertTrue(result.originalVerified)
    XCTAssertTrue(verifier.confirms(receipt(), html: result.html))
    for uid in ["999", "888", "777", "666"] {
      XCTAssertFalse(result.html.contains("var apiuid = \(uid);"))
    }
    let missing = html.replacingOccurrences(of: "var apiuid = 101;", with: "/* var apiuid = 101; */") +
      "<textarea><script>var apiuid = 101;</script></textarea>"
    let absent = verifier.sanitize(receipt(), html: missing)
    XCTAssertFalse(absent.originalVerified)
    XCTAssertFalse(verifier.confirms(receipt(), html: absent.html))
  }

  func testSanitizationCannotRepairAmbiguousOrInertOriginalResponses() throws {
    let html = try fixture()
    let invalid = [
      html.replacingOccurrences(of: "var apiuid = 101;", with: "var apiuid = 101; var apiuid = 102;"),
      html.replacingOccurrences(of: "var apiuid = 101;", with: "var apiuid = 101; apiuid = 102;"),
      html.replacingOccurrences(of: "</script>", with: ""),
      html.replacingOccurrences(of: "0008.png", with: "0007.png"),
      html + "<input type=\"password\">",
      html + "<p class=\"e\">test-only-error-details</p>",
      "<template>" + html + "</template>",
      "<noscript>" + html + "</noscript>",
      "<textarea>" + html + "</textarea>",
    ]
    for raw in invalid {
      XCTAssertFalse(verifier.confirms(receipt(), html: raw))
      let result = verifier.sanitize(receipt(), html: raw)
      XCTAssertFalse(result.originalVerified)
      XCTAssertFalse(verifier.confirms(receipt(), html: result.html))
      XCTAssertFalse(result.html.contains("fixture-api-key"))
      XCTAssertFalse(result.html.contains("test-only-error-details"))
    }
  }

  func testUnicodeTitleAndMixedCaseScriptCloseKeepOriginalOffsets() throws {
    let html = try fixture().replacingOccurrences(of: "<body>", with: "<body><title>İ 中文 😀</title>")
      .replacingOccurrences(of: "</script>", with: "</ScRiPt>")
    XCTAssertTrue(html.contains("<title>İ 中文 😀</title>"))
    XCTAssertTrue(verifier.confirms(receipt(), html: html))
    let result = verifier.sanitize(receipt(), html: html)
    XCTAssertTrue(result.originalVerified)
    XCTAssertTrue(verifier.confirms(receipt(), html: result.html))
    XCTAssertFalse(result.html.contains("fixture-api-key"))
  }

  func testPersistedOriginalFailureAndMissingPrivacyVersionCannotAutoConfirm() throws {
    let result = verifier.sanitize(receipt(), html: try fixture())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("receipt.html")
    try result.html.write(to: url, atomically: true, encoding: .utf8)
    var checked = receipt()
    checked.originalVerified = false; checked.responsePrivacyVersion = 1
    XCTAssertFalse(verifier.confirms(checked, html: result.html))
    XCTAssertFalse(verifier.sanitize(checked, html: try fixture()).originalVerified)
    func confirmed(_ value: UploadTransferReceipt) -> Bool {
      var accepted = false
      verifier.verify(value, responseURL: url) { outcome in
        if case .confirmed = outcome { accepted = true }
      }
      return accepted
    }
    XCTAssertFalse(confirmed(checked))
    checked.originalVerified = true; checked.responsePrivacyVersion = nil
    XCTAssertFalse(confirmed(checked))
    checked.responsePrivacyVersion = 1
    XCTAssertTrue(confirmed(checked))
  }

  func testReceiptURLNeverPersistsUnexpectedRedirectQueryCredentials() {
    let valid = "https://upld.e-hentai.org/managegallery?ulgid=12345"
    XCTAssertEqual(UploadGalleryReceiptVerifier.safeReceiptURL(valid), valid)
    for url in [valid + "&token=test-only-secret", valid + "&act=delete", valid + "&ulgid=54321",
                valid + "#test-only-secret", "https://other.example/?token=test-only-secret",
                "https://upld.e-hentai.org/login.php?token=test-only-secret",
                "http://upld.e-hentai.org/managegallery?ulgid=12345"] {
      XCTAssertNil(UploadGalleryReceiptVerifier.safeReceiptURL(url))
    }
    XCTAssertNil(UploadGalleryReceiptVerifier.safeReceiptURL(nil))
  }

  func testReceiptRequiresOriginalEditorControlsButAllowsReadOnlyMirrors() throws {
    let html = try fixture()
    for field in ["gname_en", "category", "ulcomment", "do_save"] {
      let missing = html.replacingOccurrences(of: "name=\"\(field)\"", with: "name=\"missing-field\"")
      XCTAssertFalse(verifier.confirms(receipt(), html: missing))
      let result = verifier.sanitize(receipt(), html: missing)
      XCTAssertFalse(result.originalVerified)
      XCTAssertFalse(verifier.confirms(receipt(), html: result.html))
    }
    let mirrored = html.replacingOccurrences(of: "<input name=\"do_save\"", with:
      "<input name=\"gname_en\" type=\"hidden\" value=\"test-only-mirror\"><input name=\"do_save\"")
      .replacingOccurrences(of: "id=\"gname_en\"", with: "id=\"gname_en\" readonly=\"readonly\"")
    XCTAssertTrue(verifier.confirms(receipt(), html: mirrored))
    let result = verifier.sanitize(receipt(), html: mirrored)
    XCTAssertTrue(result.originalVerified)
    XCTAssertTrue(verifier.confirms(receipt(), html: result.html))
    XCTAssertFalse(result.html.contains("test-only-mirror"))
  }

  func testPageSelectorsMustMatchCellsAndUniquePositionsButCanBeReordered() throws {
    let html = try fixture()
    let first = "<input id=\"pagesel_1\" name=\"pagesel_1\" readonly=\"readonly\" type=\"text\" value=\"1\"/>"
    let second = "<input id=\"pagesel_2\" name=\"pagesel_2\" readonly=\"readonly\" type=\"text\" value=\"2\"/>"
    XCTAssertTrue(html.contains(first)); XCTAssertTrue(html.contains(second))
    let invalid = [
      html.replacingOccurrences(of: first, with: ""),
      html.replacingOccurrences(of: first, with: first + first),
      html.replacingOccurrences(of: first, with: "<template>" + first + "</template>"),
      html.replacingOccurrences(of: "name=\"pagesel_1\"", with: "name=\"pagesel_2\""),
      html.replacingOccurrences(of: first, with: first.replacingOccurrences(of: "value=\"1\"", with: "value=\"0\"")),
      html.replacingOccurrences(of: first, with: first.replacingOccurrences(of: "value=\"1\"", with: "value=\"9\"")),
      html.replacingOccurrences(of: first, with: first.replacingOccurrences(of: "value=\"1\"", with: "value=\"2\"")),
    ]
    for raw in invalid {
      XCTAssertFalse(verifier.confirms(receipt(), html: raw))
      let result = verifier.sanitize(receipt(), html: raw)
      XCTAssertFalse(result.originalVerified)
      XCTAssertFalse(verifier.confirms(receipt(), html: result.html))
    }
    let reordered = html.replacingOccurrences(of: first, with: first.replacingOccurrences(of: "value=\"1\"", with: "value=\"2\""))
      .replacingOccurrences(of: second, with: second.replacingOccurrences(of: "value=\"2\"", with: "value=\"1\""))
    XCTAssertTrue(verifier.confirms(receipt(), html: reordered))
    let result = verifier.sanitize(receipt(), html: reordered)
    XCTAssertTrue(result.originalVerified)
    XCTAssertTrue(verifier.confirms(receipt(), html: result.html))
  }
}
