#!/bin/bash
# bench_macos.sh — Compare current branch vs baseline for Homebrew bottle downloads.
#
# Usage:
#   ./bench/bench_macos.sh [package]
#
# Default package: wget  (pulls ~6 deps: libidn2, libunistring, openssl, etc.)
# Baseline commit: 5a945d9 (post-arena PR #212, pre-persistent-client+native-tar PR #215)
#
# What it measures:
#   - cold: empty blobs/ and store/, full download + extract
#   - warm: blobs/ populated, store/ cleared (disk cache + native extract only)
#
# Requires: zig in PATH, nb (current build) in PATH or ./zig-out/bin/nb
# Run from repo root.

set -e

BASELINE_COMMIT="5a945d9"
PKG="${1:-wget}"
RUNS=3
BLOBS_DIR="${NANOBREW_BLOBS_DIR:-/opt/nanobrew/cache/blobs}"
STORE_DIR="${NANOBREW_STORE_DIR:-/opt/nanobrew/store}"

die() { echo "error: $*" >&2; exit 1; }

ms() {
    # macOS date lacks %N; use Python for nanosecond timing
    python3 -c "import time; print(int(time.time()*1000))"
}

median3() {
    echo "$1 $2 $3" | tr ' ' '\n' | sort -n | awk 'NR==2'
}

# -- Setup --------------------------------------------------------------------

echo "==> Building current binary (ReleaseFast)..."
zig build -Doptimize=ReleaseFast
CURRENT_BIN="$(pwd)/zig-out/bin/nb"
[ -x "$CURRENT_BIN" ] || die "build failed: $CURRENT_BIN not found"

BASELINE_DIR="/tmp/nb-baseline-${BASELINE_COMMIT}"
if [ ! -f "$BASELINE_DIR/zig-out/bin/nb" ]; then
    echo "==> Building baseline $BASELINE_COMMIT..."
    # Use git worktree to avoid touching current tree
    if [ -d "$BASELINE_DIR" ]; then
        git worktree remove --force "$BASELINE_DIR" 2>/dev/null || rm -rf "$BASELINE_DIR"
    fi
    git worktree add "$BASELINE_DIR" "$BASELINE_COMMIT"
    (cd "$BASELINE_DIR" && zig build -Doptimize=ReleaseFast)
fi
BASELINE_BIN="$BASELINE_DIR/zig-out/bin/nb"
[ -x "$BASELINE_BIN" ] || die "baseline build failed"

echo ""
echo "  current:  $CURRENT_BIN"
echo "  baseline: $BASELINE_BIN ($BASELINE_COMMIT)"
echo "  package:  $PKG"
echo "  runs:     $RUNS per scenario"
echo ""

# -- Helpers ------------------------------------------------------------------

# Remove PKG and its deps from DB so next install does real work
nb_db_remove() {
    local bin="$1"
    # Resolve deps with the binary (remove is recursive via DB)
    "$bin" remove "$PKG" >/dev/null 2>&1 || true
    # Also forcibly wipe store + blobs so nothing is cached at fs level
    rm -rf "$BLOBS_DIR"/* "$STORE_DIR"/* 2>/dev/null || true
}

nb_clean_blobs_store() {
    rm -rf "$BLOBS_DIR"/* "$STORE_DIR"/* 2>/dev/null || true
}

nb_clean_store_only() {
    rm -rf "$STORE_DIR"/* 2>/dev/null || true
}

run_nb() {
    local bin="$1"
    local t0 t1
    t0=$(ms)
    "$bin" install "$PKG" >/dev/null 2>&1
    t1=$(ms)
    echo $(( t1 - t0 ))
}

bench_cold() {
    local bin="$1"
    local times=()
    for i in $(seq 1 $RUNS); do
        nb_db_remove "$bin"
        times+=( $(run_nb "$bin") )
    done
    median3 "${times[0]}" "${times[1]}" "${times[2]}"
}

bench_warm() {
    local bin="$1"
    # Seed blobs cache with one cold run, then remove from DB+store only
    nb_db_remove "$bin"
    "$bin" install "$PKG" >/dev/null 2>&1 || true
    local times=()
    for i in $(seq 1 $RUNS); do
        # Remove from DB and store but keep blobs (downloaded tarballs)
        "$bin" remove "$PKG" >/dev/null 2>&1 || true
        nb_clean_store_only
        times+=( $(run_nb "$bin") )
    done
    median3 "${times[0]}" "${times[1]}" "${times[2]}"
}

# -- Run ----------------------------------------------------------------------

echo "Running benchmarks (this takes a few minutes)..."
echo ""

echo "  [1/4] baseline cold..."
base_cold=$(bench_cold "$BASELINE_BIN")

echo "  [2/4] current cold..."
curr_cold=$(bench_cold "$CURRENT_BIN")

echo "  [3/4] baseline warm..."
base_warm=$(bench_warm "$BASELINE_BIN")

echo "  [4/4] current warm..."
curr_warm=$(bench_warm "$CURRENT_BIN")

# -- Report -------------------------------------------------------------------

cold_speedup=$(python3 -c "print(f'{$base_cold/$curr_cold:.2f}x')" 2>/dev/null || echo "?")
warm_speedup=$(python3 -c "print(f'{$base_warm/$curr_warm:.2f}x')" 2>/dev/null || echo "?")
cold_delta=$(python3 -c "print(f'{($base_cold-$curr_cold)/$base_cold*100:.0f}%')" 2>/dev/null || echo "?")
warm_delta=$(python3 -c "print(f'{($base_warm-$curr_warm)/$base_warm*100:.0f}%')" 2>/dev/null || echo "?")

echo ""
echo "+----------------------+------------+------------+----------------+"
printf "| %-20s | %10s | %10s | %14s |\n" "scenario" "baseline" "current" "improvement"
echo "+----------------------+------------+------------+----------------+"
printf "| %-20s | %8sms | %8sms | %7s (%5s) |\n" "cold (dl+extract)" "$base_cold" "$curr_cold" "$cold_speedup" "$cold_delta"
printf "| %-20s | %8sms | %8sms | %7s (%5s) |\n" "warm (extract only)" "$base_warm" "$curr_warm" "$warm_speedup" "$warm_delta"
echo "+----------------------+------------+------------+----------------+"
echo ""
echo "Notes:"
echo "  cold = empty blobs/ + store/ (full TLS handshake + download + extract)"
echo "  warm = blobs/ populated, store/ cleared (SHA256 check + native extract only)"
echo "  baseline = $BASELINE_COMMIT (arena allocator, one client per download, shell tar)"
echo "  current  = HEAD (persistent client per worker, pre-fetched token, native tar)"
echo ""
echo "Per-phase detail (NB_BENCH=1, current binary, cold run):"
nb_db_remove "$CURRENT_BIN"
NB_BENCH=1 "$CURRENT_BIN" install "$PKG" 2>&1 | grep '\[nb-bench\]' || true
