//
//  ReorderPlanSheet.swift
//  SolaPraise
//
//  A service's 순서: add a line, drag them into order, swipe one out.
//
//  One place for all three — 「순서 추가 및 조정」. Adding and reordering
//  were two buttons under the 순서 that opened two sheets, and a line added
//  at the end almost always had to be moved next.
//
//  WHY A SHEET: the 순서 rows live in a stack inside one row of the
//  schedule list, and .onMove belongs to a List's own rows — it cannot
//  reach into a stack nested in a cell. Rather than rebuild the whole
//  schedule around a feature used once a week, the order gets its own
//  List here, where dragging is native and works the same on both devices.
//
//  A song line says whether it is the 헌금송 (헌신찬양) and who prays, and
//  sets it — here, with the 순서, not in the song's 📎 menu of files.
//
//  Nothing is written until 저장. Dragging is exploratory — you try the
//  bridge before the second chorus, then put it back — and writing every
//  intermediate order to a sheet the whole team is reading would broadcast
//  each experiment.
//

import SwiftUI

struct ReorderPlanSheet: View {
    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss

    let service: TeamService
    let sheetId: String?

    /// Identity by position at open, not by order-and-title: two rows can
    /// share both (a song sung twice, or rows a broken append numbered
    /// alike), and a List with duplicate ids drags the wrong row.
    private struct Line: Identifiable {
        let id: Int
        let item: PlanItem
    }

    @State private var lines: [Line] = []
    /// Swiped away. Removed from the sheet only on 저장, like the order.
    @State private var removed: [PlanItem] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var adding = false
    /// The 헌신 찬양 shortcut: 순서 추가 opened as it.
    @State private var addingDedication = false
    /// The song whose 헌금송 mark is being set.
    @State private var offeringFor: Line?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lines) { line in
                        HStack(spacing: 10) {
                            Image(systemName: line.item.kind.symbolName)
                                .foregroundStyle(line.item.kind == .song
                                                 ? Color.accentColor : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.item.kind == .song ? PlanSongTitle.split(line.item.title).title : line.item.title)
                                    .lineLimit(2)
                                if let key = line.item.key {
                                    Text(key).font(.caption).foregroundStyle(.secondary)
                                }
                                let offering = line.item.offering
                                if line.item.kind == .song, offering.isOffering {
                                    Text("헌금송" + (offering.prayer.map { " · 헌금기도 \($0)" } ?? ""))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Spacer(minLength: 0)
                            // 헌금송으로 지정, or who prays: written at once,
                            // as a line added is.
                            if line.item.kind == .song, !team.isReadOnly {
                                Button { offeringFor = line } label: {
                                    Image(systemName: line.item.offering.isOffering ? "gift.fill" : "gift")
                                        .foregroundStyle(line.item.offering.isOffering ? Color.accentColor : .secondary)
                                        .frame(width: 36, height: 32)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(line.item.offering.isOffering ? "헌금송 · 헌금기도자 바꾸기" : "헌금송으로 지정")
                            }
                        }
                    }
                    .onMove { from, to in lines.move(fromOffsets: from, toOffset: to) }
                    // Swipe left to remove — the same gesture as the 콘티.
                    .onDelete { offsets in
                        removed += offsets.map { lines[$0].item }
                        lines.remove(atOffsets: offsets)
                    }
                } footer: {
                    Text(removed.isEmpty
                         ? "끌어서 순서를 바꾸고, 왼쪽으로 밀어 지우세요. 저장하기 전까지는 시트가 바뀌지 않습니다. 아래 「순서 추가」로 더한 줄은 바로 시트 맨 뒤에 들어갑니다."
                         : "\(removed.count)개를 지웁니다. 저장하기 전까지는 시트가 바뀌지 않습니다.")
                }

                Section {
                    Button { adding = true } label: {
                        Label("순서 추가", systemImage: "plus.circle.fill")
                    }
                    // Most weeks, the same song for months: one tap to the
                    // last ones sung, and who prays.
                    Button { addingDedication = true } label: {
                        Label("헌신 찬양", systemImage: "gift")
                    }
                } footer: {
                    Text("헌신 찬양: 지난번 곡을 고르고 헌금기도자만 적으면 됩니다.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            // Always in edit mode: the only thing this screen is for is
            // dragging, so the handles should be there without a tap first.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("순서 추가 및 조정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(changed ? "취소" : "닫기") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(isSaving || !changed)
                }
            }
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView().controlSize(.large) } }
        }
        .onAppear(perform: load)
        // A line added is written at once, at the end of the 순서.
        .sheet(isPresented: $adding, onDismiss: merge) {
            AddPlanItemSheet(service: service).environmentObject(team)
        }
        .sheet(isPresented: $addingDedication, onDismiss: merge) {
            AddPlanItemSheet(service: service, dedication: true).environmentObject(team)
        }
        .sheet(item: $offeringFor) { line in
            OfferingSheet(song: line.item.title, prayer: line.item.offering.prayer,
                          isOffering: line.item.offering.isOffering,
                          onSave: { prayer in await setOffering(line, isOffering: true, prayer: prayer) },
                          onRemove: { await setOffering(line, isOffering: false, prayer: nil) },
                          onCancel: { offeringFor = nil })
        }
    }

    /// Written to the song's notes at once; the line here takes the new
    /// notes without losing a drag not yet saved.
    private func setOffering(_ line: Line, isOffering: Bool, prayer: String?) async -> String? {
        guard let sheetId else { return "팀 시트가 연결되어 있지 않습니다." }
        let failure = await team.setOffering(line.item, in: service, isOffering: isOffering,
                                             prayer: prayer, sheetId: sheetId)
        guard failure == nil else { return failure }
        let fresh = team.plan(for: service)
        if let at = lines.firstIndex(where: { $0.id == line.id }),
           let item = fresh.first(where: { $0.row == line.item.row && $0.title == line.item.title }) {
            lines[at] = Line(id: line.id, item: item)
        }
        offeringFor = nil
        return nil
    }

    private func load() {
        lines = team.plan(for: service).enumerated().map { Line(id: $0.offset, item: $0.element) }
    }

    /// The new line at the end, without losing a drag not yet saved.
    private func merge() {
        guard changed else { load(); return }
        let known = Set(lines.map(\.item.id) + removed.map(\.id))
        var next = (lines.map(\.id).max() ?? -1) + removed.count + 1
        for item in team.plan(for: service) where !known.contains(item.id) {
            lines.append(Line(id: next, item: item))
            next += 1
        }
    }

    private var changed: Bool {
        !removed.isEmpty || lines.map(\.id) != Array(0..<lines.count)
    }

    private func save() {
        guard let sheetId else { errorMessage = "팀 시트가 연결되어 있지 않습니다."; return }
        isSaving = true
        errorMessage = nil
        Task {
            // Removals first, each checked against its row (see
            // removePlanItem), then the rest renumbered 1…n — which closes
            // the gaps the removals leave.
            for item in removed {
                if let failure = await team.removePlanItem(item, from: service, sheetId: sheetId) {
                    isSaving = false
                    errorMessage = failure
                    return
                }
            }
            removed = []
            let failure = lines.isEmpty ? nil
                : await team.reorder(lines.map(\.item), in: service, sheetId: sheetId)
            isSaving = false
            if let failure { errorMessage = failure } else { dismiss() }
        }
    }
}
