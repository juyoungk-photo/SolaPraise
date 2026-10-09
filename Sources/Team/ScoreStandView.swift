//
//  ScoreStandView.swift
//  SolaPraise
//
//  연주모드 for attached 악보: the team's own charts on a dark stand, in the
//  team's key.
//
//  Opening a chart reads its chords and moves them to the key the 순서 says
//  the song is played in — the transposition is the DEFAULT, not a tool you
//  go looking for, because the chart someone uploaded is usually in the
//  publisher's key and the team is usually not. The reader can still step
//  it up or down from there, see the original, and take the result away as
//  a PDF of the same page.
//
//  Shown as a preview over the page image, drawn with the same geometry the
//  export uses, so what was checked on screen is what goes into the file.
//

import SwiftUI
import UIKit

struct ScoreStandItem: Identifiable, Hashable {
    let attachment: Attachment
    let song: String
    /// The key in the 순서, as the leader typed it. Nil when unset.
    let teamKey: String?

    var id: String { attachment.id }
}

struct ScoreStandView: View {
    let items: [ScoreStandItem]
    /// Uploads a transposed PDF as a new attachment on the song, when the
    /// caller can (Drive granted, a sheet configured). Returns an error
    /// message, or nil on success.
    var uploadTransposed: ((ScoreStandItem, Data, String) async -> String?)?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @StateObject private var model = ScoreStandModel()

    init(items: [ScoreStandItem], startAt: Int = 0,
         uploadTransposed: ((ScoreStandItem, Data, String) async -> String?)? = nil) {
        self.items = items
        self.uploadTransposed = uploadTransposed
        _index = State(initialValue: max(0, min(startAt, items.count - 1)))
    }

    private var item: ScoreStandItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let item {
                VStack(spacing: 0) {
                    header(item)
                    pages(item)
                    controls(item)
                }
                .foregroundStyle(.white)
                .task(id: item.id) { await model.load(item) }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(14)
            }
            .accessibilityLabel("닫기")
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        // Same rule as the chord stand: a set runs forty minutes and
        // nobody touches the screen. It must not sleep mid-song.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .focusable()
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .alert("악보", isPresented: .constant(model.note != nil)) {
            Button("확인") { model.note = nil }
        } message: {
            Text(model.note ?? "")
        }
        .sheet(item: $model.export) { file in
            ShareSheet(items: [file.url])
        }
    }

    // MARK: - Header

    private func header(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.song.isEmpty ? item.attachment.name : item.song)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                if items.count > 1 {
                    Text("\(index + 1)/\(items.count)")
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            if let state, state.isReady {
                Text(keyLine(item, state))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 60)     // clear of the close button
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the reader needs to trust the default: where the chart started,
    /// where it is now, and why.
    private func keyLine(_ item: ScoreStandItem, _ state: ScoreStandModel.State) -> String {
        guard state.chordCount > 0 else {
            return "코드를 찾지 못했습니다 — 손글씨, 사진 각도, 어두운 배경은 읽지 못할 수 있습니다."
        }
        let from = state.scoreRoot.map { ScoreStandModel.name($0, flats: state.useFlats) } ?? "?"
        let to = state.targetRoot.map { ScoreStandModel.name($0, flats: state.useFlats) } ?? "?"
        var line = "코드 \(state.chordCount)개 · 악보 \(from) → \(to)"
        if let teamKey = item.teamKey, state.defaultShift != nil {
            line += " (순서의 키 \(teamKey))"
        } else if item.teamKey == nil {
            line += " · 순서에 키가 없어 원키로 시작"
        }
        return line
    }

    // MARK: - Pages

    @ViewBuilder
    private func pages(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        if let state, state.isReady {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(state.pages.enumerated()), id: \.offset) { _, page in
                        ScorePageView(page: page,
                                      shift: state.showsOriginal ? 0 : state.shift,
                                      useFlats: state.useFlats)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            // Swipe sideways between songs; vertical is the page scroll.
            .simultaneousGesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5
                        else { return }
                        if value.translation.width < -60 { go(1) }
                        else if value.translation.width > 60 { go(-1) }
                    }
            )
        } else if let failure = state?.failure {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(failure)
                    .multilineTextAlignment(.center)
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("악보에서 코드를 읽는 중…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Controls

    private func controls(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        let ready = state?.isReady == true && (state?.chordCount ?? 0) > 0
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if items.count > 1 {
                    Button { go(-1) } label: { pill(Image(systemName: "chevron.left")) }
                        .disabled(index == 0)
                        .accessibilityLabel("이전 곡")
                }

                Button { model.step(item, -1) } label: { pill(Text("−")) }
                    .disabled(!ready)
                    .accessibilityLabel("반음 내리기")
                Text(shiftLabel(state))
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .frame(minWidth: 52)
                Button { model.step(item, 1) } label: { pill(Text("+")) }
                    .disabled(!ready)
                    .accessibilityLabel("반음 올리기")

                Button { model.toggleFlats(item) } label: {
                    pill(Text(state?.useFlats == true ? "♭" : "♯"),
                         active: state?.flatsOverride != nil)
                }
                .disabled(!ready)
                .accessibilityLabel("♭/♯ 표기 바꾸기")

                Button { model.toggleOriginal(item) } label: {
                    pill(Text("원본"), active: state?.showsOriginal == true, wide: true)
                }
                .disabled(!ready)

                if state?.defaultShift != nil, state?.shift != state?.defaultShift {
                    Button { model.resetToTeamKey(item) } label: {
                        pill(Text("팀 키"), wide: true)
                    }
                }

                Button {
                    Task { await model.exportPDF(item) }
                } label: {
                    pill(Image(systemName: "square.and.arrow.up"))
                }
                .disabled(!ready || model.isExporting)
                .accessibilityLabel("PDF로 내보내기")

                if let uploadTransposed {
                    Button {
                        Task { await model.upload(item, using: uploadTransposed) }
                    } label: {
                        pill(model.isUploading ? AnyView(ProgressView().tint(.white))
                                               : AnyView(Image(systemName: "icloud.and.arrow.up")))
                    }
                    .disabled(!ready || model.isUploading || (state?.shift ?? 0) == 0)
                    .accessibilityLabel("조옮김한 악보를 드라이브에 첨부")
                }

                if items.count > 1 {
                    Button { go(1) } label: { pill(Image(systemName: "chevron.right")) }
                        .disabled(index >= items.count - 1)
                        .accessibilityLabel("다음 곡")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
    }

    private func shiftLabel(_ state: ScoreStandModel.State?) -> String {
        guard let shift = state?.shift, shift != 0 else { return "원키" }
        return shift > 0 ? "+\(shift)" : "\(shift)"
    }

    private func pill<V: View>(_ content: V, active: Bool = false, wide: Bool = false) -> some View {
        content
            .font(.system(size: 18, weight: .semibold))
            .frame(width: wide ? 60 : 44, height: 40)
            .background(active ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
    }

    private func go(_ delta: Int) {
        let target = index + delta
        guard items.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.18)) { index = target }
    }
}

// MARK: - One page

/// A page image with each found chord covered and rewritten — the same
/// patch and size ScoreTransposer uses for the export.
private struct ScorePageView: View {
    let page: ScoreTransposer.Page
    let shift: Int
    let useFlats: Bool?

    var body: some View {
        Image(uiImage: page.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if shift % 12 != 0 {
                        ForEach(page.chords) { chord in
                            if let moved = ScoreTransposer.symbol(chord.original, by: shift,
                                                                  useFlats: useFlats) {
                                label(moved, box: chord.box, size: geo.size)
                            }
                        }
                    }
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func label(_ text: String, box: CGRect, size: CGSize) -> some View {
        let patch = ScoreTransposer.patchRect(for: box, textHeight: page.chordHeight, in: size)
        let height = patch.height / 1.3
        return Text(text)
            .font(.system(size: ScoreTransposer.fontSize(forBoxHeight: page.chordHeight * size.height),
                          weight: .bold))
            .foregroundStyle(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: patch.width, height: patch.height, alignment: .leading)
            .padding(.leading, height * 0.15)
            .frame(width: patch.width, height: patch.height, alignment: .leading)
            .background(Color.white)
            // Highlighted lightly, so a reader can see at a glance which
            // symbols were changed — and which were not, which is the
            // thing to check on a chart that was read badly.
            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            .position(x: patch.midX, y: patch.midY)
    }
}

// MARK: - Model

@MainActor
final class ScoreStandModel: ObservableObject {

    struct State {
        var pages: [ScoreTransposer.Page] = []
        var source: ScoreTransposer.Source = .pdf
        var isReady = false
        var failure: String?
        var scoreRoot: Int?
        /// From the 순서's key, when both it and the chart's key are known.
        var defaultShift: Int?
        var shift = 0
        var showsOriginal = false
        /// Nil spells by the key the chart lands in; the ♭ button flips it.
        var flatsOverride: Bool?

        var chordCount: Int { pages.reduce(0) { $0 + $1.chords.count } }

        /// The key the chart is shown in now.
        var targetRoot: Int? {
            scoreRoot.map { ($0 + (showsOriginal ? 0 : shift) + 120) % 12 }
        }

        /// Spelled the way a player in that key expects: B♭ and E♭ in B♭,
        /// not A# and D#. Keys with flats in their signature — F, B♭, E♭,
        /// A♭, D♭, G♭ — take flats. Without a known key, sharps.
        var useFlats: Bool {
            if let flatsOverride { return flatsOverride }
            guard let root = targetRoot else { return false }
            return [5, 10, 3, 8, 1, 6].contains(root)
        }
    }

    struct ExportFile: Identifiable { let url: URL; var id: URL { url } }

    @Published var states: [String: State] = [:]
    @Published var note: String?
    @Published var export: ExportFile?
    @Published var isExporting = false
    @Published var isUploading = false

    /// Read once per attachment per launch: recognition is seconds a page,
    /// and paging back to a song should not run it again.
    private static var cache: [String: State] = [:]

    func load(_ item: ScoreStandItem) async {
        if states[item.id] != nil { return }
        if let cached = Self.cache[item.id] {
            states[item.id] = cached
            return
        }
        states[item.id] = State()

        let data: Data
        do {
            let (bytes, _) = try await URLSession.shared.data(from: item.attachment.url.directDownload)
            data = bytes
        } catch {
            states[item.id]?.failure = "악보를 내려받지 못했습니다. 연결을 확인하세요."
            return
        }
        guard let read = await ScoreTransposer.read(data: data), !read.pages.isEmpty else {
            // Drive answers a file that is not shared by link with a
            // sign-in page, which is neither a PDF nor an image.
            states[item.id]?.failure = "이 파일은 악보로 열 수 없습니다. PDF나 이미지인지, 링크 공유가 켜져 있는지 확인하세요."
            return
        }

        var state = State()
        state.pages = read.pages
        state.source = read.source
        let symbols = read.pages.flatMap { $0.chords.map(\.original) }
        state.scoreRoot = ScoreChordText.likelyRoot(of: symbols)
        state.defaultShift = ScoreRecognition.shift(fromScoreChords: symbols, toKey: item.teamKey)
        // A shift the reader chose on this device wins over the default.
        state.shift = Self.savedShift(for: item.id) ?? state.defaultShift ?? 0
        state.isReady = true
        states[item.id] = state
        Self.cache[item.id] = state
    }

    func step(_ item: ScoreStandItem, _ delta: Int) {
        update(item) { state in
            var next = state.shift + delta
            if next > 6 { next -= 12 }
            if next < -5 { next += 12 }
            state.shift = next
            state.showsOriginal = false
        }
        if let shift = states[item.id]?.shift { Self.saveShift(shift, for: item.id) }
    }

    func resetToTeamKey(_ item: ScoreStandItem) {
        update(item) { state in
            state.shift = state.defaultShift ?? 0
            state.showsOriginal = false
        }
        Self.saveShift(nil, for: item.id)
    }

    func toggleFlats(_ item: ScoreStandItem) {
        // First press: the other spelling. Second: back to the key's own.
        update(item) { state in
            state.flatsOverride = state.flatsOverride == nil ? !state.useFlats : nil
        }
    }

    func toggleOriginal(_ item: ScoreStandItem) {
        update(item) { $0.showsOriginal.toggle() }
    }

    private func update(_ item: ScoreStandItem, _ change: (inout State) -> Void) {
        guard var state = states[item.id] else { return }
        change(&state)
        states[item.id] = state
        Self.cache[item.id] = state
    }

    // MARK: Export

    /// "주님 뜻대로 (A).pdf" — named for the key it is now in.
    func fileName(_ item: ScoreStandItem) -> String {
        let state = states[item.id]
        let base = (item.song.isEmpty ? item.attachment.name : item.song)
            .replacingOccurrences(of: "/", with: "-")
        guard let state, let root = state.targetRoot else { return "\(base).pdf" }
        let key = Self.name(root, flats: state.useFlats)
        return "\(base) (\(key)).pdf"
    }

    private func pdf(_ item: ScoreStandItem) async -> Data? {
        guard let state = states[item.id] else { return nil }
        let pages = state.pages
        let shift = state.showsOriginal ? 0 : state.shift
        let flats: Bool? = state.useFlats
        return await Task.detached(priority: .userInitiated) {
            ScoreTransposer.transposed(pages: pages, by: shift, useFlats: flats)
        }.value
    }

    func exportPDF(_ item: ScoreStandItem) async {
        isExporting = true
        defer { isExporting = false }
        guard let data = await pdf(item) else {
            note = "PDF를 만들지 못했습니다."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(item))
        do {
            try data.write(to: url, options: .atomic)
            export = ExportFile(url: url)
        } catch {
            note = "PDF를 저장하지 못했습니다."
        }
    }

    func upload(_ item: ScoreStandItem,
                using send: (ScoreStandItem, Data, String) async -> String?) async {
        isUploading = true
        defer { isUploading = false }
        guard let data = await pdf(item) else {
            note = "PDF를 만들지 못했습니다."
            return
        }
        if let failure = await send(item, data, fileName(item)) {
            note = failure
        } else {
            note = "「\(fileName(item))」을 이 곡의 첨부로 올렸습니다. 팀원도 같은 파일을 봅니다."
        }
    }

    // MARK: Remembered shift

    private static func savedShift(for id: String) -> Int? {
        UserDefaults.standard.object(forKey: "score.shift.\(id)") as? Int
    }

    private static func saveShift(_ shift: Int?, for id: String) {
        UserDefaults.standard.set(shift, forKey: "score.shift.\(id)")
    }

    static func name(_ root: Int, flats: Bool) -> String {
        let sharps = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let flatNames = ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"]
        return (flats ? flatNames : sharps)[((root % 12) + 12) % 12]
    }
}

/// UIActivityViewController, for handing the PDF to Files, AirDrop, Mail or
/// a print dialog — wherever a team actually keeps its charts.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
