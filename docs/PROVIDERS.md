# AI providers

Reprise uses existing local CLI sign-ins. It does not read, copy, create, or display
credentials. Explicit Sign In opens the provider's subscription login in Terminal, and
Install runs the provider's official installer there. It does not call a billing API or
create an API key. Core readiness is a bounded help check; the UI separately checks
model-free subscription status. Account quota remains unknown. Opt-in synthetic search
checks passed with Codex, Claude and Grok on 2026-10-13, and with Gemini (Antigravity),
Cursor, OpenCode and Apple's on-device model on 2026-10-14. No personal memories were
sent during verification.

## Public API

```swift
let client = AIClient()
let config = AIProviderConfiguration(
    provider: .claude,
    model: "",                 // CLI's current automatic/default alias
    executablePath: nil,       // optional user-editable absolute path
    timeoutSeconds: 90
)
let status = await client.status(configuration: config)
let response = try await client.answer(
    question: question,
    moments: selectedMoments,
    configuration: config
)
// response.text, response.citations, response.usage
// Persist response.usage using MomentStore.recordUsage.

let search = MemorySearch(store: store, client: client)
let result = try await search.search(
    question: question, configuration: config,
    filter: MomentQuery(appName: selectedApp, since: selectedDayStart, until: selectedDayEnd),
    timeZone: .autoupdatingCurrent
)
// result.response, result.moments (citation order), result.usage (planning + answer)
// Main owns persistence, including both usage entries.
// On failure after planning, MemorySearchFailure.usage preserves the completed planning entry.
```

`AIProviderKind` contains `claude`, `codex`, `gemini`, `grok`, `cursor`, `opencode`,
`ollama` and `apple`. Configuration is Codable and all public value types are Sendable. A blank model follows the
provider's own current selection; explicit model aliases remain editable.
The adapter searches standard Homebrew locations, the provider's home bin
directory, and `~/.local/bin`. A configured executable must be an absolute
executable path. Arguments are passed to Foundation Process as an array.

## Contracts inspected on 2026-10-13

| Provider | Inspected local CLI | MVP readiness |
| --- | --- | --- |
| Claude | `claude --help` | Answering implemented with explicit no-tools controls |
| Codex | `codex exec --help`, `features list`, native `debug models` with temporary profile | Answering implemented; native CLI accepts disabled tool catalog and feature overrides |
| Grok | `grok --help`, installed user guide, isolated `grok inspect --json` | Answering implemented; native inspection verifies empty custom discovery surfaces |
| Gemini | `agy --help`, `agy models`, stream-json events (2026-10-14) | Answering implemented; tools denied by strict permissions, answer through `finish` |
| Cursor | `cursor-agent --help`, `--list-models`, `status`, stream-json events | Answering implemented; ask mode, deny-all workspace permissions, Seatbelt |
| OpenCode | `opencode run --help`, `opencode models opencode`, JSON events | Answering implemented with free Zen models; every tool asks and run mode rejects it |
| Ollama | `/api/version`, `/api/tags`, `/api/show`, `/api/chat` on 127.0.0.1:11434 | Answering implemented; tool calls rejected |
| Apple | FoundationModels `SystemLanguageModel` on macOS 26 | Answering implemented in process; no tools are registered |

Thinking levels: Claude, Codex and Grok take the level as a flag, high unless another
is chosen; Codex offers the levels its model catalog lists for the model. Gemini and
Cursor name the level in the model identifier, so the search bar and Settings group
their models into families and choose the level within one. OpenCode, Ollama and Apple
have no level to choose.

Fast mode appears only for a model that has it, and turning it on asks first. Claude
receives `"fastMode":true` in its `--settings` JSON, only for Opus 5.5, Opus 5 and Opus
4.8, since the CLI otherwise switches to a model that has it; Anthropic bills Fast mode
to usage credits even while the plan has usage left. Codex receives
`service_tier="priority"` when its model catalog lists that tier for the model; the CLI
refuses a tier the catalog does not advertise. Grok and Cursor list Fast models of their
own (`grok-4.7` and `grok-4.7-build-fast`, `composer-2.5` and `composer-2.5-fast`), so
the switch chooses the listed twin by name and the model menus show each model once.

Claude runs with `--print --output-format json --safe-mode --restricted --tools ""`,
an explicit answer/citations JSON schema, the chosen `--effort` level,
an empty strict MCP configuration, disabled slash commands, no Chrome integration,
no session persistence, `dontAsk` permission mode, and `disableAllHooks`.
Its replacement system prompt restricts the response to explicitly supplied
evidence. Safe mode preserves native subscription auth. `--bare` is deliberately
avoided because the installed help says it disables OAuth/keychain subscription
auth and requires API authentication. The subprocess receives only an allowlist
of benign runtime environment variables, so API keys and billing overrides from
the app environment are not inherited.

Codex runs `exec --json --ephemeral --ignore-user-config --ignore-rules` with a
read-only sandbox, never-approve policy, the chosen reasoning level, OpenAI subscription
provider, disabled web search and disabled capability features (shell, apps,
plugins, hooks, browser, computer, images, memory, subagents and code mode).
It also uses the documented `model_catalog_json` setting from the
[configuration schema](https://developers.openai.com/codex/config-schema.json).
The catalog is the one Codex itself works from: the file named by the top-level
`model_catalog_json` key of `~/.codex/config.toml` when there is one (Reprise reads only
that key), else `~/.codex/models_cache.json`. Models under a provider prefix such as
`cursor/` are served by a proxy that `--ignore-user-config` leaves out, so they are skipped.
A temporary copy of that noncredential model catalog sets shell type
to disabled, patch tool to null, catalog tools to an empty array, direct tool
mode and disabled multi-agent mode. This closes tools advertised by model
metadata even when their feature flags are off. The native CLI's model-free
`debug models` check accepts these values and returns them unchanged. Account
identity/cache envelope fields are omitted. Missing or malformed catalog data
fails closed; explicit unknown model aliases are refused to prevent fallback
to a default tool-enabled profile. Blank selection resolves to the current
visible catalog's highest-priority model. No generation is permanently pinned.
The provider JSON schema lives only in the temporary process directory.

Grok runs a single prompt file with `--tools "" --deny '*'`, removes the
always-on MCP meta-tools, disables web search/subagents, uses the chosen reasoning effort,
`dontAsk`, `--verbatim`, and the JSON schema. The prompt file uses the documented
ACP content envelope, not an untyped JSON object. Temporary
`HOME` and `GROK_HOME` isolate global config, hooks, plugins, MCP, skills and
history. All Claude/Cursor/Codex compatibility cells are disabled. The native
existing auth path is passed via `GROK_AUTH_PATH`; credentials are never read
or copied by Reprise. Temporary config disables shared leader and updates;
memory, session search, workflows, goals and telemetry are disabled. Installed
`grok inspect --json` confirms empty MCP, hooks, plugins, skills and project
instructions with only this temporary config layer. Built-in agent presets
remain listed, but subagent execution is disabled. A sandbox alone is not the
tool boundary, because Grok's built-in sandbox can warn rather than fail on
unsupported hosts; tool filtering, denied execution and customization
isolation are independent controls. User config and sign-ins are never changed.

The installed Grok native sandbox fails while resolving a Docker socket symlink.
Reprise instead applies a macOS kernel Seatbelt policy before launching Grok,
with its native sandbox set to `off` inside that outer sandbox. Writes are allowed
only inside the private, per-call temporary directory. Forking and exec of other
programs are denied, as are known container control sockets and their resolved
targets. DNS sockets remain available for the provider connection. `realpath`
is required: Foundation may abbreviate `/private/var` to `/var`, which does not
match Seatbelt's vnode paths. The adapter fails closed if sandbox-exec is absent.
This is a layered no-tools contract, not a general-purpose confidential-computing
boundary: the provider process needs subscription authentication and network access.

## Gemini through Antigravity

Google ended the personal Gemini CLI on 2026-06-18 and points to the Antigravity CLI,
`agy`. Reprise runs `agy --input-format stream-json --output-format stream-json
--disable-slash-commands --json-schema <schema> [--model <id>] --print=` and writes one
`{"event":"user"}` message to stdin. Each request gets a temporary `HOME` with
`settings.json` set to `toolPermission: strict` and the existing
`antigravity-oauth-token` linked in as a symlink, so Reprise never reads it and the
person's conversations, history and settings stay untouched. Print mode cannot approve a
tool, so every tool request is denied. Antigravity returns the structured answer by
calling its `finish` tool, which validates it against the schema; any other tool step or
denied action fails the request. Seatbelt allows writes only in the temporary folder and
the token file (for refreshes). Gemini rejects `null` inside an `enum`, so nullable
choices are sent as `anyOf` with a null type. A blank model chooses the light-thinking
Flash model from `agy models`: the default model thought for 87 seconds on one
planning request. Each request carries about 13,000 tokens of Antigravity's own
instructions.

Google has suspended accounts that used Gemini or Antigravity sign-ins through
third-party tools, mainly tools that copied the OAuth token or proxied it to other
clients. Reprise runs Google's own CLI in its documented print mode and does not touch
the token, which keeps the risk low but not zero.

## Cursor

`cursor-agent --print --output-format stream-json --mode ask --trust [--model <id>]
--workspace <temporary folder>` gets the prompt on stdin. The workspace holds
`.cursor/cli.json` that denies shell, file reads and writes, web fetches and MCP.
Reprise starts the CLI's bundled `node` and `index.js` directly, so Seatbelt can deny
forks; exec is allowed only for that node and `/usr/bin/security`, which the CLI uses to
read its sign-in from the keychain. Writes are allowed in the temporary folder, Cursor's
chat folder for this workspace, its project and temporary caches, and its config file.
The chat, project and cache folders made for the request are removed afterwards. The
real `HOME` stays, because a temporary one breaks Cursor's sign-in. Cursor's `result`
text joins every assistant message, so the answer is read from the last one.

## OpenCode free models

`opencode run --pure --format json --model <model>` runs with private
`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` in the temporary folder and the
model catalog cached in `~/Library/Caches/local.aria.reprise/opencode`. The config turns
off plugins, MCP, instructions, sharing, snapshots and automatic updates and sets every
permission to `ask`; `run` cannot ask, so each tool request is rejected. Removing the
tools instead makes the free tier refuse the request. Only free OpenCode Zen models are
listed, refreshed from models.dev when the cache is a day old. Space Bunny is the
default; it, LongCat and Step keep no data. Big Pickle, Exo, MiMo and Ling may use
requests to improve their models, Muse Spark trains on them, and NVIDIA asks that no
personal data be sent to Nemotron. Each request carries about 35,000 tokens of
OpenCode's own instructions. See [OpenCode Zen](https://opencode.ai/docs/zen/).

## On this Mac: Apple Intelligence and Ollama

Apple's on-device model runs in the Reprise process on macOS 26 with Apple Intelligence
on. The JSON schema becomes a `DynamicGenerationSchema` for guided generation, with
permissive content transformations so quoted screen text is not refused as a request.
Its context is 4,096 tokens, so search sends at most 8 memories, 4 KiB of evidence and
one prior turn. Private Cloud Compute is not available to third-party apps.

Ollama is reached only on `127.0.0.1:11434`. `/api/chat` gets the schema as `format`,
temperature 0.2, a 12,288-token context and thinking turned off for models that think;
a reply with tool calls is rejected. Search sends at most 16 memories and 14 KiB.
Settings downloads a suggested model (EXAONE 3.5 2.4B for Korean, Qwen 3.5 4B, Gemma 3
4B) or any named model through `/api/pull`.

## API keys: OpenAI, Anthropic and Gemini

These providers need no CLI. Each request reads the key from the login keychain and sends the
same contract the CLIs get, the instructions and the evidence as one message, asking for JSON
in the shape of the schema. No tool runs, and a reply that calls one is rejected.

- **OpenAI API.** `POST https://api.openai.com/v1/responses` with `instructions`, `input`,
  `store: false` and `text.format` set to the schema (`json_schema`, not strict, because
  strict mode rejects some keywords the schemas use). The answer is the `output_text` of the
  `message` items; a `refusal` part or an incomplete status fails the request.
- **Anthropic API.** `POST https://api.anthropic.com/v1/messages` (`anthropic-version:
  2023-06-01`, `max_tokens` 8,192) with one `answer` tool whose `input_schema` is the schema
  and `tool_choice` naming it, so the answer arrives as the tool's input; the tool only
  carries the structure.
- **Gemini API.** `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
  with the key in `x-goog-api-key`, `responseMimeType: application/json` and the schema as
  `responseJsonSchema`, cleaned the same way as for Antigravity. A model that rejects the
  schema is asked again without it. Thought parts are left out of the answer.

Model menus list what the key can use (`/v1/models`, Anthropic's `/v1/models`, Gemini's
`models` with `generateContent`), without dated snapshots and models for audio, images or
embeddings. Automatic is the vendor's fast, low-cost model from that list: the newest
`gpt-N-mini`, the newest Claude Haiku, and the highest-version Gemini Flash that is not Lite,
stable before preview. Listing models also checks the key in Settings. A rejected key (401,
or Gemini's invalid-key error) is reported without quoting the vendor's message, which echoes
part of the key; a context error retries search with less evidence; other errors show the
vendor's own message. Token use comes from each reply, and the context window from the model
list where the vendor gives it (Anthropic, Gemini).

## Transcription engines

Meetings are transcribed after recording, with the engine chosen in Audio settings. Every
engine reads the sealed recording through the vault's asset reader, decoding it in pieces
to mono float PCM without a plaintext copy.

- **Apple** runs Apple's speech models on this Mac in each chosen language: SpeechAnalyzer
  on macOS 26, on-device SFSpeechRecognizer before it. It is also where every other engine
  falls back.
- **Whisper** runs through WhisperKit 1.1.1 (Argmax OSS). A model downloads from
  `argmaxinc/whisperkit-coreml` into `~/Library/Application Support/Reprise/Models/whisper`,
  with its tokenizer, and loads once right away so Core ML compiles it for the Neural Engine.
  Recordings go through in five-minute pieces cut at the quietest moment near each edge,
  with WhisperKit's voice-activity chunking, `skipSpecialTokens`, and the language passed as
  a hint when exactly one is chosen; otherwise Whisper detects it. Bracketed sound marks are
  dropped.
- **OpenAI** uses Realtime transcription sessions. For each ten-minute piece Reprise mints
  a client secret at `POST /v1/realtime/client_secrets` with
  `session.type = "transcription"`, 24 kHz 16-bit PCM input and server voice detection, then
  opens `wss://api.openai.com/v1/realtime` with the secret as a WebSocket subprotocol. The
  audio is sent as fast as the connection takes it, then two seconds of silence and a commit.
  `input_audio_buffer.speech_started` and `speech_stopped` time each utterance, and
  `conversation.item.input_audio_transcription.completed` carries its text. A piece is done
  when the closing commit is answered (usually `input_audio_buffer_commit_empty`, because
  voice detection already took everything) and every committed item has its text. Three
  pieces run at a time; a dropped connection retries its piece once. Models offered: GPT
  Transcribe (default), GPT Live Transcribe, GPT-4o Transcribe, GPT-4o mini Transcribe and
  GPT Realtime Whisper.
- **Gemini** hears the audio itself. The recording is decoded at 16 kHz and cut into
  20-minute pieces at the quietest moment near each edge; each piece is encoded as mono
  32 kbps AAC into a private temporary folder. Gemini is asked for JSON segments with a
  start time (`M:SS`), a speaker (`Speaker 1`, `Speaker 2`, … in speaking order) and the
  words verbatim, with the chosen language as a hint when exactly one is chosen. A segment
  ends where the next starts, or after about the time its words take.
  - With a Google AI plan, the piece is an `.m4a` copied into the workspace of an Antigravity
    run set up as for answers (private home, linked sign-in, kernel sandbox) but in
    `request-review` permission mode, which grants reads inside the workspace only; a print
    run cannot approve anything else. The prompt names the file's absolute path. Any tool
    step other than `view_file` and `finish`, or any denied action, rejects the answer. Two
    pieces run at a time with a timeout of three quarters of the piece's length (at least five
    minutes); in testing, 20 minutes of speech took about six minutes, most of it thinking,
    which is why pieces are not longer. Automatic uses the light-thinking Gemini Flash model.
  - With a Gemini API key, the piece is raw AAC (ADTS) sent inline as `audio/aac` to
    `generateContent` with `responseJsonSchema` and a low thinking setting (`thinkingLevel`
    for Gemini 3 and later, a zero budget for earlier Flash), asked again without that setting
    or the schema if the model refuses them. Three pieces run at a time. Automatic uses the
    newest non-Lite Flash the key lists.

  A broken answer or a CLI that stopped retries its piece once. Gemini names voices within
  one piece, so its labels are kept for recordings of one piece; longer recordings are
  labeled on this Mac by the speaker model when it is downloaded. Any other failure
  transcribes with Apple on this Mac instead, and the transcript note says why.

The OpenAI bearer is either the ChatGPT sign-in of the Codex CLI or an OpenAI API key.
For ChatGPT, Reprise starts `codex app-server -c features.plugins=false` with the same
benign environment as other provider processes, sends `initialize`, `initialized` and
`getAuthStatus` with `includeToken` and `refreshToken`, and accepts only an `authMethod`
of ChatGPT. Codex is looked up where Codex is configured in AI & Models, then in the usual
install places, then inside the ChatGPT app. The token stays in memory for one job. An API
key is read from the login keychain item `local.aria.reprise.api-key` / `openai`. A 401 or
403 says which account was refused; a 429 says the plan's or API account's limit was hit.
Any failure, including a missing account, transcribes with Apple on this Mac instead, and
the transcript note says why.

**Speaker labels** other than Gemini's use SpeakerKit's pyannote pipeline from `argmaxinc/speakerkit-coreml`
(CC BY 4.0), downloaded into `Models/speakers`. The whole recording, up to two hours, is
diarized at 16 kHz. While speakers are labeled, Apple's phrases stay separate; each segment
takes the voice heard most during it (or one within a second), voices are numbered in
speaking order, and a recording with one voice gets no labels. Neighboring segments of one
speaker and language are then joined into rows of up to 30 seconds, and the transcript
text starts a line with the speaker's name where the speaker changes. Renaming a speaker
rewrites that recording's segments and text.

## Live captions

Live captions hear Mac audio through an audio-only ScreenCaptureKit stream that leaves out
Reprise's own sounds, or the microphone through AVAudioEngine, as mono float PCM. Finding
and starting the stream each time out after 15 seconds.

- **OpenAI.** For captions in another language, Reprise mints a client secret at
  `POST /v1/realtime/translations/client_secrets` for `gpt-realtime-translate`, with
  `audio.output.language` set to the caption language and, when the spoken words are
  shown, `audio.input.transcription.model = "gpt-live-transcribe"`. It opens
  `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate` and sends
  24 kHz 16-bit PCM in `session.input_audio_buffer.append` events of about 100 ms as audio
  arrives. `session.output_transcript.delta` carries the caption text and
  `session.input_transcript.delta` the spoken words; the translated speech the session also
  returns is ignored. Captions in the spoken language use a transcription session with
  `gpt-live-transcribe`, which takes no turn detection and streams
  `conversation.item.input_audio_transcription.delta`. While a session connects, the last
  two seconds of audio wait. A dropped session reconnects up to three times, each with a
  fresh sign-in; a session OpenAI ends after running for a while is followed by the next
  at once. With Automatic, any other failure moves captions to this Mac when the spoken
  language is chosen.
- **This Mac** (macOS 26) recognizes speech with SpeechAnalyzer: SpeechTranscriber with
  volatile and fast results where it has the language, otherwise DictationTranscriber with
  punctuation and frequent finalization, which covers more languages, such as Swedish. Its
  model downloads through AssetInventory when captions start. A `TranslationSession` for
  the installed pair translates, with the low-latency model on macOS 26.4 and later and
  the standard model where the low-latency one lacks a language (26.4 has no Swedish).
  Settings checks `LanguageAvailability` and downloads a missing pair with
  `prepareTranslation()`. Volatile text is translated as it changes, and a translation that
  finishes after a newer one is dropped.

Captions keep the last 600 characters, start a new line after a sentence, and clear after
six quiet seconds. Lines wrap by estimated width, a wide character such as Hangul counting
as about one em. Captions are not stored.

## Meeting assistant

The assistant listens with two lanes of the same live speech code as captions, without
translation: the microphone as You and Mac audio as Them. OpenAI listens with a
`gpt-live-transcribe` transcription session per lane; this Mac listens with SpeechAnalyzer in
the language chosen in Settings > Meeting Assistant, or else the first transcription
language, which then guides only this Mac. A line closes at a sentence end or after 1.5
quiet seconds, and a Them line ending in `?` or `？` is a question. About 400 lines stay in
memory; nothing is stored.

- **OpenAI answers.** When the assistant opens, Reprise mints a client secret for
  `session.type = "realtime"`, `model = "gpt-realtime"`, `output_modalities = ["text"]`,
  its instructions and one `search_memory` function tool, and opens
  `wss://api.openai.com/v1/realtime?model=gpt-realtime`, so the first question starts
  answering at once. Each question is a `conversation.item.create` user message carrying
  the last four minutes of the transcript (at most 6,000 characters), followed by
  `response.create` with `tool_choice: "required"`, so every answer starts with a memory
  search. `response.function_call_arguments.done` runs the search on this Mac; its result
  returns as a `function_call_output` item and another `response.create` follows.
  `response.output_text.delta` streams the answer. The session keeps the last two
  exchanges for follow-ups and deletes older items with `conversation.item.delete`. One
  question is answered at a time; a typed one goes before one heard. The ChatGPT sign-in
  works here, where the Responses API refuses it for lack of the `api.responses.write`
  scope.
- **Memory search.** Each search term goes to the local full-text index; a phrase with no
  match is searched again by its words of three or more characters at a lower weight.
  Repeats of one app and title within five minutes collapse. Up to six excerpts of at most
  700 characters return with labels M1, M2 and on, which keep counting through the meeting.
  An answer's sources are the labels it names, or else the first three found.
- **Provider answers.** The provider chosen in AI & Models answers through the same
  contract as search, with the transcript as the first source and up to six memories found
  by the question's four longest words.
- **Automatic** asks OpenAI first. When OpenAI cannot start, the provider answers, and
  OpenAI is tried again two minutes later.
- **Web search** is a `search_web` function tool for OpenAI answers; a provider answer
  searches the question when memory search finds nothing. Automatic takes the OpenAI API key
  when OpenAI is billed by key, then Codex, then Claude Code, then the API key of the AI &
  Models provider, then any saved key. Codex runs as for answers with `web_search="live"`, low
  reasoning and the first listed model its catalog describes as fast (11.7 s for one lookup
  here, against 27.6 s on the default model). Claude Code runs as for answers with
  `--tools WebSearch --allowedTools WebSearch` and low effort (about 12 s). Both return the
  answer and its pages through the same output schema, and any other tool fails the lookup.
  The OpenAI API uses the Responses `web_search` tool and its `url_citation` annotations,
  Anthropic the `web_search_20250305` tool (at most three searches) and its citations, and
  Gemini `google_search` grounding chunks. Pages are labeled W1, W2 and on through the
  meeting.
- **MCP tools.** Reprise is an MCP client through swift-sdk 0.12.1. A command server starts
  without a shell from the words of its command line, with the person's home, a PATH of the
  usual Homebrew, npm, nvm, bun, deno, cargo and uv folders, and its environment variables;
  stderr is drained and its last line explains a failure. An address must be https, or http
  on this Mac, and uses streamable HTTP with an optional bearer token. Connecting and
  listing tools time out after 30 seconds and a call after 60; a result keeps 8,000
  characters. Each tool that is on becomes a function named after the server and the tool
  (letters, digits and `_`, at most 64 characters), and `session.update` gives the open
  answer session the new tools. Tools marked `readOnlyHint` start on; the rest start off.

## Semantic search

`MemorySearch.search(question:configuration:filter:timeZone:conversation:)` first
asks the provider for up to eight keyword alternatives, optional date/kind bounds,
and a focused or activity-overview scope. The question, current instant, timezone
and bounded prior conversation enter planning. The plan must carry its four fields
and a terms array; the rest is read leniently, because small on-device models get
details wrong. Unusable terms, dates and kinds are dropped, a local time without a
zone uses the provided timezone, and an end day on or before a whole-day start means
through that day (`since` and `until` both 2026-10-14 is that day). When a first
question's plan has no dates, its time words (오늘, 어제 저녁, last week) set them.
Whole local days use the provided timezone (including DST); planned end bounds are
exclusive. If a planned kind finds nothing and no kind filter is visible, the search
runs once more without it.

Each alternative is queried independently against the entire local FTS index,
avoiding a natural-language question ANDed into zero matches. Words of two or more
non-Latin characters and four or more Latin letters match as prefixes, so 회의 finds
회의에서, and the planner writes Korean words without particles. Page addresses are
indexed with titles and text. Up to 80 recent
hits per alternative are merged using reciprocal rank and term overlap. A
bounded time-spread fallback fills sparse results, then at most 24 candidates are
sent for the provider's answer and relevance-ordered citations. The visible
`MomentQuery` filter applies to **every** query: app is exact, its kind overrides
the plan, and date bounds intersect. Disjoint intervals return no rows rather
than widening scope. Caller-supplied literal filter text is also a hard
constraint. Filter paging/limit values do not control the candidate budget.
There is no bookmark planning field.

For broad activity summaries, SQLite scans the complete filtered interval and
groups records by app, bundle, title, kind and 15-minute bucket. A longest-text
representative is selected per group, then at most 96 are spread across the
chronologically ordered groups. Record count, group count and overall timestamp
extent accompany the answer. No activity is inferred from recording gaps.

Follow-ups include the last four question/answer pairs as quoted context, not
evidence. Focused retrieval can rehydrate up to 12 prior cited memories only if
they still exist and satisfy the current filters. Citation labels are remapped
to the new answer's evidence. Explicit new dates override prior context; day-part
follow-ups refer to the earlier question's calendar day, not a citation's time.

Results include only cited Moment IDs and the original local Moment values
for screenshot navigation. This is LLM query planning over local FTS and activity
groups, not a vector index or an exhaustive read of all excerpts. Representative
sampling and per-record truncation may still omit details; answers must avoid
exhaustive/absence claims. Selected timestamps, app names and titles are sent
as quoted provenance with candidate OCR/transcripts so temporal questions can
be answered. Image/audio bytes and filesystem paths remain local.

Completed planning and answer usage are returned separately; the UI owns
persistence. `MemorySearchFailure` exposes `underlyingError` and completed
planning usage when plan validation, retrieval, answering or cancellation
fails after planning. Failed CLI invocations without a valid terminal result
cannot currently recover their own token usage. A quota or terminal sign-in
error does not trigger an automatic alternate provider or credential setup.

## User-controlled sign-in

Installed CLI help confirms these subscription routes. The UI can open the
user's terminal for deliberate interactive sign-in; inference never launches login:

| Provider | Interactive subscription sign-in | Model-free auth status command |
| --- | --- | --- |
| Codex | `codex login` or `codex login --device-auth` | `codex login status` |
| Claude | `claude auth login --claudeai` | `claude auth status --json` |
| Grok | `grok login --oauth` or `grok login --device-auth` | No login-status subcommand in installed help |
| Gemini | Interactive `agy` start asks for a Google sign-in | `agy models` lists models only when signed in |
| Cursor | `cursor-agent login` | `cursor-agent status` |
| OpenCode | None; free models need no account | — |

Claude's `--console` and Codex API-key/token flags are not subscription sign-in
choices. Status output should be reduced to a known auth state, never printed
raw; Claude exposes `loggedIn`/`authMethod`. Reprise does not implement Grok's
native ACP subscription/billing protocol. It reads the explicit signed-in banner from `grok models`; it does
not infer quota from model availability. The core's `status` means CLI/profile
availability only. The separate `accountStatus` returns only reduced sign-in state.

## Evidence, responses, and usage

Direct `AIClient.answer` sends only the explicit question and selected Moment.text OCR/transcript.
Limits are 8 KiB for the question, 24 candidate moments, 4 KiB per moment,
and 32 KiB total evidence (8 moments and 4 KiB on Apple's model, 16 and 14 KiB on
Ollama), with UTF-8 boundaries preserved. The budget is reserved
fairly across all selected records instead of being consumed by the first few.
Activity-overview search uses up to 96 representatives within the same total
text budget. Empty and duplicate
moments are excluded. Application names, window titles, timestamps, source
paths, images, audio, library files, and other conversation history are omitted.
Local citation labels map back to Moment IDs without transmitting those IDs.
Semantic search additionally includes selected bounded provenance and up to four
prior turns, with each prior question limited to 1 KiB and answer to 3 KiB. A longer
thread also sends up to eight earlier questions, 300 bytes each, as `earlierQuestions`,
when the provider's budget keeps at least two turns.
The JSON provider input remains capped at 64 KiB. Saved search history reopens
answers and evidence IDs without planning, inference or a new usage entry.
Evidence is JSON-encoded quoted data, with instructions inside evidence explicitly
treated as untrusted.

The model must return a JSON object with `answer` and `citations`. The parser
requires a successful terminal provider event and rejects malformed/truncated JSON,
tool events and provider error results. Citation labels are read leniently:
`[m03]`, `[M3, M4]` and labels cited in the answer but missing from the list all
count. A label that was not supplied is removed from the answer, and an answer whose
citations were all invented is rejected, so every citation shown opens supplied
evidence. Citations are navigation references, not a guarantee that every model
claim is accurate.

`UsageEntry` records only nonnegative numeric input/output tokens and cost
emitted by the terminal provider result. Missing, fractional, Boolean, negative,
or string token values remain nil. No quota, paid entitlement, or token estimate
is inferred. A provider-emitted cost is telemetry, often an API-equivalent
estimate; it is not proof of an additional subscription charge. CLI-reported
served model is preferred; otherwise the requested alias or `auto` is recorded.

Each answer also keeps the tokens its request sent, cached prompt tokens included, and
the model's context window where one is known: Claude reports it with the result,
Codex's model catalog and Reprise's own copy of OpenCode's catalog list it, and Ollama
runs with the 12,288-token window Reprise asks for. Grok downloads its model catalog
into the private `GROK_HOME` of each request; Reprise takes only each model's
`context_window` from that copy before the folder is removed. The catalog names the
model asked for (`grok-4.7-build-fast`) while the result names the served one
(`grok-4.7-build`), so a served model the catalog does not name takes the window its
related or all listed models share. Gemini and Cursor report no window, so those
answers show the token count alone.

Settings offers a context window when the CLI has more than one for the model.
Claude's Opus 4.7 and later, Sonnet 5 and later, Haiku 5.5 and Fable models run with a
1M window, so its aliases and default model do too. 500K runs the CLI with
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000`, the window Claude Code works within before it
compacts; the model itself still reports 1M, and the ring measures against 500K. Older
models reach 1M only through `[1m]` variants, some billed to usage credits, so they get
no choice. Codex runs with the window its own catalog sets and offers no choice. Grok's cached model list,
`~/.grok/models_cache.json`, gives `context_windows` (256K and 500K); Reprise reads
only the window fields of that file, never its account fields or `auth.json`. Grok
applies a window from its config only to a model named with `--model`, so a chosen
window is written into the private `config.toml` as `[model."<id>"] context_window = N`
and choosing a window also names the model, Grok's default included. A window that the model does
not list is ignored. Reprise's requests stay a few thousand tokens and it never
compacts a conversation, so the choice mostly changes the ring's scale; it also moves
the point at which the CLI itself would compact.

## Process bounds and verification

Answer timeout defaults to 90 seconds and is constrained to 5-180 seconds.
Status timeout is 8 seconds. Stdout is capped at 2 MiB (128 KiB for help),
stderr at 256 KiB. Up to 128 KiB of stderr is kept in memory because some CLIs print
their help there; it is never shown or saved.
Stdin, stdout, and stderr are nonblocking. Cancellation, timeout and output
overflow terminate the owned process and descendants, escalating to SIGKILL
after 300 ms. Temporary working directories are private and removed on exit.
No shell command interpolation, inferred filesystem evidence, or credential
inspection is used.

Focused tests cover strict parsing, terminal-event requirements, tool rejection,
fabricated citations, missing/invalid usage, input bounds, timeout, cancellation,
and stdout overflow using synthetic local fixtures, native catalog/config
acceptance, search date validation, alternatives, hard visible filters, typed Grok
prompts, canonical sandbox paths, denied writes and denied child processes.
Normal `swift test` does not call models or require installed provider CLIs.
`REPRISE_TEST_NATIVE_PROVIDERS=1` enables the model-free installed-CLI checks.
`REPRISE_VERIFY_PROVIDER=codex|claude|grok|gemini|cursor|opencode|ollama|apple`
enables one synthetic planning/retrieval/answer integration check. It uses a
temporary library that is removed afterward. No TCC changes or account mutations
are part of these checks.
