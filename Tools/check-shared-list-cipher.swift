//
//  check-shared-list-cipher.swift
//  SolaPraise
//
//  Checks the sealed 관심 채널 list: what the church's password opens, what
//  it does not, and that a sealed cell is never read as links.
//
//  WHY THIS EXISTS: a list sealed wrongly is either open to everyone — the
//  point lost, silently — or opened by nobody, which looks like the church
//  having posted nothing. Both look like normal operation.
//
//  Run:
//      swiftc -O -o /tmp/listcipher \
//          Sources/Feed/SharedListCipher.swift Sources/Feed/SharedChannelList.swift \
//          Sources/Team/ContiFolder.swift Sources/Team/Keychain.swift \
//          Tools/check-shared-list-cipher.swift
//      /tmp/listcipher
//

import Foundation

@main
struct CheckSharedListCipher {

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
        let list = """
        재생목록\t주일 예배 2026\thttps://www.youtube.com/playlist?list=PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        영상\t[주일] 10.11.2026\thttps://www.youtube.com/watch?v=AAAAAAAAAA1
        """
        let password = "코너스톤2026"

        guard let sealed = SharedListCipher.seal(list, password: password) else {
            check("sealing works", false); exit(1)
        }
        check("a sealed list starts with its marker", sealed.hasPrefix(SharedListCipher.prefix))
        check("it does not show its links", !sealed.contains("list=") && !sealed.contains("watch?v="))
        check("the church's password opens it", SharedListCipher.open(sealed, password: password) == list)
        check("a wrong password does not", SharedListCipher.open(sealed, password: "코너스톤2025") == nil)
        check("no password is not an empty one", SharedListCipher.open(sealed, password: "") == nil)
        check("the same list sealed twice reads differently",
              SharedListCipher.seal(list, password: password) != sealed)

        // Korean typed on another keyboard can arrive decomposed.
        let decomposed = password.decomposedStringWithCanonicalMapping
        check("the password matches however its Hangul was composed",
              Array(decomposed.utf8) != Array(password.utf8) && SharedListCipher.open(sealed, password: decomposed) == list)

        var damaged = Array(sealed)
        damaged[damaged.count - 5] = damaged[damaged.count - 5] == "A" ? "B" : "A"
        check("a damaged cell opens to nothing, not to garbage", SharedListCipher.open(String(damaged), password: password) == nil)

        // As the members' app reads the sheet: CSV, the sealed cell beside
        // a plain row someone typed by hand.
        let csv = "SolaPraise,\(sealed)\n메모,https://youtu.be/BBBBBBBBBB2\n"
        let opened = SharedChannelList.listing(in: csv, password: password)
        check("with the password: sealed and plain links both",
              opened.playlists == ["PLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
              && Set(opened.videos) == ["AAAAAAAAAA1", "BBBBBBBBBB2"] && !opened.locked, "got \(opened)")
        let shut = SharedChannelList.listing(in: csv, password: nil)
        check("without it: only the plain link, and marked locked",
              shut.playlists.isEmpty && shut.videos == ["BBBBBBBBBB2"] && shut.locked, "got \(shut)")
        let wrong = SharedChannelList.listing(in: csv, password: "틀림")
        check("with a wrong one: the same", wrong.videos == ["BBBBBBBBBB2"] && wrong.locked)

        // Base64 can spell a link's shape; a sealed cell is never links.
        let tricky = SharedListCipher.prefix + "QUJD/live/ABCDEFGHIJKxyz0123456789+/=="
        check("a sealed cell is not read as a /live/ link",
              SharedChannelList.listing(in: tricky, password: nil).videos.isEmpty)

        print(failures == 0 ? "\nall shared list cipher checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
