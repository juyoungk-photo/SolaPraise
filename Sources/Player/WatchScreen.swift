//
//  WatchScreen.swift
//  SolaPraise
//
//  The focused player screen. Deliberately bare: player, title, actions.
//  No comments, no related rail, no up-next feed. "Next" exists only when
//  you are inside a playlist, and never fires on its own — nothing here
//  advances without a tap.
//

import AVFoundation
import SwiftUI
import SwiftData

// MARK: - What can be played

struct PlayableVideo: Identifiable, Hashable {
    let id: String              // YouTube video id
    let title: String
    let channelTitle: String?
    let durationSeconds: Int?
    /// Carried so the player can show which upload this is — comparing
    /// versions of the same worship song is routine, and title plus channel
    /// alone does not distinguish a studio cut from a live set.
    let publishedAt: Date?
    let viewCount: Int?
    /// Which channel this came from, so the player can tell a 찬양 upload from
    /// a 말씀 one without guessing from the title.
    let channelId: String?

    init(id: String, title: String, channelTitle: String? = nil,
         durationSeconds: Int? = nil, publishedAt: Date? = nil, viewCount: Int? = nil,
         channelId: String? = nil) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.viewCount = viewCount
        self.channelId = channelId
    }

    /// Built from the cache with everything it holds.
    ///
    /// Constructing these by hand at a dozen call sites meant most of them
    /// passed only id, title and channel, so the player showed no publish date
    /// for videos whose date the app already had sitting in the cache.
    init(cached video: CachedVideo) {
        self.init(id: video.videoId,
                  title: video.title,
                  channelTitle: video.channelTitle,
                  durationSeconds: video.durationSeconds,
                  publishedAt: video.publishedAt,
                  viewCount: video.viewCount,
                  channelId: video.channelId)
    }

    /// Built from a playlist item, whose `videoPublishedAt` is the upload
    /// date — not the date it was added to the playlist.
    init?(item: YTPlaylistItem) {
        guard let id = item.videoId else { return nil }
        self.init(id: id,
                  title: item.title,
                  channelTitle: item.channelTitle,
                  publishedAt: item.contentDetails?.videoPublishedAt,
                  channelId: item.channelId)
    }

    /// i.ytimg.com serves art for every video at a fixed path, so the queue and
    /// the add-sheet can show a thumbnail without every call site having to
    /// carry one through.
    var thumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }
}

// MARK: - Screen

struct WatchScreen: View {
    @EnvironmentObject private var host: PlayerHost

    /// All of these read through the host, so the screen is a view onto a
    /// player that outlives it rather than the thing that owns it.
    private var queue: [PlayableVideo] { host.queue }
    private var index: Int { host.index }
    private var player: PlayerCoordinator { host.coordinator }

    @State private var addTarget: PlayableVideo?
    @StateObject private var detection = DetectionSession()
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.modelContext) private var context
    @State private var worshipSet: [WorshipSetItem] = []
    @State private var sheetLinks: [SheetMusicLink] = []
    @State private var leadSheet: SavedSong?
    /// A whole set handed to the music stand, identified so fullScreenCover
    /// can key off it.
    private struct PerformanceSet: Identifiable {
        let id = UUID()
        let songs: [SavedSong]
    }
    @State private var performanceSet: PerformanceSet?
    @State private var hasExternalInput = AudioEngine.hasExternalInput
    @State private var startedEngineForRecording = false
    @Query private var channels: [Channel]
    @Query(sort: [SortDescriptor(\SavedSong.sourceStart)])
    private var allSongs: [SavedSong]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL


    private var current: PlayableVideo? {
        queue.indices.contains(index) ? queue[index] : nil
    }
    private var hasNext: Bool { index + 1 < queue.count }
    private var hasPrevious: Bool { index > 0 }
    private var isPlaylist: Bool { queue.count > 1 }

    /// Everything except the player itself.
    ///
    /// The video is drawn by PlayerStage and stays in one place in the view
    /// tree across both presentations. Moving it between a cover and an
    /// overlay re-parented the WKWebView, which briefly cut the audio and
    /// made the change a jump rather than a movement.
    var body: some View {
        VStack(spacing: 0) {
            header
            // What is playing stays under the player, where it belongs. It
            // used to scroll away with everything else, so reading the psalm
            // meant losing sight of which upload you were hearing — exactly
            // the thing you compare versions by.
            nowPlayingBlock
            ScrollView {
                VStack(spacing: 0) {
                    extrasBlock
                    if isPlaylist { queueBlock }
                }
                // Clear of the iPad's floating tab bar, which now stays on
                // top of the expanded player. Without this the last song in
                // a 재생목록 sat behind it.
                .padding(.bottom, AppLayout.usesCustomTabBar
                         ? AppLayout.tabBarHeight + AppLayout.floatingInset
                         : 0)
            }
        }
        .background(Color(.systemBackground))
        .onChange(of: player.didEnd) { _, ended in
            guard ended else { return }
            logWatch(completed: true)
            finishDetection(showSheet: SolaPraiseConfig.endBehavior == .overlay)
            if SolaPraiseConfig.endBehavior == .dismiss { host.close() }
        }
        // A video the player can never show should stop being offered.
        //
        // FeedStore has no prune: a 찬양 upload that is later deleted, made
        // private, or set to block embedding stays in the cache for good,
        // and its thumbnail keeps resolving from Google's CDN — so the feed
        // shows a perfectly normal card that says "Video unavailable" the
        // moment it is pressed, every time, forever. Checked against the
        // live channels: embeddable=true and no region or age restriction on
        // 45 recent uploads, which leaves the stale cache entry as the thing
        // actually producing this.
        //
        // Dropped on the player's own verdict rather than by polling every
        // cached video's status, which would be a call per fifty videos per
        // refresh to catch something that happens rarely.
        .onChange(of: host.coordinator.errorCode) { _, code in
            guard let code, [100, 101, 150, 152].contains(code),
                  let id = current?.id else { return }
            dropFromFeed(id)
        }
        .onChange(of: player.isReady) { _, ready in
            #if DEBUG
            guard ready, DebugHarness.seeksToEnd, player.duration > DebugHarness.tailSeconds else { return }
            player.seek(to: player.duration - DebugHarness.tailSeconds)
            player.play()
            #endif
        }
        .sheet(item: $addTarget) { AddToPlaylistSheet(video: $0) }
        .sheet(item: $leadSheet) { song in
            NavigationStack { LeadSheetView(song: song) }
        }
        .fullScreenCover(item: $performanceSet) { set in
            PerformanceModeView(songs: set.songs)
        }
        .onAppear {
            loadWorshipSet()
            hasExternalInput = AudioEngine.hasExternalInput
            host.onAdvance = { advance() }
            host.onClose = { finishAndClose() }
            host.onFindAlternate = { await findPlayableAlternate() }
        }
        // Plugging an interface in mid-video should make the button appear.
        .onReceive(NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification
        )) { _ in
            hasExternalInput = AudioEngine.hasExternalInput
        }
        .onChange(of: index) { _, _ in
            // Otherwise the next song's chords land in the previous song's
            // chart, at timestamps from a different recording.
            finishDetection(showSheet: false)
            loadWorshipSet()
        }
        // No detach here: leaving this screen for the mini player must not
        // tear the player down. Teardown belongs to host.close().
        .onDisappear {
            detection.stop()
            startedEngineForRecording = false
        }
    }

    // MARK: - Header

    /// A plain row rather than a navigation bar: the player screen has no
    /// push destinations, and a NavigationStack would have put its own chrome
    /// between the video and the metadata.
    private var header: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(Self.stageAnimation) { host.minimize() }
            } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("작게 보기")

            Button { finishAndClose() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("닫기")

            Spacer()

            if isPlaylist {
                Text("\(index + 1) / \(queue.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button { goPrevious() } label: { Image(systemName: "backward.end.fill") }
                    .disabled(!hasPrevious)
                    .accessibilityLabel("이전 곡")

                Button { advance() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(!hasNext)
                    .accessibilityLabel("다음 곡")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static let stageAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)

    // MARK: - Queue

    /// The rest of the playlist, in order, so you can see what is coming and
    /// jump straight to it. Scrolls with the metadata rather than pinning to
    /// the bottom — the player stays put, everything below it moves together.
    private var queueBlock: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.top, 16)

                Text("재생목록 \(queue.count)곡")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ForEach(Array(queue.enumerated()), id: \.element.id) { position, item in
                    SwipeToRemoveRow {
                        removeFromQueue(position)
                    } content: {
                        HStack(spacing: 10) {
                            Group {
                                if position == index {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                } else {
                                    Text("\(position + 1)")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .frame(width: 22)

                            VideoMetaRow(video: item, thumbnailWidth: 72)

                            // Per song, not just for whatever is playing.
                            // A 콘티 is worked through one song at a time,
                            // and the chart you want is usually for the one
                            // you are about to rehearse rather than the one
                            // currently sounding.
                            SheetMusicMenu(title: item.title) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            AudioSourceMenu(title: item.title,
                                            seconds: item.durationSeconds,
                                            artist: item.channelTitle) {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // This song, not the whole playlist.
                            //
                            // 콘티에 추가 existed only for whatever was
                            // sounding, so picking one song out of a
                            // 재생목록 meant playing it first just to reach
                            // the button. Choosing a song for Sunday is
                            // something you do while scanning a list, which
                            // is exactly where the other two per-song
                            // actions already live.
                            AddToServiceMenu(
                                title: item.title,
                                videoId: item.id,
                                key: existingSheet(forVideo: item.id)?.keyLabel
                            ) {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        // Opaque, so the row slides over the delete button
                        // behind it instead of letting it show through.
                        .background(
                            position == index
                                ? Color.accentColor.opacity(0.12)
                                : Color(.systemBackground)
                        )
                        // A tap gesture rather than a Button wrapping the
                        // row: a Button takes the drag before the swipe can
                        // see it, which is why nothing moved when a queue row
                        // was pulled sideways. The same trap the playlist
                        // rows fell into.
                        .contentShape(Rectangle())
                        .onTapGesture { jump(to: position) }
                    }
                    .id(position)
                }
            }
            .padding(.bottom, 24)
            .onChange(of: index) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Jumping counts as finishing the current video for watch stats, the same
    /// as pressing Next — otherwise a skipped song is silently unrecorded.
    private func removeFromQueue(_ position: Int) {
        let nowPlayingChanged = host.remove(at: position)
        guard nowPlayingChanged, host.queue.indices.contains(host.index) else { return }
        player.load(videoId: host.queue[host.index].id)
    }

    private func jump(to position: Int) {
        guard queue.indices.contains(position), position != index else { return }
        logWatch(completed: false)
        host.index = position
        player.load(videoId: queue[position].id)
    }

    // MARK: - Metadata + actions

    private var nowPlayingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.title)
                        .font(.headline)
                        .lineLimit(2)

                    VStack(alignment: .leading, spacing: 3) {
                        if let channel = current.channelTitle {
                            Text(channel).font(.subheadline)
                        }
                        metaLine(current)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            actionRow

            // Unfolds directly under the player the moment 코드 is pressed.
            //
            // It used to live in extrasBlock, further down a page that
            // scrolls — below the fold on a phone. So pressing 코드 changed
            // nothing you could see: the app was already listening, and the
            // screen read as frozen. The feedback has to be where the button
            // is.
            if detection.isRecording || detection.isStarting || detection.permissionDenied {
                chordPanel
                    .padding(.top, 10)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.snappy(duration: 0.25), value: detection.isRecording)
        .animation(.snappy(duration: 0.25), value: detection.isStarting)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 코드 detection is offered for 찬양 only.
    ///
    /// Unknown channels — a result from a search across all of YouTube — get
    /// the button, since that is where songs come from. A channel you have
    /// filed under 말씀 or 교제 does not.
    private var showsChordButton: Bool {
        guard let channelId = current?.channelId else { return true }
        guard let channel = channels.first(where: { $0.youtubeChannelId == channelId })
        else { return true }
        return channel.purpose == .worship
    }

    /// The facts that separate one upload of a worship song from another.
    ///
    /// The date is absolute AND relative: "2019년 5월 3일" says which release
    /// this is, "6년 전" says at a glance how old it is, and a title very
    /// often carries neither.
    @ViewBuilder
    private func metaLine(_ video: PlayableVideo) -> some View {
        HStack(spacing: 6) {
            if let published = video.publishedAt {
                Text(published, format: .dateTime.year().month().day())
                Text(published, format: .relative(presentation: .named))
                    .foregroundStyle(.tertiary)
            } else {
                Text("게시일 정보 없음").foregroundStyle(.tertiary)
            }
            if let secs = video.durationSeconds {
                Text("·")
                Text(ISO8601Duration.format(secs)).monospacedDigit()
            }
            if let views = video.viewCount {
                Text("·")
                Text("조회 \(Self.compactCount(views))").monospacedDigit()
            }
        }
        .font(.caption)
    }

    private var actionRow: some View {
        // Scrollable, and every label fixed at its natural width.
        //
        // The row has grown to five buttons. On an iPad the stack still
        // overflowed, and SwiftUI answers an overflowing HStack by squeezing
        // its children — so the labels were truncated rather than a button
        // dropped, and 「콘티에 추가」 came out cut. A button whose name is cut
        // is a button you have to guess at.
        ScrollView(.horizontal, showsIndicators: false) {
            actionButtons
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                addTarget = current
            } label: {
                Label("Playlist", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .disabled(current == nil)

            if let current, let url = YouTubeID.watchURL(current.id) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            // Recording while the video plays.
            //
            // Offered only with an interface connected, because it is only
            // meaningful then: what gets written is the INPUT — you playing
            // along — not the app's output. On the built-in microphone that
            // would be a room recording of a tablet speaker, which is worth
            // nothing to anybody.
            if hasExternalInput {
                Button {
                    if detection.audio.isWritingFile { stopSideRecording() }
                    else { startSideRecording() }
                } label: {
                    Label(
                        detection.audio.isWritingFile
                            ? clock(detection.audio.recordedSeconds)
                            : "녹음",
                        systemImage: detection.audio.isWritingFile
                            ? "stop.circle" : "record.circle"
                    )
                    .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .tint(detection.audio.isWritingFile ? .red : .accentColor)
            }

            // Deciding a song belongs on Sunday happens while listening
            // to it, so the action lives next to the player.
            if showsChordButton, let current {
                AddToServiceMenu(
                    title: current.title,
                    videoId: current.id,
                    key: existingSheet(forVideo: current.id)?.keyLabel
                ) {
                    Label("콘티에 추가", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            // 코드 is for 찬양. A QT or a psalm reading has nothing to
            // detect, and the button only invited a pointless wait there.
            if showsChordButton {
                Button {
                    if detection.isStarting {
                        detection.cancelStart()
                    } else if detection.isRecording {
                        finishDetection(showSheet: true)
                    } else {
                        startDetection()
                    }
                } label: {
                    if detection.isStarting {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("취소")
                        }
                    } else {
                        Label(
                            detection.isRecording ? "정지" : "코드",
                            systemImage: detection.isRecording ? "stop.circle" : "music.note"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .tint(detection.isRecording || detection.isStarting ? .red : .accentColor)
                .disabled(current == nil)
            }
        }
        .font(.subheadline)
        .controlSize(.small)
        // Each button keeps its own width instead of being compressed to
        // fit — the scroll view is what absorbs the overflow now.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 1)
    }

    /// Everything that is worth reading but not worth pinning.
    private var extrasBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A reading or a sermon shows one static frame for an hour, and
            // the passage it is working through is named in the title. Any
            // book, not just the Psalms — 모닝워십 walks 사사기 for weeks.
            if let passage = current.flatMap({ ScriptureReference.passage(in: $0.title) }) {
                ScripturePanel(passage: passage)
            }

            if !sheetsForThisVideo.isEmpty {
                savedSheetsList
            }

            if !worshipSet.isEmpty {
                worshipSetList
            }

            // Always offered on 찬양, not only when the channel happened to
            // publish a link. Most worship uploads publish none, so the
            // official chart — which usually exists and is sold by the team
            // that wrote the song — was invisible almost every time.
            if showsChordButton, let current {
                AudioSourceMenu(title: current.title,
                                seconds: current.durationSeconds,
                                artist: current.channelTitle) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("음원 찾기").font(.subheadline)
                            // Says why, because the reason is not obvious:
                            // the app cannot analyse what it is playing.
                            Text("파일을 받으면 작업실에서 코드 분석이 됩니다")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                SheetMusicMenu(title: current.title, published: sheetLinks) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(sheetLinks.isEmpty ? "공식 악보 찾기" : "공식 악보")
                            .font(.subheadline)
                        if !sheetLinks.isEmpty {
                            Text("\(sheetLinks.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// 12,300 → "1.2만", 4,500,000 → "450만"
    static func compactCount(_ n: Int) -> String {
        switch n {
        case 100_000_000...: return String(format: "%.1f억", Double(n) / 100_000_000)
        case 10_000...:      return String(format: "%.0f만", Double(n) / 10_000)
        case 1_000...:       return String(format: "%.1f천", Double(n) / 1_000)
        default:             return "\(n)"
        }
    }

    // MARK: - Sheets already made from this video

    /// Charts this video has already produced.
    ///
    /// Without this a detection run vanished into 악보 and the video had no
    /// memory of it, so the only way to tell whether a set had been analysed
    /// was to analyse it again.
    private var sheetsForThisVideo: [SavedSong] {
        guard let id = current?.id else { return [] }
        return allSongs.filter { $0.videoId == id }
    }

    private var savedSheetsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("이 영상의 악보")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { performanceSet = PerformanceSet(songs: sheetsForThisVideo) } label: {
                    Label("연주 모드", systemImage: "music.note.tv")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ForEach(sheetsForThisVideo) { song in
                Button { leadSheet = song } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title)
                                .font(.footnote)
                                .lineLimit(1)
                                .foregroundStyle(Color.primary)
                            HStack(spacing: 5) {
                                if let key = song.keyLabel {
                                    Text(key)
                                    if song.keyIsPublished {
                                        Text("공식").foregroundStyle(.green)
                                    }
                                }
                                if song.hasLyrics { Text("· 가사") }
                                Text("· ^[\(song.chords.count) chord](inflect: true)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        if song.sourceStart > 0 {
                            Button {
                                player.seek(to: song.sourceStart)
                                player.play()
                            } label: {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                        // Detection is a guess, and a wrong chart is worth
                        // less than none — it has to be removable where you
                        // are looking at it, not three screens away in
                        // 작업실. Nothing leaves the device, so there is no
                        // undo bar: running it again is cheap.
                        Button(role: .destructive) {
                            delete(song)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("악보 삭제")

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Removes a video the player has just refused from the cached feed.
    ///
    /// The cache only, never the playlist or the sheet: this says "the app
    /// cannot show this", which is not the same as "the team did not choose
    /// it". A 콘티 row keeps its song, and the next feed refresh will bring
    /// the video back if YouTube was simply having a bad minute.
    private func dropFromFeed(_ videoId: String) {
        let descriptor = FetchDescriptor<CachedVideo>(
            predicate: #Predicate { $0.videoId == videoId }
        )
        guard let stale = try? modelContext.fetch(descriptor), !stale.isEmpty else { return }
        for video in stale { modelContext.delete(video) }
        try? modelContext.save()
    }

    private func delete(_ song: SavedSong) {
        if leadSheet?.id == song.id { leadSheet = nil }
        modelContext.delete(song)
        try? modelContext.save()
    }

    // MARK: - Published worship set

    /// The set list the channel published in its description: song order,
    /// start times and the key they actually played in. Tapping jumps there.
    private var worshipSetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("찬양 순서")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(worshipSet) { item in
                Button {
                    player.seek(to: item.start)
                    player.play()
                } label: {
                    HStack(spacing: 10) {
                        Text(item.timeLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                            .frame(minWidth: 44, alignment: .leading)

                        Text(item.title)
                            .font(.footnote)
                            .lineLimit(1)
                            .foregroundStyle(Color.primary)

                        Spacer(minLength: 4)

                        if let key = item.key {
                            Text(key)
                                .font(.caption.weight(.semibold).monospaced())
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color(.secondarySystemBackground))
                                )
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground).opacity(0.6))
        )
    }

    /// Where this worship team publishes its own 악보 — the authoritative
    /// chart, rather than an estimate of one.
    private var sheetMusicRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("공식 악보")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(sheetLinks) { link in
                Button {
                    openURL(link.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(Color.accentColor)
                        Text(link.label)
                            .font(.footnote)
                            .lineLimit(1)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground).opacity(0.6))
        )
    }

    private func loadWorshipSet() {
        guard let current else { worshipSet = []; sheetLinks = []; return }
        let id = current.id
        let cached = try? context.fetch(FetchDescriptor<CachedVideo>(
            predicate: #Predicate { $0.videoId == id }
        )).first
        worshipSet = cached?.worshipSet ?? []
        sheetLinks = WorshipSetParser.sheetMusicLinks(cached?.descriptionText ?? "")
    }

    // MARK: - Finding a playable upload

    /// Searches for another upload of the same song that permits embedding.
    /// Costs one search (100 units), so it is a deliberate tap rather than
    /// something that fires automatically on every blocked video.
    private func findPlayableAlternate() async {
        guard let current else { return }
        guard auth.canReadYouTube else {
            host.alternateError = "다른 영상을 찾으려면 Google 로그인이 필요합니다."
            return
        }
        host.isFindingAlternate = true
        host.alternateError = nil
        defer { host.isFindingAlternate = false }

        // Strip bracketed prefixes and channel suffixes so the query is the
        // song, not the uploader's decoration.
        var query = current.title
        query = query.replacingOccurrences(
            of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression
        )
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            // search already requests videoEmbeddable=true, so anything
            // returned here is playable in-app.
            let results = try await client.search(query: query, maxResults: 10)
            guard let match = results.first(where: { $0.videoId != nil && $0.videoId != current.id }),
                  let id = match.videoId else {
                host.alternateError = "재생 가능한 다른 영상을 찾지 못했습니다."
                return
            }
            player.load(videoId: id)
        } catch {
            host.alternateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func existingSheet(forVideo id: String) -> SavedSong? {
        allSongs.first { $0.videoId == id }
    }

    // MARK: - Recording alongside playback

    /// Adds file writing to whatever is already running, or starts the engine
    /// for recording alone. Chord detection and recording share one engine, so
    /// turning one on must not disturb the other.
    private func startSideRecording() {
        let name = current?.title ?? "녹음"
        if detection.isRecording {
            let url = Recordings.newFileURL(title: name)
            try? detection.audio.startWriting(
                to: url, sampleRate: detection.audio.currentSampleRate
            )
        } else {
            startedEngineForRecording = true
            detection.startRecordingToFile(title: name, analyzing: false)
        }
    }

    private func stopSideRecording() {
        detection.audio.stopWriting()
        // Only tear the engine down if recording was the reason it came up —
        // otherwise this would silently end a chord run too.
        if startedEngineForRecording, !detection.isRecording {
            detection.stop()
        }
        startedEngineForRecording = false
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Chord detection panel

    /// Live readout while listening. Audio comes out of the speaker and back
    /// in through the mic, so this needs a real device — the Simulator has no
    /// microphone and will simply sit at "듣는 중".
    private var chordPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if detection.permissionDenied {
                Label("마이크 권한이 필요합니다. 설정에서 허용해 주세요.", systemImage: "mic.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                InputSourceBanner(audio: detection.audio, compact: true)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(detection.currentChord?.symbol()
                         ?? (detection.isStarting ? "준비 중…" : "듣는 중…"))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())

                    VStack(alignment: .leading, spacing: 2) {
                        if let key = detection.detectedKey {
                            Text("Key \(key)").font(.caption)
                        }
                        Text("\(detection.history.count)개 코드")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView(value: Double(detection.confidence))
                        .frame(width: 60)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Chord detection

    /// Chords are timed against the video, and only while it is actually
    /// playing — a paused player produces silence, and silence analysed is
    /// just noise filed as chords.
    private func startDetection() {
        detection.positionProvider = { [player] in
            guard player.state == .playing else { return nil }
            return player.currentTime
        }
        // Back to the top, and playing.
        //
        // Detection starts hearing at the moment it is switched on, so
        // pressing 코드 three minutes into a song produced a chart that began
        // at the bridge — with the first three minutes simply missing and
        // nothing saying so. The structure pass then read that fragment as
        // the whole song. Rewinding costs the listener the few seconds they
        // had already heard and makes the chart cover the song.
        player.seek(to: 0)
        player.play()
        detection.start()
    }

    private func finishDetection(showSheet: Bool) {
        guard detection.isRecording else { return }
        detection.stop()
        guard !detection.history.isEmpty else { return }

        let songs = buildSongs()
        guard !songs.isEmpty else { return }
        for song in songs { modelContext.insert(song) }
        try? modelContext.save()
        if showSheet { leadSheet = songs.first }
    }

    /// One sheet per song, not one sheet per video.
    ///
    /// A 찬양 upload is usually a forty-minute set of five songs, and a single
    /// chart spanning all of them is not a chart of anything. The channel
    /// publishes the boundaries itself — start time, title, and very often the
    /// key the team actually played in — so a run is sliced along them.
    ///
    /// This only became possible once chord timestamps came from the video's
    /// position rather than the wall clock: the set list's times and the
    /// detection's times are now the same clock.
    private func buildSongs() -> [SavedSong] {
        let history = detection.history.sorted { $0.timestamp < $1.timestamp }
        let url = current.flatMap { YouTubeID.watchURL($0.id) }

        guard worshipSet.count > 1 else {
            let session = Session(
                title: current?.title ?? "Untitled",
                youTubeURL: url,
                detectedKey: detection.detectedKey,
                createdAt: Date(),
                chords: history.map { SessionChord(chord: $0.chord, timestamp: $0.timestamp) }
            )
            return [SavedSong(
                session: session,
                sections: SongStructure.detect(chords: session.chords),
                videoId: current?.id,
                publishedKey: worshipSet.first?.key
            )]
        }

        var result: [SavedSong] = []
        for (index, item) in worshipSet.enumerated() {
            let end = index + 1 < worshipSet.count
                ? worshipSet[index + 1].start
                : TimeInterval.greatestFiniteMagnitude

            // Rebased to the song's own start, so its chart reads from 0:00
            // rather than from 24 minutes into someone else's set.
            let chords = history
                .filter { $0.timestamp >= item.start && $0.timestamp < end }
                .map { SessionChord(chord: $0.chord, timestamp: $0.timestamp - item.start) }

            // A handful of readings is a transition or a spoken introduction,
            // not a song worth filing.
            guard chords.count >= 4 else { continue }

            let session = Session(
                title: item.title,
                youTubeURL: url,
                detectedKey: detection.detectedKey,
                createdAt: Date(),
                chords: chords
            )
            result.append(SavedSong(
                session: session,
                sections: SongStructure.detect(chords: chords),
                videoId: current?.id,
                publishedKey: item.key,
                sourceStart: item.start
            ))
        }
        return result
    }

    // MARK: - Actions

    private func advance() { move(by: 1) }

    private func goPrevious() { move(by: -1) }

    /// Steps through the queue, swapping the video inside the live player
    /// rather than reloading the document.
    private func move(by delta: Int) {
        logWatch(completed: delta > 0 && player.didEnd)
        let target = index + delta
        guard queue.indices.contains(target) else { return }
        host.index = target
        if let next = current {
            player.load(videoId: next.id)
        }
    }

    private func finishAndClose() {
        logWatch(completed: player.didEnd)
        host.close()
    }

    // MARK: - Watch log

    /// Records how much of the current video was actually watched. Uses the
    /// high-water mark so seeking backwards doesn't shrink the total.
    private func logWatch(completed: Bool) {
        guard let current else { return }
        let seconds = Int(player.maxTimeReached.rounded())
        guard seconds > 0 else { return }

        modelContext.insert(
            WatchEvent(
                videoId: current.id,
                title: current.title,
                secondsWatched: seconds,
                completed: completed
            )
        )
        try? modelContext.save()
    }
}
