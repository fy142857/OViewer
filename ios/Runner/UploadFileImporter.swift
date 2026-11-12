import Flutter
import UIKit
import Photos
import PhotosUI
import MobileCoreServices
import UniformTypeIdentifiers

/// Owns only user-selected copies under Documents/uploads/imports. Source assets are never changed.
final class UploadFileImporter: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  weak var presenter: UIViewController?
  private let work = DispatchQueue(label: "oviewer.upload.import", qos: .userInitiated)
  private var pending: UploadImportJob?
  private weak var picker: UIViewController?
  private var disposed = false
  private var appLanguage: String?
  private let maxFiles = 2_000
  private let maxBytes: Int64 = 10_000_000_000
  private let reserve: Int64 = 32 * 1024 * 1024

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    precondition(Thread.isMainThread)
    guard !disposed else { result(failure("disposed")); return }
    if let args = call.arguments as? [String: Any], args["root"] != nil || args["path"] != nil {
      result(failure("invalid_arguments")); return
    }
    switch call.method {
    case "pickFiles": begin(photos: false, language: (call.arguments as? [String: Any])?["language"] as? String, result: result)
    case "pickPhotos": begin(photos: true, language: (call.arguments as? [String: Any])?["language"] as? String, result: result)
    case "cancelImport": cancel(); result(nil)
    case "availableBytes":
      do { result(try availableBytes()) } catch { result(failure("storage")) }
    case "excludeFromBackup":
      do { _ = try root(); result(true) } catch { result(failure("storage")) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  func dispose() { disposed = true; cancel(); presenter = nil }

  private var chinese: Bool { (appLanguage ?? Locale.preferredLanguages.first ?? "en").hasPrefix("zh") }
  private func failure(_ reason: String) -> FlutterError {
    FlutterError(code: reason, message: "Could not import selected upload files.", details: nil)
  }

  private func begin(photos: Bool, language: String?, result: @escaping FlutterResult) {
    guard pending == nil else { result(failure("busy")); return }
    guard let host = presenter, host.viewIfLoaded?.window != nil, host.presentedViewController == nil else {
      result(failure("no_activity")); return
    }
    appLanguage = language
    let job = UploadImportJob(result: result)
    pending = job
    if !photos {
      let controller: UIDocumentPickerViewController
      if #available(iOS 14, *) { controller = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .zip], asCopy: true) }
      else { controller = UIDocumentPickerViewController(documentTypes: ["public.image", "public.zip-archive"], in: .import) }
      controller.allowsMultipleSelection = true
      controller.delegate = self
      show(controller, from: host)
      return
    }
    if #available(iOS 14, *) {
      var configuration = PHPickerConfiguration(photoLibrary: .shared())
      configuration.filter = .images
      configuration.selectionLimit = maxFiles
      configuration.preferredAssetRepresentationMode = .current
      let controller = PHPickerViewController(configuration: configuration)
      controller.delegate = self
      show(controller, from: host)
    } else {
      // iOS 12/13 have no PHPicker. Request read access only for this explicit action.
      PHPhotoLibrary.requestAuthorization { [weak self, weak host] status in
        DispatchQueue.main.async {
          guard let self = self, self.pending === job else { return }
          guard !job.isCancelled else { self.finish(job); return }
          guard status == .authorized, let host = host else {
            job.errors.append(["displayName": "", "reason": "permission_denied"])
            self.finish(job); return
          }
          let controller = UploadLegacyPhotoPicker(maxSelection: self.maxFiles, chinese: self.chinese) { [weak self] assets in
            guard let self = self, self.pending === job else { return }
            self.picker?.dismiss(animated: true)
            self.picker = nil
            guard let assets = assets else { job.cancel(); self.finish(job); return }
            job.copying = true
            self.importAssets(assets, at: 0, job: job)
          }
          self.show(UINavigationController(rootViewController: controller), from: host)
        }
      }
    }
  }

  private func show(_ controller: UIViewController, from host: UIViewController) {
    picker = controller
    host.present(controller, animated: true)
    controller.presentationController?.delegate = self
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard picker === controller, let job = pending, !job.copying else { return }
    job.cancel(); picker = nil; finish(job)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard picker === presentationController.presentedViewController, let job = pending, !job.copying else { return }
    job.cancel(); picker = nil; finish(job)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard picker === controller, let job = pending, !job.copying else { return }
    picker = nil
    guard urls.count <= maxFiles else {
      job.errors.append(["displayName": "", "reason": "too_many_files"]); finish(job); return
    }
    if urls.isEmpty { job.cancel(); finish(job); return }
    job.copying = true
    importURLs(urls, at: 0, job: job)
  }

  private func importURLs(_ urls: [URL], at index: Int, job: UploadImportJob) {
    guard pending === job else { return }
    guard index < urls.count, !job.isCancelled else { finish(job); return }
    let url = urls[index]
    work.async {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let outcome = self.copy(url: url, name: url.lastPathComponent, type: nil, job: job)
      DispatchQueue.main.async {
        guard self.pending === job else { return }
        self.accept(outcome, name: url.lastPathComponent, job: job)
        self.importURLs(urls, at: index + 1, job: job)
      }
    }
  }

  private func importAssets(_ assets: [PHAsset], at index: Int, job: UploadImportJob) {
    guard pending === job else { return }
    guard index < assets.count, !job.isCancelled else { finish(job); return }
    let asset = assets[index]
    guard !asset.mediaSubtypes.contains(.photoLive) else {
      job.errors.append(["displayName": "", "reason": "live_photo_requires_conversion"])
      DispatchQueue.main.async { self.importAssets(assets, at: index + 1, job: job) }; return
    }
    guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
      job.errors.append(["displayName": "", "reason": "unsupported_format"])
      DispatchQueue.main.async { self.importAssets(assets, at: index + 1, job: job) }; return
    }
    if isRawType(resource.uniformTypeIdentifier) {
      job.errors.append(["displayName": resource.originalFilename, "reason": "unsupported_format"])
      DispatchQueue.main.async { self.importAssets(assets, at: index + 1, job: job) }; return
    }
    do {
      let sink = try makeSink(name: resource.originalFilename, job: job)
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true
      let request = PHAssetResourceManager.default().requestData(for: resource, options: options,
          dataReceivedHandler: { data in sink.append(data) }, completionHandler: { error in
        let outcome = sink.finish(error: error, mime: self.mime(resource.uniformTypeIdentifier))
        DispatchQueue.main.async {
          guard self.pending === job else { return }
          job.resourceRequest = nil
          self.accept(outcome, name: resource.originalFilename, job: job)
          self.importAssets(assets, at: index + 1, job: job)
        }
      })
      job.resourceRequest = request
      if job.isCancelled { PHAssetResourceManager.default().cancelDataRequest(request) }
    } catch {
      job.errors.append(["displayName": resource.originalFilename, "reason": reason(error)])
      DispatchQueue.main.async { self.importAssets(assets, at: index + 1, job: job) }
    }
  }

  private func copy(url: URL, name: String, type: String?, job: UploadImportJob) -> Result<[String: Any], Error> {
    do {
      guard !job.isCancelled else { throw UploadImportError.reason("cancelled") }
      guard url.isFileURL else { throw UploadImportError.reason("unsupported_uri") }
      let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .typeIdentifierKey])
      guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else {
        throw UploadImportError.reason("unsupported_format")
      }
      if Int64(metadata.fileSize ?? 0) > maxBytes - job.bytes { throw UploadImportError.reason("selection_too_large") }
      if Int64(metadata.fileSize ?? 0) > (try availableBytes()) - reserve { throw UploadImportError.reason("insufficient_storage") }
      let sink = try makeSink(name: name, job: job)
      guard let input = InputStream(url: url) else { return sink.finish(error: UploadImportError.reason("read_failed"), mime: "") }
      input.open()
      defer { input.close() }
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
      defer { buffer.deallocate() }
      while !job.isCancelled {
        let count = input.read(buffer, maxLength: 64 * 1024)
        if count < 0 { return sink.finish(error: input.streamError ?? UploadImportError.reason("read_failed"), mime: "") }
        if count == 0 { break }
        sink.append(Data(bytes: buffer, count: count))
        if sink.failed { break }
      }
      return sink.finish(error: nil, mime: mime(type ?? metadata.typeIdentifier ?? "public.data"))
    } catch { return .failure(error) }
  }

  private func makeSink(name: String, job: UploadImportJob) throws -> UploadImportSink {
    guard !job.isCancelled else { throw UploadImportError.reason("cancelled") }
    let uploadRoot = try root()
    let imports = uploadRoot.appendingPathComponent("imports", isDirectory: true)
    guard imports.resolvingSymlinksInPath().standardizedFileURL.path == imports.path else { throw UploadImportError.reason("storage") }
    let directory = imports.appendingPathComponent(job.id, isDirectory: true)
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else { throw UploadImportError.reason("storage") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let suffix = (name as NSString).pathExtension.lowercased()
    let validSuffix = suffix.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil ? suffix : "bin"
    let destination = directory.appendingPathComponent(UUID().uuidString.lowercased() + "." + validSuffix)
    let sink = try UploadImportSink(destination: destination, relativePath: "imports/\(job.id)/\(destination.lastPathComponent)",
        displayName: String(name.prefix(512)), remainingBytes: maxBytes - job.bytes, cancelled: { [weak job] in job?.isCancelled ?? true },
        hasSpace: { [weak self] bytes in
          guard let self = self else { return false }
          return (try? self.availableBytes()).map { $0 > self.reserve + Int64(bytes) } ?? false
        })
    job.setSink(sink)
    return sink
  }

  private func accept(_ outcome: Result<[String: Any], Error>, name: String, job: UploadImportJob) {
    switch outcome {
    case .success(let file): job.files.append(file); job.bytes += file["size"] as? Int64 ?? 0
    case .failure(let error):
      if !job.isCancelled { job.errors.append(["displayName": String(name.prefix(512)), "reason": reason(error)]) }
    }
  }

  private func reason(_ error: Error) -> String {
    if let failure = error as? UploadImportError {
      switch failure { case .reason(let value): return value }
    }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return "insufficient_storage" }
    return "read_failed"
  }

  private func mime(_ identifier: String) -> String {
    if #available(iOS 14, *) { return UTType(identifier)?.preferredMIMEType ?? "application/octet-stream" }
    return UTTypeCopyPreferredTagWithClass(identifier as CFString, kUTTagClassMIMEType)?.takeRetainedValue() as String? ?? "application/octet-stream"
  }

  private func isImageType(_ identifier: String) -> Bool {
    if #available(iOS 14, *) { return UTType(identifier)?.conforms(to: .image) == true }
    return UTTypeConformsTo(identifier as CFString, kUTTypeImage)
  }

  private func isRawType(_ identifier: String) -> Bool {
    if #available(iOS 14, *) { return UTType(identifier)?.conforms(to: .rawImage) == true }
    return UTTypeConformsTo(identifier as CFString, kUTTypeRawImage)
  }

  private func root() throws -> URL {
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .resolvingSymlinksInPath().standardizedFileURL
    var url = documents.appendingPathComponent("uploads", isDirectory: true)
    guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else { throw UploadImportError.reason("storage") }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    return url
  }

  private func availableBytes() throws -> Int64 {
    let values = try FileManager.default.attributesOfFileSystem(forPath: root().path)
    guard let value = values[.systemFreeSize] as? NSNumber else { throw UploadImportError.reason("storage") }
    return value.int64Value
  }

  private func cancel() {
    guard let job = pending else { return }
    job.cancel()
    if let request = job.resourceRequest { PHAssetResourceManager.default().cancelDataRequest(request) }
    job.providerProgress?.cancel()
    picker?.dismiss(animated: true); picker = nil
    finish(job)
  }

  private func finish(_ job: UploadImportJob) {
    guard pending === job, !job.finishing else { return }
    job.finishing = true
    if job.isCancelled {
      work.async {
        if let directory = try? self.root().appendingPathComponent("imports", isDirectory: true).appendingPathComponent(job.id, isDirectory: true),
            directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path {
          // The directory name is generated internally; no caller path enters cleanup.
          try? FileManager.default.removeItem(at: directory)
        }
        DispatchQueue.main.async {
          guard self.pending === job else { return }
          self.pending = nil
          job.result(["cancelled": true, "files": [], "errors": []])
        }
      }
    } else {
      pending = nil
      job.result(["cancelled": false, "files": job.files, "errors": job.errors])
    }
  }
}

@available(iOS 14, *)
extension UploadFileImporter: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard self.picker === picker, let job = pending, !job.copying else { return }
    picker.dismiss(animated: true)
    self.picker = nil
    if results.isEmpty { job.cancel(); finish(job); return }
    job.copying = true
    importProviders(results, at: 0, job: job)
  }

  private func importProviders(_ results: [PHPickerResult], at index: Int, job: UploadImportJob) {
    guard pending === job else { return }
    guard index < results.count, !job.isCancelled else { finish(job); return }
    let provider = results[index].itemProvider
    let name = provider.suggestedName ?? ""
    if provider.canLoadObject(ofClass: PHLivePhoto.self) {
      job.errors.append(["displayName": name, "reason": "live_photo_requires_conversion"])
      DispatchQueue.main.async { self.importProviders(results, at: index + 1, job: job) }; return
    }
    if provider.registeredTypeIdentifiers.contains(where: { isRawType($0) }) {
      job.errors.append(["displayName": name, "reason": "unsupported_format"])
      DispatchQueue.main.async { self.importProviders(results, at: index + 1, job: job) }; return
    }
    guard let type = provider.registeredTypeIdentifiers.first(where: { isImageType($0) && !isRawType($0) }) else {
      job.errors.append(["displayName": name, "reason": "unsupported_format"])
      DispatchQueue.main.async { self.importProviders(results, at: index + 1, job: job) }; return
    }
    job.providerProgress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
      // The provider deletes its temporary URL when this callback returns.
      let outcome: Result<[String: Any], Error>
      if let url = url {
        let selectedName = name.isEmpty ? url.lastPathComponent : ((name as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? name + "." + url.pathExtension : name)
        outcome = self.work.sync { self.copy(url: url, name: selectedName, type: type, job: job) }
      }
      else { outcome = .failure(error ?? UploadImportError.reason("read_failed")) }
      DispatchQueue.main.async {
        guard self.pending === job else { return }
        job.providerProgress = nil
        self.accept(outcome, name: name, job: job)
        self.importProviders(results, at: index + 1, job: job)
      }
    }
  }
}

private enum UploadImportError: Error { case reason(String) }

private final class UploadImportJob {
  let id = UUID().uuidString.lowercased()
  let result: FlutterResult
  private let lock = NSLock()
  private var cancelled = false
  private var sink: UploadImportSink?
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() { lock.lock(); cancelled = true; let current = sink; lock.unlock(); current?.cancel() }
  func setSink(_ value: UploadImportSink) { lock.lock(); sink = value; let cancelNow = cancelled; lock.unlock(); if cancelNow { value.cancel() } }
  var copying = false
  var finishing = false
  var files: [[String: Any]] = []
  var errors: [[String: String]] = []
  var bytes: Int64 = 0
  var resourceRequest: PHAssetResourceDataRequestID?
  var providerProgress: Progress?
  init(result: @escaping FlutterResult) { self.result = result }
}

/// A bounded, synchronized disk sink for PhotoKit chunks and document streams.
final class UploadImportSink {
  let destination: URL
  let partial: URL
  let relativePath: String
  let displayName: String
  let limit: Int64
  let cancelled: () -> Bool
  let hasSpace: (Int) -> Bool
  private let lock = NSLock()
  private let output: OutputStream
  private var size: Int64 = 0
  private var error: Error?
  var failed: Bool { lock.lock(); defer { lock.unlock() }; return error != nil }

  init(destination: URL, relativePath: String, displayName: String, remainingBytes: Int64,
       cancelled: @escaping () -> Bool, hasSpace: @escaping (Int) -> Bool) throws {
    self.destination = destination
    partial = destination.appendingPathExtension("part")
    self.relativePath = relativePath; self.displayName = displayName; limit = remainingBytes
    self.cancelled = cancelled; self.hasSpace = hasSpace
    guard FileManager.default.createFile(atPath: partial.path, contents: nil,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]),
          let stream = OutputStream(url: partial, append: false) else { throw UploadImportError.reason("write_failed") }
    output = stream; output.open()
  }

  func append(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    guard error == nil else { return }
    guard !cancelled() else { error = UploadImportError.reason("cancelled"); return }
    guard Int64(data.count) <= limit - size else { error = UploadImportError.reason("selection_too_large"); return }
    guard hasSpace(data.count) else { error = UploadImportError.reason("insufficient_storage"); return }
    data.withUnsafeBytes { raw in
      guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      var written = 0
      while written < data.count {
        if cancelled() { error = UploadImportError.reason("cancelled"); break }
        let count = output.write(bytes.advanced(by: written), maxLength: data.count - written)
        if count <= 0 { error = output.streamError ?? UploadImportError.reason("write_failed"); break }
        written += count; size += Int64(count)
      }
    }
  }

  func cancel() {
    lock.lock(); defer { lock.unlock() }
    error = UploadImportError.reason("cancelled")
    output.close()
    try? FileManager.default.removeItem(at: partial)
  }

  func finish(error externalError: Error?, mime: String) -> Result<[String: Any], Error> {
    lock.lock(); defer { lock.unlock() }
    output.close()
    let finalError: Error? = cancelled() ? UploadImportError.reason("cancelled") : error ?? externalError
    if let finalError = finalError { try? FileManager.default.removeItem(at: partial); return .failure(finalError) }
    do {
      try FileManager.default.moveItem(at: partial, to: destination)
      return .success(["relativePath": relativePath, "displayName": displayName.isEmpty ? destination.lastPathComponent : displayName,
                       "size": size, "mimeType": mime])
    } catch { try? FileManager.default.removeItem(at: partial); return .failure(error) }
  }
}

/// PhotoKit-backed ordered multi-selection for the supported iOS 12/13 baseline.
private final class UploadLegacyPhotoPicker: UICollectionViewController {
  private let maxSelection: Int
  private let chinese: Bool
  private let completion: ([PHAsset]?) -> Void
  private let assets: PHFetchResult<PHAsset>
  private let images = PHCachingImageManager()
  private var selected: [Int] = []
  private var completed = false

  init(maxSelection: Int, chinese: Bool, completion: @escaping ([PHAsset]?) -> Void) {
    self.maxSelection = maxSelection; self.chinese = chinese; self.completion = completion
    let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    assets = PHAsset.fetchAssets(with: .image, options: options)
    let layout = UICollectionViewFlowLayout(); layout.minimumInteritemSpacing = 2; layout.minimumLineSpacing = 2
    super.init(collectionViewLayout: layout)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = chinese ? "选择图片" : "Choose photos"
    collectionView.backgroundColor = .white
    collectionView.register(UploadPhotoCell.self, forCellWithReuseIdentifier: "photo")
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    updateDone()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let layout = collectionViewLayout as? UICollectionViewFlowLayout {
      let width = max(1, (collectionView.bounds.width - 6) / 4)
      if layout.itemSize.width != width { layout.itemSize = CGSize(width: width, height: width) }
    }
  }
  override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }
  override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! UploadPhotoCell
    let asset = assets.object(at: indexPath.item)
    cell.assetIdentifier = asset.localIdentifier
    cell.image.image = nil
    let order = selected.firstIndex(of: indexPath.item)
    cell.number.text = order.map { String($0 + 1) } ?? (asset.mediaSubtypes.contains(.photoLive) ? "LIVE" : "")
    cell.number.backgroundColor = order == nil ? UIColor.black.withAlphaComponent(0.5) : .blue
    let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .opportunistic
    images.requestImage(for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill, options: options) { [weak cell] image, _ in
      DispatchQueue.main.async { if cell?.assetIdentifier == asset.localIdentifier { cell?.image.image = image } }
    }
    cell.isAccessibilityElement = true
    cell.accessibilityLabel = (chinese ? "图片 " : "Photo ") + String(indexPath.item + 1)
    cell.accessibilityValue = order.map { (chinese ? "已选择，第 " : "Selected, order ") + String($0 + 1) } ?? (chinese ? "未选择" : "Not selected")
    cell.accessibilityTraits = order == nil ? [.button] : [.button, .selected]
    return cell
  }
  override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let asset = assets.object(at: indexPath.item)
    if asset.mediaSubtypes.contains(.photoLive) {
      let alert = UIAlertController(title: chinese ? "实况照片" : "Live Photo",
          message: chinese ? "请先导出所需的静态图片。应用不会自动丢弃动态内容。" : "Export the still image you want first. The app does not silently discard motion.", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: chinese ? "确定" : "OK", style: .default)); present(alert, animated: true); return
    }
    if let existing = selected.firstIndex(of: indexPath.item) { selected.remove(at: existing) }
    else if selected.count < maxSelection { selected.append(indexPath.item) }
    collectionView.reloadData(); updateDone()
  }
  private func updateDone() {
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: (chinese ? "添加" : "Add") + " (\(selected.count))", style: .done, target: self, action: #selector(done))
    navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
  }
  @objc private func cancel() { guard !completed else { return }; completed = true; completion(nil) }
  @objc private func done() { guard !completed else { return }; completed = true; completion(selected.map { assets.object(at: $0) }) }
}

private final class UploadPhotoCell: UICollectionViewCell {
  let image = UIImageView()
  let number = UILabel()
  var assetIdentifier: String?
  override init(frame: CGRect) {
    super.init(frame: frame)
    image.contentMode = .scaleAspectFill; image.clipsToBounds = true
    number.textColor = .white; number.textAlignment = .center; number.font = .boldSystemFont(ofSize: 13)
    contentView.addSubview(image); contentView.addSubview(number)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layoutSubviews() {
    super.layoutSubviews(); image.frame = contentView.bounds
    number.frame = CGRect(x: max(0, contentView.bounds.width - 42), y: 2, width: 40, height: 24)
  }
}
