# Changelog

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
