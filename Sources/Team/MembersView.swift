//
//  MembersView.swift
//  SolaPraise
//
//  The roster: who counts as a team member.
//
//  This list does two things, and only one of them is protection. It decides
//  who sees the 예배 준비 tab, and it is what makes "아직 답하지 않은 사람"
//  answerable at all — without a roster the app knows who replied but not who
//  was asked. What actually keeps the team's information private is the
//  sheet's own sharing.
//
//  Addresses here are the ones people sign into the APP with, which is
//  usually their personal account rather than the church one that owns the
//  document.
//

import SwiftUI

struct MembersView: View {
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager

    @State private var email = ""
    @State private var name = ""
    @State private var isWorking = false

    private var sheetId: String? { TeamSheetSource.current }

    var body: some View {
        List {
            Section {
                TextField("이메일", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                TextField("이름 (선택)", text: $name)

                Button {
                    Task { await add() }
                } label: {
                    HStack {
                        Label("팀원 추가", systemImage: "person.badge.plus")
                        Spacer()
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!email.contains("@") || isWorking)
            } header: {
                Text("추가")
            } footer: {
                Text("앱에 로그인할 때 쓰는 주소를 넣으세요. 시트를 소유한 교회 계정이 아니라 각자의 개인 계정입니다. 그 주소가 시트를 편집할 수 있어야 사인업이 저장됩니다.")
            }

            Section {
                if team.members.isEmpty {
                    Text("아직 명단이 비어 있습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(team.members) { member in
                        row(member)
                    }
                }
            } header: {
                HStack {
                    Text("명단")
                    Spacer()
                    Text("^[\(team.members.filter(\.isActive).count) person](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let message = team.errorMessage {
                    Text(message).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("팀원")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { if let sheetId { await team.load(sheetId: sheetId) } }
    }

    private func row(_ member: TeamStore.Member) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name.isEmpty ? member.email : member.name)
                    .font(.subheadline)
                    .foregroundStyle(member.isActive ? Color.primary : .secondary)
                if !member.name.isEmpty {
                    Text(member.email).font(.caption2).foregroundStyle(.secondary)
                }
                if member.email.caseInsensitiveCompare(auth.email ?? "") == .orderedSame {
                    Text("이 기기에 로그인한 계정")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            // Deactivated rather than deleted: removing the row would orphan
            // every signup this person has already made.
            Toggle("", isOn: Binding(
                get: { member.isActive },
                set: { value in
                    guard let sheetId else { return }
                    Task { await team.setMemberActive(value, member: member, sheetId: sheetId) }
                }
            ))
            .labelsHidden()
        }
    }

    private func add() async {
        guard let sheetId else { return }
        isWorking = true
        defer { isWorking = false }
        await team.addMember(
            email: email,
            name: name.trimmingCharacters(in: .whitespaces),
            sheetId: sheetId
        )
        if team.errorMessage == nil { email = ""; name = "" }
    }
}
