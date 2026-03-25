#!/bin/bash
# Test: comprehensive smoke integration tests for nanobrew on macOS
# Usage: bash tests/smoke-test.sh <path-to-nb-binary>
set -euo pipefail

NB="${1:?Usage: $0 <nb-binary>}"
NB="$(cd "$(dirname "$NB")" && pwd)/$(basename "$NB")"
PASS=0
FAIL=0

pass() { echo "    PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "    FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "==> Smoke integration tests (macOS)"
echo "    Binary: $NB"
echo ""

# Ensure nanobrew is initialised
sudo "$NB" init >/dev/null 2>&1 || true

# ===================================================================
# Basic install + binary verification
# ===================================================================

echo "--- Test: install tree ---"
"$NB" install tree >/dev/null 2>&1 || true
if tree --version 2>&1 | grep -qi "tree"; then
  pass "tree --version works"
else
  fail "tree --version did not produce expected output"
fi

echo ""
echo "--- Test: install jq ---"
"$NB" install jq >/dev/null 2>&1 || true
if jq --version 2>&1 | grep -q "jq"; then
  pass "jq --version works"
else
  fail "jq --version did not produce expected output"
fi

echo ""
echo "--- Test: install lua ---"
"$NB" install lua >/dev/null 2>&1 || true
if lua -v 2>&1 | grep -qi "lua"; then
  pass "lua -v works"
else
  fail "lua -v did not produce expected output"
fi

# ===================================================================
# Cask info
# ===================================================================

echo ""
echo "--- Test: info --cask firefox ---"
CASK_FF=$("$NB" info --cask firefox 2>&1) || true
if echo "$CASK_FF" | grep -q "Firefox"; then
  pass "info --cask firefox contains 'Firefox'"
else
  fail "info --cask firefox output missing 'Firefox'"
  echo "      output: $(echo "$CASK_FF" | head -3)"
fi

echo ""
echo "--- Test: info --cask visual-studio-code ---"
CASK_VSC=$("$NB" info --cask visual-studio-code 2>&1) || true
if echo "$CASK_VSC" | grep -q "Visual Studio Code"; then
  pass "info --cask visual-studio-code contains 'Visual Studio Code'"
else
  fail "info --cask visual-studio-code output missing 'Visual Studio Code'"
  echo "      output: $(echo "$CASK_VSC" | head -3)"
fi

# ===================================================================
# Python/script packages (@@HOMEBREW_CELLAR@@ bug)
# ===================================================================

echo ""
echo "--- Test: install awscli (script package) ---"
"$NB" install awscli >/dev/null 2>&1 || true
if aws --version 2>&1 | grep -q "aws-cli"; then
  pass "aws --version works (no bad interpreter)"
else
  fail "aws --version failed (possible @@HOMEBREW_CELLAR@@ bug)"
fi

echo ""
echo "--- Test: no @@HOMEBREW_CELLAR@@ or @@HOMEBREW_PREFIX@@ placeholders in Cellar ---"
CELLAR_DIR="/opt/nanobrew/prefix/Cellar"
if [ -d "$CELLAR_DIR" ]; then
  PLACEHOLDER_HITS=$(grep -rl '@@HOMEBREW_CELLAR@@\|@@HOMEBREW_PREFIX@@' "$CELLAR_DIR" 2>/dev/null | head -5) || true
  if [ -z "$PLACEHOLDER_HITS" ]; then
    pass "no unreplaced @@HOMEBREW_*@@ placeholders in Cellar"
  else
    fail "found unreplaced @@HOMEBREW_*@@ placeholders"
    echo "$PLACEHOLDER_HITS" | sed 's/^/      /'
  fi
else
  fail "Cellar directory not found at $CELLAR_DIR"
fi

# ===================================================================
# Search
# ===================================================================

echo ""
echo "--- Test: search ripgrep ---"
SEARCH_OUT=$("$NB" search ripgrep 2>&1) || true
if echo "$SEARCH_OUT" | grep -q "ripgrep"; then
  pass "search ripgrep contains 'ripgrep'"
else
  fail "search ripgrep output missing 'ripgrep'"
  echo "      output: $(echo "$SEARCH_OUT" | head -3)"
fi

# ===================================================================
# Outdated (version comparison)
# ===================================================================

echo ""
echo "--- Test: outdated does not false-positive pcre2 10.47_1 vs 10.47 ---"
OUTDATED_OUT=$("$NB" outdated 2>&1) || true
if echo "$OUTDATED_OUT" | grep -q "pcre2.*10\.47_1.*10\.47"; then
  fail "outdated false-positive: pcre2 10.47_1 shown as outdated vs 10.47"
else
  pass "outdated does not false-positive pcre2 version suffix"
fi

# ===================================================================
# Bundle
# ===================================================================

echo ""
echo "--- Test: bundle dump ---"
BUNDLE_OUT=$("$NB" bundle dump 2>&1) || true
if echo "$BUNDLE_OUT" | grep -q '^brew "'; then
  pass "bundle dump contains brew format lines"
else
  fail "bundle dump output missing 'brew \"' lines"
  echo "      output: $(echo "$BUNDLE_OUT" | head -3)"
fi

# ===================================================================
# Deps
# ===================================================================

echo ""
echo "--- Test: deps --tree wget ---"
"$NB" install wget >/dev/null 2>&1 || true
DEPS_OUT=$("$NB" deps --tree wget 2>&1) || true
if echo "$DEPS_OUT" | grep -qi "openssl"; then
  pass "deps --tree wget contains 'openssl'"
else
  fail "deps --tree wget output missing 'openssl'"
  echo "      output: $(echo "$DEPS_OUT" | head -5)"
fi

# ===================================================================
# Migrate
# ===================================================================

echo ""
echo "--- Test: migrate ---"
MIGRATE_OUT=$("$NB" migrate 2>&1) || true
if echo "$MIGRATE_OUT" | grep -qi "Migrated.*formulae"; then
  pass "migrate prints 'Migrated X formulae'"
else
  fail "migrate output missing 'Migrated X formulae'"
  echo "      output: $(echo "$MIGRATE_OUT" | head -3)"
fi

# ===================================================================
# Doctor
# ===================================================================

echo ""
echo "--- Test: doctor ---"
DOCTOR_OUT=$("$NB" doctor 2>&1) || true
if echo "$DOCTOR_OUT" | grep -qi "Checking nanobrew installation"; then
  pass "doctor prints 'Checking nanobrew installation'"
else
  fail "doctor output missing 'Checking nanobrew installation'"
  echo "      output: $(echo "$DOCTOR_OUT" | head -3)"
fi

# ===================================================================
# Summary
# ===================================================================

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
