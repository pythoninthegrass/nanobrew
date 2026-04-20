#!/usr/bin/env bash
# Codesign + notarize a macOS `nb` binary locally using the `codedb-notary`
# keychain profile. Produces a signed binary, a notarized tar.gz, and a .sha256
# sidecar alongside the input.
#
# Usage:
#   scripts/notarize-macos.sh <path-to-nb-binary> [arch-tag]
#
# If arch-tag is omitted, it is inferred via `file` (arm64 | x86_64).
#
# Prereqs (one-time):
#   xcrun notarytool store-credentials codedb-notary \
#     --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
#     --password "$APPLE_APP_SPECIFIC_PASSWORD"

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "notarize-macos.sh: this script only runs on macOS" >&2
  exit 1
fi

BIN="${1:-}"
if [[ -z "$BIN" || ! -f "$BIN" ]]; then
  echo "usage: $0 <path-to-nb-binary> [arch-tag]" >&2
  exit 1
fi

ARCH_TAG="${2:-}"
if [[ -z "$ARCH_TAG" ]]; then
  case "$(file -b "$BIN")" in
    *arm64*)  ARCH_TAG="arm64"  ;;
    *x86_64*) ARCH_TAG="x86_64" ;;
    *)
      echo "notarize-macos.sh: cannot infer arch from '$BIN'; pass arch-tag explicitly" >&2
      exit 1
      ;;
  esac
fi

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Rachit Pradhan (WWP9DLJ27P)}"
PROFILE="${NOTARY_PROFILE:-codedb-notary}"

OUT_DIR="$(cd "$(dirname "$BIN")" && pwd)"
TARBALL="$OUT_DIR/nb-${ARCH_TAG}-apple-darwin.tar.gz"
SHAFILE="$TARBALL.sha256"
ZIPFILE="$OUT_DIR/nb-${ARCH_TAG}-apple-darwin-notarize.zip"

echo "==> codesign ($IDENTITY)"
codesign --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --force \
  "$BIN"
codesign --verify --deep --strict "$BIN"

echo "==> notarize via profile '$PROFILE'"
rm -f "$ZIPFILE"
ditto -c -k --keepParent "$BIN" "$ZIPFILE"
xcrun notarytool submit "$ZIPFILE" --keychain-profile "$PROFILE" --wait
rm -f "$ZIPFILE"

# Standalone Mach-O CLI binaries are not .app bundles, so `spctl --assess
# --type execute` will reject them even when correctly notarized. Verify the
# signature fields directly instead: Developer ID authority + hardened runtime.
# Gatekeeper/syspolicyd will fetch the notarization ticket online on first run
# for quarantined downloads.
echo "==> verify signature fields"
CS_OUT="$(codesign -dv --verbose=4 "$BIN" 2>&1 || true)"
echo "$CS_OUT" | grep -E '^(Authority|TeamIdentifier|CodeDirectory v=|flags=)' || true
if ! echo "$CS_OUT" | grep -q "Authority=Developer ID Application"; then
  echo "notarize-macos.sh: binary is not signed with a Developer ID authority" >&2
  exit 1
fi
if ! echo "$CS_OUT" | grep -q "flags=0x10000(runtime)"; then
  echo "notarize-macos.sh: binary is missing the hardened runtime flag" >&2
  exit 1
fi

echo "==> package $TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$BIN")" "$(basename "$BIN")"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$SHAFILE")")
shasum -a 256 "$TARBALL" > "$SHAFILE"

echo ""
echo "done:"
echo "  signed+notarized: $BIN"
echo "  tarball:          $TARBALL"
echo "  sha256:           $SHAFILE"
