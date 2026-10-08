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

    /// Drops a song from the queue.
    ///
    /// The queue, not the playlist it came from: this is "not this one, not
    /// now", which is what a set list needs mid-rehearsal. Removing it from
    /// YouTube is a different decision, and it lives in the playlist screen.
    ///
    /// Removing the song that is playing moves to the next one, or closes the
    /// player when there is no next one — leaving a player sitting on a song
    /// that is no longer in the queue is a state nothing else knows how to
    /// describe.
    /// Returns true when the song that was playing changed, so the caller
    /// knows to load the new one — loading lives in the view that owns the
    /// web view, not in here.
    @discardableResult
    func remove(at position: Int) -> Bool {
        guard queue.indices.contains(position) else { return false }
        let wasCurrent = position == index
        queue.remove(at: position)

        if queue.isEmpty { close(); return false }
        if wasCurrent {
            index = min(position, queue.count - 1)
            return true
        }
        if position < index { index -= 1 }
        return false
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

    /// Live vertical travel of a drag in progress. State rather than
    /// GestureState so releasing can animate it back to rest in the same
    /// transaction that commits the mode — otherwise the two move apart and
    /// the player jumps at the moment you let go.
    @State private var drag: CGFloat = 0

    var body: some View {
        if host.isVisible, let current = host.current {
            GeometryReader { geo in
                let mini = host.mode == .mini
                let fullWidth = geo.size.width
                // The measured top of the tab bar, converted into this
                // view's space. Falls back to the full height only until the
                // first measurement arrives. Known in both modes, which is
                // what lets a drag show the dock it is heading for.
                let dockBottom = host.dockAnchorY.map { $0 - geo.frame(in: .global).minY }
                    ?? geo.size.height


                // Full width, until that makes the video too tall — which is
                // what landscape on an iPad does: 16:9 of a 1194pt width is
                // 672pt of an 834pt screen, leaving the title, the buttons
                // and the queue about 160pt to share. Past the share below
                // the video stops growing and sits narrower instead, centred,
                // so the screen stays readable in both orientations.
                //
                // A PHONE ON ITS SIDE IS THE OPPOSITE CASE. Half of a 402pt
                // landscape height is a 201pt video on an 874pt-wide screen —
                // a small picture adrift in black, with the rest of the
                // screen spent on a page nobody turns their phone sideways to
                // read. Turning the phone IS the request to watch, so there
                // the video takes the height it can and the page waits below
                // it. Measured rather than asked of the device: an iPad in a
                // short split view should behave like the small screen it is.
                let isLandscape = geo.size.width > geo.size.height
                let isShort = geo.size.height < 520
                let heightShare: CGFloat = (isLandscape && isShort) ? 1 : 0.5
                let videoHeight = min(fullWidth * 9 / 16, geo.size.height * heightShare)
                let videoWidth = videoHeight * 16 / 9

                // The two resting shapes, and the point between them the
                // finger is currently at.
                let fullX = (fullWidth - videoWidth) / 2
                let miniW = PlayerStage.miniWidth
                let miniH = miniW * 9 / 16
                let miniX = AppLayout.floatingInset + PlayerStage.miniPadding
                let miniY = dockBottom - PlayerStage.miniBarHeight + PlayerStage.miniPadding

                // 0 is the full player, 1 is docked, and a drag lives in
                // between — measured against the distance the player actually
                // has to fall, not against a fixed number of points.
                //
                // It used to be translation/220 on a phone where the dock is
                // some 600pt below the video, so the frame ran three times
                // faster than the finger: you pushed it an inch and it fled.
                // Dividing by the real travel makes y work out to exactly the
                // finger's own displacement, so the video stays under the
                // thumb the whole way down and shrinks as it goes.
                let travel = max(1, miniY)
                let base: CGFloat = mini ? 1 : 0
                let t = min(1, max(0, base + drag / travel))

                let width = videoWidth + (miniW - videoWidth) * t
                let height = videoHeight + (miniH - videoHeight) * t
                let originX = fullX + (miniX - fullX) * t
                let originY = miniY * t
                let corner = (AppLayout.usesCustomTabBar ? 16 : 6) * t

                ZStack(alignment: .topLeading) {
                    // The full screen behind the player. Faded rather than
                    // removed so the player's own frame is the thing moving.
                    WatchScreen()
                        .padding(.top, videoHeight)
                        .background(Color(.systemBackground))
                        .opacity(1 - t)
                        .allowsHitTesting(t < 0.5)

                    // The band the video sits in, full width even when the
                    // video is narrower than the screen. Without it the
                    // letterboxing beside a capped video showed the page
                    // background — white in light mode, beside a black video.
                    // Faded rather than removed. Dropped outright it
                    // vanished on the first frame of the shrink, so the band
                    // the video was travelling across disappeared before the
                    // video had left it — a flash of the page behind, which
                    // read as the animation stuttering rather than as the
                    // backdrop going.
                    Color.black
                        .frame(width: fullWidth, height: videoHeight)
                        .opacity(1 - t)
                        .allowsHitTesting(false)

                    if t > 0 {
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
                        // Floating on iPad, where the tab bar below it is a
                        // floating capsule: a full-width slab above a floating
                        // pill left a strip of the grid showing between them,
                        // which read as a gap rather than a layer. Edge to
                        // edge on iPhone, where it sits on a full-width tab
                        // bar and an inset would only break that line.
                        .frame(width: geo.size.width - AppLayout.floatingInset * 2,
                               height: PlayerStage.miniBarHeight)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(
                                cornerRadius: AppLayout.usesCustomTabBar ? 16 : 0,
                                style: .continuous)
                        )
                        .overlay(alignment: .top) {
                            if !AppLayout.usesCustomTabBar { Divider() }
                        }
                        .shadow(color: .black.opacity(AppLayout.usesCustomTabBar ? 0.14 : 0),
                                radius: 12, y: 4)
                        .offset(x: AppLayout.floatingInset,
                                y: dockBottom - PlayerStage.miniBarHeight)
                        // Fades in as the player is pulled down, so the bar
                        // it is heading for is visible the whole way.
                        .opacity(t)
                        .allowsHitTesting(t > 0.5)
                        // No tap gesture on the bar itself: a container tap
                        // competes with the buttons inside it, which is the
                        // other half of why close was unreliable. Expanding
                        // is the title's job, and dragging still works
                        // anywhere because a drag and a tap do not collide.
                        .gesture(dragGesture(mini: true, travel: travel))
                        .transition(.opacity)
                    }

                    ZStack {
                        Color.black
                        FocusPlayerView(videoId: current.id, coordinator: host.coordinator)

                        // The end-screen guard, painted the instant ENDED
                        // arrives so YouTube's suggestion grid never gets a
                        // frame.
                        if host.coordinator.didEnd,
                           SolaPraiseConfig.endBehavior == .overlay, t < 0.5 {
                            PlayerEndCard(host: host)
                        }
                        if let message = host.coordinator.errorMessage, t < 0.5 {
                            PlayerErrorCard(host: host, message: message)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .allowsHitTesting(t < 0.5)
                    // Docked, the video is a thumbnail rather than a player,
                    // and pressing a thumbnail should bring the player back.
                    //
                    // It could not before: hit testing is off below 0.5 so
                    // YouTube's own chrome cannot be pressed by accident in a
                    // 100pt-wide picture, and that took the tap with it — so
                    // the one part of the bar that most looks like a button
                    // did nothing. This layer sits ABOVE that modifier, so
                    // the web view stays deaf and the tap still lands.
                    .overlay {
                        if t > 0.5 {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(WatchScreen.stageAnimation) {
                                        host.expand()
                                    }
                                }
                                .accessibilityLabel("플레이어 열기")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .offset(x: originX, y: originY)
                    // High priority, not a plain gesture.
                    //
                    // The video is a WKWebView, and a web view's own
                    // recognisers claim a drag that starts on it — so pulling
                    // the player down worked only when the touch happened to
                    // begin off the video, which reads as "it does not
                    // respond". This one wins first.
                    .highPriorityGesture(dragGesture(mini: mini, travel: travel))
                }
                .animation(WatchScreen.stageAnimation, value: host.mode)
            }
            // The top safe area is respected in both modes. Ignoring it in
            // full mode ran the video under the status bar, and the embed
            // puts YouTube's own chrome up there — the channel name, share,
            // CC and fullscreen all sat behind the clock and the status
            // icons on an iPhone, half unreadable and half untappable.
            .transition(.opacity)
        }
    }

    /// Down docks it, up restores it. The threshold is generous because this
    /// competes with the scroll view underneath.
    /// Follows the finger from the first few points of movement.
    ///
    /// `minimumDistance` is small but not zero: the video is a web view with
    /// YouTube's own controls inside it, and a gesture that began at zero
    /// would swallow the taps meant for play and pause.
    private func dragGesture(mini: Bool, travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                // Sideways swipes belong to whatever is underneath.
                guard abs(value.translation.width) < 120 else { return }
                drag = value.translation.height
            }
            .onEnded { value in
                let moved = value.translation.height
                let thrown = value.predictedEndTranslation.height
                let sideways = abs(value.translation.width) >= 120
                withAnimation(WatchScreen.stageAnimation) {
                    drag = 0
                    guard !sideways else { return }
                    // A third of the way, or let go travelling fast enough to
                    // get there — the same two tests any sheet dismissal uses.
                    let commit = travel * 0.33
                    if !mini, moved > commit || thrown > travel * 0.6 {
                        host.minimize()
                    } else if mini, -moved > commit || -thrown > travel * 0.6 {
                        host.expand()
                    }
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

// MARK: - Reserving the bottom chrome

/// Reserves the bottom furniture a tab sits above — the docked player, and
/// on iPad the app's own tab bar — and measures where the player's share of
/// it ends.
///
/// This belongs *inside* each tab's `NavigationStack`, next to that screen's
/// own bottom furniture. On the `TabView` it reserved space below the system
/// tab bar instead of above it, so the docked bar covered the tabs outright;
/// wrapped around a tab it fared no better, because a NavigationStack does
/// not pass an outer bottom inset down to the scroll view inside it — 홈's
/// search field stayed exactly where it was and the player sat on top of it.
/// Applied in here the inset is the innermost piece of bottom furniture, so
/// the screen's own insets stack above it.
///
/// The two pieces are reserved together because they stack: the player docks
/// directly on top of the tab bar, and the gap between "what the content
/// must clear" and "where the player's bottom edge is" is exactly the tab
/// bar's height. Measuring the boundary between them is what keeps the two
/// from overlapping on iPad, where the bar is ours and the system does not
/// inset anything for it.
struct BottomChrome: ViewModifier {
    @EnvironmentObject private var host: PlayerHost

    func body(content: Content) -> some View {
        content
            // iPad draws its own bar at the bottom, so the system's — which
            // iPadOS 26 puts at the top — has to go. Applied to the tab's
            // content, which is where this modifier takes effect; on the
            // TabView it would hide an enclosing bar instead of this one.
            .toolbar(AppLayout.usesCustomTabBar ? .hidden : .automatic,
                     for: .tabBar)
            // Translucent, not the opaque slab the system swaps in once the
            // content scrolls under it. That slab is a thick grey band at the
            // top of a screen whose bottom bar is floating glass — the two
            // did not look like they belonged to the same app.
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // The docked player's share, reserved only while it is
                    // docked.
                    if host.mode == .mini {
                        Color.clear.frame(height: PlayerStage.miniBarHeight)
                    }

                    // A zero-height line where the player's bottom edge
                    // belongs, measured in EVERY mode.
                    //
                    // It used to be the mini reservation itself, which meant
                    // the line did not exist until the player was already
                    // docking. Shrinking out of full screen therefore started
                    // with no idea where it was going, aimed at the bottom of
                    // the screen, and corrected once the measurement landed a
                    // frame or two later — two animations where there should
                    // be one, which is what made it feel late. Everything
                    // below this line is fixed furniture, so the line sits at
                    // the same y in both modes and the target is known before
                    // the gesture starts.
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                host.dockAnchorY = proxy.frame(in: .global).maxY
                            }
                            .onChange(of: proxy.frame(in: .global).maxY) { _, new in
                                host.dockAnchorY = new
                            }
                    }
                    .frame(height: 0)

                    // Reserved in both modes for the same reason: a gap that
                    // appeared only while docked would move the line by its
                    // own height mid-animation. Zero on iPhone.
                    Color.clear.frame(height: AppLayout.floatingGap)

                    if AppLayout.usesCustomTabBar {
                        Color.clear.frame(height: AppLayout.tabBarHeight)
                    }
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func bottomChrome() -> some View {
        modifier(BottomChrome())
    }
}
