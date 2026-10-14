# Changelog

## 0.8.1-alpha.4

- Starting screen recording from the memory window keeps the window open. Recording is
  on at once, and screens are saved again when the window closes, as before.

## 0.8.1-alpha.3

- **Recording no longer stops a minute after launch.** In 0.8.1-alpha.1 and alpha.2,
  reading older screens again ran text recognition at background priority beside the
  capture's own; Vision stalled both, so no screen was saved after the first minute and
  quitting or updating could hang. All text recognition now runs one request at a time
  at utility priority, and quitting or updating waits at most five seconds for capture.

## 0.8.1-alpha.2

- **Answers no longer fail over citation slips.** An answer that wrote a label in
  another form, or cited a memory in its text without listing it, failed with "The
  response cites evidence that was not supplied." Labels are now read leniently,
  references to evidence that was not supplied are removed from the answer, and only
  an answer whose citations were all invented is rejected.

## 0.8.1-alpha.1

- **Korean screen text.** Text recognition put English first, which dropped or garbled
  Korean, so Korean words on screen could not be found. Recognition now detects the
  language itself and reads Korean, English and Swedish on the same screen. Screens
  saved before this version are read again in the background, newest first and one at
  a time; it waits while on battery, and Settings > Screen Recording shows how many
  remain.
- **Time words in search.** 오늘, 어제 저녁, 지난주, 3일 전, 10월 13일, today, last week
  and similar words show that time instead of searching for the words. A time word
  alone spreads up to 96 activities across that time, and other words search the text
  inside it. Parts of the day count only beside a day word, since they are also
  everyday words.
- **Model and thinking level in search.** Menus next to the provider choose the model
  and its thinking level, and Settings has the same choices. Claude, Codex and Grok
  take the level as a setting (high unless changed); Gemini and Cursor models are
  grouped into families with their levels. While the model list loads, Settings keeps
  the saved model instead of opening the identifier field.
- **Escape starts a new search.** Closing search with Escape clears it, so the next
  search starts fresh; an answered search stays under recent searches, and one still
  answering is kept. The minimize button still keeps the search.
- **Apple Intelligence searches.** Search plans from the on-device model no longer fail
  as invalid: a same-day range means that day, unusable fields are dropped, time words
  in the question fill missing dates, and a wrong kind falls back to all memories.

## 0.8.0-alpha.1

- More AI providers. **Gemini** runs through Google's Antigravity CLI (`agy`), which
  replaced the personal Gemini CLI; **Cursor** through `cursor-agent`; **OpenCode** with
  its free models and no account, zero-retention models first; **Apple Intelligence**
  with Apple's on-device model on macOS 26; and **Ollama** with models on this Mac,
  downloadable from Settings. Every CLI keeps the no-tools contract: tools are denied
  by each CLI's own permissions and a kernel sandbox, and any tool use fails the request.
  Google has suspended accounts that used Gemini sign-ins through third-party tools;
  Reprise runs Google's own CLI and never reads the sign-in, but choose Gemini only if
  you accept that risk. With no model chosen, Gemini uses its light-thinking Flash
  model, about 6 seconds a request; Antigravity's own default thought for over a minute.
- **Install** in Settings > AI & Models runs a missing provider's official installer in
  Terminal. Apple Intelligence opens its System Settings page instead.
- **Meeting summaries.** When a transcript is ready, the chosen provider writes an
  overview, key points, decisions and action items, and a notification opens the
  recording. Long meetings are summarized in parts and merged. Recordings have Summary
  and Transcript tabs, and a summary says when its transcript has changed. Turn the
  automatic summary off in Settings > Audio & Meetings.
- **Recovery key.** Settings > Privacy > Encryption shows the library's recovery key
  after your Mac password or Touch ID, to copy or save. If the keychain loses the key,
  Reprise asks for it when it opens and puts it back.
- **Browser addresses.** Screens from Safari and Chromium browsers keep the page address,
  without fragments, sign-in tokens or private windows. Addresses are searchable and
  a button opens the page again. macOS asks once per browser; Settings > Privacy turns
  it off.
- **Multiple displays.** Reprise captures the display you are using: the one with the
  front window, or the one you scrolled or clicked in more recently than you typed.
  Each display keeps its own resolution, and 1x displays get sharper OCR.
- **Search.** Korean words now match with particles (회의 finds 회의에서), and the AI
  plans terms without particles and adds the English or Korean equivalent.
- The MCP `reprise_get_memory` tool returns a meeting's summary and a screen's address.

## 0.7.0-alpha.1

- The menu bar no longer makes a screen count as new. Its clock and live status items,
  such as CPU or network meters, changed in most captures. On one real hour, a fifth of
  saved screens differed only there or not visibly at all, and each one cost OCR and
  storage. The menu bar stays in the saved image but is left out of screen text, unless a
  full-screen app covers it.
- Compressed screens older than 7 days are re-encoded once at half resolution, never
  below 1280 pixels on the longer side. That uses a quarter of the pixels, so a month of
  history takes far less space; search text, thumbnails and the timeline are unchanged,
  but small text in old screenshots gets harder to read. Choose the age or turn it off in
  **Settings > Storage > Compression**.
- JPEG thumbnails from early versions are re-encoded as HEIC in the background, about
  half their size.

## 0.6.0-alpha.2

- Recent searches saved before encryption, including their saved answers, are sealed
  as soon as Reprise opens. 0.6.0-alpha.1 left them readable until the next search.

## 0.6.0-alpha.1

- The vault is encrypted. The database moves to SQLCipher (AES-256 with per-page HMAC,
  full-text search unchanged), and screenshots, thumbnails, imports, compressed screen
  movies, meeting recordings and search history are sealed with AES-256-GCM. New
  screens are encoded in memory and written only sealed; compressed movies are sealed
  fragment by fragment as they are encoded.
- One random key per library lives in the login keychain as “Reprise Vault Key”.
  Reprise and its MCP helper read it without asking; macOS asks you before any other
  program can. Deny such a request unless you started it.
- The first launch converts the existing library: the encrypted database is checked
  against the original before it replaces it, and older media are sealed in the
  background within a minute or two. A copy of a real library (3,500 memories,
  3,900 files, 440 MB) converted in about 8 seconds.
- MCP consent is signed with a keychain-derived key, so another program can no longer
  enable MCP access by editing `mcp-access.json`. The current setting is kept once
  during conversion. Restart MCP clients after updating so they launch the new helper.
- Meeting recordings are sealed when recording stops and are transcribed from the
  sealed file; playback and screen decoding read sealed files without plaintext copies.
- A library that cannot be opened, for example because its key is missing, now shows
  an explanation instead of crashing at launch.

`sqlite3`, Quick Look and other apps can no longer open vault files. If the login
keychain is reset, the vault cannot be decrypted. Apple Development signing and the
Sparkle public key are unchanged; this release is still unnotarized.

## 0.5.0-alpha.1

- Multilingual meeting transcription. Choose up to five languages in Audio settings.
  On macOS 26 and later, every chosen language hears the recording in one on-device
  SpeechAnalyzer pass, and each passage keeps the language whose recognizer is most
  confident. Speech models download as soon as a language is chosen; no Speech
  Recognition permission is needed. Earlier macOS versions use on-device Dictation
  models for each language.
- Screen compression. Screens older than 15 minutes move into HEVC movies, roughly
  4–7 times smaller than the HEIC stills in our samples. Search text, thumbnails and
  bookmarked screens are unchanged. Deleting a compressed screen also re-encodes its
  movie without it. New thumbnails are HEIC. Settings > Storage > Compression.
- Settings keep their values when a later version adds options. Earlier releases
  reset every setting in that case.
- Screen recording that was on resumes after a crash, force quit, power loss,
  restart or shutdown.
- The vault folder and database are now private to your macOS account (0700/0600);
  the database was readable by other local accounts.
- Bookmark and storage changes no longer rewrite the full-text index, and files left
  by an interrupted capture or compression are cleaned up.

The vault is still not application-encrypted. Apple Development signing and the
Sparkle public key are unchanged; this release is still unnotarized.

## 0.4.0-alpha.3

- Maintenance release to exercise the signed Sparkle update from alpha.2.
- No feature, settings, database schema or vault-location changes.

Apple Development signing and the Sparkle public key are unchanged. This release
is still unnotarized. A successful manual alpha.2 installation has been confirmed
on the maintainer's Mac; the earlier interruption's cause remains unconfirmed.

## 0.4.0-alpha.2

- Fix the MCP result initializer for the Swift toolchain used by GitHub Actions.
- Build each app in a fresh staging bundle before replacing the local artifact.
- Include explicit copy-and-open instructions in the DMG and distinguish copying
  failures from first-launch Gatekeeper approval.
- Publish new versioned DMG and ZIP downloads without replacing alpha.1 assets.

The reported installation interruption has not yet been reproduced or resolved.
This remains an Apple Development-signed, unnotarized alpha, not a notarization fix.

## 0.4.0-alpha.1

First public alpha.

- Native screen-memory timeline with local OCR, app icons, calendar navigation,
  recording-gap compression and configurable global shortcut.
- Inline AI search with memory citations, follow-up conversations and saved history.
- Explicit microphone/system-audio recording, local transcription and inline playback.
- Codex, Claude and Grok subscription CLI adapters with editable model selection.
- Opt-in read-only MCP tools and client installation from Settings.
- Sparkle updates from GitHub Releases with signed feed and archive verification.
- English documentation, Korean README, DMG and app ZIP distribution.

Known alpha limits include unencrypted local storage, incomplete title-based
privacy/meeting detection, sampled AI evidence, CLI compatibility requirements,
unavailable subscription quota, Apple Silicon-only prebuilt binaries and no Apple
notarization. Apple Intelligence/PCC and Rewind library migration are not included.
