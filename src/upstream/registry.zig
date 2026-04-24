// nanobrew — verified upstream release registry
//
// Parses the curated registry used by the future direct-upstream resolver.

const std = @import("std");
const flate = std.compress.flate;

pub const DEFAULT_REGISTRY_PATH = "registry/upstream.json";
pub const DEFAULT_REGISTRY_JSON = @embedFile("registry_default.json");
pub const DEFAULT_REMOTE_REGISTRY_URL = "https://raw.githubusercontent.com/justrach/nanobrew/main/registry/upstream.json";
pub const DEFAULT_REGISTRY_CACHE_PATH = "/opt/nanobrew/cache/api/upstream-registry.json";
pub const DEFAULT_REGISTRY_CACHE_TTL_NS: i96 = 6 * 3600 * std.time.ns_per_s;

const MAX_REGISTRY_JSON_BYTES = 8 * 1024 * 1024;

pub const LoadOptions = struct {
    cache_path: []const u8 = DEFAULT_REGISTRY_CACHE_PATH,
    remote_url: []const u8 = DEFAULT_REMOTE_REGISTRY_URL,
    allow_remote: bool = true,
    cache_ttl_ns: i96 = DEFAULT_REGISTRY_CACHE_TTL_NS,
};

const CachedRegistryJson = struct {
    data: []u8,
    fresh: bool,
};

pub const Kind = enum {
    formula,
    cask,
};

pub const UpstreamType = enum {
    github_release,
    vendor_url,
};

pub const Platform = enum {
    macos_arm64,
    macos_x86_64,
    linux_x86_64,
    linux_aarch64,
};

pub const ArtifactKind = enum {
    app,
    pkg,
    binary,
};

pub const Sha256Mode = enum {
    asset_or_sidecar,
    asset_digest,
    required,
    required_or_no_check_with_reason,
    no_check,
};

pub const RequirementMode = enum {
    none,
    optional,
    required,
};

pub const Upstream = struct {
    type: UpstreamType,
    repo: []const u8,
    homepage: []const u8,
    release_feed: []const u8,
    allow_domains: []const []const u8,
    verified: bool,

    pub fn deinit(self: Upstream, alloc: std.mem.Allocator) void {
        alloc.free(self.repo);
        alloc.free(self.homepage);
        alloc.free(self.release_feed);
        for (self.allow_domains) |domain| alloc.free(domain);
        alloc.free(self.allow_domains);
    }
};

pub const AssetRule = struct {
    platform: Platform,
    pattern: []const u8,
    strip_components: u32,

    pub fn deinit(self: AssetRule, alloc: std.mem.Allocator) void {
        alloc.free(self.pattern);
    }
};

pub const ArtifactRule = struct {
    type: ArtifactKind,
    path: []const u8,

    pub fn deinit(self: ArtifactRule, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

pub const ResolvedAsset = struct {
    platform: Platform,
    url: []const u8,
    sha256: []const u8,

    pub fn deinit(self: ResolvedAsset, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.sha256);
    }
};

pub const SecurityWarning = struct {
    ghsa_id: []const u8,
    cve_id: []const u8,
    severity: []const u8,
    summary: []const u8,
    url: []const u8,
    affected_versions: []const u8,
    patched_versions: []const u8,

    pub fn deinit(self: SecurityWarning, alloc: std.mem.Allocator) void {
        alloc.free(self.ghsa_id);
        alloc.free(self.cve_id);
        alloc.free(self.severity);
        alloc.free(self.summary);
        alloc.free(self.url);
        alloc.free(self.affected_versions);
        alloc.free(self.patched_versions);
    }
};

pub const Resolved = struct {
    tag: []const u8,
    version: []const u8,
    assets: []const ResolvedAsset,
    security_warnings: []const SecurityWarning,

    pub fn deinit(self: Resolved, alloc: std.mem.Allocator) void {
        alloc.free(self.tag);
        alloc.free(self.version);
        for (self.assets) |asset| asset.deinit(alloc);
        alloc.free(self.assets);
        for (self.security_warnings) |warning| warning.deinit(alloc);
        alloc.free(self.security_warnings);
    }

    pub fn findAsset(self: *const Resolved, platform: Platform) ?*const ResolvedAsset {
        for (self.assets, 0..) |asset, i| {
            if (asset.platform == platform) return &self.assets[i];
        }
        return null;
    }
};

pub const Verification = struct {
    sha256: Sha256Mode,
    signature: RequirementMode,
    attestation: RequirementMode,
    no_check_reason: []const u8,

    pub fn deinit(self: Verification, alloc: std.mem.Allocator) void {
        alloc.free(self.no_check_reason);
    }
};

pub const Record = struct {
    token: []const u8,
    name: []const u8,
    desc: []const u8,
    homepage: []const u8,
    auto_updates: bool,
    kind: Kind,
    upstream: Upstream,
    assets: []const AssetRule,
    artifacts: []const ArtifactRule,
    resolved: ?Resolved,
    verification: Verification,

    pub fn deinit(self: Record, alloc: std.mem.Allocator) void {
        alloc.free(self.token);
        alloc.free(self.name);
        alloc.free(self.desc);
        alloc.free(self.homepage);
        self.upstream.deinit(alloc);
        for (self.assets) |asset| asset.deinit(alloc);
        alloc.free(self.assets);
        for (self.artifacts) |artifact| artifact.deinit(alloc);
        alloc.free(self.artifacts);
        if (self.resolved) |resolved| resolved.deinit(alloc);
        self.verification.deinit(alloc);
    }
};

pub const Registry = struct {
    schema_version: u32,
    records: []const Record,

    pub fn deinit(self: Registry, alloc: std.mem.Allocator) void {
        for (self.records) |record| record.deinit(alloc);
        alloc.free(self.records);
    }

    pub fn find(self: *const Registry, token: []const u8, kind: Kind) ?*const Record {
        for (self.records, 0..) |record, i| {
            if (record.kind == kind and std.mem.eql(u8, record.token, token)) {
                return &self.records[i];
            }
        }
        return null;
    }
};

pub fn loadRegistry(alloc: std.mem.Allocator) !Registry {
    var options: LoadOptions = .{};
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_CACHE")) |cache_path| {
        if (cache_path.len > 0) options.cache_path = cache_path;
    }
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_URL")) |remote_url| {
        options.remote_url = remote_url;
    }
    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE") != null) {
        options.allow_remote = false;
    }
    if (options.remote_url.len == 0) {
        options.allow_remote = false;
    }
    return loadRegistryWithOptions(alloc, options);
}

pub fn loadRegistryWithOptions(alloc: std.mem.Allocator, options: LoadOptions) !Registry {
    var stale_registry: ?Registry = null;
    errdefer if (stale_registry) |registry| registry.deinit(alloc);

    if (readRegistryCache(alloc, options.cache_path, options.cache_ttl_ns)) |cached_json| {
        defer alloc.free(cached_json.data);
        if (parseRegistry(alloc, cached_json.data)) |registry| {
            if (cached_json.fresh) return registry;
            stale_registry = registry;
        } else |_| {}
    }

    if (options.allow_remote and options.remote_url.len > 0) {
        if (fetchRemoteRegistryJson(alloc, options.remote_url)) |remote_json| {
            defer alloc.free(remote_json);
            if (parseRegistry(alloc, remote_json)) |registry| {
                writeRegistryCache(options.cache_path, remote_json);
                if (stale_registry) |old_registry| old_registry.deinit(alloc);
                stale_registry = null;
                return registry;
            } else |_| {}
        } else |_| {}
    }

    if (stale_registry) |registry| {
        stale_registry = null;
        return registry;
    }

    return parseRegistry(alloc, DEFAULT_REGISTRY_JSON);
}

pub fn parseRegistry(alloc: std.mem.Allocator, json_data: []const u8) !Registry {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRegistryRoot;
    const root = parsed.value.object;

    const schema_version = parseU32(root.get("schema_version") orelse return error.MissingField) orelse return error.InvalidField;
    if (schema_version != 1) return error.UnsupportedSchemaVersion;

    const records_val = root.get("records") orelse return error.MissingField;
    if (records_val != .array) return error.InvalidField;

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(alloc);
    errdefer {
        for (records.items) |record| record.deinit(alloc);
    }

    for (records_val.array.items) |record_val| {
        if (record_val != .object) return error.InvalidField;
        try records.append(alloc, try parseRecord(alloc, record_val.object));
    }

    return .{
        .schema_version = schema_version,
        .records = try records.toOwnedSlice(alloc),
    };
}

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

fn fetchRemoteRegistryJson(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = std.Io.Threaded.global_single_threaded.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "nanobrew-upstream-registry" },
            .{ .name = "Accept", .value = "application/json" },
        },
    }) catch return error.FetchFailed;

    req.sendBodiless() catch {
        req.deinit();
        return error.FetchFailed;
    };

    var head_buf: [32768]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        req.deinit();
        return error.FetchFailed;
    };
    if (response.head.status != .ok) {
        req.deinit();
        return error.FetchFailed;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch {
        out.deinit();
        req.deinit();
        return error.FetchFailed;
    };
    req.deinit();

    const raw = out.toOwnedSlice() catch {
        out.deinit();
        return error.OutOfMemory;
    };

    if (response.head.content_encoding == .gzip) {
        defer alloc.free(raw);
        return decompressGzip(alloc, raw);
    }

    return raw;
}

fn decompressGzip(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var fixed_reader = std.Io.Reader.fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&fixed_reader, .gzip, &window);

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    _ = decomp.reader.streamRemaining(&result.writer) catch return error.FetchFailed;
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn readRegistryCache(alloc: std.mem.Allocator, path: []const u8, ttl_ns: i96) ?CachedRegistryJson {
    if (path.len == 0) return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = openReadableFile(io, path) catch return null;
    defer file.close(io);

    const st = file.stat(io) catch return null;
    if (st.size == 0 or st.size > MAX_REGISTRY_JSON_BYTES) return null;
    const sz: usize = @intCast(st.size);

    const data = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(io, data, 0) catch {
        alloc.free(data);
        return null;
    };
    if (n != sz) {
        alloc.free(data);
        return null;
    }

    const now_ts = std.Io.Timestamp.now(io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    return .{
        .data = data,
        .fresh = ttl_ns < 0 or age_ns <= ttl_ns,
    };
}

fn writeRegistryCache(path: []const u8, data: []const u8) void {
    if (path.len == 0) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.dirname(path)) |dir_path| {
        if (std.fs.path.isAbsolute(dir_path)) {
            std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch {};
        } else {
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
        }
    }

    const file = createWritableFile(io, path) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, data) catch {};
}

fn openReadableFile(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn createWritableFile(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

fn parseRecord(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Record {
    const token = try dupRequiredString(alloc, obj, "token");
    errdefer alloc.free(token);
    const name = try dupOptionalString(alloc, obj, "name");
    errdefer alloc.free(name);
    const desc = try dupOptionalString(alloc, obj, "desc");
    errdefer alloc.free(desc);
    const homepage = try dupOptionalString(alloc, obj, "homepage");
    errdefer alloc.free(homepage);
    const auto_updates = getBool(obj, "auto_updates") orelse false;

    const kind = try parseKind(getString(obj, "kind") orelse return error.MissingField);

    const upstream_val = obj.get("upstream") orelse return error.MissingField;
    if (upstream_val != .object) return error.InvalidField;
    const upstream = try parseUpstream(alloc, upstream_val.object);
    errdefer upstream.deinit(alloc);

    const verification_val = obj.get("verification") orelse return error.MissingField;
    if (verification_val != .object) return error.InvalidField;
    const verification = try parseVerification(alloc, kind, verification_val.object);
    errdefer verification.deinit(alloc);

    var assets = try alloc.alloc(AssetRule, 0);
    errdefer freeAssets(alloc, assets);
    var artifacts = try alloc.alloc(ArtifactRule, 0);
    errdefer freeArtifacts(alloc, artifacts);
    var resolved: ?Resolved = null;
    errdefer if (resolved) |r| r.deinit(alloc);

    switch (kind) {
        .formula => {
            alloc.free(assets);
            const assets_val = obj.get("assets") orelse return error.MissingField;
            if (assets_val != .object) return error.InvalidField;
            assets = try parseAssets(alloc, assets_val.object);
            if (assets.len == 0) return error.MissingAssets;
        },
        .cask => {
            if (obj.get("assets")) |assets_val| {
                alloc.free(assets);
                if (assets_val != .object) return error.InvalidField;
                assets = try parseAssets(alloc, assets_val.object);
                if (upstream.type == .github_release and assets.len == 0) return error.MissingAssets;
            } else if (upstream.type == .github_release) {
                return error.MissingAssets;
            }

            alloc.free(artifacts);
            const artifacts_val = obj.get("artifacts") orelse return error.MissingField;
            if (artifacts_val != .array) return error.InvalidField;
            artifacts = try parseArtifacts(alloc, artifacts_val.array.items);
            if (artifacts.len == 0) return error.MissingArtifacts;
        },
    }

    if (obj.get("resolved")) |resolved_val| {
        if (resolved_val != .object) return error.InvalidField;
        resolved = try parseResolved(alloc, resolved_val.object);
    }

    return .{
        .token = token,
        .name = name,
        .desc = desc,
        .homepage = homepage,
        .auto_updates = auto_updates,
        .kind = kind,
        .upstream = upstream,
        .assets = assets,
        .artifacts = artifacts,
        .resolved = resolved,
        .verification = verification,
    };
}

fn parseUpstream(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Upstream {
    const upstream_type = try parseUpstreamType(getString(obj, "type") orelse return error.MissingField);
    const verified = getBool(obj, "verified") orelse return error.MissingField;
    if (!verified) return error.UnverifiedUpstream;

    const repo = try dupOptionalString(alloc, obj, "repo");
    errdefer alloc.free(repo);
    const homepage = try dupOptionalString(alloc, obj, "homepage");
    errdefer alloc.free(homepage);
    const release_feed = try dupOptionalString(alloc, obj, "release_feed");
    errdefer alloc.free(release_feed);
    const allow_domains = try parseOptionalStringArray(alloc, obj, "allow_domains");
    errdefer {
        for (allow_domains) |domain| alloc.free(domain);
        alloc.free(allow_domains);
    }

    switch (upstream_type) {
        .github_release => {
            if (repo.len == 0) return error.MissingUpstreamAllowlist;
        },
        .vendor_url => {
            if (allow_domains.len == 0) return error.MissingUpstreamAllowlist;
        },
    }

    return .{
        .type = upstream_type,
        .repo = repo,
        .homepage = homepage,
        .release_feed = release_feed,
        .allow_domains = allow_domains,
        .verified = verified,
    };
}

fn parseAssets(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]AssetRule {
    var assets: std.ArrayList(AssetRule) = .empty;
    defer assets.deinit(alloc);
    errdefer freeAssets(alloc, assets.items);

    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidField;
        const platform = try parsePlatform(entry.key_ptr.*);
        const pattern = try dupRequiredString(alloc, entry.value_ptr.*.object, "pattern");
        errdefer alloc.free(pattern);
        const strip_components = if (entry.value_ptr.*.object.get("strip_components")) |v|
            parseU32(v) orelse return error.InvalidField
        else
            0;

        try assets.append(alloc, .{
            .platform = platform,
            .pattern = pattern,
            .strip_components = strip_components,
        });
    }

    return assets.toOwnedSlice(alloc);
}

fn parseArtifacts(alloc: std.mem.Allocator, items: []const std.json.Value) ![]ArtifactRule {
    var artifacts: std.ArrayList(ArtifactRule) = .empty;
    defer artifacts.deinit(alloc);
    errdefer freeArtifacts(alloc, artifacts.items);

    for (items) |item| {
        if (item != .object) return error.InvalidField;
        const artifact_type = try parseArtifactKind(getString(item.object, "type") orelse return error.MissingField);
        const path = try dupRequiredString(alloc, item.object, "path");
        errdefer alloc.free(path);
        try artifacts.append(alloc, .{ .type = artifact_type, .path = path });
    }

    return artifacts.toOwnedSlice(alloc);
}

fn parseResolved(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Resolved {
    const tag = try dupOptionalString(alloc, obj, "tag");
    errdefer alloc.free(tag);
    const version = try dupRequiredString(alloc, obj, "version");
    errdefer alloc.free(version);

    const assets_val = obj.get("assets") orelse return error.MissingField;
    if (assets_val != .object) return error.InvalidField;

    var assets: std.ArrayList(ResolvedAsset) = .empty;
    defer assets.deinit(alloc);
    errdefer freeResolvedAssets(alloc, assets.items);

    var it = assets_val.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidField;
        const platform = try parsePlatform(entry.key_ptr.*);
        const url = try dupRequiredString(alloc, entry.value_ptr.*.object, "url");
        errdefer alloc.free(url);
        const sha256 = try dupRequiredString(alloc, entry.value_ptr.*.object, "sha256");
        errdefer alloc.free(sha256);
        if (!isSha256Hex(sha256)) return error.InvalidField;
        try assets.append(alloc, .{
            .platform = platform,
            .url = url,
            .sha256 = sha256,
        });
    }
    if (assets.items.len == 0) return error.MissingAssets;

    const security_warnings = try parseSecurityWarnings(alloc, obj);
    errdefer freeSecurityWarnings(alloc, security_warnings);

    return .{
        .tag = tag,
        .version = version,
        .assets = try assets.toOwnedSlice(alloc),
        .security_warnings = security_warnings,
    };
}

fn parseSecurityWarnings(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]SecurityWarning {
    const warnings_val = obj.get("security_warnings") orelse return alloc.alloc(SecurityWarning, 0);
    if (warnings_val != .array) return error.InvalidField;

    var warnings: std.ArrayList(SecurityWarning) = .empty;
    defer warnings.deinit(alloc);
    errdefer freeSecurityWarnings(alloc, warnings.items);

    for (warnings_val.array.items) |item| {
        if (item != .object) return error.InvalidField;
        const ghsa_id = try dupOptionalString(alloc, item.object, "ghsa_id");
        errdefer alloc.free(ghsa_id);
        const cve_id = try dupOptionalString(alloc, item.object, "cve_id");
        errdefer alloc.free(cve_id);
        const severity = try dupOptionalString(alloc, item.object, "severity");
        errdefer alloc.free(severity);
        const summary = try dupRequiredString(alloc, item.object, "summary");
        errdefer alloc.free(summary);
        const url = try dupOptionalString(alloc, item.object, "url");
        errdefer alloc.free(url);
        const affected_versions = try dupOptionalString(alloc, item.object, "affected_versions");
        errdefer alloc.free(affected_versions);
        const patched_versions = try dupOptionalString(alloc, item.object, "patched_versions");
        errdefer alloc.free(patched_versions);

        if (ghsa_id.len == 0 and cve_id.len == 0) return error.InvalidField;

        try warnings.append(alloc, .{
            .ghsa_id = ghsa_id,
            .cve_id = cve_id,
            .severity = severity,
            .summary = summary,
            .url = url,
            .affected_versions = affected_versions,
            .patched_versions = patched_versions,
        });
    }

    return warnings.toOwnedSlice(alloc);
}

fn parseVerification(alloc: std.mem.Allocator, kind: Kind, obj: std.json.ObjectMap) !Verification {
    const sha256 = try parseSha256Mode(getString(obj, "sha256") orelse return error.MissingField);
    const signature = if (getString(obj, "signature")) |v| try parseRequirementMode(v) else .none;
    const attestation = if (getString(obj, "attestation")) |v| try parseRequirementMode(v) else .none;
    const no_check_reason = try dupOptionalString(alloc, obj, "no_check_reason");
    errdefer alloc.free(no_check_reason);

    if (kind == .formula and sha256 == .no_check and signature != .required and attestation != .required) {
        return error.InvalidFormulaVerification;
    }
    if (sha256 == .no_check and no_check_reason.len == 0) {
        return error.MissingNoCheckReason;
    }

    return .{
        .sha256 = sha256,
        .signature = signature,
        .attestation = attestation,
        .no_check_reason = no_check_reason,
    };
}

fn freeAssets(alloc: std.mem.Allocator, assets: []const AssetRule) void {
    for (assets) |asset| asset.deinit(alloc);
    alloc.free(assets);
}

fn freeArtifacts(alloc: std.mem.Allocator, artifacts: []const ArtifactRule) void {
    for (artifacts) |artifact| artifact.deinit(alloc);
    alloc.free(artifacts);
}

fn freeResolvedAssets(alloc: std.mem.Allocator, assets: []const ResolvedAsset) void {
    for (assets) |asset| asset.deinit(alloc);
    alloc.free(assets);
}

fn freeSecurityWarnings(alloc: std.mem.Allocator, warnings: []const SecurityWarning) void {
    for (warnings) |warning| warning.deinit(alloc);
    alloc.free(warnings);
}

fn parseKind(value: []const u8) !Kind {
    if (std.mem.eql(u8, value, "formula")) return .formula;
    if (std.mem.eql(u8, value, "cask")) return .cask;
    return error.UnsupportedKind;
}

fn parseUpstreamType(value: []const u8) !UpstreamType {
    if (std.mem.eql(u8, value, "github_release")) return .github_release;
    if (std.mem.eql(u8, value, "vendor_url")) return .vendor_url;
    return error.UnsupportedUpstreamType;
}

fn parsePlatform(value: []const u8) !Platform {
    if (std.mem.eql(u8, value, "macos-arm64")) return .macos_arm64;
    if (std.mem.eql(u8, value, "macos-x86_64")) return .macos_x86_64;
    if (std.mem.eql(u8, value, "linux-x86_64")) return .linux_x86_64;
    if (std.mem.eql(u8, value, "linux-aarch64")) return .linux_aarch64;
    return error.UnsupportedPlatform;
}

fn parseArtifactKind(value: []const u8) !ArtifactKind {
    if (std.mem.eql(u8, value, "app")) return .app;
    if (std.mem.eql(u8, value, "pkg")) return .pkg;
    if (std.mem.eql(u8, value, "binary")) return .binary;
    return error.UnsupportedArtifactType;
}

fn parseSha256Mode(value: []const u8) !Sha256Mode {
    if (std.mem.eql(u8, value, "asset_or_sidecar")) return .asset_or_sidecar;
    if (std.mem.eql(u8, value, "asset_digest")) return .asset_digest;
    if (std.mem.eql(u8, value, "required")) return .required;
    if (std.mem.eql(u8, value, "required_or_no_check_with_reason")) return .required_or_no_check_with_reason;
    if (std.mem.eql(u8, value, "no_check")) return .no_check;
    return error.UnsupportedVerificationMode;
}

fn parseRequirementMode(value: []const u8) !RequirementMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "optional")) return .optional;
    if (std.mem.eql(u8, value, "required")) return .required;
    return error.UnsupportedVerificationMode;
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return false;
    }
    return true;
}

fn parseU32(value: std.json.Value) ?u32 {
    if (value != .integer) return null;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |value| {
        if (value == .bool) return value.bool;
    }
    return null;
}

fn dupRequiredString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return alloc.dupe(u8, getString(obj, key) orelse return error.MissingField);
}

fn dupOptionalString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return alloc.dupe(u8, getString(obj, key) orelse "");
}

fn parseOptionalStringArray(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return alloc.alloc([]const u8, 0);
    if (value != .array) return error.InvalidField;

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    errdefer {
        for (out.items) |item| alloc.free(item);
    }

    for (value.array.items) |item| {
        if (item != .string) return error.InvalidField;
        try out.append(alloc, try alloc.dupe(u8, item.string));
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

fn writeTempCacheFile(tmp_dir: *testing.TmpDir, name: []const u8, data: []const u8) ![]u8 {
    var file = try tmp_dir.dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, data);
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path[0..], name });
}

test "loadRegistryWithOptions uses valid local cache registry" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "cache-only",
        \\    "name": "Cache Only",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/cache-only",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "CacheOnly-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "CacheOnly-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "CacheOnly.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const cache_path = try writeTempCacheFile(&tmp_dir, "upstream.json", json);
    defer testing.allocator.free(cache_path);

    const registry = try loadRegistryWithOptions(testing.allocator, .{
        .cache_path = cache_path,
        .allow_remote = false,
    });
    defer registry.deinit(testing.allocator);

    try testing.expect(registry.find("cache-only", .cask) != null);
    try testing.expect(registry.find("alt-tab", .cask) == null);
}

test "loadRegistryWithOptions falls back to embedded registry when cache is invalid" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_path = try writeTempCacheFile(&tmp_dir, "upstream.json", "{ invalid json");
    defer testing.allocator.free(cache_path);

    const registry = try loadRegistryWithOptions(testing.allocator, .{
        .cache_path = cache_path,
        .allow_remote = false,
    });
    defer registry.deinit(testing.allocator);

    try testing.expect(registry.find("alt-tab", .cask) != null);
    try testing.expect(registry.find("cache-only", .cask) == null);
}

test "parseRegistry parses default registry file" {
    const registry = try parseRegistry(testing.allocator, DEFAULT_REGISTRY_JSON);
    defer registry.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), registry.schema_version);
    try testing.expect(registry.find("alt-tab", .cask) != null);
}

test "parseRegistry parses formula asset rules" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "ripgrep",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "BurntSushi/ripgrep",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": {
        \\        "pattern": "ripgrep-{version}-aarch64-apple-darwin.tar.gz",
        \\        "strip_components": 1
        \\      },
        \\      "linux-x86_64": {
        \\        "pattern": "ripgrep-{version}-x86_64-unknown-linux-musl.tar.gz"
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "asset_or_sidecar",
        \\      "signature": "optional",
        \\      "attestation": "optional"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), registry.records.len);
    const record = registry.find("ripgrep", .formula).?;
    try testing.expectEqual(Kind.formula, record.kind);
    try testing.expectEqual(UpstreamType.github_release, record.upstream.type);
    try testing.expectEqualStrings("BurntSushi/ripgrep", record.upstream.repo);
    try testing.expectEqual(@as(usize, 2), record.assets.len);
    try testing.expectEqual(Platform.macos_arm64, record.assets[0].platform);
    try testing.expectEqualStrings("ripgrep-{version}-aarch64-apple-darwin.tar.gz", record.assets[0].pattern);
    try testing.expectEqual(@as(u32, 1), record.assets[0].strip_components);
    try testing.expectEqual(Sha256Mode.asset_or_sidecar, record.verification.sha256);
}

test "parseRegistry parses cask artifacts and vendor allowlist" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "raycast",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "vendor_url",
        \\      "homepage": "https://www.raycast.com/",
        \\      "release_feed": "https://releases.raycast.com/releases/latest/download?build={arch}",
        \\      "allow_domains": ["releases.raycast.com"],
        \\      "verified": true
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "Raycast.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "required_or_no_check_with_reason"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    const record = registry.find("raycast", .cask).?;
    try testing.expectEqual(Kind.cask, record.kind);
    try testing.expectEqual(UpstreamType.vendor_url, record.upstream.type);
    try testing.expectEqualStrings("releases.raycast.com", record.upstream.allow_domains[0]);
    try testing.expectEqual(@as(usize, 1), record.artifacts.len);
    try testing.expectEqual(ArtifactKind.app, record.artifacts[0].type);
    try testing.expectEqualStrings("Raycast.app", record.artifacts[0].path);
}

test "parseRegistry parses resolved security warnings" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "app-with-advisory",
        \\    "name": "App With Advisory",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/app-with-advisory",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "App-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "App.app" }
        \\    ],
        \\    "resolved": {
        \\      "tag": "v1.2.3",
        \\      "version": "1.2.3",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://github.com/owner/app-with-advisory/releases/download/v1.2.3/App-1.2.3.zip",
        \\          "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\        }
        \\      },
        \\      "security_warnings": [{
        \\        "ghsa_id": "GHSA-xxxx-yyyy-zzzz",
        \\        "cve_id": "CVE-2026-0001",
        \\        "severity": "high",
        \\        "summary": "Example advisory affecting old releases",
        \\        "url": "https://github.com/owner/app-with-advisory/security/advisories/GHSA-xxxx-yyyy-zzzz",
        \\        "affected_versions": "< 1.2.4",
        \\        "patched_versions": ">= 1.2.4"
        \\      }]
        \\    },
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    const record = registry.find("app-with-advisory", .cask).?;
    const warning = record.resolved.?.security_warnings[0];
    try testing.expectEqualStrings("GHSA-xxxx-yyyy-zzzz", warning.ghsa_id);
    try testing.expectEqualStrings("CVE-2026-0001", warning.cve_id);
    try testing.expectEqualStrings("high", warning.severity);
    try testing.expectEqualStrings("< 1.2.4", warning.affected_versions);
    try testing.expectEqualStrings(">= 1.2.4", warning.patched_versions);
}

test "parseRegistry rejects unverified upstreams" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "unsafe",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/unsafe",
        \\      "verified": false
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "unsafe-{version}.tar.gz" }
        \\    },
        \\    "verification": { "sha256": "asset_or_sidecar" }
        \\  }]
        \\}
    ;
    try testing.expectError(error.UnverifiedUpstream, parseRegistry(testing.allocator, json));
}

test "parseRegistry rejects formula records without assets" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "empty",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/empty",
        \\      "verified": true
        \\    },
        \\    "assets": {},
        \\    "verification": { "sha256": "asset_or_sidecar" }
        \\  }]
        \\}
    ;
    try testing.expectError(error.MissingAssets, parseRegistry(testing.allocator, json));
}
