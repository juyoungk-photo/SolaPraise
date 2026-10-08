//
//  AssignRoleSheet.swift
//  SolaPraise
//
//  Putting somebody's name against a part — 수형 to 인도 for next Sunday.
//
//  ONE TAP, NOT THREE. A chip already carries half the question: tapping a
//  person asks "doing what?", tapping 「인도 미지정」 asks "who?". So the sheet
//  opens straight onto the list of whichever half is missing, and choosing
//  from it saves and closes. The two-picker form this replaces made you open
//  a picker to answer a question the chip had already asked.
//
//  WHAT THIS IS NOT: it is not answering for them. The schedule says who is
//  MEANT to do it; the signups say who has AGREED. Assigning writes the first
//  and never the second, so an assigned person's chip stays orange until they
//  say yes themselves, and a leader can still see the difference between a
//  plan and a promise. Collapsing the two would make the screen claim a team
//  is ready when nobody has actually replied.
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

    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Which half the chip left open.
    private enum Mode { case pickPart(String), pickPerson(String) }

    private var mode: Mode {
        if let person, role == nil { return .pickPart(person) }
        if let role { return .pickPerson(role) }
        // A chip always carries one or the other; this is only a fallback.
        return .pickPerson(parts.first ?? "")
    }

    /// The Schedule tab's own columns are what can actually be written, so
    /// they are what is offered. A part on the Roles tab with no column would
    /// be a choice that fails on save.
    private var parts: [String] {
        let columns = team.roleColumns.keys.sorted()
        guard columns.isEmpty else { return columns }
        return team.roles.map(\.name)
    }

    var body: some View {
        NavigationStack {
            List {
                switch mode {
                case .pickPart(let who):    partSection(for: who)
                case .pickPerson(let part): personSection(for: part)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView().controlSize(.large) } }
        }
    }

    private var title: String {
        let day = service.date.formatted(.dateTime.month().day())
        switch mode {
        case .pickPart(let who):    return "\(day) · \(who)"
        case .pickPerson(let part): return "\(day) · \(part)"
        }
    }

    // MARK: - Tapped a person: which part?

    @ViewBuilder
    private func partSection(for who: String) -> some View {
        Section {
            ForEach(parts, id: \.self) { part in
                row(title: part,
                    subtitle: holder(of: part).flatMap { $0 == who ? nil : "현재 \($0)" },
                    isCurrent: holder(of: part) == who) {
                    save(role: part, name: who)
                }
            }
        } footer: {
            Text("지정은 계획입니다. 본인이 직접 「가능」이라고 답하기 전까지는 확정으로 표시되지 않습니다.")
        }

        if let held = parts.first(where: { holder(of: $0) == who }) {
            Section {
                Button(role: .destructive) {
                    save(role: held, name: nil)
                } label: {
                    Label("\(held)에서 빼기", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: - Tapped a part: who?

    @ViewBuilder
    private func personSection(for part: String) -> some View {
        Section {
            ForEach(team.assignableNames, id: \.self) { name in
                row(title: name,
                    subtitle: otherPart(of: name, besides: part).map { "현재 \($0)" },
                    isCurrent: holder(of: part) == name) {
                    save(role: part, name: name)
                }
            }
        } footer: {
            Text("지정은 계획입니다. 본인이 직접 「가능」이라고 답하기 전까지는 확정으로 표시되지 않습니다.")
        }

        if holder(of: part) != nil {
            Section {
                Button(role: .destructive) {
                    save(role: part, name: nil)
                } label: {
                    Label("\(part) 비우기", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: - Row

    private func row(title: String,
                     subtitle: String?,
                     isCurrent: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.primary)
                    // Says who would be displaced, before displacing them.
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: - Reading the current plan

    /// Who holds a part, through the alias rule — so a sheet that staffs
    /// Piano answers for 반주.
    private func holder(of part: String) -> String? {
        if let exact = service.assignments[part]?.trimmingCharacters(in: .whitespaces),
           !exact.isEmpty { return exact }
        return service.assignments.first {
            PartAliases.matches($0.key, part)
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }?.value
    }

    /// Another part this person already has, so putting them somewhere new
    /// does not quietly double-book them.
    private func otherPart(of name: String, besides part: String) -> String? {
        parts.first { $0 != part && holder(of: $0) == name }
    }

    // MARK: - Writing

    private func save(role: String, name: String?) {
        guard let sheetId else {
            errorMessage = "팀 시트가 연결되어 있지 않습니다."
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            let failure = await team.assign(
                role: role, to: name, service: service, sheetId: sheetId
            )
            isSaving = false
            if let failure { errorMessage = failure } else { dismiss() }
        }
    }
}
