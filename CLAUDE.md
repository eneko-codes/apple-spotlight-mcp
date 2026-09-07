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

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-spotlight-mcp | grep UsageDescription
```
