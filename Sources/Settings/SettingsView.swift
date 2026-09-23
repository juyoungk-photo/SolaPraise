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
    @State private var notificationsOn = ReadingSettings.notificationsEnabled
    @State private var esvKey = ReadingSettings.esvAPIKey ?? ""
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

    // MARK: - Reading

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

            Link("Get a free ESV key at api.esv.org", destination: URL(string: "https://api.esv.org/")!)
                .font(.footnote)
        } header: {
            Text("시편 읽기")
        } footer: {
            Text("한글은 개역한글(저작권 만료)이 앱에 포함되어 오프라인에서도 열립니다. 영문 ESV는 Crossway API로 불러오며 무료 비상업용 키가 필요합니다. 개역개정은 대한성서공회 허락을 받으면 추가할 수 있습니다.")
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
        Section("Account") {
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

            Button("Sign out", role: .destructive) {
                auth.signOut()
                dismiss()
            }
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
