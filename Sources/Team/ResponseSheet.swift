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
                    // Horizontal, so a long roster scrolls sideways rather
                    // than turning the sheet into a list of parts.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(team.roles) { option in
                                let selected = option.id == chosen?.id
                                Button { role = option } label: {
                                    HStack(spacing: 4) {
                                        if option.isCore {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8))
                                        }
                                        Text(option.name)
                                    }
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        Capsule().fill(selected
                                                       ? Color.accentColor
                                                       : Color(.secondarySystemBackground))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("파트")
                } footer: {
                    Text("별표는 인도자와 반주자입니다. 이 두 파트가 비면 예배가 성립하지 않으므로 먼저 나옵니다.")
                }

                Section {
                    ForEach([SignupStatus.available, .declined, .away], id: \.rawValue) { status in
                        Button {
                            Task { await save(status) }
                        } label: {
                            HStack {
                                Circle().fill(tint(status)).frame(width: 10, height: 10)
                                Text(status.label).foregroundStyle(Color.primary)
                                Spacer()
                                if current?.status == status {
                                    Image(systemName: "checkmark").foregroundStyle(tint(status))
                                }
                            }
                        }
                        .disabled(isSaving || chosen == nil)
                    }
                } header: {
                    Text("응답")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\\(email) 으로 기록됩니다.")
                        Text("「가능」은 리더에게 알리는 것이고, 확정은 리더가 정합니다. 「자리비움」은 그 주에 아예 없다는 뜻이라 다시 묻지 않습니다.")
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
        .presentationDetents([.medium])
    }

    private func save(_ status: SignupStatus) async {
        guard let chosen, let sheetId = TeamSheetSource.current else { return }
        isSaving = true
        defer { isSaving = false }
        // Remembered for next time, since it is almost always the same.
        usualRole = chosen.name
        await team.setAvailability(
            status, service: service, role: chosen.name,
            email: email, name: name, sheetId: sheetId
        )
        if team.errorMessage == nil { dismiss() }
    }

    private func tint(_ status: SignupStatus) -> Color {
        switch status {
        case .available: return .green
        case .declined:  return .red
        case .away:      return .orange
        }
    }
}
