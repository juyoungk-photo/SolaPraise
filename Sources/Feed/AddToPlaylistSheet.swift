//
//  AddToPlaylistSheet.swift
//  SolaPraise
//
//  Adds a video to one of your real YouTube playlists, or a new one.
//  Each insert costs 50 units, and creating a playlist another 50 — so the
//  sheet states the cost rather than hiding it.
//

import SwiftUI

struct AddToPlaylistSheet: View {
    let video: PlayableVideo

    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.dismiss) private var dismiss

    @StateObject private var state = LoadState<[YTPlaylist]>()
    @State private var busyPlaylistId: String?
    @State private var addedTo: String?
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    ContentUnavailableView(
                        "Sign in required",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Playlists live in your YouTube account, so adding needs sign-in.")
                    )
                } else if state.isLoading && state.value == nil {
                    ProgressView("Loading playlists…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = state.errorMessage, state.value == nil {
                    ErrorState(message: message) { Task { await load() } }
                } else {
                    list
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { if auth.isSignedIn && state.value == nil { await load() } }
        }
    }

    private var list: some View {
        List {
            Section {
                Text(video.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let message = errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(state.value ?? []) { playlist in
                    Button {
                        Task { await add(to: playlist) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title).foregroundStyle(.primary)
                                Text("^[\(playlist.itemCount) video](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busyPlaylistId == playlist.id {
                                ProgressView().controlSize(.small)
                            } else if addedTo == playlist.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(busyPlaylistId != nil || addedTo == playlist.id)
                }
            } footer: {
                Text("Adding costs 50 of today's \(QuotaLedger.dailyUnitLimit.formatted()) units. \(quota.unitsRemaining.formatted()) left.")
            }

            Section {
                if isCreating {
                    HStack {
                        TextField("New playlist name", text: $newTitle)
                        Button("Create") { Task { await create() } }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New playlist", systemImage: "plus")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        let client = AppServices.client(auth: auth, quota: quota)
        await state.run { try await client.myPlaylists() }
    }

    private func add(to playlist: YTPlaylist) async {
        busyPlaylistId = playlist.id
        errorMessage = nil
        defer { busyPlaylistId = nil }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            _ = try await client.addVideo(video.id, to: playlist.id)
            addedTo = playlist.id
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func create() async {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        errorMessage = nil

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let playlist = try await client.createPlaylist(title: title)
            isCreating = false
            newTitle = ""
            await load()
            await add(to: playlist)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
