//
//  LeadSheetView.swift
//  SolaPraise
//
//  The full lead sheet: 곡의 진행 (sections derived from repeated chord
//  blocks), chords per section, and lyrics.
//
//  WHY LYRICS ARE TYPED, NOT FETCHED: Korean worship lyrics are copyrighted
//  and have no licensed API, so the app cannot reproduce them. What it can do
//  is open a web search so you find them yourself, and take a paste — a link
//  out is not reproduction. Your church's CCLI licence is what covers printing
//  them on the exported sheet, which is why the CCLI number is stamped on it.
//

import SwiftUI
import SwiftData

struct LeadSheetView: View {
    @Bindable var song: SavedSong

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var useFlats = false
    @State private var pdf: ShareableFile?
    @State private var renaming: SongSection?
    @State private var showPerformance = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                wideLayout
            } else {
                ScrollViewReader { proxy in
                    List {
                        mapRow { jump(to: $0, with: proxy) }
                        transposeSection
                        ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                            sectionBlock(section, at: index)
                                .id(section.id)
                        }
                        ccliFooter
                    }
                }
            }
        }
        .navigationTitle(song.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $pdf) { ActivityView(url: $0.url) }
        .sheet(item: $renaming) { section in
            RenameSectionSheet(song: song, section: section)
        }
        .fullScreenCover(isPresented: $showPerformance) {
            PerformanceModeView(songs: [song])
        }
    }

    // MARK: - Wide layout

    /// Sections side by side rather than in one tall column.
    ///
    /// A song's sections are short and there are several of them, so stacking
    /// them vertically on an iPad left a narrow ribbon of content down the
    /// middle with most of the screen blank, and the chorus three scrolls away
    /// from the verse it follows. Side by side, a whole song is usually on
    /// one screen — which is how a chart is meant to be read.
    private var wideLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SongMapView(sections: song.sections,
                                quality: SongStructure.quality(chords: song.chords)) {
                        jump(to: $0, with: proxy)
                    }
                        .padding(.horizontal, 20)

                    transposeCard
                        .padding(.horizontal, 20)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                            sectionCard(section, at: index)
                                .id(section.id)
                        }
                    }
                    .padding(.horizontal, 20)

                    ccliCard
                        .padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// The map's row in a `List`, stripped of the inset and separator a
    /// normal row would get — it is a full-width band, not a cell.
    @ViewBuilder
    private func mapRow(_ onSelect: @escaping (SongSection) -> Void) -> some View {
        if !song.sections.isEmpty {
            Section {
                SongMapView(sections: song.sections,
                            quality: SongStructure.quality(chords: song.chords),
                            onSelect: onSelect)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func jump(to section: SongSection, with proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.25)) {
            proxy.scrollTo(section.id, anchor: .top)
        }
    }

    private func sectionCard(_ section: SongSection, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Capsule()
                    .fill(SongMapView.colour(for: section.patternKey))
                    .frame(width: 4, height: 13)
                Text(section.label)
                    .font(.subheadline.weight(.semibold))
                Text(timeString(section.startTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("이름 변경") { renaming = section }
                    .font(.caption)
            }
            chordRow(for: section)
            lyricsEditor(for: section, at: index)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showPerformance = true } label: {
                Image(systemName: "music.note.tv")
            }
            .accessibilityLabel("연주 모드")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                SheetMusicMenu(title: song.title) {
                    Label("공식 악보 찾기", systemImage: "doc.text.magnifyingglass")
                }

                AudioSourceMenu(title: song.title) {
                    Label("음원 찾기", systemImage: "waveform.badge.magnifyingglass")
                }

                Menu("가사 찾기") {
                    Button("네이버에서 검색") { search(on: .naver) }
                    Button("구글에서 검색") { search(on: .google) }
                }
                Divider()
                ShareLink(item: exportText()) {
                    Label("텍스트로 공유", systemImage: "doc.plaintext")
                }
                Button {
                    if let url = ChordSheetPDF.exportLeadSheet(song: song, useFlats: useFlats) {
                        pdf = ShareableFile(url: url)
                    }
                } label: {
                    Label("악보 PDF로 공유", systemImage: "doc.richtext")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Transpose

    private var transposeSection: some View {
        Section { transposeControls }
    }

    /// iPad: a `Form` nested in a `ScrollView`'s `VStack` has no definite
    /// height and collapses to an empty band — which is what it did, so the
    /// key and the transpose buttons were simply absent on iPad. A card
    /// needs no container.
    private var transposeCard: some View {
        VStack(alignment: .leading, spacing: 12) { transposeControls }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Container-free, so both of the above can place it.
    @ViewBuilder
    private var transposeControls: some View {
            HStack {
                Text("Key")
                    .foregroundStyle(.secondary)
                Text(transposedKey ?? "—").bold()
                // The team's own key, where they published one. A microphone
                // estimate is a guess at something they already stated.
                if song.keyIsPublished {
                    Text("공식")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                } else if song.detectedKey != nil {
                    Text("감지됨")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(song.semitoneShift == 0
                     ? "원키"
                     : (song.semitoneShift > 0 ? "+\(song.semitoneShift)" : "\(song.semitoneShift)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { shift(-1) } label: { Image(systemName: "minus.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                Button("원키로") { song.semitoneShift = 0; save() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button { shift(1) } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                Toggle("♭", isOn: $useFlats).toggleStyle(.button).fixedSize()
            }
    }

    // MARK: - Section block

    private func sectionBlock(_ section: SongSection, at index: Int) -> some View {
        Section {
            chordRow(for: section)
            lyricsEditor(for: section, at: index)
        } header: {
            HStack {
                // The same colour the map gave this progression, so the two
                // views are obviously about the same thing.
                Capsule()
                    .fill(SongMapView.colour(for: section.patternKey))
                    .frame(width: 4, height: 13)
                Text(section.label)
                    .font(.subheadline.weight(.semibold))
                Text(timeString(section.startTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("이름 변경") { renaming = section }
                    .font(.caption)
            }
        }
    }

    private func chordRow(for section: SongSection) -> some View {
        let chords = song.chords
        let slice = chords.indices.contains(section.startIndex)
            ? Array(chords[section.startIndex...min(section.endIndex, chords.count - 1)])
            : []

        return FlowRow(spacing: 8) {
            ForEach(slice) { chord in
                Text(chord.asChord.transposed(by: song.semitoneShift).symbol(useFlats: useFlats))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }

    private func lyricsEditor(for section: SongSection, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(
                get: { song.sections[index].lyrics },
                set: { newValue in
                    var sections = song.sections
                    guard sections.indices.contains(index) else { return }
                    sections[index].lyrics = newValue
                    song.sections = sections
                    save()
                }
            ))
            .frame(minHeight: 64)
            .overlay(alignment: .topLeading) {
                if song.sections[index].lyrics.isEmpty {
                    Text("가사를 붙여넣으세요")
                        .foregroundStyle(.tertiary)
                        .font(.footnote)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }

            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                var sections = song.sections
                guard sections.indices.contains(index) else { return }
                sections[index].lyrics = text
                song.sections = sections
                save()
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
        }
    }

    // MARK: - CCLI

    private var ccliBinding: Binding<String> {
        Binding(
            get: { song.ccliNumber ?? "" },
            set: { song.ccliNumber = $0.isEmpty ? nil : $0; save() }
        )
    }

    private static let ccliNote = "가사는 저작권이 있어 앱이 가져올 수 없습니다. 직접 붙여넣어 주세요. 내보낸 악보에 인쇄하려면 교회의 CCLI 라이선스가 필요하며, 번호가 악보에 표시됩니다."

    private var ccliFooter: some View {
        Section {
            TextField("CCLI 번호 (선택)", text: ccliBinding)
                .keyboardType(.numbersAndPunctuation)
        } footer: {
            Text(Self.ccliNote)
        }
    }

    /// See `transposeCard` — the footer vanished on iPad for the same reason.
    private var ccliCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("CCLI 번호 (선택)", text: ccliBinding)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
            Text(Self.ccliNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Helpers

    private func shift(_ delta: Int) {
        song.semitoneShift = max(-11, min(11, song.semitoneShift + delta))
        save()
    }

    private func save() { try? modelContext.save() }

    private var transposedKey: String? {
        guard let raw = song.keyLabel else { return nil }
        // A detected key reads "G major"; a published one is bare, "E" or
        // "F#m". Both transpose, so the quality part is optional.
        let parts = raw.split(separator: " ")
        guard let first = parts.first else { return raw }

        var name = String(first)
        var suffix = parts.count > 1 ? " " + parts.dropFirst().joined(separator: " ") : ""
        // "Bbm" — the minor marker rides on the root when there is no space.
        if parts.count == 1, name.count > 1, name.hasSuffix("m") {
            name = String(name.dropLast())
            suffix = "m"
        }

        guard let root = Chord.sharpNames.firstIndex(of: name)
                ?? Chord.flatNames.firstIndex(of: name)
        else { return raw }

        let newRoot = ((root + song.semitoneShift) % 12 + 12) % 12
        let shifted = (useFlats ? Chord.flatNames : Chord.sharpNames)[newRoot]
        return shifted + suffix
    }

    private enum SearchEngine { case naver, google }

    /// Opens a web search so the user can find lyrics themselves. A link out
    /// is not reproduction — the app never ingests the page.
    private func search(on engine: SearchEngine) {
        let query = "\(song.title) 가사"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let string = switch engine {
        case .naver:  "https://search.naver.com/search.naver?query=\(encoded)"
        case .google: "https://www.google.com/search?q=\(encoded)"
        }
        guard let url = URL(string: string) else { return }
        openURL(url)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func exportText() -> String {
        var out = song.title + "\n"
        if let key = transposedKey { out += "Key: \(key)\n" }
        out += "\n"
        let chords = song.chords
        for section in song.sections {
            out += "[\(section.label)]\n"
            if chords.indices.contains(section.startIndex) {
                let slice = chords[section.startIndex...min(section.endIndex, chords.count - 1)]
                out += slice
                    .map { $0.asChord.transposed(by: song.semitoneShift).symbol(useFlats: useFlats) }
                    .joined(separator: "  ") + "\n"
            }
            if !section.lyrics.isEmpty { out += section.lyrics + "\n" }
            out += "\n"
        }
        if let ccli = song.ccliNumber, !ccli.isEmpty { out += "CCLI #\(ccli)\n" }
        return out
    }
}

// MARK: - Rename

private struct RenameSectionSheet: View {
    @Bindable var song: SavedSong
    let section: SongSection

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("이름") {
                    TextField("섹션 이름", text: $name)
                }
                Section("자주 쓰는 이름") {
                    ForEach(SongStructure.suggestedLabels, id: \.self) { suggestion in
                        Button(suggestion) { name = suggestion }
                    }
                }
            }
            .navigationTitle("섹션 이름")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { apply() }.disabled(name.isEmpty)
                }
            }
            .onAppear { name = section.label }
        }
    }

    private func apply() {
        var sections = song.sections
        if let index = sections.firstIndex(where: { $0.id == section.id }) {
            sections[index].label = name
            song.sections = sections
            try? modelContext.save()
        }
        dismiss()
    }
}

// MARK: - Wrapping row

/// Minimal flow layout so chord chips wrap instead of clipping.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
