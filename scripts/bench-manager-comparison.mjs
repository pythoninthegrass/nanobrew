#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { writeFileSync } from "node:fs";

const DEFAULT_TOKEN = "yt-dlp";

function usage() {
  process.stderr.write(`Usage: scripts/bench-manager-comparison.mjs [options]

Benchmark one formula across current nanobrew, previous nanobrew, Homebrew, and zerobrew.

Options:
  --token NAME              Formula token to benchmark (default: ${DEFAULT_TOKEN})
  --iterations N            Already-installed no-op runs per manager (default: 5)
  --nb-current PATH         Current nanobrew binary
  --nb-previous PATH        Previous nanobrew binary
  --zerobrew PATH           zerobrew binary
  --zerobrew-root PATH      Isolated zerobrew root (default: /tmp/zbr)
  --zerobrew-prefix PATH    Isolated zerobrew prefix (default: /tmp/zbp)
  --json-out PATH           Write JSON result to this path
  --json                    Print JSON to stdout instead of a text table
  --allow-opt-reset         Required: allows resetting /opt/nanobrew
  --allow-homebrew-reset    Required: allows installing/uninstalling the token with Homebrew
`);
}

const opts = {
  token: DEFAULT_TOKEN,
  iterations: 5,
  nbCurrent: "./zig-out/bin/nb",
  nbPrevious: "",
  zerobrew: "",
  zerobrewRoot: "/tmp/zbr",
  zerobrewPrefix: "/tmp/zbp",
  jsonOut: "",
  json: false,
  allowOptReset: false,
  allowHomebrewReset: false,
};

const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === "--help" || arg === "-h") {
    usage();
    process.exit(0);
  } else if (arg === "--token") {
    opts.token = argv[++i] ?? "";
  } else if (arg.startsWith("--token=")) {
    opts.token = arg.slice("--token=".length);
  } else if (arg === "--iterations") {
    opts.iterations = Number(argv[++i] ?? "");
  } else if (arg.startsWith("--iterations=")) {
    opts.iterations = Number(arg.slice("--iterations=".length));
  } else if (arg === "--nb-current") {
    opts.nbCurrent = argv[++i] ?? "";
  } else if (arg.startsWith("--nb-current=")) {
    opts.nbCurrent = arg.slice("--nb-current=".length);
  } else if (arg === "--nb-previous") {
    opts.nbPrevious = argv[++i] ?? "";
  } else if (arg.startsWith("--nb-previous=")) {
    opts.nbPrevious = arg.slice("--nb-previous=".length);
  } else if (arg === "--zerobrew") {
    opts.zerobrew = argv[++i] ?? "";
  } else if (arg.startsWith("--zerobrew=")) {
    opts.zerobrew = arg.slice("--zerobrew=".length);
  } else if (arg === "--zerobrew-root") {
    opts.zerobrewRoot = argv[++i] ?? "";
  } else if (arg.startsWith("--zerobrew-root=")) {
    opts.zerobrewRoot = arg.slice("--zerobrew-root=".length);
  } else if (arg === "--zerobrew-prefix") {
    opts.zerobrewPrefix = argv[++i] ?? "";
  } else if (arg.startsWith("--zerobrew-prefix=")) {
    opts.zerobrewPrefix = arg.slice("--zerobrew-prefix=".length);
  } else if (arg === "--json-out") {
    opts.jsonOut = argv[++i] ?? "";
  } else if (arg.startsWith("--json-out=")) {
    opts.jsonOut = arg.slice("--json-out=".length);
  } else if (arg === "--json") {
    opts.json = true;
  } else if (arg === "--allow-opt-reset") {
    opts.allowOptReset = true;
  } else if (arg === "--allow-homebrew-reset") {
    opts.allowHomebrewReset = true;
  } else {
    die(`unknown option: ${arg}`);
  }
}

if (!opts.token) die("--token must not be empty");
if (!Number.isInteger(opts.iterations) || opts.iterations < 1) die("--iterations must be a positive integer");
if (!opts.allowOptReset) die("--allow-opt-reset is required because this resets /opt/nanobrew");
if (!opts.allowHomebrewReset) die("--allow-homebrew-reset is required because this installs/uninstalls with Homebrew");

const rows = [];

rows.push(benchNanobrew({
  label: "nanobrew current",
  version: nanobrewVersion(opts.nbCurrent),
  nb: opts.nbCurrent,
  installArgs: ["install", "--shims", opts.token],
}));

if (opts.nbPrevious) {
  rows.push(benchNanobrew({
    label: "nanobrew previous",
    version: nanobrewVersion(opts.nbPrevious),
    nb: opts.nbPrevious,
    installArgs: ["install", opts.token],
  }));
}

rows.push(benchHomebrew());

if (opts.zerobrew) {
  rows.push(benchZerobrew());
}

const current = rows.find((row) => row.manager === "nanobrew current");
for (const row of rows) {
  row.current_speedup_target_reinstall = speedup(row.target_reinstall_ms, current?.target_reinstall_ms);
  row.current_speedup_noop = speedup(row.noop_median_ms, current?.noop_median_ms);
}

const result = {
  token: opts.token,
  iterations: opts.iterations,
  generated_at: new Date().toISOString(),
  notes: [
    "Target reinstall means dependencies and cache/store are already primed, then only the requested formula is removed and installed again.",
    "No-op means the requested formula is already installed and the install command is run again.",
    "Current nanobrew uses --shims for the requested formula; dependency executables stay private.",
  ],
  rows,
};

if (opts.jsonOut) writeFileSync(opts.jsonOut, `${JSON.stringify(result, null, 2)}\n`);
if (opts.json) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  printTable(result);
}

function benchNanobrew({ label, version, nb, installArgs }) {
  resetNanobrewRoot(nb);
  run(nb, installArgs, { env: nanobrewEnv(), label: `${label} prime install` });
  run(nb, ["remove", opts.token], { env: nanobrewEnv(), label: `${label} remove target` });
  const targetReinstall = timed(nb, installArgs, { env: nanobrewEnv(), label: `${label} target reinstall` });
  const noopRuns = [];
  for (let i = 0; i < opts.iterations; i += 1) {
    noopRuns.push(timed(nb, installArgs, { env: nanobrewEnv(), label: `${label} noop ${i + 1}` }).ms);
  }
  verifyNanobrewShim(label);
  return row(label, version, targetReinstall.ms, noopRuns);
}

function benchHomebrew() {
  const env = homebrewEnv();
  run("brew", ["install", opts.token], { env, label: "Homebrew prime install" });
  run("brew", ["uninstall", "--ignore-dependencies", "--force", opts.token], { env, label: "Homebrew remove target" });
  const targetReinstall = timed("brew", ["install", opts.token], { env, label: "Homebrew target reinstall" });
  const noopRuns = [];
  for (let i = 0; i < opts.iterations; i += 1) {
    noopRuns.push(timed("brew", ["install", opts.token], { env, label: `Homebrew noop ${i + 1}` }).ms);
  }
  return row("Homebrew", versionOf("brew", ["--version"]).split("\n")[0], targetReinstall.ms, noopRuns);
}

function benchZerobrew() {
  const env = { ...process.env };
  run("rm", ["-rf", opts.zerobrewRoot, opts.zerobrewPrefix], { label: "reset zerobrew root" });
  const baseArgs = ["--root", opts.zerobrewRoot, "--prefix", opts.zerobrewPrefix];
  run(opts.zerobrew, [...baseArgs, "init", "--no-modify-path"], { env, label: "zerobrew init" });
  run(opts.zerobrew, [...baseArgs, "install", opts.token], { env, label: "zerobrew prime install" });
  run(opts.zerobrew, [...baseArgs, "uninstall", opts.token], { env, label: "zerobrew remove target" });
  const targetReinstall = timed(opts.zerobrew, [...baseArgs, "install", opts.token], { env, label: "zerobrew target reinstall" });
  const noopRuns = [];
  for (let i = 0; i < opts.iterations; i += 1) {
    noopRuns.push(timed(opts.zerobrew, [...baseArgs, "install", opts.token], { env, label: `zerobrew noop ${i + 1}` }).ms);
  }
  return row("zerobrew", versionOf(opts.zerobrew, ["--version"]), targetReinstall.ms, noopRuns);
}

function resetNanobrewRoot(nb) {
  run("sudo", ["rm", "-rf", "/opt/nanobrew"], { label: "reset /opt/nanobrew" });
  run("sudo", ["mkdir", "-p", "/opt/nanobrew"], { label: "create /opt/nanobrew" });
  run("sudo", ["chown", "-R", `${process.env.USER ?? "runner"}`, "/opt/nanobrew"], { label: "chown /opt/nanobrew" });
  run(nb, ["init"], { env: nanobrewEnv(), label: "nanobrew init" });
}

function verifyNanobrewShim(label) {
  if (label !== "nanobrew current") return;
  const deno = spawnSync("test", ["-e", "/opt/nanobrew/prefix/bin/deno"], { stdio: "ignore" });
  if (deno.status === 0) die("current nanobrew shim mode exposed deno in prefix/bin");
  const python = spawnSync("test", ["-e", "/opt/nanobrew/prefix/bin/python3.14"], { stdio: "ignore" });
  if (python.status === 0) die("current nanobrew shim mode exposed python3.14 in prefix/bin");
  run("/opt/nanobrew/prefix/bin/yt-dlp", ["--version"], { env: nanobrewEnv(), label: "current yt-dlp shim smoke" });
}

function timed(cmd, args, { env, label }) {
  const start = performance.now();
  const result = run(cmd, args, { env, label });
  return { ms: round(performance.now() - start), stdout: result.stdout, stderr: result.stderr };
}

function run(cmd, args, { env = process.env, label = cmd } = {}) {
  const result = spawnSync(cmd, args, {
    env,
    encoding: "utf8",
    maxBuffer: 1024 * 1024 * 32,
  });
  if (result.status !== 0) {
    process.stderr.write(`\n${label} failed: ${cmd} ${args.join(" ")}\n`);
    if (result.stdout) process.stderr.write(`stdout:\n${result.stdout}\n`);
    if (result.stderr) process.stderr.write(`stderr:\n${result.stderr}\n`);
    process.exit(result.status ?? 1);
  }
  return result;
}

function versionOf(cmd, args) {
  const result = spawnSync(cmd, args, { encoding: "utf8" });
  if (result.status !== 0) return "";
  return `${result.stdout}${result.stderr}`.trim();
}

function nanobrewVersion(nb) {
  const direct = versionOf(nb, ["--version"]);
  if (direct) return direct;

  const help = versionOf(nb, ["help"]).replace(/\x1b\[[0-9;]*m/g, "");
  const firstLine = help.split("\n").find((line) => line.trim().length > 0) ?? "";
  const match = firstLine.match(/nanobrew\s+(v[^\s]+)/);
  return match?.[1] ?? "";
}

function nanobrewEnv() {
  return {
    ...process.env,
    NANOBREW_NO_TELEMETRY: "1",
  };
}

function homebrewEnv() {
  return {
    ...process.env,
    HOMEBREW_NO_AUTO_UPDATE: "1",
    HOMEBREW_NO_INSTALL_CLEANUP: "1",
    HOMEBREW_NO_ENV_HINTS: "1",
  };
}

function row(manager, version, targetReinstallMs, noopRuns) {
  return {
    manager,
    version,
    target_reinstall_ms: round(targetReinstallMs),
    noop_median_ms: round(median(noopRuns)),
    noop_runs_ms: noopRuns.map(round),
  };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[mid]
    : (sorted[mid - 1] + sorted[mid]) / 2;
}

function speedup(otherMs, currentMs) {
  if (!Number.isFinite(otherMs) || !Number.isFinite(currentMs) || currentMs <= 0) return null;
  return Number((otherMs / currentMs).toFixed(2));
}

function round(value) {
  return Number(value.toFixed(1));
}

function printTable(result) {
  process.stdout.write(`Manager comparison for ${result.token}\n\n`);
  process.stdout.write("| manager | target reinstall | no-op median | speedup vs current reinstall | speedup vs current no-op |\n");
  process.stdout.write("|---|---:|---:|---:|---:|\n");
  for (const item of result.rows) {
    process.stdout.write(`| ${item.manager} | ${item.target_reinstall_ms}ms | ${item.noop_median_ms}ms | ${formatSpeedup(item.current_speedup_target_reinstall)} | ${formatSpeedup(item.current_speedup_noop)} |\n`);
  }
}

function formatSpeedup(value) {
  return Number.isFinite(value) ? `${value}x` : "";
}

function die(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}
