import Foundation
import Flutter

/// The system owns file transfers; this serial native runtime owns their journal and receipts.
/// No HTTP status alone proves that a gallery batch was accepted.
final class UploadTransferRuntime: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
  private let queue = DispatchQueue(label: "oviewer.upload.transport")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let delegates = OperationQueue()
  private var store: UploadTransferStore?
  private var journal = UploadTransferJournal()
  private var startupError: String?
  private var sessions: [String: URLSession] = [:]
  private var inFlight: [String: URLSessionTask] = [:]
  private var responses: [String: UploadTransferResponseSink] = [:]
  private var backgroundHandlers: [String: [() -> Void]] = [:]
  private var recoveryCount = 0
  private var verifier: UploadTransferReceiptVerifier? = UploadGalleryReceiptVerifier()
  private var verifying = Set<String>()
  private var lastProgressWrite: TimeInterval = 0
  private let sessionPrefix: String
  private let interruptionLock = NSLock()
  private var interruptedTasks = Set<String>()
  private var interruptedEpochs = Set<String>()
  private var journalLoaded = false
  private var observedLogoutFence = false
  private var privacyReady = false

  override convenience init() {
    self.init(storeFactory: { try UploadTransferStore() }, restoreSystemTasks: true)
  }

  init(storeFactory: @escaping () throws -> UploadTransferStore, restoreSystemTasks: Bool) {
    sessionPrefix = (Bundle.main.bundleIdentifier ?? "com.oviewer.oviewer") + ".upload.v1."
    super.init()
    queue.setSpecific(key: queueKey, value: 1)
    delegates.name = "oviewer.upload.events"
    delegates.maxConcurrentOperationCount = 1
    delegates.underlyingQueue = queue
    queue.async {
      do {
        let storage = try storeFactory()
        self.store = storage
        self.journal = try storage.load()
        self.journalLoaded = true
        do {
          try storage.migrateResponsePrivacy(&self.journal)
          self.privacyReady = true
        } catch { self.startupError = "response_privacy" }
        self.interruptionLock.lock()
        self.interruptedEpochs.formUnion(self.journal.revokedEpochs)
        self.interruptionLock.unlock()
        if self.journal.epoch == nil || self.journal.revokedEpochs.contains(self.journal.epoch ?? "") { self.clearCookies() }
        do { _ = try self.enforceLogoutFence() }
        catch { if self.startupError == nil { self.startupError = self.code(error) } }
        // Even when persisting revocation failed, reconnect only to cancel any old OS jobs.
        if restoreSystemTasks { self.recover() }
      } catch { self.startupError = self.code(error) }
    }
  }

  func setReceiptVerifier(_ value: UploadTransferReceiptVerifier?) {
    queue.async { self.verifier = value; self.verifyPending() }
  }

  /// AppDelegate calls this before handing unrelated URLSession events to super.
  @discardableResult
  func handleEvents(identifier: String, completion: @escaping () -> Void) -> Bool {
    guard identifier.hasPrefix(sessionPrefix) else { return false }
    queue.async {
      guard let configuration = self.journal.sessions.first(where: { $0.identifier == identifier }),
            self.startupError == nil else {
        DispatchQueue.main.async(execute: completion); return
      }
      self.backgroundHandlers[identifier, default: []].append(completion)
      do { _ = try self.session(configuration) }
      catch { self.completeBackgroundEvents(identifier) }
    }
    return true
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Cancellation must reach a large body-copy operation without waiting behind its disk work.
    let immediate = call.arguments as? [String: Any] ?? [:]
    if call.method == "invalidateSession", let epoch = try? UploadTransferPolicy.identifier(immediate["epoch"]) {
      interruptionLock.lock(); interruptedEpochs.insert(epoch); interruptionLock.unlock()
    } else if ["pause", "cancel"].contains(call.method), let id = try? UploadTransferPolicy.identifier(immediate["taskId"]) {
      interruptionLock.lock(); interruptedTasks.insert(id); interruptionLock.unlock()
    }
    queue.async {
      do {
        if let error = self.startupError, !["invalidateSession", "snapshot"].contains(call.method) {
          throw UploadTransferFailure.reason(error)
        }
        guard self.store != nil else { throw UploadTransferFailure.reason("storage") }
        let args = call.arguments as? [String: Any] ?? [:]
        let fenced = try self.enforceLogoutFence()
        if !self.privacyReady && call.method != "invalidateSession" {
          throw UploadTransferFailure.reason("response_privacy")
        }
        if fenced && ["prepareSession", "enqueue", "resume"].contains(call.method) {
          throw UploadTransferFailure.reason("logout_pending")
        }
        switch call.method {
        case "prepareSession":
          let account = try UploadTransferPolicy.identifier(args["accountId"])
          let epoch = try UploadTransferPolicy.identifier(args["epoch"])
          guard !self.journal.revokedEpochs.contains(epoch), !self.interrupted(taskId: "", epoch: epoch) else {
            throw UploadTransferFailure.reason("session_revoked")
          }
          guard self.journal.epoch != epoch || self.journal.accountId == account else {
            throw UploadTransferFailure.reason("session_conflict")
          }
          if self.journal.accountId != account || self.journal.epoch != epoch {
            if let old = self.journal.epoch { try self.revoke(old) }
            self.journal.accountId = account; self.journal.epoch = epoch
            try self.persist()
          }
          self.reply(result, nil)
        case "enqueue":
          let value = try self.enqueue(args)
          self.reply(result, value)
          self.pump()
        case "snapshot": self.reply(result, self.journal.snapshot)
        case "pause", "resume", "cancel":
          let id = try UploadTransferPolicy.identifier(args["taskId"])
          try self.changeTask(id, operation: call.method)
          self.reply(result, nil); self.pump()
        case "invalidateSession":
          let epoch = try UploadTransferPolicy.identifier(args["epoch"])
          try self.revoke(epoch)
          self.reply(result, nil)
        case "acknowledge":
          let id = try UploadTransferPolicy.identifier(args["receiptId"])
          guard let outcome = args["outcome"] as? String, ["confirmed", "retry", "stop"].contains(outcome) else {
            throw UploadTransferFailure.reason("invalid_outcome")
          }
          try self.acknowledge(id, outcome: outcome)
          self.reply(result, nil); self.pump()
        default: self.reply(result, FlutterMethodNotImplemented)
        }
      } catch {
        self.reply(result, FlutterError(code: self.code(error), message: "The upload operation could not be completed.", details: nil))
      }
    }
  }

  private func enqueue(_ args: [String: Any]) throws -> [String: Any] {
    guard let store = store else { throw UploadTransferFailure.reason("storage") }
    let account = try UploadTransferPolicy.identifier(args["accountId"])
    let epoch = try UploadTransferPolicy.identifier(args["epoch"])
    let taskId = try UploadTransferPolicy.identifier(args["taskId"])
    try requireSession(account, epoch)
    guard let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty, rawItems.count <= 2000 else {
      throw UploadTransferFailure.reason("invalid_items")
    }
    let proxy = try UploadTransferPolicy.proxy(args["proxy"] as? String)?.normalized
    if let old = journal.tasks.first(where: { $0.taskId == taskId }) {
      guard old.accountId == account, old.epoch == epoch, old.proxy == proxy, old.items.count == rawItems.count,
        zip(old.items, rawItems).allSatisfy({ item, raw in
          item.id == raw["id"] as? String && item.url == raw["url"] as? String &&
          item.length == (raw["length"] as? NSNumber)?.int64Value && item.sha256 == raw["sha256"] as? String &&
          item.wifiOnly == (raw["wifiOnly"] as? Bool ?? false) && item.verification == (try? UploadGalleryVerification.parse(raw["verification"]))
        }) else { throw UploadTransferFailure.reason("task_conflict") }
      return old.snapshot
    }
    var items: [UploadTransferItem] = []
    var createdBodies: [String] = []
    var createdCredentials: [String] = []
    do {
      var ids = Set<String>()
      for raw in rawItems {
        let id = try UploadTransferPolicy.identifier(raw["id"])
        guard ids.insert(id).inserted, let value = raw["url"] as? String,
              let source = raw["bodyPath"] as? String, let length = (raw["length"] as? NSNumber)?.int64Value,
              let hash = raw["sha256"] as? String, let rawHeaders = raw["headers"] as? [String: String] else {
          throw UploadTransferFailure.reason("invalid_item")
        }
        _ = try UploadTransferPolicy.endpoint(value)
        var headers: [String: String] = [:]
        var cookieHeader: String?
        for (name, content) in rawHeaders {
          guard content.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else {
            throw UploadTransferFailure.reason("invalid_header")
          }
          switch name.lowercased() {
          case "content-type":
            guard headers["Content-Type"] == nil, content.utf8.count <= 512,
                  content.lowercased().hasPrefix("multipart/form-data;"), content.lowercased().contains("boundary=") else {
              throw UploadTransferFailure.reason("invalid_content_type")
            }
            headers["Content-Type"] = content
          case "user-agent":
            guard headers["User-Agent"] == nil, content.utf8.count <= 1024 else { throw UploadTransferFailure.reason("invalid_header") }
            headers["User-Agent"] = content
          case "cookie":
            guard cookieHeader == nil else { throw UploadTransferFailure.reason("invalid_header") }
            cookieHeader = content
          default: throw UploadTransferFailure.reason("invalid_header")
          }
        }
        guard headers["Content-Type"] != nil, let cookieHeader = cookieHeader else {
          throw UploadTransferFailure.reason("invalid_header")
        }
        let cookies = try UploadTransferPolicy.cookies(cookieHeader, accountId: account)
        let verification = try UploadGalleryVerification.parse(raw["verification"])
        let key = UUID().uuidString.lowercased()
        let body = try store.copyBody(source, expectedLength: length, expectedHash: hash, key: key,
          cancelled: { self.interrupted(taskId: taskId, epoch: epoch) })
        createdBodies.append(body)
        try requireSession(account, epoch)
        guard !interrupted(taskId: taskId, epoch: epoch) else { throw UploadTransferFailure.reason("cancelled") }
        try store.putCookies(cookies, key: key)
        createdCredentials.append(key)
        var item = UploadTransferItem(id: id, url: value, bodyPath: body, length: length,
          sha256: hash, headers: headers, credentialKey: key, wifiOnly: raw["wifiOnly"] as? Bool ?? false)
        item.verification = verification
        items.append(item)
      }
      let timestamp = now()
      let task = UploadTransferTask(taskId: taskId, accountId: account, epoch: epoch, items: items,
        proxy: proxy, language: args["language"] as? String == "zh" ? "zh" : "en", createdAt: timestamp, updatedAt: timestamp)
      journal.tasks.append(task)
      do { try persist() } catch { journal.tasks.removeLast(); throw error }
      return task.snapshot
    } catch {
      createdBodies.forEach { store.removeOwned($0) }
      var cleanupFailure: Error?
      for key in createdCredentials {
        do { try store.removeCookies(key) }
        catch { cleanupFailure = error }
      }
      if let cleanupFailure = cleanupFailure { startupError = code(cleanupFailure); throw cleanupFailure }
      throw error
    }
  }

  private func recover() {
    do { _ = try enforceLogoutFence() }
    catch { startupError = code(error) }
    recoveryCount = journal.sessions.count
    if recoveryCount == 0 { finishRecovery(); return }
    for config in journal.sessions {
      do {
        let session = try self.session(config)
        session.getAllTasks { tasks in
          self.queue.async {
            for task in tasks {
              let key = self.nativeKey(session, task)
              self.inFlight[key] = task
              guard let location = self.locate(session, task) else { task.cancel(); continue }
              let row = self.journal.tasks[location.0]
              let item = row.items[location.1]
              if !(self.privacyReady && self.startupError == nil && self.current(row) && row.state == "sending" && item.state == "sending" &&
                  (task.state == .running || task.state == .suspended)) { task.cancel() }
            }
            self.recoveryCount -= 1
            if self.recoveryCount == 0 { self.finishRecovery() }
          }
        }
      } catch {
        startupError = code(error)
        recoveryCount -= 1
      }
    }
  }

  private func finishRecovery() {
    do { if try enforceLogoutFence() { return } }
    catch { startupError = code(error); return }
    guard startupError == nil, privacyReady else { return }
    if inFlight.count > 1 {
      discardResponseBuffers("network_interrupted")
      inFlight.values.forEach { $0.cancel() }
    } else if let task = inFlight.values.first, task.state == .suspended {
      for session in sessions.values {
        guard let (t, i) = locate(session, task), current(journal.tasks[t]), journal.tasks[t].state == "sending" else { continue }
        do {
          let item = journal.tasks[t].items[i]
          try store?.verifyBody(item.bodyPath, length: item.length, sha256: item.sha256)
          interruptionLock.lock()
          let stopped = interruptedEpochs.contains(journal.tasks[t].epoch) || interruptedTasks.contains(journal.tasks[t].taskId) || store?.logoutIsPending() != false
          if !stopped { task.resume() }
          interruptionLock.unlock()
          if stopped { task.cancel() }
        } catch { task.cancel() }
      }
    }
    for t in journal.tasks.indices {
      for i in journal.tasks[t].items.indices where journal.tasks[t].items[i].state == "sending" {
        let item = journal.tasks[t].items[i]
        let key = (item.sessionId ?? "") + ":" + String(item.nativeTaskId ?? -1)
        if inFlight[key] == nil { _ = recordReceipt(t, i, reason: "interrupted_without_receipt", uncertain: true) }
      }
    }
    do { try persist(); try store?.removeOrphans(journal); verifyPending(); pump() }
    catch { startupError = code(error) }
  }

  private func pump() {
    do { if try enforceLogoutFence() { return } }
    catch { startupError = code(error); return }
    guard startupError == nil, privacyReady, recoveryCount == 0, inFlight.isEmpty, let store = store,
          let account = journal.accountId, let epoch = journal.epoch, !journal.revokedEpochs.contains(epoch),
          !journal.receipts.contains(where: { $0.accountId == account && !$0.acknowledged }) else { return }
    guard let t = journal.tasks.firstIndex(where: { $0.accountId == account && $0.epoch == epoch && $0.state == "queued" && !interrupted(taskId: $0.taskId, epoch: $0.epoch) }),
          let i = journal.tasks[t].items.firstIndex(where: { $0.state == "queued" }) else { return }
    do {
      let row = journal.tasks[t]
      let item = row.items[i]
      let url = try UploadTransferPolicy.endpoint(item.url)
      let body = try store.file(item.bodyPath)
      try store.verifyBody(item.bodyPath, length: item.length, sha256: item.sha256)
      if try enforceLogoutFence() { return }
      let config = try sessionConfiguration(row, item)
      // Install domain-scoped cookies only after every old OS request has completed/cancelled.
      // There is deliberately no manual Cookie header that could be forwarded on a redirect.
      clearCookies()
      for (name, value) in try store.cookies(item.credentialKey) {
        guard let cookie = HTTPCookie(properties: [.name: name, .value: value, .domain: UploadTransferPolicy.host,
            .path: "/", .secure: "TRUE", .discard: "TRUE"]) else { throw UploadTransferFailure.reason("invalid_authentication") }
        HTTPCookieStorage.shared.setCookie(cookie)
      }
      let session = try self.session(config)
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.httpShouldHandleCookies = true
      item.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      let task = session.uploadTask(with: request, fromFile: body)
      task.taskDescription = row.taskId + ":" + item.id
      journal.tasks[t].state = "sending"
      journal.tasks[t].reason = nil
      journal.tasks[t].updatedAt = now()
      journal.tasks[t].items[i].state = "sending"
      journal.tasks[t].items[i].sessionId = config.identifier
      journal.tasks[t].items[i].nativeTaskId = task.taskIdentifier
      do { try persist() } catch { task.cancel(); throw error }
      inFlight[nativeKey(session, task)] = task
      interruptionLock.lock()
      let stopped = interruptedEpochs.contains(row.epoch) || interruptedTasks.contains(row.taskId) || store.logoutIsPending()
      if !stopped { task.resume() }
      interruptionLock.unlock()
      if stopped { task.cancel(); _ = try enforceLogoutFence() }
    } catch {
      journal.tasks[t].state = "paused"
      journal.tasks[t].reason = code(error)
      journal.tasks[t].updatedAt = now()
      do { try persist() } catch { startupError = code(error) }
    }
  }

  private func sessionConfiguration(_ task: UploadTransferTask, _ item: UploadTransferItem) throws -> UploadTransferSession {
    let digest = UploadTransferStore.digest(task.epoch + "\n" + (task.proxy ?? "") + "\n" + String(item.wifiOnly))
    let id = sessionPrefix + String(digest.prefix(40))
    if let existing = journal.sessions.first(where: { $0.identifier == id }) { return existing }
    let result = UploadTransferSession(identifier: id, accountId: task.accountId, epoch: task.epoch, proxy: task.proxy, wifiOnly: item.wifiOnly)
    journal.sessions.append(result)
    try persist()
    return result
  }

  private func session(_ info: UploadTransferSession) throws -> URLSession {
    if let existing = sessions[info.identifier] { return existing }
    let configuration = URLSessionConfiguration.background(withIdentifier: info.identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.allowsCellularAccess = !info.wifiOnly
    configuration.httpShouldSetCookies = true
    configuration.httpCookieStorage = .shared
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    if let proxy = try UploadTransferPolicy.proxy(info.proxy) { configuration.connectionProxyDictionary = proxy.dictionary }
    let result = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
    sessions[info.identifier] = result
    return result
  }

  private func changeTask(_ id: String, operation: String) throws {
    guard let t = journal.tasks.firstIndex(where: { $0.taskId == id && $0.accountId == journal.accountId }) else {
      throw UploadTransferFailure.reason("task_not_found")
    }
    if operation == "resume" {
      try requireSession(journal.tasks[t].accountId, journal.tasks[t].epoch)
      guard !["completed", "stopped"].contains(journal.tasks[t].state) else { throw UploadTransferFailure.reason("task_finished") }
      guard !journal.receipts.contains(where: { $0.taskId == id && !$0.acknowledged }) else {
        throw UploadTransferFailure.reason("verification_required")
      }
      journal.tasks[t].state = "queued"; journal.tasks[t].reason = nil
      interruptionLock.lock(); interruptedTasks.remove(id); interruptionLock.unlock()
    } else if journal.tasks[t].state == "completed" {
      return
    } else {
      for i in journal.tasks[t].items.indices {
        if journal.tasks[t].items[i].state == "sending" {
          _ = recordReceipt(t, i, reason: operation == "pause" ? "paused_after_send" : "cancelled_after_send", uncertain: true)
        } else if operation == "cancel" && journal.tasks[t].items[i].state == "queued" {
          journal.tasks[t].items[i].state = "stopped"
        }
      }
      journal.tasks[t].state = operation == "cancel" ? "stopped" : "paused"
      journal.tasks[t].reason = operation == "cancel" ? "cancelled" : "user_paused"
    }
    journal.tasks[t].updatedAt = now()
    var failure: Error?
    do { try persist() } catch { failure = error }
    if operation != "resume" {
      cancelOSRequests(taskId: id)
      if operation == "cancel" {
        do { try releaseTaskSecrets(t) } catch { if failure == nil { failure = error } }
      }
    }
    if let failure = failure { throw failure }
  }

  private func revoke(_ epoch: String) throws {
    interruptionLock.lock(); interruptedEpochs.insert(epoch); interruptionLock.unlock()
    journal.revokedEpochs.insert(epoch)
    for t in journal.tasks.indices where journal.tasks[t].epoch == epoch {
      for i in journal.tasks[t].items.indices {
        if journal.tasks[t].items[i].state == "sending" {
          _ = recordReceipt(t, i, reason: "session_invalidated", uncertain: true)
        } else if journal.tasks[t].items[i].state == "queued" { journal.tasks[t].items[i].state = "stopped" }
      }
      if journal.tasks[t].state != "completed" {
        journal.tasks[t].state = "stopped"; journal.tasks[t].reason = "session_invalidated"; journal.tasks[t].updatedAt = now()
      }
    }
    if journal.epoch == epoch { journal.accountId = nil; journal.epoch = nil }
    var failure: Error?
    do { try persist() } catch { failure = error }
    // A full disk must never skip cancellation or leave credentials deliberately usable.
    for t in journal.tasks.indices where journal.tasks[t].epoch == epoch {
      cancelOSRequests(taskId: journal.tasks[t].taskId)
      do { try releaseTaskSecrets(t) } catch { if failure == nil { failure = error } }
    }
    clearCookies()
    if let failure = failure { throw failure }
  }

  private func cancelOSRequests(taskId: String) {
    for (key, task) in inFlight where task.taskDescription?.hasPrefix(taskId + ":") == true {
      responses[key]?.discard("network_interrupted")
      task.cancel()
    }
  }

  private func releaseTaskSecrets(_ t: Int) throws {
    guard let store = store else { throw UploadTransferFailure.reason("credential_cleanup") }
    var failure: Error?
    for item in journal.tasks[t].items {
      do { try store.removeCookies(item.credentialKey) }
      catch { if failure == nil { failure = error } }
      store.removeOwned(item.bodyPath)
    }
    if let failure = failure { startupError = code(failure); throw failure }
  }

  private func acknowledge(_ id: String, outcome: String) throws {
    guard let r = journal.receipts.firstIndex(where: { $0.receiptId == id && $0.accountId == journal.accountId }),
          let t = journal.tasks.firstIndex(where: { $0.taskId == journal.receipts[r].taskId }),
          let i = journal.tasks[t].items.firstIndex(where: { $0.id == journal.receipts[r].itemId }) else {
      throw UploadTransferFailure.reason("receipt_not_found")
    }
    if journal.receipts[r].acknowledged {
      guard journal.receipts[r].outcome == outcome else { throw UploadTransferFailure.reason("receipt_already_acknowledged") }
      return
    }
    if inFlight.values.contains(where: { $0.taskDescription == journal.tasks[t].taskId + ":" + journal.tasks[t].items[i].id }) {
      throw UploadTransferFailure.reason("transfer_still_stopping")
    }
    if outcome == "retry" {
      try requireSession(journal.tasks[t].accountId, journal.tasks[t].epoch)
      guard journal.tasks[t].state != "stopped", let store = store else { throw UploadTransferFailure.reason("task_finished") }
      _ = try store.file(journal.tasks[t].items[i].bodyPath)
      _ = try store.cookies(journal.tasks[t].items[i].credentialKey)
      journal.tasks[t].items[i].state = "queued"
      journal.tasks[t].items[i].sentBytes = 0
      journal.tasks[t].items[i].nativeTaskId = nil
      journal.tasks[t].items[i].receiptId = nil
      journal.tasks[t].state = "paused"; journal.tasks[t].reason = "retry_ready"
      interruptionLock.lock(); interruptedTasks.remove(journal.tasks[t].taskId); interruptionLock.unlock()
    } else if outcome == "confirmed" {
      journal.tasks[t].items[i].state = "confirmed"
      if journal.tasks[t].items.allSatisfy({ $0.state == "confirmed" }) {
        journal.tasks[t].state = "completed"; journal.tasks[t].reason = "files_confirmed"
      } else if !["paused", "stopped"].contains(journal.tasks[t].state) {
        journal.tasks[t].state = "queued"; journal.tasks[t].reason = nil
      }
    } else {
      journal.tasks[t].items[i].state = "stopped"
      for index in journal.tasks[t].items.indices where journal.tasks[t].items[index].state == "queued" {
        journal.tasks[t].items[index].state = "stopped"
      }
      journal.tasks[t].state = "stopped"; journal.tasks[t].reason = "verification_stopped"
    }
    journal.receipts[r].acknowledged = true
    journal.receipts[r].outcome = outcome
    journal.tasks[t].updatedAt = now()
    var failure: Error?
    do { try persist() } catch { failure = error }
    if outcome == "stop" {
      do { try releaseTaskSecrets(t) } catch { if failure == nil { failure = error } }
    }
    else if outcome == "confirmed" {
      do { try store?.removeCookies(journal.tasks[t].items[i].credentialKey) }
      catch { startupError = code(error); if failure == nil { failure = error } }
      store?.removeOwned(journal.tasks[t].items[i].bodyPath)
    }
    if let failure = failure { throw failure }
  }

  @discardableResult
  private func recordReceipt(_ t: Int, _ i: Int, reason: String?, uncertain: Bool,
                             status: Int? = nil, finalURL: String? = nil, responsePath: String? = nil) -> String {
    let item = journal.tasks[t].items[i]
    let id = item.receiptId ?? UUID().uuidString.lowercased()
    let state = uncertain ? "uncertain" : "awaitingVerification"
    if let existing = journal.receipts.firstIndex(where: { $0.receiptId == id }) {
      journal.receipts[existing].state = state
      if let status = status { journal.receipts[existing].status = status }
      if let finalURL = finalURL { journal.receipts[existing].finalUrl = finalURL }
      if let responsePath = responsePath { journal.receipts[existing].responsePath = responsePath }
      if let reason = reason { journal.receipts[existing].reason = reason }
      journal.receipts[existing].sentBytes = item.sentBytes
      journal.receipts[existing].length = item.length
      journal.receipts[existing].verification = item.verification
    } else {
      var receipt = UploadTransferReceipt(receiptId: id, taskId: journal.tasks[t].taskId, itemId: item.id,
        accountId: journal.tasks[t].accountId, epoch: journal.tasks[t].epoch, state: state, status: status,
        finalUrl: finalURL, responsePath: responsePath, reason: reason)
      receipt.sentBytes = item.sentBytes; receipt.length = item.length; receipt.verification = item.verification
      journal.receipts.append(receipt)
    }
    journal.tasks[t].items[i].receiptId = id
    journal.tasks[t].items[i].state = state
    if !["paused", "stopped"].contains(journal.tasks[t].state) { journal.tasks[t].state = state }
    journal.tasks[t].reason = reason
    journal.tasks[t].updatedAt = now()
    return id
  }

  private func verifyPending() {
    do { if try enforceLogoutFence() { return } }
    catch { startupError = code(error); return }
    guard privacyReady, startupError == nil, let verifier = verifier else { return }
    for receipt in journal.receipts where !receipt.acknowledged && receipt.accountId == journal.accountId && receipt.epoch == journal.epoch {
      guard receipt.originalVerified == true && receipt.responsePrivacyVersion == 1 else { continue }
      guard !inFlight.values.contains(where: { $0.taskDescription == receipt.taskId + ":" + receipt.itemId }) else { continue }
      guard verifying.insert(receipt.receiptId).inserted else { continue }
      var responseURL: URL?
      if let path = receipt.responsePath, let store = store { responseURL = try? store.file(path) }
      verifier.verify(receipt, responseURL: responseURL) { decision in
        let apply: () -> Void = {
          self.verifying.remove(receipt.receiptId)
          guard self.journal.accountId == receipt.accountId, self.journal.epoch == receipt.epoch,
                !self.journal.revokedEpochs.contains(receipt.epoch),
                self.journal.receipts.contains(where: { $0.receiptId == receipt.receiptId && !$0.acknowledged }) else { return }
          do {
            switch decision {
            case .confirmed: try self.acknowledge(receipt.receiptId, outcome: "confirmed")
            case .notAccepted: try self.acknowledge(receipt.receiptId, outcome: "retry")
            case .stop: try self.acknowledge(receipt.receiptId, outcome: "stop")
            case .unresolved: return
            }
            self.pump()
          } catch { /* Remain stopped for reconciliation; never replay an unknown write. */ }
        }
        // The built-in bounded HTML verifier completes on the delegate queue. Commit its
        // receipt and submit the next native batch before releasing the OS background event.
        if DispatchQueue.getSpecific(key: self.queueKey) == 1 { apply() }
        else { self.queue.async(execute: apply) }
      }
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard privacyReady, startupError == nil, let location = locate(session, dataTask),
          current(journal.tasks[location.0]), journal.tasks[location.0].state == "sending",
          !interrupted(taskId: journal.tasks[location.0].taskId, epoch: journal.tasks[location.0].epoch) else {
      completionHandler(.cancel); return
    }
    let key = nativeKey(session, dataTask)
    responses[key]?.discard("response_replaced")
    let sink = UploadTransferResponseSink()
    responses[key] = sink
    if response.expectedContentLength > Int64(UploadTransferPolicy.maxResponseBytes) {
      sink.discard("response_too_large"); completionHandler(.cancel)
    } else { completionHandler(.allow) }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let sink = responses[nativeKey(session, dataTask)] else { dataTask.cancel(); return }
    if !sink.append(data) { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    guard let location = locate(session, task) else { return }
    journal.tasks[location.0].items[location.1].sentBytes = min(totalBytesSent, journal.tasks[location.0].items[location.1].length)
    let timestamp = Date().timeIntervalSince1970
    if timestamp - lastProgressWrite >= 1 || totalBytesSent == totalBytesExpectedToSend {
      lastProgressWrite = timestamp
      journal.tasks[location.0].updatedAt = now()
      do { try persist() } catch { startupError = code(error); task.cancel() }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let key = nativeKey(session, task)
    inFlight.removeValue(forKey: key)
    let sink = responses.removeValue(forKey: key)
    guard let location = locate(session, task) else {
      sink?.discard("orphaned_response")
      // Orphaned system callbacks may also contain late Set-Cookie responses.
      clearCookies()
      pump()
      return
    }
    if let receiptId = journal.tasks[location.0].items[location.1].receiptId,
       journal.receipts.contains(where: { $0.receiptId == receiptId && $0.acknowledged }) {
      sink?.discard("duplicate_completion")
      clearCookies(); pump(); return
    }
    // A relaunched process may not receive historical progress callbacks.
    journal.tasks[location.0].items[location.1].sentBytes = min(journal.tasks[location.0].items[location.1].length,
      max(journal.tasks[location.0].items[location.1].sentBytes, task.countOfBytesSent))
    let row = journal.tasks[location.0]
    let response = task.response as? HTTPURLResponse
    let rawFinalURL = response?.url?.absoluteString
    let finalURL = UploadGalleryReceiptVerifier.safeReceiptURL(rawFinalURL)
    let reason: String?
    if !privacyReady { reason = "response_privacy" }
    else if !current(row) { reason = "session_invalidated" }
    else if ["paused", "stopped"].contains(row.state) { reason = row.reason ?? "interrupted_after_send" }
    else if let problem = sink?.reason { reason = problem }
    else if error != nil { reason = "network_interrupted" }
    else if finalURL == nil { reason = "unexpected_final_url" }
    else if response?.statusCode == 401 || response?.statusCode == 403 { reason = "authentication_required" }
    else if response?.statusCode == 429 { reason = "rate_limited" }
    else if !(200...299).contains(response?.statusCode ?? 0) { reason = "http_error" }
    else if sink?.bufferedBytes == 0 || sink == nil { reason = "response_missing" }
    else { reason = nil }
    let raw = reason == nil ? sink?.finish() : nil
    if reason != nil { sink?.discard(reason!) }
    let receiptId = recordReceipt(location.0, location.1, reason: reason, uncertain: reason != nil,
      status: response?.statusCode, finalURL: finalURL)
    if let index = journal.receipts.firstIndex(where: { $0.receiptId == receiptId }) {
      var receipt = journal.receipts[index]
      receipt.finalUrl = finalURL // A nil value must also remove an unsafe previous redirect URL.
      if let raw = raw, let store = store {
        do {
          // Original URL is used only in memory for the original proof.
          receipt.finalUrl = rawFinalURL
          try store.persistResponse(&receipt, raw: raw)
          receipt.finalUrl = finalURL
        } catch {
          receipt.finalUrl = finalURL
          receipt.originalVerified = false; receipt.responsePrivacyVersion = 1
          receipt.responsePath = nil
          _ = recordReceipt(location.0, location.1, reason: "response_privacy", uncertain: true)
          receipt.state = "uncertain"; receipt.reason = "response_privacy"
        }
      } else {
        receipt.originalVerified = false; receipt.responsePrivacyVersion = 1
        receipt.responsePath = nil
      }
      journal.receipts[index] = receipt
    }
    clearCookies()
    do { try persist(); verifyPending(); pump() }
    catch { startupError = code(error) }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    // Receipt persistence happened synchronously on this delegate queue; do not hold the system callback for parsing or next requests.
    guard let identifier = session.configuration.identifier else { return }
    completeBackgroundEvents(identifier)
  }

  private func completeBackgroundEvents(_ identifier: String) {
    let callbacks = backgroundHandlers.removeValue(forKey: identifier) ?? []
    DispatchQueue.main.async { callbacks.forEach { $0() } }
  }

  private func locate(_ session: URLSession, _ task: URLSessionTask) -> (Int, Int)? {
    guard let description = task.taskDescription else { return nil }
    let parts = description.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let t = journal.tasks.firstIndex(where: { $0.taskId == parts[0] }),
          let i = journal.tasks[t].items.firstIndex(where: { $0.id == parts[1] }) else { return nil }
    let item = journal.tasks[t].items[i]
    guard item.sessionId == session.configuration.identifier, item.nativeTaskId == task.taskIdentifier else { return nil }
    return (t, i)
  }

  private func clearCookies() {
    for cookie in HTTPCookieStorage.shared.cookies ?? [] {
      let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      if domain == UploadTransferPolicy.host || domain == "e-hentai.org" {
        HTTPCookieStorage.shared.deleteCookie(cookie)
      }
    }
  }

  private func current(_ task: UploadTransferTask) -> Bool {
    interruptionLock.lock(); let revoked = interruptedEpochs.contains(task.epoch); interruptionLock.unlock()
    return task.accountId == journal.accountId && task.epoch == journal.epoch && !journal.revokedEpochs.contains(task.epoch) && !revoked && store?.logoutIsPending() == false
  }
  private func requireSession(_ account: String, _ epoch: String) throws {
    if try enforceLogoutFence() { throw UploadTransferFailure.reason("logout_pending") }
    interruptionLock.lock(); let revoked = interruptedEpochs.contains(epoch); interruptionLock.unlock()
    guard account == journal.accountId, epoch == journal.epoch, !journal.revokedEpochs.contains(epoch), !revoked else {
      throw UploadTransferFailure.reason("session_expired")
    }
  }
  private func interrupted(taskId: String, epoch: String) -> Bool {
    interruptionLock.lock()
    let stopped = interruptedTasks.contains(taskId) || interruptedEpochs.contains(epoch)
    interruptionLock.unlock()
    return stopped || store?.logoutIsPending() != false
  }

  @discardableResult
  private func enforceLogoutFence() throws -> Bool {
    guard let store = store else { throw UploadTransferFailure.reason("storage") }
    guard store.logoutIsPending() else { observedLogoutFence = false; return false }
    inFlight.values.forEach { $0.cancel() }
    discardResponseBuffers("session_invalidated")
    clearCookies()
    guard journalLoaded else {
      // Do not replace a corrupt journal with an empty one while cleaning authentication.
      try store.removeAllCookies()
      throw UploadTransferFailure.reason(startupError ?? "journal_corrupt")
    }
    if observedLogoutFence { return true }
    var epochs = Set(journal.tasks.map { $0.epoch })
    if let epoch = journal.epoch { epochs.insert(epoch) }
    var failure: Error?
    for epoch in epochs {
      do { try revoke(epoch) } catch { if failure == nil { failure = error } }
    }
    journal.accountId = nil; journal.epoch = nil
    do { try persist() } catch { if failure == nil { failure = error } }
    // Includes credentials staged immediately before a crash, absent from the journal.
    do { try store.removeAllCookies() } catch { if failure == nil { failure = error } }
    if let failure = failure { throw failure }
    observedLogoutFence = true
    if startupError == "storage" || startupError == "credential_cleanup" { startupError = nil }
    return true
  }
  private func persist() throws {
    guard let store = store else { throw UploadTransferFailure.reason("storage") }
    do { try store.save(journal) }
    catch {
      startupError = code(error)
      discardResponseBuffers("storage")
      inFlight.values.forEach { $0.cancel() }
      throw error
    }
  }
  private func discardResponseBuffers(_ reason: String) { responses.values.forEach { $0.discard(reason) } }
  private func nativeKey(_ session: URLSession, _ task: URLSessionTask) -> String {
    (session.configuration.identifier ?? "") + ":" + String(task.taskIdentifier)
  }
  private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
  private func code(_ error: Error) -> String { (error as? UploadTransferFailure)?.code ?? "storage" }
  private func reply(_ result: @escaping FlutterResult, _ value: Any?) { DispatchQueue.main.async { result(value) } }
}

/// At most 2 MiB of response bytes in memory. No raw response or raw temporary file is created.
final class UploadTransferResponseSink {
  private var bytes = Data()
  private(set) var reason: String?
  var bufferedBytes: Int { bytes.count }

  func append(_ data: Data) -> Bool {
    guard reason == nil else { return false }
    guard data.count <= UploadTransferPolicy.maxResponseBytes - bytes.count else {
      discard("response_too_large"); return false
    }
    bytes.append(data)
    return true
  }

  func discard(_ reason: String) {
    if self.reason == nil { self.reason = reason }
    bytes = Data()
  }

  func finish() -> Data? {
    guard reason == nil, !bytes.isEmpty else { bytes = Data(); return nil }
    let result = bytes
    bytes = Data()
    return result
  }
}
