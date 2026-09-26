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
        self.queue = queue
        index = max(0, min(startIndex, queue.count - 1))
        mode = .full
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

    private static let miniWidth: CGFloat = 112
    private static let miniPadding: CGFloat = 8

    var body: some View {
        if host.isVisible, let current = host.current {
            GeometryReader { geo in
                let mini = host.mode == .mini
                let fullWidth = geo.size.width
                let width = mini ? Self.miniWidth : fullWidth
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
                        MiniChrome(host: host, current: current)
                            .padding(.leading, Self.miniWidth + Self.miniPadding * 2)
                            .frame(height: height + Self.miniPadding * 2)
                            .offset(y: geo.size.height - height - Self.miniPadding * 2)
                            .transition(.opacity)
                    }

                    ZStack {
                        Color.black
                        FocusPlayerView(videoId: current.id, coordinator: host.coordinator)

                        // The end-screen guard, painted the instant ENDED
                        // arrives so YouTube's suggestion grid never gets a
                        // frame. It moved here with the player: it has to be
                        // over the video, and the video no longer lives in
                        // the screen that used to draw it.
                        if host.coordinator.didEnd,
                           SolaPraiseConfig.endBehavior == .overlay, !mini {
                            PlayerEndCard(host: host)
                        }
                        if let message = host.coordinator.errorMessage, !mini {
                            PlayerErrorCard(host: host, message: message)
                        }
                    }
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: mini ? 6 : 0,
                                                    style: .continuous))
                        .offset(
                            x: mini ? Self.miniPadding : 0,
                            y: mini ? geo.size.height - height - Self.miniPadding : 0
                        )
                        .allowsHitTesting(!mini)
                        .gesture(dragGesture(mini: mini))
                }
                .background {
                    if mini {
                        Rectangle()
                            .fill(.regularMaterial)
                            .frame(height: height + Self.miniPadding * 2)
                            .overlay(alignment: .top) { Divider() }
                            .offset(y: geo.size.height - height - Self.miniPadding * 2)
                            .onTapGesture {
                                withAnimation(WatchScreen.stageAnimation) { host.expand() }
                            }
                    }
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
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(WatchScreen.stageAnimation) { host.expand() }
            }

            Spacer(minLength: 0)

            Button {
                if host.coordinator.state == .playing {
                    host.coordinator.pause()
                } else {
                    host.coordinator.play()
                }
            } label: {
                Image(systemName: host.coordinator.state == .playing
                      ? "pause.fill" : "play.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Button { host.close() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 30, height: 34)
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
