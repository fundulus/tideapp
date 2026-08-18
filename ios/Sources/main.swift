// Fundulus Tides for iOS: the same single-file web app, hosted in a WKWebView.
//
// Shares the macOS shell's core decision: the page is served over a registered
// `tides://` scheme rather than file://, because a file:// page gets an opaque origin
// that WKWebView refuses to make cross-origin fetches from, which would silently kill
// every NOAA station lookup. The Mexican harmonic sites compute in-page and need no
// network, so the app still works offline in the field.
//
// Three things genuinely differ from the Mac:
//   * The page runs edge to edge under the status bar and home indicator, so the web
//     app insets its own chrome using env(safe-area-inset-*).
//   * There is no save panel. The CSV export lands in a temp file and goes out
//     through the system share sheet.
//   * Geolocation needs an Info.plist usage string before iOS will even offer it.

import UIKit
import WebKit
import CoreLocation

private let appScheme = "tides"
private let appOrigin = "tides://app/"

// MARK: - Serving the bundled page

final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        // Serve the document only for the root. The page also links a PWA manifest
        // and a service worker for the web build; neither applies here, and answering
        // them with HTML would hand a manifest parser a page of markup.
        let path = task.request.url?.path ?? "/"
        guard path == "/" || path.isEmpty || path.hasSuffix(".html") else {
            task.didFailWithError(NSError(domain: "Tides", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Not part of the bundled app."]))
            return
        }
        guard let url = task.request.url,
              let file = Bundle.main.url(forResource: "index", withExtension: "html"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: "Tides", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Bundled index.html is missing."]))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8",
                           "Cache-Control": "no-store"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - Location

/// Answers the page's request for a position, from CoreLocation.
///
/// WKWebView does not hand `navigator.geolocation` to a third-party app, so in the shell
/// that API never resolves and the nearest-station button simply spins until it times
/// out. Rather than fight that, the page asks the shell directly and the shell replies.
/// The page keeps using the browser's own API everywhere else, so the web build is
/// untouched.
///
/// This is the same bridge the Mac shell uses, under the same message name, because the
/// page cannot tell the two apart and should not have to. The app also has to declare
/// NSLocationWhenInUseUsageDescription, which build.sh writes into the Info.plist.
final class LocationBridge: NSObject, CLLocationManagerDelegate, WKScriptMessageHandlerWithReply {
    private let manager = CLLocationManager()
    private var pending: [(Any?, String?) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        // A tide station, not a doorstep. Coarse accuracy answers faster, spares the
        // battery, and is plenty to pick the nearest of 3,500 stations.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        pending.append(replyHandler)
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // prompt; picked up by the delegate below
        case .denied, .restricted:
            finish(error: "Location is off for this app. Turn it on in Settings, "
                        + "Privacy & Security, Location Services.")
        default:
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(error: "Location permission was declined.")
        default: if !pending.isEmpty { m.requestLocation() }
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { finish(error: "No position available."); return }
        let handlers = pending; pending = []
        handlers.forEach { $0(["lat": c.latitude, "lng": c.longitude], nil) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        finish(error: error.localizedDescription)
    }

    private func finish(error: String) {
        let handlers = pending; pending = []
        handlers.forEach { $0(nil, error) }
    }
}

// MARK: - Root view controller

final class TidesViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    private var webView: WKWebView!
    private var pendingDownloads: [WKDownload: URL] = [:]
    private let locator = LocationBridge()

    // The app header is dark teal and sits under the status bar, so the clock and
    // indicators need to be light to stay legible.
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: appScheme)
        config.websiteDataStore = .default()      // keeps favourites, units, elevation
        config.allowsInlineMediaPlayback = true
        config.userContentController.addScriptMessageHandler(
            locator, contentWorld: .page, name: "locate")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The page is a fixed application surface, not a document: rubber-banding the
        // whole thing past its edges just looks broken.
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.973, green: 0.973, blue: 0.961, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor

        view.backgroundColor = webView.backgroundColor
        view.addSubview(webView)

        webView.load(URLRequest(url: URL(string: appOrigin)!))
    }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }

        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if url.scheme == appScheme || url.scheme == "blob" || url.scheme == "about" {
            decisionHandler(.allow)
        } else if url.scheme == "http" || url.scheme == "https" {
            // Real web links (CICESE, NOAA) belong in Safari, not inside the app.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // MARK: Downloads (the CSV export)

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: dest)
        pendingDownloads[download] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = pendingDownloads.removeValue(forKey: download) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad presents this as a popover and will trap without an anchor.
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect =
            CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloads.removeValue(forKey: download)
        showError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
    }

    private func showError(_ message: String) {
        let a = UIAlertController(title: "Fundulus Tides", message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}

// MARK: - App entry

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = TidesViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
