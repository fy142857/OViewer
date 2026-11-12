import Foundation
import Flutter
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers

/// Explicit, same-dimension conversion into a new protected PNG copy.
final class UploadImageConversion {
  private let worker = DispatchQueue(label: "oviewer.upload.convert")
  private var busy = false
  private let rootOverride: URL?

  init(root: URL? = nil) { rootOverride = root }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "convert" else { result(FlutterMethodNotImplemented); return }
    guard !busy else { result(FlutterError(code: "busy", message: "A conversion is already running", details: nil)); return }
    guard let path = (call.arguments as? [String: Any])?["relativePath"] as? String else {
      result(FlutterError(code: "unsafe_path", message: "Select an imported image", details: nil)); return
    }
    busy = true
    worker.async {
      do {
        let value = try self.convert(path)
        DispatchQueue.main.async { self.busy = false; result(value) }
      } catch {
        let code: String
        if let failure = error as? UploadTransferFailure { code = failure.code } else { code = "conversion_failed" }
        DispatchQueue.main.async { self.busy = false; result(FlutterError(code: code, message: "The selected image could not be converted safely", details: nil)) }
      }
    }
  }

  func convert(_ relativePath: String) throws -> [String: Any] {
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).resolvingSymlinksInPath().standardizedFileURL
    let root: URL
    if let override = rootOverride {
      root = override.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(override.lastPathComponent, isDirectory: true).standardizedFileURL
    } else { root = documents.appendingPathComponent("uploads", isDirectory: true) }
    guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
      throw UploadTransferFailure.reason("unsafe_path")
    }
    guard relativePath.hasPrefix("imports/"), !relativePath.contains("\\"),
          !relativePath.contains(":"), !relativePath.contains("\0") else { throw UploadTransferFailure.reason("unsafe_path") }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw UploadTransferFailure.reason("unsafe_path") }
    var sourceURL = root
    for component in components {
      sourceURL.appendPathComponent(String(component))
      let values = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw UploadTransferFailure.reason("unsafe_path") }
    }
    let sourceMetadata = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard sourceMetadata.isRegularFile == true else { throw UploadTransferFailure.reason("unsafe_path") }
    let sourceSize = sourceMetadata.fileSize ?? 0
    guard sourceSize > 0, sourceSize <= 100_000_000,
          let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw UploadTransferFailure.reason("unsupported_conversion") }
    guard width >= 100, height >= 100, width <= 20000, height <= 20000 else { throw UploadTransferFailure.reason("image_dimensions") }
    let maximumPixels = min(UInt64(24_000_000), ProcessInfo.processInfo.physicalMemory / 64)
    guard UInt64(width) * UInt64(height) <= maximumPixels else { throw UploadTransferFailure.reason("conversion_memory_limit") }
    // Always decode from the full image. The limit equals the source dimension,
    // so this applies EXIF orientation without reducing the pixel dimensions.
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary) else { throw UploadTransferFailure.reason("conversion_failed") }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let swapped = (5...8).contains(orientation)
    guard image.width == (swapped ? height : width), image.height == (swapped ? width : height) else {
      throw UploadTransferFailure.reason("conversion_dimensions_changed")
    }
    let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
    guard let available = free?.int64Value, available >= 82_000_000 else { throw UploadTransferFailure.reason("insufficient_storage") }
    let group = UUID().uuidString
    var directory = root.appendingPathComponent("imports", isDirectory: true).appendingPathComponent(group, isDirectory: true)
    let partial = directory.appendingPathComponent("converted.png.part")
    let output = directory.appendingPathComponent("converted.png")
    var succeeded = false
    var created = false
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else {
      throw UploadTransferFailure.reason("unsafe_path")
    }
    defer { if created && !succeeded { try? FileManager.default.removeItem(at: directory) } }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    created = true
    var backup = URLResourceValues(); backup.isExcludedFromBackup = true
    try directory.setResourceValues(backup)
    let pngType: CFString
    if #available(iOS 14, *) { pngType = UTType.png.identifier as CFString }
    else { pngType = kUTTypePNG }
    guard FileManager.default.createFile(atPath: partial.path, contents: nil,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]),
          let destination = CGImageDestinationCreateWithURL(partial as CFURL, pngType, 1, nil) else {
      throw UploadTransferFailure.reason("storage")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw UploadTransferFailure.reason("conversion_failed") }
    let size = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 50_000_000 else { throw UploadTransferFailure.reason("image_too_large") }
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: partial.path)
    try FileManager.default.moveItem(at: partial, to: output)
    succeeded = true
    return ["relativePath": "imports/\(group)/converted.png", "displayName": "converted.png", "size": size, "mimeType": "image/png"]
  }
}
