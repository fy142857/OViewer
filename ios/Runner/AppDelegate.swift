import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  private let pageExporter = PageImageExporter()

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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
