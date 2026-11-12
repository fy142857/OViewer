import Foundation
import Security
import CommonCrypto

/// Called on UploadTransferRuntime's serial queue. Credentials never enter the JSON journal.
final class UploadTransferStore {
  let root: URL
  let directory: URL
  private let journalURL: URL
  private let keychainService: String
  let logoutMarker: URL

  init(root override: URL? = nil, logoutMarker markerOverride: URL? = nil, credentialService: String? = nil) throws {
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .resolvingSymlinksInPath().standardizedFileURL
    if let override = override {
      root = override.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(override.lastPathComponent, isDirectory: true).standardizedFileURL
    } else { root = documents.appendingPathComponent("uploads", isDirectory: true).standardizedFileURL }
    guard root.resolvingSymlinksInPath().path == root.path else { throw UploadTransferFailure.reason("unsafe_path") }
    directory = root.appendingPathComponent("native/ios", isDirectory: true)
    journalURL = directory.appendingPathComponent("journal.json")
    keychainService = credentialService ?? (Bundle.main.bundleIdentifier ?? "com.oviewer.oviewer") + ".upload.credentials"
    logoutMarker = markerOverride ?? documents.appendingPathComponent(".cookies/logout-pending")
    try makeDirectory(directory)
    try makeDirectory(directory.appendingPathComponent("bodies", isDirectory: true))
    try makeDirectory(directory.appendingPathComponent("responses", isDirectory: true))
  }

  /// The marker is a crash fence, not a cookie source. Never read its contents.
  /// Missing is allowed; inaccessible or otherwise indeterminate is fail-closed.
  func logoutIsPending() -> Bool {
    do { _ = try FileManager.default.attributesOfItem(atPath: logoutMarker.path); return true }
    catch let error as NSError {
      if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
      if error.domain == NSPOSIXErrorDomain && error.code == 2 { return false } // ENOENT
      return true
    }
  }

  func load() throws -> UploadTransferJournal {
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return UploadTransferJournal() }
    let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 32 * 1024 * 1024 else { throw UploadTransferFailure.reason("journal_corrupt") }
    do {
      let journal = try JSONDecoder().decode(UploadTransferJournal.self, from: Data(contentsOf: journalURL))
      guard journal.version == 1 else { throw UploadTransferFailure.reason("journal_version") }
      return journal
    } catch let failure as UploadTransferFailure { throw failure }
      catch { throw UploadTransferFailure.reason("journal_corrupt") }
  }

  func save(_ journal: UploadTransferJournal) throws {
    let data = try JSONEncoder().encode(journal)
    guard data.count <= 32 * 1024 * 1024 else { throw UploadTransferFailure.reason("journal_full") }
    try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Raw bytes are accepted only in memory; every filesystem write receives the
  /// minimized receipt produced by the HTML verifier, never the network body.
  func persistResponse(_ receipt: inout UploadTransferReceipt, raw: Data) throws {
    guard !raw.isEmpty, raw.count <= UploadTransferPolicy.maxResponseBytes,
          let html = String(data: raw, encoding: .utf8) else { throw UploadTransferFailure.reason("response_encoding") }
    _ = try UploadTransferPolicy.identifier(receipt.receiptId)
    let sanitized = UploadGalleryReceiptVerifier().sanitize(receipt, html: html)
    let relative = "native/ios/responses/\(receipt.receiptId).html"
    try writeSanitized(sanitized.html, relative: relative)
    receipt.originalVerified = receipt.originalVerified != false && sanitized.originalVerified
    receipt.responsePrivacyVersion = 1
    receipt.responsePath = relative
  }

  /// Migrate before exposing receipts or resuming work. Checkpoint the original
  /// proof first so a crash after rewriting HTML cannot promote a previous false.
  /// Confirmed/acknowledged outcomes and task state are intentionally untouched.
  func migrateResponsePrivacy(_ journal: inout UploadTransferJournal) throws {
    try removeResponseOrphans(journal)
    let verifier = UploadGalleryReceiptVerifier()
    for index in journal.receipts.indices {
      let originalReceipt = journal.receipts[index]
      let safeURL = UploadGalleryReceiptVerifier.safeReceiptURL(originalReceipt.finalUrl)
      let urlChanged = originalReceipt.finalUrl != safeURL
      let needsContentMigration = originalReceipt.responsePrivacyVersion != 1
      if !needsContentMigration && !urlChanged { continue }
      if urlChanged {
        journal.receipts[index].finalUrl = safeURL
        if safeURL == nil && originalReceipt.finalUrl != nil {
          journal.receipts[index].originalVerified = false
          if !originalReceipt.acknowledged && originalReceipt.reason == nil {
            journal.receipts[index].reason = "unexpected_final_url"
          }
        }
      }
      guard needsContentMigration else { try save(journal); continue }
      guard let relative = originalReceipt.responsePath else {
        journal.receipts[index].originalVerified = false
        journal.receipts[index].responsePrivacyVersion = 1
        try save(journal)
        continue
      }
      guard relative.hasPrefix("native/ios/responses/"), let url = try? file(relative, mustExist: false) else {
        // A corrupted reference must never turn into permission to alter source files.
        journal.receipts[index].responsePath = nil
        journal.receipts[index].originalVerified = false
        journal.receipts[index].responsePrivacyVersion = 1
        try save(journal)
        continue
      }
      if !FileManager.default.fileExists(atPath: url.path) {
        journal.receipts[index].responsePath = nil
        journal.receipts[index].originalVerified = false
        journal.receipts[index].responsePrivacyVersion = 1
        try save(journal)
        continue
      }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw UploadTransferFailure.reason("response_privacy")
      }
      let size = values.fileSize ?? 0
      var rawHTML: String?
      if size > 0 && size <= UploadTransferPolicy.maxResponseBytes {
        let bytes = try Data(contentsOf: url)
        if bytes.count <= UploadTransferPolicy.maxResponseBytes { rawHTML = String(data: bytes, encoding: .utf8) }
      }
      guard let html = rawHTML else {
        // Invalid/oversized legacy bodies cannot be used as evidence. Removing
        // this owned file does not undo its already-recorded business outcome.
        journal.receipts[index].originalVerified = false
        try save(journal)
        try FileManager.default.removeItem(at: url)
        journal.receipts[index].responsePath = nil
        journal.receipts[index].responsePrivacyVersion = 1
        try save(journal)
        continue
      }
      let originallyVerified = originalReceipt.originalVerified ?? verifier.confirms(originalReceipt, html: html)
      journal.receipts[index].originalVerified = journal.receipts[index].originalVerified != false && originallyVerified
      try save(journal)
      let sanitized = verifier.sanitize(journal.receipts[index], html: html)
      do { try writeSanitized(sanitized.html, relative: relative) }
      catch {
        // A failed replacement must not deliberately keep an owned raw response.
        try FileManager.default.removeItem(at: url)
        journal.receipts[index].responsePath = nil
        journal.receipts[index].originalVerified = false
        journal.receipts[index].responsePrivacyVersion = 1
        try save(journal)
        throw UploadTransferFailure.reason("response_privacy")
      }
      journal.receipts[index].originalVerified = journal.receipts[index].originalVerified == true && sanitized.originalVerified
      journal.receipts[index].responsePrivacyVersion = 1
      try save(journal)
    }
  }

  private func writeSanitized(_ html: String, relative: String) throws {
    let data = Data(html.utf8)
    guard data.count <= UploadTransferPolicy.maxResponseBytes,
          relative.hasPrefix("native/ios/responses/") else { throw UploadTransferFailure.reason("response_privacy") }
    let url = try file(relative, mustExist: false)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func removeResponseOrphans(_ journal: UploadTransferJournal) throws {
    let referenced = Set(journal.receipts.compactMap { $0.responsePath })
    let parent = directory.appendingPathComponent("responses", isDirectory: true)
    for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
      let relative = "native/ios/responses/\(url.lastPathComponent)"
      if referenced.contains(relative) { continue }
      let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if properties.isRegularFile == true && properties.isSymbolicLink != true {
        let owned = try file(relative)
        try FileManager.default.removeItem(at: owned)
      }
    }
  }

  func file(_ relative: String, mustExist: Bool = true) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
          !relative.contains("\0"), relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw UploadTransferFailure.reason("unsafe_path")
    }
    let url = root.appendingPathComponent(relative).standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else {
      throw UploadTransferFailure.reason("unsafe_path")
    }
    if mustExist {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { throw UploadTransferFailure.reason("body_missing") }
    }
    return url
  }

  func copyBody(_ source: String, expectedLength: Int64, expectedHash: String, key: String,
                cancelled: () -> Bool = { false }) throws -> String {
    guard expectedLength > 0, expectedLength <= UploadTransferPolicy.maxBodyBytes,
          expectedHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw UploadTransferFailure.reason("invalid_body")
    }
    let sourceURL = try file(source)
    let actualLength = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard actualLength.map({ Int64($0) }) == expectedLength else { throw UploadTransferFailure.reason("body_changed") }
    _ = try UploadTransferPolicy.identifier(key)
    let relative = "native/ios/bodies/\(key).multipart"
    let destination = try file(relative, mustExist: false)
    let partial = destination.appendingPathExtension("part")
    guard !FileManager.default.fileExists(atPath: destination.path),
          FileManager.default.createFile(atPath: partial.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]),
          let input = InputStream(url: sourceURL), let output = OutputStream(url: partial, append: false)
    else { throw UploadTransferFailure.reason("storage") }
    input.open(); output.open()
    var finalized = false
    defer {
      input.close(); output.close()
      if !finalized { try? FileManager.default.removeItem(at: partial) }
    }
    var hash = CC_SHA256_CTX(); CC_SHA256_Init(&hash)
    var size: Int64 = 0
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
    defer { buffer.deallocate() }
    while true {
      if cancelled() { throw UploadTransferFailure.reason("cancelled") }
      let count = input.read(buffer, maxLength: 64 * 1024)
      if count < 0 { throw UploadTransferFailure.reason("read_failed") }
      if count == 0 { break }
      guard size + Int64(count) <= expectedLength else { throw UploadTransferFailure.reason("body_changed") }
      CC_SHA256_Update(&hash, buffer, CC_LONG(count))
      var offset = 0
      while offset < count {
        let written = output.write(buffer.advanced(by: offset), maxLength: count - offset)
        guard written > 0 else { throw UploadTransferFailure.reason("insufficient_storage") }
        offset += written
      }
      size += Int64(count)
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &hash)
    guard !cancelled() else { throw UploadTransferFailure.reason("cancelled") }
    guard size == expectedLength, digest.map({ String(format: "%02x", $0) }).joined() == expectedHash else {
      throw UploadTransferFailure.reason("body_changed")
    }
    output.close()
    try FileManager.default.moveItem(at: partial, to: destination)
    finalized = true
    return relative
  }

  func removeOwned(_ relative: String?) {
    guard let relative = relative,
          relative.hasPrefix("native/ios/bodies/") || relative.hasPrefix("native/ios/responses/"),
          let url = try? file(relative, mustExist: false) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  func verifyBody(_ relative: String, length: Int64, sha256: String) throws {
    let url = try file(relative)
    guard let input = InputStream(url: url) else { throw UploadTransferFailure.reason("body_missing") }
    input.open(); defer { input.close() }
    var context = CC_SHA256_CTX(); CC_SHA256_Init(&context)
    var size: Int64 = 0
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
    defer { buffer.deallocate() }
    while true {
      let count = input.read(buffer, maxLength: 64 * 1024)
      if count < 0 { throw UploadTransferFailure.reason("read_failed") }
      if count == 0 { break }
      size += Int64(count)
      guard size <= length else { throw UploadTransferFailure.reason("body_changed") }
      CC_SHA256_Update(&context, buffer, CC_LONG(count))
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &context)
    guard size == length, digest.map({ String(format: "%02x", $0) }).joined() == sha256 else {
      throw UploadTransferFailure.reason("body_changed")
    }
  }

  func putCookies(_ cookies: [String: String], key: String) throws {
    let data = try JSONEncoder().encode(cookies)
    let query = credentialQuery(key)
    let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UploadTransferFailure.reason("credential_storage") }
    } else if updated != errSecSuccess { throw UploadTransferFailure.reason("credential_storage") }
  }

  func cookies(_ key: String) throws -> [String: String] {
    var query = credentialQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { throw UploadTransferFailure.reason("authentication_required") }
    return try JSONDecoder().decode([String: String].self, from: data)
  }

  func removeCookies(_ key: String) throws {
    let status = SecItemDelete(credentialQuery(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw UploadTransferFailure.reason("credential_cleanup") }
  }

  func removeAllCookies() throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw UploadTransferFailure.reason("credential_cleanup") }
  }

  func removeOrphans(_ journal: UploadTransferJournal) throws {
    let items = journal.tasks.flatMap { $0.items }
    let files = Set(items.map { $0.bodyPath } + journal.receipts.compactMap { $0.responsePath })
    for subdirectory in ["bodies", "responses"] {
      let parent = directory.appendingPathComponent(subdirectory, isDirectory: true)
      for fileURL in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey])) ?? [] {
        let relative = "native/ios/\(subdirectory)/\(fileURL.lastPathComponent)"
        if !files.contains(relative) { removeOwned(relative) }
      }
    }
    let references = Set(items.map { $0.credentialKey })
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                               kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess, let attributes = result as? [[String: Any]] else {
      throw UploadTransferFailure.reason("credential_cleanup")
    }
    for item in attributes {
      if let key = item[kSecAttrAccount as String] as? String, !references.contains(key) { try removeCookies(key) }
    }
  }

  static func digest(_ value: String) -> String {
    let data = Data(value.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { raw in _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func credentialQuery(_ key: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
     kSecAttrAccount as String: key]
  }

  private func makeDirectory(_ url: URL) throws {
    guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
      throw UploadTransferFailure.reason("unsafe_path")
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
    var target = root
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try target.setResourceValues(values)
  }
}
