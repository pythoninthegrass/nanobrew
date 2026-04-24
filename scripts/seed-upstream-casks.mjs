#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";

const CASK_ANALYTICS_URL = "https://formulae.brew.sh/api/analytics/cask-install/30d.json";
const CASK_URL = "https://formulae.brew.sh/api/cask.json";
const GITHUB_API = "https://api.github.com";
const DEFAULT_REGISTRY = "registry/upstream.json";
const DEFAULT_EMBEDDED_REGISTRY = "src/upstream/registry_default.json";
const JSON_FETCH_TIMEOUT_MS = 15_000;

function parseArgs(argv) {
  const opts = {
    limit: 5,
    scan: 500,
    write: false,
    replace: false,
    includeExisting: false,
    includePkg: false,
    includeBinaries: true,
    registry: DEFAULT_REGISTRY,
    embeddedRegistry: DEFAULT_EMBEDDED_REGISTRY,
    analyticsFile: null,
    caskFile: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--limit") {
      opts.limit = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--limit=")) {
      opts.limit = Number.parseInt(arg.slice("--limit=".length), 10);
    } else if (arg === "--scan") {
      opts.scan = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--scan=")) {
      opts.scan = Number.parseInt(arg.slice("--scan=".length), 10);
    } else if (arg === "--write") {
      opts.write = true;
    } else if (arg === "--replace") {
      opts.replace = true;
    } else if (arg === "--include-existing") {
      opts.includeExisting = true;
    } else if (arg === "--include-pkg") {
      opts.includePkg = true;
    } else if (arg === "--no-binaries") {
      opts.includeBinaries = false;
    } else if (arg === "--registry") {
      opts.registry = argv[++i] ?? "";
    } else if (arg.startsWith("--registry=")) {
      opts.registry = arg.slice("--registry=".length);
    } else if (arg === "--embedded-registry") {
      opts.embeddedRegistry = argv[++i] ?? "";
    } else if (arg.startsWith("--embedded-registry=")) {
      opts.embeddedRegistry = arg.slice("--embedded-registry=".length);
    } else if (arg === "--analytics-file") {
      opts.analyticsFile = argv[++i] ?? "";
    } else if (arg.startsWith("--analytics-file=")) {
      opts.analyticsFile = arg.slice("--analytics-file=".length);
    } else if (arg === "--cask-file") {
      opts.caskFile = argv[++i] ?? "";
    } else if (arg.startsWith("--cask-file=")) {
      opts.caskFile = arg.slice("--cask-file=".length);
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(1);
    }
  }

  if (!Number.isInteger(opts.limit) || opts.limit < 1) die("--limit must be a positive integer");
  if (!Number.isInteger(opts.scan) || opts.scan < opts.limit) die("--scan must be an integer >= --limit");
  if (!opts.registry) die("--registry must not be empty");
  if (!opts.embeddedRegistry) die("--embedded-registry must not be empty");
  return opts;
}

function usage(code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`Usage: scripts/seed-upstream-casks.mjs [options]

Seed popular GitHub-release cask records into the verified upstream registry.

Options:
  --limit N                  Records to generate (default: 5)
  --scan N                   Popular cask rows to inspect (default: 500)
  --write                    Update registry files; otherwise print candidates
  --replace                  Replace existing cask records for generated tokens
  --include-existing         Include already-seeded records in printed output
  --include-pkg              Allow pkg-only cask records
  --no-binaries              Do not include safe binary artifacts
  --registry PATH            Registry to update (default: ${DEFAULT_REGISTRY})
  --embedded-registry PATH   Embedded fallback to update (default: ${DEFAULT_EMBEDDED_REGISTRY})
  --analytics-file PATH      Read cask analytics JSON from disk instead of fetching
  --cask-file PATH           Read cask JSON from disk instead of fetching
  -h, --help                 Show this help

Set GITHUB_TOKEN to raise GitHub API limits.
`);
  process.exit(code);
}

function die(message) {
  console.error(message);
  process.exit(1);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const [registry, analytics, casks] = await Promise.all([
    readJson(opts.registry),
    loadJson(CASK_ANALYTICS_URL, opts.analyticsFile),
    loadJson(CASK_URL, opts.caskFile),
  ]);

  const caskByToken = new Map(casks.map((cask) => [cask.token, cask]));
  const existing = new Set((registry.records ?? []).map((record) => `${record.kind}:${record.token}`));
  const releaseCache = new Map();
  const candidates = [];
  const skipped = [];

  for (const item of (analytics.items ?? []).slice(0, opts.scan)) {
    if (candidates.length >= opts.limit) break;
    const token = item.cask;
    if (!token) continue;
    if (!opts.replace && !opts.includeExisting && existing.has(`cask:${token}`)) {
      skipped.push({ token, reason: "already seeded" });
      continue;
    }

    const cask = caskByToken.get(token);
    if (!cask) {
      skipped.push({ token, reason: "cask metadata missing" });
      continue;
    }

    const seeded = await seedRecordFromCask(cask, item, opts, releaseCache);
    if (!seeded.ok) {
      skipped.push({ token, reason: seeded.reason });
      continue;
    }
    candidates.push(seeded.record);
  }

  if (!opts.write) {
    process.stdout.write(JSON.stringify({ records: candidates, skipped: skipped.slice(0, 60) }, null, 2));
    process.stdout.write("\n");
    return;
  }

  const next = {
    schema_version: registry.schema_version ?? 1,
    records: mergeRecords(registry.records ?? [], candidates, opts.replace),
  };
  const rendered = `${JSON.stringify(next, null, 2)}\n`;
  await writeFile(opts.registry, rendered);
  await writeFile(opts.embeddedRegistry, rendered);
  console.error(`seeded ${candidates.length} cask record(s): ${candidates.map((record) => record.token).join(", ")}`);
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function loadJson(url, file) {
  if (file) return readJson(file);
  const response = await fetchWithTimeout(url, {
    headers: {
      accept: "application/json",
      "user-agent": "nanobrew-upstream-cask-seeder",
    },
  }, JSON_FETCH_TIMEOUT_MS);
  if (!response.ok) throw new Error(`fetch failed for ${url}: HTTP ${response.status}`);
  return response.json();
}

async function seedRecordFromCask(cask, analyticsItem, opts, releaseCache) {
  const base = githubReleaseAssetParts(cask.url);
  if (!base) return { ok: false, reason: "not a GitHub release asset cask" };

  const artifacts = caskArtifacts(cask, opts);
  if (!artifacts.ok) return artifacts;

  const downloads = collectPlatformDownloads(cask, base);
  if (downloads.size === 0) return { ok: false, reason: "no supported macOS platform downloads" };
  if (!downloads.has("macos-arm64")) return { ok: false, reason: "no macos-arm64 download" };

  const release = await fetchRelease(base.repo, base.tag, releaseCache);
  if (!release.ok) return { ok: false, reason: release.reason };

  const assets = {};
  const resolvedAssets = {};
  for (const [platform, download] of downloads) {
    const asset = findReleaseAsset(release.data, download.url);
    if (!asset) continue;
    const digest = sha256FromDigest(asset.digest);
    if (!digest) continue;
    if (download.sha256 && digest !== download.sha256.toLowerCase()) continue;
    assets[platform] = {
      pattern: patternFromAsset(asset.name, base.tag, cask.version ?? ""),
    };
    resolvedAssets[platform] = {
      url: asset.browser_download_url,
      sha256: digest,
    };
  }

  if (!resolvedAssets["macos-arm64"]) return { ok: false, reason: "macos-arm64 asset digest missing or mismatched" };

  const canonicalRepo = canonicalRepoFromResolvedAssets(resolvedAssets) ?? base.repo;
  const record = {
    token: cask.token,
    name: caskName(cask),
    kind: "cask",
    homepage: cask.homepage ?? "",
    desc: cask.desc ?? "",
  };
  if (cask.auto_updates === true) record.auto_updates = true;
  record.upstream = {
    type: "github_release",
    repo: canonicalRepo,
    verified: true,
  };
  record.analytics = {
    cask_install_30d_rank: Number.parseInt(String(analyticsItem.number ?? ""), 10) || undefined,
    cask_install_30d_count: analyticsItem.count ?? "",
  };
  record.assets = assets;
  record.artifacts = artifacts.items;
  record.resolved = {
    tag: base.tag,
    version: cask.version ?? "",
    assets: resolvedAssets,
  };
  record.verification = {
    sha256: "asset_digest",
  };
  return { ok: true, record };
}

function canonicalRepoFromResolvedAssets(resolvedAssets) {
  for (const asset of Object.values(resolvedAssets)) {
    const parts = githubReleaseAssetParts(asset.url);
    if (parts) return parts.repo;
  }
  return "";
}

function caskArtifacts(cask, opts) {
  const items = [];
  var appCount = 0;
  var pkgCount = 0;

  for (const artifact of cask.artifacts ?? []) {
    if (!artifact || typeof artifact !== "object") continue;
    if (Array.isArray(artifact.app)) {
      if (hasObjectEntry(artifact.app)) return { ok: false, reason: "app artifact target unsupported" };
      for (const path of artifact.app) {
        if (typeof path !== "string") continue;
        if (!safeAppPath(path)) return { ok: false, reason: "unsafe app artifact path" };
        items.push({ type: "app", path });
        appCount += 1;
      }
    }
    if (opts.includePkg && Array.isArray(artifact.pkg)) {
      if (hasObjectEntry(artifact.pkg)) return { ok: false, reason: "pkg artifact target unsupported" };
      for (const path of artifact.pkg) {
        if (typeof path !== "string") continue;
        if (!safePkgPath(path)) return { ok: false, reason: "unsafe pkg artifact path" };
        items.push({ type: "pkg", path });
        pkgCount += 1;
      }
    }
    if (opts.includeBinaries && Array.isArray(artifact.binary)) {
      if (hasObjectEntry(artifact.binary)) continue;
      for (const path of artifact.binary) {
        if (typeof path !== "string") continue;
        if (!safeBinarySource(path)) continue;
        items.push({ type: "binary", path });
      }
    }
  }

  if (appCount === 0 && pkgCount === 0) {
    return { ok: false, reason: opts.includePkg ? "no supported app or pkg artifacts" : "no supported app artifacts" };
  }
  return { ok: true, items };
}

function hasObjectEntry(items) {
  return items.some((item) => item && typeof item === "object");
}

function safeAppPath(path) {
  return path.endsWith(".app") && !path.includes("..") && !path.includes("/");
}

function safePkgPath(path) {
  return path.endsWith(".pkg") && !path.includes("..") && !path.startsWith("/");
}

function safeBinarySource(path) {
  if (path.includes("..")) return false;
  if (path.startsWith("$HOMEBREW_PREFIX")) return false;
  if (path.startsWith("$APPDIR/")) return true;
  if (path.startsWith("/")) return true;
  return !path.includes("/");
}

function collectPlatformDownloads(cask, base) {
  const downloads = new Map();
  addPlatformDownload(downloads, cask.url, cask.sha256, "", base, false);

  for (const [key, variation] of Object.entries(cask.variations ?? {})) {
    if (!variation || typeof variation !== "object") continue;
    if (typeof variation.url !== "string" || typeof variation.sha256 !== "string") continue;
    const parts = githubReleaseAssetParts(variation.url);
    if (!parts || parts.repo !== base.repo || parts.tag !== base.tag) continue;
    addPlatformDownload(downloads, variation.url, variation.sha256, key, base, true);
  }
  return downloads;
}

function addPlatformDownload(downloads, url, sha256, variationKey, base, isVariation) {
  if (!isSha256(sha256)) return;
  const parts = githubReleaseAssetParts(url);
  if (!parts || parts.repo !== base.repo || parts.tag !== base.tag) return;
  for (const platform of platformsForDownload(url, variationKey, isVariation)) {
    if (!downloads.has(platform)) {
      downloads.set(platform, { url, sha256: sha256.toLowerCase() });
    }
  }
}

function platformsForDownload(url, variationKey, isVariation) {
  const s = `${url} ${variationKey}`.toLowerCase();
  const universal = /universal|x86_64\+arm64|arm64\+x86_64|amd64\+arm64|arm64\+amd64/.test(s);
  if (universal) return ["macos-arm64", "macos-x86_64"];

  const arm = /(?:arm64|aarch64|apple[-_ ]?silicon|macos[_-]?arm)/.test(s);
  const x86 = /(?:x86_64|amd64|x64|intel|64bit|macos[_-]?64)/.test(s);
  if (arm && !x86) return ["macos-arm64"];
  if (x86 && !arm) return ["macos-x86_64"];
  if (/^arm64(?:_|$)/.test(variationKey)) return ["macos-arm64"];
  if (isVariation && variationKey) return ["macos-x86_64"];
  return ["macos-arm64", "macos-x86_64"];
}

async function fetchRelease(repo, tag, cache) {
  const key = `${repo}#${tag}`;
  if (cache.has(key)) return cache.get(key);

  const encodedTag = encodeURIComponent(tag);
  const response = await fetchWithTimeout(`${GITHUB_API}/repos/${repo}/releases/tags/${encodedTag}`, {
    headers: githubHeaders(),
  }, JSON_FETCH_TIMEOUT_MS).catch((err) => ({ ok: false, status: 0, statusText: err?.message ?? "fetch failed" }));
  if (!response.ok) {
    const result = { ok: false, reason: `release fetch failed: HTTP ${response.status}` };
    cache.set(key, result);
    return result;
  }
  const data = await response.json();
  if (!Array.isArray(data.assets) || data.assets.length === 0) {
    const result = { ok: false, reason: "release has no assets" };
    cache.set(key, result);
    return result;
  }
  const result = { ok: true, data };
  cache.set(key, result);
  return result;
}

function githubHeaders() {
  const headers = {
    accept: "application/vnd.github+json",
    "user-agent": "nanobrew-upstream-cask-seeder",
    "x-github-api-version": "2022-11-28",
  };
  if (process.env.GITHUB_TOKEN) headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  return headers;
}

async function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function findReleaseAsset(release, url) {
  const name = assetNameFromUrl(url);
  return (release.assets ?? []).find((asset) => {
    return asset?.browser_download_url === url || asset?.name === name;
  }) ?? null;
}

function githubReleaseAssetParts(value) {
  if (typeof value !== "string") return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.hostname !== "github.com") return null;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 5 || parts[2] !== "releases" || parts[3] !== "download") return null;
  return {
    repo: `${parts[0]}/${parts[1]}`,
    tag: decodeURIComponent(parts[4]),
    asset: decodeURIComponent(parts.slice(5).join("/")),
  };
}

function assetNameFromUrl(value) {
  try {
    const url = new URL(value);
    const item = url.pathname.split("/").filter(Boolean).at(-1) ?? "";
    return decodeURIComponent(item);
  } catch {
    return "";
  }
}

function sha256FromDigest(value) {
  if (typeof value !== "string") return "";
  const match = /^sha256:([0-9a-f]{64})$/i.exec(value);
  return match?.[1]?.toLowerCase() ?? "";
}

function isSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}

function patternFromAsset(name, tag, version) {
  let pattern = name;
  if (tag) pattern = pattern.split(tag).join("{tag}");
  if (version && version !== tag) pattern = pattern.split(version).join("{version}");
  return pattern;
}

function caskName(cask) {
  if (Array.isArray(cask.name) && typeof cask.name[0] === "string" && cask.name[0].length > 0) {
    return cask.name[0];
  }
  return cask.token;
}

function mergeRecords(existing, generated, replace) {
  const generatedKeys = new Set(generated.map((record) => `${record.kind}:${record.token}`));
  const kept = replace
    ? existing.filter((record) => !generatedKeys.has(`${record.kind}:${record.token}`))
    : existing;
  return [...kept, ...generated.sort((a, b) => String(a.token).localeCompare(String(b.token)))];
}

main().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});
