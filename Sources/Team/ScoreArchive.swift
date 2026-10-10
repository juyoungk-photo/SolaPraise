//
//  ScoreArchive.swift
//  SolaPraise
//
//  작업실's 팀 악보: every chart the team has attached to a song in 예배
//  준비, gathered by song.
//
//  WHY: a chart attached for one Sunday was reachable only from that
//  Sunday's 콘티. The next time the song came round, the chart was three
//  services back and nobody remembered where. 내 악보 holds only charts the
//  app made from audio; this is the other half — what people uploaded.
//
//  Pure, so the grouping is checked without the app
//  (Tools/check-score-archive.swift).
//

import Foundation

enum ScoreArchive {

    struct Entry<File>: Identifiable {
        /// The song as most recently written.
        let song: String
        /// Newest first.
        let files: [File]
        let latest: Date
        var id: String { ScoreArchive.songKey(song) }
    }

    /// Song attachments grouped by song, the most recently used song first.
    ///
    /// Service-wide files (the combined 콘티 PDF) are not a song's chart and
    /// are left out, as are audio and video, which are attachments but not
    /// 악보. 「주님 뜻대로」 and 「주님뜻대로 」 are one song.
    static func entries<File>(_ files: [File], date: (File) -> Date, song: (File) -> String,
                              name: (File) -> String) -> [Entry<File>] {
        var groups: [String: [File]] = [:]
        for file in files {
            let title = song(file).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, isScore(name(file)) else { continue }
            groups[songKey(title), default: []].append(file)
        }
        return groups.values.compactMap { group -> Entry<File>? in
            let sorted = group.sorted { date($0) > date($1) }
            guard let newest = sorted.first else { return nil }
            return Entry(song: song(newest).trimmingCharacters(in: .whitespacesAndNewlines),
                         files: sorted, latest: date(newest))
        }
        .sorted { $0.latest != $1.latest ? $0.latest > $1.latest
                                         : $0.song.localizedCompare($1.song) == .orderedAscending }
    }

    /// One key per song: case, spaces and punctuation do not make a new song.
    static func songKey(_ song: String) -> String {
        song.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// A chart, by its name: anything but sound and video. A photo of a
    /// chart is often named 「IMG_2041」 with no extension in Drive, so no
    /// extension counts as a chart too.
    static func isScore(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let media = ["mp3", "m4a", "wav", "aac", "aif", "aiff", "flac", "mp4", "mov", "m4v"]
        return !media.contains(ext)
    }
}
