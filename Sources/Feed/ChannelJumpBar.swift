//
//  ChannelJumpBar.swift
//  SolaPraise
//
//  Row of channel shortcuts pinned above a feed.
//
//  Styling is deliberately explicit rather than `.bar` + `.quaternary`: that
//  combination rendered as an empty black band on device while showing chips
//  correctly in the simulator.
//

import SwiftUI

struct ChannelJumpBar: View {
    let channels: [Channel]
    let onSelect: (Channel) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(channels) { channel in
                    chip(channel)
                        .onTapGesture { onSelect(channel) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    private func chip(_ channel: Channel) -> some View {
        HStack(spacing: 5) {
            if let url = channel.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(Color.secondary.opacity(0.3))
                }
                .frame(width: 18, height: 18)
                .clipShape(Circle())
            } else {
                Image(systemName: channel.isPinned ? "pin.fill" : "play.rectangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
            Text(channel.shortTitle)
                .lineLimit(1)
                .foregroundStyle(Color.primary)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Genre filters applied to what is already cached.
///
/// Deliberately NOT searches: a saved topic search costs 100 units per run,
/// so a row of genre chips that searched would drain the daily budget in a
/// few taps. These filter titles locally — free, instant, offline.
enum WorshipGenre: String, CaseIterable, Identifiable {
    case all, hymn, ccm, worship, piano, prayer, instrumental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:          return "전체"
        case .hymn:         return "찬송가"
        case .ccm:          return "CCM"
        case .worship:      return "경배와찬양"
        case .piano:        return "피아노"
        case .prayer:       return "기도"
        case .instrumental: return "연주"
        }
    }

    /// Title keywords. Matching is case-insensitive.
    var keywords: [String] {
        switch self {
        case .all:          return []
        case .hymn:         return ["찬송", "찬송가", "hymn"]
        case .ccm:          return ["CCM", "복음성가"]
        case .worship:      return ["경배", "워십", "worship", "예배"]
        case .piano:        return ["피아노", "piano", "건반"]
        case .prayer:       return ["기도", "묵상", "prayer"]
        case .instrumental: return ["연주", "instrumental", "MR", "반주"]
        }
    }

    func matches(_ title: String) -> Bool {
        guard self != .all else { return true }
        let lower = title.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }
}

// MARK: - Channel filter

/// The same row of channels, but selecting one narrows the feed instead of
/// scrolling to it.
///
/// Jumping only made sense while 찬양 was cut into per-channel sections. With
/// one feed there is nowhere to jump — but the channel is still worth having
/// when you want it, so it became a filter you opt into rather than a
/// structure imposed on every visit.
struct ChannelFilterBar: View {
    let channels: [Channel]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "전체", thumbnail: nil, isSelected: selected == nil) {
                    selected = nil
                }
                ForEach(channels) { channel in
                    chip(
                        title: channel.shortTitle,
                        thumbnail: channel.thumbnailURL,
                        isSelected: selected == channel.youtubeChannelId
                    ) {
                        selected = selected == channel.youtubeChannelId
                            ? nil
                            : channel.youtubeChannelId
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    private func chip(
        title: String,
        thumbnail: URL?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let thumbnail {
                    AsyncImage(url: thumbnail) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(Color.secondary.opacity(0.3))
                    }
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
                }
                Text(title).lineLimit(1)
            }
            .font(.caption2.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected
                               ? Color.accentColor
                               : Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Color.primary.opacity(0.12),
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pinning

/// Pin or unpin a playlist from wherever it is shown.
///
/// Pinning also files the playlist on a feed, because the two go together: you
/// pin something so it is waiting for you on the tab you open, and a playlist
/// with no purpose has no tab to wait on.
struct PlaylistPinButton: View {
    let playlist: CachedPlaylist
    let purpose: Purpose
    let save: () -> Void

    var body: some View {
        Button {
            playlist.isPinned.toggle()
            if playlist.isPinned {
                playlist.purposeRaw = purpose.rawValue
            }
            save()
        } label: {
            Label(
                playlist.isPinned ? "고정 해제" : "\(purpose.title)에 고정",
                systemImage: playlist.isPinned ? "pin.slash" : "pin"
            )
        }
    }
}
