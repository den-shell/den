const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

/// Log levels
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn asString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
        };
    }
};

/// Logger configuration
pub const Config = struct {
    level: Level = .info,
    use_color: bool = true,
    show_timestamp: bool = true,
    show_file: bool = true,
    show_line: bool = true,
    output_file: ?std.Io.File = null,
};

/// Global logger instance
var global_logger: Logger = undefined;
var global_logger_initialized: bool = false;

/// Initialize the global logger
pub fn init(allocator: std.mem.Allocator, config: Config) !void {
    global_logger = Logger.init(allocator, config);
    global_logger_initialized = true;
}

/// Deinitialize the global logger
pub fn deinit() void {
    if (global_logger_initialized) {
        global_logger.deinit();
        global_logger_initialized = false;
    }
}

/// Get the global logger
pub fn getLogger() *Logger {
    if (!global_logger_initialized) {
        @panic("Logger not initialized. Call log.init() first.");
    }
    return &global_logger;
}

/// Logger implementation
pub const Logger = struct {
    allocator: std.mem.Allocator,
    config: Config,
    mutex: compat.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Logger {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Logger) void {
        _ = self;
        // Currently no cleanup needed
    }

    /// Set the minimum log level
    pub fn setLevel(self: *Logger, level: Level) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.config.level = level;
    }

    /// Log a message with the specified level
    pub fn log(
        self: *Logger,
        level: Level,
        comptime src: std.builtin.SourceLocation,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we should log this level
        if (@intFromEnum(level) < @intFromEnum(self.config.level)) {
            return;
        }

        // Build the log message
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        // Add color if enabled
        if (self.config.use_color) {
            const color_str = level.color();
            const color_len = @min(color_str.len, buf.len - pos);
            @memcpy(buf[pos..][0..color_len], color_str[0..color_len]);
            pos += color_len;
        }

        // Add timestamp if enabled
        if (self.config.show_timestamp) {
            const now = compat.Instant.now() catch std.mem.zeroes(compat.Instant);
            const timestamp: i64 = if (comptime builtin.os.tag == .windows)
                @intCast(now.timestamp / 10_000_000)
            else
                now.timestamp.sec;
            const seconds = @mod(timestamp, 86400);
            const hours = @divTrunc(seconds, 3600);
            const minutes = @divTrunc(@mod(seconds, 3600), 60);
            const secs = @mod(seconds, 60);
            pos += (std.fmt.bufPrint(buf[pos..], "[{d:0>2}:{d:0>2}:{d:0>2}] ", .{ hours, minutes, secs }) catch return).len;
        }

        // Add level
        pos += (std.fmt.bufPrint(buf[pos..], "[{s}] ", .{level.asString()}) catch return).len;

        // Add file and line if enabled
        if (self.config.show_file or self.config.show_line) {
            buf[pos] = '[';
            pos += 1;
            if (self.config.show_file) {
                // Extract just the filename from the full path
                const file = std.fs.path.basename(src.file);
                const file_len = @min(file.len, buf.len - pos);
                @memcpy(buf[pos..][0..file_len], file[0..file_len]);
                pos += file_len;
            }
            if (self.config.show_line) {
                if (self.config.show_file) {
                    buf[pos] = ':';
                    pos += 1;
                }
                pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{src.line}) catch return).len;
            }
            const suffix = "] ";
            const suffix_len = @min(suffix.len, buf.len - pos);
            @memcpy(buf[pos..][0..suffix_len], suffix[0..suffix_len]);
            pos += suffix_len;
        }

        // Add the formatted message
        pos += (std.fmt.bufPrint(buf[pos..], fmt, args) catch return).len;

        // Reset color if enabled
        if (self.config.use_color) {
            const reset = "\x1b[0m";
            const reset_len = @min(reset.len, buf.len - pos);
            @memcpy(buf[pos..][0..reset_len], reset[0..reset_len]);
            pos += reset_len;
        }

        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }

        // Write to stderr by default
        const output = buf[0..pos];
        if (self.config.output_file) |file| {
            file.writeStreamingAll(std.Options.debug_io, output) catch {};
        } else {
            const stderr = std.Io.File{ .handle = if (builtin.os.tag == .windows)
                (@import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return)
            else
                std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
            stderr.writeStreamingAll(std.Options.debug_io, output) catch {};
        }
    }

    /// Convenience methods for each log level
    pub fn debug(self: *Logger, comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, src, fmt, args);
    }

    pub fn info(self: *Logger, comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, src, fmt, args);
    }

    pub fn warn(self: *Logger, comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, src, fmt, args);
    }

    pub fn err(self: *Logger, comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, src, fmt, args);
    }

    pub fn fatal(self: *Logger, comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, src, fmt, args);
    }
};

/// Convenience macros for logging with automatic source location
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    getLogger().debug(@src(), fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    getLogger().info(@src(), fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    getLogger().warn(@src(), fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    getLogger().err(@src(), fmt, args);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    getLogger().fatal(@src(), fmt, args);
}
