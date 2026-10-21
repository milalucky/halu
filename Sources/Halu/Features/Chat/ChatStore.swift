import AppKit
import WebKit

/// ChatGPT as its own website in a small browser inside the panel: you sign in there yourself, like in
/// Safari, and use your own subscription. Halu doesn't see or keep the sign-in; the site's cookies live
/// in WebKit's store and survive restarts. One web view stays alive, so a conversation stays put while
/// the panel is closed.
@MainActor
final class ChatStore: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    private static let home = URL(string: "https://chatgpt.com")!
    /// Hosts that belong to ChatGPT and its sign-in; other links open in the default browser.
    private static let hosts = ["chatgpt.com", "openai.com", "auth0.com"]

    @Published private(set) var isLoading = false

    private var view: WKWebView?
    /// Sign-in pages of identity providers stay in the panel (Google, Apple, Microsoft).
    private let signInHosts = ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com"]

    var webView: WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Sites treat it as Safari, which it is underneath.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.uiDelegate = self
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: Self.home))
        self.view = view
        return view
    }

    func goHome() { webView.load(URLRequest(url: Self.home)) }
    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }

    func openInBrowser() {
        NSWorkspace.shared.open(webView.url ?? Self.home)
    }

    private func belongs(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return (Self.hosts + signInHosts).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: WKUIDelegate

    /// Links that want a new window: the site's own (and sign-in) stay here, the rest go to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if belongs(url) { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, !belongs(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
}
