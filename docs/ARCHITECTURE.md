# Architecture

Reprise is a Swift Package Manager macOS application. It has no backend service.

| Module | Responsibility |
| --- | --- |
| `Reprise` | SwiftUI/AppKit UI, overlay, capture, audio, permissions, settings and Sparkle updates |
| `RepriseCore` | SQLite persistence, search/retrieval, model adapters, history and client configuration |
| `RepriseMCPKit` | Read-only memory tools and MCP Swift SDK server |
| `RepriseMCP` | Small stdio entrypoint, packaged beside the app executable |
| `CSQLite` | System SQLite module map |

## Capture And Storage

ScreenCaptureKit supplies one bounded still capture at a time. Vision performs
on-device OCR; image encoding/deduplication runs off the main actor. Full-size
images and thumbnails are separate. The SQLite actor owns prepared statements,
WAL access, FTS5 and bounded caches. Media paths are vault-relative and validated
before file operations. Database migrations are additive.

Audio combines explicit microphone input and optional system audio. Stopping saves
the complete recording before background, bounded on-device Speech transcription.
Audio duration, transcript segments and failure notes persist with each memory.

## Retrieval And UI

The full-screen AppKit panel hosts SwiftUI. Timeline models compress recording gaps
and group app runs. Image decoding is cancellable and cached; stale decodes cannot
replace a newer request. Audio uses dedicated playback controls rather than video
views. Search conversations persist answers and evidence IDs per vault.

Local keyword retrieval does not call a provider. AI search plans bounded query
alternatives, gathers filtered evidence and validates returned citations. Broad
summaries sample activity groups across the complete interval. Provider subprocesses
have time/output limits and provider-specific no-tools profiles.

## Integrations And Delivery

MCP uses the same database schema in read-only mode. The helper can run without the
UI; consent is per vault and checked on each call. MCP does not call Reprise's AI
adapters. Client installers preserve unrelated configuration entries.

Sparkle loads a signed HTTPS appcast and signed release archives from GitHub.
Private signing keys are never bundled. The build script assembles the framework,
helper, icon and licenses into a signed application; release packaging creates a
DMG and app ZIP without any vault contents. The default bundle ID remains
`local.aria.reprise` for existing local installations.
