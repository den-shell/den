/// Shared utilities for builtin commands.
/// Eliminates duplication of common helpers across builtin files.
const std = @import("std");
const builtin = @import("builtin");
pub const spawn = @import("../../utils/spawn.zig");

pub const IO = @import("../../utils/io.zig").IO;

/// C exec functions for fork/exec patterns (POSIX only).
pub const c_exec = if (builtin.os.tag == .windows) struct {
    pub fn execvp(_: [*:0]const u8, _: [*:null]const ?[*:0]const u8) c_int {
        return -1;
    }
} else struct {
    pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

/// Read all available data from stdin into a heap-allocated string.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn readAllStdin(allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var buf: [4096]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const stdin_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.Unexpected;
        while (true) {
            var bytes_read: u32 = 0;
            const success = @import("windows_compat").ReadFile(stdin_handle, &buf, @intCast(buf.len), &bytes_read, null);
            if (success == 0 or bytes_read == 0) break;
            try result.appendSlice(allocator, buf[0..bytes_read]);
        }
    } else {
        while (true) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            if (n == 0) break;
            try result.appendSlice(allocator, buf[0..n]);
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Get a C environment variable as a Zig slice.
pub fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Get the C environ pointer (platform-specific).
pub fn getCEnviron() [*:null]const ?[*:0]const u8 {
    if (builtin.os.tag == .windows) {
        // Windows: environ not available via C extern in the same way.
        // Return an empty sentinel-terminated list.
        const empty: [*:null]const ?[*:0]const u8 = @ptrCast(&[_:null]?[*:0]const u8{null});
        return empty;
    } else if (builtin.os.tag == .macos) {
        const NSGetEnviron = @extern(*const fn () callconv(.c) *[*:null]?[*:0]u8, .{ .name = "_NSGetEnviron" });
        return @ptrCast(NSGetEnviron().*);
    } else {
        const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
        return @ptrCast(c_environ.*);
    }
}

/// Print a number, formatting whole numbers without decimal places.
pub fn printNumber(n: f64) !void {
    if (n == @floor(n) and @abs(n) < 1e15) {
        try IO.print("{d}\n", .{@as(i64, @intFromFloat(n))});
    } else {
        try IO.print("{d}\n", .{n});
    }
}
