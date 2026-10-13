# MCP Integration

Reprise provides a local stdio server using the official
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk). It reads one
explicit vault and performs no inference. A compatible client decides when to
call its tools and which model receives the results.

## Setup

1. Install Reprise in its permanent application location and open its library once.
2. In **Settings > MCP & Integrations**, enable **Allow MCP access** after reviewing
   the data-sharing warning. Screenshots require a second consent toggle.
3. Click **Install** beside Claude Desktop, Claude Code, Codex or Cursor.
4. Restart the selected client, then review its available Reprise tools.

The status label confirms a saved configuration, not a live client session.
**Check Connection** validates the bundled helper and read-only database schema
without retrieving memories. Nothing is installed into another client until the
user presses Install. The app does not start client applications automatically.

JSON clients preserve existing settings and server entries, create a private
backup beside an existing configuration, and atomically update only `reprise`.
Malformed files, symlinks and a conflicting `reprise` entry are refused. Codex uses
its native `mcp list/add/remove` commands, not a handwritten TOML editor. Only the
default per-user config location is managed; custom profiles use manual setup.

| Client | Default configuration |
| --- | --- |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Claude Code | `~/.claude.json`, user-scoped `mcpServers` |
| Cursor | `~/.cursor/mcp.json` |
| Codex | `~/.codex/config.toml`, managed through its CLI |

These paths follow the client documentation:
[Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers),
[Claude Code](https://code.claude.com/docs/en/mcp),
[Cursor](https://docs.cursor.com/context/model-context-protocol).

For another stdio client, **Copy Configuration** generates the exact app and vault
paths. A typical configuration looks like this; replace `YOUR_USER` with your own
home directory. Paths must be absolute, with no shell expansion.

```json
{
  "mcpServers": {
    "reprise": {
      "command": "/Applications/Reprise.app/Contents/MacOS/RepriseMCP",
      "args": ["--vault", "/Users/YOUR_USER/Library/Application Support/Reprise"]
    }
  }
}
```

The app may be closed while MCP is used. No HTTP listener, tunnel, cloud relay or
authentication token is created. Clients requiring remote HTTP MCP need a separate
bridge, which Reprise does not supply in this alpha.

## Tools

| Tool | Purpose |
| --- | --- |
| `reprise_library_status` | Current timezone, coverage bounds, memory count and app names |
| `reprise_search` | Search OCR/transcripts or browse newest-first with app/kind/date filters |
| `reprise_activity_overview` | Representative activities across the complete filtered interval, with coverage counts |
| `reprise_get_memory` | Retrieve OCR/transcript text and timed segments by memory ID |
| `reprise_get_screenshot` | Explicitly permitted, bounded JPEG preview for a screen memory |

Search pages default to 20 and cap at 50. Use `next_offset` for subsequent pages.
New recording/deletion can shift offset-based pagination. For summaries, start
with an overview (up to 96 activity representatives), then search narrower time
ranges or retrieve selected memories. Do not treat sampling as exhaustive.

Dates use ISO 8601 with explicit timezone offsets. Text and timed transcript
segments have independent pagination (`next_text_offset`, `next_segment_offset`).
Text pages cap at 16,000 characters; segment pages contain at most 40 bounded
excerpts. Full transcript text remains accessible through text pagination.
Screenshot previews cap at 1280px and omit the source image's metadata.
Raw audio and arbitrary files are never returned.

All returned OCR, transcripts and titles are untrusted evidence, not instructions.
Cite source IDs and timestamps; an MCP tool result does not prove an AI answer is
correct. Turning access off blocks subsequent tool responses, including from
already-running helpers. Data already sent to a client cannot be recalled.

## Boundary And Troubleshooting

The helper opens SQLite read-only with query-only mode and performs no migrations.
Missing/old schemas must first be opened by the current Reprise app. Access settings
are checked before reading and after suspended work. Screenshots use root-relative
stored paths and reject traversal, symlinks and oversized files. No tools expose
recording, deletion, arbitrary SQL, shell commands or configuration changes.

This is an application-level consent gate, **not an OS sandbox against other
processes running as your macOS user**. The vault is unencrypted, and clients may
retain tool results or transmit them to their providers. See [Privacy](PRIVACY.md).

If the app moves or the vault changes, remove the old entry and install again from
the new copy. A conflicting entry is not overwritten automatically. Close a client
that repeatedly overwrites its settings, then retry. The generated JSON can also
be merged manually through that client's own configuration UI.
