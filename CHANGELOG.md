# Changelog

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
