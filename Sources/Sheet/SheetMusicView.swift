//
//  SheetMusicView.swift
//  SolaPraise
//
//  악보 — the chord and lead-sheet workspace.
//
//  Kept apart from the YouTube tabs on purpose: this is a working mode for a
//  musician, not a consumption surface. It gets its own tab on iPad, where
//  there is room to read a chart, and lives inside 보관함 on iPhone where the
//  tab bar is already full.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SheetMusicView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\SavedSong.createdAt, order: .reverse)])
    private var songs: [SavedSong]

    @StateObject private var analyzer = AudioFileAnalyzer()
    @State private var showImporter = false
    @State private var openedSong: SavedSong?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LiveDetectView()
                    } label: {
                        Label("실시간 코드 감지", systemImage: "waveform")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        HStack {
                            Label("오디오 파일에서 분석", systemImage: "waveform.badge.magnifyingglass")
                            Spacer()
                            if analyzer.isAnalyzing {
                                ProgressView(value: analyzer.progress).frame(width: 60)
                            }
                        }
                    }
                    .disabled(analyzer.isAnalyzing)

                    if let message = analyzer.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("새로 만들기")
                } footer: {
                    Text("라인 입력(오디오 인터페이스)이 가장 정확합니다. 유튜브 오디오는 분석할 수 없습니다.")
                }

                Section("내 악보") {
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
                                    if let key = song.detectedKey { Text(key) }
                                    Text("^[\(song.sections.count) section](inflect: true)")
                                    if song.hasLyrics { Text("· 가사") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(songs[index]) }
                        try? modelContext.save()
                    }
                }
            }
            .navigationTitle("악보")
            .navigationDestination(item: $openedSong) { song in
                LeadSheetView(song: song)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await analyze(url) }
            }
        }
    }

    private func analyze(_ url: URL) async {
        let title = url.deletingPathExtension().lastPathComponent
        guard let session = await analyzer.analyze(url: url, title: title) else { return }
        let song = SavedSong(
            session: session,
            sections: SongStructure.detect(chords: session.chords)
        )
        modelContext.insert(song)
        try? modelContext.save()
        openedSong = song
    }
}
