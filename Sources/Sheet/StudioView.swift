//
//  StudioView.swift
//  SolaPraise
//
//  작업실 — where a chart is read, played from and printed; and, for the
//  developer, where audio becomes a chart.
//
//  악보 comes first and needs nothing: bring a PDF or a photo in, open it on
//  the stand — chords read, transposed, corrected — and share it as a PDF.
//  Kept on this device (LocalScores), so it works signed out and without a
//  team. The audio tools below it are DevGate-only, as before.
//
//  Kept apart from the YouTube tabs on purpose: this is a working mode for a
//  musician, not a consumption surface. Everything that starts from sound
//  lives here — recording a line input, detecting live, analysing a file —
//  along with what comes out of it: the recordings themselves and the sheets
//  made from them — and, under 팀 악보, the charts the team attached to songs
//  in 예배 준비, so a chart from three Sundays ago is one tap away.
//
//  It gets its own tab on iPad, where there is room to read a chart, and lives
//  inside 보관함 on iPhone where the tab bar is already full.
//

import SwiftUI
import AVFoundation
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

struct StudioView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\SavedSong.createdAt, order: .reverse)])
    private var songs: [SavedSong]

    @EnvironmentObject private var analyzer: AudioFileAnalyzer
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @ObservedObject private var scores = LocalScores.shared

    /// Charts open on the 악보 stand: one, or a set to swipe through.
    private struct StandSet: Identifiable {
        let id = UUID()
        let items: [ScoreStandItem]
        var startAt = 0
        var title: String? = nil
    }
    @State private var standSet: StandSet?

    private enum ImportKind { case audio, score }
    @State private var importing: ImportKind?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var renaming: LocalScores.Item?
    @State private var newTitle = ""
    @State private var importNote: String?
    @State private var openedSong: SavedSong?
    @State private var recordings: [Recordings.Item] = []
    @State private var playing: URL?
    @State private var player: AVAudioPlayer?

    private struct PerformanceSet: Identifiable {
        let id = UUID()
        let songs: [SavedSong]
    }
    @State private var performanceSet: PerformanceSet?

    /// The audio tools are still being worked on — see DevGate.
    private var showsAudioTools: Bool { DevGate.isUnlocked(auth: auth, planning: planning) }

    var body: some View {
        NavigationStack {
            List {
                scoresSection

                if showsAudioTools {
                    audioSections
                }

                // The team's charts, for someone signed in to read them. Signed
                // out there is nothing to show, and 보관함 says how 예배 opens.
                if TeamSheetSource.current != nil, auth.isSignedIn || planning.isSignedIn {
                    teamScoresSection
                }
            }
            .fullScreenCover(item: $performanceSet) { set in
                PerformanceModeView(songs: set.songs)
            }
            .fullScreenCover(item: $standSet) { set in
                ScoreStandView(items: set.items, startAt: set.startAt, setTitle: set.title)
            }
            .task {
                recordings = Recordings.all()
                #if DEBUG
                // -uiTestImportScore <path>: as if it were picked in Files.
                if let at = DebugHarness.args.firstIndex(of: "-uiTestImportScore"), at + 1 < DebugHarness.args.count {
                    let url = URL(fileURLWithPath: DebugHarness.args[at + 1])
                    let title = url.deletingPathExtension().lastPathComponent
                    if !scores.items.contains(where: { $0.title == title }) { scores.add(fileAt: url) }
                }
                #endif
            }
            // A finished analysis can rename or consume a take, and the
            // recorder hands back control here too.
            .onChange(of: analyzer.isAnalyzing) { _, _ in recordings = Recordings.all() }
            .onDisappear { stopPlayback() }
            .bottomChrome()
            .navigationTitle("작업실")
            // See 보관함: a large title brings the system tab bar back on
            // iPadOS 26, on top of the one we draw.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !scores.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
            .navigationDestination(item: $openedSong) { song in
                LeadSheetView(song: song)
            }
            .alert("악보 이름", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("곡 제목", text: $newTitle)
                Button("저장") {
                    if let renaming { scores.rename(renaming, to: newTitle) }
                    renaming = nil
                }
                Button("취소", role: .cancel) { renaming = nil }
            }
            .alert("가져오기", isPresented: Binding(get: { importNote != nil }, set: { if !$0 { importNote = nil } })) {
                Button("확인") { importNote = nil }
            } message: { Text(importNote ?? "") }
            .onAppear { collectFromInbox() }
            .onChange(of: StudioInbox.shared.wantsStudio) { _, wants in
                if wants { collectFromInbox() }
            }
        }
        // The pickers sit on the stack, not on the list that presents the
        // stand: on the same view as the stand's cover they kept its share
        // sheet from appearing — the PDF was made and nothing showed.
        // One importer for both kinds: two on one view and SwiftUI
        // presents only the last.
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: importing == .score ? [.pdf, .image] : [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: importing == .score
        ) { result in
            let kind = importing
            importing = nil
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if kind == .score {
                let added = urls.compactMap { scores.add(fileAt: $0) }
                if added.count < urls.count { importNote = "\(urls.count - added.count)개는 PDF나 이미지로 읽지 못했습니다." }
            } else if let url = urls.first {
                analyze(url)
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                let stamp = Date().formatted(.dateTime.month().day().hour().minute())
                for (n, item) in picked.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    scores.add(photo: data, title: picked.count > 1 ? "사진 악보 \(stamp) (\(n + 1))" : "사진 악보 \(stamp)")
                }
                photoItems = []
            }
        }
    }

    // MARK: 악보 (this device)

    private var scoresSection: some View {
        Section {
            HStack(spacing: 10) {
                Button { importing = .score } label: {
                    Label("파일", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                Button { showPhotos = true } label: {
                    Label("사진", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)

            if scores.items.isEmpty {
                Text("PDF나 악보 사진을 가져오면, 연주 모드에서 코드를 읽어 조옮김하고 PDF로 공유할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(scores.items.enumerated()), id: \.element.id) { position, item in
                Button {
                    standSet = StandSet(items: [scores.standItem(for: item)])
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text((item.file as NSString).pathExtension.uppercased())
                            Text("· \(item.addedAt.formatted(.dateTime.month().day()))")
                            if let key = ScoreKeyStore.key(for: "local-\(item.id.uuidString)") {
                                Text("· \(key)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        standSet = StandSet(items: scores.items.map(scores.standItem(for:)), startAt: position, title: "악보")
                    } label: { Label("전체에서 이 곡부터", systemImage: "music.note.list") }
                    Button {
                        newTitle = item.title
                        renaming = item
                    } label: { Label("이름 바꾸기", systemImage: "pencil") }
                    Button(role: .destructive) {
                        if let index = scores.items.firstIndex(of: item) { scores.delete(at: IndexSet(integer: index)) }
                    } label: { Label("삭제", systemImage: "trash") }
                }
            }
            .onDelete { scores.delete(at: $0) }
            .onMove { scores.move(from: $0, to: $1) }
        } header: {
            HStack {
                Text("악보")
                Spacer()
                if scores.items.count > 1 {
                    // A set: swipe song to song, and 「전체」 makes one PDF.
                    Button {
                        standSet = StandSet(items: scores.items.map(scores.standItem(for:)), title: "악보")
                    } label: {
                        Label("전체 연주 모드", systemImage: "music.note.tv")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        } footer: {
            Text("이 기기에만 저장되고, 로그인이 필요 없습니다. 누르면 연주 모드로 열려 코드를 읽고 조옮김·수정한 뒤 PDF로 공유하거나 파일에 저장할 수 있습니다. 순서는 「편집」에서 바꿉니다.")
        }
    }

    // MARK: Audio (DevGate)

    @ViewBuilder
    private var audioSections: some View {
        Section {
            NavigationLink {
                LiveDetectView()
            } label: {
                Label("실시간 코드 감지", systemImage: "waveform")
            }

            NavigationLink {
                RecorderView { recordings = Recordings.all() }
            } label: {
                Label("라인 입력 녹음", systemImage: "record.circle")
            }

            Button {
                importing = .audio
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("오디오 파일에서 분석", systemImage: "waveform.badge.magnifyingglass")
                        Spacer()
                        if analyzer.isAnalyzing {
                            Text("\(Int(analyzer.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if analyzer.isAnalyzing {
                        ProgressView(value: analyzer.progress)
                        HStack {
                            Text(analyzer.stage)
                            Spacer()
                            Button("취소") { analyzer.cancel() }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(analyzer.isAnalyzing)

            if let message = analyzer.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("오디오")
        } footer: {
            Text("라인 입력(오디오 인터페이스)이 가장 정확합니다. 유튜브 오디오는 분석할 수 없습니다.")
        }

        if !recordings.isEmpty {
            Section {
                ForEach(recordings) { item in
                    recordingRow(item)
                }
                .onDelete { offsets in
                    for index in offsets where recordings.indices.contains(index) {
                        if playing == recordings[index].url { stopPlayback() }
                        Recordings.delete(recordings[index])
                    }
                    recordings = Recordings.all()
                }
            } header: {
                Text("녹음")
            } footer: {
                Text("입력을 그대로 저장한 파일입니다. 다시 분석하면 실시간보다 촘촘한 창으로 읽으므로 결과가 더 정확합니다.")
            }
        }

        Section {
            if songs.isEmpty {
                Text("아직 악보가 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(songs) { song in
                NavigationLink {
                    LeadSheetView(song: song)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).lineLimit(1)
                        HStack(spacing: 6) {
                            if let key = song.keyLabel {
                            Text(key)
                            if song.keyIsPublished {
                                Text("공식").foregroundStyle(.green)
                            }
                        }
                            Text("^[\(song.sections.count) section](inflect: true)")
                            if song.hasLyrics { Text("· 가사") }
                            // Where it came from, so 찬양 and 악보
                            // stop looking like unrelated screens.
                            if song.videoId != nil {
                                Label("영상", systemImage: "play.rectangle")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button {
                        performanceSet = PerformanceSet(songs: [song])
                    } label: { Label("연주 모드", systemImage: "music.note.tv") }

                    // The chart knows which video it was made from,
                    // and nothing was showing that. A sheet with no
                    // way back to its source is a dead end.
                    if let videoId = song.videoId {
                        Button {
                            host.play(
                                queue: [PlayableVideo(id: videoId, title: song.title)],
                                startIndex: 0
                            )
                        } label: { Label("원본 영상 재생", systemImage: "play.rectangle") }
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(songs[index]) }
                try? modelContext.save()
            }
        } header: {
            HStack {
                Text("분석한 곡")
                Spacer()
                if !songs.isEmpty {
                    // The iPad-on-a-stand case: open everything as one
                    // set and swipe between songs.
                    Button {
                        performanceSet = PerformanceSet(songs: songs)
                    } label: {
                        Label("연주 모드", systemImage: "music.note.tv")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    // MARK: 팀 악보

    /// Charts attached to songs in 예배 준비, by song. Shown only when a
    /// team sheet is set up — and then on both devices, signed in or not,
    /// with a line saying why it is empty rather than an empty section.
    private var teamScoresSection: some View {
        let entries = ScoreArchive.entries(team.attachments.values.flatMap { $0 },
                                           date: \.date, song: \.song, name: \.name)
        return Section {
            if entries.isEmpty {
                Text(team.needsAuthorization
                     ? "예배 준비에 로그인하면 팀이 곡에 첨부한 악보가 여기에 모입니다."
                     : team.isLoading ? "불러오는 중…"
                     : "아직 곡에 첨부된 악보가 없습니다. 예배 준비에서 곡에 악보를 첨부하면 여기에 모입니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                if entry.files.count == 1, let file = entry.files.first {
                    teamScoreRow(file, title: entry.song)
                } else {
                    DisclosureGroup {
                        ForEach(entry.files) { file in
                            teamScoreRow(file, title: file.name)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.song).lineLimit(1)
                            Text("악보 \(entry.files.count)개 · 최근 \(entry.latest.formatted(.dateTime.month().day()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("팀 악보")
        } footer: {
            Text("예배 준비에서 곡에 첨부한 악보입니다. 누르면 악보 연주모드로 열리고, 그날 순서의 키로 맞춰집니다.")
        }
    }

    private func teamScoreRow(_ file: Attachment, title: String) -> some View {
        Button {
            standSet = StandSet(items: [ScoreStandItem(attachment: file, song: file.song, teamKey: teamKey(for: file))])
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(file.date.formatted(.dateTime.month().day()))
                    // The key it was last played in, from the stand.
                    if let key = ScoreKeyStore.key(for: file.fileId) {
                        Text("· 악보 \(key)")
                    }
                    if title != file.name {
                        Text("· \(file.name)").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // The whole row, not just its text, and in the list's own
            // colours: a list of tinted names read as links.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("악보 연주모드로 열기")
    }

    /// The key the song was played in at the service the chart belongs to.
    private func teamKey(for file: Attachment) -> String? {
        guard let service = team.services.first(where: {
            Calendar.current.isDate($0.date, inSameDayAs: file.date)
        }) else { return nil }
        return team.plan(for: service).first { $0.title == file.song }?.key
    }

    /// A take: play it back, turn it into a chart, share it out.
    private func recordingRow(_ item: Recordings.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { toggle(item) } label: {
                    Image(systemName: playing == item.url
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    Text("\(item.durationLabel) · \(item.createdAt, format: .dateTime.month().day().hour().minute())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                analyzer.start(url: item.url, title: item.title, context: modelContext)
            } label: {
                Label("코드 분석 · 악보 만들기", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(analyzer.isAnalyzing)
        }
        .padding(.vertical, 2)
    }

    private func toggle(_ item: Recordings.Item) {
        if playing == item.url { stopPlayback(); return }
        stopPlayback()
        player = try? AVAudioPlayer(contentsOf: item.url)
        player?.play()
        playing = item.url
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }

    /// Hands the file to the app-level analyser and returns immediately, so
    /// the job survives leaving this screen — you can go and listen to
    /// something while a long recording is worked through.
    private func analyze(_ url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        analyzer.start(url: url, title: title, context: modelContext)
    }

    /// A file picked in 음원 찾기, which lives in another tab entirely.
    ///
    /// Taken rather than read, so coming back to 작업실 later does not
    /// re-analyse the last thing that was bought.
    private func collectFromInbox() {
        guard let item = StudioInbox.shared.take() else { return }
        // Picked from the file browser, so it is outside the sandbox until
        // asked for. Without this the read fails and the analysis reports an
        // empty file rather than a permissions problem.
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
        analyzer.start(url: item.url, title: item.title, context: modelContext)
    }
}
