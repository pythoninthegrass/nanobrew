# Verified Upstream Registry

The upstream registry is the curated metadata layer for direct installs from trusted release sources.

Current status: the schema, parser, first GitHub Releases resolver, and resolved vendor URL cask resolver exist. Unsupported packages and resolver misses still fall back to Homebrew-compatible metadata. Records should only be added when the upstream source has an explicit trust boundary and a deterministic verification path.

The runtime registry has three sources, in order: a local cache file, the nanobrew GitHub registry metadata URL, and the embedded fallback compiled into `nb`. `src/upstream/registry_default.json` is still loaded with Zig `@embedFile`, parsed at runtime, and used whenever no valid cache or remote metadata can be loaded. A stale cache is refreshed from GitHub when possible, but can still be used if refresh fails. A "seeded" package means its trusted upstream record has been manually added to that embedded registry snapshot.

Use `scripts/discover-github-upstreams.mjs` to find Homebrew formula/cask records whose current download metadata is already GitHub-native. See `docs/github-upstream-discovery.md` for the first-pass counts and integration order.

Runtime status: cask records backed by GitHub Releases or resolved vendor URLs are now tried before the Homebrew cask API. Formula records backed by GitHub Releases are tried before the Homebrew formula API when they declare explicit binary artifacts. The embedded cask records are `alacritty`, `alt-tab`, `actual`, `firefox`, `google-chrome`, `betterdisplay`, `bitwarden`, `bruno`, `cc-switch`, `cmux`, `dockdoor`, `hammerspoon`, `maccy`, `obsidian`, `ollama-app`, `openclaw`, `opencode-desktop`, `rectangle`, `stats`, and `utm`; the embedded formula records are `gh`, `just`, `mise`, `ripgrep`, `uv`, `actionlint`, `atuin`, `fd`, `lazygit`, `podman`, `bat`, `chezmoi`, `fastfetch`, `git-delta`, `git-lfs`, `golangci-lint`, `k9s`, `llmfit`, `ruff`, and `zoxide`. Each record carries resolved `version + URL + sha256` metadata for the supported platforms. Casks hand the result to the existing native cask download/verify/install path. Formula records use the source-archive path and only become installable when their registry record declares the binary paths to copy into the keg's `bin/`. If a GitHub release record does not have resolved metadata for the current platform, nanobrew can still use the GitHub latest-release API as a fallback resolver. Vendor URL records are resolved-only and fall back to Homebrew metadata if the current platform is not present. Set `NANOBREW_DISABLE_UPSTREAM=1` to force the Homebrew metadata path while debugging.

Remote registry loading uses `/opt/nanobrew/cache/api/upstream-registry.json` by default, with a six-hour freshness window. The default remote URL is `https://raw.githubusercontent.com/justrach/nanobrew/main/registry/upstream.json`. Set `NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE=1` to use only the cache plus embedded fallback, `NANOBREW_UPSTREAM_REGISTRY_CACHE=/path/to/upstream.json` to override the cache path, or `NANOBREW_UPSTREAM_REGISTRY_URL=https://...` to override the metadata URL.

Regular-user safety: `registry/upstream.json` on `main` is the stable registry channel because released binaries may fetch it without a binary update. Experimental resolver classes, broad top-N generated records, and unsoaked records should live behind an explicit `NANOBREW_UPSTREAM_REGISTRY_URL` beta URL until they pass verification, runtime checks, install benchmarks, and a beta-release soak. If a stable hosted record regresses, revert the hosted registry entry first; users can bypass immediately with `NANOBREW_DISABLE_UPSTREAM=1`.

Use `scripts/build-upstream-release-db.mjs` after a record exists in `registry/upstream.json` to build a local review database of GitHub releases, assets, asset digests, and repository advisories. The default output is `registry/upstream-release-db.json`, which is ignored by git because it is generated review data, not runtime state.

Use `scripts/seed-upstream-formulas.mjs` to find popular formula candidates programmatically from Homebrew's 30-day install-on-request analytics. The seeder only writes formula records when it can find a GitHub latest release, a macOS arm64 archive with a GitHub SHA256 asset digest, and an inferable binary path inside that archive. Archive inspection has download timeouts and a size cap so broad scans skip unsuitable payloads instead of hanging. It mirrors generated records into both `registry/upstream.json` and `src/upstream/registry_default.json` when run with `--write`.

```sh
GITHUB_TOKEN="$(gh auth token)" scripts/seed-upstream-formulas.mjs --limit 5 --scan 300 --write
```

Use `scripts/seed-upstream-casks.mjs` to find popular app cask candidates programmatically from Homebrew's 30-day cask install analytics. The cask seeder only writes records when it can find a GitHub release asset, a supported app artifact, a macOS arm64 download, and a GitHub SHA256 asset digest matching Homebrew's checksum. It skips artifact shapes the registry cannot represent without losing install behavior, such as app rename targets.

```sh
GITHUB_TOKEN="$(gh auth token)" scripts/seed-upstream-casks.mjs --limit 10 --scan 300 --write
```

Use `scripts/upstream-coverage-report.mjs` to measure the current verified registry against Homebrew popularity analytics. Homebrew analytics are the primary prioritization signal; GitHub release asset `download_count` is also available with `--download-counts`, but it is a lifetime counter for a release asset and not equivalent to Homebrew installs.

```sh
GITHUB_TOKEN="$(gh auth token)" scripts/upstream-coverage-report.mjs --top 100 --download-counts
```

The current seeders are intentionally conservative and do not imply that the top 100 can be fully covered by the GitHub-release registry shape alone. A broad dry run with `--include-existing --scan 100 --limit 100` reports the current ceiling for that resolver class. Reaching full top-100 coverage requires adding more source classes and artifact shapes, such as Homebrew bottle metadata for formulae, source-build formula support, binary rename support, vendor-hosted casks, pkg-only casks, font casks, tap analytics metadata, and casks whose verification policy is `no_check`.

Use `scripts/bench-upstream-install.mjs` to measure the actual install path, not only metadata lookup. For formulae, this times dependency resolution, download, verification, extraction, upstream binary install or Homebrew bottle materialization, relocation, linking, and cleanup between runs. The script refuses packages that were already installed before the run, so it does not silently remove a user's existing packages. Use `--cold` to purge package-specific blob/store/tmp cache entries before each timed install. Use `--upstream-registry-url` and `--upstream-registry-cache` to test an opt-in beta registry without touching the stable registry cache.

```sh
scripts/bench-upstream-install.mjs --tokens actionlint,fd --iterations 1 --cold
scripts/bench-upstream-install.mjs --tokens actionlint,fd --iterations 1 \
  --upstream-registry-url http://127.0.0.1:8765/registry/upstream.json \
  --upstream-registry-cache /opt/nanobrew/cache/api/upstream-registry-beta-local.json
```

Use `scripts/bench-upstream-resolution.mjs` to measure metadata lookup speed for seeded records through `nb info`. It compares verified upstream metadata against the Homebrew fallback path and does not download or install payloads.

```sh
zig build
scripts/bench-upstream-resolution.mjs --tokens gh,uv,bat,obsidian,rectangle --iterations 5
```

Generator changes can be tested without GitHub:

```sh
scripts/build-upstream-release-db.mjs --self-test
```

The self-test reads `tests/fixtures/upstream-release-db` and fails if the generator attempts a network fetch. To inspect fixture-backed output directly, run:

```sh
scripts/build-upstream-release-db.mjs \
  --registry tests/fixtures/upstream-release-db/registry.json \
  --fixture-dir tests/fixtures/upstream-release-db \
  --stdout
```

Fixture files are named `<owner>__<repo>.releases.json` and `<owner>__<repo>.advisories.json`. They should contain raw GitHub API-shaped arrays so the same normalization path is exercised as a live refresh.

Required record fields:

- `token`: nanobrew package or cask token.
- `kind`: `formula` or `cask`.
- `upstream`: source descriptor.
- `verification`: checksum, signature, or attestation policy.

For `github_release` upstreams, `repo` is the `owner/name` allowlist. For `vendor_url` upstreams, `allow_domains` must list the allowed download domains.

Formula records must define at least one `assets` entry keyed by platform, such as `macos-arm64`, `macos-x86_64`, `linux-x86_64`, or `linux-aarch64`. Cask records must define at least one artifact declaration.

For GitHub release casks, `assets` is also required. Asset patterns support `{tag}`, `{version}`, and `*`. `{version}` is the release tag with a leading `v` stripped when the tag is version-like.

Hot-path records should also include `resolved` metadata:

```json
{
  "resolved": {
    "tag": "v10.12.0",
    "version": "10.12.0",
    "assets": {
      "macos-arm64": {
        "url": "https://github.com/lwouis/alt-tab-macos/releases/download/v10.12.0/AltTab-10.12.0.zip",
        "sha256": "e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14"
      }
    },
    "security_warnings": [
      {
        "ghsa_id": "GHSA-xxxx-yyyy-zzzz",
        "cve_id": "CVE-2026-0001",
        "severity": "high",
        "summary": "Example advisory affecting older releases",
        "url": "https://github.com/owner/project/security/advisories/GHSA-xxxx-yyyy-zzzz",
        "affected_versions": "< 10.12.1",
        "patched_versions": ">= 10.12.1"
      }
    ]
  }
}
```

This mirrors Homebrew's split: metadata lookup yields URL and checksum, while artifact download and verification happen later in the installer.

## Scaling The Update Path

The scalable shape is a two-layer registry:

1. Curated source records: token, upstream repo or domain allowlist, platform asset rules, artifact install rules, and verification policy.
2. Generated resolved snapshot: release tag, version, per-platform URL/SHA256, and any advisory warnings that apply to that resolved version.

The current `registry/upstream.json` keeps both layers together while the feature is small. As the registry grows, split it into a hand-reviewed source file and a generated lock snapshot. The `nb` runtime should keep using the generated embedded snapshot, so `nb info --cask` and `nb install --cask` do not need Homebrew metadata or GitHub metadata calls for seeded records.

A refresh job should:

1. Read curated source records.
2. Fetch GitHub release metadata for each allowlisted repo, using conditional requests and a `GITHUB_TOKEN` for rate limits.
3. Render each platform asset pattern against the release tag/version.
4. Require a GitHub release asset digest or an accepted checksum sidecar before writing the resolved asset.
5. Fetch GitHub repository security advisories for the same repo.
6. Normalize applicable advisories into `resolved.security_warnings`.
7. Emit a deterministic JSON snapshot and fail the refresh if a previously seeded platform loses a valid asset or checksum.

GitHub release objects expose assets with `browser_download_url` and `digest` fields. GitHub security advisories are not embedded inside release objects; repository advisories come from the repository security advisories API. Nanobrew should join those data sources during refresh and inline the normalized warning data into the generated snapshot.

`resolved.security_warnings` is advisory display metadata. Runtime install behavior should remain checksum-driven: warnings are printed, but verification and download safety still come from the resolved URL/SHA256 policy. Advisory filtering should happen in the refresh job so the hot path does not need a semver/range engine.

For now, promotion can stay manual:

1. Add or edit a source record in `registry/upstream.json` with the trusted repo, platform asset patterns, artifacts, and verification policy.
2. Run `scripts/build-upstream-release-db.mjs --token <token> --release-limit 5`. Omit `--fixture-dir` for real promotion data.
3. Inspect `registry/upstream-release-db.json`, especially `latest_candidate`, matched asset names, SHA256 digests, `latest_candidate.missing`, and `advisories`.
4. Copy `latest_candidate.manual_resolved_snippet` into the record's `resolved` field only when `latest_candidate.status` is `resolved` and the assets and digests are correct.
5. Manually curate any applicable advisory entries into `resolved.security_warnings`.
6. Mirror the promoted record into `src/upstream/registry_default.json` until the source/lock split is implemented.
7. Run `zig build test-upstream-registry`, `zig build test-upstream-github`, `zig build test`, and `./zig-out/bin/nb info --cask <token>`.

For broad crawls, set `GITHUB_TOKEN` first. Without it, GitHub's unauthenticated API limit can produce `rate_limited` release or advisory statuses in the generated DB.

Example:

```json
{
  "schema_version": 1,
  "records": [
    {
      "token": "example-tool",
      "kind": "formula",
      "upstream": {
        "type": "github_release",
        "repo": "owner/example-tool",
        "verified": true
      },
      "assets": {
        "macos-arm64": {
          "pattern": "example-tool-{version}-aarch64-apple-darwin.tar.gz",
          "strip_components": 1
        }
      },
      "verification": {
        "sha256": "asset_digest",
        "signature": "optional",
        "attestation": "optional"
      }
    }
  ]
}
```
