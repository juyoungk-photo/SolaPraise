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

    static let messageName = "focusTubePlayer"

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

    weak var webView: WKWebView?

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
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageName)
        webView?.stopLoading()
        webView = nil
    }
}

// MARK: - WKScriptMessageHandler

extension PlayerCoordinator: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        Task { @MainActor in
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
