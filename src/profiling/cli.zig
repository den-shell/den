// Profiling CLI tool for Den Shell
const std = @import("std");
const builtin = @import("builtin");
const Profiler = @import("profiler.zig").Profiler;
const IO = @import("io").IO;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    // Collect args into a slice
    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer args_list.deinit();
    while (args_iter.next()) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        try printHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printHelp();
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            IO.eprint("Error: benchmark name required\n", .{}) catch {};
            try printHelp();
            return error.InvalidArgs;
        }
        try runBenchmark(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "list")) {
        try listBenchmarks();
    } else if (std.mem.eql(u8, command, "all")) {
        try runAllBenchmarks(allocator);
    } else {
        IO.eprint("Error: unknown command '{s}'\n", .{command}) catch {};
        try printHelp();
        return error.UnknownCommand;
    }
}

fn printHelp() !void {
    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.StdoutUnavailable;
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};

    try writer.interface.writeAll(
        \\Den Shell Profiling Tool
        \\
        \\Usage: den-profile COMMAND [OPTIONS]
        \\
        \\Commands:
        \\  run NAME     Run a specific benchmark
        \\  list         List all available benchmarks
        \\  all          Run all benchmarks
        \\  help         Show this help message
        \\
        \\Available Benchmarks:
        \\  startup      Measure shell startup time
        \\  command      Measure command execution
        \\  completion   Measure completion generation
        \\  history      Measure history search
        \\  prompt       Measure prompt rendering
        \\
        \\Examples:
        \\  den-profile run startup
        \\  den-profile run completion
        \\  den-profile all
        \\
        \\Output:
        \\  Benchmarks report timing statistics including:
        \\  - Mean execution time
        \\  - Median execution time
        \\  - Min/Max times
        \\  - Standard deviation
        \\
    );
}

fn listBenchmarks() !void {
    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.StdoutUnavailable;
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};

    try writer.interface.writeAll(
        \\Available Benchmarks:
        \\
        \\  startup      - Shell startup time benchmarks
        \\                 Tests minimal startup, config load, history load,
        \\                 plugin discovery, and prompt initialization
        \\
        \\  command      - Command execution benchmarks
        \\                 Tests parsing, expansion, process spawn, pipes,
        \\                 and redirections
        \\
        \\  completion   - Completion generation benchmarks
        \\                 Tests command completion, file completion, PATH search,
        \\                 fuzzy matching, and completion ranking
        \\
        \\  history      - History search benchmarks
        \\                 Tests linear search, prefix search, substring search,
        \\                 duplicate removal, and persistence
        \\
        \\  prompt       - Prompt rendering benchmarks
        \\                 Tests simple/complex prompts, git status, color
        \\                 formatting, and module detection
        \\
        \\Run 'den-profile run NAME' to execute a specific benchmark.
        \\
    );
}

fn runBenchmark(allocator: std.mem.Allocator, name: []const u8) !void {
    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.StdoutUnavailable;
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};

    try writer.interface.print("Running {s} benchmark...\n\n", .{name});

    if (std.mem.eql(u8, name, "startup")) {
        try runExternalBenchmark(allocator, "startup_bench");
    } else if (std.mem.eql(u8, name, "command")) {
        try runExternalBenchmark(allocator, "command_exec_bench");
    } else if (std.mem.eql(u8, name, "completion")) {
        try runExternalBenchmark(allocator, "completion_bench");
    } else if (std.mem.eql(u8, name, "history")) {
        try runExternalBenchmark(allocator, "history_bench");
    } else if (std.mem.eql(u8, name, "prompt")) {
        try runExternalBenchmark(allocator, "prompt_bench");
    } else {
        IO.eprint("Error: unknown benchmark '{s}'\n", .{name}) catch {};
        try listBenchmarks();
        return error.UnknownBenchmark;
    }
}

fn runExternalBenchmark(allocator: std.mem.Allocator, bench_name: []const u8) !void {
    const exe_path = try std.fmt.allocPrint(allocator, "./zig-out/bin/{s}", .{bench_name});
    defer allocator.free(exe_path);

    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{exe_path},
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| return err;

    _ = try child.wait(std.Options.debug_io);
}

fn runAllBenchmarks(allocator: std.mem.Allocator) !void {
    const benchmarks = [_][]const u8{
        "startup",
        "command",
        "completion",
        "history",
        "prompt",
    };

    for (benchmarks) |bench_name| {
        try runBenchmark(allocator, bench_name);
        IO.eprint("\n{s}\n\n", .{@as([]const u8, &@as([80]u8, @splat('=')))}) catch {};
    }
}
