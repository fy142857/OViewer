import XCTest
import Flutter
@testable import UploadValidationHost

final class UploadTransferTests: XCTestCase {
  private var directory: URL!
  private var store: UploadTransferStore!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = try UploadTransferStore(root: directory, logoutMarker: directory.appendingPathComponent("logout-pending"),
      credentialService: "com.oviewer.upload.tests." + UUID().uuidString)
  }
  override func tearDownWithError() throws {
    try store.removeAllCookies()
    try FileManager.default.removeItem(at: directory)
  }

  func testOnlyExactOfficialHttpsUploadEndpointIsAccepted() throws {
    XCTAssertEqual(try UploadTransferPolicy.endpoint("https://upld.e-hentai.org/manage").host, "upld.e-hentai.org")
    for value in ["http://upld.e-hentai.org/manage", "https://upld.e-hentai.org.evil.test/upload",
                  "https://user:pass@upld.e-hentai.org/manage", "https://upld.e-hentai.org:444/upload",
                  "https://exhentai.org/upload", "https://upld.e-hentai.org/manage#fragment"] {
      XCTAssertThrowsError(try UploadTransferPolicy.endpoint(value))
    }
  }

  func testUnsupportedProxyCannotSilentlyBecomeDirectConnection() throws {
    XCTAssertNil(try UploadTransferPolicy.proxy(nil))
    XCTAssertEqual(try UploadTransferPolicy.proxy("127.0.0.1:7890")?.normalized, "http://127.0.0.1:7890")
    for value in ["socks5://127.0.0.1:1080", "https://proxy.test:443", "http://user:pass@proxy.test:80", "proxy.test", "http://proxy.test:80/path"] {
      XCTAssertThrowsError(try UploadTransferPolicy.proxy(value))
    }
  }

  func testBodyLimitMatchesTheCrossPlatformMultipartContract() throws {
    XCTAssertEqual(UploadTransferPolicy.maxBodyBytes, 128 * 1024 * 1024)
    XCTAssertThrowsError(try store.copyBody("missing.multipart", expectedLength: UploadTransferPolicy.maxBodyBytes + 1,
      expectedHash: String(repeating: "0", count: 64), key: "too-large")) { error in
      XCTAssertEqual((error as? UploadTransferFailure)?.code, "invalid_body")
    }
  }

  func testCookieIdentityMustMatchTaskAndDuplicateAuthIsRejected() throws {
    let cookies = try UploadTransferPolicy.cookies("ipb_member_id=123; ipb_pass_hash=hash; igneous=ignored; uconfig=preference; PHPSESSID=fixture-session", accountId: "123")
    XCTAssertEqual(cookies, ["ipb_member_id": "123", "ipb_pass_hash": "hash", "uconfig": "preference", "PHPSESSID": "fixture-session"])
    XCTAssertThrowsError(try UploadTransferPolicy.cookies("ipb_member_id=456; ipb_pass_hash=hash", accountId: "123"))
    XCTAssertThrowsError(try UploadTransferPolicy.cookies("ipb_member_id=123; ipb_member_id=456; ipb_pass_hash=hash", accountId: "123"))
    XCTAssertThrowsError(try UploadTransferPolicy.cookies("ipb_member_id=123; ipb_pass_hash=hash\r\nInjected: header", accountId: "123"))
  }

  func testCopiedBodyIsVerifiedAndOwnedCopyDoesNotDependOnSource() throws {
    let input = Data("multipart-original".utf8)
    try input.write(to: directory.appendingPathComponent("source.multipart"))
    let hash = UploadTransferStore.digest("multipart-original")
    let relative = try store.copyBody("source.multipart", expectedLength: Int64(input.count), expectedHash: hash, key: "test-copy")
    try Data("source changed".utf8).write(to: directory.appendingPathComponent("source.multipart"))
    try store.verifyBody(relative, length: Int64(input.count), sha256: hash)
    XCTAssertEqual(try Data(contentsOf: store.file(relative)), input)
    store.removeOwned(relative)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.multipart").path))
  }

  func testSameLengthCorruptionAndTraversalAreRejected() throws {
    try Data("one".utf8).write(to: directory.appendingPathComponent("source.multipart"))
    let relative = try store.copyBody("source.multipart", expectedLength: 3, expectedHash: UploadTransferStore.digest("one"), key: "corrupt")
    try Data("two".utf8).write(to: store.file(relative))
    XCTAssertThrowsError(try store.verifyBody(relative, length: 3, sha256: UploadTransferStore.digest("one")))
    for path in ["../outside", "/outside", "native/../outside", "native//ios", "native\\ios"] {
      XCTAssertThrowsError(try store.file(path, mustExist: false))
    }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("secret".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: outside)
    XCTAssertThrowsError(try store.file("link"))
  }

  func testJournalKeepsRevocationAndSnapshotHidesRequestMaterialAndOtherAccounts() throws {
    var journal = UploadTransferJournal()
    journal.accountId = "123"; journal.epoch = "active-epoch"
    journal.revokedEpochs.insert("old-epoch")
    let item = UploadTransferItem(id: "i", url: "https://upld.e-hentai.org/upload", bodyPath: "body.multipart", length: 10,
      sha256: "hash", headers: ["Content-Type": "multipart/form-data; boundary=x"], credentialKey: "keychain-reference", wifiOnly: false)
    journal.tasks.append(UploadTransferTask(taskId: "visible", accountId: "123", epoch: "active-epoch", items: [item], proxy: nil, language: "en", createdAt: 1, updatedAt: 1))
    journal.tasks.append(UploadTransferTask(taskId: "hidden", accountId: "456", epoch: "other-epoch", items: [item], proxy: nil, language: "en", createdAt: 1, updatedAt: 1))
    try store.save(journal)
    let recovered = try store.load()
    XCTAssertTrue(recovered.revokedEpochs.contains("old-epoch"))
    let snapshot = recovered.snapshot
    XCTAssertEqual((snapshot["tasks"] as? [[String: Any]])?.count, 1)
    let json = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
    XCTAssertFalse(json.contains("bodyPath")); XCTAssertFalse(json.contains("headers")); XCTAssertFalse(json.contains("sha256"))
    XCTAssertFalse(json.contains("credentialKey")); XCTAssertFalse(json.contains("hidden"))
  }

  func testLogoutFenceOnlyChecksPresenceAndDoesNotConsumeMarker() throws {
    XCTAssertFalse(store.logoutIsPending())
    let sentinel = Data([0, 255, 0, 34])
    try sentinel.write(to: store.logoutMarker)
    XCTAssertTrue(store.logoutIsPending())
    XCTAssertEqual(try Data(contentsOf: store.logoutMarker), sentinel)
    try FileManager.default.removeItem(at: store.logoutMarker)
    XCTAssertFalse(store.logoutIsPending())
  }

  func testLogoutFenceRevokesColdJournalAndDeletingMarkerCannotReviveEpoch() throws {
    var journal = UploadTransferJournal()
    journal.accountId = "123"; journal.epoch = "old-epoch"
    try store.save(journal)
    try Data("pending".utf8).write(to: store.logoutMarker)
    let runtime = UploadTransferRuntime(storeFactory: { self.store }, restoreSystemTasks: false)
    let rejected = expectation(description: "prepare rejected while logout is pending")
    runtime.handle(FlutterMethodCall(methodName: "prepareSession", arguments: ["accountId": "123", "epoch": "fresh-epoch"])) { value in
      XCTAssertEqual((value as? FlutterError)?.code, "logout_pending")
      rejected.fulfill()
    }
    wait(for: [rejected], timeout: 5)
    let fenced = try store.load()
    XCTAssertNil(fenced.accountId); XCTAssertNil(fenced.epoch)
    XCTAssertTrue(fenced.revokedEpochs.contains("old-epoch"))
    try FileManager.default.removeItem(at: store.logoutMarker)
    let oldRejected = expectation(description: "persisted epoch remains revoked")
    runtime.handle(FlutterMethodCall(methodName: "prepareSession", arguments: ["accountId": "123", "epoch": "old-epoch"])) { value in
      XCTAssertEqual((value as? FlutterError)?.code, "session_revoked")
      oldRejected.fulfill()
    }
    wait(for: [oldRejected], timeout: 5)
    let fresh = expectation(description: "fresh session accepted after logout completes")
    runtime.handle(FlutterMethodCall(methodName: "prepareSession", arguments: ["accountId": "123", "epoch": "fresh-epoch"])) { value in
      XCTAssertNil(value)
      fresh.fulfill()
    }
    wait(for: [fresh], timeout: 5)
  }

  func testRevocationStillDeletesCredentialsWhenJournalCannotBeWritten() throws {
    var journal = UploadTransferJournal()
    journal.accountId = "123"; journal.epoch = "old-epoch"
    let item = UploadTransferItem(id: "i", url: "https://upld.e-hentai.org/managegallery?ulgid=12345",
      bodyPath: "native/ios/bodies/not-created.multipart", length: 10, sha256: "hash",
      headers: ["Content-Type": "multipart/form-data; boundary=x"], credentialKey: "test-credential", wifiOnly: false)
    journal.tasks.append(UploadTransferTask(taskId: "t", accountId: "123", epoch: "old-epoch", items: [item],
      proxy: nil, language: "en", createdAt: 1, updatedAt: 1))
    try store.putCookies(["ipb_member_id": "123", "ipb_pass_hash": "fixture"], key: item.credentialKey)
    try store.save(journal)
    let runtime = UploadTransferRuntime(storeFactory: { self.store }, restoreSystemTasks: false)
    let ready = expectation(description: "cold journal read")
    runtime.handle(FlutterMethodCall(methodName: "snapshot", arguments: nil)) { value in
      XCTAssertFalse(value is FlutterError); ready.fulfill()
    }
    wait(for: [ready], timeout: 5)
    let journalURL = store.directory.appendingPathComponent("journal.json")
    try FileManager.default.removeItem(at: journalURL)
    try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
    let revoked = expectation(description: "cleanup continues after persistence failure")
    runtime.handle(FlutterMethodCall(methodName: "invalidateSession", arguments: ["epoch": "old-epoch"])) { value in
      XCTAssertEqual((value as? FlutterError)?.code, "storage"); revoked.fulfill()
    }
    wait(for: [revoked], timeout: 5)
    XCTAssertThrowsError(try store.cookies(item.credentialKey)) { error in
      XCTAssertEqual((error as? UploadTransferFailure)?.code, "authentication_required")
    }
  }

  private func responseFixture() throws -> Data {
    let bundle = Bundle(for: UploadTransferTests.self)
    return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "uploaded", withExtension: "html")))
  }

  private func responseReceipt(_ identifier: String = "response-fixture") -> UploadTransferReceipt {
    var value = UploadTransferReceipt(receiptId: identifier, taskId: "task", itemId: "item", accountId: "101", epoch: "epoch",
      state: "awaitingVerification", status: 200, finalUrl: "https://upld.e-hentai.org/managegallery?ulgid=12345", responsePath: nil, reason: nil)
    value.length = 100; value.sentBytes = 100
    value.verification = UploadGalleryVerification(galleryId: "12345", expectedNames: (1...8).map { String(format: "%04d.png", $0) }, priorFileIndexes: [])
    return value
  }

  private func assertNoRawResponseSecret(in root: URL) throws {
    let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let url as URL in files {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("fixture-api-key".utf8)), url.lastPathComponent)
      }
    }
  }

  func testNewResponsePersistsOnlySanitizedHTMLAndVerificationProof() throws {
    var receipt = responseReceipt()
    try store.persistResponse(&receipt, raw: responseFixture())
    XCTAssertEqual(receipt.originalVerified, true)
    XCTAssertEqual(receipt.responsePrivacyVersion, 1)
    let path = try XCTUnwrap(receipt.responsePath)
    let html = try String(contentsOf: store.file(path), encoding: .utf8)
    XCTAssertTrue(html.contains("local-receipt-key"))
    XCTAssertTrue(html.contains("view_image_init(12345,1,279367042)"))
    XCTAssertTrue(UploadGalleryReceiptVerifier().confirms(receipt, html: html))
    var journal = UploadTransferJournal(); journal.receipts = [receipt]
    try store.save(journal)
    try assertNoRawResponseSecret(in: directory)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("responses").path), [receipt.receiptId + ".html"])
  }

  func testResponseBufferCancellationAndLimitNeverCreateRawOrTemporaryFiles() throws {
    let parent = store.directory.appendingPathComponent("responses", isDirectory: true)
    let cancelled = UploadTransferResponseSink()
    XCTAssertTrue(cancelled.append(try responseFixture()))
    XCTAssertGreaterThan(cancelled.bufferedBytes, 0)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    cancelled.discard("cancelled")
    XCTAssertEqual(cancelled.bufferedBytes, 0)
    XCTAssertFalse(cancelled.append(Data([1])))
    XCTAssertNil(cancelled.finish())
    let oversized = UploadTransferResponseSink()
    XCTAssertTrue(oversized.append(Data("fixture-api-key".utf8)))
    XCTAssertFalse(oversized.append(Data(repeating: 0, count: UploadTransferPolicy.maxResponseBytes)))
    XCTAssertEqual(oversized.reason, "response_too_large")
    XCTAssertEqual(oversized.bufferedBytes, 0)
    XCTAssertNil(oversized.finish())
    let completed = UploadTransferResponseSink()
    let raw = try responseFixture()
    XCTAssertTrue(completed.append(raw))
    XCTAssertEqual(completed.finish(), raw)
    XCTAssertEqual(completed.bufferedBytes, 0)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
  }

  func testLegacyPrivacyMigrationPreservesConfirmedFactsAndRemovesOrphanRawFiles() throws {
    var receipt = responseReceipt("legacy")
    receipt.responsePath = "native/ios/responses/legacy.html"
    receipt.acknowledged = true; receipt.outcome = "confirmed"
    let item = UploadTransferItem(id: "item", url: receipt.finalUrl!, bodyPath: "native/ios/bodies/unused.multipart", length: 100,
      sha256: "fixture", headers: [:], credentialKey: "not-created", wifiOnly: false)
    var task = UploadTransferTask(taskId: "task", accountId: "101", epoch: "epoch", items: [item], proxy: nil, language: "en", createdAt: 1, updatedAt: 2)
    task.state = "completed"; task.reason = "files_confirmed"; task.items[0].state = "confirmed"
    var journal = UploadTransferJournal(); journal.tasks = [task]; journal.receipts = [receipt]
    try responseFixture().write(to: store.file(receipt.responsePath!, mustExist: false)) // Simulated legacy raw receipt.
    let orphan = store.directory.appendingPathComponent("responses/old-unreferenced.part")
    try responseFixture().write(to: orphan)
    let source = directory.appendingPathComponent("source-owned-elsewhere.txt")
    try Data("keep source".utf8).write(to: source)
    try store.save(journal)
    try store.migrateResponsePrivacy(&journal)
    let recovered = try store.load()
    XCTAssertEqual(recovered.tasks[0].state, "completed")
    XCTAssertEqual(recovered.tasks[0].items[0].state, "confirmed")
    XCTAssertEqual(recovered.tasks[0].reason, "files_confirmed")
    XCTAssertTrue(recovered.receipts[0].acknowledged)
    XCTAssertEqual(recovered.receipts[0].outcome, "confirmed")
    XCTAssertEqual(recovered.receipts[0].state, receipt.state)
    XCTAssertEqual(recovered.receipts[0].responsePrivacyVersion, 1)
    XCTAssertEqual(recovered.receipts[0].originalVerified, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep source")
    try assertNoRawResponseSecret(in: directory)
  }

  func testInterruptedPrivacyMigrationNeverPromotesPersistedOriginalFailure() throws {
    var receipt = responseReceipt("interrupted")
    receipt.originalVerified = false
    receipt.responsePath = "native/ios/responses/interrupted.html"
    let redacted = UploadGalleryReceiptVerifier().sanitize(responseReceipt(), html: String(decoding: try responseFixture(), as: UTF8.self))
    // Simulate a crash after rewriting HTML but before committing privacyVersion.
    try Data(redacted.html.utf8).write(to: store.file(receipt.responsePath!, mustExist: false))
    var journal = UploadTransferJournal(); journal.receipts = [receipt]
    try store.save(journal)
    try store.migrateResponsePrivacy(&journal)
    let recovered = try store.load().receipts[0]
    XCTAssertEqual(recovered.originalVerified, false)
    XCTAssertEqual(recovered.responsePrivacyVersion, 1)
    XCTAssertEqual(recovered.state, receipt.state)
    XCTAssertFalse(recovered.acknowledged)
    var accepted = false
    UploadGalleryReceiptVerifier().verify(recovered, responseURL: try store.file(XCTUnwrap(recovered.responsePath))) { result in
      if case .confirmed = result { accepted = true }
    }
    XCTAssertFalse(accepted)
    try assertNoRawResponseSecret(in: directory)
  }

  func testLegacyUnexpectedRedirectQueryIsRemovedWithoutUndoingConfirmation() throws {
    var receipt = responseReceipt("redirect")
    receipt.finalUrl = "https://upld.e-hentai.org/managegallery?ulgid=12345&token=test-only-redirect-secret"
    receipt.responsePath = "native/ios/responses/redirect.html"
    receipt.acknowledged = true; receipt.outcome = "confirmed"
    try responseFixture().write(to: store.file(receipt.responsePath!, mustExist: false))
    var journal = UploadTransferJournal(); journal.receipts = [receipt]
    try store.save(journal)
    try store.migrateResponsePrivacy(&journal)
    XCTAssertNil(journal.receipts[0].finalUrl)
    XCTAssertEqual(journal.receipts[0].originalVerified, false)
    XCTAssertTrue(journal.receipts[0].acknowledged)
    XCTAssertEqual(journal.receipts[0].outcome, "confirmed")
    XCTAssertEqual(journal.receipts[0].state, receipt.state)
    let json = try String(contentsOf: store.directory.appendingPathComponent("journal.json"), encoding: .utf8)
    XCTAssertFalse(json.contains("test-only-redirect-secret"))
    try assertNoRawResponseSecret(in: directory)
  }

  func testConfirmedReceiptClearsTaskFailureWhilePreservingReceiptHistory() throws {
    var receipt = responseReceipt("confirmed-after-redirect")
    receipt.state = "uncertain"; receipt.reason = "redirect_requires_verification"
    receipt.originalVerified = false; receipt.responsePrivacyVersion = 1
    var item = UploadTransferItem(id: "item", url: receipt.finalUrl!, bodyPath: "native/ios/bodies/not-created.multipart",
      length: 100, sha256: "fixture", headers: [:], credentialKey: "not-created", wifiOnly: false)
    item.state = "uncertain"; item.receiptId = receipt.receiptId
    var task = UploadTransferTask(taskId: "task", accountId: "101", epoch: "epoch", items: [item],
      proxy: nil, language: "en", createdAt: 1, updatedAt: 2)
    task.state = "uncertain"; task.reason = "redirect_requires_verification"
    var journal = UploadTransferJournal()
    journal.accountId = "101"; journal.epoch = "epoch"; journal.tasks = [task]; journal.receipts = [receipt]
    try store.save(journal)
    let runtime = UploadTransferRuntime(storeFactory: { self.store }, restoreSystemTasks: false)
    let confirmed = expectation(description: "explicit remote reconciliation")
    runtime.handle(FlutterMethodCall(methodName: "acknowledge",
      arguments: ["receiptId": receipt.receiptId, "outcome": "confirmed"])) { value in
      XCTAssertFalse(value is FlutterError); confirmed.fulfill()
    }
    wait(for: [confirmed], timeout: 5)
    let recovered = try store.load()
    XCTAssertEqual(recovered.tasks[0].state, "completed")
    XCTAssertEqual(recovered.tasks[0].reason, "files_confirmed")
    XCTAssertEqual(recovered.tasks[0].items[0].state, "confirmed")
    XCTAssertEqual(recovered.receipts[0].outcome, "confirmed")
    XCTAssertEqual(recovered.receipts[0].reason, "redirect_requires_verification")
  }
}
