# Privacy And Data Flow

## On This Mac

The vault stores screenshots, OCR text, window titles/app names, timestamps, audio,
transcripts, search conversations and reported usage in
`~/Library/Application Support/Reprise`, unless a custom `REPRISE_DATA_DIR` is used.
Updating the app does not change that path. The folder is private to your macOS
account, and since 0.6 its contents are encrypted (below). Screens older than 15
minutes are kept as frames of HEVC movies, re-encoded at half resolution after 7 days
by default; deleting such a screen re-encodes its movie without it. The menu bar is left
out of screen text and of the check for an unchanged screen, but stays in the image.

With several displays, only the display you are using is captured: the one with the
front window, or the one where you last scrolled or clicked if that is more recent than
your typing there.

Browser page addresses are saved for Safari and Chromium browsers (Chrome, Edge, Brave,
Arc, Vivaldi, Opera) while the browser is in front. Reprise asks the browser over Apple
Events, so macOS asks once per browser; a refusal is respected. Only http and https
addresses are kept, without the part after `#`, user names, passwords or query values
whose names look like secrets (`token`, `code`, `session`, `key` and similar). Private
and incognito windows are skipped. Turn it off in **Settings > Privacy > Browser
Addresses**; addresses already saved stay with their screens until those are deleted.

## Encryption

| Data | Protection |
| --- | --- |
| Database: OCR text, titles, transcripts, usage | SQLCipher 4 (AES-256, per-page HMAC), raw 256-bit key |
| Screenshots, thumbnails, imports | AES-256-GCM, written sealed; pixels never reach the disk unencrypted |
| Compressed screen movies | Encoded in memory and sealed fragment by fragment |
| Meeting recordings | Sealed when the recording stops, before indexing and transcription |
| Search history, MCP consent | Search history sealed; consent signed with HMAC-SHA-256 |
| Meeting summaries, page addresses | Stored in the encrypted database |

One random master key per library lives in the login keychain as “Reprise Vault Key”.
The database, media and consent keys are derived from it with HKDF. Its access list
names Reprise and its bundled MCP helper by code signature, so updates keep access;
any other program triggers a macOS approval prompt. Sealed files use independent
1 MiB AES-GCM chunks bound to their position and to the file's last chunk, so players
can read any byte range while altered, reordered or truncated files fail to open.

The first launch of 0.6 converts an existing library: it copies the database into an
encrypted file, checks row counts and the full-text index, then swaps it in, and seals
older media in the background. Nothing is deleted before its encrypted copy is verified.

What encryption does and does not do:

- It stops programs that read files directly, such as an AI agent with shell access,
  backup and sync tools, or anything that copies the folder, from seeing your memories.
- It cannot stop a program that you allow at the keychain prompt, or one that controls
  Reprise itself. Reprise decrypts in memory to show your memories.
- A meeting is written unencrypted while it records and is sealed when it stops. On
  macOS 25 and earlier, transcribing a saved meeting briefly decrypts it into a private
  work folder that is removed afterwards. Otherwise nothing decrypted reaches the disk.
- FileVault still protects the whole disk when the Mac is off or locked.
- If the login keychain is reset or lost, the vault opens only with the recovery key.
  **Settings > Privacy > Encryption > Recovery Key** shows it after your Mac password
  or Touch ID. It starts with `R1` and has 11 groups, and a checksum catches typing
  mistakes. Copies to the clipboard are marked concealed and cleared after 90 seconds.
  When Reprise cannot find its key, it asks for the recovery key, checks that it opens
  this library, and saves it back to the keychain. Anyone with the recovery key and a
  copy of the library can read it, so keep it in a password manager.
- `sqlite3` and image viewers can no longer open vault files. Use Reprise or its MCP tools.

Screen capture requires macOS permission and a start action, unless the user has
enabled start-on-launch. Audio recording is separate and explicit. Transcription uses
the engine chosen in Audio settings. Apple's speech models run on this Mac in each chosen
language; on macOS 26 and later those models download when a language is chosen. Whisper
runs on this Mac after its model downloads once from Hugging Face. Speaker labels are found
on this Mac by a speaker model downloaded the same way. These models are kept in
`~/Library/Application Support/Reprise/Models`, and recordings are decoded for them from the
sealed file without a plaintext copy. OpenAI transcription sends the recording's audio to
OpenAI (see below). Live captions hear what the Mac plays, without Reprise's own sounds,
or the microphone, only while they are on; they are shown and never saved, and Reprise's
own windows, captions included, are left out of screen capture. The meeting assistant
hears the microphone and what the Mac plays only while its window is open; what it hears is
shown and never saved. Live captions and the assistant stop when the Mac sleeps or the user
session switches, and never resume by themselves. Meeting detection
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
| In-app AI search/follow-up | Question, bounded conversation context, selected OCR/transcripts and provenance (including page host and path) to the chosen CLI/provider |
| Meeting summary | The transcript and meeting title to the chosen provider, in parts that fit its limit |
| OpenAI transcription, when chosen | The recording's audio, in ten-minute pieces, to OpenAI's Realtime API, with a short-lived session secret made from the ChatGPT sign-in of the Codex CLI or from an OpenAI API key |
| Whisper and speaker models, when chosen | Download requests to Hugging Face; recordings stay on the Mac |
| Live captions by OpenAI, when chosen | What the Mac plays, or the microphone, while captions are on, streamed to OpenAI's Realtime API with a short-lived session secret made the same way |
| Live captions on this Mac | Nothing leaves the Mac; speech and translation models download once from Apple |
| Meeting assistant listening by OpenAI, when chosen | The microphone and what the Mac plays, while the assistant is open, streamed to OpenAI's Realtime API with a short-lived session secret made the same way |
| Meeting assistant answers by OpenAI, when chosen | Each question, the last four minutes of the assistant's transcript and the memory excerpts its searches return, to OpenAI's Realtime API |
| Meeting assistant answers by a provider | Each question, the last four minutes of the transcript and up to six matching memories, to the provider chosen in AI & Models |
| Search, summaries and assistant answers by API key, when chosen | The same data a CLI provider gets, sent with the key to api.openai.com, api.anthropic.com or generativelanguage.googleapis.com |
| Apple Intelligence, Ollama | Nothing leaves the Mac; Ollama is reached only on 127.0.0.1 |
| MCP text tools | Requested OCR/transcripts/metadata to the connected client, which may transmit them onward |
| MCP screenshots | Bounded screenshot previews only when screenshot sharing is explicitly enabled |
| Update check/download | Requests to GitHub/Sparkle feed URLs, exposing normal network metadata and app/updater request metadata |

OpenCode's free models are run by third parties under OpenCode Zen. Reprise lists only
free models and puts those whose providers keep no data first; the others may use what
you send to improve their models, and NVIDIA's ask that no personal data be sent. A
summary notification shows only the meeting's title, because Notification Center keeps
its own unencrypted history.

For OpenAI transcription with a ChatGPT plan, Reprise asks the Codex CLI's own app server
for its access token each time, keeps it in memory and sends it only to api.openai.com to
start a session; it is never written or logged, and Reprise never reads Codex's files. An
OpenAI, Anthropic or Gemini API key, when saved, stays in the login keychain as “Reprise API
Key (OpenAI)”, “Reprise API Key (Anthropic)” or “Reprise API Key (Google Gemini)” and is sent
only to its vendor, in a request header, never in an address. OpenAI requests ask OpenAI not to
store the response for later retrieval. Google may use what is sent with a Gemini key on its
free tier to improve its products. Audio leaves the Mac only with OpenAI transcription, OpenAI
live captions and the meeting assistant listening with OpenAI.

In-app AI search does not send image/audio bytes. MCP does not return raw audio and
does not invoke another model itself. Reprise does not implement its own analytics
or account service. Third-party clients and provider CLIs have their own policies;
Reprise cannot guarantee or control their retention, telemetry or account behavior.
Sparkle system-profile submission and automatic installation are disabled by default.

## Credentials And Consent

Provider authentication remains owned by the installed CLI. Reprise can open a
subscription sign-in, or the provider's official installer, in Terminal at the user's
request; it does not create API keys, copy credentials or display raw auth output.
For Gemini, the existing Antigravity sign-in file is linked into a temporary folder for
each request and is never read by Reprise. Compatibility checks do not
perform inference. Token usage is displayed only when reported; quota is not guessed.

MCP access is off by default. `mcp-access.json` stores two consent flags and an
HMAC signature made with a key from the login keychain, not credentials. Each helper
request checks the flags and the signature, so another program cannot turn access on
by editing the file. Unsigned or altered settings read as access off. Turning access
off cannot recall content already shared. Removing a client entry does not necessarily
stop an already-running helper, so disable access to revoke it immediately for new
responses. The gate is not a system-level sandbox: a program you approve at the
keychain prompt can read the key.

## Reporting Problems

Do not attach databases, recordings, transcripts, unredacted screenshots, CLI logs
or credentials to public issues. Use synthetic examples and redact local paths.
Release archives contain code and assets only; no recorded library is distributed.
