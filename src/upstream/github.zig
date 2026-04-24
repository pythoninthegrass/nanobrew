// nanobrew — GitHub Releases upstream resolver
//
// Maps curated registry records onto the existing Cask install metadata so
// GitHub-hosted upstream assets can use nanobrew's native cask hot path.

const std = @import("std");
const builtin = @import("builtin");
const Cask = @import("../api/cask.zig").Cask;
const Artifact = @import("../api/cask.zig").Artifact;
const CaskSecurityWarning = @import("../api/cask.zig").SecurityWarning;
const fetch = @import("../net/fetch.zig");
const paths = @import("../platform/paths.zig");
const registry_mod = @import("registry.zig");

const API_CACHE_DIR = paths.API_CACHE_DIR;
const GITHUB_API_BASE = "https://api.github.com/repos/";
const CACHE_TTL_NS = 10 * 60 * std.time.ns_per_s;

const GithubAsset = struct {
    name: []const u8,
    url: []const u8,
    digest: []const u8,
};

pub fn fetchCask(alloc: std.mem.Allocator, token: []const u8) !Cask {
    const registry = try registry_mod.loadRegistry(alloc);
    defer registry.deinit(alloc);

    const record = registry.find(token, .cask) orelse return error.UpstreamRecordNotFound;
    return fetchCaskFromRecord(alloc, record);
}

pub fn fetchCaskFromRecord(alloc: std.mem.Allocator, record: *const registry_mod.Record) !Cask {
    if (record.kind != .cask) return error.UnsupportedKind;
    if (record.upstream.type != .github_release) return error.UnsupportedUpstreamType;

    if (record.resolved) |resolved| {
        const platform = currentPlatform() orelse return error.UnsupportedPlatform;
        if (resolved.findAsset(platform)) |asset| {
            return caskFromResolvedAsset(alloc, record, resolved.version, resolved.security_warnings, asset);
        }
    }

    const release_json = try fetchLatestReleaseJson(alloc, record.upstream.repo);
    defer alloc.free(release_json);
    return caskFromReleaseJson(alloc, record, release_json);
}

fn fetchLatestReleaseJson(alloc: std.mem.Allocator, repo: []const u8) ![]u8 {
    var cache_buf: [512]u8 = undefined;
    const cache_path = try githubReleaseCachePath(repo, &cache_buf);
    if (readCachedFile(alloc, cache_path)) |cached| return cached;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}/releases/latest", .{ GITHUB_API_BASE, repo }) catch return error.NameTooLong;

    const body = fetch.getWithHeaders(alloc, url, &.{
        .{ .name = "User-Agent", .value = "nanobrew-upstream-resolver" },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    }) catch return error.FetchFailed;
    errdefer alloc.free(body);

    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(io, API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(io, cache_path, .{})) |file| {
        defer file.close(io);
        file.writeStreamingAll(io, body) catch {};
    } else |_| {}

    return body;
}

fn caskFromReleaseJson(alloc: std.mem.Allocator, record: *const registry_mod.Record, release_json: []const u8) !Cask {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, release_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGithubRelease;

    const root = parsed.value.object;
    const tag_name = getStr(root, "tag_name") orelse return error.MissingField;
    const version = versionFromTag(tag_name);
    const assets_val = root.get("assets") orelse return error.MissingField;
    if (assets_val != .array) return error.MissingAsset;

    const asset_rule = selectCurrentPlatformAsset(record.assets) orelse return error.UnsupportedPlatform;
    const rendered_pattern = try renderPattern(alloc, asset_rule.pattern, tag_name, version);
    defer alloc.free(rendered_pattern);

    const asset = findGithubAsset(assets_val.array.items, rendered_pattern) orelse return error.MissingAsset;

    const sha256 = try sha256FromAssetDigest(alloc, record.verification, asset);
    errdefer alloc.free(sha256);
    defer alloc.free(sha256);

    return caskFromResolvedFields(alloc, record, version, asset.url, sha256, &.{});
}

fn caskFromResolvedAsset(
    alloc: std.mem.Allocator,
    record: *const registry_mod.Record,
    version: []const u8,
    warnings: []const registry_mod.SecurityWarning,
    asset: *const registry_mod.ResolvedAsset,
) !Cask {
    if (!isSha256Hex(asset.sha256)) return error.AssetDigestInvalid;
    return caskFromResolvedFields(alloc, record, version, asset.url, asset.sha256, warnings);
}

fn caskFromResolvedFields(
    alloc: std.mem.Allocator,
    record: *const registry_mod.Record,
    version: []const u8,
    url_value: []const u8,
    sha256_value: []const u8,
    warnings_value: []const registry_mod.SecurityWarning,
) !Cask {
    const token = try alloc.dupe(u8, record.token);
    errdefer alloc.free(token);
    const name = try alloc.dupe(u8, if (record.name.len > 0) record.name else record.token);
    errdefer alloc.free(name);
    const owned_version = try alloc.dupe(u8, version);
    errdefer alloc.free(owned_version);
    const url = try alloc.dupe(u8, url_value);
    errdefer alloc.free(url);
    const homepage = try alloc.dupe(u8, if (record.homepage.len > 0) record.homepage else record.upstream.homepage);
    errdefer alloc.free(homepage);
    const desc = try alloc.dupe(u8, record.desc);
    errdefer alloc.free(desc);
    const sha256 = try alloc.dupe(u8, sha256_value);
    errdefer alloc.free(sha256);
    const security_warnings = try caskSecurityWarningsFromRegistry(alloc, warnings_value);
    errdefer freeCaskSecurityWarnings(alloc, security_warnings);
    const artifacts = try caskArtifactsFromRecord(alloc, record.artifacts);
    errdefer {
        for (artifacts) |artifact| {
            switch (artifact) {
                .app => |app| alloc.free(app),
                .pkg => |pkg| alloc.free(pkg),
                .binary => |bin| {
                    alloc.free(bin.source);
                    alloc.free(bin.target);
                },
                .uninstall => |uninstall| {
                    alloc.free(uninstall.quit);
                    alloc.free(uninstall.pkgutil);
                },
            }
        }
        alloc.free(artifacts);
    }

    return .{
        .token = token,
        .name = name,
        .version = owned_version,
        .url = url,
        .sha256 = sha256,
        .homepage = homepage,
        .desc = desc,
        .auto_updates = record.auto_updates,
        .artifacts = artifacts,
        .min_macos = null,
        .metadata_source = .verified_upstream,
        .security_warnings = security_warnings,
    };
}

fn caskSecurityWarningsFromRegistry(
    alloc: std.mem.Allocator,
    warnings: []const registry_mod.SecurityWarning,
) ![]const CaskSecurityWarning {
    if (warnings.len == 0) return &.{};

    const out = try alloc.alloc(CaskSecurityWarning, warnings.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |warning| warning.deinit(alloc);
        alloc.free(out);
    }

    for (warnings) |warning| {
        out[initialized] = try dupeCaskSecurityWarning(alloc, warning);
        initialized += 1;
    }

    return out;
}

fn dupeCaskSecurityWarning(alloc: std.mem.Allocator, warning: registry_mod.SecurityWarning) !CaskSecurityWarning {
    const ghsa_id = try alloc.dupe(u8, warning.ghsa_id);
    errdefer alloc.free(ghsa_id);
    const cve_id = try alloc.dupe(u8, warning.cve_id);
    errdefer alloc.free(cve_id);
    const severity = try alloc.dupe(u8, warning.severity);
    errdefer alloc.free(severity);
    const summary = try alloc.dupe(u8, warning.summary);
    errdefer alloc.free(summary);
    const url = try alloc.dupe(u8, warning.url);
    errdefer alloc.free(url);
    const affected_versions = try alloc.dupe(u8, warning.affected_versions);
    errdefer alloc.free(affected_versions);
    const patched_versions = try alloc.dupe(u8, warning.patched_versions);
    errdefer alloc.free(patched_versions);

    return .{
        .ghsa_id = ghsa_id,
        .cve_id = cve_id,
        .severity = severity,
        .summary = summary,
        .url = url,
        .affected_versions = affected_versions,
        .patched_versions = patched_versions,
    };
}

fn freeCaskSecurityWarnings(alloc: std.mem.Allocator, warnings: []const CaskSecurityWarning) void {
    for (warnings) |warning| warning.deinit(alloc);
    if (warnings.len > 0) alloc.free(warnings);
}

fn findGithubAsset(items: []const std.json.Value, pattern: []const u8) ?GithubAsset {
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const name = getStr(obj, "name") orelse continue;
        if (!globMatch(pattern, name)) continue;
        return .{
            .name = name,
            .url = getStr(obj, "browser_download_url") orelse continue,
            .digest = getStr(obj, "digest") orelse "",
        };
    }
    return null;
}

fn sha256FromAssetDigest(alloc: std.mem.Allocator, verification: registry_mod.Verification, asset: GithubAsset) ![]const u8 {
    return switch (verification.sha256) {
        .asset_digest, .asset_or_sidecar, .required => blk: {
            const prefix = "sha256:";
            if (!std.mem.startsWith(u8, asset.digest, prefix)) return error.AssetDigestMissing;
            const hex = asset.digest[prefix.len..];
            if (!isSha256Hex(hex)) return error.AssetDigestInvalid;
            break :blk try alloc.dupe(u8, hex);
        },
        .no_check, .required_or_no_check_with_reason => try alloc.dupe(u8, "no_check"),
    };
}

fn caskArtifactsFromRecord(alloc: std.mem.Allocator, rules: []const registry_mod.ArtifactRule) ![]const Artifact {
    var artifacts: std.ArrayList(Artifact) = .empty;
    defer artifacts.deinit(alloc);
    errdefer {
        for (artifacts.items) |artifact| {
            switch (artifact) {
                .app => |app| alloc.free(app),
                .pkg => |pkg| alloc.free(pkg),
                .binary => |bin| {
                    alloc.free(bin.source);
                    alloc.free(bin.target);
                },
                .uninstall => |uninstall| {
                    alloc.free(uninstall.quit);
                    alloc.free(uninstall.pkgutil);
                },
            }
        }
    }

    for (rules) |rule| {
        switch (rule.type) {
            .app => try artifacts.append(alloc, .{ .app = try alloc.dupe(u8, rule.path) }),
            .pkg => try artifacts.append(alloc, .{ .pkg = try alloc.dupe(u8, rule.path) }),
            .binary => {
                const source = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(source);
                const target = try alloc.dupe(u8, std.fs.path.basename(rule.path));
                errdefer alloc.free(target);
                try artifacts.append(alloc, .{ .binary = .{ .source = source, .target = target } });
            },
        }
    }

    return artifacts.toOwnedSlice(alloc);
}

fn selectCurrentPlatformAsset(assets: []const registry_mod.AssetRule) ?registry_mod.AssetRule {
    const platform = currentPlatform() orelse return null;

    for (assets) |asset| {
        if (asset.platform == platform) return asset;
    }
    return null;
}

fn currentPlatform() ?registry_mod.Platform {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .macos_arm64,
            .x86_64 => .macos_x86_64,
            else => return null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .linux_x86_64,
            .aarch64 => .linux_aarch64,
            else => return null,
        },
        else => return null,
    };
}

fn renderPattern(alloc: std.mem.Allocator, pattern: []const u8, tag: []const u8, version: []const u8) ![]u8 {
    const with_tag = try std.mem.replaceOwned(u8, alloc, pattern, "{tag}", tag);
    defer alloc.free(with_tag);
    return std.mem.replaceOwned(u8, alloc, with_tag, "{version}", version);
}

fn versionFromTag(tag: []const u8) []const u8 {
    if (tag.len > 1 and (tag[0] == 'v' or tag[0] == 'V') and std.ascii.isDigit(tag[1])) {
        return tag[1..];
    }
    return tag;
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var star_value: usize = 0;

    while (v < value.len) {
        if (p < pattern.len and (pattern[p] == value[v])) {
            p += 1;
            v += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            star_value = v;
        } else if (star) |s| {
            p = s + 1;
            star_value += 1;
            v = star_value;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return false;
    }
    return true;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn githubReleaseCachePath(repo: []const u8, buf: []u8) ![]const u8 {
    var safe: [256]u8 = undefined;
    if (repo.len > safe.len) return error.NameTooLong;
    for (repo, 0..) |c, i| safe[i] = if (c == '/') '-' else c;
    return std.fmt.bufPrint(buf, "{s}/github-release-{s}.json", .{ API_CACHE_DIR, safe[0..repo.len] });
}

fn readCachedFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    const now_ts = std.Io.Timestamp.now(io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > CACHE_TTL_NS) return null;
    const sz = @min(st.size, 4 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

const testing = std.testing;

test "versionFromTag strips common v prefix" {
    try testing.expectEqualStrings("10.12.0", versionFromTag("v10.12.0"));
    try testing.expectEqualStrings("release-20250829", versionFromTag("release-20250829"));
}

test "globMatch supports wildcard asset patterns" {
    try testing.expect(globMatch("86Box-macOS-x86_64+arm64-b*.zip", "86Box-macOS-x86_64+arm64-b8200.zip"));
    try testing.expect(!globMatch("AltTab-*.zip", "AltTab.app.dSYM.zip"));
}

test "caskFromReleaseJson maps GitHub release asset to Cask" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "alt-tab",
        \\    "name": "AltTab",
        \\    "kind": "cask",
        \\    "homepage": "https://alt-tab.app/",
        \\    "desc": "Enable Windows-like alt-tab",
        \\    "auto_updates": true,
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "lwouis/alt-tab-macos",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "AltTab-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "AltTab-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "AltTab.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const release_json =
        \\{
        \\  "tag_name": "v10.12.0",
        \\  "assets": [
        \\    {
        \\      "name": "AltTab-10.12.0.zip",
        \\      "browser_download_url": "https://github.com/lwouis/alt-tab-macos/releases/download/v10.12.0/AltTab-10.12.0.zip",
        \\      "digest": "sha256:e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14"
        \\    }
        \\  ]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("alt-tab", .cask).?;
    const cask = try caskFromReleaseJson(testing.allocator, record, release_json);
    defer cask.deinit(testing.allocator);

    try testing.expectEqualStrings("alt-tab", cask.token);
    try testing.expectEqualStrings("AltTab", cask.name);
    try testing.expectEqualStrings("10.12.0", cask.version);
    try testing.expectEqualStrings("e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14", cask.sha256);
    try testing.expectEqual(@as(usize, 1), cask.artifacts.len);
    try testing.expectEqualStrings("AltTab.app", cask.artifacts[0].app);
}

test "caskFromReleaseJson requires asset digest for verified casks" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "missing-digest",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/repo",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "App-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "App-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "App.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const release_json =
        \\{
        \\  "tag_name": "v1.0.0",
        \\  "assets": [
        \\    {
        \\      "name": "App-1.0.0.zip",
        \\      "browser_download_url": "https://github.com/owner/repo/releases/download/v1.0.0/App-1.0.0.zip",
        \\      "digest": null
        \\    }
        \\  ]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("missing-digest", .cask).?;
    try testing.expectError(error.AssetDigestMissing, caskFromReleaseJson(testing.allocator, record, release_json));
}
