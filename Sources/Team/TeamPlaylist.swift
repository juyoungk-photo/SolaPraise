//
//  TeamPlaylist.swift
//  SolaPraise
//
//  The team's 콘티 playlist — where 재생목록으로 내보내기 goes when a
//  service names none of its own. 「CCC 찬양콘티」 unless changed in 설정;
//  on this device.
//

import SwiftUI

enum TeamPlaylist {
    private static let idKey = "conti.teamPlaylistId"
    private static let titleKey = "conti.teamPlaylistTitle"

    static var defaultId: String {
        DefaultChannels.defaultPlaylists.first { $0.title == "CCC 찬양콘티" }?.playlistId ?? ""
    }

    static var id: String {
        UserDefaults.standard.string(forKey: idKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultId
    }

    static var title: String {
        UserDefaults.standard.string(forKey: titleKey) ?? "CCC 찬양콘티"
    }

    static var isDefault: Bool { id == defaultId }

    static func set(id: String, title: String) {
        UserDefaults.standard.set(id, forKey: idKey)
        UserDefaults.standard.set(title, forKey: titleKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: titleKey)
    }
}

/// 설정 › 팀 콘티 재생목록: a link pasted, or one of this account's own.
struct TeamPlaylistSettingsView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @Environment(\.quotaLedger) private var quota: QuotaLedger!   // for clients only — see Unobserved

    @State private var current = (id: TeamPlaylist.id, title: TeamPlaylist.title)
    @State private var link = ""
    @State private var mine: [YTPlaylist] = []
    @State private var note: String?
    @State private var checking = false

    private var client: YouTubeAPIClient { AppServices.client(auth: auth, quota: quota) }

    var body: some View {
        Form {
            Section {
                LabeledContent("지금", value: current.title)
                if !TeamPlaylist.isDefault {
                    Button("기본값으로 (CCC 찬양콘티)") {
                        TeamPlaylist.reset()
                        current = (TeamPlaylist.id, TeamPlaylist.title)
                        note = nil
                    }
                }
            } footer: {
                Text("예배표의 「재생목록으로 내보내기」가 이 재생목록으로 갑니다. 시트의 Schedule에 그 예배의 재생목록이 따로 적혀 있으면 그쪽이 먼저입니다. 이 기기에만 저장됩니다.")
            }

            Section {
                TextField("youtube.com/playlist?list=…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await useLink() } }
                Button {
                    Task { await useLink() }
                } label: {
                    if checking { ProgressView() } else { Text("이 링크로 바꾸기") }
                }
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("링크로")
            }

            if !mine.isEmpty {
                Section("내 재생목록에서") {
                    ForEach(mine) { playlist in
                        Button {
                            choose(id: playlist.id, title: playlist.snippet?.title ?? playlist.id)
                        } label: {
                            HStack {
                                Text(playlist.snippet?.title ?? playlist.id).foregroundStyle(Color.primary)
                                Spacer()
                                if playlist.id == current.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("팀 콘티 재생목록")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard auth.isSignedIn, let playlists = try? await client.myPlaylists() else { return }
            mine = playlists
        }
    }

    private func choose(id: String, title: String) {
        TeamPlaylist.set(id: id, title: title)
        current = (id, title)
        note = nil
    }

    /// Looked up before it is kept, so a mistyped link says so.
    private func useLink() async {
        guard let id = YouTubePlaylistID.from(link.trimmingCharacters(in: .whitespaces)) else {
            note = "재생목록 링크가 아닙니다. 「list=」가 들어간 링크를 붙여 넣으세요."
            return
        }
        checking = true
        defer { checking = false }
        if let playlist = try? await client.playlist(id: id) {
            choose(id: id, title: playlist.snippet?.title ?? id)
            link = ""
        } else {
            note = "이 재생목록을 찾지 못했습니다. 비공개 재생목록이면 그 계정으로 로그인한 뒤 「내 재생목록에서」 고르세요."
        }
    }
}
