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
    @State private var isSigningIn = false

    var body: some View {
        NavigationStack {
            // One list, always. Only 재생목록 needs the account, so only
            // that section carries the sign-in offer — 작업실 analyses files
            // on this device and must not disappear with the login state.
            list
            .bottomChrome()
            .navigationTitle("보관함")
            // Inline on both. On iPadOS 26 a LARGE title splits the
            // navigation bar into two rows and the system puts the tab bar
            // back in the upper one — visible despite .toolbar(.hidden,
            // for: .tabBar) — so the iPad showed the system bar at the top
            // and ours at the bottom at the same time. Every other tab was
            // already inline, which is why only these two did it.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("설정")
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
            .task { if auth.isSignedIn, state.value == nil { await load() } }
            // Signing in from the row above has to fill the section it was
            // standing in; nothing else here re-triggers the load.
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn { Task { await load() } }
            }
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

            if TeamSheetSource.current == nil {
                Section {
                    Button { showSettings = true } label: {
                        Label("팀 시트 연결하기", systemImage: "calendar.badge.plus")
                    }
                } footer: {
                    // The 예배 준비 tab appears only once a sheet is
                    // connected, and a tab that is simply absent explains
                    // nothing about why.
                    Text("팀 시트를 연결하면 「예배 준비」 탭이 생깁니다. 주일 콘티, 파트, 사인업을 팀과 함께 봅니다.")
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
                if !auth.isSignedIn {
                    signInRow
                } else if state.isLoading && state.value == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("불러오는 중…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if let message = state.errorMessage, state.value == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("다시 시도") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                } else if state.value?.isEmpty ?? false {
                    Text("YouTube에서 만든 재생목록이 여기에 보입니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.value ?? []) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                }
            } header: {
                Text("재생목록")
            }
        }
        .listStyle(.plain)
    }

    /// 보관함's playlists are the one thing in the app that genuinely needs
    /// the account: the app's key can read all of YouTube, but it cannot be
    /// asked whose playlists these are. So the offer lives in that section
    /// alone, as a row, instead of standing in for the whole tab.
    private var signInRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("내 YouTube 재생목록을 보고 편집하려면 Google 계정이 필요합니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isSigningIn = true
                Task { await auth.signIn(); isSigningIn = false }
            } label: {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Google 로그인", systemImage: "person.crop.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isSigningIn)
        }
        .padding(.vertical, 4)
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
        guard auth.isSignedIn else { return }
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

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("불러오지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("다시 시도", action: retry)
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
