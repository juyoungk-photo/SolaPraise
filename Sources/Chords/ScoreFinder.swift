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
    static func present(url: URL, song: String, destination: ScoreDestination?, videoId: String? = nil,
                        team: TeamStore, auth: GoogleAuthManager, planning: PlanningAuth,
                        quota: QuotaLedger, player: PlayerHost, context: ModelContext) {
        // Called from a menu item: the menu is still going away, and a
        // controller presented over it in the same moment never appears.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            show(url: url, song: song, destination: destination, videoId: videoId, team: team, auth: auth,
                 planning: planning, quota: quota, player: player, context: context)
        }
    }

    @MainActor
    private static func show(url: URL, song: String, destination: ScoreDestination?, videoId: String?,
                             team: TeamStore, auth: GoogleAuthManager, planning: PlanningAuth,
                             quota: QuotaLedger, player: PlayerHost, context: ModelContext) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }

        let closer = Closer()
        // Presented by UIKit, it inherits nothing: everything the stand
        // inside it reads is handed on here — the player too, which the
        // stand's player row reads, and without which it stopped the app.
        let view = ScoreFinderView(start: url, song: song, destination: destination, videoId: videoId, closer: closer)
            .environmentObject(team)
            .environmentObject(auth)
            .environmentObject(planning)
            .environmentObject(quota)
            .environmentObject(player)
            .environment(\.playerActions, player)
            .environment(\.quotaLedger, quota)
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

    /// The picture being looked at: the one taking the most of the screen,
    /// as seen — visible, not hidden behind another picture — not the one
    /// holding the most pixels. Google's image viewer keeps the next result
    /// loaded, hidden, where the shown one is; ranked by pixels, the next
    /// chart was taken when it was the larger file. A preview's thumbnail
    /// is swapped for the full image once that loads; `currentSrc` is
    /// whichever is showing.
    static let largestImageScript = """
    (function () {
      var vw = window.innerWidth, vh = window.innerHeight;
      function shown(el) {
        for (var e = el; e && e.nodeType === 1; e = e.parentElement) {
          var s = window.getComputedStyle(e);
          if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) < 0.2) return false;
        }
        return true;
      }
      var best = null, bestSeen = 0;
      var imgs = document.images;
      for (var i = 0; i < imgs.length; i++) {
        var img = imgs[i];
        if (!img.naturalWidth) continue;
        var r = img.getBoundingClientRect();
        var w = Math.min(r.right, vw) - Math.max(r.left, 0);
        var h = Math.min(r.bottom, vh) - Math.max(r.top, 0);
        if (w < 120 || h < 120) continue;
        if (!shown(img)) continue;
        // Under the finger where it shows: not another picture on top.
        var top = document.elementFromPoint(Math.max(r.left, 0) + w / 2, Math.max(r.top, 0) + h / 2);
        if (top && top !== img && top.tagName === 'IMG') continue;
        var seen = w * h;
        if (seen > bestSeen) { bestSeen = seen; best = img; }
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
    /// The video the song is playing from: what the stand's player row plays.
    var videoId: String? = nil
    let closer: ScoreFinder.Closer

    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @Environment(\.openURL) private var openURL

    @StateObject private var page = WebPage()

    /// A chart taken from the page, waiting for where it goes.
    struct Capture: Identifiable {
        /// Kept through a crop, so the sheet stays up with the new picture.
        var id = UUID()
        var data: Data
        let isPDF: Bool
        /// Said in the sheet, over the picture: an alert raised as the sheet
        /// opened left one of the two unpresented.
        var warning: String? = nil
        var preview: UIImage? { isPDF ? nil : UIImage(data: data) }
    }

    @State private var capture: Capture?
    /// The page's large pictures, for 「악보만 보기」.
    @State private var pictures: [Picture]?

    struct Picture: Identifiable {
        let id = UUID()
        let data: Data
        let image: UIImage
    }
    @State private var capturing = false
    @State private var note: String?
    @State private var title = ""
    @State private var saving = false
    @State private var stand: ScoreStandItem?
    /// The stand to open once the review sheet has finished closing.
    /// Opened in the same moment the sheet was told to close, SwiftUI
    /// could not present it — it never appeared, and the next 「이 악보로
    /// 연주」 was presented over nothing: the app stopped answering.
    @State private var standNext: ScoreStandItem?
    /// What the upload is doing, said under the spinner.
    @State private var savingStep = ""
    /// Attached, and another version was chosen for the 콘티 before it:
    /// asked which the 콘티 takes before the stand opens (NewChart).
    @State private var asking: (item: ScoreStandItem, destination: ScoreDestination, standing: String)?

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
        .sheet(item: $capture, onDismiss: {
            if let next = standNext {
                standNext = nil
                stand = next
            }
        }) { capture in review(capture) }
        .sheet(isPresented: Binding(get: { pictures != nil }, set: { if !$0 { pictures = nil } })) {
            picturesSheet
        }
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
            HStack(spacing: 10) {
                // The page's charts alone, past its ads and text.
                Button {
                    Task { await collectPictures() }
                } label: {
                    HStack {
                        Image(systemName: "rectangle.grid.2x2")
                        Text("악보만 보기").fontWeight(.semibold)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.accentColor)
                }
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
            capture = Capture(data: data, isPDF: false,
                              warning: width < 500
                                ? "그림이 작습니다(\(width)px). 그림을 눌러 크게 연 뒤 다시 누르면 더 잘 읽힙니다. 이대로 쓰려면 아래에서 계속하세요."
                                : nil)
            return
        }
        // The screen as it is.
        if let shot = try? await page.web.takeSnapshot(configuration: nil),
           let data = shot.pngData() {
            capture = Capture(data: data, isPDF: false, warning: "화면의 그림을 찾지 못해 보이는 화면을 그대로 씁니다.")
        }
    }

    // MARK: - 악보만 보기

    /// Every large picture on the page, in page order: a blog's charts,
    /// without what surrounds them.
    static let largeImagesScript = """
    (function () {
      var out = [], seen = {};
      var imgs = document.images;
      for (var i = 0; i < imgs.length; i++) {
        var img = imgs[i], src = img.currentSrc || img.src;
        if (!src || seen[src]) continue;
        if ((img.naturalWidth || 0) < 400 || (img.naturalHeight || 0) < 300) continue;
        seen[src] = true;
        out.push(src);
        if (out.length >= 24) break;
      }
      return out;
    })()
    """

    private func collectPictures() async {
        capturing = true
        defer { capturing = false }
        let sources = (try? await page.web.evaluateJavaScript(Self.largeImagesScript) as? [String]) ?? []
        var found: [Picture] = []
        for source in sources {
            if let data = await ScoreFinder.fetch(source, referer: page.url), let image = UIImage(data: data) {
                found.append(Picture(data: data, image: image))
            }
        }
        if found.isEmpty {
            note = "이 페이지에서 큰 그림을 찾지 못했습니다. 악보가 그림으로 올라온 페이지에서 눌러 보세요."
        } else {
            pictures = found
        }
    }

    private var picturesSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(pictures ?? []) { picture in
                        Button {
                            pictures = nil
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                capture = Capture(data: picture.data, isPDF: false)
                            }
                        } label: {
                            Image(uiImage: picture.image)
                                .resizable().scaledToFit()
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("이 페이지의 그림 \(pictures?.count ?? 0)개")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { pictures = nil } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("연주할 악보를 누르세요.").font(.footnote).foregroundStyle(.secondary).padding(8)
            }
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
                if let warning = capture.warning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    if let image = capture.preview {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 320)
                            .frame(maxWidth: .infinity)
                        // To the chart alone: a page's margins, a site's
                        // header, the next song begun below it.
                        NavigationLink {
                            ChartCropView(image: image) { cropped in
                                guard let data = cropped.jpegData(compressionQuality: 0.92) else { return }
                                var next = capture
                                next.data = data
                                self.capture = next
                            }
                        } label: {
                            Label("자르기", systemImage: "crop")
                        }
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
            .overlay {
                if saving {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(savingStep).font(.callout.weight(.semibold))
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle("이 악보로 연주")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("다시 고르기") { self.capture = nil } }
            }
        }
        .presentationDetents([.large])
        .alert("새 악보를 콘티에 쓸까요?",
               isPresented: Binding(get: { asking != nil }, set: { _ in })) {
            // Either way on to the stand; each button once.
            Button("새 악보로") {
                guard let asked = asking else { return }
                play(asked.item)
                Task {
                    if let failure = await NewChart.makeDefault(asked.item.attachment, team: team, service: asked.destination.service,
                                                                song: asked.destination.song, sheetId: TeamSheetSource.current) {
                        Toast.shared.sheet(failure, saved: "")
                    }
                }
            }
            Button("그대로 두기", role: .cancel) { if let asked = asking { play(asked.item) } }
        } message: {
            Text("지금 콘티에는 「\(asking?.standing ?? "")」이 들어가 있습니다. 새 악보는 버전으로 남아, 악보 화면에서 언제든 바꿀 수 있습니다.")
        }
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
        standItem.videoId = videoId
        // Opened when the sheet has gone (its onDismiss).
        standNext = standItem
        self.capture = nil
    }

    private func attach(_ capture: Capture, to destination: ScoreDestination) async {
        guard let sheetId = TeamSheetSource.current else { return }
        saving = true
        savingStep = "악보를 준비하는 중…"
        defer { saving = false }
        // Off the main thread: a photo of a chart is decoded and encoded
        // again, a second or more on a phone with the screen held still.
        let raw = capture.data, isPDF = capture.isPDF
        let data = await Task.detached(priority: .userInitiated) {
            isPDF ? raw : (LocalScores.chartJPEG(raw) ?? raw)
        }.value
        savingStep = "드라이브에 올리고 콘티에 적는 중…"
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
        // The stand has the file already: not fetched back from Drive.
        ScoreFileCache.save(data, for: attached.fileId)
        var item = ScoreStandItem(attachment: attached, song: destination.song, teamKey: destination.key)
        item.videoId = videoId
        // The 콘티 takes it — or, when another was chosen on purpose, asked.
        if let standing = NewChart.standing(team: team, service: destination.service, song: destination.song,
                                            except: attached.fileId) {
            asking = (item, destination, standing)
            return
        }
        NewChart.takeNewest(service: destination.service, song: destination.song)
        play(item)
    }

    /// To the stand, once the review sheet has gone.
    private func play(_ item: ScoreStandItem) {
        asking = nil
        standNext = item
        capture = nil
    }

    private func close() { closer.action() }
}

// MARK: - The page

@MainActor
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
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
        web.uiDelegate = self
    }

    /// A link that opens a new window — Google Images' 「Visit」, most
    /// 「open in new tab」 links — opens here instead. A web view has no
    /// other windows, and without this the tap did nothing.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func load(_ url: URL) {
        guard web.url == nil else { return }
        // Ads off first, then the page: the rules apply only to loads made
        // after they are in place.
        Task { @MainActor in
            if let rules = await Self.adRules() {
                web.configuration.userContentController.add(rules)
            }
            web.configuration.userContentController.addUserScript(WKUserScript(
                source: Self.labelledAdScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            web.load(URLRequest(url: url))
        }
    }

    // MARK: - Ads

    /// The ad networks that cover a chart on the blogs people post them on —
    /// a banner across the top of a Tistory or Naver page took half the
    /// screen. Their requests are not made, and the slots they fill are
    /// hidden. Only ads: a page's own pictures are what is being looked for.
    static let adHosts = [
        "googlesyndication\\.com", "doubleclick\\.net", "googleadservices\\.com",
        "adservice\\.google\\.", "amazon-adsystem\\.com", "adnxs\\.com", "criteo\\.",
        "taboola\\.com", "outbrain\\.com", "dable\\.io", "mobon\\.net", "adfit\\.",
        "t1\\.daumcdn\\.net/kas/", "kakaoad", "ader\\.naver\\.com", "veta\\.naver\\.com",
        "adcr\\.naver\\.com", "tpmn\\.co\\.kr", "realclick\\.co\\.kr", "adpopcorn",
        "ad\\.daum\\.net", "ad\\.kakao\\.com", "analytics\\.ad\\.daum", "aem-kakao", "adfit\\.kakao"
    ]

    static let adSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='google_ads']", "[id^='div-gpt-ad']",
        ".revenue_unit_wrap", ".revenue_unit_item", ".kakao_ad_area", "[class*='AdFit']",
        ".tt_adsense", ".adfit", "[id^='dablewidget']", ".ad_wrap", ".ad-area",
        "iframe[src*='googlesyndication']", "iframe[src*='doubleclick']", "iframe[src*='ad.daum']", "iframe[src*='adfit']",
        "[data-ad-unit]", "[data-tistory-react-app='Revenue']", "div[class*='revenue']",
        "ins.kakao_ad_area", "[id*='kakao_ad']"
    ]

    /// Ads a page's own script puts in, with no class to match — a blog's
    /// text-link box marked 「광고」 or 「AD」. Each is hidden from that
    /// badge up to the largest box around it that is still small — under
    /// 300 characters, six levels at most, and holding no picture — so the
    /// article and its charts stay. Watched
    /// for as the page goes on adding them.
    static let labelledAdScript = """
    (function () {
      function sweep(root) {
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        var badges = [], n;
        while ((n = walker.nextNode())) {
          var t = n.nodeValue.trim();
          if (t === '광고' || t === 'AD' || t === 'Ad' || t === '스폰서') badges.push(n.parentElement);
        }
        // A box holding a real picture is the page's content, never an ad
        // box: a post that is mostly a chart has little text, and the
        // first version hid the whole post.
        function holdsPicture(e) {
          var imgs = e.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            if ((imgs[i].naturalWidth || imgs[i].width) >= 300) return true;
          }
          return false;
        }
        badges.forEach(function (badge) {
          var box = null, e = badge, depth = 0;
          while (e && e !== document.body && depth < 6) {
            if ((e.innerText || '').length > 300 || holdsPicture(e)) break;
            if (e.querySelector('a')) box = e;
            e = e.parentElement;
            depth++;
          }
          if (box) box.style.setProperty('display', 'none', 'important');
        });
      }
      sweep(document.body);
      var pending = false;
      new MutationObserver(function () {
        if (pending) return;
        pending = true;
        setTimeout(function () { pending = false; sweep(document.body); }, 400);
      }).observe(document.body, { childList: true, subtree: true });
    })();
    """

    private static var compiled: WKContentRuleList?

    static func adRules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        var rules: [[String: Any]] = adHosts.map {
            ["trigger": ["url-filter": $0], "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none", "selector": adSelectors.joined(separator: ", ")]])
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let list = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "score-finder-ads-2", encodedContentRuleList: json)
        compiled = list
        return list
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

// MARK: - 자르기

/// The picture with a frame to drag in from its edges and corners; 완료
/// keeps what is inside it.
struct ChartCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The frame, as a share of the picture, 0…1 each way.
    @State private var frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var start: CGRect?

    var body: some View {
        GeometryReader { geo in
            let shown = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: image).resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.minX, y: shown.minY)
                // Outside the frame, dimmed.
                Path { path in
                    path.addRect(shown)
                    path.addRect(box(in: shown))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: box(in: shown).width, height: box(in: shown).height)
                    .offset(x: box(in: shown).minX, y: box(in: shown).minY)
                    .allowsHitTesting(false)
                ForEach(Handle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(handle.point(in: box(in: shown)))
                        .gesture(DragGesture()
                            .onChanged { value in
                                let from = start ?? frame
                                start = from
                                frame = handle.moved(from, by: CGSize(width: value.translation.width / shown.width,
                                                                      height: value.translation.height / shown.height))
                            }
                            .onEnded { _ in start = nil })
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("자르기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") {
                    if let cropped = crop() { onCrop(cropped) }
                    dismiss()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("처음대로") { frame = CGRect(x: 0, y: 0, width: 1, height: 1) }
            }
        }
    }

    private func fitted(in size: CGSize) -> CGRect {
        let inset = size.applying(.init(scaleX: 1, y: 1))
        let scale = min((inset.width - 32) / image.size.width, (inset.height - 32) / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func box(in shown: CGRect) -> CGRect {
        CGRect(x: shown.minX + frame.minX * shown.width, y: shown.minY + frame.minY * shown.height,
               width: frame.width * shown.width, height: frame.height * shown.height)
    }

    /// What is inside the frame, at the picture's own pixels.
    private func crop() -> UIImage? {
        let upright = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
        guard let cg = upright.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let area = CGRect(x: frame.minX * w, y: frame.minY * h, width: frame.width * w, height: frame.height * h).integral
        return cg.cropping(to: area).map { UIImage(cgImage: $0) }
    }

    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

        func point(in box: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: box.minX, y: box.minY)
            case .topRight: return CGPoint(x: box.maxX, y: box.minY)
            case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
            case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
            case .top: return CGPoint(x: box.midX, y: box.minY)
            case .bottom: return CGPoint(x: box.midX, y: box.maxY)
            case .left: return CGPoint(x: box.minX, y: box.midY)
            case .right: return CGPoint(x: box.maxX, y: box.midY)
            }
        }

        /// The frame with this edge or corner dragged, kept inside the
        /// picture and at least a tenth of it each way.
        func moved(_ frame: CGRect, by d: CGSize) -> CGRect {
            var left = frame.minX, top = frame.minY, right = frame.maxX, bottom = frame.maxY
            switch self {
            case .topLeft: left += d.width; top += d.height
            case .topRight: right += d.width; top += d.height
            case .bottomLeft: left += d.width; bottom += d.height
            case .bottomRight: right += d.width; bottom += d.height
            case .top: top += d.height
            case .bottom: bottom += d.height
            case .left: left += d.width
            case .right: right += d.width
            }
            let least: CGFloat = 0.1
            left = min(max(0, left), right - least)
            top = min(max(0, top), bottom - least)
            right = max(min(1, right), left + least)
            bottom = max(min(1, bottom), top + least)
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}
