# Verified Upstream Registry

The upstream registry is the curated metadata layer for direct installs from trusted release sources.

Current status: the schema, parser, and first GitHub Releases cask resolver exist. Unsupported packages and resolver misses still fall back to Homebrew-compatible metadata. Records should only be added when the upstream source has an explicit trust boundary and a deterministic verification path.

The runtime registry has three sources, in order: a local cache file, the nanobrew GitHub registry metadata URL, and the embedded fallback compiled into `nb`. `src/upstream/registry_default.json` is still loaded with Zig `@embedFile`, parsed at runtime, and used whenever no valid cache or remote metadata can be loaded. A stale cache is refreshed from GitHub when possible, but can still be used if refresh fails. A "seeded" package means its trusted upstream record has been manually added to that embedded registry snapshot.

Use `scripts/discover-github-upstreams.mjs` to find Homebrew formula/cask records whose current download metadata is already GitHub-native. See `docs/github-upstream-discovery.md` for the first-pass counts and integration order.

Runtime status: cask records backed by GitHub Releases are now tried before the Homebrew cask API. The first embedded records are `alacritty`, `alt-tab`, and `actual`. Each record carries resolved `version + URL + sha256` metadata for the supported macOS architectures, then hands the result to the existing native cask download/verify/install path. If a record does not have resolved metadata for the current platform, nanobrew can still use the GitHub latest-release API as a fallback resolver. Set `NANOBREW_DISABLE_UPSTREAM=1` to force the Homebrew metadata path while debugging.

Remote registry loading uses `/opt/nanobrew/cache/api/upstream-registry.json` by default, with a six-hour freshness window. The default remote URL is `https://raw.githubusercontent.com/justrach/nanobrew/main/registry/upstream.json`. Set `NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE=1` to use only the cache plus embedded fallback, `NANOBREW_UPSTREAM_REGISTRY_CACHE=/path/to/upstream.json` to override the cache path, or `NANOBREW_UPSTREAM_REGISTRY_URL=https://...` to override the metadata URL.

Use `scripts/build-upstream-release-db.mjs` after a record exists in `registry/upstream.json` to build a local review database of GitHub releases, assets, asset digests, and repository advisories. The default output is `registry/upstream-release-db.json`, which is ignored by git because it is generated review data, not runtime state.

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
7. Run `zig build test-upstream-registry`, `zig build test`, and `./zig-out/bin/nb info --cask <token>`.

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
