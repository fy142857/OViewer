import Flutter
import Photos
import ImageIO

final class PageImageExporter {
  private var busy = false
  private let allowConcurrent: Bool

  init(allowConcurrent: Bool = false) { self.allowConcurrent = allowConcurrent }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "saveImage" else { result(FlutterMethodNotImplemented); return }
    guard allowConcurrent || !busy else { result("busy"); return }
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let name = args["name"] as? String else { result("save_failed"); return }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL.path + "/"
    // Flutter's temporary directory on iOS is Library/Caches.
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard (url.path.hasPrefix(temporary) || url.path.hasPrefix(caches)),
          FileManager.default.fileExists(atPath: url.path), !name.contains("/"),
          name.hasPrefix("OViewer_") else { result("save_failed"); return }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else { result("unsupported_format"); return }
    busy = true
    let finish: (String) -> Void = { status in
      DispatchQueue.main.async { self.busy = false; result(status) }
    }
    let save = {
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        request.addResource(with: .photo, fileURL: url, options: options)
      }) { success, error in
        if success { finish("saved"); return }
        let failure = error as NSError?
        if failure?.domain == "PHPhotosErrorDomain" && failure?.code == 3302 {
          finish("unsupported_format")
        } else if self.denied() { finish("permission_denied") }
        else { finish("save_failed") }
      }
    }
    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        if status == .authorized || status == .limited { save() }
        else { finish("permission_denied") }
      }
    } else {
      // iOS 12/13 performChanges prompts for add-only access using the plist key.
      if denied() { finish("permission_denied") } else { save() }
    }
  }

  private func denied() -> Bool {
    let status: PHAuthorizationStatus
    if #available(iOS 14, *) { status = PHPhotoLibrary.authorizationStatus(for: .addOnly) }
    else { status = PHPhotoLibrary.authorizationStatus() }
    return status == .denied || status == .restricted
  }
}
