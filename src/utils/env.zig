const std = @import("std");
const builtin = @import("builtin");
const cpu_opt = @import("cpu_opt.zig");

/// Windows environment variable cache to avoid memory leaks
/// Uses a simple LRU-style cache with fixed size
const WindowsEnvCache = struct {
    const CACHE_SIZE = 32;
    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    entries: [CACHE_SIZE]?Entry = @splat(null),
    allocator: std.mem.Allocator = std.heap.c_allocator,
    next_slot: usize = 0,

    fn get(self: *WindowsEnvCache, key: []const u8) ?[]const u8 {
        // First check if we already have this key cached
        for (self.entries) |entry_opt| {
            if (entry_opt) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    return entry.value;
                }
            }
        }

        // Not cached, fetch from OS using null-terminated key
        var key_buf: [512]u8 = undefined;
        if (key.len >= key_buf.len) return null;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const raw_value = std.c.getenv(key_buf[0..key.len :0]) orelse return null;
        const raw_span = std.mem.span(@as([*:0]const u8, @ptrCast(raw_value)));
        const value = self.allocator.dupe(u8, raw_span) catch return null;
        const key_copy = self.allocator.dupe(u8, key) catch {
            self.allocator.free(value);
            return null;
        };

        // Free old entry if slot is occupied
        if (self.entries[self.next_slot]) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        // Store in cache
        self.entries[self.next_slot] = Entry{
            .key = key_copy,
            .value = value,
        };
        self.next_slot = (self.next_slot + 1) % CACHE_SIZE;

        return value;
    }
};

/// Thread-local cache for Windows environment variables
threadlocal var windows_env_cache: WindowsEnvCache = .{};

/// Cross-platform environment variable access (returns pointer to static data - don't free)
/// On POSIX: returns pointer to static env data
/// On Windows: uses thread-local storage to cache values (still don't free - managed internally)
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // Windows: use thread-local cache to avoid memory leaks
        // The cache manages its own memory and reuses slots
        return windows_env_cache.get(key);
    }
    // POSIX: use libc getenv (posix.getenv removed in Zig 0.16)
    var buf: [512]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const result = std.c.getenv(buf[0..key.len :0]) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

/// Get environment variable and allocate a copy (cross-platform)
/// Caller owns returned memory
pub fn getEnvAlloc(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const value = getEnv(key) orelse return null;
    return try allocator.dupe(u8, value);
}

/// Platform information
pub const Platform = enum {
    linux,
    macos,
    windows,
    freebsd,
    openbsd,
    netbsd,
    dragonfly,
    solaris,
    illumos,
    haiku,
    unknown,

    /// Get the current platform
    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            .freebsd => .freebsd,
            .openbsd => .openbsd,
            .netbsd => .netbsd,
            .dragonfly => .dragonfly,
            .solaris => .solaris,
            .illumos => .illumos,
            .haiku => .haiku,
            else => .unknown,
        };
    }

    /// Get platform name as string
    pub fn name(self: Platform) []const u8 {
        return switch (self) {
            .linux => "Linux",
            .macos => "macOS",
            .windows => "Windows",
            .freebsd => "FreeBSD",
            .openbsd => "OpenBSD",
            .netbsd => "NetBSD",
            .dragonfly => "DragonFly BSD",
            .solaris => "Solaris",
            .illumos => "illumos",
            .haiku => "Haiku",
            .unknown => "Unknown",
        };
    }

    /// Check if platform is Unix-like
    pub fn isUnix(self: Platform) bool {
        return switch (self) {
            .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .solaris, .illumos => true,
            .windows, .haiku, .unknown => false,
        };
    }

    /// Check if platform is BSD
    pub fn isBSD(self: Platform) bool {
        return switch (self) {
            .freebsd, .openbsd, .netbsd, .dragonfly, .macos => true,
            else => false,
        };
    }
};

/// Architecture information
pub const Architecture = enum {
    x86_64,
    aarch64,
    arm,
    x86,
    riscv64,
    powerpc64,
    powerpc,
    mips64,
    mips,
    sparc64,
    unknown,

    /// Get the current architecture
    pub fn current() Architecture {
        return switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .arm => .arm,
            .x86 => .x86,
            .riscv64 => .riscv64,
            .powerpc64 => .powerpc64,
            .powerpc => .powerpc,
            .mips64 => .mips64,
            .mips => .mips,
            .sparc64 => .sparc64,
            else => .unknown,
        };
    }

    /// Get architecture name as string
    pub fn name(self: Architecture) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            .x86 => "x86",
            .riscv64 => "riscv64",
            .powerpc64 => "powerpc64",
            .powerpc => "powerpc",
            .mips64 => "mips64",
            .mips => "mips",
            .sparc64 => "sparc64",
            .unknown => "unknown",
        };
    }

    /// Get bit width
    pub fn bits(self: Architecture) u8 {
        return switch (self) {
            .x86_64, .aarch64, .riscv64, .powerpc64, .mips64, .sparc64 => 64,
            .arm, .x86, .powerpc, .mips => 32,
            .unknown => 0,
        };
    }
};

/// System information
pub const SystemInfo = struct {
    platform: Platform,
    architecture: Architecture,

    pub fn current() SystemInfo {
        return .{
            .platform = Platform.current(),
            .architecture = Architecture.current(),
        };
    }

    /// Format as "platform-architecture" (e.g., "Linux-x86_64")
    pub fn format(
        self: SystemInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}-{s}", .{ self.platform.name(), self.architecture.name() });
    }
};

/// PATH environment variable utilities
pub const PathList = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8),

    /// Parse PATH environment variable
    pub fn fromEnv(allocator: std.mem.Allocator) !PathList {
        const path_str = getEnv("PATH") orelse return PathList{
            .allocator = allocator,
            .paths = std.ArrayList([]const u8).empty,
        };

        return try parse(allocator, path_str);
    }

    /// Parse PATH string
    pub fn parse(allocator: std.mem.Allocator, path_str: []const u8) !PathList {
        var paths = std.ArrayList([]const u8).empty;
        errdefer paths.deinit(allocator);

        const separator = if (builtin.os.tag == .windows) ';' else ':';
        var iter = std.mem.splitScalar(u8, path_str, separator);

        while (iter.next()) |path| {
            if (path.len > 0) {
                const owned = try allocator.dupe(u8, path);
                try paths.append(allocator, owned);
            }
        }

        return .{
            .allocator = allocator,
            .paths = paths,
        };
    }

    pub fn deinit(self: *PathList) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit(self.allocator);
    }

    /// Get number of paths
    pub fn count(self: *const PathList) usize {
        return self.paths.items.len;
    }

    /// Get path at index
    pub fn get(self: *const PathList, index: usize) ?[]const u8 {
        if (index >= self.paths.items.len) return null;
        return self.paths.items[index];
    }

    /// Check if a path exists in the list
    pub fn contains(self: *const PathList, path: []const u8) bool {
        for (self.paths.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    /// Windows executable extensions (checked in order)
    const windows_exe_extensions = [_][]const u8{ ".exe", ".com", ".bat", ".cmd", ".ps1" };

    /// Find executable in PATH
    pub fn findExecutable(self: *const PathList, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
        for (self.paths.items) |path_dir| {
            if (builtin.os.tag == .windows) {
                // On Windows, check for executable extensions
                // First, try the name as-is (might already have extension)
                if (try self.checkWindowsExecutable(allocator, path_dir, name)) |result| {
                    return result;
                }

                // If no extension, try common executable extensions
                if (std.mem.indexOfScalar(u8, name, '.') == null) {
                    for (windows_exe_extensions) |ext| {
                        var name_with_ext_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const name_with_ext = std.fmt.bufPrint(&name_with_ext_buf, "{s}{s}", .{ name, ext }) catch continue;
                        if (try self.checkWindowsExecutable(allocator, path_dir, name_with_ext)) |result| {
                            return result;
                        }
                    }
                }
            } else {
                // On Unix, check if executable via stat (no open/close needed)
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_dir, name });
                defer allocator.free(full_path);

                const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, full_path, .{}) catch continue;
                if (stat.kind != .file) continue;
                if (stat.permissions.toMode() & 0o111 == 0) continue; // Not executable

                return try allocator.dupe(u8, full_path);
            }
        }

        return null;
    }

    /// Find all executables with given name in PATH (for `which -a`)
    pub fn findAllExecutables(self: *const PathList, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        var results = std.ArrayList([]const u8).empty;
        errdefer {
            for (results.items) |item| allocator.free(item);
            results.deinit(allocator);
        }

        for (self.paths.items) |path_dir| {
            if (builtin.os.tag == .windows) {
                // On Windows, check for executable extensions
                if (try self.checkWindowsExecutable(allocator, path_dir, name)) |result| {
                    try results.append(allocator, result);
                }
                // If no extension, try common executable extensions
                if (std.mem.indexOfScalar(u8, name, '.') == null) {
                    for (windows_exe_extensions) |ext| {
                        var name_with_ext_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const name_with_ext = std.fmt.bufPrint(&name_with_ext_buf, "{s}{s}", .{ name, ext }) catch continue;
                        if (try self.checkWindowsExecutable(allocator, path_dir, name_with_ext)) |result| {
                            try results.append(allocator, result);
                        }
                    }
                }
            } else {
                // On Unix, check if executable via mode bits
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_dir, name });

                // Check if file exists and is accessible
                std.Io.Dir.accessAbsolute(std.Options.debug_io, full_path, .{}) catch {
                    allocator.free(full_path);
                    continue;
                };

                const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, full_path, .{}) catch {
                    allocator.free(full_path);
                    continue;
                };
                defer file.close(std.Options.debug_io);

                const stat = file.stat(std.Options.debug_io) catch {
                    allocator.free(full_path);
                    continue;
                };

                if (stat.permissions.toMode() & 0o111 == 0) {
                    allocator.free(full_path);
                    continue;
                }

                try results.append(allocator, full_path);
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Check if a file exists and is an executable on Windows
    fn checkWindowsExecutable(self: *const PathList, allocator: std.mem.Allocator, path_dir: []const u8, name: []const u8) !?[]const u8 {
        _ = self;
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_dir, name });
        errdefer allocator.free(full_path);

        // Check if file exists
        std.Io.Dir.accessAbsolute(std.Options.debug_io, full_path, .{}) catch {
            allocator.free(full_path);
            return null;
        };

        // Verify it has a valid executable extension
        const has_valid_ext = blk: {
            for (windows_exe_extensions) |ext| {
                if (std.ascii.endsWithIgnoreCase(full_path, ext)) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (has_valid_ext) {
            return full_path;
        }

        allocator.free(full_path);
        return null;
    }

    /// Convert back to PATH string
    pub fn toString(self: *const PathList, allocator: std.mem.Allocator) ![]const u8 {
        if (self.paths.items.len == 0) return try allocator.dupe(u8, "");

        const separator = if (builtin.os.tag == .windows) ";" else ":";
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        for (self.paths.items, 0..) |path, i| {
            try result.appendSlice(allocator, path);
            if (i < self.paths.items.len - 1) {
                try result.appendSlice(allocator, separator);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Add path to the list
    pub fn add(self: *PathList, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        try self.paths.append(self.allocator, owned);
    }

    /// Remove path at index
    pub fn remove(self: *PathList, index: usize) void {
        if (index >= self.paths.items.len) return;
        const path = self.paths.orderedRemove(index);
        self.allocator.free(path);
    }

    /// Clear all paths
    pub fn clear(self: *PathList) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.clearRetainingCapacity();
    }
};

/// Cache for executable path lookups
/// Uses LRU eviction with 64 entries - enough for most common commands
pub const ExecutableCache = struct {
    const CACHE_SIZE = 64;

    /// Cache entry: command name -> full path
    const Entry = struct {
        name: []const u8,
        path: []const u8,
        age: u64,
    };

    entries: [CACHE_SIZE]?Entry,
    allocator: std.mem.Allocator,
    current_age: u64,
    hits: u64,
    misses: u64,

    pub fn init(allocator: std.mem.Allocator) ExecutableCache {
        return .{
            .entries = @splat(null),
            .allocator = allocator,
            .current_age = 0,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *ExecutableCache) void {
        for (&self.entries) |*entry_opt| {
            if (entry_opt.*) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.path);
                entry_opt.* = null;
            }
        }
    }

    /// Look up cached path for a command
    pub fn get(self: *ExecutableCache, name: []const u8) ?[]const u8 {
        for (&self.entries) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) {
                    entry.age = self.current_age;
                    self.current_age +%= 1;
                    self.hits += 1;
                    return entry.path;
                }
            }
        }
        self.misses += 1;
        return null;
    }

    /// Cache a command path lookup result
    pub fn put(self: *ExecutableCache, name: []const u8, path: []const u8) void {
        // Check if already exists
        for (&self.entries) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) {
                    // Update existing entry
                    self.allocator.free(entry.path);
                    entry.path = self.allocator.dupe(u8, path) catch return;
                    entry.age = self.current_age;
                    self.current_age +%= 1;
                    return;
                }
            }
        }

        // Find empty slot or evict oldest
        var oldest_idx: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);

        for (self.entries, 0..) |entry_opt, i| {
            if (entry_opt == null) {
                // Found empty slot
                self.entries[i] = Entry{
                    .name = self.allocator.dupe(u8, name) catch return,
                    .path = self.allocator.dupe(u8, path) catch return,
                    .age = self.current_age,
                };
                self.current_age +%= 1;
                return;
            } else if (entry_opt.?.age < oldest_age) {
                oldest_age = entry_opt.?.age;
                oldest_idx = i;
            }
        }

        // Evict oldest entry
        if (self.entries[oldest_idx]) |old_entry| {
            self.allocator.free(old_entry.name);
            self.allocator.free(old_entry.path);
        }

        self.entries[oldest_idx] = Entry{
            .name = self.allocator.dupe(u8, name) catch return,
            .path = self.allocator.dupe(u8, path) catch return,
            .age = self.current_age,
        };
        self.current_age +%= 1;
    }

    /// Invalidate cache entry (call when PATH changes)
    pub fn invalidate(self: *ExecutableCache, name: []const u8) void {
        for (&self.entries) |*entry_opt| {
            if (entry_opt.*) |entry| {
                if (std.mem.eql(u8, entry.name, name)) {
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.path);
                    entry_opt.* = null;
                    return;
                }
            }
        }
    }

    /// Clear entire cache (call when PATH is modified)
    pub fn clear(self: *ExecutableCache) void {
        for (&self.entries) |*entry_opt| {
            if (entry_opt.*) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.path);
                entry_opt.* = null;
            }
        }
        self.current_age = 0;
    }

    /// Get cache statistics
    pub fn getStats(self: *const ExecutableCache) struct { hits: u64, misses: u64, hit_rate: f64 } {
        const total = self.hits + self.misses;
        const hit_rate = if (total > 0) @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) else 0.0;
        return .{ .hits = self.hits, .misses = self.misses, .hit_rate = hit_rate };
    }
};

/// Global executable cache instance
var global_exec_cache: ?ExecutableCache = null;

/// Initialize the global executable cache
pub fn initExecutableCache(allocator: std.mem.Allocator) void {
    if (global_exec_cache == null) {
        global_exec_cache = ExecutableCache.init(allocator);
    }
}

/// Deinitialize the global executable cache
pub fn deinitExecutableCache() void {
    if (global_exec_cache) |*cache| {
        cache.deinit();
        global_exec_cache = null;
    }
}

/// Find executable with caching - O(1) for cached lookups
pub fn findExecutableCached(path_list: *const PathList, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    // Check cache first
    if (global_exec_cache) |*cache| {
        if (cache.get(name)) |cached_path| {
            // Verify the cached path still exists
            std.Io.Dir.accessAbsolute(std.Options.debug_io, cached_path, .{}) catch {
                // Path no longer valid, invalidate and fall through
                cache.invalidate(name);
                return try findAndCacheExecutable(path_list, allocator, name);
            };
            return try allocator.dupe(u8, cached_path);
        }
    }

    return try findAndCacheExecutable(path_list, allocator, name);
}

/// Find executable and cache the result
fn findAndCacheExecutable(path_list: *const PathList, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const result = try path_list.findExecutable(allocator, name);
    if (result) |path| {
        if (global_exec_cache) |*cache| {
            cache.put(name, path);
        }
    }
    return result;
}

/// Invalidate executable cache (call when PATH changes)
pub fn invalidateExecutableCache() void {
    if (global_exec_cache) |*cache| {
        cache.clear();
    }
}

/// Get PATH separator for the current platform
pub fn pathSeparator() u8 {
    return if (builtin.os.tag == .windows) ';' else ':';
}

/// Get directory separator for the current platform
pub fn dirSeparator() u8 {
    return if (builtin.os.tag == .windows) '\\' else '/';
}
