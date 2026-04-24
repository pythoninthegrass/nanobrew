#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";

const DEFAULT_REGISTRY = "registry/upstream.json";
const DEFAULT_NB = "./zig-out/bin/nb";

function parseArgs(argv) {
  const opts = {
    registry: DEFAULT_REGISTRY,
    nb: DEFAULT_NB,
    kind: "all",
    tokens: [],
    iterations: 5,
    warmup: 1,
    json: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--registry") {
      opts.registry = argv[++i] ?? "";
    } else if (arg.startsWith("--registry=")) {
      opts.registry = arg.slice("--registry=".length);
    } else if (arg === "--nb") {
      opts.nb = argv[++i] ?? "";
    } else if (arg.startsWith("--nb=")) {
      opts.nb = arg.slice("--nb=".length);
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
    } else if (arg === "--warmup") {
      opts.warmup = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--warmup=")) {
      opts.warmup = Number.parseInt(arg.slice("--warmup=".length), 10);
    } else if (arg === "--json") {
      opts.json = true;
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(1);
    }
  }

  if (!opts.registry) die("--registry must not be empty");
  if (!opts.nb) die("--nb must not be empty");
  if (!["all", "formula", "cask"].includes(opts.kind)) die("--kind must be one of: all, formula, cask");
  if (!Number.isInteger(opts.iterations) || opts.iterations < 1) die("--iterations must be a positive integer");
  if (!Number.isInteger(opts.warmup) || opts.warmup < 0) die("--warmup must be a non-negative integer");
  opts.tokens = [...new Set(opts.tokens)];
  return opts;
}

function usage(code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`Usage: scripts/bench-upstream-resolution.mjs [options]

Benchmark nb info metadata resolution through verified upstream vs Homebrew fallback.

Options:
  --registry PATH       Registry to read (default: ${DEFAULT_REGISTRY})
  --nb PATH             nb executable to benchmark (default: ${DEFAULT_NB})
  --kind all|formula|cask
  --tokens a,b,c        Limit to specific tokens
  --iterations N        Timed runs per mode/token (default: 5)
  --warmup N            Untimed warmup runs per mode/token (default: 1)
  --json                Emit machine-readable JSON
  -h, --help            Show this help

This measures metadata lookup via 'nb info'. It does not download or install payloads.
`);
  process.exit(code);
}

function die(message) {
  console.error(message);
  process.exit(1);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const registry = JSON.parse(await readFile(opts.registry, "utf8"));
  const wanted = new Set(opts.tokens);
  const records = (registry.records ?? [])
    .filter((record) => opts.kind === "all" || record.kind === opts.kind)
    .filter((record) => wanted.size === 0 || wanted.has(record.token))
    .filter((record) => record.resolved);

  if (records.length === 0) die("no matching resolved records to benchmark");

  const rows = [];
  for (const record of records) {
    const upstreamArgs = infoArgs(record);
    const homebrewArgs = infoArgs(record);

    for (let i = 0; i < opts.warmup; i += 1) {
      await runNb(opts.nb, upstreamArgs, upstreamEnv());
      await runNb(opts.nb, homebrewArgs, homebrewEnv());
    }

    const upstreamTimes = [];
    const homebrewTimes = [];
    for (let i = 0; i < opts.iterations; i += 1) {
      upstreamTimes.push((await runNb(opts.nb, upstreamArgs, upstreamEnv())).ms);
      homebrewTimes.push((await runNb(opts.nb, homebrewArgs, homebrewEnv())).ms);
    }

    const upstreamMedian = median(upstreamTimes);
    const homebrewMedian = median(homebrewTimes);
    rows.push({
      token: record.token,
      kind: record.kind,
      upstream_median_ms: round(upstreamMedian),
      homebrew_median_ms: round(homebrewMedian),
      delta_ms: round(homebrewMedian - upstreamMedian),
      speedup: upstreamMedian > 0 ? Number((homebrewMedian / upstreamMedian).toFixed(2)) : null,
      upstream_runs_ms: upstreamTimes.map(round),
      homebrew_runs_ms: homebrewTimes.map(round),
    });
  }

  const result = {
    generated_at: new Date().toISOString(),
    iterations: opts.iterations,
    warmup: opts.warmup,
    rows,
  };

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  printHuman(result);
}

function infoArgs(record) {
  return record.kind === "cask" ? ["info", "--cask", record.token] : ["info", record.token];
}

function upstreamEnv() {
  return {
    ...process.env,
    NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE: "1",
  };
}

function homebrewEnv() {
  const env = {
    ...process.env,
    NANOBREW_DISABLE_UPSTREAM: "1",
  };
  delete env.NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE;
  return env;
}

async function runNb(nb, args, env) {
  const start = process.hrtime.bigint();
  const result = await execFileQuiet(nb, args, env);
  const end = process.hrtime.bigint();
  if (result.code !== 0) {
    throw new Error(`${nb} ${args.join(" ")} failed with ${result.code}: ${result.stderr.slice(0, 500)}`);
  }
  return { ms: Number(end - start) / 1_000_000 };
}

function execFileQuiet(command, args, env) {
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

function printHuman(result) {
  console.log(`nb info metadata benchmark (${result.iterations} iterations, ${result.warmup} warmup)`);
  console.log("token\tkind\tupstream_ms\thomebrew_ms\tdelta_ms\tspeedup");
  for (const row of result.rows) {
    console.log(`${row.token}\t${row.kind}\t${row.upstream_median_ms}\t${row.homebrew_median_ms}\t${row.delta_ms}\t${row.speedup}x`);
  }
}

main().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});
