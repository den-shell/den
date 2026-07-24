const std = @import("std");

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const value = getenv(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// System information provider
pub const SystemInfo = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SystemInfo {
        return .{ .allocator = allocator };
    }

    /// Get current working directory
    pub fn getCurrentDir(self: *SystemInfo) ![]const u8 {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(std.Options.debug_io, &buf);
        return try self.allocator.dupe(u8, buf[0..cwd_len]);
    }

    /// Get home directory
    pub fn getHomeDir(self: *SystemInfo) !?[]const u8 {
        if (getEnvOwned(self.allocator, "HOME")) |home| {
            return home;
        }

        return null;
    }

    /// Get current user name
    pub fn getUsername(self: *SystemInfo) ![]const u8 {
        if (getEnvOwned(self.allocator, "USER")) |user| {
            return user;
        }

        if (getEnvOwned(self.allocator, "USERNAME")) |user| {
            return user;
        }

        return try self.allocator.dupe(u8, "unknown");
    }

    /// Get hostname
    pub fn getHostname(self: *SystemInfo) ![]const u8 {
        if (getEnvOwned(self.allocator, "HOSTNAME")) |hostname| {
            return hostname;
        }

        // Try to read from /etc/hostname on Unix systems
        if (@import("builtin").os.tag != .windows) {
            var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/etc/hostname", .{}) catch {
                return try self.allocator.dupe(u8, "localhost");
            };
            defer file.close(std.Options.debug_io);

            return self.readHostnameFile(file) catch
                try self.allocator.dupe(u8, "localhost");
        }

        return try self.allocator.dupe(u8, "localhost");
    }

    fn readHostnameFile(self: *SystemInfo, file: std.Io.File) ![]const u8 {
        var buf: [256]u8 = undefined;
        const size = try file.readPositionalAll(std.Options.debug_io, &buf, 0);
        const hostname = std.mem.trim(u8, buf[0..size], &std.ascii.whitespace);
        if (hostname.len == 0) return try self.allocator.dupe(u8, "localhost");
        return try self.allocator.dupe(u8, hostname);
    }

    /// Check if current user is root
    pub fn isRoot(self: *SystemInfo) bool {
        _ = self;

        if (@import("builtin").os.tag == .windows) {
            return false;
        }

        return std.c.geteuid() == 0;
    }

    /// Get battery percentage (null if no battery or can't detect)
    pub fn getBatteryPercent(self: *SystemInfo) ?u8 {
        _ = self;
        if (comptime @import("builtin").os.tag.isDarwin()) {
            return getBatteryDarwin();
        } else if (comptime @import("builtin").os.tag == .linux) {
            return getBatteryLinux();
        }
        return null;
    }

    /// Abbreviate path with home directory (~)
    pub fn abbreviatePath(self: *SystemInfo, path: []const u8) ![]const u8 {
        const home = try self.getHomeDir() orelse return try self.allocator.dupe(u8, path);
        defer self.allocator.free(home);

        if (std.mem.startsWith(u8, path, home)) {
            const rest = path[home.len..];
            return try std.fmt.allocPrint(self.allocator, "~{s}", .{rest});
        }

        return try self.allocator.dupe(u8, path);
    }

    /// Truncate path to a maximum number of components
    pub fn truncatePath(self: *SystemInfo, path: []const u8, max_components: usize) ![]const u8 {
        if (max_components == 0) {
            return try self.allocator.dupe(u8, path);
        }

        var components: std.ArrayList([]const u8) = .empty;
        defer components.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |component| {
            if (component.len > 0) {
                try components.append(self.allocator, component);
            }
        }

        const total = components.items.len;
        if (total <= max_components) {
            return try self.allocator.dupe(u8, path);
        }

        // Keep first component and last (max_components - 1) components
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        const starts_with_slash = path.len > 0 and path[0] == '/';
        if (starts_with_slash) {
            try result.append(self.allocator, '/');
        }

        // Add first component
        try result.appendSlice(self.allocator, components.items[0]);

        // Add ellipsis
        try result.appendSlice(self.allocator, "/…");

        // Add remaining components
        const start_idx = total - (max_components - 1);
        for (components.items[start_idx..]) |component| {
            try result.append(self.allocator, '/');
            try result.appendSlice(self.allocator, component);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Get the base name (last component) of a path
    pub fn basename(self: *SystemInfo, path: []const u8) ![]const u8 {
        const base = std.fs.path.basename(path);
        return try self.allocator.dupe(u8, base);
    }

    /// Get parent directory of a path
    pub fn dirname(self: *SystemInfo, path: []const u8) !?[]const u8 {
        const dir = std.fs.path.dirname(path) orelse return null;
        return try self.allocator.dupe(u8, dir);
    }

    /// Detect runtime module versions
    pub fn detectRuntimeModules(self: *SystemInfo) !RuntimeModules {
        var modules = RuntimeModules{
            .node_version = null,
            .bun_version = null,
            .deno_version = null,
            .allocator = self.allocator,
        };

        // Detect Node.js
        modules.node_version = self.getCommandVersion("node", &[_][]const u8{ "node", "--version" }) catch null;

        // Detect Bun
        modules.bun_version = self.getCommandVersion("bun", &[_][]const u8{ "bun", "--version" }) catch null;

        // Detect Deno
        modules.deno_version = self.getCommandVersion("deno", &[_][]const u8{ "deno", "--version" }) catch null;

        return modules;
    }

    /// Get version from a command
    fn getCommandVersion(self: *SystemInfo, _: []const u8, argv: []const []const u8) ![]const u8 {
        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.CommandNotFound;

        var stdout_read_buf: [1024]u8 = undefined;
        var stdout_reader = child.stdout.?.readerStreaming(std.Options.debug_io, &stdout_read_buf);
        const stdout = stdout_reader.interface.allocRemaining(self.allocator, .limited(1024)) catch return error.CommandNotFound;
        defer self.allocator.free(stdout);

        _ = try child.wait(std.Options.debug_io);

        // Extract version number from output
        const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);

        // Remove 'v' prefix if present
        const version = if (trimmed.len > 0 and trimmed[0] == 'v')
            trimmed[1..]
        else
            trimmed;

        // Take only the first line
        var line_iter = std.mem.splitScalar(u8, version, '\n');
        const first_line = line_iter.next() orelse return error.InvalidVersion;

        return try self.allocator.dupe(u8, first_line);
    }
};

/// Runtime module versions
pub const RuntimeModules = struct {
    node_version: ?[]const u8,
    bun_version: ?[]const u8,
    deno_version: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RuntimeModules) void {
        if (self.node_version) |v| self.allocator.free(v);
        if (self.bun_version) |v| self.allocator.free(v);
        if (self.deno_version) |v| self.allocator.free(v);
    }
};

const FILE = opaque {};
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(stream: *FILE) c_int;

test "hostname file read treats EOF as successful completion" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writable = try tmp.dir.createFile(std.Options.debug_io, "hostname", .{});
    try writable.writeStreamingAll(std.Options.debug_io, "ci-runner\n");
    writable.close(std.Options.debug_io);

    const readable = try tmp.dir.openFile(std.Options.debug_io, "hostname", .{});
    defer readable.close(std.Options.debug_io);

    var sysinfo = SystemInfo.init(allocator);
    const hostname = try sysinfo.readHostnameFile(readable);
    defer allocator.free(hostname);

    try std.testing.expectEqualStrings("ci-runner", hostname);
}
extern "c" fn fgetc(stream: *FILE) c_int;

/// Read battery percentage on macOS via popen("pmset -g batt")
fn getBatteryDarwin() ?u8 {
    const pipe = popen("pmset -g batt", "r") orelse return null;
    defer _ = pclose(pipe);

    var buf: [512]u8 = undefined;
    var total: usize = 0;

    while (total < buf.len) {
        const ch = fgetc(pipe);
        if (ch < 0) break; // EOF
        buf[total] = @intCast(@as(u32, @bitCast(ch)));
        total += 1;
    }

    // Parse output like: "InternalBattery-0 (id=...) 42%; charging..."
    // Look for a number followed by %
    const output = buf[0..total];
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (output[i] == '%') {
            // Walk back to find the number
            const end = i;
            var start = end;
            while (start > 0 and output[start - 1] >= '0' and output[start - 1] <= '9') {
                start -= 1;
            }
            if (start < end) {
                return std.fmt.parseInt(u8, output[start..end], 10) catch null;
            }
        }
    }
    return null;
}

/// Read battery percentage on Linux from /sys/class/power_supply/
fn getBatteryLinux() ?u8 {
    const file = std.Io.Dir.cwd().openFile(
        std.Options.debug_io,
        "/sys/class/power_supply/BAT0/capacity",
        .{},
    ) catch return null;
    defer file.close(std.Options.debug_io);

    var buf: [8]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(std.Options.debug_io, &.{buf[total..]}) catch break;
        if (n == 0) break;
        total += n;
    }

    const trimmed = std.mem.trim(u8, buf[0..total], &std.ascii.whitespace);
    return std.fmt.parseInt(u8, trimmed, 10) catch null;
}
