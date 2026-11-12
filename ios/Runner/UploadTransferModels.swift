import Foundation

struct UploadTransferItem: Codable {
  var id: String
  var url: String
  var bodyPath: String
  var length: Int64
  var sha256: String
  var headers: [String: String]
  var credentialKey: String
  var wifiOnly: Bool
  var state = "queued"
  var sentBytes: Int64 = 0
  var sessionId: String?
  var nativeTaskId: Int?
  var receiptId: String?
  var verification: UploadGalleryVerification?

  var snapshot: [String: Any] {
    var value: [String: Any] = ["id": id, "state": state, "sentBytes": sentBytes, "length": length]
    if let receiptId = receiptId { value["receiptId"] = receiptId }
    return value
  }
}

struct UploadTransferTask: Codable {
  var taskId: String
  var accountId: String
  var epoch: String
  var items: [UploadTransferItem]
  var proxy: String?
  var language: String
  var createdAt: Int64
  var updatedAt: Int64
  var state = "queued"
  var reason: String?

  var snapshot: [String: Any] {
    var value: [String: Any] = ["taskId": taskId, "accountId": accountId, "epoch": epoch,
      "state": state, "createdAt": createdAt, "updatedAt": updatedAt, "items": items.map { $0.snapshot }]
    if let reason = reason { value["reason"] = reason }
    return value
  }
}

struct UploadTransferReceipt: Codable {
  var receiptId: String
  var taskId: String
  var itemId: String
  var accountId: String
  var epoch: String
  var state: String
  var status: Int?
  var finalUrl: String?
  var responsePath: String?
  var reason: String?
  var acknowledged = false
  var outcome: String?
  var sentBytes: Int64 = 0
  var length: Int64 = 0
  var verification: UploadGalleryVerification?
  /// Optional for journal compatibility. Only the raw in-memory response can establish this proof.
  var originalVerified: Bool?
  var responsePrivacyVersion: Int?

  var snapshot: [String: Any] {
    var value: [String: Any] = ["receiptId": receiptId, "taskId": taskId, "itemId": itemId,
      "accountId": accountId, "epoch": epoch, "state": state, "acknowledged": acknowledged,
      "sentBytes": sentBytes, "length": length]
    if let status = status { value["status"] = status }
    if let finalUrl = finalUrl { value["finalUrl"] = finalUrl }
    if let responsePath = responsePath { value["responsePath"] = responsePath }
    if let reason = reason { value["reason"] = reason }
    if let outcome = outcome { value["outcome"] = outcome }
    if let verification = verification { value["verification"] = verification.dictionary }
    if let originalVerified = originalVerified { value["originalVerified"] = originalVerified }
    if let responsePrivacyVersion = responsePrivacyVersion { value["responsePrivacyVersion"] = responsePrivacyVersion }
    return value
  }
}

struct UploadGalleryVerification: Codable, Equatable {
  var galleryId: String
  var expectedNames: [String]
  var priorFileIndexes: [Int]

  var dictionary: [String: Any] {
    ["galleryId": galleryId, "expectedNames": expectedNames, "priorFileIndexes": priorFileIndexes]
  }

  static func parse(_ value: Any?) throws -> UploadGalleryVerification? {
    guard let value = value else { return nil }
    guard let raw = value as? [String: Any], let gallery = raw["galleryId"] as? String,
          gallery.range(of: "^[1-9][0-9]{0,18}$", options: .regularExpression) != nil,
          let names = raw["expectedNames"] as? [String], !names.isEmpty, names.count <= 2000,
          Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }),
          let prior = raw["priorFileIndexes"] as? [Int], prior.count <= 2000, prior.allSatisfy({ $0 > 0 }) else {
      throw UploadTransferFailure.reason("invalid_verification")
    }
    return UploadGalleryVerification(galleryId: gallery, expectedNames: names, priorFileIndexes: prior)
  }
}

struct UploadTransferSession: Codable {
  var identifier: String
  var accountId: String
  var epoch: String
  var proxy: String?
  var wifiOnly: Bool
}

struct UploadTransferJournal: Codable {
  var version = 1
  var accountId: String?
  var epoch: String?
  var revokedEpochs: Set<String> = []
  var tasks: [UploadTransferTask] = []
  var receipts: [UploadTransferReceipt] = []
  var sessions: [UploadTransferSession] = []

  var snapshot: [String: Any] {
    guard let accountId = accountId else { return ["tasks": [], "receipts": []] }
    return ["tasks": tasks.filter { $0.accountId == accountId }.map { $0.snapshot },
            "receipts": receipts.filter { $0.accountId == accountId }.map { $0.snapshot }]
  }
}

enum UploadTransferFailure: Error {
  case reason(String)
  var code: String { switch self { case .reason(let code): return code } }
}

enum UploadTransferVerification {
  /// A native protocol parser has proven that every item in this batch was accepted.
  case confirmed
  /// A parser has proven no file in this batch was accepted; retry is safe.
  case notAccepted
  case stop(String)
  /// Retain the receipt and await explicit reconciliation.
  case unresolved
}

protocol UploadTransferReceiptVerifier: AnyObject {
  /// Must not depend on Flutter running. Completion may arrive after session invalidation.
  func verify(_ receipt: UploadTransferReceipt, responseURL: URL?,
              completion: @escaping (UploadTransferVerification) -> Void)
}

struct UploadTransferProxy {
  var host: String
  var port: Int
  var normalized: String {
    let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return "http://\(authority):\(port)"
  }
  var dictionary: [AnyHashable: Any] {
    ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
     "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
  }
}

enum UploadTransferPolicy {
  static let maxBodyBytes: Int64 = 128 * 1024 * 1024
  static let maxResponseBytes = 2 * 1024 * 1024
  static let host = "upld.e-hentai.org"

  static func identifier(_ input: Any?) throws -> String {
    guard let value = input as? String, value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    else { throw UploadTransferFailure.reason("invalid_identifier") }
    return value
  }

  static func endpoint(_ value: String) throws -> URL {
    guard value.utf8.count <= 8192, let parts = URLComponents(string: value), parts.scheme == "https",
          parts.host == host, parts.user == nil, parts.password == nil, parts.fragment == nil,
          parts.port == nil || parts.port == 443, let url = parts.url else {
      throw UploadTransferFailure.reason("invalid_endpoint")
    }
    return url
  }

  static func proxy(_ input: String?) throws -> UploadTransferProxy? {
    guard let value = input?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    let normalized = value.contains("://") ? value : "http://" + value
    guard let parts = URLComponents(string: normalized), parts.scheme == "http",
          let host = parts.host, !host.isEmpty, let port = parts.port, (1...65535).contains(port),
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/" else { throw UploadTransferFailure.reason("unsupported_proxy") }
    return UploadTransferProxy(host: host, port: port)
  }

  static func cookies(_ header: String, accountId: String) throws -> [String: String] {
    guard header.utf8.count <= 16384, !header.contains("\n"), !header.contains("\r") else {
      throw UploadTransferFailure.reason("invalid_authentication")
    }
    var cookies: [String: String] = [:]
    for part in header.split(separator: ";", omittingEmptySubsequences: true) {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw UploadTransferFailure.reason("invalid_authentication") }
      let name = pair[0].trimmingCharacters(in: .whitespaces)
      let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
      if name.lowercased() == "igneous" { continue }
      guard name.utf8.count <= 128,
            name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil else {
        throw UploadTransferFailure.reason("invalid_authentication")
      }
      guard !value.isEmpty, value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
            cookies[name] == nil else { throw UploadTransferFailure.reason("invalid_authentication") }
      cookies[name] = value
    }
    guard cookies["ipb_member_id"] == accountId, cookies["ipb_pass_hash"] != nil else {
      throw UploadTransferFailure.reason("invalid_authentication")
    }
    return cookies
  }
}
