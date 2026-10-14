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
