//
//  check-song-title-tidy.swift
//  SolaPraise
//
//  Checks SongTitleTidy: which cells of Songs and Attachments change when
//  video titles are tidied into song titles, and where the columns go.
//
//  WHY THIS EXISTS: it writes into the team's own sheet. A cell in the
//  wrong column, a 참고버전 typed by a leader overwritten, or an attachment
//  renamed out of step with its song would all look like the sheet simply
//  being that way. None of them would raise an error.
//
//  Run:
//      swiftc -O -o /tmp/titletidy \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift Sources/Feed/SongSearchSuggestions.swift \
//          Sources/Feed/PlanSongTitle.swift Sources/Team/SongTitleTidy.swift \
//          Tools/check-song-title-tidy.swift
//      /tmp/titletidy
//

import Foundation

@main
struct CheckSongTitleTidy {
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
        // The layout the team's sheet has: a Service column the app never
        // wrote, Key and Transpose after the link.
        let header = ["Date", "Service", "Order", "Title", "YouTubeURL", "Key", "Transpose", "Notes"]
        let layout = SongTitleTidy.layout(header: header)
        check("Key and Transpose move to just after Title", layout?.move == 5..<7, "got \(String(describing: layout))")
        check("참고버전 goes after them", layout?.insertReferenceAt == 6)
        check("a sheet that has 참고버전 is not rearranged",
              SongTitleTidy.layout(header: header + ["참고버전"]) == nil)
        check("Key and Transpose already beside Title: only 참고버전 is added",
              SongTitleTidy.layout(header: ["Date", "Order", "Title", "Key", "Transpose", "URL"])
                == .init(move: nil, insertReferenceAt: 5))

        // After the move: Title, Key, Transpose, 참고버전, URL.
        let tidied = ["Date", "Service", "Order", "Title", "Key", "Transpose", "참고버전", "YouTubeURL", "Notes"]
        let songs = [
            tidied,
            ["2026-10-18", "", "1", "새 노래 | NEW SONG | 어느 워십 | 앨범 이름", "", "", "", "https://www.youtube.com/watch?v=aaaaaaaaaaa", ""],
            ["2026-10-18", "", "2", "찬송가 100장 | '옛 찬송' | 가수 이름", "G", "", "", "https://www.youtube.com/watch?v=bbbbbbbbbbb", ""],
            ["2026-10-18", "", "3", "약칭평 | 다른 곡 (Other Song) [음반]", "", "", "", "https://www.youtube.com/watch?v=ccccccccccc", ""],
            // Tidy already, and a 참고버전 a leader typed: left alone.
            ["2026-10-18", "", "4", "이미 고친 곡", "", "", "손으로 쓴 메모", "https://www.youtube.com/watch?v=ddddddddddd", ""],
            ["2026-10-18", "", "5", "다섯째 곡 | 팀 이름", "", "", "손으로 쓴 메모", "", ""],
        ]
        let attachments = [
            ["Date ", "Song ", "Name ", "FileId ", "URL "],
            ["2026-10-18", "새 노래 | NEW SONG | 어느 워십 | 앨범 이름",
             "2026-10-18-새_노래_|_NEW_SONG_|_어느_워십_|_앨범_이름-123.jpg", "f1", "u1"],
            ["2026-10-18", "", "2026-10-18-콘티.pdf", "f2", "u2"],
        ]
        let plan = SongTitleTidy.plan(songs: songs, attachments: attachments,
                                      channels: ["ccccccccccc": "약속의 칭찬 평화"])
        func value(_ row: Int, _ column: Int) -> String? {
            plan.songs.first { $0.row == row && $0.column == column }?.value
        }
        check("the song as Title", value(2, 3) == "새 노래", "got \(value(2, 3) ?? "nil")")
        check("the recording as 참고버전, the English title left out",
              value(2, 6) == "어느 워십 · 앨범 이름", "got \(value(2, 6) ?? "nil")")
        check("a hymn keeps its number in the title",
              value(3, 3) == "옛 찬송 (찬송가 100장)", "got \(value(3, 3) ?? "nil")")
        check("the channel tells the team's acronym from the song",
              value(4, 3) == "다른 곡", "got \(value(4, 3) ?? "nil")")
        check("a tidy title is not rewritten", value(5, 3) == nil)
        check("a 참고버전 already written is never overwritten", value(6, 6) == nil)
        check("only Title and 참고버전 cells are written",
              plan.songs.allSatisfy { $0.column == 3 || $0.column == 6 })
        let song = plan.attachments.first { $0.column == 1 }?.value
        let name = plan.attachments.first { $0.column == 2 }?.value
        check("the attachment's Song matches the Songs tab", song == "새 노래", "got \(song ?? "nil")")
        check("its file name follows", name == "2026-10-18-새_노래-123.jpg", "got \(name ?? "nil")")
        check("a service file is left alone", !plan.attachments.contains { $0.row == 3 })

        // Tidying again changes nothing.
        var after = songs
        for cell in plan.songs { after[cell.row - 1][cell.column] = cell.value }
        check("tidying twice is tidying once",
              SongTitleTidy.plan(songs: after, attachments: nil,
                                 channels: ["ccccccccccc": "약속의 칭찬 평화"]).titles == 0,
              "got \(SongTitleTidy.plan(songs: after, attachments: nil, channels: ["ccccccccccc": "약속의 칭찬 평화"]).songs)")

        print(failures == 0 ? "\nall song title tidy checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
