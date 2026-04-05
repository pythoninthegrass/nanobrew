// nanobrew — Content-addressable store
//
// Extracted bottle contents live at:
//   /opt/nanobrew/store/<sha256>/
//
// Each entry contains the full unpacked Homebrew keg.
// The store is deduplicated: same SHA256 = same content.

const std = @import("std");
const tar = @import("../extract/tar.zig");
const paths = @import("../platform/paths.zig");

const STORE_DIR = paths.STORE_DIR;

/// Validate that sha256 is exactly 64 lowercase hex characters.
/// This prevents path traversal attacks when sha256 is used as a path component.
pub fn isValidSha256(sha256: []const u8) bool {
    if (sha256.len != 64) return false;
    for (sha256) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// Ensure a store entry exists for the given SHA256.
/// If not, extract the blob tarball into the store.
pub fn ensureEntry(alloc: std.mem.Allocator, blob_path: []const u8, sha256: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    var dir_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Already extracted?
    std.fs.accessAbsolute(store_path, .{}) catch {
        // Need to extract
        try tar.extractToStore(alloc, blob_path, sha256);
        return;
    };
}

/// Check if a store entry exists.
pub fn hasEntry(sha256: []const u8) bool {
    if (!isValidSha256(sha256)) return false;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return false;
    std.fs.accessAbsolute(p, .{}) catch return false;
    return true;
}

/// Get the store path for an entry.
pub fn entryPath(sha256: []const u8, buf: []u8) []const u8 {
    if (!isValidSha256(sha256)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch "";
}

/// Remove a store entry (when refcount drops to 0).
pub fn removeEntry(sha256: []const u8) void {
    if (!isValidSha256(sha256)) return;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return;
    std.fs.deleteTreeAbsolute(p) catch {};
}

const testing = std.testing;

test "entryPath - formats store path correctly" {
    var buf: [512]u8 = undefined;
    const valid_sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const p = entryPath(valid_sha, &buf);
    try testing.expectEqualStrings("/opt/nanobrew/store/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", p);
}

test "entryPath - invalid sha returns empty string" {
    var buf: [512]u8 = undefined;
    const p = entryPath("", &buf);
    try testing.expectEqualStrings("", p);
}

test "entryPath - path traversal sha returns empty string" {
    var buf: [512]u8 = undefined;
    const p = entryPath("../../etc/passwd", &buf);
    try testing.expectEqualStrings("", p);
}
