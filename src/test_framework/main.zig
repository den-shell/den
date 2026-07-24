const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const runner_mod = @import("runner.zig");

const TestFilter = types.TestFilter;
const ReporterConfig = types.ReporterConfig;
const OutputFormat = types.OutputFormat;
const TestRunner = runner_mod.TestRunner;

/// Parse command line arguments
fn parseArgs(allocator: std.mem.Allocator, init_args: std.process.Args) !struct {
    filter: TestFilter,
    config: ReporterConfig,
    parallel: usize,
} {
    var filter = TestFilter.initDefault();
    var config = ReporterConfig.initDefault();
    var parallel: usize = 1;

    var args = try init_args.iterateAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            config.color = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.format = .json;
        } else if (std.mem.eql(u8, arg, "--junit")) {
            config.format = .junit;
        } else if (std.mem.eql(u8, arg, "--tap")) {
            config.format = .tap;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            if (args.next()) |pattern| {
                filter.pattern = pattern;
            } else {
                std.debug.print("Error: --filter requires a pattern\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--parallel")) {
            if (args.next()) |count_str| {
                parallel = std.fmt.parseInt(usize, count_str, 10) catch {
                    std.debug.print("Error: Invalid parallel count\n", .{});
                    std.process.exit(1);
                };
            } else {
                std.debug.print("Error: --parallel requires a count\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            // Treat as filter pattern
            filter.pattern = arg;
        }
    }

    return .{
        .filter = filter,
        .config = config,
        .parallel = parallel,
    };
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
        \\Den Test Runner
        \\
        \\Usage: den-test [OPTIONS] [PATTERN]
        \\
        \\Options:
        \\  -h, --help         Show this help message
        \\  -v, --verbose      Verbose output
        \\  --no-color         Disable colored output
        \\  --json             Output in JSON format
        \\  --junit            Output in JUnit XML format
        \\  --tap              Output in TAP format
        \\  --filter PATTERN   Filter tests by pattern
        \\  --parallel N       Run N tests in parallel (default: 1)
        \\
        \\Examples:
        \\  den-test                    # Run all tests
        \\  den-test parser             # Run tests matching "parser"
        \\  den-test --verbose          # Run all tests with verbose output
        \\  den-test --json             # Output results in JSON
        \\  den-test --parallel 4       # Run 4 tests in parallel
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const parsed = try parseArgs(allocator, init.minimal.args);

    // Get current working directory as root
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(std.Options.debug_io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    var test_runner = TestRunner.init(allocator, cwd, parsed.filter, parsed.config);

    const stats = if (parsed.parallel > 1)
        try test_runner.runParallel(parsed.parallel)
    else
        try test_runner.runAll();

    // Exit with non-zero if tests failed
    if (stats.hasFailed()) {
        std.process.exit(1);
    }
}
