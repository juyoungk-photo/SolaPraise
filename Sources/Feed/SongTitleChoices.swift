//
//  SongTitleChoices.swift
//  SolaPraise
//
//  The song a video is of, as a person chose or typed it — kept by video,
//  so everything that reads a song out of a video's title starts from it.
//
//  WHY: a title is read out of the video's own, and the reading sometimes
//  takes an album or a worship series for the song. When it is put right
//  — in 곡 제목 확인, as a playlist fills the 콘티 — the player went on
//  suggesting searches for the series. The correction is now the title
//  the player searches with, finds 악보 and 음원 by, and adds to a 콘티 as.
//
//  Kept on this device. The team's own title for a video, from a 순서,
//  is the next best (TeamStore.songTitle(forVideo:)).
//

import Foundation

enum SongTitleChoices {
    private static let key = "song.titleChoices"

    static func title(for videoId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[videoId]
    }

    /// Nil forgets the choice: the reading is right again.
    static func set(_ title: String?, for videoId: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let text = title?.trimmingCharacters(in: .whitespaces)
        all[videoId] = text?.isEmpty == false ? text : nil
        UserDefaults.standard.set(all, forKey: key)
    }
}
