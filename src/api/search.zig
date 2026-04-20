// nanobrew — Search API
//
// Fetches formula and cask lists from Homebrew API and performs
// case-insensitive substring matching on name and description.

const std = @import("std");
const fetch = @import("../net/fetch.zig");
const FORMULA_LIST_URL = "https://formulae.brew.sh/api/formula.json";
const CASK_LIST_URL = "https://formulae.brew.sh/api/cask.json";
const CACHE_DIR = @import("../platform/paths.zig").API_CACHE_DIR;
const FORMULA_CACHE = CACHE_DIR ++ "/_formula_list.json";
const CASK_CACHE = CACHE_DIR ++ "/_cask_list.json";
const CACHE_TTL_NS = 3600 * std.time.ns_per_s; // 1 hour

pub const SearchResult = struct {
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    is_cask: bool,

    pub fn deinit(self: SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.desc);
    }
};

pub fn search(alloc: std.mem.Allocator, query: []const u8) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    defer results.deinit(alloc); // only the list, not items — caller owns items

    // Lowercase the query for case-insensitive matching
    const lower_query = try toLower(alloc, query);
    defer alloc.free(lower_query);

    // Search formulae
    const formula_json = try fetchCachedList(alloc, FORMULA_LIST_URL, FORMULA_CACHE);
    defer alloc.free(formula_json);
    try searchFormulaList(alloc, formula_json, lower_query, &results);

    // Search casks
    const cask_json = try fetchCachedList(alloc, CASK_LIST_URL, CASK_CACHE);
    defer alloc.free(cask_json);
    try searchCaskList(alloc, cask_json, lower_query, &results);

    return results.toOwnedSlice(alloc);
}

fn fetchCachedList(alloc: std.mem.Allocator, url: []const u8, cache_path: []const u8) ![]u8 {
    // Check cache with 1-hour TTL
    if (readCachedFile(alloc, cache_path)) |data| return data;

    // Fetch from network (native HTTP, no curl)
    const body = fetch.get(alloc, url) catch return error.FetchFailed;

    // Write to cache
    std.Io.Dir.createDirAbsolute(std.Io.Threaded.global_single_threaded.io(), CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), cache_path, .{})) |file| {
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), body) catch {};
    } else |_| {}

    return body;
}

fn readCachedFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    const st = file.stat(lib_io) catch return null;
    const now_ts = std.Io.Timestamp.now(lib_io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > CACHE_TTL_NS) return null;
    const sz = @min(st.size, 64 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(lib_io, buf, 0) catch { alloc.free(buf); return null; };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

fn searchFormulaList(alloc: std.mem.Allocator, json_data: []const u8, lower_query: []const u8, results: *std.ArrayList(SearchResult)) !void {
    var scanner = std.json.Scanner.initCompleteInput(alloc, json_data);
    defer scanner.deinit();

    if ((scanner.next() catch return) != .array_begin) return;

    while (true) {
        const t = scanner.next() catch return;
        switch (t) {
            .array_end => return,
            .object_begin => {},
            else => return,
        }

        var name: []const u8 = "";
        var desc: []const u8 = "";
        var version: []const u8 = "";
        var name_owned: ?[]u8 = null;
        var desc_owned: ?[]u8 = null;
        var version_owned: ?[]u8 = null;
        defer {
            if (name_owned) |s| alloc.free(s);
            if (desc_owned) |s| alloc.free(s);
            if (version_owned) |s| alloc.free(s);
        }

        while (true) {
            const key_tok = scanner.nextAlloc(alloc, .alloc_if_needed) catch return;
            var key_slice: []const u8 = "";
            var key_alloc: ?[]u8 = null;
            switch (key_tok) {
                .object_end => break,
                .string => |s| key_slice = s,
                .allocated_string => |s| {
                    key_slice = s;
                    key_alloc = s;
                },
                else => return,
            }
            defer if (key_alloc) |s| alloc.free(s);

            if (std.mem.eql(u8, key_slice, "name")) {
                captureString(&scanner, alloc, &name, &name_owned) catch return;
            } else if (std.mem.eql(u8, key_slice, "desc")) {
                captureString(&scanner, alloc, &desc, &desc_owned) catch return;
            } else if (std.mem.eql(u8, key_slice, "versions")) {
                if ((scanner.next() catch return) != .object_begin) {
                    scanner.skipValue() catch return;
                    continue;
                }
                while (true) {
                    const sub_key_tok = scanner.nextAlloc(alloc, .alloc_if_needed) catch return;
                    var sub_key: []const u8 = "";
                    var sub_alloc: ?[]u8 = null;
                    switch (sub_key_tok) {
                        .object_end => break,
                        .string => |s| sub_key = s,
                        .allocated_string => |s| {
                            sub_key = s;
                            sub_alloc = s;
                        },
                        else => return,
                    }
                    defer if (sub_alloc) |s| alloc.free(s);

                    if (std.mem.eql(u8, sub_key, "stable")) {
                        captureString(&scanner, alloc, &version, &version_owned) catch return;
                    } else {
                        scanner.skipValue() catch return;
                    }
                }
            } else {
                scanner.skipValue() catch return;
            }
        }

        if (name.len == 0) continue;
        if (!containsIgnoreCase(name, lower_query) and !containsIgnoreCase(desc, lower_query)) continue;

        try results.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .version = try alloc.dupe(u8, version),
            .desc = try alloc.dupe(u8, desc),
            .is_cask = false,
        });
    }
}

fn searchCaskList(alloc: std.mem.Allocator, json_data: []const u8, lower_query: []const u8, results: *std.ArrayList(SearchResult)) !void {
    var scanner = std.json.Scanner.initCompleteInput(alloc, json_data);
    defer scanner.deinit();

    if ((scanner.next() catch return) != .array_begin) return;

    while (true) {
        const t = scanner.next() catch return;
        switch (t) {
            .array_end => return,
            .object_begin => {},
            else => return,
        }

        var token_str: []const u8 = "";
        var desc: []const u8 = "";
        var version: []const u8 = "";
        var token_owned: ?[]u8 = null;
        var desc_owned: ?[]u8 = null;
        var version_owned: ?[]u8 = null;
        defer {
            if (token_owned) |s| alloc.free(s);
            if (desc_owned) |s| alloc.free(s);
            if (version_owned) |s| alloc.free(s);
        }

        while (true) {
            const key_tok = scanner.nextAlloc(alloc, .alloc_if_needed) catch return;
            var key_slice: []const u8 = "";
            var key_alloc: ?[]u8 = null;
            switch (key_tok) {
                .object_end => break,
                .string => |s| key_slice = s,
                .allocated_string => |s| {
                    key_slice = s;
                    key_alloc = s;
                },
                else => return,
            }
            defer if (key_alloc) |s| alloc.free(s);

            if (std.mem.eql(u8, key_slice, "token")) {
                captureString(&scanner, alloc, &token_str, &token_owned) catch return;
            } else if (std.mem.eql(u8, key_slice, "desc")) {
                captureString(&scanner, alloc, &desc, &desc_owned) catch return;
            } else if (std.mem.eql(u8, key_slice, "version")) {
                captureString(&scanner, alloc, &version, &version_owned) catch return;
            } else {
                scanner.skipValue() catch return;
            }
        }

        if (token_str.len == 0) continue;
        if (!containsIgnoreCase(token_str, lower_query) and !containsIgnoreCase(desc, lower_query)) continue;

        try results.append(alloc, .{
            .name = try alloc.dupe(u8, token_str),
            .version = try alloc.dupe(u8, version),
            .desc = try alloc.dupe(u8, desc),
            .is_cask = true,
        });
    }
}

fn captureString(scanner: *std.json.Scanner, alloc: std.mem.Allocator, out: *[]const u8, owned: *?[]u8) !void {
    const v = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (v) {
        .string => |s| out.* = s,
        .allocated_string => |s| {
            out.* = s;
            owned.* = s;
        },
        else => {},
    }
}

fn containsIgnoreCase(haystack: []const u8, lower_needle: []const u8) bool {
    if (lower_needle.len == 0) return true;
    if (lower_needle.len > haystack.len) return false;
    const end = haystack.len - lower_needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var j: usize = 0;
        while (j < lower_needle.len) : (j += 1) {
            const hc = haystack[i + j];
            const hcl: u8 = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            if (hcl != lower_needle[j]) break;
        }
        if (j == lower_needle.len) return true;
    }
    return false;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn toLower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}
