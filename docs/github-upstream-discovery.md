# GitHub-Native Upstream Discovery

The first upstream-registry integration should start with Homebrew metadata that already points at GitHub-hosted upstream downloads. This gives nanobrew a practical seed set without treating every GitHub homepage as installable metadata.

Use:

```sh
scripts/discover-github-upstreams.mjs --limit 20
```

The script reads Homebrew's formula and cask API indexes, extracts `github.com/<owner>/<repo>` download URLs, and classifies them as:

- `github_release_asset`: `https://github.com/<owner>/<repo>/releases/download/...`
- `github_archive_source`: `https://github.com/<owner>/<repo>/archive/...`

Do not treat Homebrew bottle URLs in `ghcr.io/homebrew/...` as verified upstream metadata. Those are Homebrew-produced bottles, not upstream project releases.

As of a scan on 2026-04-24 from `https://formulae.brew.sh/api/formula.json` and `https://formulae.brew.sh/api/cask.json`:

- Formula records: 8,317 total.
- Formula stable source URLs on GitHub: 5,039.
- Formula GitHub release asset sources: 724.
- Formula GitHub archive sources: 4,081.
- Formula GitHub repository clone sources: 232.
- Other Formula GitHub source URLs: 2.
- Formula GitHub source URLs with SHA256: 4,807.
- Cask records: 7,621 total.
- Cask GitHub release asset URLs: 2,077.
- Cask GitHub release URLs with SHA256: 2,063.
- Cask GitHub release URLs with `no_check`: 14.
- Cask GitHub release URLs with an app/pkg/binary artifact: 1,671.

Recommended integration order:

1. Casks with GitHub release URLs, SHA256, and a single app/pkg/binary artifact. These map most directly into nanobrew's existing cask installer. This is now the active first path for the embedded `alacritty`, `alt-tab`, and `actual` records.
2. Formulae with GitHub release URLs and SHA256. These mostly describe source archives today, so use them first as trusted repo/tag/checksum allowlist records and inspect release assets before treating them as binary direct installs.
3. Formulae with GitHub archive URLs and SHA256. These are useful for a source-build track, but they do not preserve nanobrew's fast bottle-style install path by themselves.

Promotion rule: a discovered candidate is not verified just because Homebrew points at GitHub. A registry record still needs an explicit repo allowlist, asset matching rule, OS/arch support, and checksum/signature/attestation policy.

After adding a candidate to `registry/upstream.json`, use `scripts/build-upstream-release-db.mjs` to review the release assets, GitHub asset digests, and repository advisories before copying resolved metadata into the registry. Generator changes should also pass the offline fixture test:

```sh
scripts/build-upstream-release-db.mjs --self-test
```
