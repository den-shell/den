const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const TestResult = types.TestResult;
const TestStats = types.TestStats;
const ReporterConfig = types.ReporterConfig;
const OutputFormat = types.OutputFormat;

/// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const cyan = "\x1b[36m";
};

/// Test reporter
pub const TestReporter = struct {
    allocator: std.mem.Allocator,
    config: ReporterConfig,

    pub fn init(allocator: std.mem.Allocator, config: ReporterConfig) TestReporter {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn print(self: *const TestReporter, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        std.debug.print(fmt, args);
    }

    fn writeAll(self: *const TestReporter, bytes: []const u8) !void {
        _ = self;
        if (builtin.os.tag == .windows) {
            const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.NoStdOut;
            const stdout = std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
            try stdout.writeStreamingAll(std.Options.debug_io, bytes);
        } else {
            const stdout_posix = std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
            try stdout_posix.writeStreamingAll(std.Options.debug_io, bytes);
        }
    }

    fn writeByte(self: *const TestReporter, byte: u8) !void {
        const buf = [_]u8{byte};
        try self.writeAll(&buf);
    }

    /// Report test start
    pub fn reportStart(self: *TestReporter, module_name: []const u8) !void {
        if (self.config.format == .human) {
            if (self.config.color) {
                try self.print("{s}{s}Running{s} {s}\n", .{ Color.bold, Color.blue, Color.reset, module_name });
            } else {
                try self.print("Running {s}\n", .{module_name});
            }
        }
    }

    /// Report individual test result
    pub fn reportResult(self: *TestReporter, result: *const TestResult) !void {
        switch (self.config.format) {
            .human => try self.reportHuman(result),
            .json => try self.reportJSON(result),
            .junit => try self.reportJUnit(result),
            .tap => try self.reportTAP(result),
        }
    }

    /// Report test summary
    pub fn reportSummary(self: *TestReporter, stats: *const TestStats) !void {
        switch (self.config.format) {
            .human => try self.reportSummaryHuman(stats),
            .json => try self.reportSummaryJSON(stats),
            .junit => try self.reportSummaryJUnit(stats),
            .tap => try self.reportSummaryTAP(stats),
        }
    }

    /// Human-readable format
    fn reportHuman(self: *TestReporter, result: *const TestResult) !void {
        if (!self.config.show_passed and result.status == .passed) {
            return;
        }

        const duration_ms = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0;

        const status_str = switch (result.status) {
            .passed => if (self.config.color) Color.green ++ "PASS" ++ Color.reset else "PASS",
            .failed => if (self.config.color) Color.red ++ "FAIL" ++ Color.reset else "FAIL",
            .skipped => if (self.config.color) Color.yellow ++ "SKIP" ++ Color.reset else "SKIP",
            .running => "RUN ",
        };

        try self.print("  [{s}] {s} ({d:.2}ms)\n", .{ status_str, result.name, duration_ms });

        if (result.error_message) |msg| {
            if (self.config.verbose) {
                const indent = "    ";
                var lines = std.mem.splitScalar(u8, msg, '\n');
                while (lines.next()) |line| {
                    try self.print("{s}{s}\n", .{ indent, line });
                }
            } else {
                try self.print("    Error: {s}\n", .{msg});
            }
        }
    }

    /// JSON format
    fn reportJSON(self: *TestReporter, result: *const TestResult) !void {
        try self.writeAll("{");
        try self.print("\"name\":\"{s}\",", .{result.name});
        try self.print("\"status\":\"{s}\",", .{@tagName(result.status)});
        try self.print("\"duration_ns\":{d}", .{result.duration_ns});

        if (result.error_message) |msg| {
            // Escape JSON string
            try self.writeAll(",\"error\":\"");
            for (msg) |c| {
                switch (c) {
                    '"' => try self.writeAll("\\\""),
                    '\\' => try self.writeAll("\\\\"),
                    '\n' => try self.writeAll("\\n"),
                    '\r' => try self.writeAll("\\r"),
                    '\t' => try self.writeAll("\\t"),
                    else => try self.writeByte(c),
                }
            }
            try self.writeAll("\"");
        }

        try self.writeAll("}\n");
    }

    /// JUnit XML format
    fn reportJUnit(self: *TestReporter, result: *const TestResult) !void {
        const duration_s = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000_000.0;

        try self.print("  <testcase name=\"{s}\" time=\"{d:.3}\"", .{ result.name, duration_s });

        switch (result.status) {
            .passed => try self.writeAll(" />\n"),
            .failed => {
                try self.writeAll(">\n");
                try self.writeAll("    <failure>");
                if (result.error_message) |msg| {
                    try self.writeAll(msg);
                }
                try self.writeAll("</failure>\n");
                try self.writeAll("  </testcase>\n");
            },
            .skipped => {
                try self.writeAll(">\n");
                try self.writeAll("    <skipped />\n");
                try self.writeAll("  </testcase>\n");
            },
            .running => try self.writeAll(" />\n"),
        }
    }

    /// TAP (Test Anything Protocol) format
    fn reportTAP(self: *TestReporter, result: *const TestResult) !void {
        const status = if (result.status == .passed) "ok" else "not ok";
        try self.print("{s} - {s}\n", .{ status, result.name });

        if (result.error_message) |msg| {
            try self.print("  # {s}\n", .{msg});
        }
    }

    /// Human-readable summary
    fn reportSummaryHuman(self: *TestReporter, stats: *const TestStats) !void {
        const duration_s = @as(f64, @floatFromInt(stats.duration_ns)) / 1_000_000_000.0;

        try self.writeAll("\n");
        if (self.config.color) {
            try self.print("{s}═══════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writeAll("========================================\n");
        }

        if (self.config.color) {
            try self.print("{s}Test Results:{s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writeAll("Test Results:\n");
        }

        const passed_color = if (self.config.color) Color.green else "";
        const failed_color = if (self.config.color) Color.red else "";
        const skipped_color = if (self.config.color) Color.yellow else "";
        const reset = if (self.config.color) Color.reset else "";

        try self.print("  Total:   {d}\n", .{stats.total});
        try self.print("  {s}Passed:  {d}{s}\n", .{ passed_color, stats.passed, reset });
        try self.print("  {s}Failed:  {d}{s}\n", .{ failed_color, stats.failed, reset });
        try self.print("  {s}Skipped: {d}{s}\n", .{ skipped_color, stats.skipped, reset });
        try self.print("  Duration: {d:.2}s\n", .{duration_s});

        if (self.config.color) {
            try self.print("{s}═══════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });
        } else {
            try self.writeAll("========================================\n\n");
        }

        // Exit status indicator
        if (stats.failed > 0) {
            if (self.config.color) {
                try self.print("{s}{s}FAILED{s}\n", .{ Color.bold, Color.red, Color.reset });
            } else {
                try self.writeAll("FAILED\n");
            }
        } else {
            if (self.config.color) {
                try self.print("{s}{s}PASSED{s}\n", .{ Color.bold, Color.green, Color.reset });
            } else {
                try self.writeAll("PASSED\n");
            }
        }
    }

    /// JSON summary
    fn reportSummaryJSON(self: *TestReporter, stats: *const TestStats) !void {
        try self.writeAll("{");
        try self.print("\"total\":{d},", .{stats.total});
        try self.print("\"passed\":{d},", .{stats.passed});
        try self.print("\"failed\":{d},", .{stats.failed});
        try self.print("\"skipped\":{d},", .{stats.skipped});
        try self.print("\"duration_ns\":{d}", .{stats.duration_ns});
        try self.writeAll("}\n");
    }

    /// JUnit XML summary
    fn reportSummaryJUnit(self: *TestReporter, stats: *const TestStats) !void {
        const duration_s = @as(f64, @floatFromInt(stats.duration_ns)) / 1_000_000_000.0;

        try self.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try self.print("<testsuite tests=\"{d}\" failures=\"{d}\" skipped=\"{d}\" time=\"{d:.3}\">\n", .{
            stats.total,
            stats.failed,
            stats.skipped,
            duration_s,
        });
        try self.writeAll("</testsuite>\n");
    }

    /// TAP summary
    fn reportSummaryTAP(self: *TestReporter, stats: *const TestStats) !void {
        try self.print("1..{d}\n", .{stats.total});
        if (stats.failed > 0) {
            try self.print("# Failed: {d}\n", .{stats.failed});
        }
    }
};
