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
//  Leaving the app is the one exception, and it keeps the same rule: the
//  video moves into the system's Picture-in-Picture window, still visible.
//  Without PiP it pauses. See PlayerCoordinator's Picture-in-Picture section.
//

import SwiftUI
import Combine

@MainActor
final class PlayerHost: ObservableObject {

    /// There is no docked player. It was dropped for the system's own PiP
    /// window, which moves, resizes and tucks away better than anything
    /// drawn here — and keeping both meant a trip through the dock on the
    /// way back from PiP, and a flicker on the way out.
    enum Mode {
        case closed
        case full
        /// Playing in the system's floating PiP window, inside the app or
        /// out of it. The stage is hidden but kept — PiP plays from its web
        /// view — and reserves no space.
        case pip
    }

    @Published private(set) var mode: Mode = .closed
    @Published private(set) var queue: [PlayableVideo] = []
    @Published var index: Int = 0

    /// One coordinator for the app's lifetime, so the web view it owns is
    /// never rebuilt by a change of presentation.
    let coordinator = PlayerCoordinator()

    private var pipWatch: AnyCancellable?
    private var pipSettledWatch: AnyCancellable?

    /// The system's window has the video and its animation is over: the
    /// player page goes, in one frame.
    private func pictureInPictureHasSettled() {
        guard mode == .full, coordinator.isPictureInPicture else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { mode = .pip }
    }

    /// Writes one play to 재생 기록; set by the app, which owns the store.
    var recordWatch: ((PlayableVideo, _ seconds: Int, _ completed: Bool) -> Void)?
    /// Every video played this session, by id: the queue has often moved
    /// on, or been replaced, by the time the last one is recorded.
    private var played: [String: PlayableVideo] = [:]

    init() {
        coordinator.onLeave = { [weak self] id, seconds, completed, position in
            guard let self else { return }
            let video = self.played[id] ?? self.queue.first { $0.id == id } ?? PlayableVideo(id: id, title: "")
            self.recordWatch?(video, seconds, completed)
            // Left part-way through, after listening a while: offer the way
            // back — a tap on the wrong row should not cost the place.
            if !completed, position >= 10 { self.offerReturn(to: video, at: position) }
        }
        // When the floating window goes away — its 「돌아가기」, or its close
        // button — the player comes back: full if the song is still going
        // (that is what 「돌아가기」 means), docked if it stopped, so the
        // song is still one tap away rather than gone.
        // The mode follows the window, not the request, and changes in one
        // frame with no animation: the system animates the video into and
        // out of its corner, and a fade of the player screen on top of that
        // was the flicker.
        //
        // In: the moment PiP has the video, the player screen goes. Out: its
        // 「돌아가기」 leaves the song playing — the player comes back where it
        // was; its close pauses it — the player closes.
        pipWatch = coordinator.$isPictureInPicture
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] inPiP in
                guard let self else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { self.videoInPictureInPicture = inPiP }
                if inPiP {
                    self.leavingForPictureInPicture = false
                    guard self.mode == .full else { return }
                    // The page leaves when iOS says its animation is done
                    // (pictureInPictureSettled, below) — not at the start,
                    // when WebKit's black backdrop was left hanging alone
                    // over the tab, and not on a guessed timer, which iOS
                    // outlasted (0.75 s measured on iPad). Only a fallback
                    // here, just past that, for when the settled event never
                    // comes — the iPhone simulator never sends it.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(800))
                        self?.pictureInPictureHasSettled()
                    }
                } else {
                    guard self.mode == .pip else { return }
                    let playing = self.coordinator.state == .playing || self.coordinator.state == .buffering
                    if playing {
                        withTransaction(still) { self.mode = .full }
                    } else {
                        self.close()
                    }
                }
            }
        // ⏮ ⏭ from earphones, a car or the lock screen, in the app, in PiP
        // or in the background — the same steps as the player's own.
        coordinator.onRemoteTrack = { [weak self] next in
            guard let self, self.mode != .closed else { return }
            if next {
                guard self.hasNext else { return }
                self.index += 1
            } else if self.coordinator.currentTime > 3 || self.index == 0 {
                // As in any music player: a song under way starts again.
                self.coordinator.seek(to: 0)
                return
            } else {
                self.index -= 1
            }
            if let song = self.current { self.coordinator.load(videoId: song.id) }
        }
        pipSettledWatch = coordinator.pictureInPictureSettled
            .sink { [weak self] in self?.pictureInPictureHasSettled() }
        // A song ending in PiP moves on to the next one, so a 콘티 plays
        // through in the floating window. Through the screen's own handler
        // when it is installed, so the watch log records the song.
        // A song ending moves on to the next one — on screen, in PiP and in
        // the background alike — so a playlist or a 콘티 plays through as on
        // YouTube. Decided here, where the song ends, rather than by the
        // player screen, which is not there in PiP and did not advance on
        // screen at all: a playlist stopped after every song.
        coordinator.advanceAtEnd = { [weak self] in
            // 취침: 「이 영상 끝나면」 means nothing after it.
            // Not consumed here: the player then stops and reports the
            // end, and WatchScreen takes it there, once.
            guard let self, !self.sleepsAtEnd, self.hasNext else { return false }
            // A 말씀 feed's 「next」 goes on only as 이어 듣기.
            let series = UserDefaults.standard.string(forKey: "word.series.direction") ?? "off"
            guard self.continuesAtEnd || series != "off" else { return false }
            if let advance = self.onAdvance {
                advance()
            } else {
                self.index += 1
                if let next = self.current { self.coordinator.load(videoId: next.id) }
            }
            return true
        }
    }

    /// Handlers the player screen installs, so the overlays drawn over the
    /// video can act without the video having to live inside that screen.
    var onAdvance: (() -> Void)?
    var onClose: (() -> Void)?
    var onFindAlternate: (() async -> Void)?
    @Published var isFindingAlternate = false
    @Published var alternateError: String?

    var hasNext: Bool { index + 1 < queue.count }

    /// The queue is a playlist or a 콘티 someone put together.
    private(set) var isCurated = false

    /// The YouTube playlist the queue was played from, whole.
    struct QueueSource: Equatable {
        let playlistId: String
        let title: String
    }
    @Published private(set) var source: QueueSource?

    /// The queue as arranged in 재생목록 관리: the song playing plays on
    /// where it now stands; if it was taken out, the one in its place
    /// starts.
    func rearrange(_ newQueue: [PlayableVideo]) {
        guard !newQueue.isEmpty else { close(); return }
        let playing = current?.id
        queue = newQueue
        if let playing, let at = newQueue.firstIndex(where: { $0.id == playing }) {
            index = at
        } else {
            index = min(index, newQueue.count - 1)
            if let song = current { coordinator.load(videoId: song.id) }
        }
    }

    /// Whether the next video starts by itself when one ends: a playlist,
    /// a 콘티 and a 찬양 feed play through, as on YouTube. A 말씀 feed's
    /// 「next」 is only the channel's other uploads — a sermon is not a run
    /// — so it stops there unless 이어 듣기 is on.
    var continuesAtEnd: Bool { isCurated || current?.purpose != .word }

    // MARK: - 이전 곡으로

    /// The song left part-way a moment ago, and where — 「이전 곡으로」.
    struct Return: Equatable {
        let video: PlayableVideo
        let at: Double
        let id = UUID()
        static func == (l: Return, r: Return) -> Bool { l.id == r.id }
    }
    @Published private(set) var returnTo: Return?

    private func offerReturn(to video: PlayableVideo, at position: Double) {
        let offer = Return(video: video, at: position)
        returnTo = offer
        Task { @MainActor [weak self] in
            // Long enough to notice the wrong song; not a standing button.
            try? await Task.sleep(for: .seconds(15))
            if self?.returnTo == offer { self?.returnTo = nil }
        }
    }

    /// Back to the song left a moment ago, at the place it was left.
    func goBack() {
        guard let back = returnTo else { return }
        returnTo = nil
        if let at = queue.firstIndex(where: { $0.id == back.video.id }) {
            index = at
        } else {
            // The queue was replaced: the song goes back in where it plays now.
            queue.insert(back.video, at: min(index, queue.count))
        }
        coordinator.load(videoId: back.video.id, start: back.at)
    }

    var current: PlayableVideo? {
        queue.indices.contains(index) ? queue[index] : nil
    }
    var isPlaylist: Bool { queue.count > 1 }
    var isVisible: Bool { mode != .closed }

    /// - purpose: what the tab it was started from plays — 찬양 or 말씀 —
    ///   stamped on each video that does not already say, so the player
    ///   gives 찬양 its whole feature set and 말씀 the reduced one.
    /// - curated: a playlist or a 콘티 somebody put together. Played as it
    ///   is — the Short and promo filter below is for feeds, where it keeps
    ///   「next」 on songs. It took 「#shorts」 out of a team playlist, so
    ///   the app played two songs of three.
    /// - source: the YouTube playlist the queue is, whole — so 재생목록
    ///   관리 can save a new order back to it. Nil for anything else,
    ///   including a playlist played filtered.
    func play(queue: [PlayableVideo], startIndex: Int = 0, purpose: Purpose? = nil, curated: Bool = false,
              source: QueueSource? = nil) {
        guard !queue.isEmpty else { return }
        let queue = queue.map { video -> PlayableVideo in
            var video = video
            if video.purpose == nil { video.purpose = purpose }
            return video
        }
        let chosen = queue.indices.contains(startIndex) ? queue[startIndex] : queue[0]
        let cleaned = curated ? queue : Self.watchable(queue, keeping: chosen)
        isCurated = curated
        self.source = source

        self.queue = cleaned
        for video in cleaned { played[video.id] = video }
        index = cleaned.firstIndex { $0.id == chosen.id } ?? 0
        // Something new was chosen to watch: out of the floating window and
        // onto the screen.
        if coordinator.isPictureInPicture { coordinator.setPictureInPicture(false) }
        mode = .full
    }

    /// The upload's own details for videos queued with a title alone — a
    /// 콘티's song by its tidied title, a home card, a 작업실 song. The
    /// player showed that short title and 「게시일 정보 없음」 where a
    /// video from the feed shows the clip's title, channel, date and views.
    /// Filled in place: the same video, so nothing reloads or restarts.
    func fillDetails(_ found: [PlayableVideo]) {
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        let filled = queue.map { video -> PlayableVideo in
            guard video.publishedAt == nil, var better = byId[video.id] else { return video }
            better.purpose = video.purpose
            changed = true
            return better
        }
        guard changed else { return }
        queue = filled
        for video in filled { played[video.id] = video }
    }

    /// A feed's 「next」 as 설정 › 피드·찬양 검색 says (FeedFilter): notices
    /// and trailers out, a Short as its full-length original when the feed
    /// has it — never just dropped. The video actually chosen plays as it
    /// is: tapping a Short still plays that Short.
    static func watchable(_ videos: [PlayableVideo], keeping: PlayableVideo) -> [PlayableVideo] {
        let items = videos.map(FeedFilter.Item.init(playable:))
        let byId = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FeedFilter.arrange(items, keeping: keeping.id).compactMap { byId[$0.id] }
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

    /// Asked for, not yet confirmed — see dock().
    private var leavingForPictureInPicture = false

    /// The system's window has the video. The stage hides the inline video
    /// from this moment — not from the request, which left a black gap
    /// while PiP was being set up, and not from the page's removal, which
    /// let WebKit's 「playing in picture in picture」 placeholder flash
    /// between the video and its window.
    @Published private(set) var videoInPictureInPicture = false

    /// Leaving the full player — another tab, the chevron, a pull down.
    ///
    /// Playing: into PiP, and nothing else — no shrinking, no dock; the
    /// player screen goes when the window has the video. Not playing:
    /// there is nothing to keep on screen, so the player closes. Playing
    /// but PiP refused (an embed that will not, PiP off on the device):
    /// `orClose` decides — a tab change closes the player rather than
    /// leave it over the new tab; the chevron or a pull keeps it and says
    /// why.
    func dock(orClose: Bool = false) {
        guard mode == .full, !leavingForPictureInPicture else { return }
        let playing = coordinator.state == .playing || coordinator.state == .buffering
        guard playing else { close(); return }
        guard coordinator.enterPictureInPicture() else {
            refusedPictureInPicture(orClose: orClose)
            return
        }
        leavingForPictureInPicture = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.leavingForPictureInPicture, !self.coordinator.isPictureInPicture else { return }
            self.leavingForPictureInPicture = false
            self.refusedPictureInPicture(orClose: orClose)
        }
    }

    private func refusedPictureInPicture(orClose: Bool) {
        if orClose { close() }
        Toast.shared.show("이 영상은 PiP로 재생할 수 없습니다", symbol: "pip.exit", tint: .orange)
    }

    /// Back from PiP to the full player.
    func expand() {
        guard mode == .pip else { return }
        coordinator.setPictureInPicture(false)
    }

    // MARK: - 취침 타이머

    /// When playback stops by itself, for falling asleep to 찬양 or 말씀.
    ///
    /// Pausing is all it does: the video stays where it stopped, so the
    /// morning can pick up from there. Same on iPhone and iPad; it keeps
    /// counting in PiP, where the app is still running.
    @Published private(set) var sleepDeadline: Date?
    /// 「이 영상 끝나면」: nothing plays after the current video.
    @Published private(set) var sleepsAtEnd = false
    private var sleepTask: Task<Void, Never>?

    var isSleepTimerOn: Bool { sleepDeadline != nil || sleepsAtEnd }

    func setSleepTimer(minutes: Int) {
        setSleepTimer(after: TimeInterval(minutes * 60))
    }

    func setSleepTimer(after seconds: TimeInterval) {
        cancelSleepTimer()
        sleepDeadline = Date().addingTimeInterval(seconds)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sleepNow()
        }
    }

    func sleepAtEndOfVideo() {
        cancelSleepTimer()
        sleepsAtEnd = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepsAtEnd = false
    }

    /// Called as a video ends: true when the timer was waiting for that,
    /// so nothing plays next. Once.
    func takeSleepAtEnd() -> Bool {
        guard sleepsAtEnd else { return false }
        sleepsAtEnd = false
        Toast.shared.show("취침 타이머: 재생을 마쳤습니다", symbol: "moon.zzz.fill", tint: .indigo)
        return true
    }

    private func sleepNow() {
        sleepTask = nil
        sleepDeadline = nil
        guard mode != .closed else { return }
        coordinator.pause()
        Toast.shared.show("취침 타이머: 재생을 멈췄습니다", symbol: "moon.zzz.fill", tint: .indigo)
    }

    func close() {
        leavingForPictureInPicture = false
        cancelSleepTimer()
        coordinator.detach()
        returnTo = nil
        queue = []
        index = 0
        mode = .closed
    }
}

// MARK: - Stage

/// The player and everything around it, in one place in the view hierarchy.
///
/// The video is a single web view that is never re-parented or rebuilt —
/// a change of presentation used to interrupt the sound. It is shown full,
/// or hidden while the system's PiP window plays from it.
struct PlayerStage: View {
    @ObservedObject var host: PlayerHost

    /// Whether the pull in progress began sideways — decided on its first
    /// movement, nil between pulls.
    @State private var pullIsSideways: Bool?
    /// The pull in progress already handed the video to PiP.
    @State private var handedOver = false
    /// How far the pull in progress has come down.
    @State private var pull: CGFloat = 0

    var body: some View {
        if host.isVisible, let current = host.current {
            GeometryReader { geo in
                let fullWidth = geo.size.width
                // Full width, until that makes the video too tall — iPad in
                // landscape — when it stops growing and sits centred. A phone
                // on its side is the opposite case: turning it is the request
                // to watch, so the video takes the height it can. Measured,
                // not asked of the device, so a short split view on an iPad
                // behaves like the small screen it is.
                let isLandscape = geo.size.width > geo.size.height
                let isShort = geo.size.height < 520
                let heightShare: CGFloat = (isLandscape && isShort) ? 1 : 0.5
                let videoHeight = min(fullWidth * 9 / 16, geo.size.height * heightShare)
                let videoWidth = videoHeight * 16 / 9

                ZStack(alignment: .topLeading) {
                    WatchScreen()
                        .padding(.top, videoHeight)
                        .background(Color(.systemBackground))
                        // The page dims away under a pull, as the video lifts
                        // off it.
                        .opacity(1 - min(pull, 360) / 520)

                    // The band the video sits in, full width even when the
                    // video is narrower: beside a capped video the page
                    // background showed — white in light mode, beside black.
                    Color.black
                        .frame(width: fullWidth, height: videoHeight)
                        .allowsHitTesting(false)

                    ZStack {
                        Color.black
                        FocusPlayerView(videoId: current.id, coordinator: host.coordinator)
                        CoordinatorOverlays(coordinator: host.coordinator, host: host, expanded: true)
                    }
                    .frame(width: videoWidth, height: videoHeight)
                    // Under the finger from the first point of a pull, and
                    // a little smaller the further it goes — so the pull is
                    // answered at once, before PiP has taken the video.
                    // Smaller the further it comes — toward the size of the
                    // window it is about to become.
                    .scaleEffect(1 - min(pull, 360) / 720, anchor: .top)
                    // Handed to PiP: from here the system's window is the
                    // video. See videoInPictureInPicture.
                    .opacity(host.videoInPictureInPicture || host.mode == .pip ? 0 : 1)
                    .offset(x: (fullWidth - videoWidth) / 2, y: pull)
                    // High priority: the web view's own recognisers would
                    // otherwise claim a pull that starts on the video.
                    .highPriorityGesture(pullDown)
                }
            }
            .onChange(of: host.mode) { _, _ in pull = 0 }
            // Hidden in PiP, not removed: PiP plays from this web view.
            // Switched in one frame — see PlayerHost's pipWatch.
            .opacity(host.mode == .pip ? 0 : 1)
            .allowsHitTesting(host.mode != .pip)
            .transition(.opacity)
        }
    }

    /// A pull down on the video, as YouTube's own: the video stays under
    /// the finger, shrinking, for as long as the pull is slow; a flick, or a
    /// pull past a third of the way, hands it to PiP there and then — the
    /// system carries it to the corner from where the finger left it. Let
    /// go short of that and it springs back. Paused, the same pull closes
    /// the player. Sideways swipes are left alone.
    ///
    /// `minimumDistance` is small but not zero: a gesture that began at
    /// zero would swallow the taps meant for YouTube's play and pause.
    private var pullDown: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                if pullIsSideways == nil {
                    pullIsSideways = abs(value.translation.width) > abs(value.translation.height) * 1.5
                }
                guard pullIsSideways == false, !handedOver else { return }
                pull = max(0, value.translation.height)
                // A flick — the finger speeding down — or far enough.
                let flicked = value.velocity.height > 1100 && pull > 24
                if flicked || pull > 240 {
                    handOver()
                }
            }
            .onEnded { value in
                let decided = handedOver
                let sideways = pullIsSideways != false
                pullIsSideways = nil
                handedOver = false
                guard !decided, !sideways else {
                    if !decided { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pull = 0 } }
                    return
                }
                // Let go: far enough, or thrown, goes; otherwise back.
                if pull > 110 || value.predictedEndTranslation.height > 300 {
                    handOver()
                    handedOver = false
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pull = 0 }
                }
            }
    }

    private func handOver() {
        handedOver = true
        host.dock()
        // Held where the finger left it while PiP takes the video — the
        // page leaves in one cut, and `pull` is reset with it (onChange of
        // the mode). If the player is still here after the system's
        // animation would have finished, PiP was refused: back it goes.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if host.mode == .full, pull > 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pull = 0 }
            }
        }
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

/// Reserves the bottom furniture a tab sits above — on iPad the app's own
/// tab bar, which the system does not inset anything for.
///
/// This belongs *inside* each tab's `NavigationStack`, next to that screen's
/// own bottom furniture: a NavigationStack does not pass an outer bottom
/// inset down to the scroll view inside it.
struct BottomChrome: ViewModifier {
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
                    // Zero on iPhone.
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


/// The end card, the error card and the double-tap ripple.
///
/// They read the coordinator, and PlayerStage observes only PlayerHost — so
/// when they lived inline there, nothing the coordinator published ever
/// re-rendered them. The double-tap ripple never appeared. Worse, an error
/// the watchdog had already WITHDRAWN stayed on screen, because nothing
/// re-drew the card after errorMessage went back to nil; docking the player
/// changed PlayerHost, forced a re-render and made it vanish — which is
/// exactly how "the player comes back if I dock it and come back" looked.
/// Observing the coordinator here makes each of them follow its state.
private struct CoordinatorOverlays: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let host: PlayerHost
    let expanded: Bool

    var body: some View {
        // The end-screen guard, painted the instant ENDED arrives so
        // YouTube's suggestion grid never gets a frame.
        if coordinator.didEnd, SolaPraiseConfig.endBehavior == .overlay, expanded {
            PlayerEndCard(host: host)
        }
        if let message = coordinator.errorMessage, expanded {
            PlayerErrorCard(host: host, message: message)
        }
        // The ripple a double-tap leaves, as in YouTube. Never hit-testable:
        // it is feedback, and the next tap has to reach the player under it.
        if expanded {
            SkipFlashView(flash: coordinator.skipFlash)
                .allowsHitTesting(false)
        }
    }
}

/// YouTube's double-tap feedback: a pale half-disc against the tapped edge
/// with the chevrons and the seconds skipped, fading out by itself.
private struct SkipFlashView: View {
    let flash: PlayerCoordinator.SkipFlash?
    @State private var visible = false

    var body: some View {
        GeometryReader { geo in
            if let flash, visible {
                let width = geo.size.width / 3
                ZStack {
                    // A circle much larger than the band, clipped to it, so
                    // the inner edge curves the way YouTube's does.
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: geo.size.height * 2.2, height: geo.size.height * 2.2)
                        .offset(x: flash.forward ? geo.size.height * 0.75 : -geo.size.height * 0.75)

                    VStack(spacing: 4) {
                        Image(systemName: flash.forward ? "forward.fill" : "backward.fill")
                            .font(.title3)
                        Text("\(flash.seconds)초")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                }
                .frame(width: width, height: geo.size.height)
                .clipped()
                .frame(maxWidth: .infinity,
                       alignment: flash.forward ? .trailing : .leading)
                .transition(.opacity)
            }
        }
        .onChange(of: flash) { _, new in
            guard new != nil else { return }
            withAnimation(.easeOut(duration: 0.12)) { visible = true }
            let stamp = new?.at
            // Hidden only if no newer tap arrived meanwhile, so a run of
            // double-taps keeps one ripple up while its count climbs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                guard flash?.at == stamp else { return }
                withAnimation(.easeIn(duration: 0.25)) { visible = false }
            }
        }
    }
}

extension FeedFilter.Item {
    init(playable video: PlayableVideo) {
        self.init(id: video.id, title: video.title, seconds: video.durationSeconds, channel: video.channelTitle)
    }
}

extension FeedFilter {
    /// Search results as 설정 › 피드·찬양 검색 says: notices out, a Short as
    /// its original when the results hold it. `seconds`: each video's
    /// length, when known.
    static func arrangeResults(_ results: [YTSearchResult], seconds: (String) -> Int?) -> [YTSearchResult] {
        let items = results.compactMap { result -> Item? in
            guard let id = result.videoId else { return nil }
            return Item(id: id, title: result.title, seconds: seconds(id), channel: result.snippet?.channelTitle)
        }
        let byId = Dictionary(results.compactMap { r in r.videoId.map { ($0, r) } }, uniquingKeysWith: { first, _ in first })
        return arrange(items).compactMap { byId[$0.id] }
    }
}
