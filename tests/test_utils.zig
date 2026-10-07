const std = @import("std");
const io = std.testing.io;

/// Test utilities for Den shell tests
/// Provides helpers for temporary files, process mocking, and test assertions

/// Helper to get millisecond timestamp for Zig 0.16 compatibility
fn getMilliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @intCast(ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000));
}

/// Temporary directory manager for tests
pub const TempDir = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TempDir {
        // Generate unique name
        var random = std.Random.DefaultPrng.init(@intCast(getMilliTimestamp()));
        const rand_num = random.random().int(u32);
        const unique_name = try std.fmt.allocPrint(allocator, "den_test_{d}", .{rand_num});
        defer allocator.free(unique_name);

        const full_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{unique_name});

        // Create directory
        try std.Io.Dir.cwd().createDirPath(io, full_path);

        return TempDir{
            .path = full_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TempDir) void {
        // Clean up temp directory
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        self.allocator.free(self.path);
    }

    /// Create a file in the temp directory
    pub fn createFile(self: *TempDir, name: []const u8, content: []const u8) ![]const u8 {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, name });

        const file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true });
        defer file.close(io);

        try file.writeStreamingAll(io, content);

        return file_path;
    }

    /// Create a directory in the temp directory
    pub fn createDir(self: *TempDir, name: []const u8) ![]const u8 {
        const dir_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, name });
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return dir_path;
    }

    /// Read a file from the temp directory
    pub fn readFile(self: *TempDir, name: []const u8) ![]const u8 {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, name });
        defer self.allocator.free(file_path);

        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        // Manual read for Zig 0.16 compatibility
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&read_buf}) catch break;
            if (n == 0) break;
            try result.appendSlice(self.allocator, read_buf[0..n]);
        }

        return try result.toOwnedSlice(self.allocator);
    }
};

/// Process mock for testing command execution
pub const ProcessMock = struct {
    command: []const u8,
    args: []const []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, command: []const u8) ProcessMock {
        return ProcessMock{
            .command = command,
            .args = &[_][]const u8{},
            .stdout = "",
            .stderr = "",
            .exit_code = 0,
            .allocator = allocator,
        };
    }

    pub fn withArgs(self: *ProcessMock, args: []const []const u8) *ProcessMock {
        self.args = args;
        return self;
    }

    pub fn withStdout(self: *ProcessMock, stdout: []const u8) *ProcessMock {
        self.stdout = stdout;
        return self;
    }

    pub fn withStderr(self: *ProcessMock, stderr: []const u8) *ProcessMock {
        self.stderr = stderr;
        return self;
    }

    pub fn withExitCode(self: *ProcessMock, code: u8) *ProcessMock {
        self.exit_code = code;
        return self;
    }

    pub fn execute(self: *ProcessMock) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {
        return .{
            .stdout = self.stdout,
            .stderr = self.stderr,
            .exit_code = self.exit_code,
        };
    }
};

/// Test assertions
pub const TestAssert = struct {
    /// Assert two strings are equal
    pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
        try std.testing.expectEqualStrings(expected, actual);
    }

    /// Assert two values are equal
    pub fn expectEqual(expected: anytype, actual: anytype) !void {
        try std.testing.expectEqual(expected, actual);
    }

    /// Assert condition is true
    pub fn expectTrue(condition: bool) !void {
        try std.testing.expect(condition);
    }

    /// Assert condition is false
    pub fn expectFalse(condition: bool) !void {
        try std.testing.expect(!condition);
    }

    /// Assert string contains substring
    pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            std.debug.print("Expected '{s}' to contain '{s}'\n", .{ haystack, needle });
            return error.TestExpectedContains;
        }
    }

    /// Assert string starts with prefix
    pub fn expectStartsWith(str: []const u8, prefix: []const u8) !void {
        if (!std.mem.startsWith(u8, str, prefix)) {
            std.debug.print("Expected '{s}' to start with '{s}'\n", .{ str, prefix });
            return error.TestExpectedStartsWith;
        }
    }

    /// Assert string ends with suffix
    pub fn expectEndsWith(str: []const u8, suffix: []const u8) !void {
        if (!std.mem.endsWith(u8, str, suffix)) {
            std.debug.print("Expected '{s}' to end with '{s}'\n", .{ str, suffix });
            return error.TestExpectedEndsWith;
        }
    }

    /// Assert error is expected
    pub fn expectError(expected_error: anyerror, result: anytype) !void {
        try std.testing.expectError(expected_error, result);
    }
};

/// Shell fixture for testing shell operations
pub const ShellFixture = struct {
    temp_dir: TempDir,
    allocator: std.mem.Allocator,
    env_vars: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) !ShellFixture {
        const temp_dir = try TempDir.init(allocator);

        return ShellFixture{
            .temp_dir = temp_dir,
            .allocator = allocator,
            .env_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ShellFixture) void {
        var it = self.env_vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit();
        self.temp_dir.deinit();
    }

    /// Set environment variable for test
    pub fn setEnv(self: *ShellFixture, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.env_vars.put(key_copy, value_copy);
    }

    /// Get environment variable
    pub fn getEnv(self: *ShellFixture, key: []const u8) ?[]const u8 {
        return self.env_vars.get(key);
    }

    /// Create a test script file
    pub fn createScript(self: *ShellFixture, name: []const u8, content: []const u8) ![]const u8 {
        const script_path = try self.temp_dir.createFile(name, content);

        // Make executable
        const file = try std.Io.Dir.cwd().openFile(io, script_path, .{});
        defer file.close(io);

        // Set executable permissions (0755)
        if (@import("builtin").os.tag != .windows) {
            try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }

        return script_path;
    }

    /// Execute a command and capture output
    pub fn exec(self: *ShellFixture, command: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {

        const args = [_][]const u8{ "sh", "-c", command };

        var env_map = std.process.Environ.Map.init(self.allocator);
        defer env_map.deinit();
        const have_env = self.env_vars.count() > 0;
        if (have_env) {
            var it = self.env_vars.iterator();
            while (it.next()) |entry| {
                try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        var child = try std.process.spawn(io, .{
            .argv = &args,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = if (have_env) &env_map else null,
        });

        // Read output using ArrayList for Zig 0.16 compatibility
        var stdout_list = std.ArrayList(u8).empty;
        errdefer stdout_list.deinit(self.allocator);
        var stderr_list = std.ArrayList(u8).empty;
        errdefer stderr_list.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stdout_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        if (child.stderr) |stderr| {
            while (true) {
                const n = stderr.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stderr_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        const term = try child.wait(io);
        const exit_code: u8 = switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        };

        const stdout_owned = try stdout_list.toOwnedSlice(self.allocator);
        const stderr_owned = try stderr_list.toOwnedSlice(self.allocator);

        return .{
            .stdout = stdout_owned,
            .stderr = stderr_owned,
            .exit_code = exit_code,
        };
    }
};

/// Helper to create temporary test files
pub fn createTempFile(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    return try temp_dir.createFile("test_file.txt", content);
}

/// Helper to run a command and get output
pub fn runCommand(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
    const args = [_][]const u8{ "sh", "-c", cmd };

    var child = try std.process.spawn(io, .{
        .argv = &args,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    // Read output using ArrayList for Zig 0.16 compatibility
    var stdout_list = std.ArrayList(u8).empty;
    errdefer stdout_list.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |stdout| {
        while (true) {
            const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
            if (n == 0) break;
            try stdout_list.appendSlice(allocator, read_buf[0..n]);
        }
    }

    _ = try child.wait(io);

    return try stdout_list.toOwnedSlice(allocator);
}

// Tests for test utilities
test "TempDir creates and cleans up" {
    const allocator = std.testing.allocator;

    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    // Verify directory exists
    var dir = try std.Io.Dir.cwd().openDir(io, temp_dir.path, .{});
    dir.close(io);
}

test "TempDir.createFile creates file" {
    const allocator = std.testing.allocator;

    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    const file_path = try temp_dir.createFile("test.txt", "hello world");
    defer allocator.free(file_path);

    const content = try temp_dir.readFile("test.txt");
    defer allocator.free(content);

    try TestAssert.expectEqualStrings("hello world", content);
}

test "TestAssert.expectContains works" {
    try TestAssert.expectContains("hello world", "world");
    try TestAssert.expectContains("hello world", "hello");
}

test "TestAssert.expectStartsWith works" {
    try TestAssert.expectStartsWith("hello world", "hello");
}

test "TestAssert.expectEndsWith works" {
    try TestAssert.expectEndsWith("hello world", "world");
}

test "ShellFixture environment variables" {
    const allocator = std.testing.allocator;

    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    try fixture.setEnv("TEST_VAR", "test_value");

    const value = fixture.getEnv("TEST_VAR");
    try TestAssert.expectEqualStrings("test_value", value.?);

    // Test that env vars are passed to child processes
    const result = try fixture.exec("echo $TEST_VAR");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectContains(result.stdout, "test_value");
}

/// Den Shell fixture for testing Den-specific features
/// Uses the actual Den shell binary instead of system sh
pub const DenShellFixture = struct {
    /// Captured output of one den run. Named rather than anonymous so the
    /// several entry points share one type.
    pub const Result = struct {
        stdout: []const u8,
        stderr: []const u8,
        exit_code: u8,
    };

    temp_dir: TempDir,
    allocator: std.mem.Allocator,
    den_binary: []const u8,

    pub fn init(allocator: std.mem.Allocator) !DenShellFixture {
        const temp_dir = try TempDir.init(allocator);

        // Default to relative path from project root
        const den_binary = try allocator.dupe(u8, "./zig-out/bin/den");

        return DenShellFixture{
            .temp_dir = temp_dir,
            .allocator = allocator,
            .den_binary = den_binary,
        };
    }

    pub fn deinit(self: *DenShellFixture) void {
        self.allocator.free(self.den_binary);
        self.temp_dir.deinit();
    }

    /// Create a file in the temp directory
    pub fn createFile(self: *DenShellFixture, name: []const u8, content: []const u8) ![]const u8 {
        return try self.temp_dir.createFile(name, content);
    }

    /// Get the temp directory path
    pub fn getTempPath(self: *DenShellFixture) []const u8 {
        return self.temp_dir.path;
    }

    /// Execute a command using the Den shell and capture output
    /// The command is run from the temp directory
    pub fn exec(self: *DenShellFixture, command: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {
        // Build command that changes to temp dir first, then runs the command
        const full_command = try std.fmt.allocPrint(self.allocator, "cd {s} && {s}", .{ self.temp_dir.path, command });
        defer self.allocator.free(full_command);

        const args = [_][]const u8{ self.den_binary, "-c", full_command };

        var child = try std.process.spawn(io, .{
            .argv = &args,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        // Read output using ArrayList for Zig 0.16 compatibility
        var stdout_list = std.ArrayList(u8).empty;
        errdefer stdout_list.deinit(self.allocator);
        var stderr_list = std.ArrayList(u8).empty;
        errdefer stderr_list.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stdout_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        if (child.stderr) |stderr| {
            while (true) {
                const n = stderr.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stderr_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        const term = try child.wait(io);
        const exit_code: u8 = switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        };

        const stdout_owned = try stdout_list.toOwnedSlice(self.allocator);
        const stderr_owned = try stderr_list.toOwnedSlice(self.allocator);

        return .{
            .stdout = stdout_owned,
            .stderr = stderr_owned,
            .exit_code = exit_code,
        };
    }

    /// Execute a command directly (not prefixed with cd to temp dir)
    /// Execute a command with den *started in* the temp directory, rather than
    /// cd'ing once it is already running.
    ///
    /// Anything den reads at startup -- `den.jsonc`, and so the history file it
    /// points at -- then comes from the temp directory, which is what makes a
    /// test hermetic instead of reading the developer's own files. The binary
    /// path has to be absolute here, since the relative one is resolved against
    /// the child's working directory.
    pub fn execInTempDir(self: *DenShellFixture, command: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(io, &cwd_buf);
        const abs_binary = try std.fmt.allocPrint(self.allocator, "{s}/zig-out/bin/den", .{cwd_buf[0..cwd_len]});
        defer self.allocator.free(abs_binary);

        const args = [_][]const u8{ abs_binary, "-c", command };

        var child = try std.process.spawn(io, .{
            .argv = &args,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = self.temp_dir.path },
        });

        var stdout_list = std.ArrayList(u8).empty;
        errdefer stdout_list.deinit(self.allocator);
        var stderr_list = std.ArrayList(u8).empty;
        errdefer stderr_list.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stdout_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }
        if (child.stderr) |stderr| {
            while (true) {
                const n = stderr.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stderr_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        const term = try child.wait(io);
        const exit_code: u8 = switch (term) {
            .exited => |code| code,
            else => 1,
        };

        return .{
            .stdout = try stdout_list.toOwnedSlice(self.allocator),
            .stderr = try stderr_list.toOwnedSlice(self.allocator),
            .exit_code = exit_code,
        };
    }

    /// Run a script file through den, the way `den script.sh` does.
    ///
    /// Not the same path as `-c`: a script is read line by line, so a bug can
    /// live in one and not the other.
    pub fn execScript(self: *DenShellFixture, script_path: []const u8) !Result {
        return self.spawnDen(&[_][]const u8{ self.den_binary, script_path });
    }

    pub fn execDirect(self: *DenShellFixture, command: []const u8) !Result {
        return self.spawnDen(&[_][]const u8{ self.den_binary, "-c", command });
    }

    fn spawnDen(self: *DenShellFixture, args: []const []const u8) !Result {

        var child = try std.process.spawn(io, .{
            .argv = args,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        // Read output using ArrayList for Zig 0.16 compatibility
        var stdout_list = std.ArrayList(u8).empty;
        errdefer stdout_list.deinit(self.allocator);
        var stderr_list = std.ArrayList(u8).empty;
        errdefer stderr_list.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stdout_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        if (child.stderr) |stderr| {
            while (true) {
                const n = stderr.readStreaming(io, &.{&read_buf}) catch break;
                if (n == 0) break;
                try stderr_list.appendSlice(self.allocator, read_buf[0..n]);
            }
        }

        const term = try child.wait(io);
        const exit_code: u8 = switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        };

        const stdout_owned = try stdout_list.toOwnedSlice(self.allocator);
        const stderr_owned = try stderr_list.toOwnedSlice(self.allocator);

        return .{
            .stdout = stdout_owned,
            .stderr = stderr_owned,
            .exit_code = exit_code,
        };
    }
};
