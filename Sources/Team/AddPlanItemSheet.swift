//
//  AddPlanItemSheet.swift
//  SolaPraise
//
//  One more line in the order of service.
//
//  Not every week is the template. A 특별순서, a baptism, a longer 광고 —
//  the screen's answer to all of them used to be "add it on the sheet's Plan
//  tab", which is true, and useless on a phone in a sanctuary ten minutes
//  before the service.
//

import SwiftUI

struct AddPlanItemSheet: View {
    let service: TeamService
    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: PlanItem.Kind = .other
    @State private var minutes = ""
    @State private var isSaving = false

    private let kinds: [PlanItem.Kind] = [
        .other, .song, .prayer, .reading, .sermon, .announcement, .offering, .transition
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("순서 이름", text: $title)
                        .submitLabel(.done)
                    Picker("구분", selection: $kind) {
                        ForEach(kinds, id: \.self) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text("길이")
                        Spacer()
                        TextField("분", text: $minutes)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("분").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("맨 뒤에 추가됩니다. 자리를 옮기려면 「순서 바꾸기」를 쓰세요.")
                }

                if let message = team.errorMessage {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("순서 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("추가") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard let sheetId = TeamSheetSource.current else { return }
        isSaving = true
        defer { isSaving = false }
        let ok = await team.appendPlanItem(
            title: title.trimmingCharacters(in: .whitespaces),
            kind: kind,
            minutes: Int(minutes.trimmingCharacters(in: .whitespaces)),
            to: service,
            sheetId: sheetId
        )
        if ok { dismiss() }
    }
}
