# Manual verification

Everything below runs against **your real files**, which is why no agent may run it (see the
hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-spotlight-mcp
```

## 0 — Before you start

Build a sandbox you can delete afterwards:

```bash
mkdir -p ~/Documents/ZZTest
printf 'tide tables for August\n' > ~/Documents/ZZTest/tides.md
cp /path/to/some.pdf ~/Documents/ZZTest/report.pdf
ln -s ~/Library ~/Documents/ZZTest/escape-hatch
```

Configure the extension with:

- **read roots:** `~/Documents/ZZTest`

Restart Claude Desktop. Wait a few minutes for Spotlight to index the new folder before
testing — a freshly written file can be briefly invisible to `spotlight_search` even
inside scope, which is a different problem from the boundary tests below. Delete the
whole `ZZTest` folder when you finish, symlink included.

## 1 — Status and the folder prompt

| Step | Call | Expected |
|---|---|---|
| 1.1 | `spotlight_status` | The root listed, canonicalised, probed as reachable, and Spotlight reported as responding. |
| 1.2 | First call touching `~/Documents` | macOS asks for Documents access, quoting the usage description. |
| 1.3 | Deny it, then `spotlight_search` | Refused, naming System Settings → Privacy & Security → Files and Folders. |
| 1.4 | Re-grant, restart, `spotlight_status` | Reachable again. |

## 2 — The boundary, which is the whole point

Every one of these must be **refused**. If any succeeds, stop.

| Step | Call | Expected |
|---|---|---|
| 2.1 | `spotlight_search` with `folder: ~/Documents/ZZTest/../../.ssh` | Refused as out of scope, showing the resolved path. |
| 2.2 | `spotlight_search` with `folder: ~/Library` | Refused. |
| 2.3 | `spotlight_search` with `folder: ~/Documents/ZZTest/escape-hatch` | **Refused** — the symlink resolves to `~/Library`, which is outside the read root. |
| 2.4 | `spotlight_search` with `folder: ~/Documents/ZZTest-private` | Refused. A shared name prefix is not containment. |
| 2.5 | `spotlight_search` with no `folder` at all | Scoped to the configured read root, not the whole disk. |

Step 2.3 is the one that would be quietly wrong if canonicalisation happened after
comparison rather than before. Step 2.5 confirms an unfiltered folder never means an
unfiltered disk.

## 3 — Search inside scope

| Step | Call | Expected |
|---|---|---|
| 3.1 | `spotlight_search` for `name_contains: tide` | Finds `tides.md`. |
| 3.2 | `spotlight_search` for `text_contains` a word from inside `report.pdf` | Finds it — this is the point of using Spotlight over a plain listing. |
| 3.3 | `spotlight_search` with no filter at all | Refused with the "no filter" message, not a full dump of the scope. |
| 3.4 | `spotlight_search` with `modified_after`/`modified_before` bracketing today | Finds the files you just created. |
| 3.5 | `spotlight_search` with `min_size`/`max_size` | Filters correctly against the files' actual sizes. |
| 3.6 | `spotlight_search` in a folder Spotlight has not indexed yet (a brand-new external volume, if you have one) | Says it found nothing, and `spotlight_status` shows the index as not responding for that scope — not "empty" mistaken for "broken". |
| 3.7 | A very broad, unscoped query with a common word | Returns within the deadline; if it timed out, the response says so explicitly. |

## 4 — The boundary with the other servers

| Step | Call | Expected |
|---|---|---|
| 4.1 | `spotlight_search` for something in a folder that is NOT configured on `apple-filesystem-mcp` | Spotlight finds it (if it's within apple-spotlight-mcp's own scope), but `apple-filesystem-mcp`'s `filesystem_read_text` on that same path is refused. |

This is the property worth confirming by hand: finding a path here never implies it can
be opened anywhere else.

## 5 — Packaging

| Step | Command | Expected |
|---|---|---|
| 5.1 | `otool -P .build/release/apple-spotlight-mcp \| grep UsageDescription` | Desktop, Documents and Downloads keys present. |
| 5.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 5.3 | `codesign -dv extension/server/apple-spotlight-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 5.4 | Install, restart Claude Desktop | Two switches appear, one per tool. |

## 6 — Clean up

```bash
rm -rf ~/Documents/ZZTest
```

Then set the real read scope deliberately — it can be as generous as the sibling
filesystem server's read list, since this server never writes anything.
