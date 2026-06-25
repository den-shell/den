//! Version Detection Module
//!
//! This module provides functions for detecting versions of various
//! programming languages and tools. These are used in the prompt
//! to show context about the current project environment.
//!
//! Supported detections:
//! - Package version (from package.json, pantry.json)
//! - Bun, Node.js, Python, Ruby, Go, Rust, Zig versions

const std = @import("std");
const spawn = @import("../utils/spawn.zig");

/// Detect package version from package.json or pantry.json
pub fn detectPackageVersion(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const filenames = [_][]const u8{ "package.json", "package.jsonc", "pantry.json", "pantry.jsonc" };

    for (filenames) |filename| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch continue;

        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch continue;
        defer file.close(std.Options.debug_io);

        const max_size: usize = 8192;
        const file_size = (file.stat(std.Options.debug_io) catch continue).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = allocator.alloc(u8, read_size) catch continue;
        defer allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch break;
            if (n == 0) break;
            total_read += n;
        }
        const content = buffer[0..total_read];

        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (std.mem.startsWith(u8, content[i..], "\"version\"")) {
                var j = i + 9;
                while (j < content.len and (content[j] == ' ' or content[j] == '\t' or content[j] == ':')) : (j += 1) {}
                if (j < content.len and content[j] == '"') {
                    j += 1;
                    const start = j;
                    while (j < content.len and content[j] != '"') : (j += 1) {}
                    if (j > start) {
                        return allocator.dupe(u8, content[start..j]) catch continue;
                    }
                }
            }
        }
    }

    return error.NotFound;
}

/// Detect Bun version by running `bun --version`.
/// Uses spawn.captureOutput (the working command-substitution path) rather than
/// std.process.run, whose capture comes back empty in this build. This runs only
/// in Bun projects (gated by bun.lock in updatePromptContext), so it's one spawn
/// per prompt there — the other language detectors are intentionally left on the
/// fast-failing path to avoid spawning a process every render in every directory.
pub fn detectBunVersion(allocator: std.mem.Allocator) ![]const u8 {
    const cap = spawn.captureOutput(allocator, .{
        .argv = &[_][]const u8{ "bun", "--version" },
    }) catch return error.NotFound;
    defer cap.deinit(allocator);

    if (cap.exit_code != 0) return error.NotFound;
    const trimmed = std.mem.trim(u8, cap.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.NotFound;
    return try allocator.dupe(u8, trimmed);
}

/// Detect Node.js version by running `node --version`
pub fn detectNodeVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "node", "--version" },
    }) catch return error.NotFound;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                var trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
                // Remove leading 'v' if present
                if (trimmed.len > 0 and trimmed[0] == 'v') {
                    trimmed = trimmed[1..];
                }
                if (trimmed.len > 0) {
                    return try allocator.dupe(u8, trimmed);
                }
            }
        },
        else => {},
    }

    return error.NotFound;
}

/// Detect Python version by running `python3 --version` or `python --version`
pub fn detectPythonVersion(allocator: std.mem.Allocator) ![]const u8 {
    // Try python3 first, then python
    const commands = [_][]const []const u8{
        &[_][]const u8{ "python3", "--version" },
        &[_][]const u8{ "python", "--version" },
    };

    for (commands) |cmd| {
        const result = std.process.run(allocator, std.Options.debug_io, .{
            .argv = cmd,
        }) catch continue;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code == 0) {
                    // Python --version outputs to stdout: "Python 3.12.0"
                    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
                    const trimmed = std.mem.trim(u8, output, &std.ascii.whitespace);

                    // Parse "Python X.Y.Z" to get just "X.Y.Z"
                    if (std.mem.startsWith(u8, trimmed, "Python ")) {
                        const version = std.mem.trim(u8, trimmed[7..], &std.ascii.whitespace);
                        if (version.len > 0) {
                            return try allocator.dupe(u8, version);
                        }
                    }
                }
            },
            else => {},
        }
    }

    return error.NotFound;
}

/// Detect Ruby version by running `ruby --version`
pub fn detectRubyVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "ruby", "--version" },
    }) catch return error.NotFound;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

                // Parse "ruby 3.3.0p0 (2023-12-25 revision ...)" to get just "3.3.0"
                if (std.mem.startsWith(u8, trimmed, "ruby ")) {
                    const version_start: usize = 5;
                    var version_end: usize = version_start;
                    while (version_end < trimmed.len and trimmed[version_end] != ' ' and trimmed[version_end] != 'p') {
                        version_end += 1;
                    }
                    if (version_end > version_start) {
                        return try allocator.dupe(u8, trimmed[version_start..version_end]);
                    }
                }
            }
        },
        else => {},
    }

    return error.NotFound;
}

/// Detect Go version by running `go version`
pub fn detectGoVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "go", "version" },
    }) catch return error.NotFound;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

                // Parse "go version go1.22.0 darwin/arm64" to get just "1.22.0"
                if (std.mem.indexOf(u8, trimmed, "go")) |idx| {
                    const after_go = trimmed[idx + 2 ..];
                    if (std.mem.indexOf(u8, after_go, "go")) |version_idx| {
                        const version_start = version_idx + 2;
                        var version_end = version_start;
                        while (version_end < after_go.len and after_go[version_end] != ' ') {
                            version_end += 1;
                        }
                        if (version_end > version_start) {
                            return try allocator.dupe(u8, after_go[version_start..version_end]);
                        }
                    }
                }
            }
        },
        else => {},
    }

    return error.NotFound;
}

/// Detect Rust version by running `rustc --version`
pub fn detectRustVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "rustc", "--version" },
    }) catch return error.NotFound;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

                // Parse "rustc 1.75.0 (82e1608df 2023-12-21)" to get just "1.75.0"
                if (std.mem.startsWith(u8, trimmed, "rustc ")) {
                    const version_start: usize = 6;
                    var version_end: usize = version_start;
                    while (version_end < trimmed.len and trimmed[version_end] != ' ') {
                        version_end += 1;
                    }
                    if (version_end > version_start) {
                        return try allocator.dupe(u8, trimmed[version_start..version_end]);
                    }
                }
            }
        },
        else => {},
    }

    return error.NotFound;
}

/// Detect Zig version by running `zig version`
pub fn detectZigVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "zig", "version" },
    }) catch return error.NotFound;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    return try allocator.dupe(u8, trimmed);
                }
            }
        },
        else => {},
    }

    return error.NotFound;
}
