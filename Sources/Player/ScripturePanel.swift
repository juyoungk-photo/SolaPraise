//
//  ScripturePanel.swift
//  SolaPraise
//
//  The passage, under the video that is reading it.
//
//  A 시편 reading video gives you nothing to look at — the player shows a
//  static frame for twenty minutes while someone reads. Putting the text
//  below it means you can follow along, and it needs no player surgery: the
//  video stays exactly where it is and the page simply scrolls further.
//

import SwiftUI

struct ScripturePanel: View {
    let chapter: Int

    @EnvironmentObject private var daily: DailyReading
    @StateObject private var store = BibleStore()

    @State private var data: BibleChapter?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isExpanded = true
    @State private var translation: BibleTranslation?

    /// Its own translation, seeded from the app's. Reading along with a Korean
    /// video while the screen shows ESV is a real thing to want, and flipping
    /// it here should not change what the 시편 tab opens with tomorrow.
    private var shown: BibleTranslation { translation ?? daily.translation }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if isExpanded {
                if isLoading && data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if let message = errorMessage, data == nil {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let data {
                    verses(data)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: "\(chapter)-\(shown.rawValue)") { await load() }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.footnote)
                .foregroundStyle(.tint)

            Text("시편 \(chapter)편")
                .font(.subheadline.weight(.semibold))

            Spacer()

            Picker("", selection: Binding(
                get: { shown },
                set: { if $0.isAvailable { translation = $0 } }
            )) {
                ForEach(BibleTranslation.allCases) { option in
                    Text(option.displayName)
                        .foregroundStyle(option.isAvailable ? Color.primary : Color.secondary)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func verses(_ chapter: BibleChapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(chapter.verses) { verse in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(verse.number)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    Text(verse.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            data = try await store.chapter(chapter, in: shown)
        } catch {
            data = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Recognising a reading

enum ScriptureReference {
    /// The psalm a video is reading, from its title.
    ///
    /// Channels write it as "시편 72편 (개역개정)" or "시편 72장", so both
    /// counters are accepted. The digits are bounded on the right so 시편 7편
    /// cannot match inside 시편 72편, and the number is range-checked because
    /// a title mentioning 시편 200 is not a psalm reference.
    static func psalmChapter(in title: String) -> Int? {
        guard let range = title.range(
            of: "시편\\s*\\d{1,3}\\s*[편장]",
            options: .regularExpression
        ) else { return nil }

        guard let number = Int(title[range].filter(\.isNumber)),
              (1...Psalms.chapterCount).contains(number) else { return nil }
        return number
    }
}
