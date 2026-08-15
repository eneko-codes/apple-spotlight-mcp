#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. There is no dependency on the
# `mcpb` CLI here: zip is enough, and it keeps the toolchain to what macOS ships.
set -euo pipefail

NAME="apple-spotlight-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Universal, so the bundle also runs on an Intel Mac. Drop the second --arch for a
# faster local build.
echo "==> Building $NAME (universal)"
swift build -c release --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/$NAME"
[ -f "$BINARY" ] || BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary found" >&2; exit 1; }

# The embedded Info.plist is what makes this binary its own TCC subject. Without it
# macOS denies access with no prompt, which is a confusing failure to debug later.
echo "==> Checking the embedded Info.plist survived linking"
otool -P "$BINARY" | grep -q "UsageDescription" \
  || { echo "!! Info.plist missing from $BINARY" >&2; exit 1; }

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# Re-sign, because the signature `swift build` leaves is not enough for TCC.
#
# The linker adds its own ad-hoc signature, flagged `linker-signed`. macOS treats that
# as "signed by nobody": TCC will not register the binary as a subject, so a permission
# request never reaches it and no dialog is ever shown. The symptom is silent — the
# request simply returns with the status still `notDetermined`.
#
# Do not try to confirm that from `log show --predicate 'subsystem == "com.apple.TCC"'`.
# That subsystem returns nothing on a normal machine whatever happens, so an empty log
# is not evidence of anything; the flags below are.
#
# Verified on macOS 26.5: `codesign --force --sign -` turns flags=0x20002
# (adhoc,linker-signed) into flags=0x2 (adhoc), and the embedded Info.plist survives.
#
# Ad-hoc is still not enough to make a grant durable — it produces no designated
# requirement, so TCC falls back to the cdhash and every rebuild re-prompts. Set
# MCPB_SIGN_IDENTITY to a real signing identity to fix that; see the README.
IDENTITY="${MCPB_SIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"

# The identifier is pinned rather than inferred. codesign derives it from the embedded
# Info.plist when there is one and from the filename otherwise, and the designated
# requirement quotes it — so letting it be inferred makes the requirement depend on how
# the binary was built. Keep this in step with CFBundleIdentifier in Resources/Info.plist:
# they are two names for the same thing, and TCC sees both.
SIGN_ARGS=(--force --identifier "codes.eneko.$NAME" --sign "$IDENTITY")

# Hardened runtime is off by default: it is required for notarisation, not for TCC, and
# it blocks Apple events unless the entitlement below is granted. Opt in with
# MCPB_HARDENED=1 when preparing something to distribute.
if [ "${MCPB_HARDENED:-0}" = "1" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
  [ -f "$ROOT/Resources/entitlements.plist" ] \
    && SIGN_ARGS+=(--entitlements "$ROOT/Resources/entitlements.plist")
fi

codesign "${SIGN_ARGS[@]}" "$STAGE/server/$NAME"
FLAGS=$(codesign -dv "$STAGE/server/$NAME" 2>&1 | grep -oE 'flags=[^ ]*' || true)
case "$FLAGS" in
  *linker-signed*) echo "!! still linker-signed ($FLAGS) — TCC will never prompt" >&2; exit 1 ;;
  *) echo "    $FLAGS" ;;
esac

# Signing rewrites the binary, so re-check the plist rather than trusting the earlier pass.
otool -P "$STAGE/server/$NAME" | grep -q "UsageDescription" \
  || { echo "!! Info.plist lost during signing" >&2; exit 1; }

python3 -c "import json,sys; json.load(open('$STAGE/manifest.json'))" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

# The designated requirement is what TCC anchors a grant to. An ad-hoc signature produces
# none, which is why the grant falls back to the cdhash and dies on every rebuild.
# Printing it makes a silent regression to ad-hoc visible at build time.
echo "==> Designated requirement"
codesign -d -r- "$STAGE/server/$NAME" 2>&1 | grep "^designated" | sed 's/^/    /' \
  || echo "    (none — TCC will key on the cdhash and re-prompt after every rebuild)"

echo "==> Packing"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME.mcpb"
rm -f "$OUT"
# -X drops resource forks and extra attributes; the archive should contain only what
# the manifest describes.
( cd "$STAGE" && zip -qrX "$OUT" manifest.json icon.png server )

# The MCPB spec does not say whether the installer preserves the executable bit, so
# verify the archive at least records it. If a future Claude release drops it, the
# symptom is a server that never starts, and the fix is a chmod +x on the installed
# copy — see the README.
echo "==> Verifying the executable bit survived"
MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install it by opening the file with Claude."
