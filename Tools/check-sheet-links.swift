//
//  check-sheet-links.swift
//  SolaPraise
//
//  Checks which links in a video's description are offered as the team's
//  own 악보.
//
//  WHY THIS EXISTS: 「PayPal | info@markersworship.com」 was offered under
//  「이 팀이 올린 악보」 — the domain taken out of an e-mail address, and the
//  domain a known 악보 store. A wrong link here looks like a real one.
//
//  Run:
//      swiftc -O -o /tmp/sheetlinks \
//          Sources/Chords/WorshipSetParser.swift Tools/check-sheet-links.swift
//      /tmp/sheetlinks
//

import Foundation

@main
struct CheckSheetLinks {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    static func main() {
        let description = """
        오직 예수로 가슴 뛰는 삶
        PayPal | info@markersworship.com
        후원 계좌 https://example.org/give
        악보 구매 👉 https://markersworship.com/shop
        온라인샵 (음반 악보 MR 판매) ㅣ anointingmusic.com
        문의: hello@anointingmusic.com
        """
        let links = WorshipSetParser.sheetMusicLinks(description)
        let hosts = links.map { $0.url.host ?? "" }
        check("a store link with a 악보 label is offered", hosts.contains("markersworship.com"))
        check("a bare store domain is offered", hosts.contains("anointingmusic.com"))
        check("an e-mail address is never a 악보 link",
              !links.contains { $0.label.contains("@") || $0.url.absoluteString.contains("@") }, "got \(links.map(\.label))")
        check("a PayPal or 후원 line is never a 악보 link",
              !links.contains { $0.label.lowercased().contains("paypal") || $0.label.contains("후원") }, "got \(links.map(\.label))")
        check("each store once", hosts.count == Set(hosts).count, "got \(hosts)")

        print(failures == 0 ? "\nall sheet link checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
