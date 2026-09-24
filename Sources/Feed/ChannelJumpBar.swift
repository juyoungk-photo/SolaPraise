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
