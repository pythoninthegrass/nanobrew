# Releasing nanobrew

## Homebrew formula and GitHub Releases

Installs via Homebrew use `Formula/nanobrew.rb`, which downloads prebuilt tarballs from **GitHub Releases**:

```text
https://github.com/justrach/nanobrew/releases/download/v<VERSION>/nb-<arch>-apple-darwin.tar.gz
```

**Rule:** The `version`, `url`, and `sha256` fields in `Formula/nanobrew.rb` must match a **published** release whose assets are already uploaded. Bumping the formula to a version that has no release (or missing assets) breaks `brew install nanobrew` with HTTP 404 (see issue #157).

### Recommended flow (automated)

1. Push an annotated tag: `git tag v0.1.xxx && git push origin v0.1.xxx`
2. The [Release workflow](.github/workflows/release.yml) builds macOS/Linux binaries, **creates the GitHub Release**, uploads assets, then opens a PR that updates `Formula/nanobrew.rb` with the correct URLs and SHA256s.
3. Merge that formula PR after CI passes.

The `update-formula` job runs **after** the release is created, so tag-driven releases keep the formula aligned.

## Beta releases

Use prerelease tags for beta builds:

```bash
git tag v0.1.193-beta.1
git push origin v0.1.193-beta.1
```

Publish the GitHub Release as a **pre-release** and do not update `Formula/nanobrew.rb` for that tag. `nb update` installs from GitHub's latest stable release endpoint, so prereleases are not selected by the self-update install path. The background update banner reads `https://nanobrew.trilok.ai/version`; keep that endpoint pointed at the latest stable version only.

If the release workflow is re-enabled, beta tags must not run the formula-update job. Tags containing a prerelease suffix such as `-beta.1`, `-rc.1`, or any other hyphenated SemVer suffix should create a GitHub prerelease and skip Homebrew formula promotion.

## Safe rollout policy

Regular users should only receive stable binaries and stable registry resolutions.

- Stable binary channel: non-prerelease GitHub Releases only. These are the only releases that `nb update`, the update banner, and `Formula/nanobrew.rb` should promote.
- Beta binary channel: prerelease GitHub Releases only. These are installed manually from the release page or by an explicit beta command in the future.
- Stable registry channel: `registry/upstream.json` on `main`. Treat this as production data because released `nb` binaries may fetch it remotely and cache it for six hours.
- Beta registry channel: a branch or alternate URL passed through `NANOBREW_UPSTREAM_REGISTRY_URL`. Use this for new resolver classes, broad top-N expansion, or records that have not passed install benchmarks.
- Local/offline channel: `NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE=1` uses only the embedded fallback, and `NANOBREW_DISABLE_UPSTREAM=1` disables upstream registry resolution entirely.

Promotion rule: a record or resolver class can move from beta to stable only after it has deterministic verification, fallback behavior, runtime `nb info` checks, cold install benchmarks, and at least one beta/prerelease soak. If a stable record causes trouble, revert the hosted registry entry first; released clients will fall back after their cache expires or immediately when users set `NANOBREW_DISABLE_UPSTREAM=1`.

### Manual formula edits

If you edit `Formula/nanobrew.rb` by hand:

- Confirm the tag exists and **all** bottle files are on the release page.
- Copy SHA256 from the `.sha256` sidecar files on the release, or from `shasum -a 256` locally.

Do **not** bump `version` in the formula to match `src/main.zig` until the release exists.

## Tap repository

There is **no separate** `homebrew-nanobrew` repository for the default tap. Users install with:

```bash
brew tap justrach/nanobrew https://github.com/justrach/nanobrew
brew install nanobrew
```

Homebrew reads `Formula/nanobrew.rb` **from this repo**. Keeping releases and the formula in sync here is sufficient unless you maintain a custom tap fork elsewhere.

## Version constants

- **`src/main.zig`** — compile-time `VERSION` string (shown in `nb help`, self-update checks).
- **`Formula/nanobrew.rb`** — must track the bottled binary users download via Homebrew; tied to GitHub Releases, not necessarily every commit on `main`.

## Verify locally

After editing the formula, run:

```bash
./scripts/verify-formula-release.sh
```

This downloads the two macOS tarballs and checks SHA256s match the formula.
