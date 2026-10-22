//
//  PlayHistoryView.swift
//  SolaPraise
//
//  재생 기록: everything played, newest first, as one list.
//
//  WHY: "what was that song on Tuesday" had no answer short of scrolling a
//  channel. The player already notes each video as it is left (how far it
//  got, whether it ran to the end — PlayerCoordinator.onLeave); this is
//  that note, read back. Filters for the questions actually asked: when,
//  찬양 or 말씀, and a word from the title or channel.
//
//  On this device only. Nothing here is sent anywhere.
//

import SwiftUI
import SwiftData

struct PlayHistoryView: View {
    @Environment(\.playerActions) private var host: PlayerHost!   // acted on, not drawn — see Unobserved
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\WatchEvent.startedAt, order: .reverse)])
    private var events: [WatchEvent]
    @Query private var channels: [Channel]

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "오늘"
            case .week:  return "7일"
            case .month: return "30일"
            case .all:   return "전체"
            }
        }
        var days: Int? {
            switch self {
            case .today: return 0
            case .week:  return 6
            case .month: return 29
            case .all:   return nil
            }
        }
    }

    @State private var period: Period = .week
    @State private var purpose: Purpose?
    @State private var searchText = ""

    /// What a play was played as — stamped when recorded, else what its
    /// channel is filed under. A play recorded before either was kept
    /// finds its channel through the video, if this device still has it.
    private func purpose(of event: WatchEvent) -> Purpose? {
        if let raw = event.purposeRaw, let known = Purpose(rawValue: raw) { return known }
        guard let id = event.channelId ?? olderChannels[event.videoId] else { return nil }
        return channels.first { $0.youtubeChannelId == id }?.purpose
    }

    /// Video → channel for plays recorded without one, looked up once.
    @State private var olderChannels: [String: String] = [:]

    private func lookUpOlderChannels() {
        let ids = Set(events.filter { $0.channelId == nil }.map(\.videoId))
        guard !ids.isEmpty else { return }
        let descriptor = FetchDescriptor<CachedVideo>(predicate: #Predicate { ids.contains($0.videoId) })
        for video in (try? modelContext.fetch(descriptor)) ?? [] {
            if let channel = video.channelId { olderChannels[video.videoId] = channel }
        }
    }

    private var shown: [WatchEvent] {
        let calendar = Calendar.current
        let since = period.days.flatMap {
            calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: Date()))
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { event in
            if let since, event.startedAt < since { return false }
            if let purpose, self.purpose(of: event) != purpose { return false }
            if !needle.isEmpty {
                let haystack = ((event.title ?? "") + " " + (event.channelTitle ?? "")).lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }

    /// By day, newest first.
    private var days: [(day: Date, events: [WatchEvent])] {
        let grouped = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Period.allCases) { option in
                            FilterChip(title: option.title, isSelected: period == option) { period = option }
                        }
                        Divider().frame(height: 18).padding(.horizontal, 2)
                        FilterChip(title: "찬양", isSelected: purpose == .worship) {
                            purpose = purpose == .worship ? nil : .worship
                        }
                        FilterChip(title: "말씀", isSelected: purpose == .word) {
                            purpose = purpose == .word ? nil : .word
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowSeparator(.hidden)
            }

            if shown.isEmpty {
                ContentUnavailableView(
                    events.isEmpty ? "아직 재생 기록이 없습니다" : "이 조건의 기록이 없습니다",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(events.isEmpty
                                      ? "영상을 보고 나면 여기에 차례로 남습니다. 이 기기에만 저장됩니다."
                                      : "기간이나 찬양·말씀 필터를 바꿔 보세요.")
                )
                .listRowSeparator(.hidden)
            }

            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.events) { event in
                        Button { play(event) } label: { row(event) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    modelContext.delete(event)
                                    try? modelContext.save()
                                } label: { Label("기록 삭제", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text(dayTitle(day.day))
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "제목·채널 검색")
        .task { lookUpOlderChannels() }
        .navigationTitle("재생 기록")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ event: WatchEvent) -> some View {
        HStack(spacing: 12) {
            Thumbnail(url: URL(string: "https://i.ytimg.com/vi/\(event.videoId)/mqdefault.jpg"), width: 96, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "제목 없음")
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let channel = event.channelTitle { Text(channel).lineLimit(1) }
                    Text(event.startedAt.formatted(date: .omitted, time: .shortened))
                    Text(event.completed ? "끝까지" : "\(duration(event.secondsWatched)) 들음")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func play(_ event: WatchEvent) {
        host.play(queue: [PlayableVideo(id: event.videoId, title: event.title ?? "",
                                        channelTitle: event.channelTitle, channelId: event.channelId)],
                  purpose: purpose(of: event))
    }

    private func duration(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "오늘" }
        if calendar.isDateInYesterday(day) { return "어제" }
        return day.formatted(.dateTime.month().day().weekday(.abbreviated))
    }
}
