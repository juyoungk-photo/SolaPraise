//
//  FillFromPlaylistSheet.swift
//  SolaPraise
//
//  Choosing the playlist a service's 찬양 come from — or making one.
//
//  WHY NOT THE OLD MENU: it listed only the playlists pinned in the 찬양 tab,
//  which on most devices is two. The playlist a leader actually wants is
//  usually one they just built on YouTube and have never pinned, so the one
//  useful answer was the one not offered. This lists the pinned ones first,
//  because they are the team's regulars, and then everything in the account.
//
//  THE NEW PLAYLIST IS THE TEAM'S, NOT THE MAKER'S. It is created public and
//  its id is written to the Schedule tab, so every other member's app finds
//  it on the next load and puts it on their 홈 and 찬양 tab too. A playlist
//  that lived only on the device that made it would be a 콘티 nobody else
//  could open — which is the thing this app exists to stop.
//

import SwiftUI

struct FillFromPlaylistSheet: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss

    let service: TeamService
    let pinned: [CachedPlaylist]
    let sheetId: String?
    /// Chosen playlist id and title, handed back to the caller to push.
    let onPick: (String, String) -> Void

    @StateObject private var mine = LoadState<[YTPlaylist]>()
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                createSection

                if !pinned.isEmpty {
                    Section("고정된 재생목록") {
                        ForEach(pinned) { playlist in
                            row(title: playlist.title, subtitle: nil) {
                                onPick(playlist.playlistId, playlist.title)
                                dismiss()
                            }
                        }
                    }
                }

                Section {
                    if !auth.isSignedIn {
                        Text("Google 계정으로 로그인하면 내 재생목록이 모두 보입니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if mine.isLoading && mine.value == nil {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("불러오는 중…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    } else if let message = mine.errorMessage, mine.value == nil {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    } else {
                        ForEach(unpinned) { playlist in
                            row(title: playlist.title,
                                subtitle: "^[\(playlist.itemCount) video](inflect: true)") {
                                onPick(playlist.id, playlist.title)
                                dismiss()
                            }
                        }
                    }
                } header: {
                    Text("내 재생목록")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("재생목록에서 채우기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
            .disabled(isCreating)
            .overlay { if isCreating { ProgressView().controlSize(.large) } }
            .task {
                guard auth.isSignedIn, mine.value == nil else { return }
                let client = AppServices.client(auth: auth, quota: quota)
                await mine.run { try await client.myPlaylists() }
            }
        }
    }

    // MARK: - Create

    @ViewBuilder
    private var createSection: some View {
        Section {
            Button {
                create()
            } label: {
                Label("\(newPlaylistTitle) 만들기", systemImage: "plus.circle")
            }
            .disabled(!auth.isSignedIn || service.playlistId != nil)

            if let existing = service.playlistId {
                Button {
                    onPick(existing, newPlaylistTitle)
                    dismiss()
                } label: {
                    Label("이 예배의 재생목록 사용", systemImage: "checkmark.circle")
                }
            }
        } footer: {
            if service.playlistId != nil {
                Text("이 예배에는 이미 팀 재생목록이 있습니다. 시트의 「재생목록」 칸을 비우면 새로 만들 수 있습니다.")
            } else if auth.isSignedIn {
                // Said plainly, because both halves surprise people: it is
                // made under YOUR account, and it is visible to anyone with
                // the link rather than to the world's search results.
                Text("내 계정에 공개(링크 공유) 재생목록으로 만들고, 시트에 기록해 팀 전체의 홈·찬양 탭에 올립니다. 만든 뒤 유튜브나 「콘티에 추가」로 곡을 넣고, 다시 여기서 채우면 됩니다.")
            } else {
                Text("재생목록을 만들려면 Google 로그인이 필요합니다.")
            }
        }
    }

    /// Named for the service, so a year of them sorts and reads sensibly in
    /// a YouTube account that will accumulate one per Sunday.
    private var newPlaylistTitle: String {
        let day = service.date.formatted(
            .dateTime.year(.defaultDigits).month(.twoDigits).day(.twoDigits))
        return "\(day) \(service.title)"
    }

    private func create() {
        guard let sheetId else {
            errorMessage = "팀 시트가 연결되어 있지 않습니다."
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            let client = AppServices.client(auth: auth, quota: quota)
            do {
                let playlist = try await client.createPlaylist(
                    title: newPlaylistTitle,
                    description: "SolaPraise · \(service.title)",
                    // Unlisted, not fully public: the team needs to open it
                    // from a link, and a church's weekly 콘티 has no reason
                    // to turn up in YouTube search.
                    privacy: "unlisted"
                )
                if let failure = await team.setPlaylist(
                    playlist.id, for: service, sheetId: sheetId
                ) {
                    // The playlist exists but the sheet does not know — say
                    // so rather than reporting success, or the team will
                    // never see it.
                    errorMessage = "재생목록은 만들었지만 시트에 기록하지 못했습니다. \(failure)"
                    return
                }
                // Created and recorded — and that is the whole job.
                //
                // It used to hand the new playlist straight to the caller,
                // which opened 「이 예배의 콘티를 덮어씁니다」 and would have
                // replaced a real 콘티 with the contents of a playlist made
                // one second ago: nothing. A playlist you have just created
                // is empty by definition, so there is nothing to fill from
                // and nothing left to do on this screen.
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Rows

    private var unpinned: [YTPlaylist] {
        let already = Set(pinned.map(\.playlistId))
        return (mine.value ?? []).filter { !already.contains($0.id) }
    }

    private func row(title: String,
                     subtitle: String?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.primary).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}
