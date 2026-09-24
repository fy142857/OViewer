import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "OViewerLoginWebView") {
      registrar.register(LoginWebViewFactory(messenger: registrar.messenger()),
                         withId: "oviewer/login-webview")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
