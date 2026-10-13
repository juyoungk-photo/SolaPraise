//
//  check-conti-folder.swift
//  SolaPraise
//
//  Checks how the 콘티 folder's files are dated and versioned, and how its
//  public listing page is read.
//
//  WHY THIS EXISTS: a 콘티 filed under the wrong Sunday, or v1 shown as the
//  newest, looks like the app working.
//
//  Run:
//      swiftc -O -o /tmp/contifolder \
//          Sources/Team/ContiFolder.swift Sources/Feed/SharedChannelList.swift \
//          Tools/check-conti-folder.swift
//      /tmp/contifolder
//

import Foundation

@main
struct CheckContiFolder {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    static func day(_ text: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: text)!
    }

    static func main() {
        func same(_ a: Date?, _ b: String) -> Bool { a.map { Calendar.current.isDate($0, inSameDayAs: day(b)) } ?? false }
        check("20261011 주일예배 찬양.pdf → 10/11", same(ContiFolder.date(in: "20261011 주일예배 찬양.pdf"), "2026-10-11"))
        check("2026-10-18 콘티.pdf → 10/18", same(ContiFolder.date(in: "2026-10-18 콘티.pdf"), "2026-10-18"))
        check("2026.11.1 금요 콘티 → 11/1", same(ContiFolder.date(in: "2026.11.1 금요 콘티.pdf"), "2026-11-01"))
        check("a name with no date has none", ContiFolder.date(in: "찬양 콘티 최종.pdf") == nil)
        check("v2 is version 2", ContiFolder.version(in: "20260913 주일예배 찬양 v2.pdf") == 2)
        check("no version is version 1", ContiFolder.version(in: "20261011 주일예배 찬양.pdf") == 1)
        check("「(ver3)」 is version 3", ContiFolder.version(in: "20261018 콘티 (ver3).pdf") == 3)
        check("「love」 is no version", ContiFolder.version(in: "20261018 God is love.pdf") == 1)

        let files = ["20260913 주일예배 찬양 v1.pdf", "20260913 주일예배 찬양 v2.pdf", "20261011 주일예배 찬양.pdf"]
            .enumerated().map { ContiFolder.File(id: "id\($0.offset)", name: $0.element) }
        let sept = ContiFolder.versions(for: day("2026-09-13"), in: files)
        check("a service's versions, newest first", sept.map(\.name) == ["20260913 주일예배 찬양 v2.pdf", "20260913 주일예배 찬양 v1.pdf"],
              "got \(sept.map(\.name))")
        check("another day's file is not among them", !sept.contains { $0.name.contains("1011") })

        let page = """
        <div class="flip-entry" id="entry-1AbCdEfGhIjK" tabindex="0"><div class="flip-entry-info"><a href="x"><div class="flip-entry-title">20261011 주일예배 찬양.pdf</div></a></div></div>
        <div class="flip-entry" id="entry-1ZyXwVuTsRqP" tabindex="0"><div class="flip-entry-title">Notes &amp; plan.docx</div></div>
        """
        let parsed = ContiFolder.parseFolderPage(page)
        check("the public listing gives each PDF with its id",
              parsed == [ContiFolder.File(id: "1AbCdEfGhIjK", name: "20261011 주일예배 찬양.pdf")], "got \(parsed)")
        let now = day("2026-10-11")
        check("「Oct 10」 is this year's", same(ContiFolder.listingDate("Oct 10", now: now), "2026-10-10"))
        check("「Dec 20」 seen in October is last year's", same(ContiFolder.listingDate("Dec 20", now: now), "2025-12-20"))
        let dated = ContiFolder.parseFolderPage(#"<div id="entry-1AbCdEfGhIjK"><div class="flip-entry-title">20261011 콘티.pdf</div><div class="flip-entry-last-modified"><div>Oct 10</div>"#)
        check("the listing's modified date is read", dated.first?.modified != nil)
        // The church's 관심 채널 list sits in the same folder as a Doc.
        let withDoc = page + #"<div class="flip-entry" id="entry-1DoCiD123"><a href="https://docs.google.com/document/d/1DoCiD123/edit?usp=drive_web"><div class="flip-entry-title">SolaPraise 관심채널</div></a></div>"#
        let entries = ContiFolder.entries(inFolderPage: withDoc)
        check("every entry is listed, of any kind", entries.map(\.name) == ["20261011 주일예배 찬양.pdf", "Notes & plan.docx", "SolaPraise 관심채널"], "got \(entries.map(\.name))")
        check("an entry's link is its own, not the next one's",
              entries.map(\.link) == ["x", nil, "https://docs.google.com/document/d/1DoCiD123/edit?usp=drive_web"], "got \(entries.map(\.link))")
        check("PDFs are still all the 콘티 reader sees", ContiFolder.parseFolderPage(withDoc).count == 1)
        check("a Doc is read as text", SharedChannelList.exportURLs(id: "1DoCiD123", link: entries.last?.link).map(\.absoluteString)
              == ["https://docs.google.com/document/d/1DoCiD123/export?format=txt"])
        let listText = """
        주일 예배 2026
        https://www.youtube.com/playlist?list=PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        수요 예배 — https://youtube.com/playlist?list=PLbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&jct=SECRET
        https://www.youtube.com/watch?v=abcdefghijk&list=PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        https://www.youtube.com/playlist?list=WL
        """
        check("playlist links are found among notes, each once, without invite tokens",
              SharedChannelList.playlistIds(in: listText) == ["PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "PLbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
              "got \(SharedChannelList.playlistIds(in: listText))")
        let mixed = """
        2부예배 https://www.youtube.com/watch?v=AAAAAAAAAA1
        라이브 https://www.youtube.com/live/BBBBBBBBBB2?si=x, 짧게 https://youtu.be/CCCCCCCCCC3
        재생목록 https://www.youtube.com/watch?v=DDDDDDDDDD4&list=PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        다시 https://www.youtube.com/watch?v=AAAAAAAAAA1&t=30
        """
        let listing = SharedChannelList.listing(in: mixed)
        check("single videos are listed — watch, live, youtu.be — each once",
              listing.videos == ["AAAAAAAAAA1", "BBBBBBBBBB2", "CCCCCCCCCC3"], "got \(listing.videos)")
        check("a link naming a playlist is the playlist, not the video it was copied at",
              listing.playlists == ["PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] && !listing.videos.contains("DDDDDDDDDD4"))
        let csv = "종류,제목,링크,날짜\n영상,\"[주일] 10.11\",https://www.youtube.com/watch?v=EEEEEEEEEE5,2026-10-11\n"
        check("the sheet the manager's app writes reads back", SharedChannelList.listing(in: csv).videos == ["EEEEEEEEEE5"])
        check("a folder link gives its id",
              ContiFolder.folderId(fromLink: "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMn?usp=share_link") == "1AbCdEfGhIjKlMn")

        print(failures == 0 ? "\nall conti folder checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
