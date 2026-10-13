# Privacy And Data Flow

## On This Mac

The vault stores screenshots, OCR text, window titles/app names, timestamps, audio,
transcripts, search conversations and reported usage in
`~/Library/Application Support/Reprise`, unless a custom `REPRISE_DATA_DIR` is used.
Updating the app does not change that path. The folder is private to your macOS
account, but the app does **not** encrypt the vault itself. Other same-user processes
and backup tools may be able to read it. Screens older than 15 minutes are kept as
frames of HEVC movies; deleting such a screen re-encodes its movie without it.

Screen capture requires macOS permission and a start action, unless the user has
enabled start-on-launch. Audio recording is separate and explicit. On-device
transcription runs in each chosen language with Apple's speech models on this Mac;
on macOS 26 and later those models download when a language is chosen. Meeting detection
only offers a prompt. Reprise excludes itself from screen capture and supports
app/title exclusions, idle/battery pauses and retention limits.

Private-window detection is based on exposed titles and is not guaranteed to catch
every sensitive screen. A captured image can contain messages, credentials, health
information or financial information. Review exclusions before recording. Retention
and deletion cannot remove copies held by backups or external services.

## Data That Can Leave The Mac

| Action | Data sent |
| --- | --- |
| Local capture, OCR, text search and playback | No Reprise network transmission |
| In-app AI search/follow-up | Question, bounded conversation context, selected OCR/transcripts and provenance to the chosen CLI/provider |
| MCP text tools | Requested OCR/transcripts/metadata to the connected client, which may transmit them onward |
| MCP screenshots | Bounded screenshot previews only when screenshot sharing is explicitly enabled |
| Update check/download | Requests to GitHub/Sparkle feed URLs, exposing normal network metadata and app/updater request metadata |

In-app AI search does not send image/audio bytes. MCP does not return raw audio and
does not invoke another model itself. Reprise does not implement its own analytics
or account service. Third-party clients and provider CLIs have their own policies;
Reprise cannot guarantee or control their retention, telemetry or account behavior.
Sparkle system-profile submission and automatic installation are disabled by default.

## Credentials And Consent

Provider authentication remains owned by the installed CLI. Reprise can open a
subscription sign-in in Terminal at the user's request; it does not create API
keys, copy credentials or display raw auth output. Compatibility checks do not
perform inference. Token usage is displayed only when reported; quota is not guessed.

MCP access is off by default. `mcp-access.json` stores only two consent flags, not
credentials. Each helper request checks those flags. Turning access off cannot
recall content already shared. Removing a client entry does not necessarily stop
an already-running helper, so disable access to revoke it immediately for new
responses. The gate is not a system-level sandbox or a defense against a malicious
same-user process that directly opens the vault.

## Reporting Problems

Do not attach databases, recordings, transcripts, unredacted screenshots, CLI logs
or credentials to public issues. Use synthetic examples and redact local paths.
Release archives contain code and assets only; no recorded library is distributed.
