import Flutter
import UIKit
import WebKit

/// A login-only WKWebView without the legacy plugin's all-frame JS wrappers.
/// Keep WebKit's native UA, navigation policy and persistent cookie store.
final class LoginWebViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        return LoginWebView(frame: frame, viewId: viewId,
                            arguments: args as? [String: Any], messenger: messenger)
    }
}

private final class LoginCookieObserver: NSObject, WKHTTPCookieStoreObserver {
    weak var owner: LoginWebView?

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        owner?.cookiesDidChange()
    }
}

final class LoginWebView: NSObject, FlutterPlatformView, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let channel: FlutterMethodChannel
    private let cookieObserver = LoginCookieObserver()

    init(frame: CGRect, viewId: Int64, arguments: [String: Any]?,
         messenger: FlutterBinaryMessenger) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        // Also used by flutter_inappwebview's CookieManager and settings pages.
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: frame, configuration: configuration)
        channel = FlutterMethodChannel(name: "oviewer/login-webview/\(viewId)",
                                       binaryMessenger: messenger)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        cookieObserver.owner = self
        configuration.websiteDataStore.httpCookieStore.add(cookieObserver)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "disposed", message: "Login view closed", details: nil))
                return
            }
            if call.method == "reload" {
                self.webView.reload()
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
        if let value = arguments?["url"] as? String, let url = URL(string: value),
           url.scheme == "https", url.host == "forums.e-hentai.org" {
            webView.load(URLRequest(url: url))
        }
    }

    func view() -> UIView { return webView }

    func cookiesDidChange() {
        channel.invokeMethod("onCookiesChanged", arguments: ["url": webView.url?.absoluteString ?? ""])
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        channel.invokeMethod("onLoadStart", arguments: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        channel.invokeMethod("onLoadStop", arguments: ["url": webView.url?.absoluteString ?? ""])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        // Redirect cancellation is normal during a challenge/login flow.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        channel.invokeMethod("onLoadError", arguments: nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    deinit {
        channel.setMethodCallHandler(nil)
        webView.configuration.websiteDataStore.httpCookieStore.remove(cookieObserver)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}
