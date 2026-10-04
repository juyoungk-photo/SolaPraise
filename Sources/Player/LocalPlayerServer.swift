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

    /// Which listener the published state belongs to.
    ///
    /// Two starts could overlap — one from the player, one from the
    /// foreground re-arm on a background queue. Both saw no live listener,
    /// both tore down, both built one, and whichever assigned last won while
    /// the loser's port was still handed out. Worse, the loser's `.cancelled`
    /// then arrived AFTER the winner was ready and cleared its port, so a
    /// perfectly good server was marked dead. Both faults were timing, which
    /// is why this failed intermittently and why relaunching fixed it.
    private var generation = 0

    /// Callers waiting for a start already in flight, so a dozen taps make
    /// one server rather than a dozen competing ones.
    private var waiters: [CheckedContinuation<UInt16?, Never>] = []
    private var isStarting = false

    var port: UInt16? { lock.withLock { _isReady ? _port : nil } }

    private init() {
        // iOS reclaims network resources while the app is suspended, so an
        // overnight background leaves a listener that is gone while the port
        // it was assigned is still cached.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.ensureStarted() }
        }
    }

    /// The port of a running server, starting one if needed.
    ///
    /// Async rather than blocking. The old version slept on the calling
    /// thread for up to two seconds waiting for the port — on the main
    /// thread, during view construction, which is its own way to make the
    /// screen go black.
    @discardableResult
    func ensureStarted() async -> UInt16? {
        if let live = liveListenerPort() { return live }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let port = _port, _isReady, listener != nil {
                lock.unlock()
                continuation.resume(returning: port)
                return
            }
            waiters.append(continuation)
            guard !isStarting else { lock.unlock(); return }
            isStarting = true
            generation += 1
            let mine = generation
            lock.unlock()

            queue.async { [weak self] in self?.launch(generation: mine) }
        }
    }

    private func launch(generation mine: Int) {
        listener?.cancel()
        listener = nil

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
                    self.finishStart(generation: mine, port: listener.port?.rawValue)
                case .failed, .cancelled:
                    self.markDead(generation: mine)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener

            // A listener that never reports anything must not strand callers.
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.finishStart(generation: mine, port: nil, onlyIfPending: true)
            }
        } catch {
            finishStart(generation: mine, port: nil)
        }
    }

    private func finishStart(generation mine: Int, port: UInt16?, onlyIfPending: Bool = false) {
        lock.lock()
        // A superseded listener must not publish over the live one.
        guard mine == generation else { lock.unlock(); return }
        if onlyIfPending, !isStarting { lock.unlock(); return }
        if let port {
            _port = port
            _isReady = true
        }
        isStarting = false
        let pending = waiters
        waiters.removeAll()
        let result = _isReady ? _port : nil
        lock.unlock()

        for continuation in pending { continuation.resume(returning: result) }
    }

    private func markDead(generation mine: Int) {
        lock.lock()
        guard mine == generation else { lock.unlock(); return }
        _port = nil
        _isReady = false
        lock.unlock()
    }

    /// The cached port, but only while the listener that owns it is ready.
    private func liveListenerPort() -> UInt16? {
        lock.lock()
        let ready = _isReady
        let port = _port
        let live = listener
        lock.unlock()
        guard ready, let live, case .ready = live.state else { return nil }
        return port
    }

    func stop() {
        lock.lock()
        generation += 1
        isStarting = false
        _port = nil
        _isReady = false
        let pending = waiters
        waiters.removeAll()
        let old = listener
        listener = nil
        lock.unlock()

        old?.cancel()
        for continuation in pending { continuation.resume(returning: nil) }
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
