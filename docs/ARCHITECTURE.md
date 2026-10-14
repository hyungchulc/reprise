# Architecture

Reprise is a Swift Package Manager macOS application. It has no backend service.

| Module | Responsibility |
| --- | --- |
| `Reprise` | SwiftUI/AppKit UI, overlay, capture, audio, permissions, settings and Sparkle updates |
| `RepriseCore` | Encrypted persistence (SQLCipher, sealed media), search/retrieval, model adapters, history and client configuration |
| `RepriseMCPKit` | Read-only memory tools and MCP Swift SDK server |
| `RepriseMCP` | Small stdio entrypoint, packaged beside the app executable |

## Capture And Storage

ScreenCaptureKit supplies one bounded still capture at a time, of the display in use:
the front window comes from the on-screen window list, its display is the one it
overlaps most, and a newer scroll or click on another display moves capture to the
window under the pointer there. Each display keeps its native pixel size, and OCR
reads 1x displays at up to 3840 pixels. `BrowserURLReader` asks Safari and Chromium
browsers for the front tab's address over Apple Events with a one-second limit;
`BrowserAddress` keeps http and https addresses without fragments, credentials or
secret-like query values, and the address is indexed with the title and text. Vision performs
on-device OCR with automatic language detection, Korean, Japanese and Chinese hints first;
image encoding/deduplication runs off the main actor. Screens read before 0.8.1 put
English first and lost Korean text; they have no `text_revision` and are read again in
the background, newest first, one at a time, waiting while on battery. Full-size
images and thumbnails are separate. After 15 minutes, `FrameArchiver` moves full-size
stills of one pixel size into HEVC movies (frame i at i seconds, keyframes every 30
frames) and points each row at its movie and frame time in one transaction; a movie is
verified before any still is deleted. Deleting a compressed screen queues its movie for
re-encoding without that frame. Movies whose screens are all older than the compaction age
(7 days by default) are re-encoded once at half resolution, never below 1280 pixels on the
longer side; `archive_compact` records reduced movies, and a purge rewrite keeps the mark.
Deduplication hashes the pixels below the menu bar, and OCR skips the same band, unless a
full-screen window covers it. JPEG thumbnails from early versions are re-encoded as HEIC
in the background. The SQLite actor owns prepared statements, WAL access,
FTS5 and bounded caches. Media paths are vault-relative and validated before file
operations. Database migrations are additive, and settings decode key by key.

## Encryption

`VaultKeys` derives the database, media and consent keys from one master key that
`VaultKeychain` keeps in the login keychain, with Reprise and `RepriseMCP` as trusted
applications. The database is SQLCipher (swift-sqlcipher, FTS5, in-memory temp store,
secure delete) opened with a raw key. `VaultCipher` seals files as a 32-byte header plus
independent 1 MiB AES-GCM chunks whose nonce carries the chunk index and a last-chunk flag;
each file derives its own key from a random salt. Captures, thumbnails and imports are
encoded in memory and written sealed. Archive movies are fragmented MPEG-4 produced in
memory by `AVAssetWriter` and sealed per fragment. `VaultAsset` serves sealed movies and
recordings to AVFoundation through a resource loader that decrypts only the requested
ranges, so playback, frame decoding, re-encoding and transcription never write plaintext.
A library from before encryption is converted at launch with `sqlcipher_export`, verified,
then swapped in; `VaultMigration` seals its older media in bounded background batches.

Audio combines explicit microphone input and optional system audio. Stopping saves
the complete recording before on-device transcription. On macOS 26 and later one
SpeechAnalyzer pass runs a SpeechTranscriber per chosen language; `TranscriptMerge`
splits each result into timed phrases and keeps the most confident non-overlapping
ones across languages. Earlier systems transcribe bounded chunks per language.
Audio duration, transcript segments and failure notes persist with each memory.
When a transcript is ready, `MeetingSummarizer` sends it to the chosen provider in parts
that fit the provider's budget and merges the part summaries; the result and a hash of
its transcript are stored in `meeting_summaries`, so a new transcript marks it stale.

A missing keychain key is recovered with `RecoveryKey`: the master key plus a two-byte
SHA-256 checksum in Crockford base32. Reprise confirms that the key opens the database
before `VaultKeychain.restore` saves it with the same access list; an existing item is
never replaced.

## Retrieval And UI

The full-screen AppKit panel hosts SwiftUI. Timeline models compress recording gaps
and group app runs. Image decoding is cancellable and cached; stale decodes cannot
replace a newer request. Audio uses dedicated playback controls rather than video
views. Search conversations persist answers and evidence IDs per vault.

Local keyword retrieval does not call a provider. Words of two or more non-Latin
characters and four or more Latin letters match as prefixes, so Korean words with
particles are found. AI search plans bounded query alternatives, gathers filtered
evidence and validates returned citations. Broad summaries sample activity groups
across the complete interval. Each provider has an evidence budget (moments, bytes and
prior turns) sized to its context, halved and retried while the model reports that the
context is too large. CLI subprocesses have time/output limits, Seatbelt profiles and
provider-specific no-tools settings; Apple's on-device model runs in process through
FoundationModels guided generation, and Ollama through its loopback HTTP API with a
JSON schema format.

## Integrations And Delivery

MCP uses the same database schema in read-only mode. The helper can run without the
UI; consent is per vault and checked on each call. MCP does not call Reprise's AI
adapters. Client installers preserve unrelated configuration entries.

Sparkle loads a signed HTTPS appcast and signed release archives from GitHub.
Private signing keys are never bundled. The build script assembles the framework,
helper, icon and licenses into a signed application; release packaging creates a
DMG and app ZIP without any vault contents. The default bundle ID remains
`local.aria.reprise` for existing local installations.
