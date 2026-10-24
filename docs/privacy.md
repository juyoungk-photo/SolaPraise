# SolaPraise 개인정보처리방침

시행일: 2026년 10월 23일

SolaPraise(이하 "앱")는 교회 찬양팀이 예배를 준비하고 함께 연습하도록 돕는 iPhone·iPad 앱입니다. 이 방침은 앱이 어떤 정보를 어디에서 다루는지 설명합니다.

**요약: 앱 개발자는 서버를 운영하지 않으며, 사용자 정보를 수집·판매·분석하거나 광고·추적에 쓰지 않습니다.** 앱이 다루는 정보는 사용자 기기 안에 있거나, 사용자가 로그인한 Google 계정(YouTube·Google 스프레드시트·Google 드라이브) 안에 있습니다.

## 1. Google 계정 로그인

앱은 Google 로그인을 사용합니다. 로그인하면 Google이 앱에 다음을 제공합니다.

- 계정 이메일 주소와 이름: 화면에 누구로 로그인했는지 보여 주고, 팀 시트의 팀원 명단에서 본인을 찾는 데 씁니다.
- 접근 권한(토큰): 기기의 키체인에 저장되며 개발자에게 전송되지 않습니다.

앱이 요청하는 권한과 쓰임은 다음과 같습니다.

| 권한 | 쓰임 |
|---|---|
| YouTube (`youtube`, `youtube.readonly`) | 내 재생목록 보기, 콘티를 재생목록으로 만들고 곡을 넣거나 빼기 |
| Google 스프레드시트 (`spreadsheets`) | 팀이 쓰는 시트에서 예배 일정·순서·배정·참여 응답을 읽고 쓰기 |
| Google 드라이브 (`drive.file`) | 앱이 올린 악보 파일, 또는 사용자가 직접 고른 파일·폴더만 읽고 쓰기 |

앱은 이 권한으로 얻은 정보를 위 목적 외에 쓰지 않고, 개발자나 제3자에게 보내지 않습니다. Google 사용자 데이터의 사용은 [Google API 서비스 사용자 데이터 정책](https://developers.google.com/terms/api-services-user-data-policy)(제한적 사용 요건 포함)을 따릅니다.

로그인 없이도 찬양·말씀 영상 보기, 성경 읽기, 작업실의 악보 보기 같은 기능은 쓸 수 있습니다.

## 2. 기기 안에만 저장되는 정보

다음은 사용자 기기 안에만 저장되며, 앱을 삭제하면 함께 지워집니다.

- 영상·재생목록 목록 캐시, 재생 기록, 설정
- 작업실에 둔 악보 파일, 악보 코드 교정, 그리기, 책갈피, 악보별 글자 크기와 키
- 녹음: 사용자가 연결한 오디오 장치로 녹음한 파일

## 3. 마이크

마이크는 사용자가 코드 분석이나 녹음을 시작할 때만 켜집니다. 소리는 기기 안에서 분석되며 어디로도 전송되지 않습니다. 녹음 파일은 기기 안에만 저장됩니다.

## 4. 근처 팀원 기기와의 연결

팀 연습 중 악보를 열면, 같은 팀의 근처 기기와 Wi-Fi·블루투스로 직접 연결해 악보 교정, 그리기, 세션 리더의 위치를 주고받습니다. 이때 화면에 보일 이름(팀 명단의 이름 또는 기기 이름)과, 그리기의 주인을 가리기 위해 이메일에서 만든 식별값(해시, 이메일로 되돌릴 수 없음)이 함께 전달됩니다. 연결은 암호화되며, 인터넷이나 서버를 거치지 않고, 같은 팀 시트를 쓰는 기기끼리만 연결됩니다(팀 시트를 연결하지 않은 기기는 같은 상태의 근처 기기끼리). 이 기능을 위해 iOS의 「로컬 네트워크」 권한을 요청합니다.

## 5. 사진

「사진에 저장」을 누를 때만 악보 이미지를 사진 보관함에 추가합니다. 앱은 사진 보관함의 기존 사진을 읽지 않습니다.

## 6. 앱이 연결하는 외부 서비스

앱은 기능을 위해 다음 서비스에 요청을 보냅니다. 각 서비스는 자체 개인정보처리방침을 따릅니다.

- YouTube·Google(영상 재생과 검색, 시트·드라이브, 로그인)
- 성경 본문: ESV API(Crossway), API.Bible
- 악보·음원 검색: 사용자가 연 웹 페이지(Google 이미지 검색, 악보 사이트 등), Apple iTunes 검색, Internet Archive

## 7. 팀 시트와 드라이브의 정보

예배 일정, 배정, 참여 응답, 첨부한 악보 등은 팀이 정한 Google 스프레드시트와 드라이브에 저장되며, 그 시트·드라이브의 공유 설정에 따라 팀원이 볼 수 있습니다. 이 정보의 관리와 삭제는 Google에서 시트·드라이브 소유자가 합니다.

## 8. 정보의 삭제

- 기기 안의 정보: 앱을 삭제하면 지워집니다.
- 앱에 준 Google 권한: 앱에서 로그아웃하거나, [Google 계정 › 보안 › 타사 앱 액세스](https://myaccount.google.com/permissions)에서 언제든 철회할 수 있습니다.
- 팀 시트·드라이브의 정보: 시트·드라이브 소유자에게 요청하세요.

## 9. 어린이

앱은 만 14세 미만 어린이를 대상으로 하지 않습니다.

## 10. 변경

이 방침이 바뀌면 이 페이지에 시행일과 함께 올립니다.

## 11. 문의

[연락처 이메일]

---

# SolaPraise Privacy Policy (English)

Effective: October 23, 2026

SolaPraise ("the app") helps church worship teams prepare services and rehearse together on iPhone and iPad.

**In short: the developer runs no server and does not collect, sell, analyse, or use your information for advertising or tracking.** What the app handles stays on your device or in the Google account you sign in with (YouTube, Google Sheets, Google Drive).

**Google sign-in.** The app receives your email address and name to show who is signed in and to find you on your team's roster. Access tokens are kept in the device keychain and never sent to the developer. Scopes requested:

- YouTube (`youtube`, `youtube.readonly`): view your playlists; create a service set list as a playlist and add or remove its songs.
- Google Sheets (`spreadsheets`): read and write the team's sheet — services, order of worship, assignments, sign-up answers.
- Google Drive (`drive.file`): only files the app uploads (charts) or files and folders you pick yourself.

Google user data is used only for these purposes, is not transferred to the developer or third parties, and is handled in accordance with the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

**On the device only:** caches of videos and playlists, playback history, settings, charts kept in 작업실, chord corrections, drawings, bookmarks, chart sizes and keys, and recordings made from a connected audio interface. Deleting the app deletes them.

**Microphone:** used only when you start chord analysis or a recording. Audio is analysed on the device and never transmitted.

**Nearby devices:** while a chart is open during rehearsal, the app connects directly (Wi-Fi/Bluetooth) to nearby devices of the same team to exchange chart corrections, drawings and the session leader's position, together with a display name and, to tell whose drawing is whose, an identifier hashed from the email (it cannot be turned back into the address). The connection is encrypted, does not use the internet or any server, and is limited to devices using the same team sheet (devices with no team sheet connect only with others in the same state). The app asks for iOS Local Network permission for this.

**Photos:** the app adds a chart image to your library only when you choose 「사진에 저장」. It does not read your photos.

**Services contacted:** YouTube and Google (playback, search, Sheets, Drive, sign-in); ESV API (Crossway) and API.Bible for scripture; web pages you open to find charts (e.g. Google Images, chart sites), Apple iTunes Search and the Internet Archive. Each follows its own privacy policy.

**Team sheet and Drive:** service data and attached charts live in the team's Google Sheet and Drive, visible to team members per their sharing settings, and are managed and deleted there by their owners.

**Deletion:** delete the app to remove on-device data; sign out or revoke access at [Google Account › Third-party access](https://myaccount.google.com/permissions) at any time.

**Children:** the app is not directed to children under 14.

**Changes:** updates are posted on this page with their effective date.

**Contact:** [contact email]
