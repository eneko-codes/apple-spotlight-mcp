# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. Access is bounded by `read_roots`, configured per install.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real indexed files, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

This server only reads, so the one question is ever whether to read the owner's real files — but it is still a question, and still theirs to answer.

**`$TMPDIR` is the wrong fixture home here, unusually.** Spotlight does not index temporary directories the way it indexes the owner's folders, so a file placed there can return no match at all — and that emptiness reads as a broken query rather than an unindexed path.

## What this is

A local MCP server (Swift 6, stdio transport) for Spotlight search: name, content, kind, UTI, date range, size range and Finder tag, through `NSMetadataQuery`. No Finder, no Apple events, no network, no write of any kind, **no third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot. `Deadline.swift` is copied from `apple-system-mcp` too, until the standard's shared file holds it.

## Apple frameworks

[`NSMetadataQuery`](https://developer.apple.com/documentation/foundation/nsmetadataquery) and `NSMetadataItem` are the Spotlight API here, driven with [`NSPredicate`](https://developer.apple.com/documentation/foundation/nspredicate)/`NSCompoundPredicate` and `NSSortDescriptor` over the [file metadata attributes](https://developer.apple.com/documentation/coreservices/file_metadata) — path, name, size, content-change date, kind, text content. [FileManager](https://developer.apple.com/documentation/foundation/filemanager) does the scope checks.

**How `spotlight_search` keeps to the tool standard.** Spotlight pages at the source: `SpotlightRunner` reads only the rows of one page from the query, and the query's `resultCount` is the total, so the page notice is `Notice.page` with a known total. The limits are in `Configuration` (`searchLimitRange`, `defaultSearchLimit`, `offsetRange`, `sizeRange`); schemas, descriptions and instructions interpolate them. `Arguments.int` moves a quantity into its range and collects the sentence that says so; an argument the schema does not list is refused, with the names allowed. A query that passes its 20-second gathering deadline comes back with `timedOut`, which `Format` turns into `Notice.partial`. `Format.searchResults` renders through `ToolStandard.fitting`, so rows that are very wide halve the page instead of reaching the guard. `BoundsTests` holds this to the standard.

## Native surface not used

- The `MDQuery`/`MDItem` C API. Everything goes through the Foundation wrapper.
- Live-updating queries: results are gathered once, then the query is stopped. No `NSMetadataQueryDidUpdate` handling exists.
- Any write. Spotlight offers none, and this server adds none.
- Note the schema limit that follows from the API: `NSMetadataQuery` answers from the index, so a file macOS has not indexed is invisible here however plainly it exists. Say that, rather than reporting an empty result as an absence.
- `sort` (`modified`, `created`, `name`, `size`) is honoured by `NSSortDescriptor`s built in `SystemSpotlightStore.sortDescriptors`, always ending on the path so no two matches tie. That layer cannot be run by the tests: how Spotlight orders live data is checked by hand.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-spotlight-mcp | grep UsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
