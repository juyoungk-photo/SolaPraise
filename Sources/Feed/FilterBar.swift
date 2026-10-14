//
//  FilterBar.swift
//  SolaPraise
//
//  찬양's filters, as one row of chips.
//
//  WHY ONE ROW: there were two. A pinned row of channels, and under it a
//  「전체」 menu (channel and length again) with the saved topics beside it —
//  topics that looked like chips and did nothing when tapped. Two rows that
//  narrow the same feed, one of them half dead, read as two features. Now
//  every way to narrow the feed is a chip on one pinned line: length,
//  전체, the saved topics, the channels. One topic or one channel at a
//  time — choosing either clears the other — so what is on is always the
//  one filled chip.
//
//  The genre filter stays gone. It matched keywords in titles — "피아노",
//  "찬송가" — which worship uploads do not reliably put there. A saved topic
//  is the user's own words, and its results were fetched for it.
//

import SwiftUI

struct WorshipFilterRow: View {
    let channels: [Channel]
    let topics: [TopicSearch]
    @Binding var channelFilter: String?
    /// A topic's query; nil for none.
    @Binding var topicFilter: String?
    @Binding var length: WorshipLength
    let addTopic: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                lengthMenu
                FilterChip(title: "전체", isSelected: channelFilter == nil && topicFilter == nil) {
                    channelFilter = nil
                    topicFilter = nil
                }
                ForEach(topics) { topic in
                    FilterChip(title: "# " + topic.label, isSelected: topicFilter == topic.query) {
                        topicFilter = topicFilter == topic.query ? nil : topic.query
                        channelFilter = nil
                    }
                }
                ForEach(channels) { channel in
                    FilterChip(title: channel.shortTitle, thumbnail: channel.thumbnailURL,
                               isSelected: channelFilter == channel.youtubeChannelId) {
                        channelFilter = channelFilter == channel.youtubeChannelId ? nil : channel.youtubeChannelId
                        topicFilter = nil
                    }
                }
                Button(action: addTopic) {
                    Label("주제", systemImage: "plus")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2),
                                                        style: StrokeStyle(lineWidth: 0.5, dash: [3])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    /// Length is not one of a kind with the others — it narrows whatever
    /// is chosen — so it is a menu at the front, filled when it is on.
    private var lengthMenu: some View {
        Menu {
            ForEach(WorshipLength.allCases) { option in
                Button {
                    length = option
                } label: {
                    if length == option { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(length == .all ? "길이" : length.title)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(length == .all ? Color.primary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(length == .all ? Color(.secondarySystemBackground) : Color.accentColor))
            .overlay(Capsule().strokeBorder(length == .all ? Color.primary.opacity(0.12) : .clear, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// How long a video runs, as a thing you can ask for.
///
/// The 찬양 feed carries both four-minute songs and three-hour continuous
/// sets, and they are wanted at different moments: one to learn or rehearse,
/// the other to leave playing. Read from the video's own duration, so unlike
/// the genre filter it does not depend on an uploader having written the
/// right word in the title.
enum WorshipLength: String, CaseIterable, Identifiable {
    case all, song, set

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:  return "전체"
        case .song: return "한 곡"
        case .set:  return "긴 묶음"
        }
    }

    /// 20 minutes: longer than any single worship song, shorter than any
    /// compilation worth calling one.
    func matches(seconds: Int?) -> Bool {
        switch self {
        case .all:  return true
        // Unknown length counts as a song: a missing duration usually means
        // the metadata fetch has not caught up, and hiding it would make the
        // feed look emptier than it is.
        case .song: return (seconds ?? 0) <= 20 * 60
        case .set:  return (seconds ?? 0) > 20 * 60
        }
    }
}
