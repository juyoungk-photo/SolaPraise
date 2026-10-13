//
//  check-player-page.swift
//  SolaPraise
//
//  Builds the player document from FocusPlayerKit's real web files and checks
//  what PlayerCoordinator relies on.
//
//  WHY THIS EXISTS: the page is assembled from text. A marker renamed in
//  player.html, or a script tag that no longer matches, leaves a page that
//  loads without focus-player.js — no `ready`, no events, a black player
//  that the watchdog can only guess about. Nothing raises an error. And the
//  page was once two copies that drifted, so the fallback and the loopback
//  page are checked to be the same document.
//
//  Run:
//      swiftc -O -o /tmp/playerpagecheck \
//          Sources/Player/PlayerPage.swift Tools/check-player-page.swift
//      /tmp/playerpagecheck
//
//  Reads the copy in Vendor/FocusPlayerKit/web. When FocusPlayerKit is
//  checked out next to SolaPraise, also fails while the copy differs from
//  it — run Tools/sync-focus-player.sh.
//

import Foundation

@main
struct CheckPlayerPage {
    static func main() {
        var failures = 0
        var checks = 0
        func expect(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL \(what)") }
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let web = root.appendingPathComponent("Vendor/FocusPlayerKit/web")
        func read(_ name: String) -> String {
            guard let text = try? String(contentsOf: web.appendingPathComponent(name), encoding: .utf8) else {
                print("FAIL cannot read \(web.path)/\(name) — run from the SolaPraise root")
                exit(1)
            }
            return text
        }
        let shell = read("player.html")
        let css = read("focus-player.css")
        let js = read("focus-player.js")

        expect(shell.contains(PlayerPage.stylesheetMarker), "player.html has the stylesheet marker")
        expect(shell.contains(PlayerPage.scriptMarker), "player.html has the script marker")
        expect(shell.contains(PlayerPage.configMarker), "player.html has the config marker")

        // Loopback page: video from the query.
        let loopback = PlayerPage.assemble(shell: shell, css: css, js: js, config: nil)
        expect(!loopback.contains(PlayerPage.scriptMarker), "loopback: script inlined, not requested")
        expect(!loopback.contains(PlayerPage.stylesheetMarker), "loopback: stylesheet inlined, not requested")
        expect(loopback.contains("global.FocusPlayer = {"), "loopback: carries focus-player.js")
        expect(loopback.contains("position: absolute !important"), "loopback: carries the iframe sizing fix")
        expect(loopback.contains("https://www.youtube.com/iframe_api"), "loopback: loads the IFrame API")
        expect(loopback.contains("focusTubePlayer"), "loopback: posts to the handler PlayerCoordinator registers")
        expect(loopback.contains("var player = null"), "loopback: the global `player` evaluateJavaScript drives")
        expect(!loopback.contains("FOCUS_PLAYER_CONFIG = "), "loopback: no config written")

        // Fallback page: video written in.
        let fallback = PlayerPage.assemble(
            shell: shell, css: css, js: js,
            config: .init(videoId: "abcDEF12_-x", autoplay: true))
        expect(fallback.contains(#"window.FOCUS_PLAYER_CONFIG = {"autoplay":true,"videoId":"abcDEF12_-x"};"#),
               "fallback: config written")
        expect(fallback.replacingOccurrences(
                of: #"<script>window.FOCUS_PLAYER_CONFIG = {"autoplay":true,"videoId":"abcDEF12_-x"};</script>"#,
                with: PlayerPage.configMarker) == loopback,
               "fallback and loopback are the same document apart from the config")

        // A hostile id cannot close the script element.
        let hostile = PlayerPage.json(.init(videoId: "</script><script>alert(1)", autoplay: false))
        expect(!hostile.contains("</"), "config escapes </")

        // Every inlined <script> must still be closed by its own tag.
        let opens = loopback.components(separatedBy: "<script").count - 1
        let closes = loopback.components(separatedBy: "</script>").count - 1
        expect(opens == closes, "script tags balanced (\(opens) open, \(closes) close)")

        // The copy is the kit's, not a fork of it.
        let upstream = root.deletingLastPathComponent().appendingPathComponent("FocusPlayerKit/web")
        if FileManager.default.fileExists(atPath: upstream.path) {
            for name in ["player.html", "focus-player.js", "focus-player.css"] {
                let theirs = try? String(contentsOf: upstream.appendingPathComponent(name), encoding: .utf8)
                expect(theirs == read(name), "\(name) matches ../FocusPlayerKit — run Tools/sync-focus-player.sh")
            }
        }

        if failures > 0 {
            print("\(failures) of \(checks) checks failed")
            exit(1)
        }
        print("all \(checks) player page checks passed")
    }
}
