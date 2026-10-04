//
//  PlayerCoordinator.swift
//  SolaPraise
//
//  The JS bridge PraiseTheLord's player never had.
//
//  PraiseTheLord/Sources/YouTubePlayerView.swift claims in its header to use
//  the IFrame Player API, but embeds a bare <iframe> with no message handler —
//  so playback state is unobservable and YouTube's end-screen suggestion grid
//  paints freely when a video finishes. Since `rel=0` has only *restricted*
//  suggestions to the same channel since 2018 (it has never disabled them),
//  observing the ENDED state is the only reliable way to stop the grid.
//
//  This coordinator receives player events over WKScriptMessageHandler and
//  publishes them to SwiftUI.
//

import Foundation
import WebKit
import Combine

/// What happens the instant a video reports ENDED.
///
/// This single switch is the whole Track A / Track B difference:
///
/// - `.overlay` — paint an opaque card over the player before the suggestion
///   grid can render. Correct for a personal build; prohibited for a
///   distributed one by YouTube's Developer Policies §III.I.4 / §III.I.6 and
///   the Required Minimum Functionality rules, which forbid obscuring the
///   player or the links inside it.
/// - `.dismiss` — leave the player untouched and pop the screen, returning to
///   the finite feed. Ordinary app navigation, so policy-safe, and it achieves
///   most of the same effect.
enum EndBehavior {
    case overlay
    case dismiss
}

enum SolaPraiseConfig {
    /// Track A. Flip to `.dismiss` before any public distribution.
    static let endBehavior: EndBehavior = .overlay
}

/// Mirrors YT.PlayerState.
enum YTPlayerState: Int {
    case unstarted = -1
    case ended     = 0
    case playing   = 1
    case paused    = 2
    case buffering = 3
    case cued      = 5
}

@MainActor
final class PlayerCoordinator: NSObject, ObservableObject {

    nonisolated static let messageName = "focusTubePlayer"

    @Published private(set) var state: YTPlayerState = .unstarted
    @Published private(set) var isReady = false
    @Published private(set) var didEnd = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    /// True when playback failed because the rights holder disabled embedding
    /// (101/150/152). Nothing in-app can fix that, so the UI offers YouTube.
    @Published private(set) var isEmbedBlocked = false

    /// High-water mark of playback position, used for the watch log. Seeking
    /// backwards must not shrink what we recorded as watched.
    private(set) var maxTimeReached: Double = 0

    /// Owned, not borrowed.
    ///
    /// The web view used to be created by FocusPlayerView and referenced
    /// weakly here, which meant it died with whatever screen was showing it —
    /// fine while the player only ever existed full-screen, and fatal for a
    /// mini player, where moving between presentations would tear the document
    /// down and restart the song. The coordinator builds it once and hands the
    /// same instance to whoever is displaying it.
    private(set) var webView: WKWebView?

    /// What the live player currently holds, so a re-render does not reload.
    private var loadedVideoId: String?
    private var pendingAutoplay = true
    private var hasRetriedLoad = false
    private var readinessWatchdog: Task<Void, Never>?

    /// True when the failure is worth another attempt rather than a hand-off.
    @Published private(set) var canRetryLoad = false

    /// Builds the player document, or returns the one already running.
    func hostedWebView() -> WKWebView {
        if let webView { return webView }

        let controller = WKUserContentController()
        controller.add(self, name: Self.messageName)

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = self

        webView = web
        return web
    }

    /// Shows `videoId`, swapping it inside the live player when one is already
    /// running rather than reloading the document.
    func present(videoId: String, autoplay: Bool) {
        pendingAutoplay = autoplay
        guard loadedVideoId != videoId else { return }
        // A document is only "already running" if the web view that held it
        // still exists. detach() clears that reference, and swapping a video
        // by JavaScript into a view that is gone loaded nothing and reported
        // nothing — a black rectangle with no error to explain it.
        let isFirst = loadedVideoId == nil || webView == nil
        loadedVideoId = videoId
        hasRetriedLoad = false

        if isFirst {
            serve(videoId: videoId)
        } else {
            load(videoId: videoId)
        }
        watchForSilentFailure(videoId: videoId)
    }

    /// Turns an unexplained black player into something a person can act on.
    ///
    /// Every known failure so far — a stale loopback port, a torn-down web
    /// view, a page that never ran its script — looks identical from the
    /// outside: black, no error, no spinner. If the player has not reported
    /// itself ready in a few seconds, say so and offer the way out.
    private func watchForSilentFailure(videoId: String) {
        readinessWatchdog?.cancel()
        readinessWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            guard self.loadedVideoId == videoId, !self.isReady,
                  self.errorMessage == nil else { return }
            self.errorMessage = "영상이 열리지 않습니다. 다시 시도하거나 YouTube에서 열어 보세요."
            self.canRetryLoad = true
        }
    }

    /// Rebuilds the loopback server and the document from scratch.
    func retryLoad() {
        guard let videoId = loadedVideoId else { return }
        errorMessage = nil
        canRetryLoad = false
        isReady = false
        hasRetriedLoad = false
        LocalPlayerServer.shared.stop()
        serve(videoId: videoId)
        watchForSilentFailure(videoId: videoId)
    }

    private func serve(videoId: String) {
        guard webView != nil else { return }
        // Awaited, not blocked on. Starting the server used to sleep the
        // calling thread for up to two seconds — on the main thread, during
        // view construction, which is its own way to produce a black screen.
        Task { @MainActor in
            let port = await LocalPlayerServer.shared.ensureStarted()
            // The user may have moved on while that was starting.
            guard self.loadedVideoId == videoId, let webView = self.webView else { return }

            // Serve over loopback HTTP so the frame has a real origin AND
            // sends a Referer. See LocalPlayerServer for why neither
            // loadHTMLString(baseURL:) nor loadSimulatedRequest is enough.
            if let port,
               let url = URL(string: "http://localhost:\(port)/player.html?v=\(videoId)&autoplay=\(self.pendingAutoplay ? 1 : 0)") {
                webView.load(URLRequest(url: url))
            } else {
                self.loadFallback(videoId: videoId)
            }
        }
    }

    private func loadFallback(videoId: String) {
        guard let webView else { return }
        webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://www.youtube.com/embed")!),
            responseHTML: FocusPlayerView.html(videoId: videoId, autoplay: pendingAutoplay)
        )
    }

    // MARK: - Commands

    func load(videoId: String) {
        didEnd = false
        errorMessage = nil
        isEmbedBlocked = false
        maxTimeReached = 0
        currentTime = 0
        run("player.loadVideoById('\(escape(videoId))');")
    }

    /// Queues without autoplaying — used when the user should press play.
    func cue(videoId: String) {
        didEnd = false
        maxTimeReached = 0
        currentTime = 0
        run("player.cueVideoById('\(escape(videoId))');")
    }

    func play()  { run("player.playVideo();") }
    func pause() { run("player.pauseVideo();") }
    func stop()  { run("player.stopVideo();") }

    func seek(to seconds: Double) {
        run("player.seekTo(\(seconds), true);")
    }

    func replay() {
        didEnd = false
        run("player.seekTo(0, true); player.playVideo();")
    }

    private func run(_ js: String) {
        guard let webView else { return }
        webView.evaluateJavaScript("try { \(js) } catch (e) { }")
    }

    /// Single-quote escaping for ids interpolated into JS.
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
    }

    // MARK: - Teardown

    /// Must be called when the view goes away, or the userContentController
    /// keeps a strong reference to this coordinator forever.
    func detach() {
        readinessWatchdog?.cancel()
        readinessWatchdog = nil
        canRetryLoad = false
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageName)
        webView?.stopLoading()
        webView = nil
        loadedVideoId = nil
        state = .unstarted
        isReady = false
        didEnd = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        isEmbedBlocked = false
    }
}

// MARK: - Navigation

extension PlayerCoordinator: WKNavigationDelegate {

    /// A refused connection to the loopback port produces no error page, just
    /// a black view — which is what a stale port looked like. Rebuild the
    /// server once and retry before falling back.
    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            guard let videoId = self.loadedVideoId else { return }
            guard !self.hasRetriedLoad else {
                self.loadFallback(videoId: videoId)
                return
            }
            self.hasRetriedLoad = true
            LocalPlayerServer.shared.stop()
            self.serve(videoId: videoId)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension PlayerCoordinator: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit delivers these on the main thread, so read them there
        // rather than hopping — a Task defers every player event by a turn,
        // including ENDED, which is the one that has to paint before
        // YouTube's suggestion grid can.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }
            self.handle(event: event, body: body)
        }
    }

    private func handle(event: String, body: [String: Any]) {
        #if DEBUG
        if event != "time" { print("[FocusPlayer] \(event) \(body)") }
        #endif
        switch event {
        case "ready":
            isReady = true
            if let d = body["duration"] as? Double { duration = d }

        case "state":
            let raw = (body["state"] as? Int) ?? -1
            state = YTPlayerState(rawValue: raw) ?? .unstarted
            if let d = body["duration"] as? Double, d > 0 { duration = d }

            if state == .ended {
                // THE critical line. Stop before YouTube can paint its
                // end-screen grid, then let SwiftUI cover the player.
                stop()
                didEnd = true
            }

        case "time":
            if let t = body["t"] as? Double {
                currentTime = t
                maxTimeReached = max(maxTimeReached, t)
            }
            if let d = body["duration"] as? Double, d > 0 { duration = d }

        case "error":
            let code = (body["code"] as? Int) ?? -1
            errorMessage = Self.describeError(code)
            isEmbedBlocked = [101, 150, 152].contains(code)

        default:
            break
        }
    }

    /// YouTube IFrame API error codes.
    private static func describeError(_ code: Int) -> String {
        switch code {
        case 2:            return "That video ID isn't valid."
        case 5:            return "This video can't play in the embedded player."
        case 100:          return "That video was removed or made private."
        case 101, 150, 152:
            // 152 is undocumented but behaves the same: embedded playback is
            // restricted outside youtube.com. Extremely common on CCM uploads.
            return "이 영상은 앱에서 재생할 수 없도록 설정되어 있습니다."
        default:           return "The player hit an unexpected error (\(code))."
        }
    }
}
