//
//  PlayerHost.swift
//  SolaPraise
//
//  The player, owned by the app rather than by a screen.
//
//  WHY: a video presented from a `fullScreenCover` dies when that cover is
//  dismissed, so leaving the player meant stopping the song. Hoisting the
//  queue and the coordinator to app level lets the same document shrink to a
//  bar above the tab bar and keep playing while you browse.
//
//  This is NOT background playback. The player stays on screen and stays
//  visible — which is both what YouTube's terms require of an embedded player
//  and what makes the feature worth having: you can see what is playing.
//
//  System Picture-in-Picture is a different thing and is not available here:
//  the video lives inside YouTube's cross-origin iframe, which does not expose
//  its media element to the host app.
//

import SwiftUI

@MainActor
final class PlayerHost: ObservableObject {

    enum Mode {
        case closed
        case full
        case mini
    }

    @Published private(set) var mode: Mode = .closed
    @Published private(set) var queue: [PlayableVideo] = []
    @Published var index: Int = 0

    /// One coordinator for the app's lifetime, so the web view it owns is
    /// never rebuilt by a change of presentation.
    let coordinator = PlayerCoordinator()

    /// Where the tab bar starts, in global coordinates.
    ///
    /// Measured, not assumed. A hardcoded tab-bar height was wrong often
    /// enough to put the docked player ON the tab bar — and because the bar
    /// is hit-testable, it then swallowed every tap meant for a tab. Two
    /// symptoms, one cause: tabs stopped switching and the close button
    /// became unreliable, because both were fighting the same overlap.
    @Published var dockAnchorY: CGFloat?

    /// Handlers the player screen installs, so the overlays drawn over the
    /// video can act without the video having to live inside that screen.
    var onAdvance: (() -> Void)?
    var onClose: (() -> Void)?
    var onFindAlternate: (() async -> Void)?
    @Published var isFindingAlternate = false
    @Published var alternateError: String?

    var hasNext: Bool { index + 1 < queue.count }

    var current: PlayableVideo? {
        queue.indices.contains(index) ? queue[index] : nil
    }
    var isPlaylist: Bool { queue.count > 1 }
    var isVisible: Bool { mode != .closed }

    func play(queue: [PlayableVideo], startIndex: Int = 0) {
        guard !queue.isEmpty else { return }
        let chosen = queue.indices.contains(startIndex) ? queue[startIndex] : queue[0]
        let cleaned = Self.watchable(queue, keeping: chosen)

        self.queue = cleaned
        index = cleaned.firstIndex { $0.id == chosen.id } ?? 0
        mode = .full
    }

    /// Drops what nobody queued a playlist to watch.
    ///
    /// A channel's uploads carry trailers, notices and Shorts alongside the
    /// music, and once they are in the queue they play automatically — the
    /// exact interruption this app exists to avoid. The video actually chosen
    /// is always kept, however it looks: tapping a Short should still play
    /// that Short.
    static func watchable(_ videos: [PlayableVideo], keeping: PlayableVideo) -> [PlayableVideo] {
        videos.filter { video in
            if video.id == keeping.id { return true }
            // A Short is a minute or less by definition. Unknown durations
            // are kept, because a missing length is not evidence of anything.
            if let seconds = video.durationSeconds, seconds <= 70 { return false }
            return !isPromotional(video.title)
        }
    }

    private static let promotionalMarkers = [
        "#shorts", "shorts", "예고", "광고", "홍보", "안내", "공지",
        "teaser", "trailer", "preview"
    ]

    private static func isPromotional(_ title: String) -> Bool {
        let lower = title.lowercased()
        return promotionalMarkers.contains { lower.contains($0) }
    }

    func minimize() {
        guard mode == .full else { return }
        mode = .mini
    }

    func expand() {
        guard mode == .mini else { return }
        mode = .full
    }

    func close() {
        coordinator.detach()
        queue = []
        index = 0
        mode = .closed
    }
}

// MARK: - Stage

/// The player and everything around it, in one place in the view hierarchy.
///
/// The first version put the full player in a `fullScreenCover` and the mini
/// player in a `safeAreaInset`. Those are separate presentation contexts, so
/// switching between them re-parented the WKWebView — which briefly
/// interrupted the audio and made the change a jump rather than a movement,
/// because two different presentations cannot animate into each other.
///
/// Here the video is a single view whose frame changes. Nothing is re-parented
/// and nothing reloads, so the sound is continuous and the geometry can be
/// animated like any other layout change.
struct PlayerStage: View {
    @ObservedObject var host: PlayerHost

    static let miniWidth: CGFloat = 112
    static let miniPadding: CGFloat = 8

    /// The space the docked player occupies.
    ///
    /// Published so the tab content can reserve it. The player is an overlay,
    /// which means it draws over the feed and knows nothing about it — the
    /// bottom row of cards ended up underneath the bar, visible through the
    /// material and impossible to tap. An overlay has to be paid for in
    /// layout somewhere, and this is the number.
    static var miniBarHeight: CGFloat { miniWidth * 9 / 16 + miniPadding * 2 }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if host.isVisible, let current = host.current {
            GeometryReader { geo in
                let mini = host.mode == .mini
                let fullWidth = geo.size.width
                // The measured top of the tab bar, converted into this
                // view's space. Falls back to the full height only until the
                // first measurement arrives.
                let anchor = host.dockAnchorY.map { $0 - geo.frame(in: .global).minY }
                let dockBottom = mini ? (anchor ?? geo.size.height) : geo.size.height
                let width = mini ? PlayerStage.miniWidth : fullWidth
                let height = width * 9 / 16

                ZStack(alignment: .topLeading) {
                    // The full screen behind the player. Faded rather than
                    // removed so the player's own frame is the thing moving.
                    WatchScreen()
                        .padding(.top, fullWidth * 9 / 16)
                        .background(Color(.systemBackground))
                        .opacity(mini ? 0 : 1)
                        .allowsHitTesting(!mini)

                    if mini {
                        // One bar, laid out across the full width, with a
                        // gap where the player sits on top of it. The first
                        // version positioned the chrome with padding and an
                        // offset inside a topLeading ZStack, so it sized
                        // itself to its content and its buttons ended up
                        // somewhere other than where they appeared to be —
                        // which is why stop and close did nothing.
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: PlayerStage.miniWidth + PlayerStage.miniPadding * 2)
                            MiniChrome(host: host, current: current)
                        }
                        .frame(width: geo.size.width, height: PlayerStage.miniBarHeight)
                        .background(.regularMaterial)
                        .overlay(alignment: .top) { Divider() }
                        .offset(y: dockBottom - PlayerStage.miniBarHeight)
                        // No tap gesture on the bar itself: a container tap
                        // competes with the buttons inside it, which is the
                        // other half of why close was unreliable. Expanding
                        // is the title's job, and dragging still works
                        // anywhere because a drag and a tap do not collide.
                        .gesture(dragGesture(mini: true))
                        .transition(.opacity)
                    }

                    ZStack {
                        Color.black
                        FocusPlayerView(videoId: current.id, coordinator: host.coordinator)

                        // The end-screen guard, painted the instant ENDED
                        // arrives so YouTube's suggestion grid never gets a
                        // frame.
                        if host.coordinator.didEnd,
                           SolaPraiseConfig.endBehavior == .overlay, !mini {
                            PlayerEndCard(host: host)
                        }
                        if let message = host.coordinator.errorMessage, !mini {
                            PlayerErrorCard(host: host, message: message)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: mini ? 6 : 0, style: .continuous))
                    .offset(
                        x: mini ? PlayerStage.miniPadding : 0,
                        y: mini ? dockBottom - PlayerStage.miniBarHeight + PlayerStage.miniPadding : 0
                    )
                    .allowsHitTesting(!mini)
                    .gesture(dragGesture(mini: mini))
                }
                .animation(WatchScreen.stageAnimation, value: host.mode)
            }
            .ignoresSafeArea(edges: host.mode == .mini ? [] : .top)
            .transition(.opacity)
        }
    }

    /// Down docks it, up restores it. The threshold is generous because this
    /// competes with the scroll view underneath.
    private func dragGesture(mini: Bool) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) < 120 else { return }
                if !mini, value.translation.height > 60 {
                    withAnimation(WatchScreen.stageAnimation) { host.minimize() }
                } else if mini, value.translation.height < -40 {
                    withAnimation(WatchScreen.stageAnimation) { host.expand() }
                }
            }
    }
}

// MARK: - Mini chrome

/// Title and controls beside the docked player.
private struct MiniChrome: View {
    @ObservedObject var host: PlayerHost
    let current: PlayableVideo

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let channel = current.channelTitle {
                    Text(channel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(WatchScreen.stageAnimation) { host.expand() }
            }

            Button {
                if host.coordinator.state == .playing {
                    host.coordinator.pause()
                } else {
                    host.coordinator.play()
                }
            } label: {
                // 44pt, the minimum Apple specifies for a touch target. The
                // old 34 and 30 were small enough to miss, which read as the
                // buttons not working at all.
                Image(systemName: host.coordinator.state == .playing
                      ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { host.close() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 10)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Overlays

/// "Done", over an opaque black field.
///
/// Opaque, not translucent: nothing of the player may show through, because
/// what would show through is YouTube's end-screen suggestion grid — the
/// rabbit hole this app exists to close.
struct PlayerEndCard: View {
    @ObservedObject var host: PlayerHost

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                Text("Done")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    Button { host.coordinator.replay() } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    if host.hasNext {
                        Button { host.onAdvance?() } label: {
                            Label("Next", systemImage: "forward.end")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button { host.onClose?() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .font(.subheadline)
            }
            .padding()
        }
    }
}

struct PlayerErrorCard: View {
    @ObservedObject var host: PlayerHost
    let message: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    if host.coordinator.canRetryLoad {
                        Button {
                            host.coordinator.retryLoad()
                        } label: {
                            Label("다시 시도", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)

                        if let current = host.current,
                           let url = YouTubeID.watchURL(current.id) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("YouTube에서 열기", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }

                    if host.coordinator.isEmbedBlocked {
                        // The song is usually available as another upload —
                        // label copies get embedding disabled, church and
                        // cover uploads generally do not.
                        Button {
                            Task { await host.onFindAlternate?() }
                        } label: {
                            if host.isFindingAlternate {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("재생 가능한 다른 영상 찾기",
                                      systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isFindingAlternate)

                        if let error = host.alternateError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }

                        if let current = host.current,
                           let url = YouTubeID.watchURL(current.id) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("YouTube에서 열기", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }
                    if host.hasNext {
                        Button("다음 곡으로") { host.onAdvance?() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                }
            }
            .padding()
        }
    }
}
