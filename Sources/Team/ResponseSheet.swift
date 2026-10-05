//
//  ResponseSheet.swift
//  SolaPraise
//
//  Answering for one service: which part, and whether you can do it.
//
//  Small on purpose. Answering is the thing most of the team will ever do in
//  this tab, usually several weeks at a sitting when the month goes up, so it
//  opens over the schedule and closes straight back to it rather than
//  navigating anywhere.
//

import SwiftUI

struct ResponseSheet: View {
    let service: TeamService

    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @Environment(\.dismiss) private var dismiss

    @State private var role: TeamRole?
    @State private var isSaving = false

    private var email: String { team.actingEmail(auth: auth, planning: planning) ?? "" }
    private var name: String { planning.isSignedIn ? (planning.email ?? email)
                                                   : (auth.displayName ?? email) }

    /// The part already answered for, then the one usually played, then
    /// whatever is first.
    ///
    /// Most people serve the same part every time. Making them pick it again
    /// each week is the sort of friction that turns answering into something
    /// done later and then not at all.
    private var chosen: TeamRole? {
        role
            ?? team.roles.first { team.mySignup(for: service, role: $0.name, email: email) != nil }
            ?? team.roles.first { $0.name == usualRole }
            ?? team.roles.first
    }

    @AppStorage("team.usualRole") private var usualRole = ""
    private var current: TeamSignup? {
        chosen.flatMap { team.mySignup(for: service, role: $0.name, email: email) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Choosing a part IS the answer. Asking for a part and
                    // then separately for 가능 made people say the same
                    // thing twice, and the pair could disagree.
                    ForEach(team.roles) { option in
                        Button {
                            Task { await save(.available, role: option) }
                        } label: {
                            HStack(spacing: 8) {
                                if option.isCore {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.yellow)
                                }
                                Text(option.name).foregroundStyle(Color.primary)
                                Spacer()
                                if taken(option).isEmpty == false {
                                    Text(taken(option).joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if current?.role == option.name,
                                   current?.status == .available {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(isSaving)
                    }
                } header: {
                    Text("맡을 파트")
                } footer: {
                    Text("파트를 누르면 그대로 저장됩니다. 별표는 인도자와 반주자입니다. 옆의 이름은 이미 그 파트를 맡겠다고 한 사람입니다.")
                }

                Section {
                    Button {
                        Task { await save(.declined, role: chosen) }
                    } label: {
                        HStack {
                            Circle().fill(Color.red).frame(width: 10, height: 10)
                            Text("이번 주는 어려움").foregroundStyle(Color.primary)
                            Spacer()
                            if current?.status == .declined {
                                Image(systemName: "checkmark").foregroundStyle(.red)
                            }
                        }
                    }
                    Button {
                        Task { await save(.away, role: chosen) }
                    } label: {
                        HStack {
                            Circle().fill(Color.orange).frame(width: 10, height: 10)
                            Text("자리비움").foregroundStyle(Color.primary)
                            Spacer()
                            if current?.status == .away {
                                Image(systemName: "checkmark").foregroundStyle(.orange)
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(email) 으로 기록됩니다.")
                        Text("「자리비움」은 그 주에 아예 없다는 뜻이라 다시 묻지 않습니다.")
                    }
                }

                // Withdrawing has to be as easy as answering, or the first
                // answer becomes one people hesitate over. Only offered once
                // there is something to withdraw.
                if let current {
                    Section {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.uturn.backward")
                                Text("응답 취소 (미지정으로)")
                                Spacer()
                            }
                        }
                    } footer: {
                        Text("이 주에 대한 내 응답을 지웁니다. 다시 답할 수 있습니다.")
                    }
                }

                if let message = team.errorMessage {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(service.date.formatted(.dateTime.month().day().weekday()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Button("닫기") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Who has already said they will take this part.
    private func taken(_ role: TeamRole) -> [String] {
        team.signupsAll(for: service, role: role.name)
            .filter { $0.status == .available }
            .filter { $0.email.caseInsensitiveCompare(email) != .orderedSame }
            .map { $0.name.isEmpty ? $0.email : $0.name }
    }

    private func save(_ status: SignupStatus, role: TeamRole?) async {
        guard let role, let sheetId = TeamSheetSource.current else { return }
        isSaving = true
        defer { isSaving = false }
        // Remembered for next time, since it is almost always the same.
        if status == .available { usualRole = role.name }
        await team.setAvailability(
            status, service: service, role: role.name,
            email: email, name: name, sheetId: sheetId
        )
        if team.errorMessage == nil { dismiss() }
    }

    private func clear() async {
        guard let sheetId = TeamSheetSource.current else { return }
        isSaving = true
        defer { isSaving = false }
        await team.clearAvailability(
            service: service, email: email, sheetId: sheetId
        )
        if team.errorMessage == nil { dismiss() }
    }
}
