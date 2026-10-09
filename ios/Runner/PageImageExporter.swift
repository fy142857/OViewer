import Flutter
import Photos
import ImageIO
import UserNotifications

final class PageImageExporter {
  private var busy = false
  private let allowConcurrent: Bool
  private let onSaved: ((String) -> Void)?

  init(allowConcurrent: Bool = false, onSaved: ((String) -> Void)? = nil) {
    self.allowConcurrent = allowConcurrent
    self.onSaved = onSaved
  }

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
      DispatchQueue.main.async {
        self.busy = false
        if status == "saved", let message = args["successMessage"] as? String {
          self.onSaved?(message)
        }
        result(status)
      }
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

// Local notifications are independent of Photos and wallet launch completion.
final class SponsorNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private var preparing = false
  private var waiters: [(Bool) -> Void] = []
  private var pendingMessages: [String] = []

  func prepare(_ completion: @escaping (Bool) -> Void) {
    waiters.append(completion)
    guard !preparing else { return }
    preparing = true
    center.getNotificationSettings { settings in
      if settings.authorizationStatus == .notDetermined {
        self.center.requestAuthorization(options: [.alert]) { allowed, _ in
          self.finish(allowed)
        }
      } else {
        self.finish(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
      }
    }
  }

  private func finish(_ allowed: Bool) {
    DispatchQueue.main.async {
      self.preparing = false
      let callbacks = self.waiters
      self.waiters.removeAll()
      let messages = self.pendingMessages
      self.pendingMessages.removeAll()
      callbacks.forEach { $0(allowed) }
      if allowed { messages.forEach { self.post($0) } }
    }
  }

  func show(_ message: String) {
    guard !message.isEmpty else { return }
    if preparing { pendingMessages.append(message); return }
    center.getNotificationSettings { settings in
      if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
        self.post(message)
      }
    }
  }

  private func post(_ message: String) {
    let content = UNMutableNotificationContent()
    content.title = "OViewer"
    content.body = message
    let request = UNNotificationRequest(identifier: "oviewer.sponsor.saved." + UUID().uuidString,
        content: content, trigger: nil)
    center.add(request) { _ in /* Delivery failures never change the image save result. */ }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    guard notification.request.identifier.hasPrefix("oviewer.sponsor.saved.")
    else { completionHandler([]); return }
    if #available(iOS 14, *) { completionHandler([.banner, .list]) }
    else { completionHandler([.alert]) }
  }

}
