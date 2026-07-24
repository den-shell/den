const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const types = @import("types.zig");

/// Cross-platform handle read helper
fn readHandle(handle: anytype, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        var bytes_read: u32 = 0;
        const success = @import("windows_compat").ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
        if (success == 0) return error.ReadFailed;
        return bytes_read;
    } else {
        return std.posix.read(handle, buf);
    }
}
const discovery_mod = @import("discovery.zig");
const reporter_mod = @import("reporter.zig");

const TestResult = types.TestResult;
const TestStats = types.TestStats;
const TestFilter = types.TestFilter;
const ReporterConfig = types.ReporterConfig;
const TestDiscovery = discovery_mod.TestDiscovery;
const TestReporter = reporter_mod.TestReporter;

/// Test runner
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    filter: TestFilter,
    reporter: TestReporter,
    root_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8, filter: TestFilter, config: ReporterConfig) TestRunner {
        return .{
            .allocator = allocator,
            .filter = filter,
            .reporter = TestReporter.init(allocator, config),
            .root_dir = root_dir,
        };
    }

    /// Run all discovered tests
    pub fn runAll(self: *TestRunner) !TestStats {
        var discovery = TestDiscovery.init(self.allocator, self.root_dir);

        // Get known test modules from build.zig
        var modules = try discovery.getKnownTestModules();
        defer {
            for (modules.items) |*module| {
                module.deinit();
            }
            modules.deinit(self.allocator);
        }

        var stats = TestStats.init();

        for (modules.items) |module| {
            // Apply filter
            if (!self.filter.matches(module.name)) {
                continue;
            }

            try self.reporter.reportStart(module.name);

            const result = try self.runTestModule(module.name);
            defer result.deinit();

            try self.reporter.reportResult(&result);
            stats.addResult(&result);
        }

        try self.reporter.reportSummary(&stats);

        return stats;
    }

    /// Run a specific test module
    fn runTestModule(self: *TestRunner, module_name: []const u8) !TestResult {
        var result = try TestResult.init(self.allocator, module_name);

        const start_time = compat.Instant.now() catch std.mem.zeroes(compat.Instant);

        // Build test command
        var cmd_args = std.ArrayList([]const u8).empty;
        defer cmd_args.deinit(self.allocator);

        try cmd_args.append(self.allocator, "zig");
        try cmd_args.append(self.allocator, "build");

        // Construct test step name
        const test_step = try self.getTestStepName(module_name);
        defer self.allocator.free(test_step);
        try cmd_args.append(self.allocator, test_step);

        // Execute test
        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = cmd_args.items,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            const end_time = compat.Instant.now() catch start_time;
            const duration = end_time.since(start_time);
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to spawn test: {any}", .{err});
            try result.setFailed(duration, error_msg);
            self.allocator.free(error_msg);
            return result;
        };

        // Read stdout manually
        var stdout_buf = std.ArrayList(u8).empty;
        defer stdout_buf.deinit(self.allocator);
        if (child.stdout) |stdout_pipe| {
            var read_buf: [4096]u8 = undefined;
            while (true) {
                const n = readHandle(stdout_pipe.handle, &read_buf) catch break;
                if (n == 0) break;
                try stdout_buf.appendSlice(self.allocator, read_buf[0..n]);
                if (stdout_buf.items.len >= 1024 * 1024) break;
            }
        }
        const stdout = stdout_buf.items;

        // Read stderr manually
        var stderr_buf = std.ArrayList(u8).empty;
        defer stderr_buf.deinit(self.allocator);
        if (child.stderr) |stderr_pipe| {
            var read_buf: [4096]u8 = undefined;
            while (true) {
                const n = readHandle(stderr_pipe.handle, &read_buf) catch break;
                if (n == 0) break;
                try stderr_buf.appendSlice(self.allocator, read_buf[0..n]);
                if (stderr_buf.items.len >= 1024 * 1024) break;
            }
        }
        const stderr = stderr_buf.items;

        const term = child.wait(std.Options.debug_io) catch |err| {
            const end_time = compat.Instant.now() catch start_time;
            const duration = end_time.since(start_time);
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to wait for test: {any}", .{err});
            try result.setFailed(duration, error_msg);
            self.allocator.free(error_msg);
            return result;
        };

        const end_time = compat.Instant.now() catch start_time;
        const duration = end_time.since(start_time);

        switch (term) {
            .exited => |code| {
                if (code == 0) {
                    result.setPassed(duration);
                } else {
                    const error_output = if (stderr.len > 0) stderr else stdout;
                    try result.setFailed(duration, error_output);
                }
            },
            else => {
                const error_msg = try std.fmt.allocPrint(self.allocator, "Test terminated abnormally: {any}", .{term});
                try result.setFailed(duration, error_msg);
                self.allocator.free(error_msg);
            },
        }

        return result;
    }

    /// Get test step name for build.zig
    fn getTestStepName(self: *TestRunner, module_name: []const u8) ![]const u8 {
        // Map module names to build.zig test steps
        const mapping = .{
            .{ "tokenizer", "test-tokenizer" },
            .{ "parser", "test-parser" },
            .{ "expander", "test-expander" },
            .{ "executor", "test-executor" },
            .{ "plugins", "test-plugins" },
            .{ "plugin_interface", "test-interface" },
            .{ "builtin_plugins", "test-builtin-plugins" },
            .{ "plugin_integration", "test-plugin-integration" },
            .{ "plugin_discovery", "test-plugin-discovery" },
            .{ "plugin_api", "test-plugin-api" },
            .{ "hook_manager", "test-hook-manager" },
            .{ "builtin_hooks", "test-builtin-hooks" },
            .{ "theme", "test-theme" },
            .{ "prompt", "test-prompt" },
            .{ "modules", "test-modules" },
            .{ "system_modules", "test-system-modules" },
        };

        inline for (mapping) |pair| {
            if (std.mem.eql(u8, module_name, pair[0])) {
                return try self.allocator.dupe(u8, pair[1]);
            }
        }

        // Default: test-{module_name}
        return try std.fmt.allocPrint(self.allocator, "test-{s}", .{module_name});
    }

    /// Run tests in parallel
    pub fn runParallel(self: *TestRunner, max_parallel: usize) !TestStats {
        var discovery = TestDiscovery.init(self.allocator, self.root_dir);

        var modules = try discovery.getKnownTestModules();
        defer {
            for (modules.items) |*module| {
                module.deinit();
            }
            modules.deinit(self.allocator);
        }

        var stats = TestStats.init();
        var current_parallel: usize = 0;
        var module_index: usize = 0;

        while (module_index < modules.items.len or current_parallel > 0) {
            // Start new tests if we have capacity
            while (current_parallel < max_parallel and module_index < modules.items.len) {
                const module = modules.items[module_index];

                if (!self.filter.matches(module.name)) {
                    module_index += 1;
                    continue;
                }

                try self.reporter.reportStart(module.name);

                // In a real implementation, we'd track processes
                // For now, just run sequentially
                const result = try self.runTestModule(module.name);
                defer result.deinit();

                try self.reporter.reportResult(&result);
                stats.addResult(&result);

                module_index += 1;
                current_parallel += 1;
            }

            current_parallel = 0;
        }

        try self.reporter.reportSummary(&stats);
        return stats;
    }
};
