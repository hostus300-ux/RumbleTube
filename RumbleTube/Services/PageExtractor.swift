import Foundation
import UIKit
import WebKit

/// Loads a rumble.com listing page in a hidden WKWebView (so client-rendered grids render too),
/// then runs the bundled extract.js to pull out the videos. Images, media and fonts are blocked to keep it fast.
@MainActor
final class PageExtractor: NSObject {
    static let shared = PageExtractor()

    enum ExtractError: LocalizedError {
        case timeout, loadFailed(String)
        var errorDescription: String? {
            switch self {
            case .timeout: return "Rumble took too long to respond."
            case .loadFailed(let m): return m
            }
        }
    }

    private lazy var script: String = {
        guard let url = Bundle.main.url(forResource: "extract", withExtension: "js"),
              let s = try? String(contentsOf: url) else { return "JSON.stringify({items:[],hasNext:false})" }
        return s
    }()

    private var rules: WKContentRuleList?
    private var rulesLoaded = false
    private var slots = 3

    private static let ruleJSON = """
    [{"trigger":{"url-filter":".*","resource-type":["image","media","font","style-sheet"]},"action":{"type":"block"}},
     {"trigger":{"url-filter":"(doubleclick|googlesyndication|googletagmanager|google-analytics|amazon-adsystem|adnxs|taboola|outbrain|criteo)"},"action":{"type":"block"}}]
    """

    private func loadRules() async {
        guard !rulesLoaded else { return }
        rulesLoaded = true
        rules = await withCheckedContinuation { cont in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "rt-extract-v1", encodedContentRuleList: Self.ruleJSON) { list, _ in
                cont.resume(returning: list)
            }
        }
    }

    private func acquire() async {
        while slots == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
        slots -= 1
    }
    private func release() { slots += 1 }

    /// Extract the listing on `url`.
    func extract(_ url: URL, timeout: TimeInterval = 18) async throws -> ListingPage {
        let json = try await withWebView(url, timeout: timeout) { web, finished, elapsedSinceFinish in
            guard let raw = try? await web.evaluateJavaScript(self.script) as? String,
                  let page = try? JSONDecoder().decode(ListingPage.self, from: Data(raw.utf8)) else { return nil }
            if !page.items.isEmpty { return raw }
            if page.empty == true || (finished && elapsedSinceFinish > 5) { return raw }
            return nil
        }
        return try JSONDecoder().decode(ListingPage.self, from: Data(json.utf8))
    }

    /// Fallback for pages URLSession can't fetch: the rendered HTML.
    func html(_ url: URL, timeout: TimeInterval = 15) async throws -> String {
        try await withWebView(url, timeout: timeout) { web, finished, _ in
            guard finished else { return nil }
            return try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        }
    }

    // MARK: - plumbing

    private func withWebView(_ url: URL, timeout: TimeInterval,
                             poll: @escaping (WKWebView, Bool, TimeInterval) async -> String?) async throws -> String {
        await loadRules()
        await acquire()
        defer { release() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = false
        if let rules { config.userContentController.add(rules) }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = RumbleHTTP.userAgent
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        let tracker = NavTracker()
        web.navigationDelegate = tracker
        // Keep it in the window so its timers aren't throttled.
        let host = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        host?.insertSubview(web, at: 0)
        defer { web.stopLoading(); web.removeFromSuperview() }

        web.load(URLRequest(url: url))
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 450_000_000)
            if let err = tracker.error { throw ExtractError.loadFailed(err) }
            let sinceFinish = tracker.finishedAt.map { Date().timeIntervalSince($0) } ?? 0
            if let result = await poll(web, tracker.finishedAt != nil, sinceFinish) { return result }
        }
        throw ExtractError.timeout
    }

    private final class NavTracker: NSObject, WKNavigationDelegate {
        var finishedAt: Date?
        var error: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedAt = Date() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.error = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.error = error.localizedDescription
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Stay on rumble.com; never follow app-store / external redirects.
            let host = navigationAction.request.url?.host ?? ""
            decisionHandler(host.hasSuffix("rumble.com") || navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel)
        }
    }
}
