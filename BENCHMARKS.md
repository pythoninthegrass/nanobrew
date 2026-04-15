# Benchmarks

All benchmarks run on Apple Silicon (M-series), macOS, with a stable internet connection.

**Tools compared:**
- [Homebrew](https://brew.sh/) (Ruby) — the standard macOS package manager
- [Zerobrew](https://github.com/lucasgelfond/zerobrew) v0.1.0 (Rust) — a 5-20x faster Homebrew alternative
- **nanobrew** (Zig) — this project

## Results

### Single package, no dependencies (`tree`)

| | Homebrew | Zerobrew | nanobrew | Speedup vs brew |
|---|---|---|---|---|
| **Cold install** | 8.99s | 5.86s | **1.19s** | **7.6x** |
| **Warm install** | 2.25s | 0.35s | **0.19s** | **11.8x** |

### Multi-dep package (`wget` — 6 packages total)

wget depends on: libunistring, ca-certificates, gettext, openssl@3, libidn2

| | Homebrew | Zerobrew | nanobrew | Speedup vs brew |
|---|---|---|---|---|
| **Cold install** | 16.84s | failed* | **11.26s** | **1.5x** |
| **Warm install** | 2.43s | failed* | **0.58s** | **4.2x** |

*Zerobrew failed on wget with: `zerobrew prefix "/opt/zerobrew/prefix" (20 bytes) is longer than "/opt/homebrew" (13 bytes)` — a Mach-O binary patching limitation.

## Definitions

- **Cold install**: No local cache. Bottles must be downloaded from ghcr.io, extracted, and installed from scratch.
- **Warm install**: Bottles already downloaded and extracted in the content-addressable store. Only materialization (APFS clonefile) and linking required.

## Where the time goes

### Homebrew (`brew install tree`, cold)

```
Total: 8.99s
  - Ruby startup + config loading:   ~1.5s
  - API metadata fetch:              ~0.5s
  - Bottle download:                 ~1.5s
  - Extraction + pour:               ~1.0s
  - Linking + cleanup:               ~4.5s
```

Homebrew spends most of its time in Ruby overhead — loading configs, running cleanup hooks, and post-install checks.

### nanobrew (`nb install tree`, cold)

```
Total: 1.19s
  - API metadata fetch (curl):       ~0.3s
  - GHCR token + bottle download:    ~0.7s
  - Extraction (tar):                ~0.1s
  - Materialize (clonefile):         ~0.05s
  - Link + DB write:                 ~0.04s
```

nanobrew has near-zero overhead. No interpreter startup, no cleanup passes, no config loading.

### nanobrew (`nb install tree`, warm)

```
Total: 0.19s
  - API metadata fetch (curl):       ~0.15s
  - Download skip (blob cached):     ~0s
  - Extraction skip (store cached):  ~0s
  - Materialize (clonefile):         ~0.03s
  - Link + DB write:                 ~0.01s
```

Warm installs are dominated by the API fetch. The actual install is ~40ms.

## Methodology

Each benchmark was run with:

1. Full cleanup between cold runs (remove cached bottles, store entries, installed kegs)
2. For warm runs, kegs removed but caches preserved
3. `time` used for wall-clock measurement
4. Single run per data point (not averaged — these are representative, not statistical)

### Reproducing

```bash
# Cold install benchmark
brew uninstall tree 2>/dev/null
rm -rf /opt/nanobrew/store/* /opt/nanobrew/cache/blobs/*
time nb install tree

# Warm install benchmark
nb remove tree
time nb install tree

# Compare with Homebrew
brew uninstall tree 2>/dev/null
time brew install tree
```

## Download pipeline improvements (PR #212, #215)

Measured on Apple Silicon macOS, `nb install wget` (5 packages), 5 warm runs / 3 cold runs each.
Baseline: commit `5a945d9` (arena allocator, one client per download, shell `tar xzf`).
Current: persistent HTTP client per worker, pre-fetched GHCR token, native tar extraction.

| scenario | baseline (median) | current (median) | improvement |
|---|---|---|---|
| cold (download + extract) | 1188ms | 1160ms | **1.02x** |
| warm (extract only) | 1937ms | 1749ms | **1.11x** |

The warm improvement (~188ms / 5 pkgs = **~38ms per package**) comes entirely from eliminating
the `tar xzf` fork/exec per package. Cold improvement is minimal because network download time
dominates; the persistent TLS session and pre-fetched token benefit large batches most (fewer
than one reused connection per worker when packages <= worker count).

### Per-phase timing (NB_BENCH=1)

Set `NB_BENCH=1` to print per-download timings to stderr:

```
==> Downloading + installing 5 packages...
[nb-bench] dl f8f1b459...: 647ms
[nb-bench] dl bae6d6d8...: 663ms
[nb-bench] dl 03be72d2...: 690ms
[nb-bench] dl 1f984003...: 826ms
[nb-bench] dl 6f302907...: 1009ms
    [2518ms]                  <- wall clock (5 parallel downloads)
```

### Reproducing

```bash
bash bench/bench_macos.sh wget
```

## Known limitations

- **Mach-O patching** is not implemented. Bottles with hardcoded `/opt/homebrew` library paths won't work at runtime. This affects packages with dynamic library dependencies (e.g., wget, ffmpeg) but not standalone binaries (e.g., tree, ripgrep).

## Future improvements

- Larger-batch benchmark (50+ packages) to measure persistent TLS session reuse at scale
- HTTP/2 multiplexing to co-pipeline downloads over fewer connections
- Prefetch metadata for dependency-tree resolution (currently one API round-trip per package)
