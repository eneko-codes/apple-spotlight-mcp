<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-spotlight-mcp icon">
</p>

# apple-spotlight-mcp

A local MCP server, written in Swift, exposing Spotlight search to Claude through
`NSMetadataQuery`. It ships as a Claude extension.

No Finder, no Apple events, no network. Everything is a direct `NSMetadataQuery` call,
gated by one allow-list of folders chosen when the extension is installed. Nothing
outside it is reachable, by any tool.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 26 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `spotlight_status` | read | Reports the read scope, whether macOS is actually letting this process reach it, and whether Spotlight is answering for it. Reads no file contents. |
| `spotlight_search` | read | Asks Spotlight for files matching name, text inside the file, kind, UTI, date range, size range or Finder tag, optionally under one folder. |

## Frameworks and APIs

| Used | For | Reference |
|---|---|---|
| Foundation `NSMetadataQuery`, `NSMetadataItem` | Every search — this is the Spotlight API | [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) |
| `NSMetadataItem*Key` constants — path, name, size, content-change date, kind, text content | Predicates and returned rows | [File Metadata Attributes](https://developer.apple.com/documentation/coreservices/file_metadata) |
| `NSPredicate`, `NSCompoundPredicate`, `NSSortDescriptor` | Building the query | [NSPredicate](https://developer.apple.com/documentation/foundation/nspredicate) |
| Foundation `FileManager` | Scope checks only | [FileManager](https://developer.apple.com/documentation/foundation/filemanager) |

The older `MDQuery`/`MDItem` C API is not used, and neither is any write API — Spotlight
offers no way to write, and this server adds none. Note that `NSMetadataQuery` answers from
the index: a file macOS has not indexed is invisible here however plainly it exists.

## The rules worth knowing before you use it

**Canonicalise first, then compare — the order is not negotiable.** Every path is
resolved before it is checked: `~` expanded, `..` removed, symlinks followed. Comparing
the raw string first would let `~/Documents/../../../etc` and a symlink pointing out of
the tree both pass a prefix test while landing somewhere else entirely. The configured
roots are canonicalised the same way, because `/tmp` is itself a symlink to
`/private/tmp` — a root compared raw would reject every path that resolved through it.
Containment is checked by path component, not string prefix, so `Documents-private` is
never mistaken for something inside `Documents`.

**Spotlight and a read allow-list are two separate checks.** `spotlight_search` answers
from Spotlight's own index, which has already read the contents of everything it
indexed — but a path it returns still has to pass whatever allow-list the tool
that opens it enforces. Finding a path here never means it is readable elsewhere.

**Spotlight can stall indefinitely** on an unindexed or network volume. Every query
carries a deadline and reports when it was hit — an empty result and a timed-out query
are two different answers, and the tool never confuses them.

**A folder Spotlight has not indexed is invisible here however plainly it exists.** An
excluded volume, a network share, or something written seconds ago will not show up in
`spotlight_search` no matter how correct the filter is. `spotlight_status` reports
whether the index is answering at all for the configured folders.

**This server has no write of any kind.** It only ever searches and reads metadata.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-spotlight-mcp.mcpb`. It fails loudly rather than shipping a bundle
that would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-spotlight-mcp.mcpb` with Claude. Then **quit Claude Desktop completely
and reopen it** — reinstalling does not replace a server process that is already
running, and the old one keeps answering.

### 3. Configure the read scope

This server is the deliberate exception to "nothing to configure":
`read_roots` is not a preference with a sensible default, it
is the security boundary itself. In Claude Desktop → Settings → Extensions → Spotlight,
set **Folders Claude may search** — Claude can find anything inside these; nothing
outside them is reachable at all. There is no hardcoded fallback like `~/Documents` — an
unconfigured install reaches nothing, deliberately, rather than reaching folders nobody
chose.

### 4. Grant the permission

The first call that touches a folder raises the macOS consent dialog for it, one dialog
per top-level location, under System Settings → Privacy & Security → Files and Folders
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas). The
embedded `Info.plist` declares separate usage descriptions for Desktop, Documents,
Downloads, removable volumes and network volumes — a read root anywhere else (iCloud
Drive, an external disk, `~/Code`) falls under **Full Disk Access** instead, which has
no per-folder prompt and has to be granted by hand.

A root that is configured but never actually reached will not prompt. `spotlight_status`
probes every configured root and reports what it found, and whether Spotlight is
answering for it.

If no dialog ever appears:

```bash
otool -P extension/server/apple-spotlight-mcp | grep UsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-spotlight-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds. `pack.sh` prints the requirement on every build, so a silent
regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires. This
server sends no Apple events and needs no entitlements file to go with it.

## Tool switches

Both tools can be turned on and off individually in Claude Desktop, because the bundle
declares them in its manifest — that is where policy lives, not in this code.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Spotlight": {
      "command": "/absolute/path/to/apple-spotlight-mcp/.build/release/apple-spotlight-mcp",
      "args": ["--read-roots", "/Users/you/Documents"]
    }
  }
}
```

You lose the per-tool switches, and the read scope must be passed as an argument by hand
since there is no `user_config` to fill it in for you.

## Known limits

- **`spotlight_search` only finds what Spotlight has indexed.** An excluded volume, a
  network share, or something written seconds ago is invisible to it however plainly it
  exists.
- **There is no "recent files" tool**, by design. Sorting by `modified` descending with
  no other filter is how you ask for recent work instead.
- **Finding a path here does not make it readable elsewhere.** Spotlight's index and a read
  allow-list are two separate checks.
- **`sort` is advertised but not honoured.** The tool schema offers `modified`, `created`,
  `name` and `size`; results always come back by modification date, newest first.

## Development

```bash
swift build
swift test
```

Tests across two suites — `PathScopeTests` and `CatalogueTests` — all against a modelled
scope that throws from every method except `canonicalise`, so a scope test that
accidentally reached a real file or a live Spotlight index fails loudly rather than
quietly passing. See `CLAUDE.md`, whose first section is the hard rule that makes that
non-negotiable: no agent working in this repository may touch a file outside it.

Manual verification against real files is the owner's job, by hand, with MCP Inspector.

## Licence

MIT.
