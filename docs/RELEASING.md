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
