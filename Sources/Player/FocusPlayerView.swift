//
//  FocusPlayerView.swift
//  SolaPraise
//
//  A real YouTube IFrame Player API embed, with a JS→Swift message bridge.
//
//  Two defects in PraiseTheLord's YouTubePlayerView are fixed here:
//    1. It had no JS bridge at all, so ENDED was unobservable.
//    2. Its updateUIView reloaded the whole HTML string on every SwiftUI
//       update, restarting playback. Here, changing the video calls
//       loadVideoById on the live player instead.
//

import SwiftUI
import WebKit

struct FocusPlayerView: UIViewRepresentable {

    let videoId: String
    var autoplay: Bool = true
    @ObservedObject var coordinator: PlayerCoordinator

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(coordinator, name: PlayerCoordinator.messageName)

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

        // Serve the player over loopback HTTP so the frame has a real origin
        // AND sends a Referer. Neither loadHTMLString(baseURL:) nor
        // loadSimulatedRequest provides a Referer, and without one YouTube
        // rejects the embed with the 152/153 family — which surfaces as the
        // misleading "owner doesn't allow embedding" even for videos that are
        // demonstrably embeddable. See LocalPlayerServer for the evidence.
        // Use "localhost", NOT "127.0.0.1". YouTube treats them differently:
        // some channels' videos (성서유니온 among them) return error 150 and
        // render "This video is unavailable" for a raw-IP origin, while the
        // identical page served as localhost plays. Verified side by side on
        // the same server with only the hostname changed.
        context.coordinator.fallbackHTML = { Self.html(videoId: videoId, autoplay: autoplay) }
        context.coordinator.load(videoId: videoId, autoplay: autoplay, into: web)

        web.navigationDelegate = context.coordinator
        coordinator.webView = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        // Only act on an actual video change, and swap it in-place rather than
        // reloading the document — reloading is what restarted playback before.
        guard context.coordinator.loadedVideoId != videoId else { return }
        context.coordinator.loadedVideoId = videoId
        coordinator.load(videoId: videoId)
    }

    func makeCoordinator() -> Box { Box() }

    /// The URL that serves one video from the loopback server.
    static func playerURL(port: UInt16, videoId: String, autoplay: Bool) -> URL? {
        URL(string: "http://localhost:\(port)/player.html?v=\(videoId)&autoplay=\(autoplay ? 1 : 0)")
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Box) {
        // The userContentController holds the handler strongly; without this
        // the PlayerCoordinator leaks for the life of the process.
        web.configuration.userContentController
            .removeScriptMessageHandler(forName: PlayerCoordinator.messageName)
        web.stopLoading()
    }

    /// Tracks which video the live player currently holds, and catches a
    /// failed load of the loopback page.
    final class Box: NSObject, WKNavigationDelegate {
        var loadedVideoId: String?
        var autoplay = true
        var fallbackHTML: (() -> String)?
        private var hasRetried = false

        func load(videoId: String, autoplay: Bool, into web: WKWebView) {
            loadedVideoId = videoId
            self.autoplay = autoplay
            hasRetried = false
            serve(videoId: videoId, into: web)
        }

        private func serve(videoId: String, into web: WKWebView) {
            if let port = LocalPlayerServer.shared.start(),
               let url = FocusPlayerView.playerURL(port: port, videoId: videoId, autoplay: autoplay) {
                web.load(URLRequest(url: url))
            } else {
                loadFallback(into: web)
            }
        }

        private func loadFallback(into web: WKWebView) {
            guard let html = fallbackHTML?() else { return }
            // Last resort if the loopback listener could not start. Without a
            // Referer YouTube rejects many embeds, so this plays less than the
            // server path does — but a degraded player beats a black screen.
            web.loadSimulatedRequest(
                URLRequest(url: URL(string: "https://www.youtube.com/embed")!),
                responseHTML: html
            )
        }

        /// A refused connection to the loopback port produces no error page —
        /// just a black view, which is what a stale port looked like. Rebuild
        /// the server once and try again before falling back.
        func webView(_ web: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard let videoId = loadedVideoId, !hasRetried else {
                loadFallback(into: web)
                return
            }
            hasRetried = true
            LocalPlayerServer.shared.stop()
            serve(videoId: videoId, into: web)
        }
    }

    // MARK: - Player document

    private static func html(videoId: String, autoplay: Bool) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <style>
            html, body { margin:0; padding:0; background:#000; width:100%; height:100%; overflow:hidden; }
            #player { width:100%; height:100%; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            var player = null;
            var ticker = null;

            function post(payload) {
              try {
                window.webkit.messageHandlers.\(PlayerCoordinator.messageName).postMessage(payload);
              } catch (e) {}
            }

            function safeDuration() {
              try { return player && player.getDuration ? player.getDuration() : 0; }
              catch (e) { return 0; }
            }

            function startTicker() {
              if (ticker) { clearInterval(ticker); }
              ticker = setInterval(function () {
                try {
                  if (player && player.getCurrentTime) {
                    post({ event: 'time', t: player.getCurrentTime(), duration: safeDuration() });
                  }
                } catch (e) {}
              }, 1000);
            }

            post({
              event: 'diag',
              origin: String(location.origin),
              href: String(location.href),
              referrer: String(document.referrer),
              hasYT: (typeof YT !== 'undefined')
            });

            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                videoId: '\(videoId)',
                playerVars: {
                  playsinline: 1,
                  controls: 1,
                  modestbranding: 1,
                  rel: 0,
                  iv_load_policy: 3,
                  fs: 1,
                  enablejsapi: 1,
                  autoplay: \(autoplay ? 1 : 0),
                  origin: 'https://www.youtube.com'
                },
                events: {
                  onReady: function (e) {
                    post({ event: 'ready', duration: safeDuration() });
                    startTicker();
                  },
                  onStateChange: function (e) {
                    post({ event: 'state', state: e.data, duration: safeDuration() });
                  },
                  onError: function (e) {
                    post({ event: 'error', code: e.data });
                  }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }
}
