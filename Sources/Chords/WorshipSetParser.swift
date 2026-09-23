//
//  WorshipSetParser.swift
//  SolaPraise
//
//  Reads a worship set list out of a video description.
//
//  Worship channels publish exactly what a musician needs, in plain text:
//
//      MARKERS WORSHIP
//      04:45 - 1. 나는 예배자입니다 I'm a Worshipper | E
//      10:15 - 2. 신령과 진정으로 In Spirit, in Truth | E
//
//      어노인팅
//      03:15 나의 예배를 받으소서
//      14:59 호흡 있는 모든 만물
//
//  This is the key the team actually played in, published by them — not a
//  guess from a degraded microphone signal. It is public metadata that
//  arrives free with the snippet we already request, and needs no audio,
//  which is why it exists instead of stream analysis.
//

import Foundation

struct WorshipSetItem: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    let title: String
    /// Musical key as published, e.g. "E", "Bb", "F#m". Nil when the channel
    /// lists songs without keys.
    let key: String?

    var timeLabel: String {
        let total = Int(start)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// A link to official sheet music, pulled from a channel's own description.
struct SheetMusicLink: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let url: URL
}

enum WorshipSetParser {

    /// Finds where a worship team publishes or sells its official 악보.
    ///
    /// Worship teams sell chord charts as ministry income — 어노인팅 links
    /// "온라인샵 (음반 악보 MR 판매) ㅣ anointingmusic.com", MARKERS has
    /// markersworship.com. That chart is authoritative; a chord estimate is a
    /// guess at something that already exists definitively, so the app points
    /// at the source rather than competing with it.
    static func sheetMusicLinks(_ description: String) -> [SheetMusicLink] {
        guard !description.isEmpty else { return [] }

        // Domains known to publish worship sheet music.
        let knownHosts = ["anointingmusic.com", "markersworship.com",
                          "wecca.co.kr", "onward.co.kr", "praise.co.kr"]
        let keywords = ["악보", "코드", "chord", "Chord", "sheet", "Sheet", "MR"]

        var found: [SheetMusicLink] = []
        var seen = Set<String>()

        for rawLine in description.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let urlRange = line.range(of: #"https?://[^\s]+"#, options: .regularExpression)
                    ?? line.range(of: #"[a-z0-9.-]+\.(com|kr|net|org)(/[^\s]*)?"#, options: .regularExpression)
            else { continue }

            var raw = String(line[urlRange])
            if !raw.hasPrefix("http") { raw = "https://" + raw }
            guard let url = URL(string: raw), let host = url.host else { continue }
            guard !seen.contains(host) else { continue }

            let mentionsSheet = keywords.contains { line.contains($0) }
            let isKnown = knownHosts.contains { host.contains($0) }
            guard mentionsSheet || isKnown else { continue }

            // Label from the surrounding text, falling back to the host.
            var label = line.replacingOccurrences(of: raw, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " 👉ㅣ|•·-–—\t"))
            if label.isEmpty || label.count > 40 { label = host }

            seen.insert(host)
            found.append(SheetMusicLink(label: label, url: url))
        }
        return found
    }

    /// A timestamp at the start of a line, then the song title.
    private static let linePattern = #"^\s*(\d{1,2}:\d{2}(?::\d{2})?)\s*[-–—.)]?\s*(.+?)\s*$"#

    /// A bare musical key: A–G, optional accidental, optional minor/major/7.
    private static let keyPattern = #"^[A-G][b♭#♯]?(m|min|maj|M)?7?$"#

    /// Parses a description into a set list. Returns an empty array when the
    /// description has no timestamped lines, which is the common case.
    static func parse(_ description: String) -> [WorshipSetItem] {
        guard !description.isEmpty else { return [] }

        var items: [WorshipSetItem] = []
        for rawLine in description.components(separatedBy: .newlines) {
            guard let match = rawLine.range(of: linePattern, options: .regularExpression) else { continue }
            let line = String(rawLine[match])

            guard let stampRange = line.range(of: #"\d{1,2}:\d{2}(?::\d{2})?"#, options: .regularExpression) else { continue }
            let stamp = String(line[stampRange])
            guard let seconds = seconds(from: stamp) else { continue }

            var rest = String(line[stampRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—.)\t"))
            guard !rest.isEmpty else { continue }

            // Pull a trailing "| E" style key off the end.
            var key: String?
            if let bar = rest.lastIndex(of: "|") {
                let tail = rest[rest.index(after: bar)...].trimmingCharacters(in: .whitespaces)
                if tail.range(of: keyPattern, options: .regularExpression) != nil {
                    key = tail
                    rest = String(rest[..<bar]).trimmingCharacters(in: .whitespaces)
                }
            }

            // Drop list numbering: "1. 나는 예배자입니다" → "나는 예배자입니다".
            rest = rest.replacingOccurrences(
                of: #"^\d{1,2}[.)]\s*"#, with: "", options: .regularExpression
            )
            guard !rest.isEmpty else { continue }

            items.append(WorshipSetItem(start: seconds, title: rest, key: key))
        }

        // A single 00:00 line is a chapter marker, not a set list.
        return items.count >= 2 ? items : []
    }

    private static func seconds(from stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }
}
