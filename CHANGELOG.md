# Changelog

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
