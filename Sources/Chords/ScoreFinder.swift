//
//  ScoreFinder.swift
//  SolaPraise
//
//  악보 검색 inside the app, ending on the stand: find a chart, press
//  「이 악보로 연주」, and it is open in 연주모드 — attached to the song on
//  the 콘티 when there is one.
//
//  WHY: the flow from a search to playing from a chart went through Safari.
//  The song was carried into PiP so the music went on, the chart was saved
//  to Photos or Files by hand, and then the person came back, found the song
//  in 예배표, pressed 📎, picked the file from where they had put it, and
//  opened the stand. Six steps, three apps, and a file left behind. Here the
//  page is in the app — the player keeps playing underneath — and the chart
//  on screen is taken as it is:
//
//  - a page that IS a chart — a PDF or an image — as that file;
//  - otherwise the largest picture in view: a Google Images preview, a
//    store's sample page, a blog's scan;
//  - and, failing both, the screen as it is.
//
//  What happens next is asked once: 「이 곡에 첨부하고 연주」 when the song
//  is on an upcoming 콘티 and this account may attach, which puts it where
//  the team sees it; 「작업실에 두고 연주」 otherwise — on this device only.
//

import SwiftUI
import SwiftData
import WebKit
import UIKit

/// Where a chart found for a song belongs: that song on a 콘티.
struct ScoreDestination {
    let service: TeamService
    let song: String
    let key: String?
}

enum ScoreFinder {

    /// Opens the finder over whatever is on screen — from the player, the
    /// stand or a menu, where a SwiftUI sheet does not always present.
    @MainActor
    static func present(url: URL, song: String, destination: ScoreDestination?,
                        team: TeamStore, auth: GoogleAuthManager, planning: PlanningAuth,
                        quota: QuotaLedger, context: ModelContext) {
        // Called from a menu item: the menu is still going away, and a
        // controller presented over it in the same moment never appears.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            show(url: url, song: song, destination: destination, team: team, auth: auth,
                 planning: planning, quota: quota, context: context)
        }
    }

    @MainActor
    private static func show(url: URL, song: String, destination: ScoreDestination?,
                             team: TeamStore, auth: GoogleAuthManager, planning: PlanningAuth,
                             quota: QuotaLedger, context: ModelContext) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }

        let closer = Closer()
        let view = ScoreFinderView(start: url, song: song, destination: destination, closer: closer)
            .environmentObject(team)
            .environmentObject(auth)
            .environmentObject(planning)
            .environmentObject(quota)
            .environment(\.modelContext, context)
        let host = UIHostingController(rootView: AnyView(view))
        host.modalPresentationStyle = .fullScreen
        closer.action = { [weak host] in host?.dismiss(animated: true) }
        top.present(host, animated: true)
    }

    /// How the finder, presented by UIKit, takes itself away.
    final class Closer {
        var action: () -> Void = {}
    }

    /// The largest picture in view, by what it holds: its own pixels, not
    /// how big it is drawn. A preview's thumbnail is swapped for the full
    /// image once that loads; `currentSrc` is whichever is showing.
    static let largestImageScript = """
    (function () {
      var best = null, bestArea = 0;
      var vw = window.innerWidth, vh = window.innerHeight;
      var imgs = document.images;
      for (var i = 0; i < imgs.length; i++) {
        var img = imgs[i];
        var r = img.getBoundingClientRect();
        if (r.width < 120 || r.height < 120) continue;
        if (r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw) continue;
        var area = (img.naturalWidth || 0) * (img.naturalHeight || 0);
        if (area > bestArea) { bestArea = area; best = img; }
      }
      if (!best) return null;
      return { src: best.currentSrc || best.src, w: best.naturalWidth, h: best.naturalHeight };
    })()
    """

    /// The picture or file behind a source: a data: URL decoded, anything
    /// else fetched as the page would.
    static func fetch(_ source: String, referer: URL?) async -> Data? {
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
            let header = source[..<comma]
            let body = String(source[source.index(after: comma)...])
            return header.contains(";base64") ? Data(base64Encoded: body)
                                              : body.removingPercentEncoding.flatMap { $0.data(using: .utf8) }
        }
        guard let url = URL(string: source) else { return nil }
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }

    static func isPDF(_ data: Data) -> Bool { data.prefix(4) == Data("%PDF".utf8) }
}

// MARK: - The browser

struct ScoreFinderView: View {
    let start: URL
    let song: String
    let destination: ScoreDestination?
    let closer: ScoreFinder.Closer

    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @Environment(\.openURL) private var openURL

    @StateObject private var page = WebPage()

    /// A chart taken from the page, waiting for where it goes.
    struct Capture: Identifiable {
        let id = UUID()
        let data: Data
        let isPDF: Bool
        var preview: UIImage? { isPDF ? nil : UIImage(data: data) }
    }

    @State private var capture: Capture?
    @State private var capturing = false
    @State private var note: String?
    @State private var title = ""
    @State private var saving = false
    @State private var stand: ScoreStandItem?

    var body: some View {
        NavigationStack {
            WebPageView(page: page)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationTitle(song)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { close() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { page.web.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!page.canGoBack)
                        Button {
                            if let url = page.url { openURL(url) }
                        } label: { Image(systemName: "safari") }
                            .accessibilityLabel("Safari에서 열기")
                    }
                }
        }
        .onAppear {
            title = song
            page.load(start)
        }
        .sheet(item: $capture) { capture in review(capture) }
        // Played, then back where the search began.
        .fullScreenCover(item: $stand, onDismiss: { close() }) { item in
            ScoreStandView(items: [item])
        }
        .alert("악보", isPresented: .constant(note != nil)) {
            Button("확인") { note = nil }
        } message: { Text(note ?? "") }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Button {
                Task { await take() }
            } label: {
                HStack {
                    if capturing { ProgressView().tint(.white) } else { Image(systemName: "music.note.list") }
                    Text("이 악보로 연주").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(capturing)
            Text("악보가 화면에 크게 보일 때 누르세요 — PDF나 그림이면 그 파일을, 아니면 화면의 가장 큰 그림을 씁니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Taking the chart

    private func take() async {
        capturing = true
        defer { capturing = false }
        // A page that is a file: the file.
        if let url = page.url, ["pdf", "jpg", "jpeg", "png", "webp", "gif"].contains(url.pathExtension.lowercased()),
           let data = await ScoreFinder.fetch(url.absoluteString, referer: nil), usable(data) {
            capture = Capture(data: data, isPDF: ScoreFinder.isPDF(data))
            return
        }
        // The largest picture in view.
        if let found = try? await page.web.evaluateJavaScript(ScoreFinder.largestImageScript) as? [String: Any],
           let source = found["src"] as? String,
           let data = await ScoreFinder.fetch(source, referer: page.url), usable(data) {
            let width = (found["w"] as? Int) ?? UIImage(data: data).map { Int($0.size.width) } ?? 0
            if width < 500 {
                note = "그림이 작습니다(\(width)px). 그림을 눌러 크게 연 뒤 다시 누르면 더 잘 읽힙니다. 이대로 쓰려면 아래에서 계속하세요."
            }
            capture = Capture(data: data, isPDF: false)
            return
        }
        // The screen as it is.
        if let shot = try? await page.web.takeSnapshot(configuration: nil),
           let data = shot.pngData() {
            note = "화면의 그림을 찾지 못해 보이는 화면을 그대로 씁니다."
            capture = Capture(data: data, isPDF: false)
        }
    }

    private func usable(_ data: Data) -> Bool {
        ScoreFinder.isPDF(data) || UIImage(data: data) != nil
    }

    // MARK: - Where it goes

    private var canAttach: Bool { destination != nil && team.canAttach && TeamSheetSource.current != nil }

    private func review(_ capture: Capture) -> some View {
        NavigationStack {
            Form {
                Section {
                    if let image = capture.preview {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 320)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("PDF 악보", systemImage: "doc.richtext")
                    }
                    TextField("곡 제목", text: $title)
                }
                Section {
                    if canAttach, let destination {
                        Button {
                            Task { await attach(capture, to: destination) }
                        } label: {
                            Label("\(destination.service.date.formatted(.dateTime.month().day())) 콘티의 「\(PlanSongTitle.split(destination.song).title)」에 첨부하고 연주",
                                  systemImage: "paperclip")
                        }
                    }
                    Button {
                        keepLocally(capture)
                    } label: {
                        Label("작업실에 두고 연주", systemImage: "recordingtape")
                    }
                } footer: {
                    Text(canAttach
                         ? "첨부하면 팀 모두가 그 곡에서 이 악보를 봅니다. 작업실은 이 기기에만 둡니다."
                         : destination != nil
                         ? "작업실은 이 기기에만 둡니다. 콘티 곡에 바로 첨부하려면 예배 준비에서 구글 드라이브 권한을 연결하세요."
                         : "작업실은 이 기기에만 둡니다. 다가오는 콘티에 있는 곡이면 그 곡에 바로 첨부할 수 있습니다.")
                }
            }
            .disabled(saving)
            .overlay { if saving { ProgressView().controlSize(.large) } }
            .navigationTitle("이 악보로 연주")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("다시 고르기") { self.capture = nil } }
            }
        }
        .presentationDetents([.large])
    }

    private var fileTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PlanSongTitle.split(song).title : trimmed
    }

    private func keepLocally(_ capture: Capture) {
        let item: LocalScores.Item?
        if capture.isPDF {
            item = LocalScores.shared.add(data: capture.data, extension: "pdf", title: fileTitle)
        } else {
            item = LocalScores.shared.add(photo: capture.data, title: fileTitle)
        }
        guard let item else { note = "악보를 저장하지 못했습니다."; return }
        var standItem = LocalScores.shared.standItem(for: item)
        if let key = destination?.key {
            standItem = ScoreStandItem(attachment: standItem.attachment, song: standItem.song, teamKey: key)
        }
        self.capture = nil
        stand = standItem
    }

    private func attach(_ capture: Capture, to destination: ScoreDestination) async {
        guard let sheetId = TeamSheetSource.current else { return }
        saving = true
        defer { saving = false }
        let data = capture.isPDF ? capture.data : (LocalScores.chartJPEG(capture.data) ?? capture.data)
        let stem = fileTitle.replacingOccurrences(of: " ", with: "_")
        let day = TeamSheet.dateFormatter.string(from: destination.service.date)
        let name = "\(day)-\(stem)-\(Int(Date().timeIntervalSince1970)).\(capture.isPDF ? "pdf" : "jpg")"
        let who = team.actingEmail(auth: auth, planning: planning) ?? ""
        if let failure = await team.attach(data: data, name: name, mimeType: capture.isPDF ? "application/pdf" : "image/jpeg",
                                           song: destination.song, to: destination.service, sheetId: sheetId, by: who) {
            note = failure
            return
        }
        guard let attached = team.attachments(for: destination.service).first(where: { $0.name == name }) else {
            note = "첨부했지만 찾지 못했습니다. 예배표에서 열어 주세요."
            return
        }
        self.capture = nil
        stand = ScoreStandItem(attachment: attached, song: destination.song, teamKey: destination.key)
    }

    private func close() { closer.action() }
}

// MARK: - The page

@MainActor
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    @Published var url: URL?
    @Published var canGoBack = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        // As Safari: a web view's own user agent gets Google's basic pages
        // — image results as small thumbnails with no viewer to enlarge.
        web.customUserAgent = UIDevice.current.userInterfaceIdiom == .pad
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        super.init()
        web.navigationDelegate = self
    }

    func load(_ url: URL) {
        guard web.url == nil else { return }
        web.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        url = webView.url
        canGoBack = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        url = webView.url
        canGoBack = webView.canGoBack
    }
}

struct WebPageView: UIViewRepresentable {
    @ObservedObject var page: WebPage
    func makeUIView(context: Context) -> WKWebView { page.web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
