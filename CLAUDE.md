# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. Access is bounded by `read_roots`, configured per install.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real indexed files, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

This server only reads, so the one question is ever whether to read the owner's real files — but it is still a question, and still theirs to answer.

**`$TMPDIR` is the wrong fixture home here, unusually.** Spotlight does not index temporary directories the way it indexes the owner's folders, so a file placed there can return no match at all — and that emptiness reads as a broken query rather than an unindexed path.

## What this is

A local MCP server (Swift 6, stdio transport) for Spotlight search: name, content, kind, UTI, date range, size range and Finder tag, through `NSMetadataQuery`. No Finder, no Apple events, no network, no write of any kind.

## Apple frameworks

[`NSMetadataQuery`](https://developer.apple.com/documentation/foundation/nsmetadataquery) and `NSMetadataItem` are the Spotlight API here, driven with [`NSPredicate`](https://developer.apple.com/documentation/foundation/nspredicate)/`NSCompoundPredicate` and `NSSortDescriptor` over the [file metadata attributes](https://developer.apple.com/documentation/coreservices/file_metadata) — path, name, size, content-change date, kind, text content. [FileManager](https://developer.apple.com/documentation/foundation/filemanager) does the scope checks.

## Native surface not used

- The `MDQuery`/`MDItem` C API. Everything goes through the Foundation wrapper.
- Live-updating queries: results are gathered once, then the query is stopped. No `NSMetadataQueryDidUpdate` handling exists.
- Any write. Spotlight offers none, and this server adds none.
- Note the schema limit that follows from the API: `NSMetadataQuery` answers from the index, so a file macOS has not indexed is invisible here however plainly it exists. Say that, rather than reporting an empty result as an absence.
- **Known defect:** `spotlight_search` advertises a `sort` argument (`modified`, `created`, `name`, `size`) that the dispatch never reads — results are always sorted by modification date, newest first. Fix the schema or honour the argument; do not document it as working.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-spotlight-mcp | grep UsageDescription
```
