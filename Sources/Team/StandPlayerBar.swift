//
//  StandPlayerBar.swift
//  SolaPraise
//
//  The chart's own song, under the chart: play it, see how far it has
//  got, drag to any minute and second, and jump to places marked.
//
//  WHY: the stand's player row worked whatever happened to be playing —
//  another song, a sermon — not the song on the stand. Practising a chart
//  means its recording: the bridge again, the key change again. A place
//  marked once (책갈피) is a tap away from then on, on this device.
//
//  Same on both devices: one thin line, no thumbnail.
//

import SwiftUI

struct StandPlayerBar: View {
    let item: ScoreStandItem
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var team: TeamStore

    /// The song's video: the one it was opened from, else the 순서's.
    @State private var videoId: String?
    /// Where the finger has the bar, while it drags.
    @State private var scrub: Double?
    @State private var marks: [SongBookmarks.Mark] = []

    var body: some View {
        Group {
            if let videoId {
                // The player says where it is without publishing it: looked
                // at twice a second while the bar is up.
                HStack(spacing: 10) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        row(videoId)
                    }
                    // Outside the half-second redraw: a menu redrawn under
                    // the finger closed before it opened.
                    bookmarkMenu(videoId, playing: isThis(videoId))
                }
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else {
                // Something for the lookup below to run on: an empty view
                // runs no tasks.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: item.id) {
            videoId = item.videoId ?? team.videoId(forSong: item.song, on: item.attachment.date)
            marks = videoId.map(SongBookmarks.load) ?? []
        }
    }

    private func row(_ videoId: String) -> some View {
        let player = host.coordinator
        let playing = isThis(videoId)
        let duration = playing ? player.duration : 0
        let now = scrub ?? (playing ? player.currentTime : 0)
        return HStack(spacing: 10) {
            Button { playPause(videoId) } label: {
                Image(systemName: playing && player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 30)
            }
            .accessibilityLabel(playing && player.state == .playing ? "일시정지" : "이 곡 재생")

            Text(Self.clock(now))
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)
            Slider(value: Binding(get: { min(now, max(duration, 1)) }, set: { scrub = $0 }),
                   in: 0...max(duration, 1)) { editing in
                guard !editing, let target = scrub else { return }
                player.seek(to: target)
                scrub = nil
            }
            .tint(.white.opacity(0.8))
            .overlay { markTicks(duration: duration) }
            .disabled(!playing || duration <= 0)
            .accessibilityLabel("재생 위치")
            Text(Self.clock(duration))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(minWidth: 36, alignment: .leading)
        }
    }

    /// The marked places along the bar, each in its colour. Only shown: a
    /// mark that took taps sat over the bar's thumb and stopped the drag.
    private func markTicks(duration: Double) -> some View {
        GeometryReader { geo in
            if duration > 0 {
                ForEach(marks) { mark in
                    Capsule()
                        .fill(mark.color)
                        .frame(width: 3, height: 14)
                        .position(x: 8 + (geo.size.width - 16) * min(1, mark.time / duration), y: geo.size.height / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func bookmarkMenu(_ videoId: String, playing: Bool) -> some View {
        Menu {
            Button {
                marks = SongBookmarks.add(host.coordinator.currentTime, to: videoId)
            } label: {
                Label("지금 위치에 책갈피", systemImage: "bookmark")
            }
            .disabled(!playing)
            if !marks.isEmpty {
                Section("가기") {
                    ForEach(marks) { mark in
                        Button("\(mark.dot)  \(Self.clock(mark.time))") { jump(to: mark.time, videoId: videoId) }
                    }
                }
                Menu("책갈피 지우기") {
                    ForEach(marks) { mark in
                        Button("\(mark.dot)  \(Self.clock(mark.time))", role: .destructive) {
                            marks = SongBookmarks.remove(mark, from: videoId)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: marks.isEmpty ? "bookmark" : "bookmark.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("책갈피")
    }

    private func isThis(_ videoId: String) -> Bool {
        host.mode != .closed && host.queue.indices.contains(host.index) && host.queue[host.index].id == videoId
    }

    /// This song: paused or played; another playing: this one instead.
    private func playPause(_ videoId: String) {
        if isThis(videoId) {
            host.coordinator.togglePlay()
        } else {
            host.play(queue: [PlayableVideo(id: videoId, title: item.song)], purpose: .worship)
        }
    }

    private func jump(to mark: Double, videoId: String) {
        if isThis(videoId) {
            host.coordinator.seek(to: mark)
        } else {
            host.play(queue: [PlayableVideo(id: videoId, title: item.song)], purpose: .worship)
            // Once the video has loaded enough to seek in.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                host.coordinator.seek(to: mark)
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Places marked in a song's recording, by video, on this device — each
/// in a colour of its own, so the bridge and the key change are told apart
/// on the bar at a glance.
enum SongBookmarks {
    struct Mark: Identifiable, Equatable {
        let time: Double
        let hue: Int
        var id: Double { time }
        var color: Color { SongBookmarks.palette[hue % SongBookmarks.palette.count] }
        /// The same colour where a menu draws its icons in one: a dot in the text.
        var dot: String { SongBookmarks.dots[hue % SongBookmarks.dots.count] }
    }

    static let palette: [Color] = [.orange, .blue, .green, .red, .yellow, .purple]
    static let dots = ["🟠", "🔵", "🟢", "🔴", "🟡", "🟣"]
    private static let key = "stand.bookmarks.v2"

    private static var all: [String: [[Double]]] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: [[Double]]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func load(_ videoId: String) -> [Mark] {
        (all[videoId] ?? []).compactMap { pair in
            pair.count == 2 ? Mark(time: pair[0], hue: Int(pair[1])) : nil
        }
    }

    private static func save(_ marks: [Mark], for videoId: String) {
        all[videoId] = marks.isEmpty ? nil : marks.map { [$0.time, Double($0.hue)] }
    }

    /// Kept in order of time; one within two seconds of another is the same
    /// place. A new mark takes the next colour not in use.
    static func add(_ seconds: Double, to videoId: String) -> [Mark] {
        var marks = load(videoId)
        guard !marks.contains(where: { abs($0.time - seconds) < 2 }) else { return marks }
        let used = Set(marks.map(\.hue))
        let hue = (0..<palette.count).first { !used.contains($0) } ?? marks.count
        marks.append(Mark(time: seconds.rounded(), hue: hue))
        marks.sort { $0.time < $1.time }
        save(marks, for: videoId)
        return marks
    }

    static func remove(_ mark: Mark, from videoId: String) -> [Mark] {
        let marks = load(videoId).filter { $0 != mark }
        save(marks, for: videoId)
        return marks
    }
}
