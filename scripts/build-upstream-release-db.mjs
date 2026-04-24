#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_REGISTRY = "registry/upstream.json";
const DEFAULT_OUT = "registry/upstream-release-db.json";
const DEFAULT_SELF_TEST_FIXTURE_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../tests/fixtures/upstream-release-db",
);
const GITHUB_API = "https://api.github.com";
const FIXTURE_RATE = {
  limit: "fixture",
  remaining: "fixture",
  reset: "",
};

function parseArgs(argv) {
  const opts = {
    registry: DEFAULT_REGISTRY,
    out: DEFAULT_OUT,
    releaseLimit: 10,
    tokens: [],
    includePrerelease: false,
    noAdvisories: false,
    stdout: false,
    fixtureDir: null,
    selfTest: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--registry") {
      opts.registry = argv[++i] ?? "";
    } else if (arg.startsWith("--registry=")) {
      opts.registry = arg.slice("--registry=".length);
    } else if (arg === "--out") {
      opts.out = argv[++i] ?? "";
    } else if (arg.startsWith("--out=")) {
      opts.out = arg.slice("--out=".length);
    } else if (arg === "--token") {
      opts.tokens.push(...splitTokens(argv[++i] ?? ""));
    } else if (arg.startsWith("--token=")) {
      opts.tokens.push(...splitTokens(arg.slice("--token=".length)));
    } else if (arg === "--release-limit") {
      opts.releaseLimit = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--release-limit=")) {
      opts.releaseLimit = Number.parseInt(arg.slice("--release-limit=".length), 10);
    } else if (arg === "--include-prerelease") {
      opts.includePrerelease = true;
    } else if (arg === "--no-advisories") {
      opts.noAdvisories = true;
    } else if (arg === "--stdout") {
      opts.stdout = true;
    } else if (arg === "--fixture-dir") {
      opts.fixtureDir = argv[++i] ?? "";
    } else if (arg.startsWith("--fixture-dir=")) {
      opts.fixtureDir = arg.slice("--fixture-dir=".length);
    } else if (arg === "--self-test") {
      opts.selfTest = true;
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(1);
    }
  }

  if (!opts.registry) die("--registry must not be empty");
  if (!opts.out && !opts.stdout) die("--out must not be empty unless --stdout is set");
  if (opts.fixtureDir === "") die("--fixture-dir must not be empty");
  if (!Number.isInteger(opts.releaseLimit) || opts.releaseLimit < 1 || opts.releaseLimit > 100) {
    die("--release-limit must be an integer from 1 to 100");
  }
  opts.tokens = [...new Set(opts.tokens)];
  return opts;
}

function splitTokens(value) {
  return value.split(",").map((token) => token.trim()).filter(Boolean);
}

function usage(code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`Usage: scripts/build-upstream-release-db.mjs [options]

Build a local review database for curated GitHub Releases upstream records.

Options:
  --registry PATH         Curated registry to read (default: ${DEFAULT_REGISTRY})
  --out PATH              Generated DB path (default: ${DEFAULT_OUT})
  --token NAME[,NAME]     Limit refresh to one or more registry tokens
  --release-limit N       Releases to keep per repo, max 100 (default: 10)
  --include-prerelease    Include prereleases when selecting candidates
  --no-advisories         Skip repository security advisory fetches
  --stdout                Print generated JSON instead of writing --out
  --fixture-dir PATH      Read GitHub API fixtures from PATH instead of network
  --self-test             Run the built-in offline fixture test
  -h, --help              Show this help

Set GITHUB_TOKEN to raise GitHub API limits.
Fixture files are named <owner>__<repo>.releases.json and
<owner>__<repo>.advisories.json.
`);
  process.exit(code);
}

function die(message) {
  console.error(message);
  process.exit(1);
}

async function readRegistry(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

function selectedRecords(registry, opts) {
  const wanted = new Set(opts.tokens);
  return (registry.records ?? []).filter((record) => {
    if (record?.upstream?.type !== "github_release") return false;
    if (wanted.size > 0 && !wanted.has(record.token)) return false;
    return true;
  });
}

function githubHeaders() {
  const headers = {
    "accept": "application/vnd.github+json",
    "user-agent": "nanobrew-upstream-release-db",
    "x-github-api-version": "2022-11-28",
  };
  if (process.env.GITHUB_TOKEN) {
    headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }
  return headers;
}

async function fetchJson(url) {
  const response = await fetch(url, { headers: githubHeaders() });
  const rate = {
    limit: response.headers.get("x-ratelimit-limit") ?? "",
    remaining: response.headers.get("x-ratelimit-remaining") ?? "",
    reset: response.headers.get("x-ratelimit-reset") ?? "",
  };
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    return {
      ok: false,
      status: response.status,
      statusText: response.statusText,
      rate,
      error: text.slice(0, 500),
    };
  }
  return {
    ok: true,
    status: response.status,
    rate,
    data: await response.json(),
  };
}

async function fetchRepoReleases(repo, opts) {
  const url = `${GITHUB_API}/repos/${repo}/releases?per_page=${opts.releaseLimit}`;
  const response = opts.fixtureDir
    ? await readRepoFixture(repo, "releases", opts.fixtureDir)
    : await fetchJson(url);
  if (!response.ok) {
    return {
      status: githubFailureStatus(response),
      http_status: response.status,
      error: response.error,
      rate: response.rate,
      releases: [],
    };
  }

  const releases = response.data
    .filter((release) => !release.draft)
    .filter((release) => opts.includePrerelease || !release.prerelease)
    .slice(0, opts.releaseLimit)
    .map(normalizeRelease);

  return {
    status: "ok",
    http_status: response.status,
    rate: response.rate,
    releases,
  };
}

async function fetchRepoAdvisories(repo, opts) {
  if (opts.noAdvisories) {
    return {
      status: "skipped",
      http_status: 0,
      advisories: [],
    };
  }

  const url = `${GITHUB_API}/repos/${repo}/security-advisories?state=published&per_page=100`;
  const response = opts.fixtureDir
    ? await readRepoFixture(repo, "advisories", opts.fixtureDir)
    : await fetchJson(url);
  if (!response.ok) {
    const status = githubFailureStatus(response);
    return {
      status: status === "rate_limited" ? status : response.status === 404 || response.status === 403 ? "unavailable" : status,
      http_status: response.status,
      error: response.error,
      rate: response.rate,
      advisories: [],
    };
  }

  return {
    status: "ok",
    http_status: response.status,
    rate: response.rate,
    advisories: response.data.map(normalizeAdvisory),
  };
}

async function readRepoFixture(repo, kind, fixtureDir) {
  const path = join(fixtureDir, `${fixtureRepoName(repo)}.${kind}.json`);
  const data = JSON.parse(await readFile(path, "utf8"));
  return {
    ok: true,
    status: 200,
    rate: FIXTURE_RATE,
    data,
  };
}

function fixtureRepoName(repo) {
  return repo.replaceAll("/", "__");
}

function githubFailureStatus(response) {
  if (
    response.status === 403 && rateLimitExhausted(response)
  ) {
    return "rate_limited";
  }
  return "fetch_failed";
}

function rateLimitExhausted(response) {
  return response.rate?.remaining === "0" || /rate limit/i.test(response.error ?? "");
}

function normalizeRelease(release) {
  return {
    id: release.id ?? null,
    tag: release.tag_name ?? "",
    name: release.name ?? "",
    html_url: release.html_url ?? "",
    target_commitish: release.target_commitish ?? "",
    draft: Boolean(release.draft),
    prerelease: Boolean(release.prerelease),
    immutable: Boolean(release.immutable),
    created_at: release.created_at ?? "",
    published_at: release.published_at ?? "",
    assets: Array.isArray(release.assets) ? release.assets.map(normalizeAsset) : [],
  };
}

function normalizeAsset(asset) {
  return {
    id: asset.id ?? null,
    name: asset.name ?? "",
    browser_download_url: asset.browser_download_url ?? "",
    digest: asset.digest ?? "",
    content_type: asset.content_type ?? "",
    state: asset.state ?? "",
    size: Number.isFinite(asset.size) ? asset.size : 0,
    download_count: Number.isFinite(asset.download_count) ? asset.download_count : 0,
    created_at: asset.created_at ?? "",
    updated_at: asset.updated_at ?? "",
  };
}

function normalizeAdvisory(advisory) {
  const identifiers = Array.isArray(advisory.identifiers) ? advisory.identifiers : [];
  const vulnerabilities = Array.isArray(advisory.vulnerabilities) ? advisory.vulnerabilities : [];
  const ghsaId = advisory.ghsa_id ?? identifierValue(identifiers, "GHSA") ?? "";
  const cveId = advisory.cve_id ?? identifierValue(identifiers, "CVE") ?? "";

  return {
    ghsa_id: ghsaId,
    cve_id: cveId,
    severity: advisory.severity ?? "",
    summary: advisory.summary ?? "",
    url: advisory.html_url ?? advisory.url ?? "",
    state: advisory.state ?? "",
    published_at: advisory.published_at ?? "",
    updated_at: advisory.updated_at ?? "",
    affected_versions: uniqueJoined(vulnerabilities.map((v) => v?.vulnerable_version_range)),
    patched_versions: uniqueJoined(vulnerabilities.map((v) => v?.patched_versions)),
    packages: [...new Set(vulnerabilities.map((v) => v?.package?.name).filter(Boolean))],
  };
}

function identifierValue(identifiers, type) {
  const found = identifiers.find((identifier) => identifier?.type === type);
  return found?.value ?? null;
}

function uniqueJoined(values) {
  return [...new Set(values.filter((value) => typeof value === "string" && value.length > 0))].join(", ");
}

function buildLatestCandidate(record, releases, advisories) {
  const release = releases[0];
  if (!release) {
    return {
      status: "missing_release",
      reason: "no non-draft release matched the refresh filters",
    };
  }

  const version = versionFromTag(release.tag);
  const assets = {};
  const missing = [];
  for (const [platform, rule] of Object.entries(record.assets ?? {})) {
    const pattern = renderPattern(rule?.pattern ?? "", release.tag, version);
    const asset = release.assets.find((candidate) => globMatch(pattern, candidate.name));
    if (!asset) {
      missing.push({ platform, pattern, reason: "missing_asset" });
      continue;
    }

    const sha256 = sha256FromDigest(asset.digest);
    if (!sha256) {
      missing.push({ platform, pattern, asset: asset.name, reason: "missing_sha256_digest" });
      continue;
    }

    assets[platform] = {
      name: asset.name,
      url: asset.browser_download_url,
      sha256,
      digest: asset.digest,
      size: asset.size,
      content_type: asset.content_type,
    };
  }

  const status = missing.length === 0 ? "resolved" : "incomplete";
  const snippetAssets = Object.fromEntries(
    Object.entries(assets).map(([platform, asset]) => [
      platform,
      {
        url: asset.url,
        sha256: asset.sha256,
      },
    ]),
  );

  return {
    status,
    tag: release.tag,
    version,
    release_url: release.html_url,
    assets,
    missing,
    advisory_review_count: advisories.length,
    manual_resolved_snippet: status === "resolved"
      ? {
          tag: release.tag,
          version,
          assets: snippetAssets,
          security_warnings: [],
        }
      : null,
  };
}

function renderPattern(pattern, tag, version) {
  return pattern.replaceAll("{tag}", tag).replaceAll("{version}", version);
}

function versionFromTag(tag) {
  if (/^[vV]\d/.test(tag)) return tag.slice(1);
  return tag;
}

function sha256FromDigest(digest) {
  if (typeof digest !== "string") return null;
  const prefix = "sha256:";
  if (!digest.startsWith(prefix)) return null;
  const hex = digest.slice(prefix.length);
  return /^[0-9a-f]{64}$/i.test(hex) ? hex : null;
}

function globMatch(pattern, value) {
  const regex = new RegExp(`^${pattern.split("*").map(escapeRegex).join(".*")}$`);
  return regex.test(value);
}

function escapeRegex(value) {
  return value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
}

function summarizeRecord(record) {
  return {
    token: record.token ?? "",
    kind: record.kind ?? "",
    name: record.name ?? "",
    homepage: record.homepage ?? "",
    repo: record.upstream?.repo ?? "",
    asset_rules: record.assets ?? {},
    artifacts: record.artifacts ?? [],
    verification: record.verification ?? {},
    current_resolved: record.resolved
      ? {
          tag: record.resolved.tag ?? "",
          version: record.resolved.version ?? "",
          platforms: Object.keys(record.resolved.assets ?? {}),
          security_warning_count: Array.isArray(record.resolved.security_warnings)
            ? record.resolved.security_warnings.length
            : 0,
        }
      : null,
  };
}

async function buildRecord(record, opts) {
  const repo = record.upstream.repo;
  const [releaseResult, advisoryResult] = await Promise.all([
    fetchRepoReleases(repo, opts),
    fetchRepoAdvisories(repo, opts),
  ]);

  return {
    ...summarizeRecord(record),
    release_status: releaseResult.status,
    advisory_status: advisoryResult.status,
    latest_candidate: buildLatestCandidate(record, releaseResult.releases, advisoryResult.advisories),
    releases: releaseResult.releases,
    advisories: advisoryResult.advisories,
    errors: [
      releaseResult.status === "ok" ? null : {
        source: "releases",
        http_status: releaseResult.http_status,
        error: releaseResult.error ?? "",
      },
      advisoryResult.status === "ok" || advisoryResult.status === "skipped" ? null : {
        source: "advisories",
        http_status: advisoryResult.http_status,
        error: advisoryResult.error ?? "",
      },
    ].filter(Boolean),
  };
}

async function buildDatabase(opts) {
  const registry = await readRegistry(opts.registry);
  const records = selectedRecords(registry, opts);
  if (opts.tokens.length > 0 && records.length === 0) {
    die(`no matching GitHub release records found for token filter: ${opts.tokens.join(", ")}`);
  }

  const dbRecords = [];
  for (const record of records) {
    dbRecords.push(await buildRecord(record, opts));
  }

  return {
    schema_version: 1,
    generated_at: opts.generatedAt ?? new Date().toISOString(),
    source_registry: opts.registry,
    release_limit: opts.releaseLimit,
    include_prerelease: opts.includePrerelease,
    advisory_fetch: opts.noAdvisories ? "skipped" : "enabled",
    record_count: dbRecords.length,
    records: dbRecords,
  };
}

async function writeDatabase(result, opts) {
  const json = `${JSON.stringify(result, null, 2)}\n`;
  if (opts.stdout) {
    process.stdout.write(json);
  } else {
    await mkdir(dirname(opts.out), { recursive: true });
    await writeFile(opts.out, json);
    console.log(`wrote ${opts.out} (${result.record_count} records)`);
  }
}

async function runSelfTest(opts) {
  const fixtureDir = opts.fixtureDir ?? DEFAULT_SELF_TEST_FIXTURE_DIR;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => {
    throw new Error("offline self-test attempted a network fetch");
  };

  try {
    const result = await buildDatabase({
      ...opts,
      registry: join(fixtureDir, "registry.json"),
      out: "",
      stdout: true,
      tokens: [],
      releaseLimit: 10,
      includePrerelease: false,
      noAdvisories: false,
      fixtureDir,
      generatedAt: "2026-01-02T03:04:05.000Z",
    });

    assert.equal(result.schema_version, 1);
    assert.equal(result.generated_at, "2026-01-02T03:04:05.000Z");
    assert.equal(result.record_count, 2);

    const complete = result.records.find((record) => record.token === "fixture-complete");
    assert.ok(complete, "fixture-complete record is present");
    assert.equal(complete.release_status, "ok");
    assert.equal(complete.advisory_status, "ok");
    assert.equal(complete.latest_candidate.status, "resolved");
    assert.equal(complete.latest_candidate.tag, "v1.2.3");
    assert.equal(complete.latest_candidate.version, "1.2.3");
    assert.equal(
      complete.latest_candidate.assets["macos-arm64"].name,
      "FixtureApp-1.2.3-macos-arm64.zip",
    );
    assert.equal(
      complete.latest_candidate.assets["macos-arm64"].sha256,
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    assert.equal(
      complete.latest_candidate.manual_resolved_snippet.assets["macos-arm64"].url,
      "https://github.com/fixture/complete/releases/download/v1.2.3/FixtureApp-1.2.3-macos-arm64.zip",
    );
    assert.deepEqual(complete.latest_candidate.manual_resolved_snippet.security_warnings, []);
    assert.equal(complete.advisories.length, 1);
    assert.equal(complete.advisories[0].ghsa_id, "GHSA-abcd-1234-wxyz");
    assert.equal(complete.advisories[0].cve_id, "CVE-2026-0001");
    assert.equal(complete.advisories[0].affected_versions, "< 1.2.3, >= 2.0.0 < 2.0.5");
    assert.equal(complete.advisories[0].patched_versions, ">= 1.2.3, >= 2.0.5");
    assert.deepEqual(complete.advisories[0].packages, ["fixture-complete"]);

    const incomplete = result.records.find((record) => record.token === "fixture-incomplete");
    assert.ok(incomplete, "fixture-incomplete record is present");
    assert.equal(incomplete.latest_candidate.status, "incomplete");
    assert.equal(incomplete.latest_candidate.manual_resolved_snippet, null);
    assert.deepEqual(
      incomplete.latest_candidate.missing.map((missing) => missing.reason),
      ["missing_asset", "missing_sha256_digest"],
    );

    console.log("upstream release DB offline self-test passed");
  } finally {
    globalThis.fetch = originalFetch;
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.selfTest) {
    await runSelfTest(opts);
    return;
  }

  const result = await buildDatabase(opts);
  await writeDatabase(result, opts);
}

main().catch((err) => {
  console.error(err.stack || String(err));
  process.exit(1);
});
