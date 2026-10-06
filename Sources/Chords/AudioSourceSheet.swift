//
//  AudioSourceSheet.swift
//  SolaPraise
//
//  음원 찾기: the recording itself, and the way it reaches 작업실.
//
//  The old version was a menu of search-engine links. This one names the
//  track — artist, album, year, length, price — plays Apple's 30-second clip
//  so you can tell two recordings of the same hymn apart before paying, and
//  opens the page where the file is bought. The teams' own shops stay,
//  below, because 어노인팅 and 마커스 sell MR and stems that no store carries.
//
//  WHY IT STOPS AT THE PURCHASE: the analyser needs a file, and the only
//  files the app may use are the ones you own. The preview is Apple's, served
//  for recognising a recording, and 30 seconds would not carry a chart
//  anyway. So the last row here is the one that matters — it opens 작업실's
//  importer, which is where the file you just bought becomes a 악보.
//

import SwiftUI
import AVFoundation

struct AudioSourceSheet: View {
    let title: String
    /// What we already know about the recording being listened to, used to
    /// sort the store's answers — see AudioSourceSearch.ranked.
    var seconds: Int?
    var artist: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var term: String = ""
    @State private var tracks: [AudioSourceSearch.Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searched = false

    @State private var preview = PreviewPlayer()
    @State private var showImporter = false
    @State private var importedFile: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("곡 제목", text: $term)
                            .submitLabel(.search)
                            .onSubmit { Task { await run() } }
                        if !term.isEmpty {
                            Button {
                                term = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("영상 제목에서 대괄호·날짜·채널명을 걷어낸 말로 찾습니다. 결과가 없으면 곡 이름만 남겨 보세요.")
                }

                if isSearching {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("찾는 중…").foregroundStyle(.secondary)
                        }
                    }
                } else if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if !tracks.isEmpty {
                    Section {
                        ForEach(tracks) { track in
                            row(track)
                        }
                    } header: {
                        Text("구매할 수 있는 음원")
                    } footer: {
                        Text("미리듣기는 30초짜리 확인용입니다. 분석에는 구매한 파일이 필요합니다.")
                    }
                } else if searched {
                    Section {
                        Text("이 제목으로는 찾지 못했습니다. 아래 판매처에서 직접 찾아보세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(AudioSources.all) { source in
                        Button {
                            if let url = source.url(for: term.isEmpty ? title : term) {
                                openURL(url)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name).foregroundStyle(Color.primary)
                                    Text(source.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("직접 판매하는 곳")
                } footer: {
                    Text("찬양팀이 직접 파는 MR과 스템은 스토어에 없는 경우가 많습니다.")
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("받은 파일 작업실에서 분석", systemImage: "waveform.badge.magnifyingglass")
                    }
                    if let importedFile {
                        Text(importedFile.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("파일을 고르면 작업실의 분석이 시작됩니다.")
                }
            }
            .navigationTitle("음원 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task {
                guard !searched else { return }
                term = AudioSourceSearch.query(from: title)
                await run()
            }
            .onDisappear { preview.stop() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                importedFile = url
                preview.stop()
                StudioInbox.shared.submit(url: url, title: term.isEmpty ? title : term)
                dismiss()
            }
        }
    }

    private func row(_ track: AudioSourceSearch.Track) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: track.artwork) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let album = track.album {
                        Text(album).lineLimit(1)
                    }
                    if let released = track.releasedAt {
                        Text(released, format: .dateTime.year())
                    }
                    if let duration = track.durationText {
                        Text(duration).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            VStack(spacing: 6) {
                if let previewURL = track.previewURL {
                    Button {
                        preview.toggle(previewURL, id: track.id)
                    } label: {
                        Image(systemName: preview.playingId == track.id
                              ? "stop.circle.fill" : "play.circle")
                            .font(.title3)
                            .frame(width: 36, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("미리듣기")
                }
                if let storeURL = track.storeURL {
                    Button {
                        openURL(storeURL)
                    } label: {
                        Text(track.priceText ?? "구매")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func run() async {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false; searched = true }
        do {
            tracks = AudioSourceSearch.ranked(
                try await AudioSourceSearch.search(query),
                seconds: seconds, artist: artist
            )
        } catch {
            tracks = []
            errorMessage = "음원을 찾지 못했습니다: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview playback

/// Plays Apple's 30-second clip, one at a time.
///
/// Its own player rather than the app's: this is a few seconds of listening
/// to check a recording, and routing it through the video player would stop
/// whatever is already playing and put the wrong thing in the mini bar.
@MainActor
@Observable
final class PreviewPlayer {
    private(set) var playingId: Int?
    private var player: AVPlayer?

    func toggle(_ url: URL, id: Int) {
        if playingId == id { stop(); return }
        stop()
        // .ambient: a preview must never interrupt a service running in the
        // other half of the app, and it must obey the ring switch.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        playingId = id
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playingId = nil
    }
}
