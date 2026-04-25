#!/usr/bin/env node

import { readdir, rm, stat } from "node:fs/promises";
import { spawn } from "node:child_process";

const DEFAULT_NB = "./zig-out/bin/nb";
const DEFAULT_ROOT = "/opt/nanobrew";

function parseArgs(argv) {
  const opts = {
    nb: DEFAULT_NB,
    root: DEFAULT_ROOT,
    kind: "formula",
    tokens: [],
    iterations: 1,
    order: "upstream-first",
    json: false,
    cold: false,
    allowCasks: false,
    upstreamRegistryUrl: "",
    upstreamRegistryCache: "",
    trace: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--nb") {
      opts.nb = argv[++i] ?? "";
    } else if (arg.startsWith("--nb=")) {
      opts.nb = arg.slice("--nb=".length);
    } else if (arg === "--root") {
      opts.root = argv[++i] ?? "";
    } else if (arg.startsWith("--root=")) {
      opts.root = arg.slice("--root=".length);
    } else if (arg === "--kind") {
      opts.kind = argv[++i] ?? "";
    } else if (arg.startsWith("--kind=")) {
      opts.kind = arg.slice("--kind=".length);
    } else if (arg === "--tokens") {
      opts.tokens.push(...splitList(argv[++i] ?? ""));
    } else if (arg.startsWith("--tokens=")) {
      opts.tokens.push(...splitList(arg.slice("--tokens=".length)));
    } else if (arg === "--iterations") {
      opts.iterations = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--iterations=")) {
      opts.iterations = Number.parseInt(arg.slice("--iterations=".length), 10);
    } else if (arg === "--order") {
      opts.order = argv[++i] ?? "";
    } else if (arg.startsWith("--order=")) {
      opts.order = arg.slice("--order=".length);
    } else if (arg === "--cold") {
      opts.cold = true;
    } else if (arg === "--allow-casks") {
      opts.allowCasks = true;
    } else if (arg === "--upstream-registry-url") {
      opts.upstreamRegistryUrl = argv[++i] ?? "";
    } else if (arg.startsWith("--upstream-registry-url=")) {
      opts.upstreamRegistryUrl = arg.slice("--upstream-registry-url=".length);
    } else if (arg === "--upstream-registry-cache") {
      opts.upstreamRegistryCache = argv[++i] ?? "";
    } else if (arg.startsWith("--upstream-registry-cache=")) {
      opts.upstreamRegistryCache = arg.slice("--upstream-registry-cache=".length);
    } else if (arg === "--trace") {
      opts.trace = true;
    } else if (arg === "--json") {
      opts.json = true;
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(1);
    }
  }

  if (!opts.nb) die("--nb must not be empty");
  if (!opts.root) die("--root must not be empty");
  if (!["formula", "cask"].includes(opts.kind)) die("--kind must be formula or cask");
  if (opts.kind === "cask" && !opts.allowCasks) {
    die("--kind cask installs/removes apps under /Applications; pass --allow-casks to run it");
  }
  if (opts.tokens.length === 0) die("--tokens is required");
  if (!Number.isInteger(opts.iterations) || opts.iterations < 1) die("--iterations must be a positive integer");
  if (!["upstream-first", "homebrew-first", "alternating"].includes(opts.order)) {
    die("--order must be one of: upstream-first, homebrew-first, alternating");
  }
  opts.tokens = [...new Set(opts.tokens)];
  return opts;
}

function usage(code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`Usage: scripts/bench-upstream-install.mjs --tokens a,b [options]

Benchmark actual nb install wall time through verified upstream vs Homebrew fallback.

Options:
  --nb PATH          nb executable to benchmark (default: ${DEFAULT_NB})
  --root PATH        nanobrew root used for package-specific cache purge (default: ${DEFAULT_ROOT})
  --kind formula|cask
  --tokens a,b       Package tokens to install and remove
  --iterations N     Timed installs per mode/token (default: 1)
  --order MODE       upstream-first, homebrew-first, or alternating (default: upstream-first)
  --cold             Remove package-specific cache/store entries before each timed install
  --upstream-registry-url URL
                     Upstream registry URL to benchmark, e.g. a beta registry
  --upstream-registry-cache PATH
                     Cache path for the upstream registry during benchmark
  --allow-casks      Required for cask benchmarks because they modify /Applications
  --trace            Capture cask install phase timings in JSON
  --json             Emit machine-readable JSON
  -h, --help         Show this help

The script refuses tokens already installed before the benchmark starts, then removes
each benchmarked install after timing it. It preserves unrelated packages.
`);
  process.exit(code);
}

function die(message) {
  console.error(message);
  process.exit(1);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const rows = [];
  const skipped = [];

  for (const token of opts.tokens) {
    if (await isInstalled(opts.nb, token, opts.kind)) {
      skipped.push({ token, kind: opts.kind, reason: "already installed before benchmark" });
      continue;
    }

    const upstreamRuns = [];
    const homebrewRuns = [];
    const upstreamTraceRuns = [];
    const homebrewTraceRuns = [];
    try {
      for (let i = 0; i < opts.iterations; i += 1) {
        const order = iterationOrder(opts.order, i);
        for (const mode of order) {
          const runResult = await installOnce(opts, token, mode);
          if (mode === "upstream") {
            upstreamRuns.push(runResult.ms);
            if (opts.trace) upstreamTraceRuns.push(runResult.trace);
          } else {
            homebrewRuns.push(runResult.ms);
            if (opts.trace) homebrewTraceRuns.push(runResult.trace);
          }
          await removeToken(opts.nb, token, opts.kind);
        }
      }
    } finally {
      await removeToken(opts.nb, token, opts.kind);
    }

    const upstreamMedian = median(upstreamRuns);
    const homebrewMedian = median(homebrewRuns);
    const row = {
      token,
      kind: opts.kind,
      upstream_median_ms: round(upstreamMedian),
      homebrew_median_ms: round(homebrewMedian),
      delta_ms: round(homebrewMedian - upstreamMedian),
      speedup: upstreamMedian > 0 ? Number((homebrewMedian / upstreamMedian).toFixed(2)) : null,
      upstream_runs_ms: upstreamRuns.map(round),
      homebrew_runs_ms: homebrewRuns.map(round),
    };
    if (opts.trace) {
      row.upstream_trace_runs = upstreamTraceRuns;
      row.homebrew_trace_runs = homebrewTraceRuns;
      row.upstream_phase_median_ms = medianPhases(upstreamTraceRuns);
      row.homebrew_phase_median_ms = medianPhases(homebrewTraceRuns);
      row.phase_delta_ms = phaseDeltas(row.upstream_phase_median_ms, row.homebrew_phase_median_ms);
    }
    rows.push(row);
  }

  const result = {
    generated_at: new Date().toISOString(),
    kind: opts.kind,
    iterations: opts.iterations,
    order: opts.order,
    cold: opts.cold,
    trace: opts.trace,
    upstream_registry_url: opts.upstreamRegistryUrl || null,
    upstream_registry_cache: opts.upstreamRegistryCache || null,
    summary: summarize(rows),
    rows,
    skipped,
  };

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  printHuman(result);
}

function iterationOrder(order, iteration) {
  if (order === "homebrew-first") return ["homebrew", "upstream"];
  if (order === "alternating" && iteration % 2 === 1) return ["homebrew", "upstream"];
  return ["upstream", "homebrew"];
}

async function installOnce(opts, token, mode) {
  if (opts.cold) await purgePackageCache(opts, token, mode);
  const args = opts.kind === "cask" ? ["install", "--cask", token] : ["install", token];
  const start = process.hrtime.bigint();
  const result = await run(opts.nb, args, envFor(opts, mode));
  const end = process.hrtime.bigint();
  if (result.code !== 0) {
    throw new Error(`${mode} install failed for ${token}: ${result.stderr.slice(0, 1200)}${result.stdout.slice(0, 1200)}`);
  }
  return {
    ms: Number(end - start) / 1_000_000,
    trace: opts.trace ? parseTrace(`${result.stderr}\n${result.stdout}`, token) : {},
  };
}

function envFor(opts, mode) {
  const env = { ...process.env };
  if (opts.trace && opts.kind === "cask") {
    env.NANOBREW_CASK_TRACE = "1";
  } else {
    delete env.NANOBREW_CASK_TRACE;
  }
  if (opts.kind === "cask" && opts.cold) {
    env.NANOBREW_DISABLE_CASK_BLOB_CACHE = "1";
  } else {
    delete env.NANOBREW_DISABLE_CASK_BLOB_CACHE;
  }
  if (mode === "upstream") {
    delete env.NANOBREW_DISABLE_UPSTREAM;
    if (opts.upstreamRegistryUrl) {
      env.NANOBREW_UPSTREAM_REGISTRY_URL = opts.upstreamRegistryUrl;
      if (opts.upstreamRegistryCache) {
        env.NANOBREW_UPSTREAM_REGISTRY_CACHE = opts.upstreamRegistryCache;
      }
      delete env.NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE;
    } else {
      delete env.NANOBREW_UPSTREAM_REGISTRY_URL;
      if (opts.upstreamRegistryCache) {
        env.NANOBREW_UPSTREAM_REGISTRY_CACHE = opts.upstreamRegistryCache;
      }
      env.NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE = "1";
    }
  } else {
    env.NANOBREW_DISABLE_UPSTREAM = "1";
    delete env.NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE;
    delete env.NANOBREW_UPSTREAM_REGISTRY_URL;
    delete env.NANOBREW_UPSTREAM_REGISTRY_CACHE;
  }
  return env;
}

async function isInstalled(nb, token, kind) {
  const result = await run(nb, ["list"], process.env);
  if (result.code !== 0) return false;
  return result.stdout.split("\n").some((line) => {
    const trimmed = line.trim();
    if (!trimmed.startsWith(`${token} `)) return false;
    return kind === "cask" ? trimmed.endsWith("(cask)") : !trimmed.endsWith("(cask)");
  });
}

async function removeToken(nb, token, kind) {
  const args = kind === "cask" ? ["remove", "--cask", token] : ["remove", token];
  await run(nb, args, process.env).catch(() => null);
}

async function purgePackageCache(opts, token, mode) {
  await removeTmpArchives(opts.root, token);
  if (opts.kind === "cask") return;
  const sha = await shaFromInfo(opts, token, mode).catch(() => "");
  if (!sha) return;
  await rm(`${opts.root}/cache/blobs/${sha}`, { force: true, recursive: true });
  await rm(`${opts.root}/store/${sha}`, { force: true, recursive: true });
  await rm(`${opts.root}/store-relocated/${sha}`, { force: true, recursive: true });
}

async function removeTmpArchives(root, token) {
  const tmp = `${root}/cache/tmp`;
  const entries = await readdir(tmp).catch(() => []);
  await Promise.all(entries
    .filter((entry) => entry === token || entry.startsWith(`${token}-`) || entry.startsWith(`${token}.`))
    .map(async (entry) => {
      const path = `${tmp}/${entry}`;
      const info = await stat(path).catch(() => null);
      if (!info) return;
      await rm(path, { force: true, recursive: info.isDirectory() });
    }));
}

async function shaFromInfo(opts, token, mode) {
  const args = opts.kind === "cask" ? ["info", "--cask", token] : ["info", token];
  const result = await run(opts.nb, args, envFor(opts, mode));
  if (result.code !== 0) return "";
  const match = /^\s*sha256:\s*([0-9a-f]{64})\s*$/im.exec(result.stdout);
  return match?.[1]?.toLowerCase() ?? "";
}

function run(command, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

function round(value) {
  return Number(value.toFixed(2));
}

function splitList(value) {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function parseTrace(output, token) {
  const phases = {};
  const re = /^\[nb-cask-trace\]\s+token=(\S+)\s+phase=([A-Za-z0-9_]+)\s+ms=([0-9]+(?:\.[0-9]+)?)\s*$/gm;
  let match = null;
  while ((match = re.exec(output)) !== null) {
    if (match[1] !== token) continue;
    const ms = Number(match[3]);
    if (!Number.isFinite(ms)) continue;
    phases[match[2]] = round((phases[match[2]] ?? 0) + ms);
  }
  return phases;
}

function medianPhases(runs) {
  const byPhase = new Map();
  for (const run of runs) {
    for (const [phase, ms] of Object.entries(run ?? {})) {
      if (!Number.isFinite(ms)) continue;
      if (!byPhase.has(phase)) byPhase.set(phase, []);
      byPhase.get(phase).push(ms);
    }
  }
  return Object.fromEntries([...byPhase.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([phase, values]) => [phase, round(median(values))]));
}

function phaseDeltas(upstream, homebrew) {
  const phases = new Set([...Object.keys(upstream ?? {}), ...Object.keys(homebrew ?? {})]);
  return Object.fromEntries([...phases]
    .sort()
    .filter((phase) => Number.isFinite(upstream?.[phase]) && Number.isFinite(homebrew?.[phase]))
    .map((phase) => [phase, round(homebrew[phase] - upstream[phase])]));
}

function summarize(rows) {
  const measured = rows.filter((row) =>
    Number.isFinite(row.upstream_median_ms) &&
    Number.isFinite(row.homebrew_median_ms) &&
    row.upstream_median_ms > 0 &&
    row.homebrew_median_ms > 0);
  const upstreamTotal = measured.reduce((sum, row) => sum + row.upstream_median_ms, 0);
  const homebrewTotal = measured.reduce((sum, row) => sum + row.homebrew_median_ms, 0);
  const speedups = measured.map((row) => row.homebrew_median_ms / row.upstream_median_ms);
  const averageSpeedup = speedups.length > 0
    ? speedups.reduce((sum, value) => sum + value, 0) / speedups.length
    : null;
  return {
    measured_count: measured.length,
    faster_count: measured.filter((row) => row.homebrew_median_ms > row.upstream_median_ms).length,
    upstream_total_ms: round(upstreamTotal),
    homebrew_total_ms: round(homebrewTotal),
    total_delta_ms: round(homebrewTotal - upstreamTotal),
    weighted_speedup: upstreamTotal > 0 ? Number((homebrewTotal / upstreamTotal).toFixed(2)) : null,
    average_speedup: averageSpeedup == null ? null : Number(averageSpeedup.toFixed(2)),
    min_speedup: speedups.length > 0 ? Number(Math.min(...speedups).toFixed(2)) : null,
    max_speedup: speedups.length > 0 ? Number(Math.max(...speedups).toFixed(2)) : null,
  };
}

function printHuman(result) {
  const cacheLabel = result.cold ? "cold package cache" : "warm cache";
  console.log(`nb install benchmark (${result.kind}, ${result.iterations} iteration(s), ${cacheLabel})`);
  if (result.upstream_registry_url) {
    console.log(`upstream registry: ${result.upstream_registry_url}`);
  }
  if (result.upstream_registry_cache) {
    console.log(`upstream registry cache: ${result.upstream_registry_cache}`);
  }
  if (result.skipped.length > 0) {
    console.log("skipped:");
    for (const item of result.skipped) {
      console.log(`  ${item.token}: ${item.reason}`);
    }
  }
  if (result.rows.length === 0) return;
  if (result.summary.measured_count > 0) {
    console.log(`summary\tmeasured=${result.summary.measured_count}\tfaster=${result.summary.faster_count}\tweighted=${result.summary.weighted_speedup}x\tavg=${result.summary.average_speedup}x\tdelta_ms=${result.summary.total_delta_ms}`);
  }
  console.log("token\tkind\tupstream_ms\thomebrew_ms\tdelta_ms\tspeedup");
  for (const row of result.rows) {
    console.log(`${row.token}\t${row.kind}\t${row.upstream_median_ms}\t${row.homebrew_median_ms}\t${row.delta_ms}\t${row.speedup}x`);
  }
  const tracedRows = result.rows.filter((row) => row.phase_delta_ms && Object.keys(row.phase_delta_ms).length > 0);
  if (tracedRows.length > 0) {
    console.log("phase_token\tphase\tupstream_ms\thomebrew_ms\tdelta_ms");
    for (const row of tracedRows) {
      const slowest = Object.entries(row.phase_delta_ms)
        .sort((a, b) => a[1] - b[1])[0];
      if (!slowest) continue;
      const [phase, delta] = slowest;
      console.log(`${row.token}\t${phase}\t${row.upstream_phase_median_ms[phase]}\t${row.homebrew_phase_median_ms[phase]}\t${delta}`);
    }
  }
}

main().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});
