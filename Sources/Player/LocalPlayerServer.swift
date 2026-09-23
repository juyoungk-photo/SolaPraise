//
//  LocalPlayerServer.swift
//  SolaPraise
//
//  A minimal loopback HTTP server that serves the player page.
//
//  WHY THIS EXISTS: YouTube's embed requires the containing frame to have a
//  real origin AND send a Referer header. A WKWebView loaded via
//  `loadHTMLString(baseURL:)` has neither, and `loadSimulatedRequest` gives it
//  a document URL but still no Referer — both produce the 152/153 family of
//  errors, which surface as the misleading "the owner doesn't allow this video
//  to be played in other apps" even on videos that are demonstrably embeddable.
//
//  Verified: this exact player HTML, served over http://localhost, plays
//  코너스톤교회 videos that failed through both WKWebView loading paths.
//
//  This changes nothing about *which* videos may play — a video with embedding
//  disabled still will not play. It only stops us being falsely rejected.
//

import Foundation
import Network

final class LocalPlayerServer {

    static let shared = LocalPlayerServer()

    private var listener: NWListener?
    private(set) var port: UInt16?
    private let queue = DispatchQueue(label: "solapraise.playerserver")

    private init() {}

    /// Starts on an OS-assigned free port. Safe to call repeatedly.
    @discardableResult
    func start() -> UInt16? {
        if let port { return port }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only — never reachable from outside the device.
            params.requiredInterfaceType = .loopback

            let listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = listener.port?.rawValue
                }
            }
            listener.start(queue: queue)
            self.listener = listener

            // The port is assigned asynchronously; wait briefly for it.
            let deadline = Date().addingTimeInterval(2)
            while port == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return port
        } catch {
            return nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            // Only the path matters; the page reads the video id from its query.
            let path = request
                .split(separator: "\r\n").first
                .flatMap { $0.split(separator: " ").dropFirst().first }
                .map(String.init) ?? "/"

            let body = Self.page(for: path)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// The player document. The video id arrives as `?v=…` so one static page
    /// serves every video and swapping songs never reloads the document.
    private static func page(for path: String) -> String {
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
            var player = null, ticker = null;

            function qs(name) {
              var m = new RegExp('[?&]' + name + '=([^&]*)').exec(window.location.search);
              return m ? decodeURIComponent(m[1]) : '';
            }

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

            function onYouTubeIframeAPIReady() {
              post({ event: 'diag', origin: String(location.origin), href: String(location.href) });
              player = new YT.Player('player', {
                videoId: qs('v'),
                playerVars: {
                  playsinline: 1, controls: 1, modestbranding: 1, rel: 0,
                  iv_load_policy: 3, fs: 1, enablejsapi: 1,
                  autoplay: qs('autoplay') === '1' ? 1 : 0,
                  origin: window.location.origin
                },
                events: {
                  onReady: function () { post({ event: 'ready', duration: safeDuration() }); startTicker(); },
                  onStateChange: function (e) { post({ event: 'state', state: e.data, duration: safeDuration() }); },
                  onError: function (e) { post({ event: 'error', code: e.data }); }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }
}
