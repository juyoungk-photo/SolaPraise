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
    /// Whole-chapter Psalms come from the bundle; anything else is a passage
    /// fetched from ESV, because 개역한글 is bundled for the Psalms only.
    let passage: ScriptureReference.Passage

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
                    // Required wherever the text appears, not only on the
                    // reading screen.
                    ScriptureAttribution(translation: data.translation)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: "\(passage.esvQuery)-\(shown.rawValue)") { await load() }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.footnote)
                .foregroundStyle(.tint)

            Text(passage.display)
                .font(.subheadline.weight(.semibold))

            Spacer()

            if passage.isPsalms || ReadingSettings.extraVersion != nil {
            Picker("", selection: Binding(
                get: { shown },
                set: { if $0.isAvailable { translation = $0 } }
            )) {
                ForEach(BibleTranslation.offered) { option in
                    Text(option.displayName)
                        .foregroundStyle(option.isAvailable ? Color.primary : Color.secondary)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            }

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
            if passage.isPsalms, passage.verses == nil {
                data = try await store.chapter(passage.chapter, in: shown)
            } else if shown == .extra, let version = ReadingSettings.extraVersion {
                data = BibleChapter(
                    chapter: passage.chapter,
                    verses: try await store.extraPassage(passage.esvQuery,
                                                         versionId: version.id),
                    translation: .extra
                )
            } else {
                // Everything outside the Psalms comes from a licensed source,
                // because 개역한글 is bundled for the Psalms alone.
                data = BibleChapter(chapter: passage.chapter,
                                    verses: try await store.esvPassage(passage.esvQuery),
                                    translation: .esv)
            }
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

// MARK: - Any passage

extension ScriptureReference {

    /// A reference found in a video title.
    struct Passage: Equatable, Identifiable {
        /// So a passage can be presented as a sheet directly.
        var id: String { esvQuery }

        let koreanBook: String
        let englishBook: String
        let chapter: Int
        /// "46-57" when the title gives verses, nil for a whole chapter.
        let verses: String?

        var display: String {
            let base = "\(koreanBook) \(chapter)"
            guard let verses else { return base + "장" }
            return base + ":" + verses
        }

        /// ESV's own reference syntax.
        var esvQuery: String {
            let base = "\(englishBook) \(chapter)"
            guard let verses else { return base }
            return base + ":" + verses
        }

        var isPsalms: Bool { englishBook == "Psalm" }
    }

    /// Korean book names as the church actually writes them, mapped to what
    /// Crossway's API expects.
    ///
    /// Longest-first matching matters: 사사기 must be tried before 사기 would
    /// ever be, and 요한일서 before 요한.
    private static let books: [(korean: String, english: String)] = [
        ("창세기","Genesis"),("출애굽기","Exodus"),("레위기","Leviticus"),("민수기","Numbers"),
        ("신명기","Deuteronomy"),("여호수아","Joshua"),("사사기","Judges"),("룻기","Ruth"),
        ("사무엘상","1 Samuel"),("사무엘하","2 Samuel"),("열왕기상","1 Kings"),("열왕기하","2 Kings"),
        ("역대상","1 Chronicles"),("역대하","2 Chronicles"),("에스라","Ezra"),("느헤미야","Nehemiah"),
        ("에스더","Esther"),("욥기","Job"),("시편","Psalm"),("잠언","Proverbs"),
        ("전도서","Ecclesiastes"),("아가","Song of Solomon"),("이사야","Isaiah"),("예레미야애가","Lamentations"),
        ("예레미야","Jeremiah"),("에스겔","Ezekiel"),("다니엘","Daniel"),("호세아","Hosea"),
        ("요엘","Joel"),("아모스","Amos"),("오바댜","Obadiah"),("요나","Jonah"),
        ("미가","Micah"),("나훔","Nahum"),("하박국","Habakkuk"),("스바냐","Zephaniah"),
        ("학개","Haggai"),("스가랴","Zechariah"),("말라기","Malachi"),
        ("마태복음","Matthew"),("마가복음","Mark"),("누가복음","Luke"),("요한계시록","Revelation"),
        ("요한복음","John"),("사도행전","Acts"),("로마서","Romans"),
        ("고린도전서","1 Corinthians"),("고린도후서","2 Corinthians"),("갈라디아서","Galatians"),
        ("에베소서","Ephesians"),("빌립보서","Philippians"),("골로새서","Colossians"),
        ("데살로니가전서","1 Thessalonians"),("데살로니가후서","2 Thessalonians"),
        ("디모데전서","1 Timothy"),("디모데후서","2 Timothy"),("디도서","Titus"),
        ("빌레몬서","Philemon"),("히브리서","Hebrews"),("야고보서","James"),
        ("베드로전서","1 Peter"),("베드로후서","2 Peter"),
        ("요한일서","1 John"),("요한이서","2 John"),("요한삼서","3 John"),("유다서","Jude"),
        // Short forms the church uses in its own titles: "(수 7:1-26)".
        ("수","Joshua"),("삿","Judges"),("창","Genesis"),("출","Exodus"),("레","Leviticus"),
        ("민","Numbers"),("신","Deuteronomy"),("삼상","1 Samuel"),("삼하","2 Samuel"),
        ("왕상","1 Kings"),("왕하","2 Kings"),("대상","1 Chronicles"),("대하","2 Chronicles"),
        ("느","Nehemiah"),("욥","Job"),("시","Psalm"),("잠","Proverbs"),("전","Ecclesiastes"),
        ("사","Isaiah"),("렘","Jeremiah"),("겔","Ezekiel"),("단","Daniel"),
        ("마","Matthew"),("막","Mark"),("눅","Luke"),("요","John"),("행","Acts"),
        ("롬","Romans"),("고전","1 Corinthians"),("고후","2 Corinthians"),("갈","Galatians"),
        ("엡","Ephesians"),("빌","Philippians"),("골","Colossians"),("히","Hebrews"),
        ("약","James"),("벧전","1 Peter"),("벧후","2 Peter"),("계","Revelation")
    ]

    /// Pulls a reference out of a title like
    /// "[모닝워십] 화, 9.22.2026 욕심쟁이 세상 (사사기 9:46–57) @…".
    static func passage(in title: String) -> Passage? {
        // Longest names first so a short form never shadows a full one.
        let ordered = books.sorted { $0.korean.count > $1.korean.count }

        for book in ordered {
            let pattern = NSRegularExpression.escapedPattern(for: book.korean)
                // The en-dash is what these titles actually use for ranges.
                + "\\s*(\\d{1,3})(?:\\s*[:장]\\s*(\\d{1,3}(?:\\s*[-–—]\\s*\\d{1,3})?))?"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = title as NSString
            guard let match = regex.firstMatch(
                in: title, range: NSRange(location: 0, length: ns.length)
            ) else { continue }

            guard let chapter = Int(ns.substring(with: match.range(at: 1))) else { continue }
            var verses: String?
            if match.range(at: 2).location != NSNotFound {
                verses = ns.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: "–", with: "-")
                    .replacingOccurrences(of: "—", with: "-")
                    .replacingOccurrences(of: " ", with: "")
            }
            return Passage(
                koreanBook: book.korean,
                englishBook: book.english,
                chapter: chapter,
                verses: verses
            )
        }
        return nil
    }
}
