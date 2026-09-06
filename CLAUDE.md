# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. Access is bounded by `read_roots`, configured per install.

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
