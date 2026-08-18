// Tides: native macOS shell around the single-file web app.
//
// The web app is unchanged and unaware it is being hosted: it is served to a
// WKWebView through a custom URL scheme rather than loaded from file://, because a
// file:// page is given an opaque origin that WKWebView refuses to make cross-origin
// fetches from, which would break the NOAA station lookups. A registered scheme
// gives the page a stable origin and normal CORS behaviour.
//
// The Mexican harmonic stations are computed in-page and need no network at all, so
// the app stays useful offline; only the NOAA half requires connectivity.

import Cocoa
import WebKit
import UniformTypeIdentifiers
import CoreLocation

private let appScheme = "tides"
private let appOrigin = "tides://app/"

// MARK: - Serving the bundled page

/// Serves the bundled web app over the custom scheme. Any path resolves to
/// index.html, since the app is a single self-contained document.
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

// MARK: - Downloads (the CSV export)

/// The inundation view exports CSV by clicking an anchor at a blob: URL. WKWebView
/// surfaces that as a download rather than a navigation, so it needs a destination.
final class DownloadHandler: NSObject, WKDownloadDelegate {
    private var pending: [WKDownload: URL] = [:]

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if suggestedFilename.lowercased().hasSuffix(".csv") {
            panel.allowedContentTypes = [.commaSeparatedText]
        }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in
            guard result == .OK, let url = panel.url else { completionHandler(nil); return }
            // WKWebView insists on writing to a path that does not yet exist.
            try? FileManager.default.removeItem(at: url)
            self.pending[download] = url
            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = pending.removeValue(forKey: download) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pending.removeValue(forKey: download)
        NSApp.presentError(error)
    }
}

// MARK: - Window

/// Answers the page's request for a position, from CoreLocation.
///
/// WKWebView does not hand `navigator.geolocation` to a third-party app, so in the shell
/// that API never resolves and the nearest-station button simply did nothing. Rather than
/// fight that, the page asks the shell directly and the shell replies. The page keeps
/// using the browser's own API everywhere else, so the web build is untouched.
///
/// The app also has to declare NSLocationWhenInUseUsageDescription, or macOS will not
/// offer it to Location Services at all and it never appears in System Settings.
final class LocationBridge: NSObject, CLLocationManagerDelegate, WKScriptMessageHandlerWithReply {
    private let manager = CLLocationManager()
    private var pending: [(Any?, String?) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        // A tide station, not a doorstep. Coarse accuracy answers faster and is plenty
        // to pick the nearest of 3,500 stations.
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
            finish(error: "Location is off for this app. Turn it on in System Settings, "
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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let downloads = DownloadHandler()
    private let locator = LocationBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: appScheme)
        config.websiteDataStore = .default()          // keeps localStorage: favourites, units, elevation
        config.userContentController.addScriptMessageHandler(
            locator, contentWorld: .page, name: "locate")
        // The window below uses a full-size content view, which runs the page up under
        // the titlebar and drops the traffic-light buttons on top of the masthead. The
        // page insets itself when it knows it is us. Marked at document start so the
        // first frame is already correct, rather than visibly reflowing once measured.
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.setAttribute('data-shell','mac');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Tides"                  // still the name in Window and Mission Control
        window.titleVisibility = .hidden        // but not drawn across the masthead
        window.titlebarAppearsTransparent = true
        // Match the page background so the window never flashes a different colour
        // while the web view is coming up. Do NOT make the web view transparent to
        // achieve this: with drawsBackground off the page composites away entirely
        // and the window colour is all you see.
        window.backgroundColor = NSColor(red: 0.973, green: 0.973, blue: 0.961, alpha: 1) // #F8F8F5
        window.minSize = NSSize(width: 420, height: 560)
        window.contentView = webView
        window.setFrameAutosaveName("TidesMainWindow")     // remembers size and position
        if window.frame.width < 420 { window.setContentSize(NSSize(width: 1180, height: 900)) }
        window.center()
        window.makeKeyAndOrderFront(nil)

        for event in [NSWindow.didEnterFullScreenNotification,
                      NSWindow.didExitFullScreenNotification,
                      NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: event, object: window,
                                                   queue: .main) { [weak self] _ in
                self?.syncTitlebarInset()
            }
        }

        buildMenu()
        webView.load(URLRequest(url: URL(string: appOrigin)!))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Tells the page how far to hold off the top of the window. Under a full-size
    /// content view the content layout rect is the part of the window below the
    /// titlebar, so the shortfall against the frame is the titlebar itself. This is
    /// measured rather than assumed: it costs nothing, it does not go stale if Apple
    /// changes the height, and it falls out to zero in full screen, where the titlebar
    /// is gone and a hardcoded inset would leave a band of dead teal behind.
    private func syncTitlebarInset() {
        guard let window, let webView else { return }
        let inset = max(0, window.frame.height - window.contentLayoutRect.height)
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--titlebar-inset','"
            + String(Int(inset.rounded())) + "px')")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncTitlebarInset()
    }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // An anchor carrying `download` (the CSV export) becomes a download, not a load.
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }

        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        // Our own page, and blob URLs it creates, stay inside. Anything else is a real
        // web link (CICESE, NOAA) and belongs in the user's browser.
        if url.scheme == appScheme || url.scheme == "blob" || url.scheme == "about" {
            decisionHandler(.allow)
        } else if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSApp.presentError(error)
    }

    // Window.open from the page opens in the browser rather than a blank child window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: Menus

    @objc private func reloadPage() { webView.reload() }
    @objc private func zoomIn()  { webView.pageZoom = min(webView.pageZoom + 0.1, 2.5) }
    @objc private func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.6) }
    @objc private func zoomReset() { webView.pageZoom = 1.0 }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Tides", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tides", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tides", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit is not decoration: the station search and elevation field need
        // cut/copy/paste and select-all to behave like every other Mac text field.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
