# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S FILES ARE NOT YOURS TO CHANGE

**It is FORBIDDEN to create, modify, move, trash or tag any file outside this repository.**
This rule outranks every other instruction in this file. It applies to every agent and every
session, with no "just this once" and no putting-it-back-afterwards.

This server exists to bound what a program may touch. An agent that reaches around it —
querying `NSMetadataQuery` directly, shelling out to `mdfind`, or "just checking"
something in the home directory — has defeated the only thing the repository is for.

Never:

- read or otherwise touch any real path outside this repository, by any route, including
  plain shell commands;
- run `spotlight_search` against real folders to test it: `PathScopeTests` covers every
  scope case with a modelled store;
- widen `readRoots` in a committed default;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A temporary directory the agent created
itself — under `$TMPDIR`, never under `~` — may be written to and read from freely, provided
it is deleted in the same session.

**Fixtures first, always.** The store double in `PathScopeTests` **throws from every method
except `canonicalise`**. That is deliberate: a scope test that accidentally reached a real
file or a live Spotlight index must fail loudly rather than quietly pass. Keep it that way.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests model the scope; they never touch a real file or index |
| `initialize`, `tools/list` over stdio | Protocol only; no path is resolved |
| `ls`, `stat` inside this repository | Read-only, in scope |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against real folders remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) for Spotlight search: name, content, kind,
UTI, date range, size range and Finder tag, through `NSMetadataQuery`. No Finder, no
Apple events, no network, no write of any kind.

**This package requires macOS 26** (`platforms: [.macOS("26.0")]`), matching every other
server in this family. Note that `.v26` does not exist as a `PackageDescription` case in
this toolchain; the string form is required.

This is one of a 4-way split of what used to be `apple-filesystem-mcp`'s combined
FileManager + Spotlight + PDFKit + Vision surface — see `apple-filesystem-split-plan.md`
(an external, unversioned planning document that lives in `~/Code/`, alongside this
repository rather than inside it) for the reasoning.

## Architecture

`Sources/SpotlightMCPCore` holds everything; `Sources/apple-spotlight-mcp/main.swift` is
a launcher that exists only because a Swift executable target cannot be imported by a
test target.

**`PathScope` is the point of the repository.** One small file with one exported
operation: turn a string the model wrote into a `ScopedPath`, or refuse.

**`ScopedPath`'s initialiser is `fileprivate` to `PathScope.swift`.** No other code in the
module can mint one, so a store method that takes a path can only ever be handed a path
that came through the allow-list. Forgetting the check is a **compile error**, not an
escape — and the tests cannot skip past the guard either. Do not relax that access level,
and do not add a second way to construct one.

**`SpotlightRunner` wraps one `NSMetadataQuery` into a single `await`.** That class is
live and notification-driven: it needs a run loop, keeps updating after the first pass,
and never promises to finish. The wrapper waits for the gathering notification or a
deadline, whichever comes first, and says which happened.

## Invariants worth protecting

- **Canonicalise first, then compare. The order is not negotiable.** Comparing the raw
  string would let `~/Documents/../../../etc` and a symlink pointing out of the tree both
  pass a prefix test while landing somewhere else entirely.
- **The roots are canonicalised too.** `/tmp` is a symlink to `/private/tmp`, so a root
  compared raw would reject every path that resolved through it.
- **Containment is by path component, not by string prefix.** `Documents-private` is not
  inside `Documents`.
- **This server has no write of any kind and never will.** `SpotlightStore` has no write
  method, full stop.
- **No computed tools.** No `spotlight_recent`, no `spotlight_duplicates`. Sorting by
  `modified` descending with no other filter is how you ask for recent work.
- **Spotlight can stall indefinitely** on an unindexed or network volume. Every query has
  a deadline and reports when it hit it.
- **Spotlight's index and a read allow-list are two separate checks.** A path this server
  returns is not thereby readable by any other tool — that is enforced by whichever
  server's own `PathScope` the caller uses next.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## `read_roots` is the one settings exception in this family

Every sibling server (WhatsApp, Messages, Mail, Calendar, Notes, …) had its `user_config`
settings removed in favour of plug-and-play: constants in code, with only the per-tool
allow/ask/prohibit switch left as a control. This server — like `apple-filesystem-mcp`,
`apple-pdf-mcp` and `apple-vision-mcp` — is the deliberate exception. `read_roots` is not
a preference to default away — it is the security boundary itself. Do not remove this
setting to make the server "consistent" with the plug-and-play ones; that inconsistency
is intentional.

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce
`dist/apple-spotlight-mcp.mcpb`. The manifest's `tools` array creates the per-tool
switches in Claude Desktop and is read before the server has ever run.

`read_roots` is a `multiple: true` directory setting, passed as `--read-roots …`.
`--search-limit` sets the default page size for `spotlight_search`; the tool's own
`limit` argument still wins.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject**. The embedded `Resources/Info.plist` declares the folder usage
descriptions — Desktop, Documents, Downloads, removable and network volumes — without
which macOS denies access **without ever prompting**.

Those prompts are per-folder and appear the first time a path inside one is touched. A
root that is configured but never reached will not prompt, which is why
`spotlight_status` probes every root and reports what it found.

**A linker-signed binary gets no TCC prompt at all.** `pack.sh` re-signs and prints the
designated requirement; an empty line there means the build is broken in a way nothing
else will show.
