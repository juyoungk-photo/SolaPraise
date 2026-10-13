//
//  PlayerPage.swift
//  SolaPraise
//
//  The player document, built from FocusPlayerKit's web files.
//
//  There used to be two player pages here, written out as Swift strings: one
//  in LocalPlayerServer for the loopback path, one in FocusPlayerView for the
//  loadSimulatedRequest fallback. They drifted — the fix for the iframe that
//  never filled the web view (3790dba) went into the fallback only, so the
//  path that actually runs kept the bug. Both now come from one page,
//  FocusPlayerKit/web/player.html, bundled as the `web` folder (project.yml)
//  and shared with the family hub.
//
//  The stylesheet and script are inlined so the document is one response:
//  the fallback has no server to ask for a second file.
//
//  Foundation only, so Tools/check-player-page.swift can build it.
//

import Foundation

enum PlayerPage {

    /// What the fallback page cannot read from a query string.
    struct Config {
        let videoId: String
        let autoplay: Bool
    }

    /// The loopback page: the video comes from `?v=…&autoplay=…`.
    static func html(bundle: Bundle = .main) -> String {
        html(config: nil, bundle: bundle)
    }

    /// The page with its video written in — for loadSimulatedRequest, whose
    /// document URL carries no query.
    static func html(config: Config?, bundle: Bundle = .main) -> String {
        guard let files = files(in: bundle) else {
            assertionFailure("FocusPlayerKit web files missing from the bundle — check project.yml")
            return missingPage
        }
        return assemble(shell: files.shell, css: files.css, js: files.js, config: config)
    }

    // MARK: - Assembly

    static let stylesheetMarker = #"<link rel="stylesheet" href="focus-player.css">"#
    static let scriptMarker = #"<script src="focus-player.js"></script>"#
    static let configMarker = "<!-- focus-player:config -->"

    /// Inlines the stylesheet and script and writes the config. Pure, so the
    /// check can run it on the real files.
    static func assemble(shell: String, css: String, js: String, config: Config?) -> String {
        var page = shell
        page = page.replacingOccurrences(of: stylesheetMarker, with: "<style>\n\(css)\n</style>")
        page = page.replacingOccurrences(of: scriptMarker, with: "<script>\n\(safeInline(js))\n</script>")
        if let config {
            page = page.replacingOccurrences(
                of: configMarker,
                with: "<script>window.FOCUS_PLAYER_CONFIG = \(json(config));</script>")
        }
        return page
    }

    /// The config as a JS literal. JSON is valid JS; `</` is escaped so no
    /// value can close the script element early.
    static func json(_ config: Config) -> String {
        let object: [String: Any] = ["videoId": config.videoId, "autoplay": config.autoplay]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return safeInline(text)
    }

    private static func safeInline(_ text: String) -> String {
        text.replacingOccurrences(of: "</", with: "<\\/")
    }

    // MARK: - Files

    private struct Files { let shell: String; let css: String; let js: String }

    /// Read once: the bundle does not change while the app runs.
    private static var cached: Files?
    private static let lock = NSLock()

    private static func files(in bundle: Bundle) -> Files? {
        lock.lock(); defer { lock.unlock() }
        if bundle == .main, let cached { return cached }
        func read(_ name: String, _ ext: String) -> String? {
            bundle.url(forResource: name, withExtension: ext, subdirectory: "web")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let shell = read("player", "html"),
              let css = read("focus-player", "css"),
              let js = read("focus-player", "js") else { return nil }
        let files = Files(shell: shell, css: css, js: js)
        if bundle == .main { cached = files }
        return files
    }

    /// Reports through the same bridge, so the error card shows rather than
    /// a black rectangle that the watchdog has to guess about.
    private static let missingPage = """
        <!DOCTYPE html><html><body style="background:#000">
        <script>
          try { window.webkit.messageHandlers.focusTubePlayer.postMessage({ event: 'error', code: -2 }); } catch (e) {}
        </script>
        </body></html>
        """
}
