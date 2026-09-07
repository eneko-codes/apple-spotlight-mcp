# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. Access is bounded by `read_roots`, configured per install.

## HARD RULE — LIVE DATA IS THE OWNER'S CALL, NOT YOURS

**By default, tests run against fakes**: in-memory doubles, fixtures, and data invented for
the test. That is what makes the suite repeatable and safe to run unattended. An automated
test exists to catch a breaking change, and it does not need the owner's real data to do
that — so never reach for the real thing out of convenience.

**Debugging is different.** Sometimes the only way to see a real bug is against real data,
and that is a legitimate thing to do here — this rule is not a blanket ban and must not be
read as one. What is forbidden is deciding it alone. However harmless the check looks, the
owner decides whether their own data is touched.

So ask, before doing anything: put an explicit choice to the owner in chat — a question
with options they can pick, not a remark buried in a longer message — stating

1. exactly what you intend to run;
2. exactly which live data it would touch, named rather than summarised;
3. what it would create, change or delete, and whether that is reversible.

If they pick the option that allows it, go ahead and do it. That is a real yes. The
permission covers the run you described — a different check, or a wider one, means a fresh
question. An unrelated "go ahead" earlier in the session is not that consent.

**A yes is not permission to be careless.** Once allowed, still pick the gentlest way to get
the answer. Work down this ladder and stop at the first rung that settles the question:

1. read, and write nothing;
2. create your own record and act on that — make a new one, then modify or delete *that*,
   never something the owner made;
3. ask the owner to create a throwaway record for you to work on, saying what it needs to
   look like;
4. work on a copy of the real data, off to one side.

Changing or deleting something the owner created is the last resort. It has to have been
named in the question you asked, it has to have a way back, and you have to say which rung
you are on and why the gentler ones cannot answer it. Whatever you created, remove in the
same session.

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
