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

// MARK: - Mini player

/// The player docked above the tab bar.
///
/// Deliberately still a real player rather than a title and a play button: the
/// video keeps rendering, which is the condition under which continuing to
/// play is legitimate at all.
struct MiniPlayerBar: View {
    @ObservedObject var host: PlayerHost

    var body: some View {
        if host.mode == .mini, let current = host.current {
            HStack(spacing: 10) {
                FocusPlayerView(videoId: current.id, coordinator: host.coordinator)
                    .frame(width: 112, height: 63)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .allowsHitTesting(false)

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
                        .font(.body)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            // Tapping the bar — but not its buttons — goes back to full screen.
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { host.expand() } }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height < -40 {
                            withAnimation(.easeOut(duration: 0.2)) { host.expand() }
                        } else if value.translation.height > 60 {
                            host.close()
                        }
                    }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
