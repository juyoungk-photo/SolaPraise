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

    // The player document itself is PlayerPage, built from FocusPlayerKit.
}
