<p align="center"><img src="Resources/AppIcon.png" width="112" alt="Reprise icon"></p>

# Reprise

**Your screen history and meeting memories, searchable on your Mac.**

[한국어](README.ko.md) · [Download Alpha](https://github.com/hyungchulc/reprise/releases) · [MCP](docs/MCP.md) · [Privacy](docs/PRIVACY.md)

Reprise is a native macOS memory app with a full-screen timeline, local screen OCR,
meeting audio and transcripts, and AI answers linked to the original memories.
It is an independent implementation inspired by Rewind's workflow, not an official
Rewind product, fork, or compatible database reader.

> **Alpha software.** Back up important recordings. The first binary release is
> Apple Silicon only, development-signed, and **not Apple-notarized**. It is not a
> production-ready archival or compliance tool. macOS may block the initial launch.

## Install

1. Download the DMG or app ZIP from [Releases](https://github.com/hyungchulc/reprise/releases).
2. Move `Reprise.app` to `Applications` or `~/Applications`, then open that copy.
3. Complete onboarding. Grant screen recording permission only when you want screen
   capture; microphone and speech permissions are separate.
4. Choose a global shortcut and, optionally, connect an installed AI provider CLI.

Requires macOS 14 or later. Native Liquid Glass is used on macOS 26 or later;
older systems use material-based controls. macOS 14/15 compatibility is a source
target, not a completed device test matrix. The app UI is currently English.

For a Gatekeeper warning, review the release and verify its checksum before using
the normal **System Settings > Privacy & Security > Open Anyway** flow. Do not
disable Gatekeeper globally. A signing-identity change may require a fresh capture
permission and restart. Reprise never edits the system permission database.

### If macOS Cannot Verify The App

This alpha's Apple Development signature is **not Developer ID distribution
approval**. macOS may block the initial launch even when the archive checksum and
code signature are valid. The DMG contains the app and an Applications shortcut,
not a separate installer; the ZIP contains the same app.

**A failed copy or installation is a separate issue.** If the app cannot be moved
to your chosen Applications folder, report the exact alert and step. Open Anyway
is not a fix for a failed copy. Manual alpha.2 installation has since succeeded on
the maintainer's Mac, but the cause of an earlier interruption is still unconfirmed.
This does not establish compatibility on other Macs.

After copying succeeds and you attempt to open that copy, use **Open Anyway**
only if you trust this source and macOS offers it. This is a user-granted exception,
not a verified or notarized installation. If no exception is offered or the system
reports malware, stop and report the exact alert. Do not disable system protection
or remove quarantine attributes. See [Apple's guidance](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

Building the reviewed source locally is another development option. Free Apple
Accounts do not provide Developer ID distribution signing or notarization, which
require Apple Developer Program membership. This release does not claim a clean
downloaded-installation test on every supported macOS version.

## What It Does

| Area | Alpha functionality |
| --- | --- |
| Screen memory | Periodic ScreenCaptureKit still frames of the display you are using, on-device Vision OCR, browser page addresses, local full-text index |
| Timeline | Full-screen overlay, app icons and icon-derived colors, calendar, compressed recording gaps, 30-second navigation |
| Search | Local keyword search that also matches Korean words with particles, AI query planning, source-linked answers, follow-up questions, saved conversations |
| Meetings | Explicit microphone recording, optional system audio, post-recording transcription with Apple's models or Whisper on your Mac, OpenAI's newest models with a ChatGPT plan or API key, or Gemini with a Google AI plan or API key, speaker labels you can rename, automatic summaries with decisions and action items, inline playback and timestamp seeking |
| Live captions | Captions over every app and full-screen video for what the Mac plays or the microphone, translated as they are spoken, by OpenAI with a ChatGPT plan or API key or on this Mac with Apple's speech and translation models on macOS 26; text size, color, background, lines and position |
| Meeting assistant | A floating window that hears you and the others, answers the others' questions within about a second from the conversation and your memories with source links, and takes typed questions; searches the web through Codex, Claude Code or an API key, and calls tools from MCP servers you add; OpenAI's Realtime model with a ChatGPT plan or API key, or any AI & Models provider; listening on this Mac on macOS 26 |
| AI providers | Claude, Codex, Gemini, Grok, Cursor and OpenCode (free models) through their CLIs; your own OpenAI, Anthropic or Gemini API key; Apple's on-device model and Ollama on your Mac; install and sign-in from Settings, model, thinking-level and Fast mode controls in search, a context window choice for Claude and Grok, and reported token and context use |
| MCP | Opt-in read-only memory search for Claude Desktop, Claude Code, Codex, Cursor and compatible local clients |
| Appearance | System/custom accent, system/manual light and dark modes, text size, transitions and optional edge glow |
| Controls | Editable global shortcuts for the memory overlay, search alone, live captions, meeting recording, the meeting assistant and answering the last question, Dock/menu bar placement, launch options, pause reminders, exclusions and retention |
| Updates | Sparkle checks a signed feed and downloads signed archives from GitHub Releases |

The default shortcut is **Command + Shift + Space**. It opens focused search in
the memory overlay. Escape first closes search, and the next search starts fresh (a
search still answering is kept), then closes the overlay. Time words such as today,
yesterday evening, last week or 10월 13일 show that time, spread across it; other
words search the text inside it.
Recent conversations restore saved answers and citations without another AI call.
Moving through the timeline steps through screens. Recordings sit on a waveform lane
under it and open in a panel above the bottom bar only when chosen: from the lane, at
the moment clicked, from search results or from a citation. The panel stays open while
the timeline is within the recording and stays in view while searching. An optional
**Search Only** shortcut, set in Settings > General, opens just the search box with no
memory view behind it.

Screen and audio recording are separate actions. Optional meeting detection offers
a prompt; it never starts recording automatically. Screen auto-start requires an
explicit setting. No sample library is created.

## AI Search

In **Settings > AI & Models**, select the provider and model. **Install** runs the
provider's official installer in Terminal, so every step stays visible, and **Sign In**
opens its own subscription sign-in. Reprise does not bundle the CLIs or create API
keys; authentication, availability and limits remain provider-controlled.

| Provider | What it needs |
| --- | --- |
| Claude, Codex, Grok, Cursor | The provider's CLI and a subscription sign-in |
| Gemini | Google's Antigravity CLI (`agy`), which replaced the personal Gemini CLI, and a Google sign-in |
| OpenCode | The OpenCode CLI only. Free models, no account. Zero-retention models are listed first; others may use prompts to improve their models |
| Apple Intelligence | macOS 26 with Apple Intelligence on. Runs on this Mac; nothing leaves it |
| Ollama | The Ollama app and a downloaded model. **Download** in Settings fetches a suggested or named model |
| OpenAI API, Anthropic API, Gemini API | An API key from the vendor's console, pasted in Settings. No CLI; billed by the token to the key's account |

Google has suspended accounts that used Gemini sign-ins through third-party tools.
Reprise runs Google's own CLI in its documented mode and never reads the sign-in, but
the risk is Google's call; choose Gemini only if you accept it. A Gemini API key does not
carry this risk.

Search plans keywords over the local full-text index, then supplies bounded OCR and
transcript evidence to the chosen provider. The language model never reads the whole
library: it writes the search terms and the answer, and local search finds the
memories in between. Focused answers use up to 24 memories (8 on Apple's on-device
model, 16 on Ollama); activity summaries sample up to 96 representatives across the
full filtered interval. Answers link back to stored memories and show coverage.
**Sampling and excerpt limits can omit details; an answer is not an exhaustive
account of a day.**

Provider subprocesses use explicit tool restrictions, isolated temporary settings,
timeouts and bounded output. Unsupported CLI contracts fail closed. These controls
reduce agent side effects; they are not a guarantee that a third-party executable
is trustworthy. Remaining subscription quota is shown as unknown when unavailable. Private Cloud
Compute is not available to third-party apps. Without a subscription, choose
OpenAI API, Anthropic API or Gemini API and paste a key: search, summaries and the meeting
assistant then run on that API account, billed by the token. An OpenAI key also serves
transcription, live captions and the assistant's listening, and a Gemini key transcription. See [provider contracts](docs/PROVIDERS.md).

## MCP Connections

Open **Settings > MCP & Integrations**, enable memory access, and install a client
configuration. Restart the client after installation. Screenshot sharing is a
separate opt-in and is off by default. **Copy Configuration** supports other clients
with local stdio MCP support.

The bundled `RepriseMCP` helper searches the same vault without opening the UI or
running an additional model. It cannot record, delete or change memories. Connected
clients may send retrieved content to their own providers. Web-only clients that
require a remote HTTP server cannot connect directly. [Setup and tools](docs/MCP.md).

## Local Data And Resource Use

The default vault is `~/Library/Application Support/Reprise`. It is independent of
the app version and contains the database, images, audio, transcripts, search history
and usage. Since 0.6 the vault is **encrypted**: the database with SQLCipher and every
screenshot, movie and recording with AES-256-GCM. The key lives in your login keychain,
where only Reprise and its MCP helper can read it without asking. If any other app asks
macOS for “Reprise Vault Key”, deny it unless you started that request. Save the
**recovery key** from **Settings > Privacy > Encryption** in a password manager: if the
keychain loses the key, for example on a new Mac, Reprise asks for it when it opens.
Without either, the vault cannot be opened. [What encryption covers](docs/PRIVACY.md#encryption).
Reprise does not bundle any recorded memories or credentials in its releases.

Capture defaults to native Retina resolution, 85% image quality and a 3-second
interval. With several displays, Reprise records the one with the window you are
using, or the one you are scrolling or clicking in, each at its own resolution.
In Safari and Chromium browsers it also saves the page address, without fragments
or sign-in tokens and never from private windows; macOS asks once per browser, and
**Settings > Privacy** turns it off. Settings expose smaller resolutions, intervals, retention and storage
limits. Unchanged-screen deduplication that ignores the menu bar's clock and live status
items, HEIC with JPEG fallback, separate 400px HEIC thumbnails, HEVC compression of
screens older than 15 minutes (roughly 4–7 times smaller in our samples), re-encoding at
half resolution after 7 days (adjustable or off in Settings), bounded capture/OCR work,
and 96 MB preview / 8 MB thumbnail caches
limit background work. These are implementation choices, not measured guarantees
against another app. CPU and process memory are visible; GPU usage is not measured.

Automatic transcription saves the recording first, then transcribes it with the engine
chosen in **Settings > Audio & Meetings**. Apple's speech models work on this Mac in each
chosen language and keep, for every passage, the language that fits it best. Whisper runs
on this Mac through WhisperKit after a one-time model download. OpenAI's transcription
models run online through the ChatGPT plan the Codex CLI is signed in with, or an OpenAI
API key; without either, Reprise transcribes with Apple on this Mac instead. Gemini listens
to the recording through the Google AI plan the Antigravity CLI is signed in with, or a
Gemini API key, and tells the voices apart in recordings up to 20 minutes. Other speaker
labels are found on this Mac. Speakers can be renamed in the transcript.
When a transcript is ready, the chosen AI provider summarizes it into an overview,
key points, decisions and action items, and a notification opens the recording. The
summary is stored encrypted with the recording; the notification shows only the
meeting's title. Turn it off in **Settings > Audio & Meetings**, or summarize any recording
from its Summary tab.
On macOS 26 and later, speech models download when a language is chosen. Failures remain visible
and the original audio is preserved. A recording can last at most four hours.
Title-based privacy and meeting detection are best-effort, not complete protection.
Review [data flow and limitations](docs/PRIVACY.md) before recording sensitive work.

Live captions listen to what the Mac plays, or to the microphone, and show captions over
every app, also full-screen video. Turn them on from the Reprise menu in the menu bar or
with a shortcut set in **Settings > General > Shortcuts**, and choose **Move Captions** to
drag them into place. In **Settings > Live Captions**, choose the caption language and who
makes the captions. OpenAI's live translation recognizes the spoken language by itself,
writes 57 languages and runs with the ChatGPT plan of the Codex CLI or an OpenAI API key.
On macOS 26, this Mac captions with Apple's speech recognition and translation once the
spoken language is chosen, without sending audio anywhere; Settings shows which languages
this Mac can recognize and translate. Automatic uses OpenAI when its account works and this
Mac otherwise. Captions are shown, not saved.

The meeting assistant opens a small window beside the meeting from the Reprise menu, a
shortcut, or with every meeting recording when **Settings > Meeting Assistant** says so. It
hears you through the microphone and the others through Mac audio and writes down what each
side says. When the others ask a question, it answers about a second later from the
conversation and your memories, with buttons that open each memory it used; type a question
of your own, or press the Answer Last Question shortcut. OpenAI's Realtime model answers
fastest, with the ChatGPT plan of the Codex CLI or an OpenAI API key; without OpenAI, the
provider chosen in AI & Models answers, and Apple's on-device model or Ollama keep everything
on this Mac. What the assistant hears is not saved; record the meeting to keep a transcript.
Live captions and the assistant stop when the Mac sleeps.

The assistant also searches the web when a question needs it, through Codex or Claude Code
signed in on this Mac or an OpenAI, Gemini or Anthropic API key, and shows the pages it
used. **Settings > Meeting Assistant > MCP Tools** adds your own MCP servers by command or
address; tools that only read start on, tools that change things start off, and the
assistant calls the tools that are on while OpenAI answers.

## Updates

Use **Settings > General > Check for Updates** or the menu bar command. Automatic
checks are optional and off by default. Sparkle verifies both the update feed and
the archive with the pinned Ed25519 public key before extraction. Releases are
hosted on GitHub; installation waits for recording shutdown before relaunch.

Older local-only builds need one manual installation of this alpha. After that,
updates use GitHub. Updating does not replace the vault. Signing and macOS
permission behavior can still require user attention during alpha development.

## Build From Source

Use Xcode 26 or newer with the macOS 26 SDK and Swift Package Manager. The source
targets macOS 14+. Dependencies are pinned in `Package.resolved`.
Use `main` for the Swift toolchain compatibility fix made after the first alpha tag.

```sh
git clone https://github.com/hyungchulc/reprise.git
cd reprise
swift build
swift test --filter 'MCPTests|MomentStoreTests|MemorySearchTests'
./script/build_and_run.sh --build
```

The packaged result is `dist/Reprise.app`; building does not replace or restart an
installed copy. The script uses an available Apple Development identity, or an
explicit `REPRISE_SIGNING_IDENTITY`. For a disposable unsigned-development build:

```sh
REPRISE_SIGNING_IDENTITY=- REPRISE_ALLOW_ADHOC=1 ./script/build_and_run.sh --build
```

Ad-hoc builds can lose capture permission across rebuilds. Forks must replace the
update feed and public key before distribution. [Release procedure](docs/RELEASING.md).

## Development And Reporting

The app uses SwiftUI/AppKit, ScreenCaptureKit, Vision, Speech, AVFoundation, SQLCipher
FTS5, the official MCP Swift SDK, and Sparkle. There is no bundled LLM, vector
database or always-running inference service; Apple's on-device model and Ollama run
only when chosen. [Architecture](docs/ARCHITECTURE.md).

Report reproducible problems through [Issues](https://github.com/hyungchulc/reprise/issues).
Include macOS/app versions and steps, but **never upload your vault, raw recordings,
tokens, personal screenshots or unredacted transcripts**. See [security reporting](SECURITY.md).
Third-party licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Reprise's original code and assets are available under the [MIT License](LICENSE).
Third-party components retain their own licenses. No Rewind binaries, extracted
assets or recorded user data are included.
