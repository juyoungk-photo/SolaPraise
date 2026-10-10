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
import PDFKit

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
    /// Names the whole-set PDF: 「10월 12일 주일예배」.
    var setTitle: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var index: Int
    @StateObject private var model = ScoreStandModel()
    /// Edit mode: drag a chord, tap it to correct or remove it, press and
    /// hold on the page to add one recognition missed.
    @State private var editing = false
    @State private var chordAction: ChordAction?
    @State private var entry: ChordEntry?
    @State private var choosingPage = false
    /// Where an added chord starts: near the top left of the page, clear of
    /// the title, ready to be dragged.
    static let addPoint = CGPoint(x: 0.2, y: 0.08)

    struct ChordAction: Identifiable { let page: Int; let chord: UUID; var id: UUID { chord } }
    /// Typing a chord: correcting one (chord set) or adding one at a point.
    struct ChordEntry: Identifiable {
        let page: Int
        let chord: UUID?
        let point: CGPoint
        var text: String
        let id = UUID()
    }

    init(items: [ScoreStandItem], startAt: Int = 0, setTitle: String? = nil,
         uploadTransposed: ((ScoreStandItem, Data, String) async -> String?)? = nil) {
        self.items = items
        self.setTitle = setTitle
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
                #if DEBUG
                .task {
                    if DebugHarness.exportScoreSet { await model.exportSet(items, title: setTitle) }
                }
                #endif
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
            Button("확인") {
                model.note = nil
                if let pending = model.pendingExport {
                    model.pendingExport = nil
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        model.export = pending
                    }
                }
            }
        } message: {
            Text(model.note ?? "")
        }
        .sheet(item: $model.export) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog("코드", isPresented: .constant(chordAction != nil),
                            titleVisibility: .hidden, presenting: chordAction) { action in
            Button("코드 고치기") {
                let shown = item.map { model.displayed(action.chord, page: action.page, in: $0) } ?? ""
                entry = ChordEntry(page: action.page, chord: action.chord, point: .zero, text: shown ?? "")
                chordAction = nil
            }
            Button("이 코드 지우기", role: .destructive) {
                if let item { model.remove(item, page: action.page, chord: action.chord) }
                chordAction = nil
            }
            Button("취소", role: .cancel) { chordAction = nil }
        } message: { _ in
            Text("코드가 아닌 글자를 잘못 읽었다면 지우세요. 지우면 원래 인쇄된 글자가 그대로 보입니다.")
        }
        .confirmationDialog("어느 쪽에 넣을까요?", isPresented: $choosingPage, titleVisibility: .visible) {
            ForEach(0..<(item.flatMap { model.states[$0.id]?.pages.count } ?? 0), id: \.self) { page in
                Button("\(page + 1)쪽") {
                    entry = ChordEntry(page: page, chord: nil, point: Self.addPoint, text: "")
                }
            }
            Button("취소", role: .cancel) {}
        }
        .alert(entry?.chord == nil ? "코드 추가" : "코드 고치기",
               isPresented: .constant(entry != nil)) {
            TextField("예: G, D/F#, Em7", text: Binding(
                get: { entry?.text ?? "" }, set: { entry?.text = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Latin letters: on a Korean keyboard 「B」 types 「ㅠ」.
                .keyboardType(.asciiCapable)
            Button("저장") {
                if let entry, let item {
                    if let failure = model.write(entry.text, item, page: entry.page,
                                                 chord: entry.chord, at: entry.point) {
                        model.note = failure
                    }
                }
                entry = nil
            }
            Button("취소", role: .cancel) { entry = nil }
        } message: {
            Text(entry?.chord == nil
                 ? "지금 화면에 보이는 키로 적으세요. 페이지 위쪽에 놓이니, 끌어서 제자리로 옮기세요."
                 : "지금 화면에 보이는 키로 적으세요.")
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
            if editing {
                Text("코드를 끌어서 옮기고, 눌러서 고치거나 지우세요. 빠진 코드는 「+ 코드」로 넣고 제자리로 끌어다 놓으세요.")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
            } else if let state, state.isReady {
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
        // Where the chart's key came from, so a wrong guess can be spotted:
        // the file name says what was printed; the chords only suggest.
        let source: String
        if let written = state.writtenKey {
            source = written.hasSuffix("m") ? "\(written) — 파일 이름" : "파일 이름"
        } else {
            source = "코드로 추정"
        }
        var line = "코드 \(state.chordCount)개 · 악보 \(from)(\(source)) → \(to)"
        if state.writtenKey != nil, let estimated = state.estimatedRoot, estimated != state.scoreRoot {
            line += " · 코드로는 \(ScoreStandModel.name(estimated, flats: state.useFlats))"
        }
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
                    ForEach(Array(state.pages.enumerated()), id: \.offset) { pageIndex, page in
                        ScorePageView(
                            page: page,
                            shift: state.showsOriginal ? 0 : state.shift,
                            useFlats: state.useFlats,
                            scale: model.chordScale,
                            editing: editing,
                            onMove: { id, offset in model.move(item, page: pageIndex, chord: id, to: offset) },
                            onTapChord: { id in chordAction = ChordAction(page: pageIndex, chord: id) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            // No page scroll while editing: a drag moves a chord.
            .scrollDisabled(editing)
            // Swipe sideways between songs; vertical is the page scroll.
            // Not while editing, where a sideways drag is a chord being moved.
            .simultaneousGesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        guard !editing else { return }
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

    /// Key on the left, 원본 in the middle, tools on the right and the
    /// song arrows at the far right edge — one row where it fits, two where
    /// it does not. The arrows were split, ‹ at the left end and › at the
    /// right; on a stand both are reached with the same hand, so they sit
    /// together.
    ///
    /// The first layout was one scrolling row: on a phone it ran off the
    /// edge, and the key itself was never shown — only "+1" and a lone ♭
    /// or ♯, which read as a broken key name. The key the chart is in now
    /// is the biggest thing in the row.
    private func controls(_ item: ScoreStandItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                keyGroup(item)
                Spacer(minLength: 12)
                originalButton(item)
                Spacer(minLength: 12)
                toolGroup(item)
                songNav()
            }
            .padding(.horizontal, 16)

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    keyGroup(item)
                    Spacer(minLength: 8)
                    originalButton(item)
                }
                .padding(.horizontal, 16)
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            toolGroup(item)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) { toolGroup(item) }
                        }
                    }
                    // Outside the scroll: the arrows never scroll away.
                    songNav()
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
    }

    @ViewBuilder
    private func keyGroup(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        let ready = state?.isReady == true && (state?.chordCount ?? 0) > 0
        Button { model.step(item, -1) } label: { pill(Text("−")) }
            .disabled(!ready)
            .accessibilityLabel("반음 내리기")

        // The key, large, with the step from the printed key under it.
        VStack(spacing: 0) {
            Text(state.flatMap(ScoreStandModel.keyName) ?? "–")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text(shiftLabel(state))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(minWidth: 58, minHeight: 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("지금 키 \(state.flatMap(ScoreStandModel.keyName) ?? "모름"), \(shiftLabel(state))")

        Button { model.step(item, 1) } label: { pill(Text("+")) }
            .disabled(!ready)
            .accessibilityLabel("반음 올리기")

        Button { model.toggleFlats(item) } label: {
            pill(Text("♯/♭").font(.system(size: 15, weight: .semibold)),
                 active: state?.flatsOverride != nil, wide: true)
        }
        .disabled(!ready)
        .accessibilityLabel(state?.useFlats == true ? "샵으로 표기" : "플랫으로 표기")

        if state?.defaultShift != nil, state?.shift != state?.defaultShift {
            Button { model.resetToTeamKey(item) } label: {
                pill(Text("팀 키").font(.system(size: 15, weight: .semibold)), wide: true)
            }
        }
    }

    private func originalButton(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        let ready = state?.isReady == true && (state?.chordCount ?? 0) > 0
        return Button { model.toggleOriginal(item) } label: {
            pill(Text("원본"), active: state?.showsOriginal == true, wide: true)
        }
        .disabled(!ready)
    }

    @ViewBuilder
    private func toolGroup(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        let ready = state?.isReady == true && (state?.chordCount ?? 0) > 0
        // Chord size, for charts printed small. Applies to the export too,
        // and is remembered on this device.
        Button { model.resize(by: -0.1) } label: { pill(Text("A").font(.system(size: 13, weight: .bold))) }
            .disabled(!ready || model.chordScale <= 0.71)
            .accessibilityLabel("코드 글자 작게")
        Button { model.resize(by: 0.1) } label: { pill(Text("A").font(.system(size: 21, weight: .bold))) }
            .disabled(!ready || model.chordScale >= 2.49)
            .accessibilityLabel("코드 글자 크게")

        Button { editing.toggle() } label: {
            pill(Text(editing ? "완료" : "편집"), active: editing, wide: true)
        }
        .disabled(!(state?.isReady ?? false))
        .accessibilityLabel(editing ? "편집 끝내기" : "코드 위치·글자 편집")

        if editing {
            // Added near the top of the page, then dragged into place.
            Button {
                if (state?.pages.count ?? 0) > 1 { choosingPage = true }
                else { entry = ChordEntry(page: 0, chord: nil, point: Self.addPoint, text: "") }
            } label: {
                pill(Text("+ 코드").font(.system(size: 14, weight: .semibold)), wide: true)
            }
            .accessibilityLabel("빠진 코드 넣기")
        }
        if editing, state?.isEdited == true {
            Button { Task { await model.resetEdits(item) } } label: {
                pill(Text("되돌리기").font(.system(size: 13, weight: .semibold)), wide: true)
            }
            .accessibilityLabel("손으로 고친 것을 모두 지우고 다시 인식")
        }

        // One song, or the whole 콘티 as one file — to share, or keep in
        // Files: the share sheet offers both.
        let shareLabel = pill(model.isExporting ? AnyView(ProgressView().tint(.white))
                                                : AnyView(Image(systemName: "square.and.arrow.up")))
        if items.count > 1 {
            Menu {
                Button {
                    Task { await model.exportPDF(item) }
                } label: { Label("이 곡만 (\(item.song.isEmpty ? "현재 악보" : item.song))", systemImage: "doc") }
                .disabled(!ready)
                Button {
                    Task { await model.exportSet(items, title: setTitle) }
                } label: { Label("콘티 전체 \(items.count)곡 — 한 파일로", systemImage: "doc.on.doc") }
            } label: { shareLabel }
            .disabled(model.isExporting)
            .accessibilityLabel("PDF로 공유·저장")
        } else {
            Button { Task { await model.exportPDF(item) } } label: { shareLabel }
                .disabled(!ready || model.isExporting)
                .accessibilityLabel("PDF로 공유·저장")
        }

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

    }

    /// Previous and next song, side by side at the right edge.
    @ViewBuilder
    private func songNav() -> some View {
        if items.count > 1 {
            HStack(spacing: 6) {
                Button { go(-1) } label: { pill(Image(systemName: "chevron.left")) }
                    .disabled(index == 0)
                    .accessibilityLabel("이전 곡")
                Button { go(1) } label: { pill(Image(systemName: "chevron.right")) }
                    .disabled(index >= items.count - 1)
                    .accessibilityLabel("다음 곡")
            }
            .padding(.leading, 4)
        }
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

/// A page image with each chord covered and rewritten, laid out by
/// ScoreLayout — the same call the PDF export makes — so the preview is
/// the file.
private struct ScorePageView: View {
    let page: ScoreTransposer.Page
    let shift: Int
    let useFlats: Bool?
    let scale: CGFloat
    let editing: Bool
    let onMove: (UUID, CGSize) -> Void
    let onTapChord: (UUID) -> Void

    /// The chord being dragged and how far, in view points.
    @State private var dragging: (id: UUID, by: CGSize)?

    var body: some View {
        Image(uiImage: page.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    let labels = ScoreLayout.labels(
                        chords: page.chords, chordHeight: page.chordHeight, shift: shift,
                        useFlats: useFlats, scale: scale, alwaysDraw: editing, in: size)
                    ZStack(alignment: .topLeading) {
                        ForEach(labels.compactMap(\.cover).indices, id: \.self) { i in
                            let cover = labels.compactMap(\.cover)[i]
                            Rectangle().fill(.white)
                                .frame(width: cover.width, height: cover.height)
                                .position(x: cover.midX, y: cover.midY)
                        }
                        ForEach(labels) { label in
                            chordView(label, size: size)
                        }
                    }
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func chordView(_ label: ScoreLayout.Label, size: CGSize) -> some View {
        let moving = dragging?.id == label.id ? dragging!.by : .zero
        return Text(label.text)
            .font(.system(size: label.fontSize, weight: .bold))
            .foregroundStyle(.black)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, label.textOrigin.x - label.patch.minX)
            .frame(width: label.patch.width, height: label.patch.height, alignment: .leading)
            .background(Color.white)
            // Outlined lightly, so a reader can see which symbols were
            // changed — and which were not, the thing to check on a chart
            // that was read badly. Stronger while editing.
            .overlay(Rectangle().stroke(Color.accentColor.opacity(editing ? 0.9 : 0.35),
                                        lineWidth: editing ? 1.5 : 1))
            // A finger-sized target. On a phone a chord on a dense chart is
            // eight points tall — too small to press, let alone drag — so
            // the touch area reaches past it. Taller than wide: neighbours
            // on a line are close, the lines above and below are not.
            .contentShape(Rectangle().inset(by: -max(0, (36 - label.patch.height) / 2)))
            .position(x: label.patch.midX + moving.width, y: label.patch.midY + moving.height)
            .gesture(editing ? DragGesture(minimumDistance: 4)
                .onChanged { value in dragging = (label.id, value.translation) }
                .onEnded { value in
                    dragging = nil
                    onMove(label.id, CGSize(width: value.translation.width / size.width,
                                            height: value.translation.height / size.height))
                } : nil)
            .onTapGesture { if editing { onTapChord(label.id) } }
            .allowsHitTesting(editing)
            .accessibilityLabel("코드 \(label.text)")
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
        /// The key in the file's name, as written — 「G」, 「F#m」 — when it
        /// has one. Then scoreRoot comes from it rather than the chords.
        var writtenKey: String?
        /// What the chords alone suggest, kept to cross-check a written key.
        var estimatedRoot: Int?
        /// From the 순서's key, when both it and the chart's key are known.
        var defaultShift: Int?
        var shift = 0
        var showsOriginal = false
        /// Nil spells by the key the chart lands in; the ♭ button flips it.
        var flatsOverride: Bool?
        /// Chords moved, corrected, removed or added by hand on this device.
        var isEdited = false

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
    /// A set file waiting for its "some songs were left out" alert to close.
    var pendingExport: ExportFile?
    @Published var isExporting = false
    @Published var isUploading = false
    /// The reader's chord size, 1 = as printed. Per device: a stand at arm's
    /// length and a keyboard at two metres want different sizes.
    @Published private(set) var chordScale: CGFloat =
        (UserDefaults.standard.object(forKey: "score.chordScale") as? Double).map { CGFloat($0) } ?? 1

    func resize(by step: CGFloat) {
        chordScale = min(2.5, max(0.7, (chordScale + step) * 10).rounded() / 10)
        UserDefaults.standard.set(Double(chordScale), forKey: "score.chordScale")
    }

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

        // OPENED BEFORE, OPENS AT ONCE. The file is kept on this device
        // after the first download, and the chords after the first
        // reading — so a chart seen once opens with neither the download
        // nor the seconds of recognition. A new upload is a new file id,
        // so a replaced chart is never served stale.
        let data: Data
        if let kept = ScoreFileCache.load(item.id) {
            data = kept
        } else {
            do {
                let (bytes, _) = try await URLSession.shared.data(from: item.attachment.url.directDownload)
                data = bytes
            } catch {
                states[item.id]?.failure = "악보를 내려받지 못했습니다. 연결을 확인하세요."
                return
            }
        }
        // A reading by an older recogniser is dropped unless someone fixed
        // it by hand — then their corrections win over any new reading.
        var saved = ScoreEditStore.load(item.id)
        if let old = saved, !old.edited, old.version != ScoreRecognition.version { saved = nil }
        guard var read = await ScoreTransposer.read(data: data, recognise: saved == nil),
              !read.pages.isEmpty else {
            // Drive answers a file that is not shared by link with a
            // sign-in page, which is neither a PDF nor an image.
            states[item.id]?.failure = "이 파일은 악보로 열 수 없습니다. PDF나 이미지인지, 링크 공유가 켜져 있는지 확인하세요."
            return
        }

        // Only a real chart is kept: a sign-in page Drive sent in its place
        // has been rejected above and never reaches here.
        ScoreFileCache.save(data, for: item.id)

        var state = State()
        if let saved, saved.pages.count == read.pages.count {
            for index in read.pages.indices { read.pages[index].chords = saved.pages[index] }
            state.isEdited = saved.edited
        } else {
            if saved != nil {
                // The file changed shape since; read it afresh.
                ScoreEditStore.remove(item.id)
                if let fresh = await ScoreTransposer.read(data: data) { read = fresh }
            }
            ScoreEditStore.save(read.pages.map(\.chords), edited: false, for: item.id)
        }
        state.pages = read.pages
        state.source = read.source
        // The chart's key: what its name says, if it says one — that is
        // what was printed — and otherwise what its chords suggest.
        let symbols = read.pages.flatMap { $0.chords.map(\.original) }
        let hint = ScoreChordText.keyHint(in: item.attachment.name) ?? ScoreChordText.keyHint(in: item.song)
        state.estimatedRoot = ScoreChordText.likelyRoot(of: symbols)
        state.writtenKey = hint?.written
        state.scoreRoot = hint?.root ?? state.estimatedRoot
        state.defaultShift = state.scoreRoot.flatMap { ScoreRecognition.shift(fromRoot: $0, toKey: item.teamKey) }
        // A shift the reader chose on this device wins over the default.
        state.shift = Self.savedShift(for: item.id) ?? state.defaultShift ?? 0
        state.isReady = true
        states[item.id] = state
        Self.cache[item.id] = state
        recordKey(item)
    }

    /// The key the chart is now in, for the 예배표 to show beside the song.
    private func recordKey(_ item: ScoreStandItem) {
        guard var state = states[item.id], state.scoreRoot != nil else { return }
        // The key it is played in, even while 원본 is being looked at.
        state.showsOriginal = false
        ScoreKeyStore.set(Self.keyName(state), for: item.attachment.fileId)
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
        recordKey(item)
    }

    func resetToTeamKey(_ item: ScoreStandItem) {
        update(item) { state in
            state.shift = state.defaultShift ?? 0
            state.showsOriginal = false
        }
        Self.saveShift(nil, for: item.id)
        recordKey(item)
    }

    func toggleFlats(_ item: ScoreStandItem) {
        // First press: the other spelling. Second: back to the key's own.
        update(item) { state in
            state.flatsOverride = state.flatsOverride == nil ? !state.useFlats : nil
        }
        recordKey(item)
    }

    func toggleOriginal(_ item: ScoreStandItem) {
        update(item) { $0.showsOriginal.toggle() }
    }

    // MARK: Editing by hand

    func move(_ item: ScoreStandItem, page: Int, chord: UUID, to offset: CGSize) {
        edit(item, page: page, chord: chord) { $0.offset.width += offset.width; $0.offset.height += offset.height }
    }

    func remove(_ item: ScoreStandItem, page: Int, chord: UUID) {
        update(item) { state in
            guard state.pages.indices.contains(page) else { return }
            state.pages[page].chords.removeAll { $0.id == chord }
            state.isEdited = true
        }
        saveEdits(item)
    }

    /// The chord as the reader sees it now — the key on screen.
    func displayed(_ chord: UUID, page: Int, in item: ScoreStandItem) -> String? {
        guard let state = states[item.id], state.pages.indices.contains(page),
              let found = state.pages[page].chords.first(where: { $0.id == chord }) else { return nil }
        let shift = state.showsOriginal ? 0 : state.shift
        return ScoreTransposer.symbol(found.original, by: shift, useFlats: state.useFlats) ?? found.original
    }

    /// Corrects a chord, or adds one at a point. The text is in the key on
    /// screen and is stored in the score's own key, so changing the
    /// transposition later moves it with the rest. Returns a message when
    /// the text is not a chord.
    func write(_ text: String, _ item: ScoreStandItem, page: Int,
               chord: UUID?, at point: CGPoint) -> String? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard let state = states[item.id], ScoreChordText.parse(typed) != nil else {
            return "「\(typed)」은 코드로 읽을 수 없습니다. 예: G, D/F#, Em7, Bbsus4"
        }
        let shift = state.showsOriginal ? 0 : state.shift
        let original = ScoreChordText.transpose(text: typed, by: -shift) ?? typed
        if let chord {
            edit(item, page: page, chord: chord) { $0.original = original }
        } else {
            update(item) { state in
                guard state.pages.indices.contains(page) else { return }
                let h = state.pages[page].chordHeight
                // Centred where the finger was, a typical chord wide.
                let box = CGRect(x: point.x - h, y: point.y - h / 2, width: h * 2, height: h)
                state.pages[page].chords.append(ScoreChord(original: original, box: box, userAdded: true))
                state.isEdited = true
            }
            saveEdits(item)
        }
        return nil
    }

    /// Forgets every hand edit and reads the chart again.
    func resetEdits(_ item: ScoreStandItem) async {
        ScoreEditStore.remove(item.id)
        Self.cache[item.id] = nil
        states[item.id] = nil
        await load(item)
    }

    private func edit(_ item: ScoreStandItem, page: Int, chord: UUID, _ change: (inout ScoreChord) -> Void) {
        update(item) { state in
            guard state.pages.indices.contains(page),
                  let index = state.pages[page].chords.firstIndex(where: { $0.id == chord }) else { return }
            change(&state.pages[page].chords[index])
            state.isEdited = true
        }
        saveEdits(item)
    }

    private func saveEdits(_ item: ScoreStandItem) {
        guard let state = states[item.id] else { return }
        ScoreEditStore.save(state.pages.map(\.chords), edited: true, for: item.id)
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
        let scale = chordScale
        return await Task.detached(priority: .userInitiated) {
            ScoreTransposer.transposed(pages: pages, by: shift, useFlats: flats, scale: scale)
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

    /// Every song in the set, each in the key it is shown in, as ONE PDF
    /// in 순서 order — for printing the whole 콘티, or sending it ahead.
    ///
    /// A song not opened yet is read first, so this can take a few seconds
    /// a song on a set nobody has paged through. A song whose file cannot
    /// be read is left out and named, rather than failing the whole file.
    func exportSet(_ items: [ScoreStandItem], title: String?) async {
        isExporting = true
        defer { isExporting = false }
        let combined = PDFDocument()
        var skipped: [String] = []
        for item in items {
            await load(item)
            // Another load of the same song may be running — the one the
            // stand started for the page on screen. Wait for it.
            var waited = 0
            while states[item.id]?.isReady != true, states[item.id]?.failure == nil, waited < 600 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard let data = await pdf(item), let document = PDFDocument(data: data) else {
                skipped.append(item.song.isEmpty ? item.attachment.name : item.song)
                continue
            }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { combined.insert(page, at: combined.pageCount) }
            }
        }
        guard combined.pageCount > 0, let data = combined.dataRepresentation() else {
            note = "PDF를 만들지 못했습니다."
            return
        }
        let base = (title?.isEmpty == false ? title! : "콘티").replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base) 악보.pdf")
        do {
            try data.write(to: url, options: .atomic)
            if skipped.isEmpty {
                export = ExportFile(url: url)
            } else {
                // An alert and the share sheet cannot both be up: say what
                // is missing first, and share when it is dismissed.
                pendingExport = ExportFile(url: url)
                note = "열 수 없는 악보는 빠졌습니다: \(skipped.joined(separator: ", "))"
            }
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

    /// The key the chart is shown in now, written the way a player reads
    /// it: 「A♭」, not 「Ab」.
    static func keyName(_ state: State) -> String? {
        guard let root = state.targetRoot else { return nil }
        let name = Self.name(root, flats: state.useFlats)
        guard name.count == 2 else { return name }
        return String(name.prefix(1)) + (name.hasSuffix("b") ? "♭" : "♯")
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

/// A chart's chords as last read or corrected, kept on this device per
/// attachment — so a chart opens without being read again, and a chart
/// corrected once stays corrected.
enum ScoreEditStore {
    struct Saved: Codable {
        var pages: [[ScoreChord]]
        /// Changed by hand, as opposed to only recognised.
        var edited: Bool
        /// ScoreRecognition.version that read it; nil before versions.
        var version: Int?
    }

    private static var folder: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("ScoreEdits", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func file(_ id: String, in folder: URL?) -> URL? {
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return folder?.appendingPathComponent(safe + ".json")
    }

    static func load(_ id: String) -> Saved? {
        guard let url = file(id, in: folder), let data = try? Data(contentsOf: url) else { return nil }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) { return saved }
        // The first format held only hand-edited pages.
        return (try? JSONDecoder().decode([[ScoreChord]].self, from: data)).map { Saved(pages: $0, edited: true, version: nil) }
    }

    static func save(_ pages: [[ScoreChord]], edited: Bool, for id: String) {
        guard let url = file(id, in: folder),
              let data = try? JSONEncoder().encode(Saved(pages: pages, edited: edited,
                                                         version: ScoreRecognition.version)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(_ id: String) {
        if let url = file(id, in: folder) { try? FileManager.default.removeItem(at: url) }
    }
}

/// The chart files themselves, in Caches: the system may clear them when
/// space is short, which costs only a download.
enum ScoreFileCache {
    private static var folder: URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("Scores", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func load(_ id: String) -> Data? {
        ScoreEditStore.file(id, in: folder).flatMap { try? Data(contentsOf: $0) }
    }

    static func save(_ data: Data, for id: String) {
        guard let url = ScoreEditStore.file(id, in: folder) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The key each chart was last shown in, by Drive file id, for the 예배표.
enum ScoreKeyStore {
    private static let key = "score.keys"

    static func key(for fileId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[fileId]
    }

    static func set(_ value: String?, for fileId: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[fileId] = value
        UserDefaults.standard.set(all, forKey: key)
    }
}
