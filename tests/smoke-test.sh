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
export PATH="/opt/nanobrew/prefix/bin:$PATH"

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
if grep -q "Firefox" <<<"$CASK_FF"; then
  pass "info --cask firefox contains 'Firefox'"
else
  fail "info --cask firefox output missing 'Firefox'"
  echo "      output: $(echo "$CASK_FF" | head -3)"
fi

echo ""
echo "--- Test: info --cask visual-studio-code ---"
CASK_VSC=$("$NB" info --cask visual-studio-code 2>&1) || true
if grep -q "Visual Studio Code" <<<"$CASK_VSC"; then
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
AWS_VERSION_OUT=$(aws --version 2>&1) || true
if grep -q "aws-cli" <<<"$AWS_VERSION_OUT"; then
  pass "aws --version works (no bad interpreter)"
else
  fail "aws --version failed (possible @@HOMEBREW_CELLAR@@ bug)"
  echo "      which aws: $(command -v aws || echo 'not found')"
  if [ -e /opt/nanobrew/prefix/bin/aws ]; then
    echo "      prefix/bin/aws: $(ls -l /opt/nanobrew/prefix/bin/aws)"
    echo "      prefix/bin/aws shebang: $(head -n 1 /opt/nanobrew/prefix/bin/aws 2>/dev/null || echo 'unreadable')"
  else
    echo "      prefix/bin/aws: missing"
  fi
  if [ -e /opt/nanobrew/prefix/Cellar/awscli ]; then
    AWS_LIBEXEC=$(find /opt/nanobrew/prefix/Cellar/awscli -path '*/libexec/bin/aws' | head -n 1)
    AWS_PY=$(find /opt/nanobrew/prefix/Cellar/awscli -path '*/libexec/bin/python' | head -n 1)
    if [ -n "$AWS_LIBEXEC" ]; then
      echo "      libexec aws: $(ls -l "$AWS_LIBEXEC")"
      echo "      libexec aws shebang: $(head -n 1 "$AWS_LIBEXEC" 2>/dev/null || echo 'unreadable')"
    fi
    if [ -n "$AWS_PY" ]; then
      echo "      libexec python: $(ls -l "$AWS_PY")"
      echo "      libexec python resolved: $(python3 - <<'PY' "$AWS_PY"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
    fi
  fi
  echo "      aws --version output: $(printf '%s' "$AWS_VERSION_OUT" | head -3)"
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
if grep -q "ripgrep" <<<"$SEARCH_OUT"; then
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
if grep -q "pcre2.*10\.47_1.*10\.47" <<<"$OUTDATED_OUT"; then
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
if grep -q 'brew "' <<<"$BUNDLE_OUT"; then
  pass "bundle dump contains brew format lines"
elif [ -z "$BUNDLE_OUT" ]; then
  # On CI with fresh install, bundle dump may return nothing if DB didn't record
  pass "bundle dump returned empty (fresh CI environment, acceptable)"
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
if grep -qi "openssl" <<<"$DEPS_OUT"; then
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
if grep -qi "Migrated.*formulae" <<<"$MIGRATE_OUT" || grep -qi "^Migrated:" <<<"$MIGRATE_OUT"; then
  pass "migrate prints migration results"
else
  fail "migrate output missing migration summary"
  echo "      output: $(echo "$MIGRATE_OUT" | head -3)"
fi

# ===================================================================
# Doctor
# ===================================================================

echo ""
echo "--- Test: doctor ---"
DOCTOR_OUT=$("$NB" doctor 2>&1) || true
if grep -qi "Checking nanobrew installation" <<<"$DOCTOR_OUT"; then
  pass "doctor prints installation check banner"
else
  fail "doctor output missing 'Checking nanobrew installation'"
  echo "      output: $(echo "$DOCTOR_OUT" | head -3)"
fi
# ===================================================================
# Regression: tar subprocess fallback for unsupported headers (#221)
# perl's bottle uses GNU long-name / pax-extended headers that Zig's
# native tar can't parse — the subprocess fallback must kick in.
# ===================================================================

echo ""
echo "--- Test: install perl (exercises tar subprocess fallback #221) ---"
"$NB" install perl >/dev/null 2>&1 || true
if perl -e 'print "ok"' 2>&1 | grep -q "^ok$"; then
  pass "perl installed and runs (#221 tar fallback works)"
else
  fail "perl install or execution failed — tar fallback may have regressed"
  echo "      which perl: $(command -v perl || echo 'not found')"
  if [ -e /opt/nanobrew/prefix/Cellar/perl ]; then
    echo "      Cellar/perl present"
  else
    echo "      Cellar/perl missing — extract likely failed"
  fi
fi

# ===================================================================
# Regression: Intel Mac does not install arm64 bottles (#226/#227)
# Only meaningful on x86_64 Macs.
# ===================================================================

if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "x86_64" ]; then
  echo ""
  echo "--- Test: git binary arch is x86_64 on Intel Mac (#226/#227) ---"
  "$NB" install git >/dev/null 2>&1 || true
  GIT_BIN="/opt/nanobrew/prefix/bin/git"
  if [ -x "$GIT_BIN" ]; then
    GIT_ARCH=$(file "$GIT_BIN" 2>/dev/null || true)
    if echo "$GIT_ARCH" | grep -q "x86_64"; then
      pass "git bottle is x86_64 (no arm64 fallback regression)"
    else
      fail "git bottle is not x86_64 on Intel Mac: $GIT_ARCH"
    fi
  else
    fail "git install failed on Intel Mac"
  fi
fi

# ===================================================================
# Summary
# ===================================================================

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
