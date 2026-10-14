//
//  LyricSpacing.swift
//  SolaPraise
//
//  Korean word spacing (띄어쓰기) put back into lyrics read off a score, and
//  the syllables recognition commonly confuses put right.
//
//  WHY: a lead sheet prints one syllable under each note, evenly spaced —
//  「찬 양 하 —며— 경 배 —해—」 — so the page says nothing about where one
//  word ends. Read bar by bar, the 코드표 showed 「하며경 | 배해귀」: words
//  cut in half, and a singer reading a phrase that was never written. The
//  spacing has to come from the language. iOS's tokenizer does not split
//  unspaced Korean (measured: it returns the whole line as one token), so
//  this does: a vocabulary of the words worship songs use, the particles
//  and endings that close a word (의 을 를 · 하며 하신 하리라 …), and a
//  search for the reading that explains a line with known words.
//
//  The same search corrects recognition. Vision reads 「며」 as 「묘」,
//  「주」 as 「추」, 「사랑」 as 「사람」; each confusable syllable is tried
//  both ways and kept the way that makes Korean — 「하묘」 is not a word,
//  「하며」 is. A reading that fits as it is, is left as it is.
//
//  Pure Foundation, so Tools/check-lyric-spacing.swift runs it.
//

import Foundation

enum LyricSpacing {

    /// The syllables as they should read, and which of them begin a word.
    struct Result: Equatable {
        var syllables: [String]
        var startsWord: [Bool]

        /// The line written out with its spaces.
        /// One entry per syllable given — a dropped stray is "" — so the
        /// result lines up with the notes it was read from.
        var text: String {
            var out = ""
            for (syllable, starts) in zip(syllables, startsWord) where !syllable.isEmpty {
                if starts, !out.isEmpty { out += " " }
                out += syllable
            }
            return out
        }
    }

    /// One line of sung syllables — one per note, as printed — spaced and
    /// corrected. Non-Korean syllables pass through, each its own word.
    static func space(_ syllables: [String]) -> Result {
        guard !syllables.isEmpty else { return Result(syllables: [], startsWord: []) }
        // Runs of Hangul are spaced; anything else stands alone.
        var out = Result(syllables: [], startsWord: [])
        var run: [String] = []
        func flush() {
            guard !run.isEmpty else { return }
            let spaced = spaceHangul(run)
            out.syllables += spaced.syllables
            out.startsWord += spaced.startsWord
            run = []
        }
        for syllable in syllables {
            if isHangulSyllable(syllable) {
                run.append(syllable)
            } else {
                flush()
                out.syllables.append(syllable)
                out.startsWord.append(true)
            }
        }
        flush()
        if let first = out.startsWord.indices.first { out.startsWord[first] = true }
        return out
    }

    static func isHangulSyllable(_ text: String) -> Bool {
        text.count == 1 && text.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
    }

    // MARK: - The search

    /// Cheapest reading of a run of Hangul syllables as words.
    ///
    /// A word is a stem — a known word, or failing that unknown syllables,
    /// which cost the most — followed by any number of particles and
    /// endings. Each word costs a little, so a line is not cut into more
    /// words than its vocabulary explains; each substituted syllable costs
    /// more, so a reading is only changed when the change buys real words.
    private static func spaceHangul(_ syllables: [String]) -> Result {
        let n = syllables.count
        let maxWord = 9
        var best = [Double](repeating: .infinity, count: n + 1)
        var back = [(from: Int, word: [String])](repeating: (0, []), count: n + 1)
        best[0] = 0
        for end in 1...n {
            for start in max(0, end - maxWord)..<end where best[start] < .infinity {
                let piece = Array(syllables[start..<end])
                guard let (cost, reading) = bestWord(piece) else { continue }
                if best[start] + cost < best[end] {
                    best[end] = best[start] + cost
                    back[end] = (start, reading)
                }
            }
        }
        // Rebuild.
        var words: [[String]] = []
        var at = n
        while at > 0 {
            words.append(back[at].word)
            at = back[at].from
        }
        words.reverse()
        var result = Result(syllables: [], startsWord: [])
        for word in words {
            var started = false
            for syllable in word {
                result.syllables.append(syllable)
                result.startsWord.append(!started && !syllable.isEmpty)
                if !syllable.isEmpty { started = true }
            }
        }
        return result
    }

    /// The best reading of a stretch as ONE word, over the confusable
    /// spellings of its syllables.
    private static func bestWord(_ piece: [String]) -> (Double, [String])? {
        var best: (Double, [String])?
        func walk(_ index: Int, _ chosen: [String], _ penalty: Double) {
            if index == piece.count {
                if let cost = wordCost(chosen) {
                    let total = cost + penalty
                    if best == nil || total < best!.0 { best = (total, chosen) }
                }
                return
            }
            let syllable = piece[index]
            walk(index + 1, chosen + [syllable], penalty)
            for alternative in confusable[syllable] ?? [] {
                walk(index + 1, chosen + [alternative], penalty + substitutionCost)
            }
            if dropped.contains(syllable) {
                // Kept as "" so the line stays aligned with its notes.
                walk(index + 1, chosen + [""], penalty + substitutionCost)
            }
        }
        walk(0, [], 0)
        return best
    }

    private static let wordCost_base = 0.6
    private static let unknownSyllableCost = 1.4
    private static let suffixCost = 0.12
    private static let substitutionCost = 0.9

    /// What one word costs as stem + suffixes, or nil when it cannot be one.
    private static func wordCost(_ withDropped: [String]) -> Double? {
        let word = withDropped.filter { !$0.isEmpty }
        guard !word.isEmpty else { return nil }
        let text = word.joined()
        var best: Double?
        for split in 1...word.count {
            let stem = word[0..<split].joined()
            let rest = Array(word[split...])
            // Only some nouns take 하다: 사랑하며, never 사람하며 — which is
            // what turns a misread 「사람하며」 back into 「사랑하며」 and
            // leaves 「사람의」 alone.
            if let first = rest.first, hada.contains(first), lexicon.contains(stem), !hadaStems.contains(stem) {
                continue
            }
            let stemCost: Double
            if lexicon.contains(stem) {
                stemCost = 0
            } else if split <= 3 {
                stemCost = Double(split) * unknownSyllableCost
            } else {
                continue
            }
            guard let suffix = suffixChainCost(rest) else { continue }
            let total = wordCost_base + stemCost + suffix
            if best == nil || total < best! { best = total }
        }
        // A whole known word, even one that looks like stem + ending.
        if lexicon.contains(text) { best = min(best ?? .infinity, wordCost_base) }
        return best
    }

    /// Particles and endings after a stem, as a chain of known pieces. An
    /// ending that makes the word describe the next one — 하「신」, 하「는」,
    /// 당「할」 — closes it: nothing follows it in the same word, which is
    /// what keeps 「귀하신 만왕의」 from reading as 「귀하신만 왕의」.
    private static func suffixChainCost(_ rest: [String]) -> Double? {
        if rest.isEmpty { return 0 }
        var best = [Double](repeating: .infinity, count: rest.count + 1)
        var closed = [Bool](repeating: false, count: rest.count + 1)
        // After a particle only another particle: 「에서」, 「에게」, 「로도」 —
        // never an ending, which is how 「때에 기도로」 read as one word.
        var afterParticle = [Bool](repeating: false, count: rest.count + 1)
        best[0] = 0
        for end in 1...rest.count {
            for start in max(0, end - 4)..<end where best[start] < .infinity && !closed[start] {
                let piece = rest[start..<end].joined()
                guard suffixes.contains(piece), !afterParticle[start] || particles.contains(piece) else { continue }
                if best[start] + suffixCost < best[end] {
                    best[end] = best[start] + suffixCost
                    closed[end] = closing.contains(piece)
                    afterParticle[end] = particles.contains(piece) && !endings.contains(piece)
                }
            }
        }
        return best[rest.count] < .infinity ? best[rest.count] : nil
    }

    /// The forms of 하다 that join a noun into a verb.
    static let hada: Set<String> = ["하", "해", "한", "할", "함", "합", "히"]

    /// Known words that take 하다 (or, for 영원 and the like, 히). An
    /// unknown stem may; a known word not listed here may not.
    static let hadaStems: Set<String> = {
        let words = """
        찬양 찬송 경배 예배 감사 기도 노래 사랑 축복 선포 고백 순종 인도 동행 구원 의지 간구 승리 창조 회복 치유
        거룩 전능 합당 위대 영원 귀 존귀 신실 충만 영화 선 위태 당 평안 강 크 진실 온전 겸손 자유 영광 위 향 원 말 생각 기억
        """
        return Set(words.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }()

    /// Case and other particles: what follows a noun.
    static let particles: Set<String> = [
        "의", "을", "를", "은", "는", "이", "가", "에", "께", "께서", "에게", "와", "과", "로", "으로",
        "도", "만", "뿐", "여", "이여", "부터", "까지", "처럼", "같이", "보다", "마다", "에서", "엔",
    ]

    /// Pieces that are endings as well as particles — 는, 도 — so a word
    /// may go on after them as an ending would.
    static let endings: Set<String> = ["는", "이", "여", "가", "뿐"]

    /// Endings after which a word is over.
    static let closing: Set<String> = [
        "신", "시는", "는", "한", "할", "된", "될", "던", "운", "울", "린", "릴", "이신", "으신",
        // particles that are the last thing a word can carry
        "의", "을", "를", "와", "과",
    ]

    // MARK: - Recognition

    /// Syllables Vision mistakes for one another on a lead sheet, each with
    /// what it was more likely meant to be.
    static let confusable: [String: [String]] = [
        "묘": ["며"], "며": ["묘"],
        "추": ["주"], "쥬": ["주"],
        "람": ["랑"], "랑": ["람"],
        "섬": ["심"], "듬": ["름"],
        "뫼": ["외"], "쟈": ["자"],
    ]

    /// Syllables that are noise on a lyric line — a stroke read as Hangul.
    static let dropped: Set<String> = ["힣"]

    // MARK: - Vocabulary

    /// Particles and endings that close a word, alone or chained:
    /// 하 + 신 = 하신, 하 + 리 + 라 = 하리라, 의, 을 …
    static let suffixes: Set<String> = [
        // particles
        "의", "을", "를", "은", "는", "이", "가", "에", "께", "께서", "에게", "와", "과",
        "로", "으로", "도", "만", "뿐", "여", "이여", "아", "야", "부터", "까지", "처럼",
        "같이", "보다", "마다", "서", "에서", "엔", "란", "이란", "라", "이라",
        // 하다 and its forms
        "하", "해", "한", "할", "함", "합", "히", "하여", "하네",
        // endings
        "며", "고", "신", "시", "시는", "시며", "시고", "시니", "시네", "셨", "셨네",
        "는", "니", "니다", "다", "라", "리", "리라", "리니", "리로다", "로다", "네",
        "어", "아", "여", "게", "기", "소서", "요", "죠", "든", "면", "자",
        "이신", "이시", "이시며", "으신", "으시", "으니", "으나", "으면", "으며", "심", "음", "도록",
        "운", "울", "린", "릴", "수록", "일세", "니라", "리요", "던",
        "였", "었", "았", "겠", "습", "옵", "나이다", "도다", "세", "세요",
        "드려", "드리", "드리네", "드리리", "려", "렵", "러",
    ]

    /// Words worship songs use — nouns, and the stems verbs and adjectives
    /// are built on. Not exhaustive: an unknown word still comes out whole,
    /// at a higher cost; this is what lets the search tell 「귀하신 만왕의」
    /// from 「귀하신만 왕의」.
    static let lexicon: Set<String> = {
        let words = """
        주 주님 하나님 아버지 예수 예수님 그리스도 성령 성부 성자 여호와 하늘 아버지 임마누엘 메시야 메시아
        어린양 왕 만왕 주인 목자 반석 피난처 요새 방패 산성 구주 구세주 친구 신랑 근원 근원자
        알파 오메가 처음 나중 시작 끝 이름 보좌 나라 영광 능력 권세 위엄 존귀 찬양 찬송 경배 예배 감사 기도 노래
        사랑 은혜 자비 긍휼 평화 평강 기쁨 소망 믿음 진리 생명 빛 길 말씀 약속 축복 복 영 마음 영혼 몸 삶 평생 일생
        세상 땅 하늘 바다 산 강 물 불 바람 구름 별 해 달 날 밤 아침 오늘 내일 영원 영원히 이제 지금 모든 만물 만민 열방 민족
        나 너 우리 그대 당신 그 저 내 네 그의 주의 자녀 백성 형제 자매 교회 성전 제단 십자가 보혈 피 죽음 부활 생명수
        구원 구속 회복 치유 자유 승리 소망 거룩 전능 합당 위대 귀 신실 충만 선 선하 크 높 높이 깊 넓 놀라 아름답 존귀
        따르 살 살아 살리 계 계신 오 오신 가 가신 보 보내 받 받기 주시 주신 드리 엎드리 엎드려 나아가 나아 서 앉 일어나
        부르 외치 노래하 춤추 기뻐 즐거 감사하 사랑하 찬양하 경배하 예배하 다스리 다스 창조 창조주 섬기 따라 함께
        영화 영광스러 존귀하 전능하 거룩하 위대하 합당하 신실하 영원하 귀하 선하 크신 높으신 계시 되 되신 이루 이루시 이루신
        십자가의 은혜로 날마다 언제나 항상 오직 다만 다시 또 더 가장 참 늘 홀로 함께 곁 앞 뒤 안 위 아래 속 가운데
        되 되신 어려운 일 당 당하 무슨 세월 지나 갈 것 더욱 의지 적 밝히 비춰 비추 인도 위태 도움 간구 천국 올라 동안 어둘 어두운 밝을 밝은 사람 끝날 아들 딸
        """
        return Set(words.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }()
}
