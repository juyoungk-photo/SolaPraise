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

    @EnvironmentObject private var analyzer: AudioFileAnalyzer
    @State private var showImporter = false
    @State private var openedSong: SavedSong?

    private struct PerformanceSet: Identifiable {
        let id = UUID()
        let songs: [SavedSong]
    }
    @State private var performanceSet: PerformanceSet?

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
                    Text("새로 만들기")
                } footer: {
                    Text("라인 입력(오디오 인터페이스)이 가장 정확합니다. 유튜브 오디오는 분석할 수 없습니다.")
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
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button {
                                performanceSet = PerformanceSet(songs: [song])
                            } label: { Label("연주 모드", systemImage: "music.note.tv") }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(songs[index]) }
                        try? modelContext.save()
                    }
                } header: {
                    HStack {
                        Text("내 악보")
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
            .fullScreenCover(item: $performanceSet) { set in
                PerformanceModeView(songs: set.songs)
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
                analyze(url)
            }
        }
    }

    /// Hands the file to the app-level analyser and returns immediately, so
    /// the job survives leaving this screen — you can go and listen to
    /// something while a long recording is worked through.
    private func analyze(_ url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        analyzer.start(url: url, title: title, context: modelContext)
    }
}
