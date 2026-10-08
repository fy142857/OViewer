import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  private let pageExporter = PageImageExporter()
  private let sponsorExporter = PageImageExporter(allowConcurrent: true)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "OViewerReleaseLink") {
      FlutterMethodChannel(name: "oviewer/release_link", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in
          guard call.method == "open" else { result(FlutterMethodNotImplemented); return }
          guard let value = call.arguments as? String,
                let url = URL(string: value),
                let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                parts.scheme == "https", parts.host == "github.com",
                parts.user == nil, parts.password == nil,
                parts.port == nil || parts.port == 443,
                parts.query == nil, parts.fragment == nil,
                parts.path.range(of: "^/fy142857/OViewer/releases/tag/[^/]+$", options: .regularExpression) != nil
          else { result(false); return }
          UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
        }
    }
    if let registrar = registrar(forPlugin: "OViewerLoginWebView") {
      registrar.register(LoginWebViewFactory(messenger: registrar.messenger()),
                         withId: "oviewer/login-webview")
    }
    if let registrar = registrar(forPlugin: "OViewerPageImageExporter") {
      FlutterMethodChannel(name: "oviewer/page_image_export", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { [weak self] call, result in self?.pageExporter.handle(call, result: result) }
    }
    if let registrar = registrar(forPlugin: "OViewerSponsor") {
      FlutterMethodChannel(name: "oviewer/sponsor", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { [weak self] call, result in
          if call.method == "saveImage" {
            guard let name = (call.arguments as? [String: Any])?["name"] as? String,
                  name.range(of: "^OViewer_sponsor_(wechat_[0-9]+\\.png|alipay_[0-9]+\\.jpg)$", options: .regularExpression) != nil
            else { result("save_failed"); return }
            self?.sponsorExporter.handle(call, result: result)
          } else if call.method == "openApp" {
            let scheme: String
            switch call.arguments as? String {
            case "wechat": scheme = "weixin://"
            case "alipay": scheme = "alipays://"
            default: result(false); return
            }
            guard let url = URL(string: scheme), UIApplication.shared.canOpenURL(url)
            else { result(false); return }
            UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
          } else { result(FlutterMethodNotImplemented) }
        }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
