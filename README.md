# SolaPraise

A two-purpose YouTube client for iOS. It shows only what you chose to see —
your worship music and your daily Word — with no recommendation feed and no
infinite scroll.

**Purpose 1 — Worship & music.** Search worship videos and songs, curate
playlists, share them, and edit your existing playlist library.
**Purpose 2 — The Word.** QT and prayer videos from your church channel and a
few others.

Playlists are your **real YouTube playlists**, read and written live through
the Data API — never a local copy, so they stay in sync with the YouTube app
and your TV. There is no backend, no database and no hosting: YouTube is the
store and SwiftData is only a local cache.

---

## Status

| Area | What | State |
|---|---|---|
| Player | Focus player, end-screen interception, drag-to-dock mini player | **Done — verified on device** |
| 말씀 | Channel whitelist, free RSS ingestion, daily reading, passage shortcuts | **Done** |
| 찬양 | Budgeted search with paging, topic searches, pinned playlists and sets | **Done** |
| 보관함 | Your real YouTube playlists, reorder and remove | **Done** (needs sign-in) |
| 예배 | Team schedule, three-state answers, 순서, 콘티 push, set-list archive | **Done** (needs a team sheet) |
| 작업실 | Line-in recording, chord detection, lead sheets, PDF export | **Done** (detection needs a device) |
| Sharing | Songbook PDF, collaborative playlists | Partial |

Most of the app works without signing in: an app-level API key covers the
feeds, search, playback and the readers. A Google account is needed only for
your own playlists and for the team sheet.

## Privacy

There is no backend and no account with this project. Nothing is collected,
stored or transmitted to anyone operating it, because there is nobody
operating it — the app talks to Google's APIs directly from the device.

- **Google sign-in** is optional and used for two things only: reading and
  editing *your own* YouTube playlists, and reading and writing the team's
  planning spreadsheet. The tokens live in the device keychain and are never
  sent anywhere else. Signing out deletes them.
- **Everything else** — the worship and Word feeds, search, playback, the
  Psalms, chord detection — runs without an account.
- **Audio you analyse** stays on the device. Files are read for chord
  detection and never uploaded.
- **Scripture** comes from Crossway's ESV API (non-commercial use) and a
  bundled public-domain 개역한글 Psalter.

The full [Privacy Policy](PRIVACY.md) and [Terms of Service](TERMS.md) are
in this repository.

---

### The embed origin bug — read this before touching the player

For a long stretch, almost nothing played: videos failed with error 152 and the
message *"the owner doesn't allow this video to be played in other apps."* That
message is misleading. The videos were fine.

**YouTube's embed requires the containing frame to have a real origin AND to
send a `Referer` header.** A WKWebView document that was never fetched over the
network has neither:

| How the player page is loaded | Origin | Referer | Result |
|---|---|---|---|
| `loadHTMLString(baseURL:)` | spoofed | none | fails (152) |
| `loadSimulatedRequest` | real | **none** | fails (152) |
| **served over loopback HTTP** | real | **yes** | **plays** |

So `LocalPlayerServer` runs a tiny `NWListener` HTTP server on 127.0.0.1 and the
player page is loaded from it. `NSAllowsLocalNetworking` in Info.plist permits
the http load. This was proven by serving the identical HTML from
`python3 -m http.server` and watching the same videos play in a browser.

**This does not bypass anything.** A video whose owner genuinely disabled
embedding still will not play. It only stops us being *falsely* rejected.

Two earlier conclusions in this project were wrong because of this bug, and are
corrected here: that most Korean CCM has embedding disabled (no evidence — that
was the referrer bug), and that the Simulator's failures were purely
environmental (they were, but they also masked this real bug for a long time,
because when nothing plays you cannot tell a broken embed from a blocked video).

### Verifying the end-screen interception

**Verified on device:** the video stops and an opaque "Done" card covers the
player with **no YouTube suggestion grid at any point**.

**YouTube embeds do not play in the iOS Simulator at all** — Safari there returns
"Video player configuration error 153" for a bare `youtube.com/embed/<id>` URL
with no app involved. Always verify playback on hardware.

```bash
xcrun devicectl device process launch --device <device-id> \
    --terminate-existing com.juyoungkim.solapraise \
    -- -uiTestVideoId <videoId> -uiTestSeekToEnd
```

Note the `--` separator: without it `devicectl` parses `-uiTestVideoId` as its
own flag.

## Build

```bash
brew install xcodegen      # once
xcodegen generate
open SolaPraise.xcodeproj
```

`SolaPraise.xcodeproj` is generated from `project.yml` and is **not** committed —
regenerate it rather than editing it by hand. (PraiseTheLord's loose-files
problem, avoided.)

Command-line build:

```bash
xcodebuild -project SolaPraise.xcodeproj -scheme SolaPraise -destination 'generic/platform=iOS Simulator' build
```

## One-time setup

### 1. Google Cloud Console

1. Create a project (e.g. **SolaPraise**).
2. **APIs & Services → Library** → enable **YouTube Data API v3**.
3. **OAuth consent screen** → External → fill in app name and support email →
   add your own Google account as a **test user**.
4. **Credentials → Create Credentials → OAuth client ID** → application type
   **iOS** → bundle id `com.juyoungkim.solapraise`.

### 2. Info.plist

Replace the two placeholders in `Sources/Info.plist`:

- `GIDClientID` → `<your-client-id>.apps.googleusercontent.com`
- the URL scheme → your **reversed** client id, e.g.
  `com.googleusercontent.apps.1234567890-abcdef`

### 3. Run

Run on the Simulator to browse your library. Phases 6–7 (key and chord
detection) need a **physical device** — the Simulator has no microphone.

> **Token lifetime.** While the Cloud project's publishing status is *Testing*,
> Google expires refresh tokens after **7 days**, so expect to tap sign-in
> again roughly weekly. Submitting the app for verification removes this.

## Daily psalm reading

The app opens on today's psalm once a day, full screen, before anything else.
Dismiss it and you land on the normal tabs; a 시편 tab returns to it anytime.
Free ← → navigation means you can keep reading, and **reading ahead carries
forward** — the daily advance moves on from wherever you actually stopped, not
from a fixed calendar slot. A local morning notification (default 06:30,
configurable in Settings) suggests the day's reading. A Share button posts the
psalm and "읽었습니다" into KakaoTalk or a team chat.

### Translations and licensing

This is the part that constrains the design, so it is worth stating plainly.

| Version | Status | How it is served |
|---|---|---|
| **개역한글 (KRV)** | Copyright **expired 2012** (대한성서공회's own copyright FAQ) | **Bundled** in `Resources/psalms-krv.json` — 150 chapters, 2,461 verses, ~294 KB, fully offline |
| **ESV** | Crossway's, licensed | Fetched live from `api.esv.org` under a free **non-commercial** key you supply in Settings |
| **개역개정** | 대한성서공회's, **not bundled** | Needs a 저작권 사용 허가 from 대한성서공회. Once granted it drops in as another `psalms-<code>.json` with no code change |

Two obligations are enforced in code, not left to good intentions:

- **Attribution is always displayed** beneath the text for both translations,
  and 개역한글's 동일성유지권 means the verse text is never altered — the build
  step strips only Strong's-number markup, never words.
- **ESV is never bundled and its cache is hard-capped at 500 verses**
  (`ESVClient.maxCachedVerses`). Crossway allow storing at most 500 verses or
  half a book, whichever is less; Psalms has 2,461 verses, so 500 is the
  ceiling. This is a licence term, not a performance tuning knob.

`bolls.life` lists ESV, NIV and others, but as a third party almost certainly
serving them unlicensed — it is used **only** for the public-domain 개역한글.

### Getting the ESV key

Register a free non-commercial application at [api.esv.org](https://api.esv.org/),
then paste the key into **Settings → 시편 읽기**. It is stored in UserDefaults on
device and is never committed. Without a key the Korean side still works
completely offline, and the English side shows a clear prompt rather than failing.

## Chord detection and 악보 생성

Playing a video and tapping **코드** listens through the microphone while the
YouTube player plays through the speaker — the same trick PraiseTheLord uses,
which keeps this clear of audio-extraction ToS concerns. Stopping produces a
chord sheet you can transpose and export as PDF.

**Requires a physical device.** The Simulator has no microphone, so the panel
sits at "듣는 중" forever there.

### What was fixed on import

PraiseTheLord's DSP was ported rather than rewritten, but it needed real work —
its README describes a pipeline the code did not run:

- **`DetectionSession` only wired `ChromaExtractor` → `ChordDetector`.**
  `NNLSChromaExtractor`, `BassDetector` and `ChordHMM` existed but were never
  called. All three are now in the chain: NNLS chroma → similarities → Viterbi
  smoothing, with the bass detector supplying slash chords.
- **`ChordDetector(includeSevenths: false)` was the default**, so it detected
  plain triads only — unusable for worship. Sevenths are on, and sus2/sus4/add9
  templates were added, since the README claimed that vocabulary and no
  templates existed for it.
- **`Chord` had no bass field**, so slash chords could not be represented even
  though `BassDetector` computed the note. Added, along with `/B` rendering and
  transposition.
- **`NNLSChromaExtractor` did not compile** — it read `self.noteCount` in `init`
  before all stored properties were initialised. Since PraiseTheLord ships no
  `.xcodeproj`, that file had probably never been built.

Note that sus2 and sus4 are pitch-class inversions of each other (Csus2 = C,D,G;
Gsus4 = G,C,D), so chroma alone cannot separate them — the bass detector is what
disambiguates.

**Chord charts only, never lyrics.** A chart generated by listening is your own
work; worship lyrics are licensed and would need your church's CCLI cover.

## 곡의 진행 and lyrics

Stopping detection produces a **lead sheet**: sections derived from the chord
timeline, transposable chords per section, and a lyrics field.

**Structure is derived, not fetched.** `SongStructure.detect` scores candidate
phrase lengths by how many chords are explained by a progression that repeats,
then chunks on the winner and merges neighbours sharing a progression. The
most-repeated progression is guessed to be 후렴 and the first is 절; every label
is renameable, because that guess is a heuristic.

The tie-break matters more than it looks: in a typical verse-chorus song, units
of 2, 4 and 8 all score identically, since an 8-chord block that repeats also
repeats at 4 and 2. Taking the shortest chops the song into meaningless
two-chord fragments; the longest swallows verse and chorus into one block. So
among tied winners it takes the **shortest multiple of four**.

**Lyrics are typed, never fetched.** Korean worship lyrics are copyrighted and
have no licensed API, so the app cannot reproduce them. What it does instead:

- **가사 찾기** opens a 네이버 or 구글 search for `"곡명" 가사`. A link out is not
  reproduction — the app never reads the page.
- A **Paste** button per section takes what you copied, so the round trip is
  two taps.
- A **CCLI number** field stamps the notice onto the exported PDF. A church
  copyright licence covers printing lyrics and chord charts; displaying that
  notice is the condition. Without a number, a sheet containing lyrics prints
  "가사 사용 시 CCLI 라이선스 필요" instead.

Confirm with **CCLI 코리아** what your church's licence actually covers — the
published terms are US-centric and app use may differ from projection and print.

## Debug launch arguments

All DEBUG-only, and all usable from `xcrun simctl launch` or Xcode's scheme
arguments. They exist because the Simulator can't be tapped from a script.

| Argument | Effect |
|---|---|
| `-uiTestVideoId <id>` | Open FocusPlayer directly on that video, skipping the sign-in gate |
| `-uiTestSeekToEnd` | Once ready, seek to 3s before the end so a real ENDED fires |
| `-uiTestBypassAuth` | Skip the sign-in gate — the Word feed needs no auth at all |
| `-uiTestSeedChannels <UC…,UC…>` | Seed channels into the Word whitelist |
| `-uiTestTab word\|worship\|library` | Force the starting tab |
| `-uiTestPerChannelCap <n>` | Override the 6-per-channel cap |
| `-uiTestSeedTopic <label>` | Seed a saved topic search |
| `-uiTestDrainQuota` | Spend the whole budget, to verify the refusal path |
| `-uiTestPsalm <n>` | Jump to a psalm |
| `-uiTestTranslation krv\|esv` | Force the reading translation |
| `-uiTestForceGate` | Re-arm the once-a-day reading gate |
| `-uiTestSkipGate` | Mark today's gate as already seen |
| `-uiTestShowPsalmGrid` | Open the 150-psalm grid |
| `-uiTestSeedRead <n>` | Mark psalms through n as read, for the colour coding |
| `-uiTestShowSearch` | Open the home search sheet |
| `-uiTestChordSheet` | Show a sample 악보, to check rendering and PDF without a mic |
| `-uiTestLeadSheet` | Show a sample lead sheet with derived 절/후렴 sections |

Example — the Word feed with a seeded channel:

```bash
xcrun simctl launch <udid> com.juyoungkim.solapraise \
    -uiTestBypassAuth -uiTestTab word \
    -uiTestSeedChannels UC_x5XG1OV2P6uZZ5FSM9Ttw
```

## Quota

The Data API allows 10,000 units/day, resetting at midnight Pacific.

| Call | Cost | Used for |
|---|---|---|
| `feeds/videos.xml` (RSS) | **0** | Channel updates — the whole Word feed is free |
| `playlists.list`, `playlistItems.list`, `videos.list`, `channels.list` | 1 | Library, durations, channel resolution |
| `search.list` | **100** | General search only — capped at 100/day and shown in the UI |
| `playlistItems.insert/update/delete`, `playlists.insert` | **50** | Playlist edits |

`QuotaLedger` charges every call *before* it goes out, so a burst can't
overshoot, and recognises YouTube's exhaustion reasons to degrade gracefully
instead of surfacing a raw 403.

## Distribution

This is built as a **personal** app. Sharing it publicly would require dropping
the end-of-video overlay (Phase 2), which YouTube's Developer Policies prohibit
(§III.I.4, §III.I.6, and the Required Minimum Functionality rules), plus Google
OAuth verification and a YouTube compliance audit. The end-of-video behaviour is
therefore isolated behind a single `EndBehavior` switch so that change stays
small. See the project plan for the full analysis.

## Provenance

Ported from `../PraiseTheLord`: `GoogleAuthManager`, `CurrentUser`, `SignInView`,
and `YouTubeID.parse`. Phases 6–7 import its DSP stack (`ChromaExtractor`,
`NNLSChromaExtractor`, `BassDetector`, `ChordDetector`, `ChordHMM`,
`KeyEstimator`) and `PDFExporter` unmodified. The quota limit-marker strategy
comes from `../Video_Organizer`.
