//
//  SheetHealthView.swift
//  SolaPraise
//
//  워크플로 점검 — the audit's findings as a checklist, with the fix next to
//  each one that has a fix.
//
//  Opened from the pinned line in 예배 준비 when something needs attention,
//  and from the sheet links at the bottom at any time, so "is everything
//  set up right?" has an answer even when the answer is yes.
//

import SwiftUI

struct SheetHealthView: View {
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @Environment(\.dismiss) private var dismiss

    let sheetId: String?
    @State private var working = false
    @State private var note: String?

    private var findings: [SheetAudit.Finding] {
        team.audit(accounts: Self.accounts(auth: auth, planning: planning))
    }

    /// Who is signed in as what, for the audit. Shared with ServicePrepView
    /// so the pinned line and this screen can never disagree.
    @MainActor
    static func accounts(auth: GoogleAuthManager, planning: PlanningAuth) -> SheetAudit.Accounts {
        SheetAudit.Accounts(
            mainEmail: auth.email,
            mainHasYouTube: auth.isSignedIn && auth.hasGranted("https://www.googleapis.com/auth/youtube"),
            churchEmail: planning.isSignedIn ? planning.email : nil,
            churchSheetConfigured: ChurchSheetSource.current != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                let all = findings
                let attention = SheetAudit.needsAttention(all)
                Section {
                    Label(attention.isEmpty ? "확인할 문제가 없습니다"
                                            : "확인이 필요한 항목 \(attention.count)개",
                          systemImage: attention.isEmpty ? "checkmark.seal.fill"
                                                         : "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(attention.isEmpty ? .green : .orange)
                    if let loaded = team.lastLoaded {
                        Text("마지막으로 시트를 읽은 때: \(loaded.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("시트와 계정 설정을 읽기만 해서 점검합니다. 고치는 버튼은 누를 때만 시트를 바꿉니다.")
                }

                ForEach(areas(all), id: \.self) { area in
                    Section(area) {
                        ForEach(all.filter { $0.area == area }) { finding in
                            row(finding)
                        }
                    }
                }
            }
            .navigationTitle("워크플로 점검")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await reload() }
                    } label: {
                        if working { ProgressView() } else { Label("다시 점검", systemImage: "arrow.clockwise") }
                    }
                    .disabled(working || sheetId == nil)
                }
            }
            .alert("워크플로 점검", isPresented: .constant(note != nil)) {
                Button("확인") { note = nil }
            } message: {
                Text(note ?? "")
            }
        }
    }

    /// Areas in the order the findings put them — worst first.
    private func areas(_ findings: [SheetAudit.Finding]) -> [String] {
        var seen: [String] = []
        for finding in findings where !seen.contains(finding.area) { seen.append(finding.area) }
        return seen
    }

    @ViewBuilder
    private func row(_ finding: SheetAudit.Finding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(finding.title).font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: symbol(finding.severity))
                    .foregroundStyle(tint(finding.severity))
            }
            if !finding.detail.isEmpty {
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fix = finding.fix {
                Button {
                    Task { await apply(fix) }
                } label: {
                    Text(label(fix)).font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(working || (needsSheet(fix) && (sheetId == nil || team.isReadOnly)))
            }
        }
        .padding(.vertical, 2)
    }

    private func symbol(_ severity: SheetAudit.Severity) -> String {
        switch severity {
        case .ok:      return "checkmark.circle.fill"
        case .note:    return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    private func tint(_ severity: SheetAudit.Severity) -> Color {
        switch severity {
        case .ok:      return .green
        case .note:    return .secondary
        case .warning: return .orange
        case .problem: return .red
        }
    }

    private func label(_ fix: SheetAudit.Fix) -> String {
        switch fix {
        case .repairShiftedRows:     return "제자리로 옮기기"
        case .repairDuplicates:      return "중복 정리"
        case .connectChurchAccount:  return "교회 계정 연결"
        case .signInMain:            return "YouTube 계정으로 로그인"
        }
    }

    private func needsSheet(_ fix: SheetAudit.Fix) -> Bool {
        fix == .repairShiftedRows || fix == .repairDuplicates
    }

    private func apply(_ fix: SheetAudit.Fix) async {
        working = true
        defer { working = false }
        switch fix {
        case .repairShiftedRows:
            guard let sheetId else { return }
            note = await team.repairDamagedSongRows(sheetId: sheetId)
        case .repairDuplicates:
            guard let sheetId else { return }
            note = await team.repairDuplicateSongs(sheetId: sheetId)
        case .connectChurchAccount:
            await planning.signIn()
            team.configure(auth: auth, planning: planning)
            await reload()
        case .signInMain:
            await auth.signIn()
            team.configure(auth: auth, planning: planning)
            await reload()
        }
    }

    private func reload() async {
        guard let sheetId else { return }
        working = true
        defer { working = false }
        await team.load(sheetId: sheetId)
    }
}
