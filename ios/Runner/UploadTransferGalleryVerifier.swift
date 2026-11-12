import Foundation

struct UploadSanitizedResponse {
  let html: String
  let originalVerified: Bool
}

/// Matches the observed managegallery response, including new server file IDs.
/// Structure changes or partial/ambiguous responses remain pending for reconciliation.
final class UploadGalleryReceiptVerifier: UploadTransferReceiptVerifier {
  static func safeReceiptURL(_ value: String?) -> String? {
    guard let value = value, let parts = URLComponents(string: value),
          parts.scheme == "https", parts.host == UploadTransferPolicy.host, parts.path == "/managegallery",
          parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil, parts.fragment == nil,
          let query = parts.queryItems, query.count == 1, query[0].name == "ulgid", let gallery = query[0].value,
          gallery.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil else { return nil }
    return "https://upld.e-hentai.org/managegallery?ulgid=" + gallery
  }

  func verify(_ receipt: UploadTransferReceipt, responseURL: URL?, completion: @escaping (UploadTransferVerification) -> Void) {
    guard receipt.originalVerified == true, receipt.responsePrivacyVersion == 1,
          let url = responseURL,
          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= UploadTransferPolicy.maxResponseBytes,
          let data = try? Data(contentsOf: url), data.count <= UploadTransferPolicy.maxResponseBytes,
          let html = String(data: data, encoding: .utf8) else { completion(.unresolved); return }
    completion(confirms(receipt, html: html) ? .confirmed : .unresolved)
  }

  /// This HTML is a local receipt, never a reusable upload form. Only the raw
  /// in-memory document may establish the original proof; redaction is checked too.
  func sanitize(_ receipt: UploadTransferReceipt, html: String) -> UploadSanitizedResponse {
    let original = confirms(receipt, html: html)
    guard let document = try? UploadReceiptHTML.parse(html) else {
      return UploadSanitizedResponse(html: "<html><body><p id=\"e\">Receipt requires manual verification.</p></body></html>", originalVerified: false)
    }
    var redacted = redactedHTML(document, base: receipt.finalUrl)
    if redacted.utf8.count > UploadTransferPolicy.maxResponseBytes {
      redacted = "<html><body><p id=\"e\">Receipt requires manual verification.</p></body></html>"
    }
    let redactedVerified = confirms(receipt, html: redacted)
    if !original && redactedVerified {
      // Never repair an invalid original into a proof. This non-secret invalid
      // literal preserves failure even if a future parser normalizes markup.
      redacted += "<script>var apiuid = null;</script>"
      if redacted.utf8.count > UploadTransferPolicy.maxResponseBytes {
        redacted = "<html><body><p id=\"e\">Receipt requires manual verification.</p></body></html>"
      }
    }
    return UploadSanitizedResponse(html: redacted, originalVerified: original && redactedVerified)
  }

  private func redactedHTML(_ root: UploadReceiptHTML.Node, base: String?) -> String {
    let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    func escape(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    func action(_ value: String) -> String {
      guard let url = URL(string: value, relativeTo: base.flatMap({ URL(string: $0) }))?.absoluteURL,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
            parts.scheme == "https", parts.host == UploadTransferPolicy.host, parts.path == "/managegallery",
            parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
            parts.fragment == nil || parts.fragment == "reorder",
            let query = parts.queryItems, query.count == 1, query[0].name == "ulgid",
            let gallery = query[0].value, gallery.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil else {
        return "about:invalid"
      }
      return "https://upld.e-hentai.org/managegallery?ulgid=" + gallery + (parts.fragment == nil ? "" : "#reorder")
    }
    func render(_ node: UploadReceiptHTML.Node, cellName inheritedCellName: String? = nil,
                filenameText inheritedFilename: Bool = false) -> String {
      if node.name == "document" { return node.children.map { render($0) }.joined() }
      var cellName = inheritedCellName
      let id = node.attributes["id"] ?? ""
      if id.hasPrefix("cell_") {
        let names = node.descendants.filter { $0.name == "div" && $0.classes.contains("n") }
        cellName = names.count == 1 ? names[0].textContent.trimmingCharacters(in: .whitespacesAndNewlines) : nil
      }
      let filename = inheritedFilename || (cellName != nil && node.name == "div" && node.classes.contains("n"))
      var attributes: [String: String] = [:]
      if ["uploadform", "reorderform", "e"].contains(id) { attributes["id"] = id }
      else if id.hasPrefix("cell_") {
        attributes["id"] = id.range(of: #"^cell_[1-9][0-9]*$"#, options: .regularExpression) == nil ? "cell_invalid" : id
      } else if id.hasPrefix("thumb_") {
        attributes["id"] = id.range(of: #"^thumb_[1-9][0-9]*$"#, options: .regularExpression) == nil ? "thumb_invalid" : id
      } else if id.hasPrefix("pagesel_") {
        attributes["id"] = id.range(of: #"^pagesel_[1-9][0-9]*$"#, options: .regularExpression) == nil ? "pagesel_invalid" : id
      }
      let classes = node.classes.intersection(["n", "e"]).sorted()
      if !classes.isEmpty { attributes["class"] = classes.joined(separator: " ") }
      if node.name == "form" {
        if let value = node.attributes["action"] { attributes["action"] = action(value) }
        if let value = node.attributes["method"] { attributes["method"] = value.lowercased() == "post" ? "post" : "invalid" }
        if let value = node.attributes["enctype"] { attributes["enctype"] = value.lowercased() == "multipart/form-data" ? "multipart/form-data" : "invalid" }
      }
      if node.name == "input", node.attributes["type"]?.lowercased() == "password" { attributes["type"] = "password" }
      // Keep the minimum read-only shape expected by Dart's editor/image parser,
      // without hidden upload tokens, editable values, or authorization data.
      if let name = node.attributes["name"], ["gname_en", "category", "ulcomment", "do_save"].contains(name) {
        attributes["name"] = name
        if let type = node.attributes["type"], ["hidden", "text", "password"].contains(type.lowercased()) {
          attributes["type"] = type.lowercased()
        }
      }
      if node.name == "input" && id.hasPrefix("pagesel_") {
        if let name = node.attributes["name"] {
          attributes["name"] = name.range(of: #"^pagesel_[1-9][0-9]*$"#, options: .regularExpression) == nil ? "pagesel_invalid" : name
        }
        if let value = node.attributes["value"] {
          if let position = Int(value), position > 0 { attributes["value"] = String(position) }
          else { attributes["value"] = "invalid" }
        }
      }
      if node.name == "img" && id.hasPrefix("thumb_") {
        if let handler = node.attributes["onclick"],
           handler.range(of: #"^\s*view_image_init\(\s*[0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+\s*\)\s*;?\s*$"#, options: .regularExpression) != nil {
          attributes["onclick"] = handler
        }
        for name in ["alt", "title"] {
          if let value = node.attributes[name] {
            var invalid = "invalid-name"
            if invalid == cellName { invalid += "-mismatch" }
            attributes[name] = value == cellName ? value : invalid
          }
        }
      }
      var text = ""
      if node.name == "script" {
        if node.attributes["src"] == nil {
          if let identities = literalAPIUsers(node.text) {
            text = identities.map { "var apiuid = \($0);" }.joined()
            if !identities.isEmpty { text += "var apikey = \"local-receipt-key\";" }
            else if node.text.contains("apiuid") { text = "/* apiuid omitted */" }
          } else { text = "var apiuid = null;" }
        }
      } else if node.name == "title" && node.textContent.lowercased().contains("e-hentai.org login") {
        text = "E-Hentai.org Login"
      } else if (id == "e" || (node.name == "p" && node.classes.contains("e"))) && !node.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        text = "Website reported an error."
      } else if filename && !["textarea", "style"].contains(node.name) {
        text = escape(UploadReceiptHTML.decode(node.text))
      }
      let serialized = attributes.keys.sorted().map { " \($0)=\"\(escape(attributes[$0]!))\"" }.joined()
      let children = node.children.map { render($0, cellName: cellName, filenameText: filename) }.joined()
      let close = node.closed && !void.contains(node.name) ? "</\(node.name)>" : ""
      return "<\(node.name)\(serialized)>" + text + children + close
    }
    return render(root)
  }

  func confirms(_ receipt: UploadTransferReceipt, html: String) -> Bool {
    guard receipt.originalVerified != false,
          receipt.state == "awaitingVerification", receipt.status == 200,
          receipt.length > 0, receipt.sentBytes == receipt.length,
          let specification = receipt.verification, let finalURL = receipt.finalUrl,
          galleryURL(finalURL, gallery: specification.galleryId, base: nil),
          !specification.expectedNames.isEmpty, Set(specification.expectedNames).count == specification.expectedNames.count,
          let document = try? UploadReceiptHTML.parse(html) else { return false }
    let nodes = document.descendants
    for inert in nodes where ["template", "noscript", "iframe", "noembed", "noframes", "xmp", "plaintext"].contains(inert.name) {
      if inert.descendants.contains(where: {
        let id = $0.attributes["id"] ?? ""
        return id == "uploadform" || id == "reorderform" || id.hasPrefix("cell_") ||
          id.hasPrefix("thumb_") || id.hasPrefix("pagesel_") || ($0.name == "div" && $0.classes.contains("n")) ||
          ($0.name == "script" && $0.text.contains("apiuid"))
      }) { return false }
    }
    guard !nodes.contains(where: {
      ($0.name == "input" && $0.attributes["type"]?.lowercased() == "password") ||
      ($0.name == "title" && $0.textContent.lowercased().contains("e-hentai.org login")) ||
      (($0.attributes["id"] == "e" || ($0.name == "p" && $0.classes.contains("e"))) && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }) else { return false }
    let forms = nodes.filter { $0.name == "form" && $0.attributes["id"] == "uploadform" }
    let reorders = nodes.filter { $0.name == "form" && $0.attributes["id"] == "reorderform" }
    guard forms.count == 1, forms[0].closed, forms[0].attributes["method"]?.lowercased() == "post",
          forms[0].attributes["enctype"]?.lowercased() == "multipart/form-data",
          let action = forms[0].attributes["action"], galleryURL(action, gallery: specification.galleryId, base: finalURL),
          reorders.count == 1, reorders[0].closed, let reorderAction = reorders[0].attributes["action"],
          galleryURL(reorderAction, gallery: specification.galleryId, base: finalURL, allowFragment: true) else { return false }
    let inertNames: Set<String> = ["template", "noscript", "iframe", "noembed", "noframes", "xmp", "plaintext"]
    let inertNodes = Set(nodes.filter { inertNames.contains($0.name) }
      .flatMap { $0.descendants }.map { ObjectIdentifier($0) })
    let controls = forms[0].descendants.filter {
      ["input", "select", "textarea", "button"].contains($0.name) && !inertNodes.contains(ObjectIdentifier($0))
    }
    for name in ["gname_en", "category", "ulcomment", "do_save"] {
      guard controls.contains(where: { $0.attributes["name"] == name }) else { return false }
    }
    var uids: [String] = []
    for script in nodes where script.name == "script" && script.attributes["src"] == nil {
      guard let values = literalAPIUsers(script.text) else { return false }
      uids.append(contentsOf: values)
    }
    guard uids == [receipt.accountId] else { return false }

    let allCells = nodes.filter { $0.name == "div" && ($0.attributes["id"]?.hasPrefix("cell_") == true) }
    let cells = reorders[0].descendants.filter { $0.name == "div" && ($0.attributes["id"]?.hasPrefix("cell_") == true) }
    guard !cells.isEmpty, cells.count <= 2000, allCells.count == cells.count else { return false }
    let positionInputs = reorders[0].descendants.filter { $0.name == "input" && ($0.attributes["id"]?.hasPrefix("pagesel_") == true) }
    guard positionInputs.count == cells.count else { return false }
    var byName: [String: [Int]] = [:]
    var fileOccurrences: [Int: Int] = [:]
    var cellIds = Set<String>()
    var positions = Set<Int>()
    for cell in cells {
      guard cell.closed, let id = cell.attributes["id"], cellIds.insert(id).inserted,
            let page = capture(#"^cell_([1-9][0-9]*)$"#, id, group: 1) else { return false }
      let contents = cell.descendants
      guard !contents.contains(where: { $0.attributes["id"]?.hasPrefix("cell_") == true }) else { return false }
      let names = contents.filter { $0.name == "div" && $0.classes.contains("n") }
      let images = contents.filter { $0.name == "img" && $0.attributes["id"] == "thumb_" + page }
      let inputs = contents.filter { $0.name == "input" && $0.attributes["id"] == "pagesel_" + page }
      guard inputs.count == 1, inputs[0].attributes["name"] == "pagesel_" + page,
            let position = inputs[0].attributes["value"].flatMap({ Int($0) }),
            position >= 1, position <= cells.count, positions.insert(position).inserted else { return false }
      guard names.count == 1, names[0].closed, images.count == 1,
            let onclick = images[0].attributes["onclick"] else { return false }
      let pattern = #"^\s*view_image_init\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*\)\s*;?\s*$"#
      guard capture(pattern, onclick, group: 1) == specification.galleryId,
            capture(pattern, onclick, group: 2) == page,
            let file = capture(pattern, onclick, group: 3).flatMap({ Int($0) }), file > 0 else { return false }
      let name = names[0].textContent.trimmingCharacters(in: .whitespacesAndNewlines)
      guard images[0].attributes["alt"] == name, images[0].attributes["title"] == name else { return false }
      byName[name, default: []].append(file)
      fileOccurrences[file, default: 0] += 1
    }
    let previous = Set(specification.priorFileIndexes)
    var newFiles = Set<Int>()
    for name in specification.expectedNames {
      guard let matches = byName[name], matches.count == 1, let file = matches.first,
            fileOccurrences[file] == 1, !previous.contains(file), newFiles.insert(file).inserted else { return false }
    }
    return true
  }

  private func galleryURL(_ value: String, gallery: String, base: String?, allowFragment: Bool = false) -> Bool {
    guard let url = URL(string: value, relativeTo: base.flatMap({ URL(string: $0) }))?.absoluteURL,
          let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
          parts.scheme == "https", parts.host == UploadTransferPolicy.host, parts.path == "/managegallery",
          parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
          parts.fragment == nil || (allowFragment && parts.fragment == "reorder") else { return false }
    let items = parts.queryItems ?? []
    return items.count == 1 && items[0].name == "ulgid" && items[0].value == gallery
  }

  private func capture(_ pattern: String, _ value: String, group: Int) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let range = Range(match.range(at: group), in: value) else { return nil }
    return String(value[range])
  }

  private func literalAPIUsers(_ script: String) -> [String]? {
    let source = Array(script.utf16)
    var masked = source
    var index = 0
    var quote: UInt16 = 0
    var lineComment = false
    var blockComment = false
    while index < source.count {
      let value = source[index]
      if lineComment {
        if value == 10 || value == 13 { lineComment = false }
        else { masked[index] = 32 }
      } else if blockComment {
        masked[index] = 32
        if value == 42 && index + 1 < source.count && source[index + 1] == 47 {
          masked[index + 1] = 32; index += 1; blockComment = false
        }
      } else if quote != 0 {
        masked[index] = 32
        if value == 92 && index + 1 < source.count { masked[index + 1] = 32; index += 1 }
        else if value == quote { quote = 0 }
      } else if value == 34 || value == 39 || value == 96 {
        quote = value; masked[index] = 32
      } else if value == 47 && index + 1 < source.count && source[index + 1] == 47 {
        lineComment = true; masked[index] = 32; masked[index + 1] = 32; index += 1
      } else if value == 47 && index + 1 < source.count && source[index + 1] == 42 {
        blockComment = true; masked[index] = 32; masked[index + 1] = 32; index += 1
      }
      index += 1
    }
    guard quote == 0, !blockComment else { return nil }
    let text = String(decoding: masked, as: UTF16.self)
    if text.range(of: #"\bapiuid\b"#, options: .regularExpression) == nil { return [] }
    // The observed identity script consists of literal declarations. Unknown regex
    // literals/division alongside apiuid are not evaluated or guessed here.
    if text.contains("/") { return nil }
    guard let declaration = try? NSRegularExpression(pattern: #"\bvar\s+apiuid\s*=\s*([0-9]+)\s*;"#),
          let assignment = try? NSRegularExpression(pattern: #"\bapiuid\s*=(?!=|>)"#) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    let matches = declaration.matches(in: text, range: range)
    guard assignment.numberOfMatches(in: text, range: range) == matches.count else { return nil }
    return matches.compactMap { match in Range(match.range(at: 1), in: text).map { String(text[$0]) } }
  }
}

/// A small non-executing HTML tokenizer. It handles quoted attributes and raw-text
/// elements so user descriptions/comments cannot impersonate a form or API identity.
private enum UploadReceiptHTML {
  final class Node {
    let name: String
    let attributes: [String: String]
    var children: [Node] = []
    var text = ""
    var closed = false
    init(_ name: String, _ attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    var classes: Set<String> { Set((attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)) }
    var descendants: [Node] { children.flatMap { [$0] + $0.descendants } }
    var textContent: String { UploadReceiptHTML.decode(text) + children.map { $0.textContent }.joined() }
  }

  static func parse(_ html: String) throws -> Node {
    guard html.utf8.count <= UploadTransferPolicy.maxResponseBytes else { throw UploadTransferFailure.reason("response_too_large") }
    let source = html as NSString
    let root = Node("document")
    var stack = [root]
    var offset = 0
    var nodeCount = 1
    let rawText: Set<String> = ["script", "style", "textarea", "title"]
    let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    let nameRegex = try NSRegularExpression(pattern: #"^/?([A-Za-z][A-Za-z0-9:-]*)"#)
    let attributeRegex = try NSRegularExpression(pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
    while offset < source.length {
      let open = source.range(of: "<", options: [], range: NSRange(location: offset, length: source.length - offset))
      if open.location == NSNotFound { stack.last?.text += source.substring(from: offset); break }
      if open.location > offset { stack.last?.text += source.substring(with: NSRange(location: offset, length: open.location - offset)) }
      if source.length - open.location >= 4 && source.substring(with: NSRange(location: open.location, length: 4)) == "<!--" {
        let end = source.range(of: "-->", options: [], range: NSRange(location: open.location + 4, length: source.length - open.location - 4))
        guard end.location != NSNotFound else { throw UploadTransferFailure.reason("invalid_html") }
        offset = NSMaxRange(end); continue
      }
      var cursor = open.location + 1
      var quote: unichar = 0
      while cursor < source.length {
        let char = source.character(at: cursor)
        if quote != 0 { if char == quote { quote = 0 } }
        else if char == 34 || char == 39 { quote = char }
        else if char == 62 { break }
        cursor += 1
      }
      guard cursor < source.length else { throw UploadTransferFailure.reason("invalid_html") }
      let token = source.substring(with: NSRange(location: open.location + 1, length: cursor - open.location - 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      offset = cursor + 1
      if token.hasPrefix("!") || token.hasPrefix("?") { continue }
      let tokenSource = token as NSString
      guard let nameMatch = nameRegex.firstMatch(in: token, range: NSRange(location: 0, length: tokenSource.length)) else {
        throw UploadTransferFailure.reason("invalid_html")
      }
      let name = tokenSource.substring(with: nameMatch.range(at: 1)).lowercased()
      if token.hasPrefix("/") {
        if let index = stack.lastIndex(where: { $0.name == name }), index > 0 {
          stack[index].closed = true
          stack.removeSubrange(index...)
        }
        continue
      }
      var tail = tokenSource.substring(from: NSMaxRange(nameMatch.range))
      let selfClosing = tail.hasSuffix("/")
      if selfClosing { tail.removeLast() }
      let tailSource = tail as NSString
      var attributes: [String: String] = [:]
      var consumed = 0
      for match in attributeRegex.matches(in: tail, range: NSRange(location: 0, length: tailSource.length)) {
        guard tailSource.substring(with: NSRange(location: consumed, length: match.range.location - consumed))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UploadTransferFailure.reason("invalid_html") }
        let key = tailSource.substring(with: match.range(at: 1)).lowercased()
        guard attributes[key] == nil else { throw UploadTransferFailure.reason("invalid_html") }
        var value = ""
        for group in 2...4 where match.range(at: group).location != NSNotFound { value = tailSource.substring(with: match.range(at: group)); break }
        attributes[key] = decode(value)
        consumed = NSMaxRange(match.range)
      }
      guard tailSource.substring(from: consumed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw UploadTransferFailure.reason("invalid_html")
      }
      nodeCount += 1
      guard nodeCount <= 40_000 else { throw UploadTransferFailure.reason("invalid_html") }
      let node = Node(name, attributes)
      stack.last?.children.append(node)
      if rawText.contains(name) {
        let endRegex = try NSRegularExpression(pattern: "</" + name + #"\s*>"#, options: .caseInsensitive)
        guard let end = endRegex.firstMatch(in: html, range: NSRange(location: offset, length: source.length - offset)) else {
          throw UploadTransferFailure.reason("invalid_html")
        }
        node.text = source.substring(with: NSRange(location: offset, length: end.range.location - offset))
        node.closed = true
        offset = NSMaxRange(end.range)
      } else if void.contains(name) || selfClosing { node.closed = true }
      else {
        guard stack.count < 128 else { throw UploadTransferFailure.reason("invalid_html") }
        stack.append(node)
      }
    }
    return root
  }

  static func decode(_ source: String) -> String {
    var value = source
    let named = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "amp": "&"]
    if let regex = try? NSRegularExpression(pattern: #"&(quot|apos|lt|gt|amp|#[xX][0-9a-fA-F]+|#[0-9]+);"#) {
      for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
        guard let numberRange = Range(match.range(at: 1), in: source), let whole = Range(match.range, in: value) else { continue }
        let number = String(source[numberRange])
        if let text = named[number] { value.replaceSubrange(whole, with: text) }
        else {
          let hex = number.hasPrefix("#x") || number.hasPrefix("#X")
          let code = hex ? UInt32(number.dropFirst(2), radix: 16) : UInt32(number.dropFirst())
          if let code = code, let scalar = UnicodeScalar(code) { value.replaceSubrange(whole, with: String(scalar)) }
        }
      }
    }
    return value
  }
}
