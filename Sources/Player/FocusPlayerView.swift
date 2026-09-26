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

    /// The web view belongs to the coordinator, so the same document survives
    /// being moved between presentations — full screen, mini player, and back.
    func makeUIView(context: Context) -> WKWebView {
        let web = coordinator.hostedWebView()
        coordinator.present(videoId: videoId, autoplay: autoplay)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        coordinator.present(videoId: videoId, autoplay: autoplay)
    }

    // Deliberately no dismantleUIView: the view is reused rather than
    // destroyed, and removing the message handler here would kill the player
    // every time it changed presentation. Teardown is PlayerCoordinator's
    // detach(), called when playback actually ends.

    // MARK: - Player document

    static func html(videoId: String, autoplay: Bool) -> String {
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
