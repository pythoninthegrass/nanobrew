# Changelog

All notable changes to nanobrew are documented here.

## Unreleased

## [0.1.192] - 2026-04-21

### Fixed
- **Cask DMG installs failed with `error.MountFailed` / `error.ExtractFailed` after download** — the cask installer used Zig's static `std.Io.Threaded.global_single_threaded.io()` for `hdiutil`, `cp`, `unzip`, `tar`, checksum reads, and cask downloads. On Zig 0.16 that global IO is backed by a failing allocator, so `std.process.run` could fail before spawning `hdiutil` and surface as `error.MountFailed`. Cask install/remove now receive the initialized process IO from `main`, and cask downloads use the same IO-backed HTTP client. Verified with Raycast, Google Chrome, and Firefox casks. (#242)

## [0.1.191] - 2026-04-20

### Added
- **macOS release notarization** — release tarballs for `darwin-arm64` and `darwin-x86_64` are now signed with a Developer ID Application certificate under the hardened runtime and notarized by Apple. Gatekeeper fetches the notarization ticket online on first run, so downloads via browser no longer prompt as "unidentified developer". Closes #118 for macOS consumers (Sigstore/cosign remains a separate option for cross-platform provenance). (#118, #228)
- **`nb where <pattern>`** — new diagnostic subcommand that aggregates three views for a given pattern: installed kegs/casks/debs that match, files in `$PREFIX/{bin,lib,opt}` that match, and Homebrew index hits. Replaces the common `nb list | grep X; ls $PREFIX/lib/ | grep X; nb search X` pipeline. (#228)
- **`scripts/notarize-macos.sh`** — local notarization helper that uses the `codedb-notary` keychain profile. Used for one-off releases and for reproducing CI behavior locally when CI secrets are unavailable. (#228)
- **`nb info <formula>` — rich output** — formula info now prints description, homepage, license, bottle/source URL + sha256, dependencies, build dependencies, and caveats (mirroring `nb info --cask`). Bottled formulae are tagged `(bottled)`; source-only formulae tag the URL as `(source)`. `Formula` struct gains `homepage` and `license` fields parsed from the Homebrew API. (#230, #231)

### Fixed
- **Python (and other framework-bundled formulae) crashed on `dlopen` with `Invalid Page` / `Code Signature Invalid`** — the Mach-O relocator only re-signed binaries it rewrote with `install_name_tool`, leaving every other Mach-O with whatever (often broken) signature the upstream bottle shipped. `install_name_tool` removes signatures unconditionally on invocation, and `*.framework` bundles carry a sealed-resource hash that invalidates on any nested file change. Additionally, the batch `codesign` call had a 4 KiB stdout capture limit that SIGPIPEd the subprocess mid-batch on packages with many Mach-O files (e.g. `python@3.14`'s 76 `.so` plugins), leaving most files unsigned. Now every Mach-O file in a keg is ad-hoc re-signed after relocation, and every `*.framework` bundle gets a final `codesign --deep` pass after `replaceKegPlaceholders` finishes all text-file rewrites. Fresh cold install of `python@3.14` went from **60/76 broken `.so`** + invalid framework + SIGKILL on `import sqlite3` to **0/76 broken** + valid framework + all imports succeed. (#239)
- **`nb outdated` and `nb upgrade` leaked heap memory every run** — `getOutdatedPackages` duped three per-item strings (`name`, `old_ver`, `new_ver`) without ever freeing them, and the chained `alloc.dupe … catch continue` construction could leak earlier allocations when a later dupe or the final `result.append` failed. `Outdated` struct gains a `deinit` method; both callers now free each item before freeing the list; partial-allocation failure paths cascade-free already-successful dupes. (#234, #236)
- **`nb info <alias>` leaked the parsed `Formula` on every invocation** — `runInfo` captured the `fetchFormula` result but never called `deinit`, so every field duped by `parseFormulaJson` (`bottle_url`, `bottle_sha256`, `dependencies`, `caveats`, …) leaked on exit. `defer f.deinit(alloc)` added immediately after the fetch; `nb info python` went from 22 DebugAllocator leaks to 0. New regression tests cover the alias parse + deinit round-trip under the leak-detecting `testing.allocator`. (#235, #237)

### Performance
- **`nb leaves` 10 s → under 1 s** on a typical developer install with ~100 packages. The command was issuing sequential `fetchFormula` calls per installed keg with no shared HTTP client, plus doing O(n³) membership scans via nested `for (kegs) |other|` loops. Now uses a bounded work-stealing thread pool (`@min(kegs.len, 8)` workers, each owning a persistent `std.http.Client`) for parallel metadata fetch, and a `StringHashMap(Keg)` for O(1) membership lookups. Output order preserved. (#232, #238)
- **Streaming JSON parse for search + alias lookup** — `nb search` and formula alias resolution use `std.json.Scanner` with `skipValue()` on ignored keys instead of materializing the full 29.5 MB `formula.json` / 14.2 MB `cask.json` into a `std.json.Value` tree. `nb search curl` drops from 190 ms to 106 ms (1.80×); `nb info python` drops from 168 ms to 100 ms (1.68×). No behavior change. (#229)
- **Dependency resolver reuses one HTTP client per worker thread** — the BFS parallel branch in `DepResolver` previously spawned one thread per frontier item, each creating a throwaway `std.http.Client`. Now runs a bounded work-stealing pool (`@min(batch_size, 8)` threads) where each worker keeps a persistent `std.http.Client` and pulls items via an atomic index. Cold `nb install graphviz` (15 deps): resolver phase drops from ~3123 ms to ~1766 ms (~43% faster). Improvement scales with frontier size. (#233, #240)

### Changed
- **Dependency resolver wording** — release copy now says `O(1) resolver queue` instead of implying whole-graph dependency resolution is constant time.

## [0.1.082] - 2026-04-01

### Fixed
- **macOS self-update downloads** — `nb update` now requests the actual macOS release asset names (`nb-<arch>-apple-darwin.tar.gz`) instead of the non-existent `...-darwin.tar.gz` variant. This fixes checksum-download failures on released macOS builds. (#99)

### Changed
- Release notes and landing-page version metadata were rolled forward for the self-update patch release.

## [0.1.081] - 2026-04-01

### Fixed
- **Installed-state drift** — `nb install <formula>` now reconciles already-present kegs back into `state.json`, including the fully-up-to-date path where nothing new is installed. This fixes cases where a package existed in `Cellar` but `nb list` / `nb remove` still treated it as missing. (#97)

## [0.1.080] - 2026-04-01

### Fixed
- **Tap cask installs from third-party repos** — `nb install --cask user/tap/cask` now resolves and parses casks directly from tap repositories. (#92)
- **Tap formulas stored at repo root** — third-party taps that place formula `.rb` files at the repository root now work in addition to `Formula/` layouts. (#94)
- **Linux ELF interpreter relocation** — placeholder interpreters like `@@HOMEBREW_PREFIX@@/lib/ld.so` now resolve to the real path before falling back to architecture-based system linker detection. (#89)
- **Homebrew formula checksum drift** — release formula checksums were corrected to match the live `v0.1.079` release assets. (#93)
- **macOS script package installs** — runtime dependencies from `uses_from_macos` are now resolved on macOS, fixing Python-backed installs like `awscli` in smoke tests.
- **Test runner coverage** — `zig build test` now completes and exercises the full root test set instead of silently missing API coverage.

### Changed
- Release branch now carries the current `codedb.snapshot` alongside the integrated issue-fix set.
- Smoke integration checks now print actionable diagnostics when a script-package install fails on CI.

## [0.1.076] - 2026-03-27

### Fixed
- **Python framework dylib crash** — Mach-O relocator now resolves symlinks in `Python.framework/`, fixing `_Py_Initialize symbol not found` for all Python-dependent packages (gyb, aws, pip3, etc.). (#65)
- **Third-party tap installs** — `nb install mongodb/brew/mongodb-community` now works: added `Hardware::CPU.intel?`/`else`/`end` parsing, filename version extraction (`-8.2.6.tgz`), and `prefix.install Dir["*"]` semantics for pre-built packages. (#68)
- **`--casks` silently ignored** — `--casks` (plural, Homebrew convention) now accepted as alias for `--cask`. Unknown flags error instead of being silently dropped. (#71)
- **`nb update` failed** — v0.1.075 release was missing build artifacts; now uploaded with SHA256 checksums. (#66)
- **Tap formula silent success** — `nb install user/tap/formula` now errors clearly when formula not found, instead of "Already installed (0 packages)". (#68)

### Added
- **`nb reinstall <pkg>`** — removes then reinstalls a package. (#73)
- **`NANOBREW_BOTTLE_DOMAIN`** / **`NANOBREW_API_DOMAIN`** env vars — override bottle and API mirrors for users behind proxies or in regions with limited GitHub access. Also supports `HOMEBREW_BOTTLE_DOMAIN` / `HOMEBREW_API_DOMAIN`. (#74)
- **Linux migrate path** — `nb migrate` now searches `/home/linuxbrew/.linuxbrew/` on Linux. (#72)
- **`:recommended` / `:optional` deps skipped** — tap formula parser no longer treats recommended dependencies as required.

## [0.1.075] - 2026-03-26

### Fixed
- **`nb install r` broken** — placeholder walker skipped symlinked scripts (e.g. `bin/r` → `bin/R`), leaving `@@HOMEBREW_CELLAR@@` unreplaced. Walker now resolves and processes symlink targets. (#62)
- **Cask install silent failure** — `nb install --cask firefox` reported success but left empty directories. Installer now validates the `.app` exists in the mounted DMG before copying and returns `error.ArtifactFailed` instead of silently continuing. (#60)
- **Placeholder early-exit bug** — probe check used fixed `512` instead of actual bytes read, risking skipped files on short reads.

## [0.1.067] - 2026-02-16

### Added
- **`nb nuke`** — completely uninstall nanobrew and all installed packages. Removes `/opt/nanobrew` and `~/.local/bin/nb`. Requires typing `yes` to confirm (or `--yes` to skip). Also available as `nb uninstall-self`.
- **Tap-aware `nb remove`** — `nb remove steipete/tap/sag` now works (resolves the tap ref to the short package name automatically).

## [0.1.065] - 2026-02-16

### Added
- **Third-party tap support** — `nb install user/tap/formula` now works. nanobrew is the only fast Homebrew client that supports third-party taps. Example: `nb install steipete/tap/sag` installs in ~2s.
- **Ruby formula parser** (`src/api/tap.zig`) — line-by-line parser for `.rb` formula files. Extracts version, url, sha256, dependencies, bottle blocks, and handles `#{version}` interpolation and `on_macos`/`on_linux` platform conditionals.
- **Tap formula fetching** — fetches formulas directly from `raw.githubusercontent.com/<user>/homebrew-<tap>/HEAD/Formula/<name>.rb`. Falls back to `Formula/<letter>/<name>.rb` for sharded repos.
- **Pre-built binary detection** — when a tap formula has no build system (common for pre-built binary taps), nanobrew scans the extracted tarball for executables and copies them to the keg `bin/` directory.
- **Native HTTP everywhere** — replaced all remaining curl subprocess calls with Zig's native `std.http.Client`. Zero external dependencies for network operations. Shared HTTP client in dependency resolver for TLS connection reuse.

### Changed
- Dependency resolver now shares a single HTTP client across all API fetches for TLS connection reuse, reducing resolve time for multi-dep packages.
- `fetchFormulaWithClient` routes tap refs (names with 2 slashes) to the Ruby formula pipeline automatically — no special flags needed.

## [0.1.06] - 2026-02-16

### Added
- **Linux support** — nanobrew now runs natively on Linux (x86_64 and aarch64). Same 1.2 MB static binary.
- **`nb install --deb <pkg>`** — Install packages from Ubuntu repositories. Native `.deb` extraction without `dpkg`, `ar`, or `zstd` binaries — only needs `tar`. 2.8x faster than `apt-get install` in Docker containers.
- **Platform abstraction layer** (`src/platform/`) — centralized path constants, comptime platform detection, COW copy abstraction (`clonefile` on macOS, `cp --reflink=auto` on Linux).
- **ELF relocator** (`src/elf/relocate.zig`) — detects ELF binaries, parses headers, uses `patchelf` for RPATH/interpreter fixups, replaces `@@HOMEBREW_PREFIX@@` placeholders in `.pc`/`.cmake`/`.la` config files.
- **Deb package index parser** (`src/deb/index.zig`) — native RFC 822-style parser for Ubuntu `Packages.gz` indices.
- **Deb dependency resolver** (`src/deb/resolver.zig`) — BFS + topological sort with support for alternatives and virtual packages.
- **Native ar + decompression** (`src/deb/extract.zig`) — parses ar archive headers, decompresses `data.tar` with Zig's native zstd and gzip decompressors.
- **Native HTTP for deb downloads** — `std.http.Client` with connection reuse across all package downloads. Streaming SHA256 verification in a single pass.
- **Content-addressable deb cache** — downloaded `.deb` files cached by SHA256 hash. Warm installs skip download entirely.
- **systemd service management** (`src/services/systemd.zig`) — discovers `.service` files in Cellar, wraps `systemctl start/stop/restart`.
- **Comptime bottle tags** for Linux — `x86_64_linux` and `aarch64_linux` bottle selection in `formula.zig`.
- **Cross-compilation targets** — `zig build linux` and `zig build linux-arm` in `build.zig`.
- **Deb parity test** (`tests/deb-parity.sh`) — Docker-based integration test verifying byte-identical extraction vs `dpkg-deb` across 5 test categories.
- **Linux CI** — `build-linux` job with deb parity test, cross-compile job for both architectures.
- **Deb benchmark workflow** — automated `nb --deb` vs `apt-get` benchmarks in CI, auto-updates README.

### Changed
- `install.sh` detects OS and uses `.bashrc` on Linux.
- Services dispatcher now routes to launchd (macOS) or systemd (Linux) at comptime.
- Cask commands show a clear error on Linux (casks are macOS-only).
- Mach-O relocator refactored to share placeholder logic with ELF relocator.
- `tar` extraction uses `--skip-old-files` for safe overlay in Docker containers.

### Fixed
- **zstd decompression for large packages** — buffer sized at `default_window_len + block_size_max` (8MB + 128KB). Previously failed on packages like libc6.
- **HTTP connection reuse failures** — retry with fresh client after ~20 sequential downloads.

## [0.1.052] - 2026-02-16

### Added
- **Update checker** — `nb` now checks for new versions once per day (via Cloudflare edge cache) and shows a colored banner when an update is available.
- **Version display** — `nb help` header shows the current version.
- **Cloudflare `/version` endpoint** — Worker returns latest release version with 5-min CF cache, so the Zig client never hits GitHub directly.
- **GitHub Actions benchmark workflow** — Weekly CI job benchmarks `nb install` vs `brew install` for tree, wget, ffmpeg and auto-updates the README table.

### Fixed
- Release workflow no longer generates duplicate `license` lines in Formula.

## [0.1.05] - 2026-02-16

### Added
- **`nb doctor`** — Health check that scans for broken symlinks, missing Cellar dirs, orphaned store entries, and permission issues. Alias: `nb dr`.
- **`nb cleanup`** — Removes expired API/token caches, temp files, and orphaned blobs/store entries. Supports `--dry-run` to preview and `--all` to include history-referenced entries.
- **`nb outdated`** — Lists packages with newer versions available. Shows `[pinned]` tag for pinned packages.
- **`nb pin <pkg>` / `nb unpin <pkg>`** — Pin a package to prevent `nb upgrade` from touching it.
- **`nb rollback <pkg>`** — Revert a package to its previous version using the install history. Alias: `nb rb`.
- **`nb bundle dump`** — Export all installed kegs and casks to a Brewfile-compatible `Nanobrew` file.
- **`nb bundle install [file]`** — Install everything listed in a bundle file. Defaults to `./Nanobrew`.
- **`nb deps [--tree] <formula>`** — Show dependencies. `--tree` renders an ASCII dependency tree with box-drawing characters.
- **`nb services [list|start|stop|restart] [name]`** — Discover and control launchctl services from installed packages. Scans Cellar for `homebrew.mxcl.*.plist` files.
- **`nb completions [zsh|bash|fish]`** — Print shell completion scripts to stdout.
- **Pinned packages** — `pinned` field added to database. Pinned packages are skipped by `nb upgrade` and tagged `[pinned]` in `nb list` and `nb outdated`.
- **Install history** — Database now tracks previous versions of each package. Used by `nb rollback` and protected by `nb cleanup`.

### Changed
- `nb list` now shows `[pinned]` tag for pinned packages.
- `nb upgrade` skips pinned packages (use `nb unpin` first).
- `nb cleanup` protects store entries referenced by install history.
- Extracted `getOutdatedPackages` helper used by both `nb upgrade` and `nb outdated`.
- Database schema extended with `pinned`, `installed_at`, and `history` fields (backward-compatible with older `state.json` files).

## [0.1.03] - 2026-02-16

### Added
- **Source builds** — Formulae without pre-built bottles are now compiled from source automatically. Supports cmake, autotools, meson, and make build systems. Source tarballs are SHA256-verified before building.
- **`nb search <query>`** — Search across all Homebrew formulae and casks. Case-insensitive substring matching on name and description. Results show version, `[installed]` status, and `(cask)` tag. Alias: `nb s`.
- **`nb upgrade`** — Upgrade outdated packages. Compares installed versions against the Homebrew API and reinstalls any that are behind. Works with both kegs and casks.
  - `nb upgrade` — upgrade all outdated packages
  - `nb upgrade <name>` — upgrade a specific package
  - `nb upgrade --cask` — upgrade all casks
  - `nb upgrade --cask <name>` — upgrade a specific cask
- **Post-install scripts** — Common Ruby post-install patterns (`system`, `mkdir_p`, `ln_sf`) are parsed from Homebrew formula source and executed after install.
- **Caveat display** — Formulae with caveats (e.g. postgresql, openssh) now display their instructions after installation with an `==> Caveats` header.

### Changed
- Formula parser now reads `urls.stable.url`, `urls.stable.checksum`, `build_dependencies`, `caveats`, and `post_install_defined` from the Homebrew API.
- Install pipeline gracefully falls back to source build when no arm64 bottle exists, instead of failing with `NoArm64Bottle`.
- Search results are cached for 1 hour to avoid repeated large API fetches.

## [0.1.02] - 2025-06-15

### Added
- **Cask support** — `nb install --cask <app>` installs macOS applications from .dmg, .zip, .pkg, and .tar.gz bundles. `nb remove --cask <app>` uninstalls them.
- Cask tracking in database (apps, binaries, version).
- `nb list` now shows installed casks alongside kegs.

## [0.1.01] - 2025-06-14

### Added
- `nb update` / `nb self-update` — Self-update nanobrew to the latest release.
- Error logging throughout the install pipeline.
- Unit tests for all pure functions.

## [0.1.00] - 2025-06-13

### Added
- Initial release.
- BFS parallel dependency resolution with topological sort.
- Parallel bottle download with streaming SHA256 verification.
- Content-addressable store with APFS clonefile materialization.
- Native Mach-O relocation (no otool subprocess).
- Batched codesign per keg.
- Symlink management for bin/ and opt/.
- JSON-based install state database.
- Commands: `init`, `install`, `remove`, `list`, `info`, `help`.
- Warm installs in under 4ms.
