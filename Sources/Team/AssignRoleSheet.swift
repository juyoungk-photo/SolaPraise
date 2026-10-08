//
//  AssignRoleSheet.swift
//  SolaPraise
//
//  Putting somebody's name against a part — 수형 to 인도 for next Sunday.
//
//  WHAT THIS IS NOT: it is not answering for them. The schedule says who is
//  MEANT to do it; the signups say who has AGREED. Assigning writes the
//  first and never the second, so an assigned person's chip stays orange
//  until they say yes themselves, and a leader can still see at a glance the
//  difference between a plan and a promise. Collapsing the two would make the
//  screen claim a team is ready when nobody has actually replied.
//
//  Reached by tapping a chip, which is where the question already lives:
//  "인도 미지정" asks who, and a person's chip asks what they are doing.
//

import SwiftUI

struct AssignRoleSheet: View {
    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss

    let service: TeamService
    /// The part the chip was about, when it was a part.
    let role: String?
    /// The person the chip was about, when it was a person.
    let person: String?
    let sheetId: String?

    @State private var pickedRole: String = ""
    @State private var pickedName: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var roles: [String] {
        // The Schedule tab's own columns are what can actually be written,
        // so they are what is offered. A role on the Roles tab with no column
        // would be a choice that fails on save.
        let columns = team.roleColumns.keys.sorted()
        guard columns.isEmpty else { return columns }
        return team.roles.map(\.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("파트", selection: $pickedRole) {
                        ForEach(roles, id: \.self) { Text($0).tag($0) }
                    }
                    // A pushed list rather than a dropdown menu: a roster
                    // runs to a dozen names and a part list to nearly as
                    // many, and a menu that long opens as a scrolling popover
                    // over the thing you are reading.
                    .pickerStyle(.navigationLink)
                } footer: {
                    if roles.isEmpty {
                        Text("Schedule 탭에 파트 열이 없습니다. 시트에 「인도」 같은 열을 추가한 뒤 새로 고쳐 주세요.")
                    }
                }

                Section {
                    Picker("사람", selection: $pickedName) {
                        Text("비워 두기").tag("")
                        ForEach(team.assignableNames, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    // Said plainly, because the orange chip that follows is
                    // otherwise read as the app failing to save.
                    Text("지정은 계획입니다. 본인이 직접 「가능」이라고 답하기 전까지는 확정으로 표시되지 않습니다.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(service.date.formatted(.dateTime.month().day()) + " " + service.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(isSaving || pickedRole.isEmpty)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .onAppear {
            pickedRole = role ?? roles.first ?? ""
            // Opening from a person's chip proposes that person; opening from
            // "인도 미지정" proposes nobody and asks.
            pickedName = person ?? currentHolder(of: pickedRole) ?? ""
        }
        .onChange(of: pickedRole) { _, new in
            // Switching part shows who already has it, so a leader does not
            // overwrite somebody without seeing them.
            guard person == nil else { return }
            pickedName = currentHolder(of: new) ?? ""
        }
    }

    private func currentHolder(of role: String) -> String? {
        service.assignments[role]
    }

    private func save() {
        guard let sheetId else {
            errorMessage = "팀 시트가 연결되어 있지 않습니다."
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            let failure = await team.assign(
                role: pickedRole,
                to: pickedName.isEmpty ? nil : pickedName,
                service: service,
                sheetId: sheetId
            )
            isSaving = false
            if let failure { errorMessage = failure } else { dismiss() }
        }
    }
}
