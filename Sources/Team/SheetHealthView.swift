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
import SwiftData

struct SheetHealthView: View {
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.modelContext) private var modelContext
    @State private var confirmingTitles = false
    @State private var confirmingGrid = false
    @State private var confirmingWeek = false
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
                    // What to look at, said here — the count alone left the
                    // reader hunting through the sections below for it.
                    ForEach(attention) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: finding.severity == .problem ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.severity == .problem ? .red : .orange)
                                .font(.caption)
                            Text("\(finding.area) · \(finding.title)")
                                .font(.callout)
                        }
                    }
                    if let loaded = team.lastLoaded {
                        Text("마지막으로 시트를 읽은 때: \(loaded.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("시트와 계정 설정을 읽기만 해서 점검합니다. 고치는 버튼은 누를 때만 시트를 바꿉니다.")
                }

                // The sheet usable on its own: members answer on it without
                // the app. What would change is listed before it is asked.
                Section {
                    let plan = team.gridSetupPreview()
                    if team.rawGrid != nil, plan.isEmpty {
                        Label("멤버가 시트의 「응답」 탭에서 바로 응답할 수 있습니다", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(plan, id: \.self) { line in
                            Text(line).font(.callout)
                        }
                        Button {
                            confirmingGrid = true
                        } label: {
                            Label(team.rawGrid != nil ? "응답 탭 정리" : "시트를 멤버용으로 정리", systemImage: "tablecells.badge.ellipsis")
                        }
                        .disabled(working || sheetId == nil || team.isReadOnly)
                    }
                } header: {
                    Text("시트에서 바로 응답")
                } footer: {
                    Text("앱이 없어도 팀원이 시트만 열어 예배마다 가능 · 미정 · 어려움 · 자리비움을 고를 수 있게 합니다. 앱도 같은 칸을 읽고 씁니다.")
                }

                // One page for the next service, built from formulas.
                Section {
                    Button {
                        confirmingWeek = true
                    } label: {
                        Label(team.hasWeekTab ? "「이번 주」 탭 다시 만들기" : "「이번 주」 탭 만들기", systemImage: "calendar.day.timeline.left")
                    }
                    .disabled(working || sheetId == nil || team.isReadOnly)
                } header: {
                    Text("시트에서 이번 주 보기")
                } footer: {
                    Text("다음 예배의 시간 · 콘티 PDF · 파트별 배정 · 곡(키 · 메모 · 팀 메모 · 영상 · 고른 악보)을 시트의 한 탭에 수식으로 모읍니다. 앱 없이도 매주 다음 예배로 저절로 넘어갑니다. 열이 바뀌었으면 다시 만들면 됩니다.")
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
            .confirmationDialog("「이번 주」 탭을 만들까요?", isPresented: $confirmingWeek, titleVisibility: .visible) {
                Button(team.hasWeekTab ? "다시 만들기" : "만들기") { Task { await prepareWeek() } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("팀 시트에 「이번 주」 탭을 \(team.hasWeekTab ? "다시 씁니다 — 그 탭에 손으로 적은 것은 지워집니다" : "더합니다"). 다른 탭은 바꾸지 않습니다.")
            }
            .confirmationDialog("팀 시트를 바꿀까요?", isPresented: $confirmingGrid, titleVisibility: .visible) {
                Button("정리하기") { Task { await prepareGrid() } }
                Button("취소", role: .cancel) {}
            } message: {
                Text(team.gridSetupPreview().joined(separator: "\n") + "\n\n팀 전체가 쓰는 문서입니다. 기존 탭의 내용은 지우지 않습니다.")
            }
            .confirmationDialog("곡 제목을 정리할까요?", isPresented: $confirmingTitles, titleVisibility: .visible) {
                Button("정리하기") { Task { await tidyTitles() } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("Songs 탭의 Title을 곡 제목만 남기고(찬송가는 장 번호와 함께), 팀·앨범·연도는 새 「참고버전」 열에 적습니다. Key·Transpose는 Title 바로 옆으로 옮깁니다. Attachments 탭의 곡 이름과 파일 이름도 맞춥니다. 링크·키·메모 같은 다른 칸은 그대로이고, 이미 적힌 참고버전은 덮어쓰지 않습니다.")
            }
        }
    }

    private func prepareWeek() async {
        guard let sheetId else { return }
        working = true
        defer { working = false }
        note = await team.prepareWeekTab(sheetId: sheetId)
            ?? "「이번 주」 탭을 만들었습니다. 팀원에게 시트에서 이 탭만 열면 된다고 알려 주세요."
    }

    private func prepareGrid() async {
        guard let sheetId else { return }
        working = true
        defer { working = false }
        note = await team.prepareGrid(sheetId: sheetId)
            ?? "정리했습니다. 팀원에게 「응답」 탭에서 자기 이름 칸을 고르면 된다고 알려 주세요."
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
        case .tidySongTitles:        return "곡 제목 정리"
        case .connectChurchAccount:  return "교회 계정 연결"
        case .signInMain:            return "YouTube 계정으로 로그인"
        }
    }

    private func needsSheet(_ fix: SheetAudit.Fix) -> Bool {
        fix == .repairShiftedRows || fix == .repairDuplicates || fix == .tidySongTitles
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
        case .tidySongTitles:
            // Asked first: it moves the team's columns.
            confirmingTitles = true
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

    /// Each song's channel, which tells a team's name from the song in a
    /// video's title: from the videos this device has, then one YouTube
    /// call for the rest (1 unit for fifty).
    private func tidyTitles() async {
        guard let sheetId else { return }
        working = true
        defer { working = false }
        let header = team.rawSongs?.first ?? []
        let urlColumn = TeamSheet.column(header, ["youtubeurl", "url", "link", "링크", "영상"])
        let ids = Set((team.rawSongs ?? []).dropFirst().compactMap { row -> String? in
            guard let urlColumn, row.indices.contains(urlColumn) else { return nil }
            return TeamSheet.videoKey(row[urlColumn])
        })
        var channels: [String: String] = [:]
        for id in ids {
            let descriptor = FetchDescriptor<CachedVideo>(predicate: #Predicate { $0.videoId == id })
            if let title = (try? modelContext.fetch(descriptor))?.first?.channelTitle { channels[id] = title }
        }
        let missing = ids.filter { channels[$0] == nil }
        if !missing.isEmpty,
           let found = try? await AppServices.client(auth: auth, quota: quota).videos(ids: Array(missing)) {
            for video in found { if let title = video.snippet?.channelTitle { channels[video.id] = title } }
        }
        note = await team.tidySongTitles(sheetId: sheetId, channels: channels)
    }

    private func reload() async {
        guard let sheetId else { return }
        working = true
        defer { working = false }
        await team.load(sheetId: sheetId)
    }
}
