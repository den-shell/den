const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

// Use the lightweight `Init.Minimal` entry point. The full `std.process.Init`
// eagerly constructs an arena, a general-purpose allocator, an Io implementation,
// and an `environ_map` of *every* environment variable before main() runs — about
// 1ms of startup. Den builds its own environment from C `environ` and uses the
// libc allocator, so it needs none of that; Minimal gives just the args.
pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.mode == .Debug) {
        // Keep leak detection in Debug builds.
        var gpa: std.heap.DebugAllocator(.{}) = .{};
        defer _ = gpa.deinit();
        try run(gpa.allocator(), init.args);
    } else {
        // Release: the libc allocator (malloc) — lean and fast, libc is always linked.
        try run(std.heap.c_allocator, init.args);
    }
}

fn run(allocator: std.mem.Allocator, args: std.process.Args) !void {
    var cli_args = try cli.parseArgs(allocator, args);
    defer cli_args.deinit();
    try cli.execute(cli_args);
}

test {
    std.testing.refAllDecls(@This());
}
