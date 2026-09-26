//
//  ServicePrepView.swift
//  SolaPraise
//
//  예배 준비 — one Sunday, everything needed to play it.
//
//  A playlist is an ordered list of videos. A service is that plus the date,
//  the roles, who filled them, the key each song is actually in, the leader's
//  notes, and the charts the team has made. This screen is where those stop
//  being four places.
//

import SwiftUI
import SwiftData

struct ServicePrepView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var team: TeamStore

    @Query(sort: [SortDescriptor(\SavedSong.createdAt, order: .reverse)])
    private var sheets: [SavedSong]

    @State private var selected: TeamService?
    @State private var showSettings = false

    private var sheetId: String? { ReadingSettings.teamSheetId }
    private var service: TeamService? { selected ?? team.upcoming }

    var body: some View {
        NavigationStack {
            Group {
                if team.isLoading && team.services.isEmpty {
                    ProgressView("팀 시트 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let service {
                    content(service)
                } else {
                    ContentUnavailableView(
                        "예정된 예배가 없습니다",
                        systemImage: "calendar",
                        description: Text(team.errorMessage
                                          ?? "팀 시트의 Schedule 탭에 날짜를 추가하면 여기에 나타납니다.")
                    )
                }
            }
            .navigationTitle("예배 준비")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { if let sheetId { await team.load(sheetId: sheetId) } }
            .task {
                team.configure(auth: auth)
                if team.services.isEmpty, let sheetId {
                    await team.load(sheetId: sheetId)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if team.services.count > 1 {
                Menu {
                    ForEach(team.services) { option in
                        Button {
                            selected = option
                        } label: {
                            Label(
                                option.date.formatted(.dateTime.month().day()) + " " + option.title,
                                systemImage: option.id == service?.id ? "checkmark" : ""
                            )
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    // MARK: - Content

    private func content(_ service: TeamService) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.date, format: .dateTime.year().month().day().weekday(.wide))
                        .font(.headline)
                    Text(service.title).font(.subheadline).foregroundStyle(.secondary)
                    if let notes = service.notes {
                        Text(notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 2)
            }

            songSection(service)
            roleSection(service)

            if let message = team.errorMessage {
                Section { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    // MARK: - Songs

    @ViewBuilder
    private func songSection(_ service: TeamService) -> some View {
        let list = team.songs(for: service)
        Section {
            if list.isEmpty {
                Text("이 예배의 콘티가 아직 비어 있습니다. 시트의 Songs 탭에 추가하세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list) { song in
                    songRow(song)
                }

                if !playable(list).isEmpty {
                    Button {
                        host.play(queue: playable(list), startIndex: 0)
                    } label: {
                        Label("콘티 전체 재생", systemImage: "play.fill")
                    }
                }
            }
        } header: {
            Text("콘티")
        } footer: {
            Text("키는 시트에 적힌 값입니다. 팀이 실제로 연주하는 키이므로 감지된 키보다 우선합니다.")
        }
    }

    private func songRow(_ song: TeamSong) -> some View {
        HStack(spacing: 12) {
            Text("\(song.order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.subheadline)
                HStack(spacing: 6) {
                    if let key = song.key {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    if song.transpose != 0 {
                        Text(song.transpose > 0 ? "+\(song.transpose)" : "\(song.transpose)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // A chart this team already made for the same song, so
                    // the work is not repeated every week.
                    if existingSheet(for: song) != nil {
                        Label("악보", systemImage: "music.quarternote.3")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if let notes = song.notes {
                        Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            if let id = song.videoId {
                Button {
                    host.play(queue: [PlayableVideo(id: id, title: song.title)], startIndex: 0)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    private func playable(_ list: [TeamSong]) -> [PlayableVideo] {
        list.compactMap { song in
            guard let id = song.videoId else { return nil }
            return PlayableVideo(id: id, title: song.title)
        }
    }

    /// Matched on title: the sheet names a song, the chart was made from a
    /// video whose title contains it.
    private func existingSheet(for song: TeamSong) -> SavedSong? {
        let needle = song.title.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return nil }
        return sheets.first { $0.title.contains(needle) || needle.contains($0.title) }
    }

    // MARK: - Roles

    @ViewBuilder
    private func roleSection(_ service: TeamService) -> some View {
        Section {
            if team.roles.isEmpty {
                Text("시트의 Roles 탭에 파트를 추가하면 여기에서 사인업할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(team.roles) { role in
                    roleRow(service, role)
                }
            }
        } header: {
            Text("파트")
        } footer: {
            Text("「가능」은 리더에게 알리는 것이고, 확정은 리더가 시트에서 이름을 넣어 정합니다.")
        }
    }

    private func roleRow(_ service: TeamService, _ role: TeamRole) -> some View {
        let assigned = service.assignments[role.name]
        let volunteers = team.signups(for: service, role: role.name)
        let email = auth.email ?? ""
        let mine = team.mySignup(for: service, role: role.name, email: email)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(role.name).font(.subheadline.weight(.medium))
                Spacer()
                if let assigned {
                    Text(assigned)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                } else {
                    Text("미정").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !volunteers.isEmpty {
                Text("가능: " + volunteers.map(\.name).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !email.isEmpty, !service.isPast {
                HStack(spacing: 8) {
                    Button {
                        Task { await setAvailability(true, service, role) }
                    } label: {
                        Label("가능", systemImage: mine?.isAvailable == true
                              ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(mine?.isAvailable == true ? .green : .accentColor)

                    Button {
                        Task { await setAvailability(false, service, role) }
                    } label: {
                        Label("어려움", systemImage: mine?.isAvailable == false
                              ? "xmark.circle.fill" : "circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(mine?.isAvailable == false ? .red : .secondary)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func setAvailability(_ value: Bool, _ service: TeamService, _ role: TeamRole) async {
        guard let sheetId, let email = auth.email else { return }
        await team.setAvailability(
            value,
            service: service,
            role: role.name,
            email: email,
            name: auth.displayName ?? email,
            sheetId: sheetId
        )
    }
}
