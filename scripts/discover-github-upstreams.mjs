#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const FORMULA_URL = "https://formulae.brew.sh/api/formula.json";
const CASK_URL = "https://formulae.brew.sh/api/cask.json";

function parseArgs(argv) {
  const opts = {
    kind: "all",
    limit: 25,
    json: false,
    formulaFile: null,
    caskFile: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") {
      opts.json = true;
    } else if (arg === "--kind") {
      opts.kind = argv[++i] ?? "";
    } else if (arg.startsWith("--kind=")) {
      opts.kind = arg.slice("--kind=".length);
    } else if (arg === "--limit") {
      opts.limit = Number.parseInt(argv[++i] ?? "", 10);
    } else if (arg.startsWith("--limit=")) {
      opts.limit = Number.parseInt(arg.slice("--limit=".length), 10);
    } else if (arg === "--formula-file") {
      opts.formulaFile = argv[++i] ?? null;
    } else if (arg.startsWith("--formula-file=")) {
      opts.formulaFile = arg.slice("--formula-file=".length);
    } else if (arg === "--cask-file") {
      opts.caskFile = argv[++i] ?? null;
    } else if (arg.startsWith("--cask-file=")) {
      opts.caskFile = arg.slice("--cask-file=".length);
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(1);
    }
  }

  if (!["all", "formula", "cask"].includes(opts.kind)) {
    console.error("--kind must be one of: all, formula, cask");
    process.exit(1);
  }
  if (!Number.isInteger(opts.limit) || opts.limit < 0) {
    console.error("--limit must be a non-negative integer");
    process.exit(1);
  }

  return opts;
}

function usage(code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`Usage: scripts/discover-github-upstreams.mjs [options]

Find Homebrew formula/cask metadata whose upstream download URL is native to GitHub.

Options:
  --kind all|formula|cask   Scan both indexes or only one kind (default: all)
  --limit N                 Candidate rows to print per class (default: 25)
  --json                    Emit machine-readable JSON
  --formula-file PATH       Read formula.json from disk instead of fetching
  --cask-file PATH          Read cask.json from disk instead of fetching
  -h, --help                Show this help
`);
  process.exit(code);
}

async function loadJson(sourceUrl, filePath) {
  if (filePath) {
    return JSON.parse(await readFile(filePath, "utf8"));
  }

  const response = await fetch(sourceUrl, {
    headers: {
      "accept": "application/json",
      "user-agent": "nanobrew-github-upstream-discovery",
    },
  });
  if (!response.ok) {
    throw new Error(`fetch failed for ${sourceUrl}: HTTP ${response.status}`);
  }
  return response.json();
}

function githubParts(value) {
  if (typeof value !== "string") return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.hostname !== "github.com") return null;

  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 2) return null;
  const [owner, rawRepo] = parts;
  const isGitRepoUrl = rawRepo.endsWith(".git") && parts.length === 2;
  const repo = rawRepo.endsWith(".git") ? rawRepo.slice(0, -".git".length) : rawRepo;
  const rest = parts.slice(2);
  return {
    owner,
    repo,
    fullName: `${owner}/${repo}`,
    rest,
    isGitRepoUrl,
    url: value,
  };
}

function githubUrlClass(parts) {
  if (!parts) return null;
  if (parts.rest[0] === "releases" && parts.rest[1] === "download") {
    return "github_release_asset";
  }
  if (parts.rest[0] === "archive") {
    return "github_archive_source";
  }
  if (parts.isGitRepoUrl) {
    return "github_git_repo_source";
  }
  return "github_other";
}

function releaseTag(parts) {
  if (!parts || parts.rest[0] !== "releases" || parts.rest[1] !== "download") return "";
  return parts.rest[2] ?? "";
}

function archiveTag(parts) {
  if (!parts || parts.rest[0] !== "archive") return "";
  if (parts.rest[1] === "refs" && parts.rest[2] === "tags") {
    return stripKnownArchiveExtension(parts.rest.slice(3).join("/"));
  }
  return stripKnownArchiveExtension(parts.rest.slice(1).join("/"));
}

function stripKnownArchiveExtension(value) {
  for (const suffix of [".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".zip"]) {
    if (value.endsWith(suffix)) return value.slice(0, -suffix.length);
  }
  return value;
}

function isSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}

function formulaCandidates(formulae) {
  const candidates = [];
  const summary = {
    total: formulae.length,
    github_source: 0,
    github_release_asset: 0,
    github_archive_source: 0,
    github_git_repo_source: 0,
    github_other: 0,
    github_source_with_sha256: 0,
  };

  for (const formula of formulae) {
    const sourceUrl = formula?.urls?.stable?.url;
    const parts = githubParts(sourceUrl);
    if (!parts) continue;

    const sourceClass = githubUrlClass(parts);
    summary.github_source += 1;
    summary[sourceClass] += 1;
    const checksum = formula?.urls?.stable?.checksum ?? "";
    if (isSha256(checksum)) summary.github_source_with_sha256 += 1;

    if (sourceClass !== "github_release_asset" && sourceClass !== "github_archive_source") {
      continue;
    }

    candidates.push({
      kind: "formula",
      token: formula.name,
      version: formula?.versions?.stable ?? "",
      repo: parts.fullName,
      source_class: sourceClass,
      release_tag: sourceClass === "github_release_asset" ? releaseTag(parts) : archiveTag(parts),
      url: sourceUrl,
      verification: isSha256(checksum) ? "homebrew_sha256" : "missing_sha256",
      sha256: checksum,
      note: sourceClass === "github_archive_source"
        ? "source archive; useful for repo/tag allowlist, not a direct binary install"
        : "release asset; inspect GitHub release assets before promoting",
    });
  }

  return { summary, candidates };
}

function caskCandidates(casks) {
  const candidates = [];
  const summary = {
    total: casks.length,
    github_release_asset: 0,
    github_release_with_sha256: 0,
    github_release_no_check: 0,
    github_release_with_install_artifact: 0,
  };

  for (const cask of casks) {
    const parts = githubParts(cask?.url);
    if (githubUrlClass(parts) !== "github_release_asset") continue;

    summary.github_release_asset += 1;
    if (isSha256(cask.sha256)) summary.github_release_with_sha256 += 1;
    if (cask.sha256 === "no_check") summary.github_release_no_check += 1;

    const artifacts = installArtifacts(cask.artifacts ?? []);
    if (artifacts.length > 0) summary.github_release_with_install_artifact += 1;

    candidates.push({
      kind: "cask",
      token: cask.token,
      version: cask.version ?? "",
      repo: parts.fullName,
      source_class: "github_release_asset",
      release_tag: releaseTag(parts),
      url: cask.url,
      verification: isSha256(cask.sha256) ? "homebrew_sha256" : cask.sha256 === "no_check" ? "homebrew_no_check" : "missing_sha256",
      sha256: cask.sha256 ?? "",
      artifacts,
      note: artifacts.length > 0
        ? "direct cask candidate; has GitHub release URL and install artifact"
        : "download candidate, but artifact mapping needs cask parser support",
    });
  }

  return { summary, candidates };
}

function installArtifacts(artifacts) {
  const out = [];
  for (const item of artifacts) {
    if (!item || typeof item !== "object") continue;
    for (const key of ["app", "pkg", "binary"]) {
      if (!Object.hasOwn(item, key)) continue;
      const value = item[key];
      if (!Array.isArray(value)) continue;
      for (const entry of value) {
        if (typeof entry === "string") {
          out.push({ type: key, path: entry });
        }
      }
    }
  }
  return out;
}

function takeUsefulCandidates(candidates, limit) {
  return candidates
    .filter((candidate) => candidate.verification === "homebrew_sha256")
    .sort((a, b) => {
      if (a.kind !== b.kind) return a.kind.localeCompare(b.kind);
      if (a.source_class !== b.source_class) return a.source_class.localeCompare(b.source_class);
      return a.token.localeCompare(b.token);
    })
    .slice(0, limit);
}

function printText(result, limit) {
  console.log("Homebrew GitHub-native upstream discovery");
  console.log(`Generated: ${result.generated_at}`);
  console.log(`Sources: ${FORMULA_URL}, ${CASK_URL}`);
  console.log("");
  if (result.summary.formula) {
    const s = result.summary.formula;
    console.log("Formulae:");
    console.log(`  total records: ${s.total}`);
    console.log(`  GitHub stable source URLs: ${s.github_source}`);
    console.log(`  GitHub release asset sources: ${s.github_release_asset}`);
    console.log(`  GitHub archive sources: ${s.github_archive_source}`);
    console.log(`  GitHub git repository sources: ${s.github_git_repo_source}`);
    console.log(`  Other GitHub stable source URLs: ${s.github_other}`);
    console.log(`  GitHub source URLs with SHA256: ${s.github_source_with_sha256}`);
    console.log("");
  }
  if (result.summary.cask) {
    const s = result.summary.cask;
    console.log("Casks:");
    console.log(`  total records: ${s.total}`);
    console.log(`  GitHub release asset URLs: ${s.github_release_asset}`);
    console.log(`  GitHub release URLs with SHA256: ${s.github_release_with_sha256}`);
    console.log(`  GitHub release URLs with no_check: ${s.github_release_no_check}`);
    console.log(`  GitHub release URLs with app/pkg/binary artifact: ${s.github_release_with_install_artifact}`);
    console.log("");
  }

  for (const [label, candidates] of Object.entries(result.candidates)) {
    if (candidates.length === 0) continue;
    console.log(`${label} candidates (${Math.min(limit, candidates.length)} shown):`);
    for (const candidate of candidates.slice(0, limit)) {
      const tag = candidate.release_tag ? ` tag=${candidate.release_tag}` : "";
      const artifact = candidate.artifacts?.[0] ? ` artifact=${candidate.artifacts[0].type}:${candidate.artifacts[0].path}` : "";
      console.log(`  ${candidate.kind}:${candidate.token} repo=${candidate.repo}${tag} verification=${candidate.verification}${artifact}`);
      console.log(`    ${candidate.url}`);
    }
    console.log("");
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const summary = {};
  const candidates = {};

  if (opts.kind === "all" || opts.kind === "formula") {
    const formulae = await loadJson(FORMULA_URL, opts.formulaFile);
    const formula = formulaCandidates(formulae);
    summary.formula = formula.summary;
    candidates.formula = takeUsefulCandidates(formula.candidates, opts.limit);
  }

  if (opts.kind === "all" || opts.kind === "cask") {
    const casks = await loadJson(CASK_URL, opts.caskFile);
    const cask = caskCandidates(casks);
    summary.cask = cask.summary;
    candidates.cask = takeUsefulCandidates(cask.candidates, opts.limit);
  }

  const result = {
    generated_at: new Date().toISOString(),
    sources: {
      formula: FORMULA_URL,
      cask: CASK_URL,
    },
    summary,
    candidates,
  };

  if (opts.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    printText(result, opts.limit);
  }
}

main().catch((err) => {
  console.error(err.stack || String(err));
  process.exit(1);
});
