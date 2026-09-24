//
//  ReadingView.swift
//  SolaPraise
//
//  The daily psalm. Used both as the once-a-day full-screen gate and as the
//  Reading tab.
//
//  Attribution under the text is a licence obligation for both translations,
//  not decoration — do not remove it.
//

import SwiftUI

struct ReadingView: View {
    /// Non-nil when shown as the daily gate, which adds a dismiss affordance.
    var onDismiss: (() -> Void)?

    @EnvironmentObject private var daily: DailyReading
    @StateObject private var store = BibleStore()

    @State private var chapterData: BibleChapter?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showGrid = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header.id("top")
                        body(for: chapterData)
                        attribution
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .onChange(of: daily.chapter) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                    Task { await load() }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showGrid) { PsalmGridView() }
            .task {
                if chapterData == nil { await load() }
                #if DEBUG
                if DebugHarness.showPsalmGrid { showGrid = true }
                #endif
            }
            .onChange(of: daily.translation) { _, _ in Task { await load() } }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if onDismiss != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button { onDismiss?() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
        }
        ToolbarItem(placement: .principal) {
            // Version names rather than 한/영: "ESV" says which English text
            // this is, and 한 never did.
            Picker("Translation", selection: translationBinding) {
                ForEach(BibleTranslation.allCases) { t in
                    Text(t.displayName)
                        .foregroundStyle(t.isAvailable ? Color.primary : Color.secondary)
                        .tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showGrid = true } label: {
                Image(systemName: "square.grid.3x3")
            }
            .accessibilityLabel("시편 목록")

            ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
                .disabled(chapterData == nil)
        }
    }

    private var translationBinding: Binding<BibleTranslation> {
        Binding(
            get: { daily.translation },
            // A segmented picker has no per-segment disable, so an
            // unavailable choice is refused here instead. The view already
            // explains how to add the key.
            set: { if $0.isAvailable { daily.setTranslation($0) } }
        )
    }

    // MARK: - Content

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(daily.title(for: daily.translation))
                .font(.largeTitle.bold())
            HStack(spacing: 6) {
                Circle()
                    .fill(daily.isCurrentRead ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(daily.isCurrentRead ? "읽음" : "오늘의 말씀")
                    .font(.subheadline)
                    .foregroundStyle(daily.isCurrentRead ? Color.green : Color.secondary)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func body(for chapter: BibleChapter?) -> some View {
        if isLoading && chapter == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if let message = errorMessage, chapter == nil {
            missingText(message)
        } else if let chapter {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(chapter.verses) { verse in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(verse.number)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(verse.text)
                            .font(.body)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func missingText(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            if daily.translation == .esv {
                Button("Open Settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                Button("한글로 보기") { daily.setTranslation(.krv) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.top, 40)
    }

    private var attribution: some View {
        Text(daily.translation.attribution)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 10)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                daily.previous()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("이전 편")

            Button {
                if daily.isCurrentRead { daily.unmarkRead() } else { daily.markRead() }
            } label: {
                Label(
                    daily.isCurrentRead ? "읽음" : "읽었습니다",
                    systemImage: daily.isCurrentRead ? "checkmark.circle.fill" : "circle"
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Button {
                daily.next()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("다음 편")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Share

    /// Psalm 119 is 176 verses — pasting that into a group chat is a wall, so
    /// long chapters share an excerpt and short ones share in full.
    private var shareText: String {
        let title = daily.title(for: daily.translation)
        guard let chapter = chapterData else { return title }

        let limit = 20
        let shown = chapter.verses.prefix(limit)
        let lines = shown.map { "\($0.number). \($0.text)" }.joined(separator: "\n")
        let ellipsis = chapter.verses.count > limit ? "\n…" : ""

        return "\(title) 읽었습니다 🙏\n\n\(lines)\(ellipsis)\n\n\(daily.translation.attribution)"
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            chapterData = try await store.chapter(daily.chapter, in: daily.translation)
        } catch {
            chapterData = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
