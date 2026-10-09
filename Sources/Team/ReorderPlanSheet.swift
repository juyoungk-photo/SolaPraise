//
//  ReorderPlanSheet.swift
//  SolaPraise
//
//  Dragging a service's 순서 into a new order.
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
    @State private var isSaving = false
    @State private var errorMessage: String?

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
                                Text(line.item.title).lineLimit(2)
                                if let key = line.item.key {
                                    Text(key).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { from, to in lines.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text("끌어서 순서를 바꾼 뒤 저장하세요. 저장하기 전까지는 시트가 바뀌지 않습니다.")
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
            .navigationTitle("순서 바꾸기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(isSaving || !changed)
                }
            }
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView().controlSize(.large) } }
        }
        .onAppear {
            lines = team.plan(for: service).enumerated().map { Line(id: $0.offset, item: $0.element) }
        }
    }

    private var changed: Bool {
        lines.map(\.id) != Array(0..<lines.count)
    }

    private func save() {
        guard let sheetId else { errorMessage = "팀 시트가 연결되어 있지 않습니다."; return }
        isSaving = true
        errorMessage = nil
        Task {
            let failure = await team.reorder(lines.map(\.item), in: service, sheetId: sheetId)
            isSaving = false
            if let failure { errorMessage = failure } else { dismiss() }
        }
    }
}
