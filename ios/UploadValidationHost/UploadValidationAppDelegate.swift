import UIKit

/// A separate XCTest host: no Runner AppDelegate, Flutter engine, account state, or networking startup.
@UIApplicationMain
final class UploadValidationAppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    precondition(Bundle.main.bundleIdentifier == "com.oviewer.oviewer.uploadvalidation",
                 "Upload native tests require their isolated validation application.")
    let controller = UIViewController()
    controller.view.backgroundColor = .white
    let label = UILabel()
    label.text = "OViewer Upload Validation"
    label.textColor = .black
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
    ])
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
