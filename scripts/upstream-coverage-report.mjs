#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const DEFAULT_REGISTRY = "registry/upstream.json";
const FORMULA_ANALYTICS_URL = "https://formulae.brew.sh/api/analytics/install-on-request/30d.json";
const CASK_ANALYTICS_URL = "https://formulae.brew.sh/api/analytics/cask-install/30d.json";
const GITHUB_API = "https://api.github.com";
const JSON_FETCH_TIMEOUT_MS = 15_000;

function parseArgs(argv) {
  const opts = {
    registry: DEFAULT_REGISTRY,
    top: 100,
    json: false,
    downloadCounts: false,
    formulaAnalyticsFile: null,
    caskAnalyticsFile: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--registry") {
      opts.registry = argv[++i] ?? "";
    } else if (arg.startsWith("--registry=")) {
      opts.registry = arg.slice("--registry=".length);
    } else if (arg === "--top") {
      opts.top = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--top=")) {
      opts.top = Number.parseInt(arg.slice("--top=".length), 10);
    } else if (arg === "--json") {
      opts.json = true;
    } else if (arg === "--download-counts") {
      opts.downloadCounts = true;
    } else if (arg === "--formula-analytics-file") {
      opts.formulaAnalyticsFile = argv[++i] ?? "";
    } else if (arg.startsWith("--formula-analytics-file=")) {
      opts.formulaAnalyticsFile = arg.slice("--formula-analytics-file=".length);
    } else if (arg === "--cask-analytics-file") {
      opts.caskAnalyticsFile = argv[++i] ?? "";
    } else if (arg.startsWith("--cask-analytics-file=")) {
      opts.caskAnalyticsFile = arg.slice("--cask-analytics-file=".length);
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(1);
    }
  }

  if (!opts.registry) die("--registry must not be empty");
  if (!Number.isInteger(opts.top) || opts.top < 1) die("--top must be a positive integer");
  return opts;
}

function usage(code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`Usage: scripts/upstream-coverage-report.mjs [options]

Report verified upstream coverage against Homebrew popularity analytics.

Options:
  --registry PATH              Registry to read (default: ${DEFAULT_REGISTRY})
  --top N                      Popular rows to include in coverage math (default: 100)
  --download-counts            Fetch GitHub release asset download_count for seeded records
  --json                       Emit machine-readable JSON
  --formula-analytics-file P   Read formula analytics JSON from disk instead of fetching
  --cask-analytics-file P      Read cask analytics JSON from disk instead of fetching
  -h, --help                   Show this help

Set GITHUB_TOKEN to raise GitHub API limits for --download-counts.
`);
  process.exit(code);
}

function die(message) {
  console.error(message);
  process.exit(1);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const [registry, formulaAnalytics, caskAnalytics] = await Promise.all([
    readJson(opts.registry),
    loadJson(FORMULA_ANALYTICS_URL, opts.formulaAnalyticsFile, "nanobrew-upstream-coverage-report"),
    loadJson(CASK_ANALYTICS_URL, opts.caskAnalyticsFile, "nanobrew-upstream-coverage-report"),
  ]);

  const records = registry.records ?? [];
  const formulaRecords = records.filter((record) => record.kind === "formula");
  const caskRecords = records.filter((record) => record.kind === "cask");

  const formulaCoverage = coverageForKind("formula", formulaRecords, formulaAnalytics.items ?? [], opts.top);
  const caskCoverage = coverageForKind("cask", caskRecords, caskAnalytics.items ?? [], opts.top);
  const result = {
    generated_at: new Date().toISOString(),
    registry: opts.registry,
    top: opts.top,
    formula: formulaCoverage,
    cask: caskCoverage,
  };

  if (opts.downloadCounts) {
    result.github_release_downloads = await githubDownloadCounts(records);
  }

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }

  printHuman(result);
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function loadJson(url, file, userAgent) {
  if (file) return readJson(file);
  const response = await fetchWithTimeout(url, {
    headers: {
      accept: "application/json",
      "user-agent": userAgent,
    },
  }, JSON_FETCH_TIMEOUT_MS);
  if (!response.ok) throw new Error(`fetch failed for ${url}: HTTP ${response.status}`);
  return response.json();
}

function coverageForKind(kind, records, analyticsItems, top) {
  const tokenKey = kind === "formula" ? "formula" : "cask";
  const seeded = new Map(records.map((record) => [record.token, record]));
  const ranked = analyticsItems
    .slice(0, top)
    .map((item) => ({
      token: item[tokenKey],
      rank: Number.parseInt(String(item.number ?? ""), 10) || 0,
      count_text: item.count ?? "",
      count: parseCount(item.count),
    }))
    .filter((item) => item.token);

  const seededRanked = ranked.filter((item) => seeded.has(item.token));
  const totalCount = sum(ranked.map((item) => item.count));
  const coveredCount = sum(seededRanked.map((item) => item.count));
  const allAnalytics = new Map((analyticsItems ?? []).map((item) => [item[tokenKey], item]));
  const seededWithAnalytics = records
    .map((record) => {
      const item = allAnalytics.get(record.token);
      return {
        token: record.token,
        rank: Number.parseInt(String(item?.number ?? record.analytics?.install_on_request_30d_rank ?? record.analytics?.cask_install_30d_rank ?? ""), 10) || null,
        count_text: item?.count ?? record.analytics?.install_on_request_30d_count ?? record.analytics?.cask_install_30d_count ?? "",
        count: parseCount(item?.count ?? record.analytics?.install_on_request_30d_count ?? record.analytics?.cask_install_30d_count ?? ""),
      };
    })
    .sort((a, b) => (a.rank ?? Number.MAX_SAFE_INTEGER) - (b.rank ?? Number.MAX_SAFE_INTEGER));

  return {
    seeded_records: records.length,
    top_total_records: ranked.length,
    top_seeded_records: seededRanked.length,
    top_total_30d_count: totalCount,
    top_seeded_30d_count: coveredCount,
    top_coverage_percent: totalCount === 0 ? 0 : Number(((coveredCount / totalCount) * 100).toFixed(2)),
    seeded_ranked: seededRanked,
    seeded_with_analytics: seededWithAnalytics,
    top_unseeded: ranked.filter((item) => !seeded.has(item.token)).slice(0, 15),
  };
}

async function githubDownloadCounts(records) {
  const releaseCache = new Map();
  const rows = [];
  for (const record of records) {
    if (record.upstream?.type !== "github_release" || !record.resolved?.tag) continue;
    const release = await fetchRelease(record.upstream.repo, record.resolved.tag, releaseCache);
    if (!release.ok) {
      rows.push({
        token: record.token,
        kind: record.kind,
        repo: record.upstream.repo,
        tag: record.resolved.tag,
        status: release.reason,
        matched_assets: [],
        total_download_count: 0,
      });
      continue;
    }

    const matched = [];
    for (const asset of Object.values(record.resolved.assets ?? {})) {
      const releaseAsset = findReleaseAsset(release.data, asset.url);
      if (!releaseAsset) continue;
      matched.push({
        name: releaseAsset.name ?? assetNameFromUrl(asset.url),
        platform_url: asset.url,
        download_count: Number.isFinite(releaseAsset.download_count) ? releaseAsset.download_count : 0,
      });
    }
    rows.push({
      token: record.token,
      kind: record.kind,
      repo: record.upstream.repo,
      tag: record.resolved.tag,
      status: "ok",
      matched_assets: matched,
      total_download_count: sum(matched.map((asset) => asset.download_count)),
    });
  }
  rows.sort((a, b) => b.total_download_count - a.total_download_count);
  return rows;
}

async function fetchRelease(repo, tag, cache) {
  const key = `${repo}#${tag}`;
  if (cache.has(key)) return cache.get(key);
  const response = await fetchWithTimeout(`${GITHUB_API}/repos/${repo}/releases/tags/${encodeURIComponent(tag)}`, {
    headers: githubHeaders(),
  }, JSON_FETCH_TIMEOUT_MS).catch(() => null);
  if (!response || !response.ok) {
    const result = { ok: false, reason: `release fetch failed: HTTP ${response?.status ?? 0}` };
    cache.set(key, result);
    return result;
  }
  const result = { ok: true, data: await response.json() };
  cache.set(key, result);
  return result;
}

function githubHeaders() {
  const headers = {
    accept: "application/vnd.github+json",
    "user-agent": "nanobrew-upstream-coverage-report",
    "x-github-api-version": "2022-11-28",
  };
  if (process.env.GITHUB_TOKEN) headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  return headers;
}

function findReleaseAsset(release, url) {
  const name = assetNameFromUrl(url);
  return (release.assets ?? []).find((asset) => {
    return asset?.browser_download_url === url || asset?.name === name;
  }) ?? null;
}

function assetNameFromUrl(value) {
  try {
    const url = new URL(value);
    return decodeURIComponent(url.pathname.split("/").filter(Boolean).at(-1) ?? "");
  } catch {
    return "";
  }
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

function parseCount(value) {
  if (typeof value === "number") return value;
  return Number.parseInt(String(value ?? "").replaceAll(",", ""), 10) || 0;
}

function sum(values) {
  return values.reduce((acc, value) => acc + value, 0);
}

function printHuman(result) {
  console.log(`Verified upstream coverage (${result.registry}, top ${result.top})`);
  printKind("Formulae", result.formula);
  printKind("Casks", result.cask);
  if (result.github_release_downloads) {
    console.log("\nGitHub release asset download_count for seeded GitHub-release records:");
    for (const row of result.github_release_downloads.slice(0, 20)) {
      console.log(`  ${row.kind}:${row.token} ${row.total_download_count.toLocaleString()} (${row.repo} ${row.tag})`);
    }
  }
}

function printKind(label, data) {
  console.log(`\n${label}:`);
  console.log(`  seeded records: ${data.seeded_records}`);
  console.log(`  top ${data.top_total_records} seeded: ${data.top_seeded_records}`);
  console.log(`  top 30d count covered: ${data.top_seeded_30d_count.toLocaleString()} / ${data.top_total_30d_count.toLocaleString()} (${data.top_coverage_percent}%)`);
  console.log("  seeded by Homebrew rank:");
  for (const item of data.seeded_with_analytics.slice(0, 15)) {
    const rank = item.rank == null ? "?" : String(item.rank);
    console.log(`    #${rank} ${item.token} ${item.count_text}`);
  }
  console.log("  next high-ranked unseeded:");
  for (const item of data.top_unseeded.slice(0, 10)) {
    console.log(`    #${item.rank} ${item.token} ${item.count_text}`);
  }
}

main().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});
