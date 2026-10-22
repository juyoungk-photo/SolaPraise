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
import Combine
import Photos
import UIKit
import PDFKit

struct ScoreStandItem: Identifiable, Hashable {
    let attachment: Attachment
    let song: String
    /// The key in the 순서, as the leader typed it. Nil when unset.
    let teamKey: String?
    /// Some pages of the file only — one song's pages of a 콘티 file. Nil
    /// for the whole file.
    var pages: [Int]? = nil
    /// How this version is named in the stand's version menu.
    var versionLabel: String? = nil
    /// From an earlier service — the chart the song was last played from,
    /// offered when this service has none. Shown as such, and never taken
    /// off from here: it belongs to that service.
    var earlierDay: Date? = nil

    /// The file and the pages: one 콘티 file is several songs on the stand,
    /// each read, transposed and corrected on its own.
    var id: String {
        pages.map { "\(attachment.id)#\($0.map(String.init).joined(separator: ","))" } ?? attachment.id
    }
}

struct ScoreStandView: View {
    /// The set as it stands: each song's chosen version.
    @State private var items: [ScoreStandItem]
    /// Every version of each song, newest first — chosen from in the header.
    /// State: a version taken off here leaves the chips at once.
    @State private var versions: [String: [ScoreStandItem]]
    /// The service whose 콘티 the versions are chosen for (ContiChoice).
    /// Nil where there is no 콘티 to put a version in.
    var contiScope: String?
    /// Takes a version off the song — its attachment — returning an error
    /// message, or nil. Nil where versions cannot be taken off here.
    var removeVersion: ((ScoreStandItem) async -> String?)?
    /// Shares a version chosen for the 콘티 with the team (the sheet's 콘티
    /// column); nil where there is no sheet to share it on.
    var shareChoice: ((ScoreStandItem) async -> String?)?
    /// Puts a new 콘티 made here up for the team (TeamStore.uploadConti),
    /// returning what happened in words; nil where it cannot be put up.
    var uploadSet: ((Data, String) async -> String)?
    /// Redrawn when a version is chosen for the 콘티 (kept in defaults).
    @State private var choiceTick = 0
    @State private var removing: ScoreStandItem?
    /// A spot on the page being read for a chord, and whether it found one.
    @State private var probing = false
    @State private var probeFound = false
    /// The file name for the whole set made into one PDF: the next 콘티
    /// version's, 「20261018 주일예배 찬양 v3」.
    var setFileName: String?
    /// Make that file as soon as the stand opens — from 「새 콘티 버전 만들기」.
    var exportOnOpen = false
    /// Each song's corner line on the whole-set PDF, by song as written:
    /// 「2026/10/18 주일2부 - 1. 곡」 (ContiCaption).
    var setCaptions: [String: String] = [:]
    /// What a song's chart carries besides — the 헌금송's prayer and call —
    /// by song as written: shown above its page, and printed with it.
    var notices: [String: String] = [:]
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
    @EnvironmentObject private var team: TeamStore
    @Environment(\.openURL) private var openFile
    /// Edit mode: drag a chord, tap it to correct or remove it, press and
    /// hold on the page to add one recognition missed.
    @State private var editing = false
    /// The page alone: header, buttons and ✕ out of the way. A one-page
    /// chart on iPad lost its last staff and lyrics under the buttons. A tap
    /// on the page toggles it; editing brings everything back, since a tap
    /// there belongs to the chords.
    @State private var fullPage = false
    private var showsChrome: Bool { !fullPage || editing }
    /// How far apart the 코드표's lyrics sit, apart from their size.
    @AppStorage("score.chartSpacing") private var chartSpacing: Double = 1.35
    static let spacings: [(title: String, value: Double)] = [
        ("촘촘", 0.85), ("기본", 1.0), ("넓게", 1.35), ("아주 넓게", 1.7)
    ]
    /// The pinch in progress on the 코드표, as a factor of its size.
    @GestureState private var pinch: CGFloat = 1
    /// 코드표: the page read as bars of chords and lyrics, instead of the
    /// page itself. Remembered on this device.
    @AppStorage("score.showsChart") private var showsChart = false
    @State private var chordAction: ChordAction?
    @State private var entry: ChordEntry?
    /// A 코드표 line being corrected.
    @State private var editingLyrics: LyricLine?
    struct LyricLine: Identifiable {
        let item: ScoreStandItem
        let index: Int
        let chord: (UUID) -> String?
        let id = UUID()
    }
    @State private var choosingPage = false
    /// 가사 확인 open, for the song on the stand.
    @State private var checkingLyrics: ScoreStandItem?
    @State private var confirmingReread = false
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
        /// The page as printed round the chord, to check the reading by eye.
        var original: UIImage? = nil
        let id = UUID()
    }

    init(items: [ScoreStandItem], startAt: Int = 0, setTitle: String? = nil,
         versions: [String: [ScoreStandItem]] = [:], setFileName: String? = nil, exportOnOpen: Bool = false,
         setCaptions: [String: String] = [:],
         notices: [String: String] = [:],
         contiScope: String? = nil,
         removeVersion: ((ScoreStandItem) async -> String?)? = nil,
         shareChoice: ((ScoreStandItem) async -> String?)? = nil,
         uploadSet: ((Data, String) async -> String)? = nil,
         uploadTransposed: ((ScoreStandItem, Data, String) async -> String?)? = nil,
         transport: PlayerCoordinator? = nil) {
        self.transport = transport
        _items = State(initialValue: items)
        _versions = State(initialValue: versions)
        self.contiScope = contiScope
        self.removeVersion = removeVersion
        self.shareChoice = shareChoice
        self.uploadSet = uploadSet
        self.setFileName = setFileName
        self.exportOnOpen = exportOnOpen
        self.setCaptions = setCaptions
        self.notices = notices
        self.setTitle = setTitle
        self.uploadTransposed = uploadTransposed
        _index = State(initialValue: max(0, min(startAt, items.count - 1)))
    }

    /// The player, when one is playing: its 연습 controls ride on the chart
    /// (PracticeControls), since the video is under the stand.
    let transport: PlayerCoordinator?

    private var item: ScoreStandItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    // In two: the whole chain as one expression was more than the type
    // checker would take.
    var body: some View {
        editPresentations(stand)
    }

    /// What editing presents over the stand: taking a version off, a 코드표
    /// line's lyrics, a chord typed or turned to.
    private func editPresentations<Content: View>(_ content: Content) -> some View {
        content
        .confirmationDialog("이 악보를 지울까요?", isPresented: Binding(get: { removing != nil },
                                                                     set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { version in
            Button("지우기", role: .destructive) { Task { await remove(version) } }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("팀 시트의 첨부에서 빠지고, 이 계정이 올린 파일이면 드라이브에서도 지워집니다. 되돌릴 수 없습니다.")
        }
        .sheet(item: $editingLyrics) { line in
            if let systems = model.charts[line.item.id], systems.indices.contains(line.index) {
                LyricEditSheet(line: systems[line.index], chord: line.chord,
                               onSave: { edited in
                                   model.fixLyrics(line.item, line: line.index, edited: edited)
                                   editingLyrics = nil
                               },
                               onCancel: { editingLyrics = nil })
            }
        }
        .sheet(item: $checkingLyrics) { item in
            LyricCheckSheet(systems: model.charts[item.id] ?? [], song: item.song)
        }
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
        // Presented by UIKit from the top, not as a `.sheet`: from a stand
        // opened in 작업실 the sheet never appeared. See SharePresenter.
        .onChange(of: model.export?.id) { _, id in
            guard id != nil, let file = model.export else { return }
            SharePresenter.present(file.url) { model.export = nil }
        }
        .confirmationDialog("코드", isPresented: .constant(chordAction != nil),
                            titleVisibility: .hidden, presenting: chordAction) { action in
            Button("코드 고치기") {
                let shown = item.map { model.displayed(action.chord, page: action.page, in: $0) } ?? ""
                let place = item.flatMap { model.states[$0.id]?.pages[action.page].chords.first { $0.id == action.chord } }
                    .map { CGPoint(x: $0.placed.midX, y: $0.placed.midY) } ?? .zero
                entry = ChordEntry(page: action.page, chord: action.chord, point: place, text: shown ?? "",
                                   original: item.flatMap { model.originalPatch($0, page: action.page, chord: action.chord) })
                chordAction = nil
            }
            Button("이 코드 지우기", role: .destructive) {
                if let item { model.remove(item, page: action.page, chord: action.chord) }
                chordAction = nil
            }
            Button("취소", role: .cancel) { chordAction = nil }
        } message: { _ in
            Text("코드가 아닌 글자를 잘못 읽었다면 지우세요. 지우면 원래 인쇄된 글자가 그대로 보이고, 편집 중에는 점선 상자로 남아 누르면 되살아납니다.")
        }
        .confirmationDialog("코드를 다시 읽을까요?", isPresented: $confirmingReread, titleVisibility: .visible) {
            Button("다시 읽기 — 손으로 고친 것은 지워집니다", role: .destructive) {
                if let item { Task { await model.resetEdits(item) } }
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("어느 쪽에 넣을까요?", isPresented: $choosingPage, titleVisibility: .visible) {
            ForEach(0..<(item.flatMap { model.states[$0.id]?.pages.count } ?? 0), id: \.self) { page in
                Button("\(page + 1)쪽") {
                    entry = ChordEntry(page: page, chord: nil, point: Self.addPoint, text: "")
                }
            }
            Button("취소", role: .cancel) {}
        }
        // A sheet, not an alert: the chord typed, or turned to on wheels.
        // On iPad a popover at the chord instead (ScorePageView), narrow,
        // the page still in view beside it.
        .sheet(isPresented: Binding(get: { entry != nil && sizeClass != .regular },
                                    set: { if !$0 { entry = nil } })) {
            if let current = entry { chordEntryView(current) }
        }
    }

    /// 코드 추가 / 코드 고치기 for an entry — as a sheet on a phone, a
    /// popover on iPad.
    private func chordEntryView(_ current: ChordEntry) -> some View {
        ChordEntrySheet(
            title: current.chord == nil ? "코드 추가" : "코드 고치기",
            original: current.original,
            message: current.chord != nil
                ? "지금 화면에 보이는 키로 고르거나 적으세요."
                : current.point != Self.addPoint
                    ? (probeFound ? "그 자리에서 읽은 코드입니다. 맞으면 저장하고, 아니면 고치세요."
                                  : "그 자리에서 코드를 읽지 못했습니다. 고르거나 적으면 그 자리에 놓입니다.")
                    : "지금 화면에 보이는 키로 고르거나 적으세요. 페이지 위쪽에 놓이니, 끌어서 제자리로 옮기세요.",
            initial: current.text,
            startRoot: item.flatMap(shownKey),
            compact: sizeClass == .regular,
            onSave: { text in
                if let item, let failure = model.write(text, item, page: current.page,
                                                       chord: current.chord, at: current.point) {
                    model.note = failure
                }
                entry = nil
            },
            onCancel: { entry = nil })
    }

    private var stand: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let item {
                VStack(spacing: 0) {
                    if showsChrome { header(item).transition(.move(edge: .top).combined(with: .opacity)) }
                    songPager
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !editing else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { fullPage.toggle() }
                        }
                        .accessibilityAction(named: fullPage ? "메뉴 보이기" : "악보만 크게 보기") {
                            fullPage.toggle()
                        }
                    if showsChrome, let transport {
                        PracticeControls(coordinator: transport, withTransport: true)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.white)
                            .font(.caption)
                            .padding(.vertical, 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if showsChrome { controls(item).transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                .foregroundStyle(.white)
                .task(id: item.id) { await model.load(item) }
                .task {
                    // 「새 콘티 버전 만들기」: the set as chosen, made into one file.
                    if exportOnOpen { await model.exportSet(contiItems, title: setTitle, fileName: setFileName, captions: setCaptions, notices: notices, upload: uploadSet) }
                }
                #if DEBUG
                .task {
                    if DebugHarness.exportScoreSet { await model.exportSet(contiItems, title: setTitle, fileName: setFileName, captions: setCaptions, notices: notices, upload: uploadSet) }
                }
                #endif
            }

            if showsChrome {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(14)
                }
                .accessibilityLabel("닫기")
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        // Same rule as the chord stand: a set runs forty minutes and
        // nobody touches the screen. It must not sleep mid-song.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.team = team
            model.nearbyName = team.lastActingEmail.flatMap { team.rosterName(for: $0) } ?? UIDevice.current.name
            model.joinRoom(items: items, team: TeamSheetSource.current)
        }
        // The team's corrections, as they are made, while this is open.
        .task { await model.watchTeam() }
        #if DEBUG
        // -uiTestRehearsalEdit: take the first chord off, as a hand would,
        // once the room has had time to connect — to watch it leave the
        // other simulator's stand.
        .task {
            guard DebugHarness.args.contains("-uiTestRehearsalEdit"), let item else { return }
            try? await Task.sleep(for: .seconds(15))
            await model.ensureRead(item)
            if let first = model.states[item.id]?.pages.first?.chords.first {
                print("[Rehearsal] removing \(first.original) — peers: \(RehearsalLink.shared.peers)")
                model.remove(item, page: 0, chord: first.id)
            }
        }
        #endif
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.leaveRoom()
            // Corrections waiting to be shared go now, not lost with the stand.
            model.shareNow()
        }
        .focusable()
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        #if DEBUG
        .onChange(of: item.flatMap { model.charts[$0.id]?.isEmpty == false } ?? false) { _, ready in
            if ready, DebugHarness.lyricCheckVideo != nil, checkingLyrics == nil { checkingLyrics = item }
        }
        #endif
    }

    /// A spot pressed while editing: read for a chord, and offered to add
    /// there — as read, or empty to type when nothing could be made out.
    private func probe(_ item: ScoreStandItem, page: Int, at point: CGPoint) {
        guard !probing else { return }
        probing = true
        Task {
            let found = await model.readChord(item, page: page, at: point)
            probing = false
            probeFound = found != nil
            entry = ChordEntry(page: page, chord: nil, point: found?.center ?? point, text: found?.text ?? "",
                               original: model.originalPatch(item, page: page, around: found?.center ?? point))
        }
    }

    /// A notice for the song — its first line the heading — on the stand
    /// as it is on the printed chart.
    private func noticeCard(_ notice: String) -> some View {
        let lines = notice.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 6) {
            Label(lines.first ?? "", systemImage: (lines.first ?? "").hasPrefix("헌금송") ? "gift" : "note.text")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            if lines.count > 1 {
                Text(lines.dropFirst().joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
    }

    /// The key the page is showing: the printed one under 원본, else the
    /// one it has been moved to.
    private func shownKey(_ item: ScoreStandItem) -> String? {
        guard let state = model.states[item.id],
              let root = state.showsOriginal ? state.scoreRoot : state.targetRoot else { return nil }
        return ScoreStandModel.name(root, flats: state.useFlats)
    }

    // MARK: - Header

    /// The song's versions — each 콘티's pages, each chart attached — side
    /// by side, newest first, one tap to turn to. They were behind a menu,
    /// and a song with two charts read as a song with one. The choice is
    /// the set's: it goes into the next 콘티 made from here.
    @ViewBuilder
    private func versionChips(_ item: ScoreStandItem) -> some View {
        if let options = versions[item.song], options.count > 1 {
            let _ = choiceTick
            let names = VersionChips.names(options.map { option in
                VersionChips.Version(label: option.versionLabel ?? option.attachment.name,
                                     key: model.chartKeyName(option),
                                     by: option.attachment.addedBy.isEmpty ? nil
                                        : team.rosterName(for: option.attachment.addedBy),
                                     note: option.earlierDay.map { "지난 " + $0.formatted(.dateTime.month(.defaultDigits).day()) })
            }, songs: [item.song, PlanSongTitle.split(item.song).title])
            let inConti = contiScope.flatMap { ContiChoice.pick(options, scope: $0, song: item.song)?.id }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                        let selected = option.id == item.id
                        Button {
                            guard !selected, let at = items.firstIndex(where: { $0.id == item.id }) else { return }
                            items[at] = option
                            Task { await model.load(option) }
                        } label: {
                            HStack(spacing: 4) {
                                // The one the 콘티 takes, marked on its chip:
                                // looking at another changes nothing.
                                if option.id == inConti {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                                }
                                Text(names[offset])
                                if offset == 0 {
                                    Text("최신").font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.white.opacity(selected ? 0.25 : 0.15)))
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.12)))
                            .foregroundStyle(selected ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((option.versionLabel ?? option.attachment.name)
                                            + (offset == 0 ? ", 최신" : "") + (option.id == inConti ? ", 콘티에 들어감" : ""))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }

                    // For the version on screen: put it in the 콘티, or take
                    // it off the song — compare, keep one, and that is it.
                    if let contiScope {
                        if item.id == inConti {
                            Label("콘티에 들어감", systemImage: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.leading, 6)
                        } else {
                            Button {
                                ContiChoice.choose(item.id, scope: contiScope, song: item.song)
                                // Marked for the team, so every member's 콘티 —
                                // and the sheet — takes the same one.
                                // Marked here at once; the sheet says when it
                                // has it (Toast.sheet).
                                markChosen(item)
                                if let shareChoice {
                                    Task {
                                        let failure = await shareChoice(item)
                                        if let failure { model.note = failure }
                                        Toast.shared.sheet(failure,
                                                           saved: "「\(PlanSongTitle.split(item.song).title)」 콘티 버전 — 시트에 저장됨")
                                    }
                                }
                                choiceTick += 1
                            } label: {
                                Label("콘티에 넣기", systemImage: "checkmark.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 6)
                        }
                    }
                    // A song's own chart only: a 콘티's pages are the 콘티
                    // file's, taken off from its own menu.
                    if removeVersion != nil, item.pages == nil, !item.attachment.belongsToService, item.earlierDay == nil {
                        Button { removing = item } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("이 버전 지우기")
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// The stand's own copies of the song's versions marked as the sheet now
    /// has them: the chosen one ✓, the others not.
    private func markChosen(_ item: ScoreStandItem) {
        guard var list = versions[item.song] else { return }
        let chosen = item.pages == nil && item.earlierDay == nil ? item.attachment.fileId : nil
        for index in list.indices where list[index].pages == nil && list[index].earlierDay == nil {
            var attachment = list[index].attachment
            attachment.chosenForConti = attachment.fileId == chosen
            list[index] = ScoreStandItem(attachment: attachment, song: list[index].song, teamKey: list[index].teamKey,
                                         pages: list[index].pages, versionLabel: list[index].versionLabel)
        }
        versions[item.song] = list
        if let at = items.firstIndex(where: { $0.song == item.song }),
           let updated = list.first(where: { $0.id == items[at].id }) { items[at] = updated }
        choiceTick += 1
    }

    /// The version on screen taken off its song; the stand moves to the
    /// version the 콘티 now takes.
    private func remove(_ version: ScoreStandItem) async {
        guard let removeVersion else { return }
        if let failure = await removeVersion(version) {
            model.note = failure
            return
        }
        var rest = versions[version.song] ?? []
        rest.removeAll { $0.id == version.id }
        versions[version.song] = rest
        if let contiScope, ContiChoice.chosen(scope: contiScope, song: version.song) == version.id {
            ContiChoice.choose(nil, scope: contiScope, song: version.song)
        }
        choiceTick += 1
        guard let at = items.firstIndex(where: { $0.id == version.id }) else { return }
        let next = contiScope.flatMap { ContiChoice.pick(rest, scope: $0, song: version.song) } ?? rest.first
        if let next {
            items[at] = next
            await model.load(next)
        } else {
            items.remove(at: at)
            if items.isEmpty { dismiss(); return }
            index = min(index, items.count - 1)
        }
    }

    /// The set as the 콘티 takes it: the 순서's songs only — those with a
    /// corner line — each in its chosen version, not whichever was last
    /// looked at. Charts of songs taken out of the 순서, and an old 콘티's
    /// leftover pages, went into new 콘티s too.
    private var contiItems: [ScoreStandItem] {
        let songs = setCaptions.isEmpty ? items : items.filter { setCaptions[$0.song] != nil }
        guard let contiScope else { return songs }
        return songs.map { item in
            versions[item.song].flatMap { ContiChoice.pick($0, scope: contiScope, song: item.song) } ?? item
        }
    }

    private func header(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // The song, not the video's title it was entered under.
                Text(item.song.isEmpty ? item.attachment.name : PlanSongTitle.split(item.song).title)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if items.count > 1 {
                    Text("\(index + 1)/\(items.count)")
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        // Never broken over lines: 「1/」 above 「3」 read as nothing.
                        .fixedSize()
                }
                Spacer(minLength: 0)
                NearbyBadge(inRow: true)
                // The file itself, in Drive: to check what was uploaded.
                if !item.attachment.fileId.hasPrefix("local-") {
                    Button { openFile(item.attachment.url) } label: {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 30)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel("원본 파일 열기")
                }
                // Not while editing: 편집 works on 악보 only. Hidden, not
                // removed, so the line keeps its height and the page its place.
                Picker("보기", selection: $showsChart) {
                    Text("악보").tag(false)
                    Text("코드표").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                // The stand is dark on every device; a segmented control
                // takes its look from the environment, and on iPad it
                // came out light with 「악보」 unreadable.
                .environment(\.colorScheme, .dark)
                .opacity(editing ? 0 : 1)
                .allowsHitTesting(!editing)
            }
            // Both states laid over each other, in the same space: entering
            // 편집 must not move the page — a chord is checked against the
            // page as it was, at the same place. The taller sets the height.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    NearbyBadge(inRow: false)
                    // Shown from the start, before the page has loaded: which
                    // version to look at is the first choice, not the last.
                    versionChips(item)
                    // Borrowed from an earlier service: said, so nobody takes it
                    // for a chart put up this week.
                    if let day = item.earlierDay {
                        Label("지난 \(day.formatted(.dateTime.month(.defaultDigits).day())) 예배에서 쓴 악보 — 이번 예배에는 아직 올린 악보가 없습니다",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(2)
                    }
                    if let state, state.isReady {
                        // What was read off the page, against what is sung.
                        if showsChart, let systems = model.charts[item.id], !systems.isEmpty {
                            Button { checkingLyrics = item } label: {
                                Label("가사 확인", systemImage: "text.badge.checkmark")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        Text(keyLine(item, state))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2, reservesSpace: true)
                    }
                }
                .opacity(editing ? 0 : 1)
                .allowsHitTesting(!editing)
                .accessibilityHidden(editing)

                if editing {
                    VStack(alignment: .leading, spacing: 4) {
                        // Both lines laid over each other, two lines kept:
                        // 원본 on and off must not move the page either.
                        let printed = state?.showsOriginal == true
                        ZStack(alignment: .topLeading) {
                            Text("코드를 끌어서 옮기고, 눌러서 고치거나 지우세요. 빠진 코드는 그 자리를 누르면 읽어 봅니다 — 「+ 코드」로 넣어도 됩니다. 지운 코드는 점선 상자를 누르면 되살아납니다. 「원본」으로 인쇄된 악보와 비교하세요. 페이지는 두 손가락으로 넘깁니다.")
                                .foregroundStyle(Color.accentColor)
                                .opacity(printed ? 0 : 1)
                            Text("원본을 보는 중 — 편집은 멈춥니다. 「원본」을 다시 누르면 이어서 편집합니다.")
                                .foregroundStyle(.orange)
                                .opacity(printed ? 1 : 0)
                        }
                        .font(.footnote)
                        .lineLimit(2, reservesSpace: true)
                        rereadButton(item)
                            .opacity(printed ? 0.3 : 1)
                            .disabled(printed)
                    }
                }
            }
            if let status = model.shareStatus[item.id] {
                Label(status, systemImage: status.contains("이 기기에만") || status.contains("못했")
                      ? "exclamationmark.icloud" : "person.2")
                    .font(.caption)
                    .foregroundStyle(status.contains("이 기기에만") || status.contains("못했")
                                     ? Color.orange : Color.accentColor)
                    .lineLimit(1)
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
        if state.isReading { return "코드를 읽는 중…" }
        guard state.isRead else {
            return "악보 그대로 보는 중 — 키를 바꾸거나 코드표·편집을 열면 코드를 읽습니다."
                + (item.teamKey.map { " (순서의 키 \($0))" } ?? "")
        }
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
        } else if item.teamKey == nil, !item.attachment.fileId.hasPrefix("local-") {
            // Only for a team chart: one from 작업실 has no 순서 to have a key.
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
                    // The 헌금송's prayer and call, read before the song.
                    if let notice = notices[item.song], !editing {
                        noticeCard(notice)
                    }
                    ForEach(Array(state.pages.enumerated()), id: \.offset) { pageIndex, page in
                        ScorePageView(
                            page: page,
                            shift: state.showsOriginal ? 0 : state.shift,
                            useFlats: state.useFlats,
                            scale: model.chordScale,
                            // 원본 while editing is a check: the page as
                            // printed, nothing drawn or editable on it.
                            original: state.showsOriginal,
                            editing: editing,
                            removed: editing ? model.removedChords(item, page: pageIndex) : [],
                            onMove: { id, offset in model.move(item, page: pageIndex, chord: id, to: offset) },
                            onTapChord: { id in chordAction = ChordAction(page: pageIndex, chord: id) },
                            onRestore: { id in model.restore(item, page: pageIndex, chord: id) },
                            onTapPage: { point in probe(item, page: pageIndex, at: point) },
                            popoverAt: sizeClass == .regular && entry?.page == pageIndex ? entry?.point : nil,
                            popover: { entry.map { AnyView(chordEntryView($0)) } ?? AnyView(EmptyView()) },
                            onPopoverDismiss: { entry = nil })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                // While editing, one finger moves a chord and two scroll
                // the page. Scrolling used to be off altogether, and a
                // chart taller than the screen could not be edited below
                // the fold; with one-finger scrolling, a drag that missed a
                // chord by a little moved the page instead.
                .background(ScrollTouches(minimum: editing ? 2 : 1))
            }
            // Reading the chords takes seconds a page: said over the page,
            // where the eye is, not in a line at the top.
            .overlay {
                if state.isReading || probing {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("코드를 읽는 중…").font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state.isReading || probing)
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
                Text("악보를 여는 중…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Songs side by side

    /// Swipe left or right for the next or previous song.
    ///
    /// A real pager, not a drag gesture on the page: the drag sat inside
    /// the page's own vertical scroll, which took the touch first, so the
    /// swipe worked only now and then. Each song is a page of its own; the
    /// next is read while the current one is on the stand, so turning to it
    /// is immediate. While editing there is one song and no pager — a
    /// sideways drag there moves a chord.
    @ViewBuilder
    private var songPager: some View {
        if editing || items.count < 2, let item {
            songContent(item)
        } else {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { position, song in
                    songContent(song)
                        .task { await model.load(song) }
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .task(id: "\(index)|\(showsChart)") {
                // The next song read ahead, so the swipe lands on it ready —
                // its 코드표 too, when that is what is showing.
                guard items.indices.contains(index + 1) else { return }
                await model.load(items[index + 1])
                if showsChart { await model.loadChart(items[index + 1]) }
            }
        }
    }

    @ViewBuilder
    private func songContent(_ song: ScoreStandItem) -> some View {
        if showsChart && !editing {
            chart(song)
                .task(id: chartKey(song)) {
                    guard showsChart else { return }
                    await model.ensureRead(song)
                    await model.loadChart(song)
                }
        } else {
            pages(song)
        }
    }

    // MARK: - 코드표

    /// Reloads when the song changes, when 코드표 is chosen, and after a hand
    /// edit has thrown the old reading away.
    private func chartKey(_ item: ScoreStandItem) -> String {
        "\(item.id)|\(showsChart)|\(model.states[item.id]?.isReady == true)|\(model.charts[item.id] == nil)"
    }

    @ViewBuilder
    private func chart(_ item: ScoreStandItem) -> some View {
        if let systems = model.charts[item.id], let state = model.states[item.id] {
            if systems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list").font(.largeTitle)
                    Text("오선을 찾지 못해 코드표를 만들 수 없습니다. 오선 없이 코드와 가사만 있는 악보는 「악보」로 보세요.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let originals = Dictionary(state.pages.flatMap(\.chords).map { ($0.id, $0.original) },
                                           uniquingKeysWith: { first, _ in first })
                let shift = state.showsOriginal ? 0 : state.shift
                let name: (UUID) -> String? = { id in
                    originals[id].map { ScoreTransposer.symbol($0, by: shift, useFlats: state.useFlats) ?? $0 }
                }
                ScoreChartView(systems: systems, chord: name,
                               scale: min(ScoreStandModel.chartScaleRange.upperBound,
                                          max(ScoreStandModel.chartScaleRange.lowerBound, model.chartScale * pinch)),
                               spacing: chartSpacing,
                               onEditLine: { index in
                                   editingLyrics = LyricLine(item: item, index: index, chord: name)
                               })
                // Two fingers size the 코드표 as they move, and the size is
                // kept when they lift — the A buttons step it, a pinch lands
                // anywhere between.
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, pinch, _ in pinch = value.magnification }
                        .onEnded { value in model.setChartScale(model.chartScale * value.magnification) }
                )
            }
        } else if let failure = model.states[item.id]?.failure {
            Text(failure)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("마디와 가사를 읽는 중…")
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
            // One line: 원본 centred on the bar, in 편집 and out — it stays
            // where the finger knows it. Room kept for it in the middle.
            HStack(spacing: 8) {
                keyGroup(item)
                if editing {
                    // Paused while the page is shown as printed.
                    editGroup(item).disabled(model.states[item.id]?.showsOriginal == true)
                }
                Spacer(minLength: 76)
                toolGroup(item)
                songNav()
            }
            .padding(.horizontal, 16)
            .overlay { originalButton(item) }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    keyGroup(item)
                    if editing {
                    // Paused while the page is shown as printed.
                    editGroup(item).disabled(model.states[item.id]?.showsOriginal == true)
                }
                    Spacer(minLength: 8)
                    if !editing || sizeClass == .regular { originalButton(item) }
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
        // Unread counts as ready: the first press reads the chords.
        let ready = state?.isReady == true && state?.isReading != true
            && (state?.isRead == false || (state?.chordCount ?? 0) > 0)
        Button { Task { await model.stepAsking(item, -1) } } label: { pill(Text("−")) }
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

        Button { Task { await model.stepAsking(item, 1) } } label: { pill(Text("+")) }
            .disabled(!ready)
            .accessibilityLabel("반음 올리기")

        Button { Task { await model.ensureRead(item); model.toggleFlats(item) } } label: {
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
        // Nothing is drawn over an unread page: it IS the original.
        let ready = state?.isReady == true && state?.isRead == true && (state?.chordCount ?? 0) > 0
        return Button { model.toggleOriginal(item) } label: {
            pill(Text("원본"), active: state?.showsOriginal == true, wide: true)
        }
        .disabled(!ready)
    }

    /// What editing adds, on the left beside the key — so 완료 stays where
    /// 편집 was and the finger that pressed one finds the other.
    @ViewBuilder
    private func editGroup(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        // Added near the top of the page, then dragged into place.
        Button {
            if (state?.pages.count ?? 0) > 1 { choosingPage = true }
            else { entry = ChordEntry(page: 0, chord: nil, point: Self.addPoint, text: "") }
        } label: {
            pill(Text("+ 코드").font(.system(size: 14, weight: .semibold)), wide: true)
        }
        .accessibilityLabel("빠진 코드 넣기")
        Button { model.undo(item) } label: {
            pill(Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .semibold)))
        }
        .disabled(!model.canUndo(item))
        .accessibilityLabel("되돌리기")
    }

    /// 다시 읽기, beside the editing hint: always offered while editing,
    /// not only after a hand edit — the reader improves, and a chart read by
    /// an older one can be read again — but rarely, so not in the row of
    /// buttons, which it pushed onto a second line on iPad, over the
    /// bottom staff. A chart corrected by hand asks first.
    private func rereadButton(_ item: ScoreStandItem) -> some View {
        Button {
            if model.states[item.id]?.isEdited == true { confirmingReread = true }
            else { Task { await model.resetEdits(item) } }
        } label: {
            // A button that looks like one: as a grey line of text it went
            // unseen, and 「how do I read it again?」 had no visible answer.
            Label("코드 다시 읽기", systemImage: "arrow.clockwise")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("코드를 처음부터 다시 인식")
    }

    @ViewBuilder
    private func toolGroup(_ item: ScoreStandItem) -> some View {
        let state = model.states[item.id]
        let ready = state?.isReady == true && (state?.chordCount ?? 0) > 0
        // Size, for what is on screen: the chords on the page — for charts
        // printed small; applies to the export too — or the 코드표, each
        // its own setting, remembered on this device.
        let smaller = showsChart ? model.chartScale <= 0.61 : model.chordScale <= 0.71
        let larger = showsChart ? model.chartScale >= 2.39 : model.chordScale >= 2.49
        Button {
            if showsChart { model.resizeChart(by: -0.05) } else { model.resize(by: -0.05) }
        } label: { pill(Text("A").font(.system(size: 13, weight: .bold))) }
            .disabled(!ready || smaller)
            .accessibilityLabel(showsChart ? "코드표 글자 작게" : "코드 글자 작게")
        Button {
            if showsChart { model.resizeChart(by: 0.05) } else { model.resize(by: 0.05) }
        } label: { pill(Text("A").font(.system(size: 21, weight: .bold))) }
            .disabled(!ready || larger)
            .accessibilityLabel(showsChart ? "코드표 글자 크게" : "코드 글자 크게")

        // On the 코드표, where 편집 does nothing, its place is the spacing:
        // the lyrics' room, apart from their size.
        if showsChart {
            Menu {
                Picker("간격", selection: $chartSpacing) {
                    ForEach(Self.spacings, id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            } label: {
                pill(Text("간격").font(.system(size: 15, weight: .semibold)), wide: true)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("가사 간격")
        } else {
            Button {
                if editing { editing = false } else { Task { await model.ensureRead(item); editing = true } }
            } label: {
                pill(Text(editing ? "완료" : "편집"), active: editing, wide: true)
            }
            .disabled(!(state?.isReady ?? false))
            .accessibilityLabel(editing ? "편집 끝내기" : "코드 위치·글자 편집")
        }

        // Not while editing — sharing an edit in progress is what 완료 then
        // 공유 is for — but their place is kept, so 완료 sits exactly where
        // 편집 did.
        Group {
        // One song, or the whole 콘티 as one file — to share, or keep in
        // Files: the share sheet offers both.
        let shareLabel = pill(model.isExporting ? AnyView(ProgressView().tint(.white))
                                                : AnyView(Image(systemName: "square.and.arrow.up")))
        // As it is on the stand — the key, every correction — kept where
        // the person wants it: Photos a page an image, Files a PDF.
        Menu {
            Section(item.song.isEmpty ? "현재 악보" : PlanSongTitle.split(item.song).title) {
                Button { Task { await model.saveToPhotos(item) } } label: {
                    Label("사진에 저장", systemImage: "photo.on.rectangle")
                }
                Button { Task { await model.saveToFiles(item, notice: notices[item.song]) } } label: {
                    Label("파일에 저장", systemImage: "folder")
                }
                Button { Task { await model.exportPDF(item, notice: notices[item.song]) } } label: {
                    Label("공유…", systemImage: "square.and.arrow.up")
                }
            }
            // The page as it is will do: unread, it is the chart as printed.
            .disabled(state?.isReady != true)
            if items.count > 1 {
                Button {
                    Task { await model.exportSet(contiItems, title: setTitle, fileName: setFileName, captions: setCaptions, notices: notices, upload: uploadSet) }
                } label: {
                    Label(setFileName.map { "새 콘티 \($0) — 지금 악보·키로" } ?? "콘티 전체 \(items.count)곡 — 한 파일로",
                          systemImage: "doc.on.doc")
                }
            }
        } label: { shareLabel }
        .menuOrder(.fixed)
        .disabled(model.isExporting)
        .accessibilityLabel("저장·공유")

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
        .opacity(editing ? 0 : 1)
        .allowsHitTesting(!editing)
        .accessibilityHidden(editing)
        // While editing, 원본 takes the place 공유 leaves: beside 완료, a
        // check to make often, and the row stays one line on iPad.
        // (On a phone. iPad keeps 원본 where it always is.)
        .overlay(alignment: .leading) {
            if editing && sizeClass != .regular { originalButton(item) }
        }

    }

    /// Previous and next song, side by side at the right edge.
    @ViewBuilder
    private func songNav() -> some View {
        // While editing there is one song on the stand and no pager; the
        // arrows keep their place, unseen, for the same reason as 공유.
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
            .opacity(editing ? 0 : 1)
            .allowsHitTesting(!editing)
            .accessibilityHidden(editing)
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

// MARK: - Two-finger scrolling

/// How many fingers the enclosing scroll view's pan needs. SwiftUI's
/// ScrollView has no such setting; its UIScrollView does.
private struct ScrollTouches: UIViewRepresentable {
    let minimum: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Found after layout: in makeUIView the view is not in the
        // hierarchy yet.
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            (ancestor as? UIScrollView)?.panGestureRecognizer.minimumNumberOfTouches = minimum
        }
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
    /// The page as printed: no chord drawn over it — not a transposed one,
    /// and not one corrected, moved or added by hand. 원본 used to mean
    /// "not transposed", and a chord added by hand still showed there.
    let original: Bool
    let editing: Bool
    /// Chords taken off by hand, shown faint while editing to put back.
    var removed: [ScoreChord] = []
    let onMove: (UUID, CGSize) -> Void
    let onTapChord: (UUID) -> Void
    var onRestore: (UUID) -> Void = { _ in }
    /// A tap on the page, off any chord, while editing — normalised.
    var onTapPage: (CGPoint) -> Void = { _ in }
    /// On iPad, 코드 추가 / 고치기 as a popover pointing at this spot.
    var popoverAt: CGPoint? = nil
    var popover: () -> AnyView = { AnyView(EmptyView()) }
    var onPopoverDismiss: () -> Void = {}

    /// The chord being dragged and how far, in view points.
    @State private var dragging: (id: UUID, by: CGSize)?

    var body: some View {
        Image(uiImage: page.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                if !original {
                GeometryReader { geo in
                    let size = geo.size
                    let labels = ScoreLayout.labels(
                        chords: page.chords, chordHeight: page.chordHeight, shift: shift,
                        useFlats: useFlats, scale: scale, alwaysDraw: editing, in: size)
                    ZStack(alignment: .topLeading) {
                        // The popover's anchor: the chord's spot on the page.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .popover(isPresented: Binding(get: { popoverAt != nil },
                                                          set: { if !$0 { onPopoverDismiss() } }),
                                     attachmentAnchor: .rect(.rect(CGRect(
                                        x: (popoverAt?.x ?? 0) * size.width - 14, y: (popoverAt?.y ?? 0) * size.height - 10,
                                        width: 28, height: 20))),
                                     // Below a chord in the top half of the
                                     // page, above one lower down: up there,
                                     // a popover above it ran off the screen.
                                     arrowEdge: (popoverAt?.y ?? 1) < 0.5 ? .top : .bottom) {
                                popover()
                                    .frame(width: 340, height: 560)
                                    .presentationCompactAdaptation(.popover)
                            }
                        // Under everything: the page itself, pressed where a
                        // chord was missed.
                        if editing {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: size.width, height: size.height)
                                .onTapGesture(coordinateSpace: .local) { location in
                                    onTapPage(CGPoint(x: location.x / size.width, y: location.y / size.height))
                                }
                        }
                        ForEach(ghosts(in: size)) { chord in
                            ghostView(chord, size: size)
                        }
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
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The chords taken off, less any a chord now on the page covers — one
    /// put back by 「+ 코드」 there needs no ghost beside it.
    private func ghosts(in size: CGSize) -> [ScoreChord] {
        removed.filter { gone in
            !page.chords.contains { chord in
                let overlap = chord.placed.intersection(gone.placed)
                return !overlap.isNull && overlap.width * overlap.height > gone.placed.width * gone.placed.height * 0.4
            }
        }
    }

    /// A chord taken off: a dashed box round where it was, with the
    /// printed chord showing through it — no text of its own, which would
    /// sit over the printed one, in another key once transposed. A tap
    /// puts it back.
    private func ghostView(_ chord: ScoreChord, size: CGSize) -> some View {
        let rect = CGRect(x: chord.placed.minX * size.width, y: chord.placed.minY * size.height,
                          width: chord.placed.width * size.width, height: chord.placed.height * size.height)
            .insetBy(dx: -2, dy: -2)
        return RoundedRectangle(cornerRadius: 3)
            .stroke(Color.gray, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: max(9, min(14, rect.height * 0.7))))
                    .foregroundStyle(.white, .gray)
                    .offset(x: 6, y: -6)
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle().inset(by: -max(0, (36 - rect.height) / 2)))
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { onRestore(chord.id) }
            .accessibilityLabel("지운 코드 \(ScoreTransposer.symbol(chord.original, by: shift, useFlats: useFlats) ?? chord.original) 되살리기")
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
        /// The chords have been read (or a reading was kept). Until then the
        /// page is shown as it is — reading is seconds a page, and asked for
        /// only when something needs it: a key change, 코드표, 편집.
        var isRead = false
        /// A reading under way, for the stand to say so.
        var isReading = false

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
        // Steps of 0.05: 0.1 jumped past the size wanted.
        chordScale = min(2.5, max(0.7, ((chordScale + step) * 20).rounded() / 20))
        UserDefaults.standard.set(Double(chordScale), forKey: "score.chordScale")
    }

    /// The 코드표's own size, apart from the chords on the page: they
    /// were one setting, and a chart printed with small chords — sized up
    /// on the page — turned the 코드표 into lyrics too large to sing from.
    @Published private(set) var chartScale: CGFloat =
        (UserDefaults.standard.object(forKey: "score.chartScale") as? Double).map { CGFloat($0) } ?? 1

    func resizeChart(by step: CGFloat) {
        setChartScale(((chartScale + step) * 20).rounded() / 20)
    }

    static let chartScaleRange: ClosedRange<CGFloat> = 0.6...2.4

    /// Any size in range — a pinch lands between the buttons' steps.
    func setChartScale(_ value: CGFloat) {
        chartScale = min(Self.chartScaleRange.upperBound, max(Self.chartScaleRange.lowerBound, value))
        UserDefaults.standard.set(Double(chartScale), forKey: "score.chartScale")
    }

    /// Read once per attachment per launch: recognition is seconds a page,
    /// and paging back to a song should not run it again.
    private static var cache: [String: State] = [:]

    func load(_ item: ScoreStandItem) async {
        knownItems[item.id] = item
        onScreen = item
        defer { readIfInRoom() }
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
        if let kept = ScoreFileCache.load(item.attachment.fileId) {
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
        removed[item.id] = ScoreRemovedStore.load(item.id)
        // The team's corrections, when someone has shared newer ones than
        // this copy holds and this device has none of its own unshared.
        // Not after 다시 읽기, which asked for the chart as read.
        let remoteId = team?.attachment(fileId: item.attachment.fileId)?.editsFileId ?? item.attachment.editsFileId
        if let remoteId, saved?.sharedFrom != remoteId, saved?.dirty != true, !rereading.contains(item.id),
           let file = await SharedEdits.fetch(remoteId),
           let pages = file.charts[SharedEdits.key(pages: item.pages)] {
            // Marked when the sender's app marks corrections: any chord
            // carrying the field at all.
            let marked = pages.joined().contains { $0.corrected != nil }
            let lyrics = file.lyrics?[SharedEdits.key(pages: item.pages)] ?? []
            let shared = ScoreEditStore.Saved(pages: pages, edited: true, version: ScoreRecognition.version,
                                              sharedFrom: remoteId, dirty: false,
                                              marksCorrections: marked ? true : nil,
                                              base: pages, lyricBase: lyrics)
            ScoreEditStore.write(shared, for: item.id)
            ScoreLyricFixStore.save(lyrics, for: item.id)
            saved = shared
            shareStatus[item.id] = "팀원이 고친 코드를 받았습니다"
        }
        if let old = saved, !old.edited, old.version != ScoreRecognition.version { saved = nil }
        // The pages only: what is shown at once. Chords come from a kept
        // reading, or are read when a key change, 코드표 or 편집 asks.
        guard var read = await ScoreTransposer.read(data: data, recognise: false, only: item.pages),
              !read.pages.isEmpty else {
            // Drive answers a file that is not shared by link with a
            // sign-in page, which is neither a PDF nor an image.
            states[item.id]?.failure = "이 파일은 악보로 열 수 없습니다. PDF나 이미지인지, 링크 공유가 켜져 있는지 확인하세요."
            return
        }

        // Only a real chart is kept: a sign-in page Drive sent in its place
        // has been rejected above and never reaches here.
        ScoreFileCache.save(data, for: item.attachment.fileId)

        var state = State()
        if let saved, saved.pages.count == read.pages.count {
            for index in read.pages.indices { read.pages[index].chords = saved.pages[index] }
            state.isEdited = saved.edited
            state.isRead = true
        } else if saved != nil {
            // The file changed shape since; it is read again when asked.
            ScoreEditStore.remove(item.id)
        }
        state.pages = read.pages
        state.source = read.source
        applyKeys(&state, item)
        state.isReady = true
        states[item.id] = state
        Self.cache[item.id] = state
        if state.isRead { recordKey(item) }
        // Fixed here and never shared — the stand closed, the app was
        // quit, the network was down: sent now, merged with whatever the
        // team shared meanwhile. It used to wait for the next edit.
        if saved?.dirty == true { scheduleShare(item) }
        // After 다시 읽기, read again now: that is what was asked.
        if rereading.contains(item.id) { await ensureRead(item) }
        // Corrections kept before they were marked: found by reading the
        // page again, in the background — the page is already showing.
        if let saved, saved.edited, saved.marksCorrections != true, state.isRead {
            Task { await markCorrections(item, data: data) }
        }
    }

    /// Marks the chords corrected by hand in edits kept before corrections
    /// were marked. Untransposed, the page draws only chords that differ
    /// from the print, and a correction without its mark stayed hidden
    /// under the printed — wrong — symbol. A kept chord is a correction
    /// when the page, read again, has another chord at its place.
    private func markCorrections(_ item: ScoreStandItem, data: Data) async {
        guard let fresh = await ScoreTransposer.read(data: data, only: item.pages),
              let state = states[item.id], fresh.pages.count == state.pages.count else { return }
        var corrected = Set<UUID>()
        for (page, kept) in state.pages.enumerated() {
            let found = fresh.pages[page].chords
            for chord in kept.chords where !chord.userAdded && chord.corrected != true {
                guard let match = found.max(by: { Self.overlap($0.box, chord.box) < Self.overlap($1.box, chord.box) }),
                      Self.overlap(match.box, chord.box) > 0.3 else { continue }
                if Self.spelling(match.original) != Self.spelling(chord.original) { corrected.insert(chord.id) }
            }
        }
        update(item) { state in
            for page in state.pages.indices {
                for index in state.pages[page].chords.indices where corrected.contains(state.pages[page].chords[index].id) {
                    state.pages[page].chords[index].corrected = true
                }
            }
        }
        // Kept marked, as it was otherwise: not made dirty, so nothing is
        // shared again for it.
        guard let now = states[item.id], let before = ScoreEditStore.load(item.id) else { return }
        ScoreEditStore.save(now.pages.map(\.chords), edited: true, for: item.id,
                            sharedFrom: before.sharedFrom, dirty: before.dirty == true)
    }

    /// How much of the smaller box the two share.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        return shared.width * shared.height / max(1e-9, min(a.width * a.height, b.width * b.height))
    }

    private static func spelling(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
    }

    /// The chart's key: what its name says, if it says one — that is what
    /// was printed — and otherwise what its chords suggest; and the shift to
    /// the 순서's key.
    private func applyKeys(_ state: inout State, _ item: ScoreStandItem) {
        let symbols = state.pages.flatMap { $0.chords.map(\.original) }
        let hint = ScoreChordText.keyHint(in: item.attachment.name) ?? ScoreChordText.keyHint(in: item.song)
        state.estimatedRoot = ScoreChordText.likelyRoot(of: symbols)
        state.writtenKey = hint?.written
        state.scoreRoot = hint?.root ?? state.estimatedRoot
        state.defaultShift = state.scoreRoot.flatMap { ScoreRecognition.shift(fromRoot: $0, toKey: item.teamKey) }
        // A shift the reader chose on this device wins over the default —
        // and nothing is shifted before there are chords to shift.
        state.shift = state.isRead ? (Self.savedShift(for: item.id) ?? state.defaultShift ?? 0) : 0
    }

    private var readingTasks: [String: Task<Void, Never>] = [:]

    /// The chords, read now if they have not been: the first key change,
    /// 코드표 or 편집 on a chart asks for this, and waits for it — once,
    /// however many ask.
    func ensureRead(_ item: ScoreStandItem) async {
        guard let state = states[item.id], state.isReady, !state.isRead else { return }
        if let running = readingTasks[item.id] { await running.value; return }
        let task = Task { @MainActor in
            update(item) { $0.isReading = true }
            var data = ScoreFileCache.load(item.attachment.fileId)
            if data == nil {
                data = try? await URLSession.shared.data(from: item.attachment.url.directDownload).0
            }
            guard let data, let read = await ScoreTransposer.read(data: data, only: item.pages),
                  var state = states[item.id], read.pages.count == state.pages.count else {
                update(item) { $0.isReading = false }
                note = "코드를 읽지 못했습니다."
                return
            }
            for index in state.pages.indices { state.pages[index].chords = read.pages[index].chords }
            state.isRead = true
            state.isReading = false
            applyKeys(&state, item)
            states[item.id] = state
            Self.cache[item.id] = state
            // After 다시 읽기, the shared corrections it set aside are
            // remembered as seen, so they are not taken up again.
            let remoteId = team?.attachment(fileId: item.attachment.fileId)?.editsFileId ?? item.attachment.editsFileId
            ScoreEditStore.save(state.pages.map(\.chords), edited: false, for: item.id,
                                sharedFrom: rereading.contains(item.id) ? remoteId : nil)
            rereading.remove(item.id)
            recordKey(item)
        }
        readingTasks[item.id] = task
        await task.value
        readingTasks[item.id] = nil
    }

    /// The key a chart is printed in, when this device has read it — from
    /// the stand's reading, else the reading kept from an earlier visit.
    /// For the version chips; nil until read, never a guess.
    func chartKeyName(_ item: ScoreStandItem) -> String? {
        if let state = states[item.id], state.isRead, let root = state.writtenKey == nil ? state.estimatedRoot : state.scoreRoot {
            return Self.name(root, flats: [5, 10, 3, 8, 1, 6].contains(root))
        }
        if let known = keptKeys[item.id] { return known }
        let symbols = ScoreEditStore.load(item.id)?.pages.joined().map(\.original) ?? []
        let name = ScoreChordText.likelyRoot(of: symbols).map { Self.name($0, flats: [5, 10, 3, 8, 1, 6].contains($0)) }
        keptKeys[item.id] = .some(name)
        return name
    }
    /// Read once from disk per chart; nil inside means "looked, none".
    private var keptKeys: [String: String?] = [:]

    /// The key the chart is now in, for the 예배표 to show beside the song.
    private func recordKey(_ item: ScoreStandItem) {
        guard var state = states[item.id], state.scoreRoot != nil else { return }
        // The key it is played in, even while 원본 is being looked at.
        state.showsOriginal = false
        ScoreKeyStore.set(Self.keyName(state), for: item.attachment.fileId)
    }

    /// A key change asked of a chart: its chords read first if they have
    /// not been. That first time, the 순서's key — when there is one — is
    /// the answer, and the press goes no further.
    func stepAsking(_ item: ScoreStandItem, _ delta: Int) async {
        let wasRead = states[item.id]?.isRead == true
        await ensureRead(item)
        if !wasRead, (states[item.id]?.shift ?? 0) != 0 { return }
        step(item, delta)
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

    /// Each hand edit's chords as they were before it, newest last, so a
    /// chord taken off by mistake — when it was meant to be corrected —
    /// comes back as it was. Per chart, for as long as the stand is open.
    @Published private(set) var history: [String: [Snapshot]] = [:]
    private static let historyLimit = 50

    struct Snapshot {
        let chords: [[ScoreChord]]
        let removed: [[ScoreChord]]
    }

    func canUndo(_ item: ScoreStandItem) -> Bool { history[item.id]?.isEmpty == false }

    /// The chords as they are, kept before an edit changes them.
    private func remember(_ item: ScoreStandItem) {
        guard let state = states[item.id] else { return }
        var past = history[item.id] ?? []
        past.append(Snapshot(chords: state.pages.map(\.chords), removed: removed[item.id] ?? []))
        if past.count > Self.historyLimit { past.removeFirst(past.count - Self.historyLimit) }
        history[item.id] = past
    }

    /// The last hand edit, taken back.
    func undo(_ item: ScoreStandItem) {
        guard var past = history[item.id], let previous = past.popLast() else { return }
        history[item.id] = past
        update(item) { state in
            for page in state.pages.indices where previous.chords.indices.contains(page) {
                state.pages[page].chords = previous.chords[page]
            }
        }
        setRemoved(previous.removed, for: item)
        saveEdits(item)
    }

    /// Chords taken off by hand, per page: shown while editing as faint
    /// boxes, and put back by a tap — after the stand was closed and opened
    /// again, which ↩ cannot reach. Kept on this device only; the team's
    /// shared corrections carry the chords, not what was taken off them.
    @Published private(set) var removed: [String: [[ScoreChord]]] = [:]

    func removedChords(_ item: ScoreStandItem, page: Int) -> [ScoreChord] {
        let pages = removed[item.id] ?? []
        return pages.indices.contains(page) ? pages[page] : []
    }

    private func setRemoved(_ pages: [[ScoreChord]], for item: ScoreStandItem) {
        removed[item.id] = pages
        ScoreRemovedStore.save(pages, for: item.id)
    }

    /// A chord taken off, back where it was.
    func restore(_ item: ScoreStandItem, page: Int, chord: UUID) {
        var pages = removed[item.id] ?? []
        guard pages.indices.contains(page),
              let index = pages[page].firstIndex(where: { $0.id == chord }) else { return }
        remember(item)
        let back = pages[page].remove(at: index)
        update(item) { state in
            guard state.pages.indices.contains(page) else { return }
            state.pages[page].chords.append(back)
            state.isEdited = true
        }
        setRemoved(pages, for: item)
        saveEdits(item)
    }

    func move(_ item: ScoreStandItem, page: Int, chord: UUID, to offset: CGSize) {
        edit(item, page: page, chord: chord) { $0.offset.width += offset.width; $0.offset.height += offset.height }
    }

    func remove(_ item: ScoreStandItem, page: Int, chord: UUID) {
        remember(item)
        var taken: ScoreChord?
        update(item) { state in
            guard state.pages.indices.contains(page) else { return }
            taken = state.pages[page].chords.first { $0.id == chord }
            state.pages[page].chords.removeAll { $0.id == chord }
            state.isEdited = true
        }
        if let taken {
            var pages = removed[item.id] ?? []
            while pages.count <= page { pages.append([]) }
            pages[page].append(taken)
            setRemoved(pages, for: item)
        }
        saveEdits(item)
    }

    /// The chord printed where a finger pressed, if the reader can make one
    /// out there: a strip around the spot, enlarged, read as a page is — and,
    /// failing that, as a lone capital (ScoreRecognition.readRepeated). In
    /// the key on screen, centred where it was found.
    ///
    /// WHY: the page reading misses a chord here and there — a lone letter,
    /// one crowded by a slur. Typing it was the only way to put it back; a
    /// tap on it now reads that spot alone, which is what finds most of them.
    func readChord(_ item: ScoreStandItem, page: Int, at point: CGPoint) async -> (text: String, center: CGPoint)? {
        guard let state = states[item.id], state.pages.indices.contains(page),
              let image = state.pages[page].image.cgImage else { return nil }
        let height = state.pages[page].chordHeight
        let shift = state.showsOriginal ? 0 : state.shift
        let flats: Bool? = state.useFlats
        return await Task.detached(priority: .userInitiated) { () -> (text: String, center: CGPoint)? in
            let width = CGFloat(image.width), tall = CGFloat(image.height)
            let spanY = max(height * 3, 0.035)
            let area = CGRect(x: point.x - 0.13, y: point.y - spanY / 2, width: 0.26, height: spanY)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !area.isNull,
                  let crop = image.cropping(to: CGRect(x: area.minX * width, y: area.minY * tall,
                                                       width: area.width * width, height: area.height * tall).integral)
            else { return nil }
            let read = ScoreRecognition.chords(in: ScoreRecognition.enlarged(crop, by: 3) ?? crop)
            let nearest = read.map { found -> (String, CGPoint) in
                (found.original, CGPoint(x: area.minX + found.box.midX * area.width,
                                         y: area.minY + found.box.midY * area.height))
            }
            .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
            // A lone capital, read from a tighter piece round the finger.
            let lone: (String, CGPoint)? = nearest == nil ? {
                let piece = CGRect(x: point.x - height * 1.2, y: point.y - height * 0.8,
                                   width: height * 2.4, height: height * 1.6)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !piece.isNull,
                      let cut = image.cropping(to: CGRect(x: piece.minX * width, y: piece.minY * tall,
                                                          width: piece.width * width, height: piece.height * tall).integral),
                      let found = ScoreRecognition.readRepeated(cut) else { return nil }
                return (found.original, point)
            }() : nil
            guard let (original, center) = nearest ?? lone else { return nil }
            return (ScoreTransposer.symbol(original, by: shift, useFlats: flats) ?? original, center)
        }.value
    }

    /// The page as printed round a chord: its line and a little of the staff
    /// under it, the chord's place outlined — shown over 코드 고치기 and
    /// over a chord read from a tap, so the reading is checked by eye
    /// against what is printed, not trusted.
    func originalPatch(_ item: ScoreStandItem, page: Int, chord: UUID) -> UIImage? {
        guard let state = states[item.id], state.pages.indices.contains(page),
              let found = state.pages[page].chords.first(where: { $0.id == chord }) else { return nil }
        return Self.patch(state.pages[page], box: found.box)
    }

    func originalPatch(_ item: ScoreStandItem, page: Int, around point: CGPoint) -> UIImage? {
        guard let state = states[item.id], state.pages.indices.contains(page) else { return nil }
        let h = state.pages[page].chordHeight
        return Self.patch(state.pages[page], box: CGRect(x: point.x - h, y: point.y - h / 2, width: h * 2, height: h))
    }

    private static func patch(_ page: ScoreTransposer.Page, box: CGRect) -> UIImage? {
        guard let image = page.image.cgImage else { return nil }
        let h = max(page.chordHeight, box.height)
        // The chord and its neighbours, the top of the staff under it: big
        // enough to read the printed symbol at a glance.
        let area = CGRect(x: box.midX - 0.12, y: box.minY - h * 0.9, width: 0.24, height: h * 3.6)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let width = CGFloat(image.width), tall = CGFloat(image.height)
        let pixels = CGRect(x: area.minX * width, y: area.minY * tall,
                            width: area.width * width, height: area.height * tall).integral
        guard !area.isNull, let crop = image.cropping(to: pixels) else { return nil }
        let size = CGSize(width: crop.width, height: crop.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            // The chord's place, outlined.
            let mark = CGRect(x: (box.minX - area.minX) / area.width * size.width,
                              y: (box.minY - area.minY) / area.height * size.height,
                              width: box.width / area.width * size.width,
                              height: box.height / area.height * size.height)
                .insetBy(dx: -size.height * 0.03, dy: -size.height * 0.03)
            UIColor.systemOrange.setStroke()
            let path = UIBezierPath(roundedRect: mark, cornerRadius: 3)
            path.lineWidth = max(2, size.height * 0.015)
            path.stroke()
        }
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
            // Marked, so it is drawn over the printed symbol in the printed
            // key too — it showed only once the chart was transposed.
            edit(item, page: page, chord: chord) { $0.original = original; $0.corrected = true }
        } else {
            remember(item)
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

    // MARK: 코드표

    /// Each song's bars, chords and lyrics, read the first time 코드표 is
    /// asked for — a second or two a page — and again after a hand edit.
    /// Held in memory only: the lyrics are the team's chart, read to lay it
    /// out, and are not kept.
    @Published var charts: [String: [ScoreChart.System]] = [:]
    private var chartsReading: Set<String> = []

    func loadChart(_ item: ScoreStandItem) async {
        guard charts[item.id] == nil, !chartsReading.contains(item.id),
              let state = states[item.id], state.isReady else { return }
        chartsReading.insert(item.id)
        defer { chartsReading.remove(item.id) }
        let pages = state.pages.map { page in
            (page.image.cgImage, page.chords.map { ScoreChart.ChordMark(id: $0.id, box: $0.placed) })
        }
        // Read once, kept on the device: the lyrics and bars take seconds
        // to read, and a song turned to on Sunday should not take them
        // again. Kept against the chords it was read with — a chord moved
        // or added by hand reads the 코드표 again.
        let signature = ScoreChartStore.signature(pages.map(\.1))
        // Lyrics corrected by hand, laid over every reading: kept apart from
        // it, which a moved chord throws away.
        let fixes = ScoreLyricFixStore.load(item.id)
        if let kept = ScoreChartStore.load(item.id, signature: signature) {
            charts[item.id] = LyricFixes.apply(fixes, to: kept)
            return
        }
        let systems = await Task.detached(priority: .userInitiated) {
            pages.flatMap { image, marks in image.map { ScoreChart.read($0, chords: marks) } ?? [] }
        }.value
        charts[item.id] = LyricFixes.apply(fixes, to: systems)
        ScoreChartStore.save(systems, for: item.id, signature: signature)
    }

    /// A 코드표 line's lyrics, corrected by hand — and shared with the team.
    func fixLyrics(_ item: ScoreStandItem, line index: Int, edited: ScoreChart.System) {
        guard var systems = charts[item.id], systems.indices.contains(index) else { return }
        let fixes = LyricFixes.merge(ScoreLyricFixStore.load(item.id), system: index,
                                     shown: systems[index], edited: edited)
        ScoreLyricFixStore.save(fixes, for: item.id)
        systems[index] = edited
        charts[item.id] = systems
        // Shared with the chords: the team reads the same words — the room
        // at once, the sheet a moment later.
        RehearsalLink.shared.send(.init(kind: .lyrics, fileId: item.attachment.fileId,
                                        key: SharedEdits.key(pages: item.pages), delta: nil,
                                        lyrics: fixes, from: nearbyName))
        if var saved = ScoreEditStore.load(item.id) {
            saved.dirty = true
            ScoreEditStore.write(saved, for: item.id)
            scheduleShare(item)
        }
    }

    /// Forgets every hand edit and reads the chart again.
    func resetEdits(_ item: ScoreStandItem) async {
        // A fresh reading: the edits being undone, and the chords taken
        // off, no longer exist.
        history[item.id] = nil
        removed[item.id] = nil
        ScoreRemovedStore.remove(item.id)
        charts[item.id] = nil
        rereading.insert(item.id)
        ScoreEditStore.remove(item.id)
        Self.cache[item.id] = nil
        states[item.id] = nil
        await load(item)
    }

    private func edit(_ item: ScoreStandItem, page: Int, chord: UUID, _ change: (inout ScoreChord) -> Void) {
        remember(item)
        update(item) { state in
            guard state.pages.indices.contains(page),
                  let index = state.pages[page].chords.firstIndex(where: { $0.id == chord }) else { return }
            change(&state.pages[page].chords[index])
            state.isEdited = true
        }
        saveEdits(item)
    }

    private func saveEdits(_ item: ScoreStandItem) {
        charts[item.id] = nil
        guard let state = states[item.id] else { return }
        let before = ScoreEditStore.load(item.id)
        let now = state.pages.map(\.chords)
        ScoreEditStore.save(now, edited: true, for: item.id,
                            sharedFrom: before?.sharedFrom, dirty: true,
                            base: before?.base, lyricBase: before?.lyricBase)
        // The room first: only what changed, to the stands nearby at once.
        // The sheet gets the whole correction a moment later.
        if let old = before?.pages, let delta = ChartDelta.between(old, now), !delta.isEmpty {
            RehearsalLink.shared.send(.init(kind: .delta, fileId: item.attachment.fileId,
                                            key: SharedEdits.key(pages: item.pages), delta: delta,
                                            lyrics: nil, from: nearbyName))
        }
        scheduleShare(item)
    }

    // MARK: The room

    /// The name shown to the devices nearby.
    var nearbyName = ""
    private var linkToken: UUID?
    /// When a change last came from the room, per chart — the same change
    /// arriving through the sheet a moment later is not announced again.
    private var heardNearby: [String: Date] = [:]

    /// While the stand is open: the team's devices in the room, and every
    /// chart of the set, so a change to a song not on screen lands too.
    func joinRoom(items: [ScoreStandItem], team sheetId: String?) {
        for item in items where knownItems[item.id] == nil { knownItems[item.id] = item }
        guard linkToken == nil else { return }
        RehearsalLink.shared.start(team: RehearsalLink.teamTag(sheetId), name: nearbyName)
        linkToken = RehearsalLink.shared.listen { [weak self] message in self?.heard(message) }
        roomWatch = RehearsalLink.shared.$peers
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.readIfInRoom() } }
    }

    func leaveRoom() {
        guard let linkToken else { return }
        RehearsalLink.shared.unlisten(linkToken)
        RehearsalLink.shared.stop()
        self.linkToken = nil
        roomWatch = nil
    }

    private var roomWatch: AnyCancellable?
    private var onScreen: ScoreStandItem?

    /// With someone in the room, the chart on screen has its chords ahead —
    /// theirs if they have read it, else read here: a change is laid on
    /// chords, and reading them only when the first change came took
    /// seconds, on the one change that most needed to be seen at once.
    private func readIfInRoom() {
        guard !RehearsalLink.shared.peers.isEmpty, let item = onScreen,
              states[item.id]?.isReady == true, states[item.id]?.isRead != true,
              states[item.id]?.isReading != true else { return }
        askRoom(item)
    }

    /// One printed chord on two devices: the same id, or — read on each
    /// device under its own ids — the same spot on the page.
    static func samePrinted(_ a: ScoreChord, _ b: ScoreChord) -> Bool {
        a.id == b.id || (abs(a.box.midX - b.box.midX) < 0.015 && abs(a.box.midY - b.box.midY) < 0.01)
    }

    private func heard(_ message: RehearsalLink.Message) {
        for item in knownItems.values
        where item.attachment.fileId == message.fileId && SharedEdits.key(pages: item.pages) == message.key {
            switch message.kind {
            case .want:
                // Answered by whoever has the chords read.
                if let pages = readChords(item) {
                    send(.chords, item, pages: pages)
                }
                continue
            case .chords:
                guard let pages = message.pages else { continue }
                takeChords(item, pages: pages)
            case .delta:
                guard let delta = message.delta else { continue }
                guard let current = readChords(item) else {
                    // Not read here yet: the room's reading, not a new one.
                    askRoom(item)
                    continue
                }
                let laid = delta.applied(to: current, same: Self.samePrinted)
                keep(item, pages: laid.pages)
                // Fell partly on nothing: this copy was read differently.
                // The whole chart, from the one who changed it.
                if laid.missed > 0 { askRoom(item) }
            case .lyrics:
                ScoreLyricFixStore.save(message.lyrics ?? [], for: item.id)
                charts[item.id] = nil
            }
            heardNearby[item.id] = Date()
            if message.kind != .chords {
                shareStatus[item.id] = "\(message.from.isEmpty ? "팀원" : message.from) 님이 고친 것을 바로 받았습니다"
            }
        }
    }

    /// The chords this device has for a chart: on screen if read, else kept.
    private func readChords(_ item: ScoreStandItem) -> [[ScoreChord]]? {
        states[item.id].flatMap { $0.isRead ? $0.pages.map(\.chords) : nil } ?? ScoreEditStore.load(item.id)?.pages
    }

    /// Kept as this device's copy, not as its own fix: the sender shares it
    /// with the sheet, and this device's own unshared fixes stay marked.
    private func keep(_ item: ScoreStandItem, pages: [[ScoreChord]]) {
        var saved = ScoreEditStore.load(item.id) ?? .init(pages: pages, edited: true, version: ScoreRecognition.version)
        saved.pages = pages
        saved.edited = true
        ScoreEditStore.write(saved, for: item.id)
        if states[item.id]?.isReady == true { adopt(item, pages: pages) }
    }

    /// Another device's reading, whole. Fixes of this device's own that are
    /// not yet shared are laid on top of it.
    private func takeChords(_ item: ScoreStandItem, pages: [[ScoreChord]]) {
        if let at = tookChords[item.id], Date().timeIntervalSince(at) < 2 { return }
        let saved = ScoreEditStore.load(item.id)
        let mine = saved?.dirty == true ? EditMerge.pages(base: saved?.base, local: saved!.pages, remote: pages) : pages
        keep(item, pages: mine)
        tookChords[item.id] = Date()
        waitingForRoom.remove(item.id)
    }
    private var tookChords: [String: Date] = [:]
    private var waitingForRoom: Set<String> = []

    /// Asks the room for a chart's chords; reads them here only if nobody
    /// answers within two seconds.
    private func askRoom(_ item: ScoreStandItem) {
        guard !waitingForRoom.contains(item.id) else { return }
        waitingForRoom.insert(item.id)
        send(.want, item)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.waitingForRoom.remove(item.id) != nil,
                  self.states[item.id]?.isRead != true else { return }
            await self.ensureRead(item)
        }
    }

    private func send(_ kind: RehearsalLink.Message.Kind, _ item: ScoreStandItem, pages: [[ScoreChord]]? = nil) {
        RehearsalLink.shared.send(.init(kind: kind, fileId: item.attachment.fileId,
                                        key: SharedEdits.key(pages: item.pages), delta: nil,
                                        lyrics: nil, pages: pages, from: nearbyName))
    }

    // MARK: Sharing corrections

    /// Set by the view: where shared corrections are read and written.
    weak var team: TeamStore?
    /// Charts being read again on request, whose shared corrections are
    /// set aside.
    private var rereading: Set<String> = []
    private var shareTasks: [String: Task<Void, Never>] = [:]
    /// A line for the header: shared, sharing, or why not.
    @Published var shareStatus: [String: String] = [:]

    /// Shares a chart's corrections a second after the last change — one
    /// upload for a run of quick fixes, not one per tap, and soon enough for
    /// the members not in the room.
    private func scheduleShare(_ item: ScoreStandItem) {
        shareTasks[item.id]?.cancel()
        shareStatus[item.id] = "고친 코드를 팀과 공유하는 중…"
        shareTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.share(item)
        }
    }

    /// Shares now whatever is waiting — when the stand closes.
    func shareNow() {
        for (id, task) in shareTasks {
            task.cancel()
            if let item = knownItems[id] { Task { await share(item) } }
        }
        shareTasks = [:]
    }

    private var knownItems: [String: ScoreStandItem] = [:]

    private func share(_ item: ScoreStandItem) async {
        guard let saved = ScoreEditStore.load(item.id), saved.dirty == true else { return }
        guard let team else {
            shareStatus[item.id] = "이 기기에만 저장됨"
            return
        }
        let key = SharedEdits.key(pages: item.pages)
        let lyrics = ScoreLyricFixStore.load(item.id)
        switch await team.shareEdits(fileId: item.attachment.fileId, key: key,
                                     pages: saved.pages, base: saved.base,
                                     lyrics: lyrics, lyricBase: saved.lyricBase) {
        case .success(let result):
            // What the team has now — this device's fixes and anyone
            // else's since, put together — is what this device shows.
            let merged = result.file.charts[key] ?? saved.pages
            let mergedLyrics = result.file.lyrics?[key] ?? lyrics
            var now = ScoreEditStore.load(item.id) ?? saved
            // Fixed again while this was being sent: kept, on top.
            let editedMeanwhile = now.pages != saved.pages
            now.pages = editedMeanwhile ? EditMerge.pages(base: saved.pages, local: now.pages, remote: merged) : merged
            now.sharedFrom = result.fileId
            now.base = merged
            now.lyricBase = mergedLyrics
            now.dirty = editedMeanwhile
            ScoreEditStore.write(now, for: item.id)
            if now.pages != states[item.id]?.pages.map(\.chords) { adopt(item, pages: now.pages) }
            if mergedLyrics != lyrics {
                ScoreLyricFixStore.save(mergedLyrics, for: item.id)
                charts[item.id] = nil
            }
            shareStatus[item.id] = merged != saved.pages
                ? "공유했습니다 — 팀원이 고친 곳도 함께 들어왔습니다"
                : "고친 코드를 팀과 공유했습니다"
            if editedMeanwhile { scheduleShare(item) }
        case .failure(.noAccess):
            shareStatus[item.id] = "이 기기에만 저장됨 — 공유하려면 교회 계정을 연결하세요"
        case .failure(.moved), .failure(.notFound):
            shareStatus[item.id] = "이 기기에만 저장됨 — 시트를 새로 고친 뒤 다시 고치면 공유됩니다"
        case .failure(.failed(let reason)):
            shareStatus[item.id] = "공유하지 못했습니다: \(reason) — 다음에 열 때 다시 보냅니다"
        }
    }

    /// Chords from the team on the page as it stands: the key, the
    /// position, everything else kept.
    private func adopt(_ item: ScoreStandItem, pages: [[ScoreChord]]) {
        guard var state = states[item.id], state.pages.count == pages.count else { return }
        for index in pages.indices { state.pages[index].chords = pages[index] }
        state.isEdited = true
        state.isRead = true
        applyKeys(&state, item)
        states[item.id] = state
        Self.cache[item.id] = state
        charts[item.id] = nil
    }

    /// While the stand is open: the team's newer corrections, taken up as
    /// they are shared — every 3 seconds, one read of the Attachments tab
    /// (twenty a minute, a third of what Google allows one person), and a
    /// download only when a chart's file changed. For the members not in
    /// the room; those in it have had the change from RehearsalLink.
    ///
    /// WHY: corrections reached another member only when they closed the
    /// chart and opened it again after a reload. In a rehearsal the person
    /// fixing the bridge and the people reading it are looking at it at
    /// the same moment.
    func watchTeam() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let team, let ids = await team.editsIds() else { continue }
            for (id, item) in knownItems where states[id]?.isReady == true {
                guard let remote = ids[item.attachment.fileId], !remote.isEmpty else { continue }
                let saved = ScoreEditStore.load(id)
                guard remote != saved?.sharedFrom else { continue }
                // Fixes of its own waiting: sharing merges the two.
                if saved?.dirty == true { scheduleShare(item); continue }
                guard let file = await SharedEdits.fetch(remote) else { continue }
                receive(item, file: file, fileId: remote, saved: saved)
            }
        }
    }

    private func receive(_ item: ScoreStandItem, file: SharedEdits.File, fileId: String, saved: ScoreEditStore.Saved?) {
        let key = SharedEdits.key(pages: item.pages)
        guard let pages = file.charts[key] else {
            // A change to another song's pages of this file: nothing here.
            if var kept = saved { kept.sharedFrom = fileId; ScoreEditStore.write(kept, for: item.id) }
            return
        }
        let lyrics = file.lyrics?[key] ?? []
        let changed = pages != saved?.pages || lyrics != ScoreLyricFixStore.load(item.id)
        ScoreEditStore.write(.init(pages: pages, edited: true, version: ScoreRecognition.version,
                                   sharedFrom: fileId, dirty: false,
                                   marksCorrections: pages.joined().contains { $0.corrected != nil } ? true : nil,
                                   base: pages, lyricBase: lyrics), for: item.id)
        ScoreLyricFixStore.save(lyrics, for: item.id)
        guard changed else { return }
        adopt(item, pages: pages)
        // Already had from the room: the sheet's copy only settles the ids.
        if let heard = heardNearby[item.id], Date().timeIntervalSince(heard) < 30 { return }
        shareStatus[item.id] = "팀원이 고친 코드를 받았습니다"
        let song = item.song.isEmpty ? (item.attachment.name as NSString).deletingPathExtension
                                     : PlanSongTitle.split(item.song).title
        Toast.shared.show("「\(song)」 팀원이 고친 악보를 받았습니다", symbol: "arrow.down.circle.fill", tint: .blue)
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
        // The song as sung — not the upload's 「[새찬송가 546장] … | 팀」 —
        // and a file's name without its own extension.
        let base = (item.song.isEmpty ? (item.attachment.name as NSString).deletingPathExtension
                                      : PlanSongTitle.split(item.song).title)
            .replacingOccurrences(of: "/", with: "-")
        guard let state, let root = state.targetRoot else { return "\(base).pdf" }
        let key = Self.name(root, flats: state.useFlats)
        return "\(base) (\(key)).pdf"
    }

    private func pdf(_ item: ScoreStandItem, caption: String? = nil, notice: String? = nil) async -> Data? {
        guard let state = states[item.id] else { return nil }
        let pages = state.pages
        let shift = state.showsOriginal ? 0 : state.shift
        let flats: Bool? = state.useFlats
        let scale = chordScale
        return await Task.detached(priority: .userInitiated) {
            ScoreTransposer.transposed(pages: pages, by: shift, useFlats: flats, scale: scale,
                                       caption: caption, notice: notice)
        }.value
    }

    /// The chart as it is on the stand — key, corrections — into Photos,
    /// a page an image.
    func saveToPhotos(_ item: ScoreStandItem) async {
        guard let state = states[item.id] else { return }
        isExporting = true
        defer { isExporting = false }
        let pages = state.pages
        let shift = state.showsOriginal ? 0 : state.shift
        let flats: Bool? = state.useFlats
        let scale = chordScale
        let images = await Task.detached(priority: .userInitiated) {
            ScoreTransposer.images(pages: pages, by: shift, useFlats: flats, scale: scale)
        }.value
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: break
        default:
            note = "사진에 저장하려면 설정 > SolaPraise > 사진에서 「사진 추가」를 허용하세요."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            }
            note = images.count == 1 ? "사진에 저장했습니다." : "사진에 \(images.count)장 저장했습니다."
        } catch {
            note = "사진에 저장하지 못했습니다."
        }
    }

    /// The chart as it is on the stand, as a PDF into Files — where to, the
    /// person chooses.
    func saveToFiles(_ item: ScoreStandItem, notice: String? = nil) async {
        isExporting = true
        defer { isExporting = false }
        guard let data = await pdf(item, notice: notice) else {
            note = "PDF를 만들지 못했습니다."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(item))
        do {
            try data.write(to: url, options: .atomic)
            SharePresenter.exportToFiles(url)
        } catch {
            note = "PDF를 저장하지 못했습니다."
        }
    }

    func exportPDF(_ item: ScoreStandItem, notice: String? = nil) async {
        isExporting = true
        defer { isExporting = false }
        guard let data = await pdf(item, notice: notice) else {
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
    /// - upload: a new 콘티 version is put up for the team first; what
    ///   happened is said, and the share sheet follows.
    func exportSet(_ items: [ScoreStandItem], title: String?, fileName: String? = nil,
                   captions: [String: String] = [:], notices: [String: String] = [:],
                   upload: ((Data, String) async -> String)? = nil) async {
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
            guard let data = await pdf(item, caption: captions[item.song], notice: notices[item.song]),
                  let document = PDFDocument(data: data) else {
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
        // As the 콘티 folder names its files, a version up, when given — to
        // save straight into that folder from the share sheet.
        let file = fileName.map { $0.replacingOccurrences(of: "/", with: "-") + ".pdf" } ?? "\(base) 악보.pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        do {
            try data.write(to: url, options: .atomic)
            if let upload, fileName != nil {
                let said = await upload(data, file)
                pendingExport = ExportFile(url: url)
                note = skipped.isEmpty ? said : said + "\n열 수 없는 악보는 빠졌습니다: \(skipped.joined(separator: ", "))"
            } else if skipped.isEmpty {
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
/// A chart's chords as last read or corrected, kept on this device per
/// attachment — so a chart opens without being read again, and a chart
/// corrected once stays corrected.
/// Each 코드표 as read, on this device only — never shared or uploaded:
/// it holds the song's words.
enum ScoreChartStore {
    private struct Saved: Codable {
        let signature: String
        let systems: [ScoreChart.System]
    }

    /// The readers' versions and every chord's id and place: what the
    /// reading depends on besides the page itself, which a file id fixes.
    static func signature(_ pages: [[ScoreChart.ChordMark]]) -> String {
        "\(ScoreChart.version).\(ScoreRecognition.version)|" + pages.map { marks in
            marks.map { "\($0.id.uuidString)@\(Int($0.box.minX * 10000)),\(Int($0.box.minY * 10000))" }
                .joined(separator: ",")
        }.joined(separator: "|")
    }

    private static var folder: URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("ScoreCharts", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func load(_ id: String, signature: String) -> [ScoreChart.System]? {
        guard let url = ScoreEditStore.file(id, in: folder), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.signature == signature else { return nil }
        return saved.systems
    }

    static func save(_ systems: [ScoreChart.System], for id: String, signature: String) {
        guard let url = ScoreEditStore.file(id, in: folder),
              let data = try? JSONEncoder().encode(Saved(signature: signature, systems: systems)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 코드표 lyrics corrected by hand on this device (LyricFixes).
enum ScoreLyricFixStore {
    private static var folder: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("ScoreLyricFixes", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func load(_ id: String) -> [LyricFix] {
        guard let url = ScoreEditStore.file(id, in: folder), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LyricFix].self, from: data)) ?? []
    }

    static func save(_ fixes: [LyricFix], for id: String) {
        guard let url = ScoreEditStore.file(id, in: folder) else { return }
        if fixes.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(fixes) { try? data.write(to: url, options: .atomic) }
    }
}

/// Chords taken off a chart by hand on this device, to put back later.
enum ScoreRemovedStore {
    private static var folder: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("ScoreRemoved", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func load(_ id: String) -> [[ScoreChord]] {
        guard let url = ScoreEditStore.file(id, in: folder), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([[ScoreChord]].self, from: data)) ?? []
    }

    static func save(_ pages: [[ScoreChord]], for id: String) {
        guard let url = ScoreEditStore.file(id, in: folder) else { return }
        if pages.allSatisfy(\.isEmpty) { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(pages) { try? data.write(to: url, options: .atomic) }
    }

    static func remove(_ id: String) {
        if let url = ScoreEditStore.file(id, in: folder) { try? FileManager.default.removeItem(at: url) }
    }
}

enum ScoreEditStore {
    struct Saved: Codable {
        var pages: [[ScoreChord]]
        /// Changed by hand, as opposed to only recognised.
        var edited: Bool
        /// ScoreRecognition.version that read it; nil before versions.
        var version: Int?
        /// The shared corrections file this copy came from or was last
        /// sent as — see SharedEdits.
        var sharedFrom: String? = nil
        /// Changed here and not yet shared with the team.
        var dirty: Bool? = nil
        /// Its corrected chords carry ScoreChord.corrected. Nil for edits
        /// kept before the mark existed, or received from a teammate's
        /// older app — marked once, by reading the page again.
        var marksCorrections: Bool? = nil
        /// The chords and lyric fixes as of `sharedFrom` — what this device
        /// and the team last agreed on, which a merge measures changes
        /// from (EditMerge).
        var base: [[ScoreChord]]? = nil
        var lyricBase: [LyricFix]? = nil
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

    static func save(_ pages: [[ScoreChord]], edited: Bool, for id: String,
                     sharedFrom: String? = nil, dirty: Bool = false,
                     base: [[ScoreChord]]? = nil, lyricBase: [LyricFix]? = nil) {
        write(Saved(pages: pages, edited: edited, version: ScoreRecognition.version,
                    sharedFrom: sharedFrom, dirty: dirty, marksCorrections: true,
                    base: base, lyricBase: lyricBase), for: id)
    }

    static func write(_ saved: Saved, for id: String) {
        guard let url = file(id, in: folder), let data = try? JSONEncoder().encode(saved) else { return }
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

/// 「근처 3명」: the stands in the room that a fix reaches at once.
private struct NearbyBadge: View {
    /// In the title row (wide screens), or as a line under it (a phone,
    /// whose title row the song's name already fills).
    let inRow: Bool
    @ObservedObject private var link = RehearsalLink.shared
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        if !link.peers.isEmpty, inRow == (width != .compact) {
            Label(inRow ? "근처 \(link.peers.count)명" : "근처 \(link.peers.joined(separator: ", "))와 바로 연결됨",
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(Color.green.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .accessibilityLabel("근처 팀원 \(link.peers.count)명과 바로 연결됨: \(link.peers.joined(separator: ", "))")
        }
    }
}
