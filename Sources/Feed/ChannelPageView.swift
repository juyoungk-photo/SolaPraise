//
//  ChannelPageView.swift
//  SolaPraise
//
//  Any YouTube channel's page — banner, avatar, size, and its uploads —
//  reachable by tapping a channel name while a song is playing.
//
//  WHY: hearing a version you like is how you find a worship team you did
//  not know. The natural next question is "what else have they done", and
//  until now answering it meant leaving for the YouTube app and leaving
//  the song behind.
//
//  It looks like YouTube's own channel page on purpose. The banner, the
//  round avatar and the subscriber count are how people recognise a
//  channel at a glance, and a page shaped differently would read as a
//  different place rather than as that channel.
//
//  Two reads, both one unit: channels.list for the header, the uploads
//  playlist for the videos. No search, so no 100-unit cost, which is why
//  this can open freely on a tap.
//

import SwiftUI
import SwiftData

struct ChannelPageView: View {
    let channelId: String
    /// Shown until the real title arrives, so the header is never blank.
    let fallbackTitle: String

    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.modelContext) private var modelContext

    @Query private var channels: [Channel]

    @State private var channel: YTChannel?
    @State private var uploads: [YTPlaylistItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var existing: Channel? {
        channels.first { $0.youtubeChannelId == channelId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 14)

                Divider()

                if isLoading && uploads.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let errorMessage, uploads.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(16)
                } else {
                    Text("최근 영상")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                    LazyVGrid(columns: FeedGrid.columns, spacing: 16) {
                        ForEach(uploads) { item in
                            if let id = item.videoId {
                                Button {
                                    host.play(queue: [PlayableVideo(
                                        id: id, title: item.title,
                                        channelTitle: channel?.title ?? fallbackTitle,
                                        channelId: channelId)], startIndex: 0)
                                } label: {
                                    VideoTile(title: item.title,
                                              thumbnailURL: item.thumbnailURL)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .bottomChrome()
        .navigationTitle(channel?.title ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The cropped strip YouTube itself shows on a phone, not the
            // 2560-wide master: a fifth of the bytes, and already framed.
            if let banner = channel?.bannerURL {
                // The shape owns the size; the image only fills it.
                //
                // An image with .fill inside a flexible frame reports its
                // NATURAL width to layout — a banner is several times wider
                // than a phone — and .clipped() hides the overflow from the
                // eye but not from layout. The whole page then widened to
                // the banner and slid left: the avatar cut off, the green
                // label reading 「…널에 있음」, the first column of videos
                // sliced through. In an overlay the image cannot affect the
                // size of anything.
                Color(.secondarySystemBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .overlay {
                        AsyncImage(url: banner) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            EmptyView()
                        }
                    }
                    .clipped()
            }

            HStack(alignment: .center, spacing: 14) {
                AsyncImage(url: channel?.thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(Color(.secondarySystemBackground))
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel?.title ?? fallbackTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    if let line = statsLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)

            followButton
                .padding(.horizontal, 16)
        }
    }

    /// "@markersworship · 구독자 50.1만명 · 동영상 1,203개" — the line under
    /// a channel's name on YouTube, in the order YouTube puts it.
    private var statsLine: String? {
        var parts: [String] = []
        if let handle = channel?.handle { parts.append(handle) }
        if let subs = channel?.subscribers { parts.append("구독자 \(Self.compact(subs))명") }
        if let videos = channel?.videoCount { parts.append("동영상 \(videos.formatted())개") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Following

    @ViewBuilder
    private var followButton: some View {
        if let existing {
            // Already in the app — say where, rather than offering to add
            // it twice or hiding that it is there.
            Label(existing.purposeRaw == Purpose.worship.rawValue
                  ? "찬양 채널에 있음" : "내 채널에 있음",
                  systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Button {
                follow()
            } label: {
                Label("찬양 채널로 추가", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    /// Adds the channel to the 찬양 feed.
    ///
    /// Into 찬양 specifically, because that is where this page is reached
    /// from — a song playing — and a worship team found by listening to
    /// their worship belongs with the worship. It can be moved in Settings.
    private func follow() {
        let order = (channels.map(\.sortOrder).max() ?? 0) + 1
        modelContext.insert(Channel(
            youtubeChannelId: channelId,
            title: channel?.title ?? fallbackTitle,
            handle: channel?.handle,
            thumbnailURLString: channel?.thumbnailURL?.absoluteString,
            purpose: .worship,
            sortOrder: order
        ))
        try? modelContext.save()
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let client = AppServices.client(auth: auth, quota: quota)
        async let header = client.channel(for: .channelId(channelId))
        async let videos = client.channelUploads(channelId: channelId, limit: 30)
        do {
            channel = try await header
            uploads = try await videos
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "채널을 불러오지 못했습니다."
        }
    }

    /// 501000 → "50.1만". Korean counts in 만, not in thousands.
    private static func compact(_ value: Int) -> String {
        if value >= 100_000_000 {
            return String(format: "%.1f억", Double(value) / 100_000_000)
                .replacingOccurrences(of: ".0", with: "")
        }
        if value >= 10_000 {
            return String(format: "%.1f만", Double(value) / 10_000)
                .replacingOccurrences(of: ".0", with: "")
        }
        return value.formatted()
    }
}

/// A plain thumbnail-and-title tile for a channel's uploads.
private struct VideoTile: View {
    let title: String
    let thumbnailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.footnote)
                .lineLimit(2)
                .foregroundStyle(Color.primary)
        }
    }
}
