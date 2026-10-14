# Changelog

## 0.9.0-alpha.1

- **Choose the transcription engine.** Settings > Audio & Meetings offers three:
  Apple's speech models on this Mac (as before), OpenAI's Whisper on this Mac through
  WhisperKit, and OpenAI's newest transcription models online. Whisper downloads once
  from Hugging Face, in the size you pick (Large v3 Turbo, 627 MB, is recommended), and
  recordings never leave the Mac. OpenAI offers GPT Transcribe, GPT Live Transcribe,
  GPT-4o Transcribe, GPT-4o mini Transcribe and GPT Realtime Whisper.
- **OpenAI with a ChatGPT plan or an API key.** With a ChatGPT plan, Reprise asks the
  Codex CLI on this Mac for its ChatGPT sign-in each time, keeps it in memory and never
  stores it. Without a subscription, an OpenAI API key works instead; it stays in the
  login keychain. The recording goes to OpenAI in ten-minute pieces, three at a time,
  and an hour of audio takes about a minute. When neither account works, or OpenAI
  fails, the recording is transcribed with Apple on this Mac, and the transcript says so.
- **Transcribe again with another engine.** The transcribe button in a recording uses
  the chosen engine; its menu transcribes that one recording with another.
- **Speaker labels.** Turn on Label speakers and a speaker model, about 30 MB, finds who
  is speaking, on this Mac, with every engine. The transcript and its text name each
  speaker, such as Speaker 1; click a name to rename that speaker everywhere in the
  recording, so summaries and searches say who said what. Recordings up to two hours
  are labeled.
- **Long follow-up threads keep their topic.** Each question still carries the last four
  turns in full, and now also up to eight earlier questions of the same thread.

## 0.8.2-alpha.2

- **The search bar fits again.** Fast mode is a bolt button beside the thinking level,
  so the Audio switch keeps its full width.
- **Recordings open only when you choose them.** Moving through the timeline steps
  through screens alone. A recording opens from its lane under the timeline, at the
  moment you click, from search results or from a citation, and stays open while the
  timeline is anywhere within the recording, not just at its start. The recording panel
  has close and delete buttons.
- **Context window choice.** Settings > AI & Models offers the windows the provider's
  CLI has for the model: Claude 1M or 500K on its latest models, Grok 256K or 500K.
  Claude Code works within 500K and compacts at its edge while the model keeps 1M. Grok
  applies a window only to a model named on its command line, so choosing one while
  Grok's default model is in use names that model. Codex keeps the window its own model
  catalog sets.
- **Codex follows the catalog it uses.** When Codex's own config names a model catalog
  with `model_catalog_json`, Reprise lists models, thinking levels, Fast mode and context
  windows from that file, as Codex does, instead of from Codex's download cache. Models a
  proxy serves under a provider prefix, such as `cursor/...`, are left out, because
  Reprise runs Codex against OpenAI directly.
- **Grok shows its context window.** Grok answers show the ring too, 256K by default.
  Reprise reads the window from the model list the Grok CLI downloads for each request,
  and the choices in Settings from the CLI's cached copy of that list, taking only the
  window fields.

## 0.8.2-alpha.1

- **Fast mode.** A Fast switch next to the thinking level, and in Settings, for models
  that have one. Claude uses its `fastMode` setting on Opus 5.5, Opus 5 and Opus 4.8;
  Anthropic bills it to usage credits even while the plan has usage left. Codex uses
  the Fast service tier its model catalog lists, such as "2x speed, increased usage".
  Grok and Cursor switch to the model's `-fast` twin, so their model menus now list
  each model once. Turning Fast mode on asks first and says what it costs.
- **Context use.** Each answer shows how much of the model's context window the request
  filled, as a ring with a percentage, for Claude, Codex, OpenCode and Ollama. Grok,
  Gemini and Cursor report the tokens but not their window, so only the count shows.
  Reprise sends the last few turns and fresh excerpts with every question, so a long
  conversation never fills the window.
- **Recordings stay in view during search.** The recording panel above the bottom bar
  stays open while search is open. Choosing a recording in the results opens it there
  instead of inside the results.
- **Audio filter switches at once.** Turning on Audio or choosing an app no longer
  shows the previous screen results until the new list arrives.
- **Search Only shortcut.** A second shortcut in Settings > General opens just the
  search box, with no memory view behind it, and leaves the menu bar and Dock in place.
  Escape or a click elsewhere closes it, and opening a memory from it shows the full
  view. It has no default; record one to use it.

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
