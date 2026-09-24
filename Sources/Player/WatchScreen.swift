//
//  WatchScreen.swift
//  SolaPraise
//
//  The focused player screen. Deliberately bare: player, title, actions.
//  No comments, no related rail, no up-next feed. "Next" exists only when
//  you are inside a playlist, and never fires on its own — nothing here
//  advances without a tap.
//

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

    init(id: String, title: String, channelTitle: String? = nil,
         durationSeconds: Int? = nil, publishedAt: Date? = nil, viewCount: Int? = nil) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.viewCount = viewCount
    }
}

// MARK: - Screen

struct WatchScreen: View {
    let queue: [PlayableVideo]

    @State private var index: Int
    @State private var addTarget: PlayableVideo?
    @StateObject private var detection = DetectionSession()
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @State private var isFindingAlternate = false
    @State private var alternateError: String?
    @Environment(\.modelContext) private var context
    @State private var worshipSet: [WorshipSetItem] = []
    @State private var sheetLinks: [SheetMusicLink] = []
    @State private var leadSheet: SavedSong?
    @StateObject private var player = PlayerCoordinator()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    init(queue: [PlayableVideo], startIndex: Int = 0) {
        self.queue = queue
        _index = State(initialValue: max(0, min(startIndex, queue.count - 1)))
    }

    init(video: PlayableVideo) {
        self.init(queue: [video], startIndex: 0)
    }

    private var current: PlayableVideo? {
        queue.indices.contains(index) ? queue[index] : nil
    }
    private var hasNext: Bool { index + 1 < queue.count }
    private var hasPrevious: Bool { index > 0 }
    private var isPlaylist: Bool { queue.count > 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playerBlock
                metadataBlock
                Spacer(minLength: 0)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { finishAndClose() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .principal) {
                    if isPlaylist {
                        Text("\(index + 1) / \(queue.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isPlaylist {
                        Button { goPrevious() } label: {
                            Image(systemName: "backward.end.fill")
                        }
                        .disabled(!hasPrevious)
                        .accessibilityLabel("이전 곡")

                        Button { advance() } label: {
                            Image(systemName: "forward.end.fill")
                        }
                        .disabled(!hasNext)
                        .accessibilityLabel("다음 곡")
                    }
                }
            }
        }
        .onChange(of: player.didEnd) { _, ended in
            guard ended else { return }
            logWatch(completed: true)
            if SolaPraiseConfig.endBehavior == .dismiss { dismiss() }
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
        .onAppear { loadWorshipSet() }
        .onChange(of: index) { _, _ in loadWorshipSet() }
        .onDisappear {
            player.detach()
            detection.stop()
        }
    }

    // MARK: - Player + overlay

    private var playerBlock: some View {
        ZStack {
            Color.black
            if let current {
                FocusPlayerView(videoId: current.id, coordinator: player)
            }

            // The end-screen guard. Painted the instant ENDED arrives, after
            // stopVideo() — so YouTube's suggestion grid never gets a frame.
            if player.didEnd && SolaPraiseConfig.endBehavior == .overlay {
                endCard
                    .transition(.opacity)
            }

            if let message = player.errorMessage {
                errorCard(message)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: player.didEnd)
    }

    private var endCard: some View {
        ZStack {
            // Opaque, not translucent — nothing of the player shows through.
            Color.black
            VStack(spacing: 18) {
                Text("Done")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    Button {
                        player.replay()
                    } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    if hasNext {
                        Button {
                            advance()
                        } label: {
                            Label("Next", systemImage: "forward.end")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        finishAndClose()
                    } label: {
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

    private func errorCard(_ message: String) -> some View {
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
                    if player.isEmbedBlocked {
                        // The song is usually available as another upload —
                        // label copies get embedding disabled, church and
                        // cover uploads generally do not.
                        Button {
                            Task { await findPlayableAlternate() }
                        } label: {
                            if isFindingAlternate {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("재생 가능한 다른 영상 찾기", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFindingAlternate || !quota.canSearch)

                        if let alternateError {
                            Text(alternateError)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }

                        if let current, let url = YouTubeID.watchURL(current.id) {
                            Button {
                                logWatch(completed: false)
                                openURL(url)
                            } label: {
                                Label("YouTube에서 열기", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }
                    if hasNext {
                        Button("다음 곡으로") { advance() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Metadata + actions

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.title)
                        .font(.headline)
                        .lineLimit(3)

                    VStack(alignment: .leading, spacing: 3) {
                        if let channel = current.channelTitle {
                            Text(channel).font(.subheadline)
                        }
                        HStack(spacing: 6) {
                            if let published = current.publishedAt {
                                Text(published, format: .dateTime.year().month().day())
                            }
                            if let secs = current.durationSeconds {
                                Text("·")
                                Text(ISO8601Duration.format(secs)).monospacedDigit()
                            }
                            if let views = current.viewCount {
                                Text("·")
                                Text("조회 \(Self.compactCount(views))").monospacedDigit()
                            }
                        }
                        .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if !worshipSet.isEmpty {
                worshipSetList
            }

            if !sheetLinks.isEmpty {
                sheetMusicRow
            }

            if detection.isRecording || detection.permissionDenied {
                chordPanel
            }

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

                Button {
                    if detection.isRecording {
                        detection.stop()
                        if !detection.history.isEmpty {
                            let session = detection.buildSession(
                                title: current?.title ?? "Untitled",
                                url: current.flatMap { YouTubeID.watchURL($0.id) }
                            )
                            let song = SavedSong(
                                session: session,
                                sections: SongStructure.detect(chords: session.chords),
                                videoId: current?.id
                            )
                            modelContext.insert(song)
                            try? modelContext.save()
                            leadSheet = song
                        }
                    } else {
                        detection.start()
                    }
                } label: {
                    Label(
                        detection.isRecording ? "정지" : "코드",
                        systemImage: detection.isRecording ? "stop.circle" : "music.note"
                    )
                }
                .buttonStyle(.bordered)
                .tint(detection.isRecording ? .red : .accentColor)
                .disabled(current == nil)
            }
            .font(.subheadline)
            .controlSize(.small)
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
        guard auth.isSignedIn else {
            alternateError = "다른 영상을 찾으려면 Google 로그인이 필요합니다."
            return
        }
        isFindingAlternate = true
        alternateError = nil
        defer { isFindingAlternate = false }

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
                alternateError = "재생 가능한 다른 영상을 찾지 못했습니다."
                return
            }
            player.load(videoId: id)
        } catch {
            alternateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
                HStack(spacing: 6) {
                    Image(systemName: detection.inputSource.isHighQuality
                          ? "cable.connector" : "mic.fill")
                        .font(.caption2)
                    Text(detection.inputSource.label)
                        .font(.caption2)
                    if detection.inputSampleRate > 0 {
                        Text("· \(Int(detection.inputSampleRate / 1000))kHz")
                            .font(.caption2.monospacedDigit())
                    }
                }
                .foregroundStyle(detection.inputSource.isHighQuality ? Color.green : Color.orange)

                if let warning = detection.inputSource.warning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(detection.currentChord?.symbol() ?? "듣는 중…")
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

    // MARK: - Actions

    private func advance() { move(by: 1) }

    private func goPrevious() { move(by: -1) }

    /// Steps through the queue, swapping the video inside the live player
    /// rather than reloading the document.
    private func move(by delta: Int) {
        logWatch(completed: delta > 0 && player.didEnd)
        let target = index + delta
        guard queue.indices.contains(target) else { return }
        index = target
        if let next = current {
            player.load(videoId: next.id)
        }
    }

    private func finishAndClose() {
        logWatch(completed: player.didEnd)
        dismiss()
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
