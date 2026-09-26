//
//  PlaylistLibraryView.swift
//  SolaPraise
//
//  Your real YouTube playlists, read live from the API. Never a local copy —
//  what you see here is what the YouTube app shows.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PlaylistLibraryView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @Environment(\.modelContext) private var modelContext
    @StateObject private var state = LoadState<[YTPlaylist]>()
    @State private var showSettings = false
    @State private var showAddChannel = false

    /// Channels kept here rather than in a purpose feed — 교제 content like
    /// 코너스톤TV or 아현이네TV that is worth having but shouldn't dilute
    /// 말씀 or 찬양.
    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var allChannels: [Channel]

    private var shelfChannels: [Channel] {
        allChannels.filter { $0.purposeRaw == Purpose.fellowship.rawValue }
    }

    @Query(sort: [SortDescriptor(\SavedSong.createdAt, order: .reverse)])
    private var savedSongs: [SavedSong]

    @EnvironmentObject private var analyzer: AudioFileAnalyzer
    @State private var showImporter = false
    @State private var analyzedSong: SavedSong?

    var body: some View {
        NavigationStack {
            Group {
                if state.isLoading && state.value == nil {
                    ProgressView("Loading your playlists…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = state.errorMessage, state.value == nil {
                    ErrorState(message: message) { Task { await load() } }
                } else if let playlists = state.value, playlists.isEmpty, shelfChannels.isEmpty {
                    EmptyState()
                } else {
                    list
                }
            }
            .navigationTitle("보관함")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAddChannel) {
                AddChannelView(defaultPurpose: .fellowship)
            }
            .navigationDestination(item: $analyzedSong) { song in
                LeadSheetView(song: song)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                runAnalysis(on: url)
            }
            .refreshable { await load() }
            .task { if state.value == nil { await load() } }
        }
    }

    private var list: some View {
        List {
            if !shelfChannels.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelfChannels) { channel in
                                NavigationLink {
                                    ChannelDetailView(channel: channel)
                                } label: {
                                    channelChip(channel)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                } header: {
                    HStack {
                        Text("채널")
                        Spacer()
                        Button { showAddChannel = true } label: {
                            Label("추가", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } footer: {
                    Text("교회 교제 채널이나 내 채널을 보관함에 둘 수 있습니다. 말씀·찬양 피드는 건드리지 않습니다.")
                }
            }

            if shelfChannels.isEmpty {
                Section {
                    Button { showAddChannel = true } label: {
                        Label("채널 추가", systemImage: "person.2.badge.plus")
                    }
                } footer: {
                    Text("교회 교제 채널이나 내 채널을 보관함에 둘 수 있습니다.")
                }
            }

            Section {
                NavigationLink {
                    StudioView()
                } label: {
                    Label("작업실 · 녹음과 악보", systemImage: "recordingtape")
                }

                ForEach(savedSongs.prefix(5)) { song in
                    NavigationLink {
                        LeadSheetView(song: song)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).lineLimit(1)
                            HStack(spacing: 6) {
                                if let key = song.detectedKey { Text(key) }
                                if song.hasLyrics { Text("· 가사") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    // Purely local, so no undo bar: a detection run is cheap
                    // to repeat and nothing leaves the device.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            delete(song)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            delete(song)
                        } label: { Label("악보 삭제", systemImage: "trash") }
                    }
                }
            } header: {
                Text("작업실")
            } footer: {
                Text("내가 가진 오디오 파일(예배 실황 녹음 등)에서 코드를 분석합니다. 유튜브 오디오는 분석할 수 없습니다.")
            }

            Section {
                ForEach(state.value ?? []) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        PlaylistRow(playlist: playlist)
                    }
                }
            } header: {
                if !shelfChannels.isEmpty { Text("재생목록") }
            }
        }
        .listStyle(.plain)
    }

    private func channelChip(_ channel: Channel) -> some View {
        HStack(spacing: 7) {
            if let url = channel.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(Color.secondary.opacity(0.3))
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            Text(channel.shortTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func delete(_ song: SavedSong) {
        modelContext.delete(song)
        try? modelContext.save()
    }

    /// Analyses a user-owned audio file and stores the result as a lead sheet.
    /// Hands the file to the app-level analyser and returns immediately. The
    /// job outlives this screen, so switching tabs no longer cancels it.
    private func runAnalysis(on url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        analyzer.start(url: url, title: title, context: modelContext)
    }

    private func load() async {
        let client = AppServices.client(auth: auth, quota: quota)
        await state.run { try await client.myPlaylists() }
    }
}

// MARK: - Row

private struct PlaylistRow: View {
    let playlist: YTPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: playlist.thumbnailURL, width: 88, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.body)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text("^[\(playlist.itemCount) video](inflect: true)")
                    Text("·")
                    Label(playlist.privacy.label, systemImage: playlist.privacy.symbolName)
                        .labelStyle(.titleAndIcon)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - States

private struct EmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No playlists yet",
            systemImage: "list.bullet.rectangle",
            description: Text("Playlists you create on YouTube — or here — will appear in this list.")
        )
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Thumbnail

struct Thumbnail: View {
    let url: URL?
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
