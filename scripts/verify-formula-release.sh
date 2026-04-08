#!/usr/bin/env bash
# Verify Formula/nanobrew.rb release URLs return artifacts and SHA256s match.
# Usage: ./scripts/verify-formula-release.sh [path/to/nanobrew.rb]
# Requires: curl, shasum (macOS) or sha256sum (Linux)

set -euo pipefail

FORMULA="${1:-Formula/nanobrew.rb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f "$FORMULA" ]]; then
  echo "usage: $0 [Formula/nanobrew.rb]" >&2
  exit 1
fi

VERSION=$(grep -E '^\s*version\s' "$FORMULA" | sed -E 's/.*[\"'"'"']([^\"'"'"']+)[\"'"'"'].*/\1/')
ARM_URL=$(grep 'nb-arm64-apple-darwin.tar.gz' "$FORMULA" | grep url | sed -E 's/.*[\"'"'"']([^\"'"'"']+)[\"'"'"'].*/\1/')
X86_URL=$(grep 'nb-x86_64-apple-darwin.tar.gz' "$FORMULA" | grep url | sed -E 's/.*[\"'"'"']([^\"'"'"']+)[\"'"'"'].*/\1/')
ARM_SHA=$(awk '/nb-arm64-apple-darwin\.tar\.gz/{p=1} p&&/sha256/{gsub(/"/,"",$2); print $2; exit}' "$FORMULA" 2>/dev/null || true)
# Fallback: line after arm url block
if [[ -z "${ARM_SHA:-}" ]]; then
  ARM_SHA=$(grep -A3 'nb-arm64-apple-darwin.tar.gz' "$FORMULA" | grep sha256 | head -1 | sed -E 's/.*sha256[[:space:]]+[\"'"'"']([^\"'"'"']+)[\"'"'"'].*/\1/')
fi
X86_SHA=$(grep -A3 'nb-x86_64-apple-darwin.tar.gz' "$FORMULA" | grep sha256 | head -1 | sed -E 's/.*sha256[[:space:]]+[\"'"'"']([^\"'"'"']+)[\"'"'"'].*/\1/')

echo "Formula: $FORMULA"
echo "version=$VERSION"
echo ""

check_one() {
  local name="$1" url="$2" expected="$3"
  local tmp
  tmp="$(mktemp)"
  echo "Checking $name ..."
  if ! curl -fsSL -o "$tmp" "$url"; then
    echo "  FAIL: could not download $url" >&2
    rm -f "$tmp"
    return 1
  fi
  local got
  if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  else
    got="$(sha256sum "$tmp" | awk '{print $1}')"
  fi
  rm -f "$tmp"
  if [[ "$got" != "$expected" ]]; then
    echo "  FAIL: sha256 mismatch for $name" >&2
    echo "    expected: $expected" >&2
    echo "    got:      $got" >&2
    return 1
  fi
  echo "  OK ($name)"
}

fail=0
check_one "arm64" "$ARM_URL" "$ARM_SHA" || fail=1
check_one "x86_64" "$X86_URL" "$X86_SHA" || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Fix the formula or publish the GitHub Release for v$VERSION first. See docs/RELEASING.md" >&2
  exit 1
fi

echo ""
echo "All release URLs for v$VERSION look good."
