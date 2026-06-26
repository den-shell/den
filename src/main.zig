const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    // In release, use the libc allocator (malloc) — leaner and faster than the
    // general-purpose allocator, with lower per-process memory overhead (libc is
    // always linked). Keep the leak-detecting gpa for Debug builds.
    const allocator = if (builtin.mode == .Debug) init.gpa else std.heap.c_allocator;

    // Parse command line arguments
    var cli_args = try cli.parseArgs(allocator, init.minimal.args);
    defer cli_args.deinit();

    // Execute the command
    try cli.execute(cli_args);
}

test {
    std.testing.refAllDecls(@This());
}
