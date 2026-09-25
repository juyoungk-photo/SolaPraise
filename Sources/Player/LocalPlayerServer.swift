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
import UIKit

final class LocalPlayerServer {

    static let shared = LocalPlayerServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "solapraise.playerserver")
    private let lock = NSLock()

    /// Port and readiness move together, under the lock: the port is assigned
    /// on the listener's queue and read from the main thread.
    private var _port: UInt16?
    private var _isReady = false

    var port: UInt16? { lock.withLock { _isReady ? _port : nil } }

    private init() {
        // iOS reclaims network resources while the app is suspended, so an
        // overnight background leaves a listener that is gone while the port
        // it was assigned is still cached. Re-arm on the way back in, off the
        // main thread, so the first tap does not pay for it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { self?.restartIfDead() }
        }
    }

    /// Starts on an OS-assigned free port. Safe to call repeatedly.
    @discardableResult
    func start() -> UInt16? {
        // The old version returned the cached port whenever it had one, with
        // no check that the listener still existed. After a suspension that
        // handed the player a dead port: the page never loaded and the screen
        // stayed black until the app was killed and relaunched, which is
        // exactly what "works again after restarting" was.
        if let live = liveListenerPort() { return live }

        teardown()

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
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.withLock {
                        self._port = listener.port?.rawValue
                        self._isReady = true
                    }
                case .failed, .cancelled:
                    // Without this the port outlived the listener serving it.
                    self.lock.withLock {
                        self._port = nil
                        self._isReady = false
                    }
                default:
                    break
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

    /// The cached port, but only while the listener that owns it is ready.
    private func liveListenerPort() -> UInt16? {
        guard let listener, case .ready = listener.state else { return nil }
        return port
    }

    private func restartIfDead() {
        guard liveListenerPort() == nil else { return }
        _ = start()
    }

    private func teardown() {
        listener?.cancel()
        listener = nil
        lock.withLock {
            _port = nil
            _isReady = false
        }
    }

    func stop() { teardown() }

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
