const std = @import("std");
const color_mod = @import("color.zig");

const ColorSupport = color_mod.ColorSupport;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const value = getenv(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

fn getEnvSlice(key: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const result = std.c.getenv(buf[0..key.len :0]) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn getEnvSliceOwned(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    const value = getEnvSlice(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// Terminal capabilities
pub const TerminalCapabilities = struct {
    is_tty: bool,
    color_support: ColorSupport,
    width: usize,
    height: usize,
    supports_unicode: bool,
    supports_emoji: bool,

    pub fn detect(allocator: std.mem.Allocator) !TerminalCapabilities {
        const is_tty = isTTY();
        const color_support = detectColorSupport(allocator);
        const size = getTerminalSize();
        const supports_unicode = detectUnicodeSupport(allocator);

        return .{
            .is_tty = is_tty,
            .color_support = color_support,
            .width = size.width,
            .height = size.height,
            .supports_unicode = supports_unicode,
            .supports_emoji = supports_unicode and color_support != .none,
        };
    }

    pub fn shouldUseColor(self: *const TerminalCapabilities) bool {
        return self.is_tty and self.color_support != .none;
    }

    pub fn shouldUseFancySymbols(self: *const TerminalCapabilities) bool {
        return self.is_tty and self.supports_unicode;
    }
};

/// Terminal size
pub const TerminalSize = struct {
    width: usize,
    height: usize,
};

/// Check if stdout is a TTY
pub fn isTTY() bool {
    if (comptime @import("builtin").os.tag == .windows) {
        const win = std.os.windows;
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return false;
        var mode: win.DWORD = 0;
        return win.kernel32.GetConsoleMode(handle, &mode) != 0;
    } else {
        return std.c.isatty(std.posix.STDOUT_FILENO) != 0;
    }
}

/// Detect color support level
pub fn detectColorSupport(allocator: std.mem.Allocator) ColorSupport {

    // Check NO_COLOR environment variable
    if (getEnvOwned(allocator, "NO_COLOR")) |no_color| {
        defer allocator.free(no_color);
        if (no_color.len > 0) return .none;
    }

    // Check COLORTERM environment variable
    if (getEnvOwned(allocator, "COLORTERM")) |colorterm| {
        defer allocator.free(colorterm);
        return ColorSupport.fromColorterm(colorterm);
    }

    // Check TERM environment variable
    if (getEnvOwned(allocator, "TERM")) |term| {
        defer allocator.free(term);

        if (std.mem.indexOf(u8, term, "256color") != null) {
            return .extended;
        }

        if (std.mem.indexOf(u8, term, "color") != null) {
            return .basic;
        }

        if (std.mem.eql(u8, term, "dumb")) {
            return .none;
        }
    }

    // Default to basic color support
    return .basic;
}

/// Get terminal size
pub fn getTerminalSize() TerminalSize {
    // Try to get from environment first
    if (getTerminalSizeFromEnv()) |size| {
        return size;
    }

    // Try ioctl on Unix systems
    if (@import("builtin").os.tag != .windows) {
        if (getTerminalSizeUnix()) |size| {
            return size;
        }
    }

    // Fallback to default size
    return .{ .width = 80, .height = 24 };
}

/// Get terminal size from environment variables
fn getTerminalSizeFromEnv() ?TerminalSize {
    const allocator = std.heap.page_allocator;

    const columns = getEnvOwned(allocator, "COLUMNS") orelse return null;
    defer allocator.free(columns);

    const lines = getEnvOwned(allocator, "LINES") orelse return null;
    defer allocator.free(lines);

    const width = std.fmt.parseInt(usize, columns, 10) catch return null;
    const height = std.fmt.parseInt(usize, lines, 10) catch return null;

    return .{ .width = width, .height = height };
}

/// Get terminal size using ioctl (Unix)
fn getTerminalSizeUnix() ?TerminalSize {
    if (@import("builtin").os.tag == .windows) return null;

    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result != 0) {
        return null;
    }

    return .{
        .width = @as(usize, @intCast(ws.col)),
        .height = @as(usize, @intCast(ws.row)),
    };
}

/// Detect Unicode support
pub fn detectUnicodeSupport(allocator: std.mem.Allocator) bool {
    // Check LANG environment variable
    if (getEnvOwned(allocator, "LANG")) |lang| {
        defer allocator.free(lang);

        // Check for UTF-8 encoding
        if (std.mem.indexOf(u8, lang, "UTF-8") != null or
            std.mem.indexOf(u8, lang, "utf8") != null)
        {
            return true;
        }
    }

    // Check LC_ALL environment variable
    if (getEnvOwned(allocator, "LC_ALL")) |lc_all| {
        defer allocator.free(lc_all);

        if (std.mem.indexOf(u8, lc_all, "UTF-8") != null or
            std.mem.indexOf(u8, lc_all, "utf8") != null)
        {
            return true;
        }
    }

    // Check TERM environment variable
    if (getEnvOwned(allocator, "TERM")) |term| {
        defer allocator.free(term);

        // Some modern terminals
        if (std.mem.eql(u8, term, "xterm-256color") or
            std.mem.eql(u8, term, "screen-256color") or
            std.mem.indexOf(u8, term, "kitty") != null or
            std.mem.indexOf(u8, term, "alacritty") != null)
        {
            return true;
        }
    }

    // Default to false for safety
    return false;
}

/// Detect terminal emulator
pub fn detectTerminalEmulator(allocator: std.mem.Allocator) ?[]const u8 {
    // Check common terminal-specific environment variables
    const vars = [_][]const u8{
        "TERM_PROGRAM", // macOS Terminal, iTerm2
        "KITTY_WINDOW_ID", // Kitty
        "ALACRITTY_SOCKET", // Alacritty
        "WEZTERM_EXECUTABLE", // WezTerm
    };

    for (vars) |var_name| {
        if (getEnvSliceOwned(allocator, var_name)) |value| {
            return value;
        }
    }

    return null;
}

/// Detect if running in tmux or screen
pub fn isMultiplexer(allocator: std.mem.Allocator) bool {
    if (getEnvOwned(allocator, "TMUX")) |tmux| {
        defer allocator.free(tmux);
        return true;
    }

    if (getEnvOwned(allocator, "TERM")) |term| {
        defer allocator.free(term);
        return std.mem.startsWith(u8, term, "screen");
    }

    return false;
}
