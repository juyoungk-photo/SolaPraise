# SolaPraise — working rules

## iPad and iPhone: layout may differ, features may not

**Layout and UI are allowed to be arranged and optimised differently for each
device. Features are not.** Unless an exception is written down explicitly, a
feature is developed for both at the same time and works on both.

Different is fine, and often right:

- iPad draws its own bottom tab bar; iPhone keeps the system one.
- 작업실 is a tab of its own on iPad and lives inside 보관함 on iPhone.
- The 악보 lays sections out side by side on iPad and in one column on iPhone.
- A phone in landscape gives the player the whole height; an iPad does not.

Missing is not. These all shipped broken on one device only, and each was
found by the user rather than by me:

- **말씀 was moved before 찬양 on iPad and not on iPhone.** The order was
  written down twice — `tabItems`, which the iPad bar reads, and the
  `TabView` body, which is what the iPhone bar renders. One got the edit.
- **작업실 was unreachable on iPhone when signed out**, because 보관함
  replaced its whole tab with the sign-in prompt, and on iPhone 작업실 lives
  only inside 보관함.
- **The iPad 악보 had no Key/transpose row and no CCLI footer**, because both
  were `Section`s wrapped in a `Form` inside a `ScrollView`, where a Form
  collapses to nothing.
- **보관함 and 작업실 showed two tab bars on iPad**, because they were the
  last two tab roots still using a large title.

### What this means in practice

1. **Prefer one source of truth over two parallel ones.** The tab bug was not
   a missed edit so much as a structure that required the same edit twice and
   never said so. When a device needs different presentation, branch at the
   presentation, not at the list of what exists.
2. **Verify on both simulators before saying something is done.** Build,
   install and screenshot on an iPhone *and* an iPad. "It builds" is not
   verification, and neither is checking the device the change was written
   for.
3. **Check the states, not just the screen.** Signed out as well as signed in;
   empty as well as populated. 작업실 was present on both devices and
   invisible on one of them only when signed out.
4. **If a feature genuinely should exist on one device only, say so in a code
   comment where it is decided**, with the reason. `showsStudioTab` is the
   model: it states that iPad has room for the tab and that iPhone keeps
   4 tabs rather than 5.

## Verification

- Both simulators, every time: `iPhone 17` and `iPad Pro 11-inch (M5)`.
- `xcodegen generate` after adding a file, or the build will not see it.
- Prefer a runnable check over an assertion for anything that parses or
  builds a string — those fail silently and look like "no data yet". See
  `Tools/check-sheet-urls.swift`, `check-church-sheet.swift`,
  `check-episode-date.swift`, `check-song-structure.swift`, and
  `check-score-ocr.swift`, which draws a score page and runs the real
  chord recogniser on it.
- Report what was actually verified and what was only reasoned about. Rotation
  and microphone behaviour cannot be driven from here; say so rather than
  implying they were tested.

## Secrets

`Secrets.xcconfig` is gitignored and must never be committed. The repository
is public: no API keys, no sheet ids, no personal addresses, no church
account handles — in code, comments or commit messages.
