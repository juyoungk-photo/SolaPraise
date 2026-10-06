//
//  FilterBar.swift
//  SolaPraise
//
//  One line of filters instead of three rows of chips.
//
//  찬양 spent the top of the screen on a channel row, a genre row and a topic
//  row, stacked — roughly the first 40% of a phone before a single video,
//  every time, whether or not anything was being filtered. Filters are
//  occasional and videos are the point.
//
//  Now: one line that says what is on, and opens the choices when tapped.
//  Nothing selected reads "전체" and takes a single row; something selected
//  says so, and can be cleared from the same place.
//
//  The genre filter is gone. It matched keywords in titles — "피아노",
//  "찬송가" — which worship uploads do not reliably put there, so most of its
//  settings returned almost nothing and it was never worth the row. Length
//  replaces it, which is read from the video rather than guessed from its
//  name: this feed mixes four-minute songs with three-hour compilations, and
//  which of the two you are after is the question actually worth asking.
//

import SwiftUI

struct FilterBar<Trailing: View>: View {
    let channels: [Channel]
    @Binding var channelFilter: String?
    @Binding var length: WorshipLength
    /// Topics and anything else the tab wants beside the filters.
    @ViewBuilder var trailing: Trailing

    private var channelName: String? {
        channels.first { $0.youtubeChannelId == channelFilter }?.shortTitle
    }

    private var isFiltered: Bool { channelFilter != nil || length != .all }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("채널") {
                    Button {
                        channelFilter = nil
                    } label: {
                        if channelFilter == nil { Label("전체", systemImage: "checkmark") }
                        else { Text("전체") }
                    }
                    ForEach(channels) { channel in
                        Button {
                            channelFilter = channel.youtubeChannelId
                        } label: {
                            if channelFilter == channel.youtubeChannelId {
                                Label(channel.shortTitle, systemImage: "checkmark")
                            } else {
                                Text(channel.shortTitle)
                            }
                        }
                    }
                }
                Section("길이") {
                    ForEach(WorshipLength.allCases) { option in
                        Button {
                            length = option
                        } label: {
                            if length == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
                if isFiltered {
                    Section {
                        Button(role: .destructive) {
                            channelFilter = nil
                            length = .all
                        } label: { Label("필터 해제", systemImage: "xmark.circle") }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                    // What is on, in the order it was chosen in.
                    Text(label)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isFiltered
                                   ? Color.accentColor.opacity(0.18)
                                   : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isFiltered ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)

            trailing
        }
        .padding(.horizontal, 16)
    }

    private var label: String {
        switch (channelName, length) {
        case (nil, .all):        return "전체"
        case (let name?, .all):  return name
        case (nil, let l):       return l.title
        case (let name?, let l): return "\(name) · \(l.title)"
        }
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
