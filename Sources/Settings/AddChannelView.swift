//
//  AddChannelView.swift
//  SolaPraise
//
//  Adds a channel to the whitelist from a pasted URL or @handle.
//
//  A pasted channel *id* (UC…) costs nothing at all: the Atom feed both
//  validates it and supplies the real channel title. Only a @handle needs the
//  Data API (channels.list, 1 unit) to resolve to a UC id first.
//

import SwiftUI
import SwiftData

struct AddChannelView: View {
    let defaultPurpose: Purpose

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @State private var input = ""
    @State private var purpose: Purpose
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(defaultPurpose: Purpose) {
        self.defaultPurpose = defaultPurpose
        _purpose = State(initialValue: defaultPurpose)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("youtube.com/@handle or channel URL", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                } header: {
                    Text("Channel")
                } footer: {
                    Text("Paste a channel link, a @handle, or a UC… channel id. A channel id or link costs no API quota; a @handle costs 1 unit to resolve.")
                }

                suggestionsSection

                Section("Show in") {
                    Picker("Tab", selection: $purpose) {
                        ForEach(Purpose.allCases) { p in
                            Label(p.title, systemImage: p.symbolName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await add() }
                    } label: {
                        if isWorking { ProgressView().controlSize(.small) } else { Text("Add") }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
        }
    }

    // MARK: - Suggestions

    /// One-tap adds with the channel id already known, so these cost no quota
    /// and work without signing in.
    @ViewBuilder
    private var suggestionsSection: some View {
        let available = DefaultChannels.all.filter { !channelExists($0.channelId) }
        if !available.isEmpty {
            Section {
                ForEach(available) { suggestion in
                    Button {
                        addSuggestion(suggestion)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).foregroundStyle(.primary)
                                Text(suggestion.handle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("추천 채널")
            } footer: {
                Text("채널 ID가 이미 있어 추가 시 할당량을 사용하지 않습니다.")
            }
        }
    }

    private func addSuggestion(_ suggestion: SuggestedChannel) {
        guard !channelExists(suggestion.channelId) else { return }
        modelContext.insert(Channel(
            youtubeChannelId: suggestion.channelId,
            title: suggestion.title,
            handle: suggestion.handle,
            purpose: suggestion.purpose,
            sortOrder: nextSortOrder()
        ))
        try? modelContext.save()
    }

    // MARK: - Add

    private func add() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        guard let ref = YouTubeID.parseChannel(input) else {
            errorMessage = "That doesn't look like a YouTube channel link, @handle, or UC… id."
            return
        }

        do {
            let resolved = try await resolve(ref)

            guard !channelExists(resolved.id) else {
                errorMessage = "That channel is already in your list."
                return
            }

            let channel = Channel(
                youtubeChannelId: resolved.id,
                title: resolved.title,
                handle: resolved.handle,
                thumbnailURLString: resolved.thumbnailURL?.absoluteString,
                purpose: purpose,
                sortOrder: nextSortOrder()
            )
            modelContext.insert(channel)
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private struct Resolved {
        let id: String
        let title: String
        let handle: String?
        let thumbnailURL: URL?
    }

    private func resolve(_ ref: YouTubeID.ChannelRef) async throws -> Resolved {
        switch ref {
        case .channelId(let id):
            // Free path: the Atom feed proves the channel exists and names it.
            let feed = try await YouTubeRSSClient().fetch(channelId: id)
            return Resolved(
                id: id,
                title: feed.channelTitle ?? "Channel",
                handle: nil,
                thumbnailURL: nil
            )

        case .handle, .username:
            guard auth.isSignedIn else {
                throw AddChannelError.needsSignIn
            }
            let client = AppServices.client(auth: auth, quota: quota)
            guard let ytChannel = try await client.channel(for: ref) else {
                throw AddChannelError.notFound
            }
            return Resolved(
                id: ytChannel.id,
                title: ytChannel.title,
                handle: ytChannel.handle,
                thumbnailURL: ytChannel.thumbnailURL
            )
        }
    }

    private enum AddChannelError: LocalizedError {
        case needsSignIn, notFound
        var errorDescription: String? {
            switch self {
            case .needsSignIn:
                return "Resolving a @handle needs the YouTube API. Sign in first, or paste the channel's URL with its UC… id instead."
            case .notFound:
                return "No channel found for that handle."
            }
        }
    }

    // MARK: - Store helpers

    private func channelExists(_ id: String) -> Bool {
        let descriptor = FetchDescriptor<Channel>(
            predicate: #Predicate { $0.youtubeChannelId == id }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    private func nextSortOrder() -> Int {
        let all = (try? modelContext.fetch(FetchDescriptor<Channel>())) ?? []
        return (all.map(\.sortOrder).max() ?? 0) + 1
    }
}
