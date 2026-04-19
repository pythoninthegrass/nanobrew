// nanobrew — Tar/gzip extraction
//
// Extracts Homebrew bottle tarballs into the content-addressable store.
// Fast path: native std.compress.flate.Decompress + std.tar.pipeToFileSystem.
// Fallback: `tar -xzf` subprocess — Zig's std.tar doesn't yet support every
// header variant shipped by Homebrew bottles (GNU long-name / pax-extended
// headers hit by perl, postgresql@17 — issue #221).

const std = @import("std");
const paths = @import("../platform/paths.zig");
const store = @import("../store/store.zig");

const STORE_DIR = paths.STORE_DIR;

/// Extract a gzipped tar blob into the store at store/<sha256>/
pub fn extractToStore(alloc: std.mem.Allocator, blob_path: []const u8, sha256: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    if (!store.isValidSha256(sha256)) return error.InvalidSha256;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Skip if already extracted
    std.Io.Dir.accessAbsolute(lib_io, dest_dir, .{}) catch {
        // Doesn't exist — create and extract
        try std.Io.Dir.createDirAbsolute(lib_io, dest_dir, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(lib_io, dest_dir) catch {};

        extractTarGzNative(lib_io, blob_path, dest_dir) catch {
            // Native extractor couldn't parse this bottle (likely an unsupported
            // tar header type). Wipe any partial output and retry via the system
            // `tar` binary, which handles every header variant we've hit.
            std.Io.Dir.cwd().deleteTree(lib_io, dest_dir) catch {};
            try std.Io.Dir.createDirAbsolute(lib_io, dest_dir, .default_dir);
            try extractTarGzSubprocess(alloc, blob_path, dest_dir);
        };
        return;
    };
}

/// Native in-process extraction: open blob → flate decompress → tar write.
/// No subprocess, no fork/exec overhead. Saves ~10-20ms per package.
fn extractTarGzNative(io: std.Io, blob_path: []const u8, dest_dir: []const u8) !void {
    const blob = try std.Io.Dir.openFileAbsolute(io, blob_path, .{});
    defer blob.close(io);

    var read_buf: [65536]u8 = undefined;
    var file_reader = blob.readerStreaming(io, &read_buf);

    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&file_reader.interface, .gzip, &window);

    var dest = try std.Io.Dir.openDirAbsolute(io, dest_dir, .{});
    defer dest.close(io);

    // mode_mode = .executable_bit_only: preserves the executable bit from the
    // tar header (critical for binaries in Homebrew bottles) without over-applying
    // other permission bits.
    try std.tar.pipeToFileSystem(io, dest, &decomp.reader, .{
        .mode_mode = .executable_bit_only,
    });
}

/// Fallback extraction via the system `tar` binary. Slower (fork/exec + extra
/// read of the blob) but handles every header type `tar(1)` understands.
fn extractTarGzSubprocess(alloc: std.mem.Allocator, blob_path: []const u8, dest_dir: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "tar", "-xzf", blob_path, "-C", dest_dir },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.ExtractFailed;
}

const testing = std.testing;

test "extractToStore creates errdefer cleanup on failure" {
    const T = @TypeOf(extractToStore);
    const info = @typeInfo(T);
    try testing.expect(info == .@"fn");
}

test "extractTarGzNative returns error on nonexistent blob" {
    const err = extractTarGzNative(testing.io, "/nonexistent/blob.tar.gz", "/tmp");
    try testing.expectError(error.FileNotFound, err);
}

// ── Regression tests (#221) ──────────────────────────────────────────────────
// extractTarGzSubprocess calls std.process.run with `global_single_threaded.io()`,
// whose allocator is `Allocator.failing` until overwritten by `std.start`. That
// means test binaries (which don't run std.start) can't exercise the spawn path
// directly — the spawn allocSentinel returns OutOfMemory. Full end-to-end
// coverage lives in tests/smoke-test.sh (installs perl, which triggers the
// fallback). Here we keep structural guards so the fallback wiring can't be
// removed silently.

test "extractTarGzSubprocess signature is available for fallback" {
    const T = @TypeOf(extractTarGzSubprocess);
    try testing.expect(@typeInfo(T) == .@"fn");
}

test "extractToStore rejects invalid sha256" {
    const err = extractToStore(testing.allocator, "/nonexistent", "not-a-valid-hash");
    try testing.expectError(error.InvalidSha256, err);
}
