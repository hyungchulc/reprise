# Subscription CLI providers

Reprise uses existing local CLI sign-ins. It does not read, copy, create, or display
credentials. Explicit Sign In opens the provider's subscription login in Terminal.
It does not call a billing API or create an API key. Core readiness is a bounded
help check; the UI separately checks model-free subscription status. Account quota
remains unknown. Opt-in synthetic search checks passed with Codex, Claude and Grok
on 2026-10-13. No personal memories were sent during verification.

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

`AIProviderKind` contains `codex`, `claude`, and `grok`. Configuration is
Codable and all public value types are Sendable. A blank model follows the
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

Claude runs with `--print --output-format json --safe-mode --restricted --tools ""`,
an explicit answer/citations JSON schema, high reasoning effort,
an empty strict MCP configuration, disabled slash commands, no Chrome integration,
no session persistence, `dontAsk` permission mode, and `disableAllHooks`.
Its replacement system prompt restricts the response to explicitly supplied
evidence. Safe mode preserves native subscription auth. `--bare` is deliberately
avoided because the installed help says it disables OAuth/keychain subscription
auth and requires API authentication. The subprocess receives only an allowlist
of benign runtime environment variables, so API keys and billing overrides from
the app environment are not inherited.

Codex runs `exec --json --ephemeral --ignore-user-config --ignore-rules` with a
read-only sandbox, never-approve policy, high reasoning, OpenAI subscription
provider, disabled web search and disabled capability features (shell, apps,
plugins, hooks, browser, computer, images, memory, subagents and code mode).
It also uses the documented `model_catalog_json` setting from the
[configuration schema](https://developers.openai.com/codex/config-schema.json).
A temporary copy of the existing noncredential model catalog sets shell type
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
always-on MCP meta-tools, disables web search/subagents, uses high reasoning,
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

## Semantic search

`MemorySearch.search(question:configuration:filter:timeZone:conversation:)` first
asks the provider for up to eight keyword alternatives, optional date/kind bounds,
and a focused or activity-overview scope. The question, current instant, timezone
and bounded prior conversation enter planning. JSON
is validated for exact fields, bounded literal terms, explicit date offsets,
valid local calendar dates and ordered bounds. Whole local days use the
provided timezone (including DST); planned end bounds are exclusive.

Each alternative is queried independently against the entire local FTS index,
avoiding a natural-language question ANDed into zero matches. Up to 80 recent
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

Claude's `--console` and Codex API-key/token flags are not subscription sign-in
choices. Status output should be reduced to a known auth state, never printed
raw; Claude exposes `loggedIn`/`authMethod`. Reprise does not implement Grok's
native ACP subscription/billing protocol. It reads the explicit signed-in banner from `grok models`; it does
not infer quota from model availability. The core's `status` means CLI/profile
availability only. The separate `accountStatus` returns only reduced sign-in state.

## Evidence, responses, and usage

Direct `AIClient.answer` sends only the explicit question and selected Moment.text OCR/transcript.
Limits are 8 KiB for the question, 24 candidate moments, 4 KiB per moment,
and 32 KiB total evidence, with UTF-8 boundaries preserved. The budget is reserved
fairly across all selected records instead of being consumed by the first few.
Activity-overview search uses up to 96 representatives within the same total
text budget. Empty and duplicate
moments are excluded. Application names, window titles, timestamps, source
paths, images, audio, library files, and other conversation history are omitted.
Local citation labels map back to Moment IDs without transmitting those IDs.
Semantic search additionally includes selected bounded provenance and up to four
prior turns, with each prior question limited to 1 KiB and answer to 3 KiB.
The JSON provider input remains capped at 64 KiB. Saved search history reopens
answers and evidence IDs without planning, inference or a new usage entry.
Evidence is JSON-encoded quoted data, with instructions inside evidence explicitly
treated as untrusted.

The model must return a JSON object with `answer` and `citations`. The parser
requires a successful terminal provider event, rejects malformed/truncated JSON,
tool events, provider error results and unknown citation labels, and checks
inline `[M1]` references against the supplied labels. Citations are navigation
references, not a guarantee that every model claim is accurate.

`UsageEntry` records only nonnegative numeric input/output tokens and cost
emitted by the terminal provider result. Missing, fractional, Boolean, negative,
or string token values remain nil. No quota, paid entitlement, or token estimate
is inferred. A provider-emitted cost is telemetry, often an API-equivalent
estimate; it is not proof of an additional subscription charge. CLI-reported
served model is preferred; otherwise the requested alias or `auto` is recorded.

## Process bounds and verification

Answer timeout defaults to 90 seconds and is constrained to 5-180 seconds.
Status timeout is 8 seconds. Stdout is capped at 2 MiB (128 KiB for help),
stderr at 256 KiB; stderr content is drained but never surfaced or retained.
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
`REPRISE_VERIFY_PROVIDER=codex|claude|grok`
enables one synthetic planning/retrieval/answer integration check. It uses a
temporary library that is removed afterward. No TCC changes or account mutations
are part of these checks.
