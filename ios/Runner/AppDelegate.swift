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
