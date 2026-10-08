# Privacy Policy — SolaPraise

**Last updated: 7 October 2026**

SolaPraise is a free, open-source iPhone and iPad app built for a church
worship team. This policy describes what the app does with your information.

## The short version

**There is no server behind this app, and no operator collecting anything.**
The app runs entirely on your device and talks directly to Google's APIs and a
small number of other public services. No analytics, no advertising, no
tracking, no profiles. Nobody — including the developer — receives your data,
because there is nowhere for it to be sent.

## Information the app handles

### Your Google account (optional)

Signing in is optional. Most of the app — the worship and scripture feeds,
search, playback, the Psalms, and chord detection — works with no account at
all.

If you do sign in, the app requests two Google permissions:

| Scope | Why |
|---|---|
| `https://www.googleapis.com/auth/youtube` | To list, play from, and edit **your own** YouTube playlists. |
| `https://www.googleapis.com/auth/spreadsheets` | To read and write your team's planning spreadsheet. |

What happens to the resulting access and refresh tokens:

- They are stored in the **iOS Keychain on your device**.
- They are sent **only to Google**, to make the API calls above.
- They are never transmitted to the developer or to any third party.
- **Signing out deletes them**, and you can revoke access at any time at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

The app reads your account's email address and display name solely to show who
is signed in and to match you against the team roster on the spreadsheet. This
stays on the device and in that spreadsheet.

### Your team's planning spreadsheet

The scheduling features read and write a Google Sheet that **your team owns**.
It typically holds service dates, song lists, role assignments, and members'
names, email addresses, and availability responses.

The developer has no access to it. Who can read or edit that sheet is decided
entirely by your team's own Google Drive sharing settings. If you want your
information removed from it, ask whoever administers the sheet.

### Audio and the microphone

- **Audio files you choose** for chord analysis are read and processed
  **entirely on your device**. They are never uploaded anywhere.
- **The microphone**, if you use live chord detection or the recorder, is
  processed on your device. Recordings are saved in the app's own storage on
  your device and are not transmitted.
- Deleting the app removes all of it.

### Content you save in the app

Pinned videos, saved searches, channel lists, lead sheets, and any lyrics you
paste in are stored locally on your device using Apple's on-device storage.
They are not synced to the developer.

## Services the app contacts

Because the app talks to these services directly from your device, each one
necessarily sees your IP address and the request you make. Each has its own
privacy policy, which governs that interaction:

| Service | Used for |
|---|---|
| YouTube / Google APIs | Video feeds, search, playback, playlists |
| Google Sheets API | The team planning sheet |
| Crossway ESV API (`api.esv.org`) | English scripture text |
| API.Bible (`scripture.api.bible`) | Additional scripture translations |
| Apple iTunes Search API | Looking up recordings of a song |
| Naver / web search | Opening a sheet-music or audio search in your browser |

The app's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements. Specifically: data obtained through
these APIs is used only to provide the features described above, is never
sold, is never transferred to anyone else, and is never used for advertising
or for training machine-learning models.

## Children

The app is not directed at children under 13 and collects nothing from anyone.

## Changes

Any change to this policy will be committed to this repository, and the
revision history is public.

## Contact

Questions about this policy, or about the app's handling of data:
[open an issue](https://github.com/juyoungk-photo/SolaPraise/issues), or write
to the support address shown on the app's Google sign-in screen.
