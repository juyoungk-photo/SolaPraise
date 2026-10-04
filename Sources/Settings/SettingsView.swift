//
//  SettingsView.swift
//  SolaPraise
//
//  Channel whitelist, quota visibility, account.
//  Topic searches arrive with Phase 4.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var channels: [Channel]

    @State private var addingFor: Purpose?
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @State private var notificationsOn = ReadingSettings.notificationsEnabled
    @State private var esvKey = ReadingSettings.esvAPIKey ?? ""
    @State private var apiBibleKey = ReadingSettings.apiBibleKey ?? ""
    @State private var extraVersion = ReadingSettings.extraVersion
    @State private var availableVersions: [APIBibleClient.Version] = []
    @State private var isLoadingVersions = false
    @State private var versionsError: String?
    @State private var teamSheetInput = ReadingSettings.teamSheetId ?? ""
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var planning: PlanningAuth
    @StateObject private var feed = FeedStore()
    @State private var refreshNote: String?
    @State private var notifyTime: Date = {
        var c = DateComponents()
        c.hour = ReadingSettings.notifyHour
        c.minute = ReadingSettings.notifyMinute
        return Calendar.current.date(from: c) ?? Date()
    }()

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Purpose.allCases) { purpose in
                    channelSection(for: purpose)
                }
                appearanceSection
                readingSection
                refreshSection
                todaySection
                accountSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $addingFor) { purpose in
                AddChannelView(defaultPurpose: purpose)
            }
        }
    }

    // MARK: - Channels

    private func channelSection(for purpose: Purpose) -> some View {
        let items = channels.filter { $0.purposeRaw == purpose.rawValue }

        return Section {
            ForEach(items) { channel in
                ChannelRow(
                    channel: channel,
                    onTogglePin: { togglePin(channel, in: purpose) }
                )
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(items[index]) }
                try? modelContext.save()
            }
            .onMove { offsets, destination in
                var reordered = items
                reordered.move(fromOffsets: offsets, toOffset: destination)
                // Rewrite sortOrder so the new arrangement survives relaunch.
                for (index, channel) in reordered.enumerated() {
                    channel.sortOrder = index
                }
                try? modelContext.save()
            }

            Button {
                addingFor = purpose
            } label: {
                Label("Add channel", systemImage: "plus")
            }
        } header: {
            Label(purpose.title, systemImage: purpose.symbolName)
        } footer: {
            if purpose == .word && !items.isEmpty {
                Text("핀으로 표시한 채널의 최신 영상이 말씀 탭 맨 위 큰 카드가 됩니다. 편집을 눌러 순서를 바꿀 수 있습니다.")
            }
        }
    }

    /// Exactly one channel per purpose may be pinned — tapping a new one
    /// releases the old.
    private func togglePin(_ channel: Channel, in purpose: Purpose) {
        let wasPinned = channel.isPinned
        for other in channels where other.purposeRaw == purpose.rawValue {
            other.isPinned = false
        }
        channel.isPinned = !wasPinned
        try? modelContext.save()
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("테마", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("화면")
        } footer: {
            Text("시스템을 고르면 기기 설정을 따라갑니다.")
        }
    }

    // MARK: - Reading

    @ViewBuilder
    private var readingSection: some View {
        Section {
            Toggle("아침 알림", isOn: Binding(
                get: { notificationsOn },
                set: { newValue in
                    notificationsOn = newValue
                    ReadingSettings.notificationsEnabled = newValue
                    Task {
                        if newValue {
                            let granted = await ReadingNotifications.requestAuthorization()
                            if granted {
                                await ReadingNotifications.schedule()
                            } else {
                                // Permission refused at the system level —
                                // don't leave a toggle claiming it's on.
                                notificationsOn = false
                                ReadingSettings.notificationsEnabled = false
                            }
                        } else {
                            ReadingNotifications.cancel()
                        }
                    }
                }
            ))

            if notificationsOn {
                DatePicker(
                    "알림 시간",
                    selection: Binding(
                        get: { notifyTime },
                        set: { newValue in
                            notifyTime = newValue
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            ReadingSettings.notifyHour = parts.hour ?? 6
                            ReadingSettings.notifyMinute = parts.minute ?? 30
                            Task { await ReadingNotifications.schedule() }
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }

            SecureField("ESV API key", text: Binding(
                get: { esvKey },
                set: { esvKey = $0; ReadingSettings.esvAPIKey = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Link("api.esv.org에서 무료 키 만들기",
                 destination: URL(string: "https://api.esv.org/account/create-application/")!)
                .font(.footnote)
        } header: {
            Text("시편 읽기")
        } footer: {
            Text("한글은 개역한글(저작권 만료)이 앱에 포함되어 오프라인에서도 열립니다. 영문 ESV는 Crossway API로 불러오며 무료 키가 필요합니다. 비상업용 — 유료도 광고도 없는 앱에만 허용되며, 이 앱은 해당됩니다. 한 번에 500절, 저장도 500절까지이고, 본문을 보여주는 화면마다 저작권 표기와 esv.org 링크가 함께 나옵니다.")
        }

        extraTranslationSection
        teamSheetSection
    }

    // MARK: - Team sheet

    /// Where 예배 준비 gets its data, and the only thing the leader has to
    /// set up for the team.
    @ViewBuilder
    private var teamSheetSection: some View {
        Section {
            TextField("Google Sheets 주소 붙여넣기", text: $teamSheetInput, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote)

            HStack {
                if let id = TeamAccess.sheetId(from: teamSheetInput), !teamSheetInput.isEmpty {
                    Text(id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if !teamSheetInput.isEmpty {
                    Text("시트 주소를 알아볼 수 없습니다")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button("저장") {
                    ReadingSettings.teamSheetId = TeamAccess.sheetId(from: teamSheetInput)
                    Task {
                        team.configure(auth: auth, planning: planning)
                        if let id = ReadingSettings.teamSheetId {
                            await team.load(sheetId: id)
                        }
                    }
                }
                .font(.caption)
                .disabled(TeamAccess.sheetId(from: teamSheetInput) == nil)
            }

            if TeamSheetSource.current != nil {
                Button("연결 해제", role: .destructive) {
                    ReadingSettings.teamSheetId = nil
                    teamSheetInput = ""
                }
                .font(.caption)
            }

            if auth.isSignedIn {
                Button {
                    Task {
                        _ = await auth.requestScopes(
                            ["https://www.googleapis.com/auth/spreadsheets"]
                        )
                        if let id = TeamSheetSource.current { await team.load(sheetId: id) }
                    }
                } label: {
                    Label("시트 권한 다시 요청", systemImage: "lock.rotation")
                }
                .font(.caption)

                Button {
                    Task {
                        auth.signOut()
                        await auth.signIn()
                        if let id = TeamSheetSource.current { await team.load(sheetId: id) }
                    }
                } label: {
                    Label("로그아웃 후 다시 로그인", systemImage: "arrow.clockwise")
                }
                .font(.caption)
            }

            if TeamSheetSource.current != nil, auth.isSignedIn {
                NavigationLink {
                    MembersView()
                } label: {
                    Label("팀원 명단", systemImage: "person.2")
                }
            }

            // The tab's absence used to be unexplained, and the thing that
            // explains it lives behind the tab.
            if TeamSheetSource.current == nil {
                Text("「예배」 탭: 팀 시트를 연결하면 나타납니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !auth.isSignedIn {
                Text("「예배」 탭: Google 로그인이 필요합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // A second account, for the sheet alone.
            if planning.isSignedIn, let address = planning.email {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(address).font(.caption)
                        Text("플래닝 계정").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("연결 해제") {
                        planning.signOut()
                        team.configure(auth: auth, planning: planning)
                    }
                    .font(.caption)
                }
            } else {
                Button {
                    Task {
                        await planning.signIn()
                        team.configure(auth: auth, planning: planning)
                        if let id = TeamSheetSource.current { await team.load(sheetId: id) }
                    }
                } label: {
                    Label("다른 계정으로 시트 연결", systemImage: "person.2.badge.key")
                }
                .font(.caption)
            }
            if let message = planning.lastError {
                Text(message).font(.caption2).foregroundStyle(.orange)
            }

            if let message = team.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("팀 시트")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // The one address that matters, stated plainly.
                //
                // The sheet is commonly owned by the church's account while
                // the app is signed in personally, and the app holds only one
                // account — so this is the address that must be able to read
                // and write the sheet, and the one that belongs on Members.
                // Leaving it implicit meant sharing with the wrong address and
                // wondering why nothing changed.
                if let email = team.actingEmail(auth: auth, planning: planning) {
                    (Text("시트에 접근하는 계정: ").foregroundStyle(.secondary)
                     + Text(email).bold()
                     + Text(planning.isSignedIn ? " (플래닝 계정)" : "").foregroundStyle(.secondary))
                        .font(.caption)
                } else {
                    Text("로그인하지 않아 시트를 열 수 없습니다.").font(.caption)
                }
                Text("시트가 교회 계정 소유라도 상관없습니다. 위 주소가 그 시트를 편집할 수 있으면 됩니다. 교회 계정으로 기록을 남기고 싶으면 「다른 계정으로 시트 연결」을 쓰세요 — YouTube 로그인은 그대로 둔 채 시트만 다른 계정으로 씁니다.")
                Text("Schedule · Roles · Songs · Signups 탭이 필요하고, Members 탭에는 앱에 로그인하는 주소를 적습니다. Members 탭이 없으면 시트를 열 수 있는 사람 모두에게 「예배」 탭이 보입니다 — 실제로 지키는 것은 이 목록이 아니라 구글 시트의 공유 설정입니다.")
            }
        }
    }

    // MARK: - A third translation

    /// NASB, NIV and the rest come from API.Bible, whose catalogue depends on
    /// the reader's own key — so the list is fetched rather than hardcoded.
    /// 새번역 and 개역개정 are not in it at any tier: 대한성서공회 licenses
    /// those directly and publishes no developer API.
    @ViewBuilder
    private var extraTranslationSection: some View {
        Section {
            SecureField("API.Bible key", text: Binding(
                get: { apiBibleKey },
                set: { apiBibleKey = $0; ReadingSettings.apiBibleKey = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Link("Get a free key at scripture.api.bible",
                 destination: URL(string: "https://scripture.api.bible/")!)
                .font(.footnote)

            if let chosen = extraVersion {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chosen.abbreviation).font(.subheadline.weight(.semibold))
                        Text("\(chosen.name) · \(chosen.language)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("해제") {
                        extraVersion = nil
                        ReadingSettings.extraVersion = nil
                    }
                    .font(.caption)
                }
            }

            if !apiBibleKey.isEmpty {
                Button {
                    Task { await loadVersions() }
                } label: {
                    HStack {
                        Text(availableVersions.isEmpty ? "번역본 불러오기" : "목록 새로고침")
                        Spacer()
                        if isLoadingVersions { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isLoadingVersions)
            }

            if let message = versionsError {
                Text(message).font(.caption).foregroundStyle(.orange)
            }

            if !availableVersions.isEmpty {
                Picker("번역본", selection: Binding(
                    get: { extraVersion?.id ?? "" },
                    set: { id in
                        let match = availableVersions.first { $0.id == id }
                        extraVersion = match
                        ReadingSettings.extraVersion = match
                    }
                )) {
                    Text("선택 안 함").tag("")
                    ForEach(availableVersions) { version in
                        Text("\(version.abbreviation) — \(version.language)").tag(version.id)
                    }
                }
            }
        } header: {
            Text("번역본 추가")
        } footer: {
            Text("NASB·NIV 등은 API.Bible 키로 불러올 수 있으며, 어떤 번역본이 보이는지는 키의 플랜에 따라 다릅니다. NIV는 상업적 사용이 허용되지 않습니다. 새번역과 개역개정은 대한성서공회가 직접 허락하는 저작물이라 어떤 API로도 받을 수 없고, 공회에 사용 허가를 신청해야 합니다.")
        }
    }

    private func loadVersions() async {
        isLoadingVersions = true
        versionsError = nil
        defer { isLoadingVersions = false }
        do {
            availableVersions = try await APIBibleClient().versions()
            if availableVersions.isEmpty {
                versionsError = "이 키로 사용할 수 있는 번역본이 없습니다."
            }
        } catch {
            versionsError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Manual refresh

    private var refreshSection: some View {
        Section {
            Button {
                Task { await runRefresh() }
            } label: {
                HStack {
                    Label("채널 새로고침", systemImage: "arrow.clockwise")
                    Spacer()
                    if feed.isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(feed.isRefreshing)

            if let refreshNote {
                Text(refreshNote).font(.caption).foregroundStyle(.secondary)
            }
            if let message = feed.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("채널")
        } footer: {
            Text(auth.isSignedIn
                 ? "로그인되어 있어 YouTube API로 영상을 가져옵니다. 시편 읽기 채널은 처음 한 번만 깊게(최대 1000개) 받아오며 약 20 units를 사용합니다."
                 : "로그인하면 영상 목록을 안정적으로 가져오고, 시편 듣기 카드에 필요한 과거 영상까지 받아옵니다. 로그인 전에는 불안정한 RSS만 사용합니다.")
        }
    }

    private func runRefresh() async {
        refreshNote = nil
        let client = auth.isSignedIn ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: nil, context: modelContext, client: client)
        let count = (try? modelContext.fetchCount(FetchDescriptor<CachedVideo>())) ?? 0
        refreshNote = "저장된 영상 \(count)개"
    }

    // MARK: - Today

    private var todaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API budget")
                    Spacer()
                    Text("\(quota.unitsUsed.formatted()) / \(QuotaLedger.dailyUnitLimit.formatted())")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, quota.fractionUsed))
                    .tint(quota.fractionUsed > 0.85 ? .orange : .accentColor)
            }
            .padding(.vertical, 2)

            HStack {
                Text("Searches")
                Spacer()
                Text("\(quota.searchesUsed) of \(QuotaLedger.dailySearchLimit) used")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Today")
        } footer: {
            Text("Resets at midnight Pacific. Channel updates use the free RSS feed and cost nothing; each general search costs 100 units and each playlist edit 50.")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                if let url = auth.avatarURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(.quaternary)
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let name = auth.displayName {
                        Text(name).font(.body)
                    }
                    if let email = auth.email {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)

            if auth.isSignedIn {
                Button("Sign out", role: .destructive) {
                    auth.signOut()
                    dismiss()
                }
            } else {
                // Browsing without an account is a starting point, not a
                // one-way door: the playlist half of the app is still here
                // and signing in is what turns it on.
                Button {
                    Task { await auth.signIn() }
                } label: {
                    Label("Google 계정으로 로그인", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: {
            Text("계정")
        } footer: {
            Text(auth.isSignedIn
                 ? "내 재생목록을 보고, 곡을 추가하고, 순서를 바꿀 수 있습니다."
                 : "로그인하면 내 YouTube 재생목록을 이 앱에서 보고 편집할 수 있습니다. 나머지 기능은 로그인 없이도 그대로 동작합니다.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.shortVersion)
        } footer: {
            Text("Topic searches arrive in a later phase.")
        }
    }
}

// MARK: - Row

private struct ChannelRow: View {
    let channel: Channel
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let url = channel.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(.quaternary)
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.title).font(.body).lineLimit(1)
                if let handle = channel.handle {
                    Text(handle).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: onTogglePin) {
                Image(systemName: channel.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(channel.isPinned ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(channel.isPinned ? "Unpin channel" : "Pin channel")
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
}
