//
//  LyricCheckSheet.swift
//  SolaPraise
//
//  「가사 확인」 on the 코드표: is what was read off the page what is sung?
//
//  Two ways, side by side:
//  - the first line, searched on Google, to read against by eye;
//  - the lyrics a YouTube upload of the song prints in its description,
//    compared line by line (LyricCheck): every syllable that differs is
//    marked, with the description's text under it. The uploads are the
//    ones this device has already seen for the song, or one whose link is
//    pasted here. Nothing is fetched from a lyrics site, and nothing kept.
//

import SwiftUI
import SwiftData

struct LyricCheckSheet: View {
    let systems: [ScoreChart.System]
    let song: String

    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    struct Source: Identifiable, Hashable {
        let id: String
        let label: String
        let lyrics: [String]
    }

    @State private var sources: [Source] = []
    @State private var chosen: String?
    @State private var link = ""
    @State private var note: String?
    @State private var loading = false

    /// The 코드표's lines as shown — spaced and corrected — verse by verse.
    private var lines: [(label: String, syllables: [String], shown: [String], text: String)] {
        var out: [(String, [String], [String], String)] = []
        for (s, system) in systems.enumerated() {
            let verses = max(system.verses, 1)
            for verse in 0..<verses {
                let raw = system.bars.flatMap(\.cells).compactMap { cell -> String? in
                    verse < cell.syllables.count && !cell.syllables[verse].isEmpty ? cell.syllables[verse] : nil
                }
                guard !raw.isEmpty else { continue }
                let spaced = LyricSpacing.space(raw)
                let label = verses > 1 ? "\(s + 1)줄 \(verse + 1)절" : "\(s + 1)줄"
                var syllables: [String] = [], shown: [String] = []
                for (k, syllable) in spaced.syllables.enumerated() where !syllable.isEmpty {
                    syllables.append(syllable)
                    // A space before each word, as it reads on the 코드표.
                    shown.append((spaced.startsWord[k] && !shown.isEmpty ? " " : "") + syllable)
                }
                out.append((label, syllables, shown, spaced.text))
            }
        }
        return out
    }

    private var source: Source? { sources.first { $0.id == chosen } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let first = lines.first {
                        Button {
                            if let url = WatchScreen.googleURL("\(first.text) 가사") { openURL(url) }
                        } label: {
                            Label("「\(first.text)」 Google에서 찾기", systemImage: "globe")
                        }
                    }
                } footer: {
                    Text("첫 줄로 찾아서, 나오는 가사와 아래 코드표를 눈으로 맞춰 보세요.")
                }

                Section {
                    if sources.isEmpty {
                        Text(loading ? "영상을 찾는 중…" : "이 기기에 가사가 적힌 이 곡의 영상이 없습니다. 가사가 설명에 있는 영상의 링크를 붙여 넣으세요.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("영상", selection: $chosen) {
                            ForEach(sources) { Text($0.label).tag(Optional($0.id)) }
                        }
                    }
                    HStack {
                        TextField("youtube.com/watch?v=… 또는 youtu.be/…", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await addLink() } }
                        Button("추가") { Task { await addLink() } }
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                    }
                    if let note { Text(note).font(.caption).foregroundStyle(.orange) }
                } header: {
                    Text("영상 설명의 가사와 비교")
                } footer: {
                    Text("팀이 영상 설명에 적어 둔 가사와 한 줄씩 맞춥니다. 다른 글자는 주황색, 그 아래가 설명의 가사입니다. 가사 사이트에서는 가져오지 않습니다.")
                }

                if let source {
                    let checked = LyricCheck.compare(lines: lines.map(\.syllables), referenceLines: source.lyrics)
                    let agree = checked.filter(\.agrees).count
                    Section {
                        ForEach(Array(zip(lines, checked).enumerated()), id: \.offset) { _, pair in
                            row(pair.0.label, pair.0.shown, pair.1)
                        }
                    } header: {
                        Text("\(checked.count)줄 중 \(agree)줄 같음")
                    }
                }
            }
            .navigationTitle("가사 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        .task {
            findCached()
            #if DEBUG
            if let id = DebugHarness.lyricCheckVideo { link = "https://youtu.be/\(id)"; await addLink() }
            #endif
        }
    }

    private func row(_ label: String, _ shown: [String], _ line: LyricCheck.Line) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                shown.enumerated().reduce(Text("")) { text, item in
                    text + Text(item.element)
                        .foregroundStyle(line.differs.contains(item.offset) ? Color.orange : Color.primary)
                        .underline(line.differs.contains(item.offset))
                }
                .font(.body)
                Spacer(minLength: 0)
                Image(systemName: line.agrees ? "checkmark.circle.fill" : line.found ? "exclamationmark.circle" : "questionmark.circle")
                    .foregroundStyle(line.agrees ? Color.green : line.found ? Color.orange : Color.secondary)
            }
            if let reference = line.reference, !line.agrees {
                Text(reference).font(.callout).foregroundStyle(.secondary).padding(.leading, 64)
            } else if !line.found {
                Text("설명에서 찾지 못함").font(.caption).foregroundStyle(.secondary).padding(.leading, 64)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Sources

    /// Uploads of this song the device already has, with lyrics in their
    /// descriptions.
    private func findCached() {
        let all = (try? modelContext.fetch(FetchDescriptor<CachedVideo>())) ?? []
        for video in all where PlanSongTitle.sameSong(video.title, song) {
            add(id: video.videoId, title: video.title, channel: video.channelTitle, description: video.descriptionText)
        }
        if chosen == nil { chosen = sources.first?.id }
    }

    private func add(id: String, title: String, channel: String?, description: String?) {
        guard let description, !sources.contains(where: { $0.id == id }) else { return }
        // Credit lines written 「보컬 | 이름」 pass for lyrics elsewhere; here
        // they would only add noise.
        let lyrics = SongSearchSuggestions.lyricLines(in: description)
            .filter { !$0.contains("|") && !$0.contains("[") }
        // A description is this song's lyrics only if a line of the 코드표
        // is found in it — a channel's blurb is not.
        guard lyrics.count >= 3,
              LyricCheck.compare(lines: lines.map(\.syllables), referenceLines: lyrics).contains(where: \.found)
        else { return }
        let name = PlanSongTitle.split(title).title
        sources.append(Source(id: id, label: [name, channel].compactMap { $0 }.joined(separator: " · "), lyrics: lyrics))
    }

    /// One upload by its link — one unit of quota.
    private func addLink() async {
        guard let id = YouTubeID.parse(link.trimmingCharacters(in: .whitespaces)) else {
            note = "YouTube 영상 링크가 아닙니다."
            return
        }
        loading = true
        defer { loading = false }
        guard let video = try? await AppServices.client(auth: auth, quota: quota).videos(ids: [id]).first else {
            note = "영상을 찾지 못했습니다."
            return
        }
        let before = sources.count
        add(id: id, title: video.snippet?.title ?? "영상", channel: video.snippet?.channelTitle,
            description: video.snippet?.description)
        if sources.count > before {
            chosen = id
            note = nil
            link = ""
        } else {
            note = "이 영상의 설명에는 이 곡의 가사가 없습니다."
        }
    }
}
