const std = @import("std");
const builtin = @import("builtin");

/// ANSI escape sequence codes
pub const ESC = "\x1b";
pub const CSI = ESC ++ "[";
pub const OSC = ESC ++ "]";

/// Color type for 8-bit and 24-bit colors
pub const Color = union(enum) {
    /// Standard 16 colors (0-15)
    basic: u8,
    /// 256 color palette (0-255)
    palette: u8,
    /// 24-bit RGB color
    rgb: struct { r: u8, g: u8, b: u8 },

    /// Create a basic color (0-15)
    pub fn fromBasic(index: u8) Color {
        return .{ .basic = index };
    }

    /// Create a palette color (0-255)
    pub fn fromPalette(index: u8) Color {
        return .{ .palette = index };
    }

    /// Create an RGB color
    pub fn fromRGB(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Parse hex color string (#RRGGBB) to RGB color
    pub fn fromHex(hex: []const u8) !Color {
        if (hex.len != 7 or hex[0] != '#') {
            return error.InvalidHexColor;
        }

        const r = try std.fmt.parseInt(u8, hex[1..3], 16);
        const g = try std.fmt.parseInt(u8, hex[3..5], 16);
        const b = try std.fmt.parseInt(u8, hex[5..7], 16);

        return Color.fromRGB(r, g, b);
    }

    /// Convert color to foreground ANSI sequence
    pub fn toForeground(self: Color, buf: []u8) ![]const u8 {
        return switch (self) {
            .basic => |idx| blk: {
                const code = 30 + (idx % 8) + (if (idx >= 8) @as(u8, 60) else @as(u8, 0));
                break :blk try std.fmt.bufPrint(buf, "\x1b[{d}m", .{code});
            },
            .palette => |idx| try std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{idx}),
            .rgb => |c| try std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        };
    }

    /// Convert color to background ANSI sequence
    pub fn toBackground(self: Color, buf: []u8) ![]const u8 {
        return switch (self) {
            .basic => |idx| blk: {
                const code = 40 + (idx % 8) + (if (idx >= 8) @as(u8, 60) else @as(u8, 0));
                break :blk try std.fmt.bufPrint(buf, "\x1b[{d}m", .{code});
            },
            .palette => |idx| try std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{idx}),
            .rgb => |c| try std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        };
    }
};

/// Standard colors (0-15) as simple ANSI strings
pub const Colors = struct {
    // Normal colors (0-7)
    pub const black = "\x1b[30m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";

    // Bright colors (8-15)
    pub const bright_black = "\x1b[90m";
    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_magenta = "\x1b[95m";
    pub const bright_cyan = "\x1b[96m";
    pub const bright_white = "\x1b[97m";
};

/// Text styles/attributes
pub const Style = enum(u8) {
    reset = 0,
    bold = 1,
    dim = 2,
    italic = 3,
    underline = 4,
    blink = 5,
    reverse = 7,
    hidden = 8,
    strikethrough = 9,

    // Reset individual attributes
    reset_bold = 22,
    reset_italic = 23,
    reset_underline = 24,
    reset_blink = 25,
    reset_reverse = 27,
    reset_hidden = 28,
    reset_strikethrough = 29,

    /// Convert style to ANSI escape sequence
    pub fn toSequence(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .italic => "\x1b[3m",
            .underline => "\x1b[4m",
            .blink => "\x1b[5m",
            .reverse => "\x1b[7m",
            .hidden => "\x1b[8m",
            .strikethrough => "\x1b[9m",
            .reset_bold => "\x1b[22m",
            .reset_italic => "\x1b[23m",
            .reset_underline => "\x1b[24m",
            .reset_blink => "\x1b[25m",
            .reset_reverse => "\x1b[27m",
            .reset_hidden => "\x1b[28m",
            .reset_strikethrough => "\x1b[29m",
        };
    }
};

/// ANSI sequence builder for creating complex terminal control sequences
pub const Builder = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .buffer = std.ArrayList(u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *Builder) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn build(self: *Builder) ![]const u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    pub fn getString(self: *const Builder) []const u8 {
        return self.buffer.items;
    }

    /// Append raw text
    pub fn text(self: *Builder, str: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, str);
    }

    /// Set foreground color
    pub fn fg(self: *Builder, color: Color) !void {
        try self.buffer.appendSlice(self.allocator, CSI);
        var buf: [32]u8 = undefined;
        const result = switch (color) {
            .basic => |idx| if (idx < 8)
                try std.fmt.bufPrint(&buf, "3{d}m", .{idx})
            else
                try std.fmt.bufPrint(&buf, "9{d}m", .{idx - 8}),
            .palette => |idx| try std.fmt.bufPrint(&buf, "38;5;{d}m", .{idx}),
            .rgb => |c| try std.fmt.bufPrint(&buf, "38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        };
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Set background color
    pub fn bg(self: *Builder, color: Color) !void {
        try self.buffer.appendSlice(self.allocator, CSI);
        var buf: [32]u8 = undefined;
        const result = switch (color) {
            .basic => |idx| if (idx < 8)
                try std.fmt.bufPrint(&buf, "4{d}m", .{idx})
            else
                try std.fmt.bufPrint(&buf, "10{d}m", .{idx - 8}),
            .palette => |idx| try std.fmt.bufPrint(&buf, "48;5;{d}m", .{idx}),
            .rgb => |c| try std.fmt.bufPrint(&buf, "48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        };
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Set text style
    pub fn style(self: *Builder, s: Style) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}m", .{@intFromEnum(s)});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor up
    pub fn cursorUp(self: *Builder, n: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}A", .{n});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor down
    pub fn cursorDown(self: *Builder, n: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}B", .{n});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor forward (right)
    pub fn cursorForward(self: *Builder, n: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}C", .{n});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor backward (left)
    pub fn cursorBackward(self: *Builder, n: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}D", .{n});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor to next line
    pub fn cursorNextLine(self: *Builder, n: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}E", .{n});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor to previous line
    pub fn cursorPrevLine(self: *Builder, n: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}F", .{n});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor to column
    pub fn cursorToColumn(self: *Builder, col: u32) !void {
        var buf: [16]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d}G", .{col});
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor to position (1-indexed)
    pub fn cursorTo(self: *Builder, row: u32, col: u32) !void {
        var buf: [24]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, CSI ++ "{d};{d}H", .{ row, col });
        try self.buffer.appendSlice(self.allocator, result);
    }

    /// Move cursor to home position (1,1)
    pub fn cursorHome(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "H");
    }

    /// Move cursor to end
    pub fn cursorEnd(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "F");
    }

    /// Save cursor position
    pub fn saveCursor(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "s");
    }

    /// Restore cursor position
    pub fn restoreCursor(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "u");
    }

    /// Clear screen
    pub fn clearScreen(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "2J");
    }

    /// Clear screen from cursor to end
    pub fn clearToEnd(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "0J");
    }

    /// Clear screen from cursor to beginning
    pub fn clearToBegin(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "1J");
    }

    /// Clear line
    pub fn clearLine(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "2K");
    }

    /// Clear line from cursor to end
    pub fn clearLineToEnd(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "0K");
    }

    /// Clear line from cursor to beginning
    pub fn clearLineToBegin(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "1K");
    }

    /// Hide cursor
    pub fn hideCursor(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "?25l");
    }

    /// Show cursor
    pub fn showCursor(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "?25h");
    }

    /// Enable alternative screen buffer
    pub fn altScreenEnable(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "?1049h");
    }

    /// Disable alternative screen buffer
    pub fn altScreenDisable(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "?1049l");
    }

    /// Enable mouse tracking
    pub fn mouseTrackingEnable(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "?1000h");
    }

    /// Disable mouse tracking
    pub fn mouseTrackingDisable(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "?1000l");
    }

    /// Request cursor position (response comes via stdin)
    pub fn requestCursorPosition(self: *Builder) !void {
        try self.buffer.appendSlice(self.allocator, CSI ++ "6n");
    }

    /// Scroll up
    pub fn scrollUp(self: *Builder, n: u32) !void {
        try self.buffer.writer(self.allocator).print(CSI ++ "{d}S", .{n});
    }

    /// Scroll down
    pub fn scrollDown(self: *Builder, n: u32) !void {
        try self.buffer.writer(self.allocator).print(CSI ++ "{d}T", .{n});
    }
};

/// Direct ANSI sequence functions (no allocation)
pub const Sequences = struct {
    // Reset
    pub const reset = CSI ++ "0m";

    // Cursor movement
    pub fn cursorUp(n: u32) [16]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, CSI ++ "{d}A", .{n}) catch unreachable;
        return buf;
    }

    pub fn cursorDown(n: u32) [16]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, CSI ++ "{d}B", .{n}) catch unreachable;
        return buf;
    }

    pub fn cursorForward(n: u32) [16]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, CSI ++ "{d}C", .{n}) catch unreachable;
        return buf;
    }

    pub fn cursorBackward(n: u32) [16]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, CSI ++ "{d}D", .{n}) catch unreachable;
        return buf;
    }

    pub fn cursorTo(row: u32, col: u32) [32]u8 {
        var buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, CSI ++ "{d};{d}H", .{ row, col }) catch unreachable;
        return buf;
    }

    // Cursor visibility
    pub const hide_cursor = CSI ++ "?25l";
    pub const show_cursor = CSI ++ "?25h";
    pub const cursor_home = CSI ++ "H";

    // Save/restore
    pub const save_cursor = CSI ++ "s";
    pub const restore_cursor = CSI ++ "u";

    // Clear operations
    pub const clear_screen = CSI ++ "2J";
    pub const clear_to_end = CSI ++ "0J";
    pub const clear_to_begin = CSI ++ "1J";
    pub const clear_line = CSI ++ "2K";
    pub const clear_line_to_end = CSI ++ "0K";
    pub const clear_line_to_begin = CSI ++ "1K";

    // Alternative screen
    pub const alt_screen_enable = CSI ++ "?1049h";
    pub const alt_screen_disable = CSI ++ "?1049l";

    // Mouse tracking
    pub const mouse_tracking_enable = CSI ++ "?1000h";
    pub const mouse_tracking_disable = CSI ++ "?1000l";

    // Cursor position query
    pub const request_cursor_position = CSI ++ "6n";
};

/// Terminal size
pub const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

/// Get terminal size (cross-platform)
pub fn getTerminalSize() !TerminalSize {
    if (builtin.os.tag == .windows) {
        return getTerminalSizeWindows();
    } else {
        return getTerminalSizeUnix();
    }
}

/// Get terminal size on Unix-like systems
fn getTerminalSizeUnix() !TerminalSize {
    var winsize: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (result < 0) return error.IoctlFailed;

    return .{
        .rows = winsize.row,
        .cols = winsize.col,
    };
}

/// Get terminal size on Windows
fn getTerminalSizeWindows() !TerminalSize {
    const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.GetStdHandleFailed;

    var info: @import("windows_compat").CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (@import("windows_compat").GetConsoleScreenBufferInfo(handle, &info) == 0) {
        return error.GetConsoleInfoFailed;
    }

    const width = info.srWindow.Right - info.srWindow.Left + 1;
    const height = info.srWindow.Bottom - info.srWindow.Top + 1;

    return .{
        .rows = @intCast(height),
        .cols = @intCast(width),
    };
}

/// Check if stdout is a terminal
pub fn isTerminal() bool {
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return false;
        var mode: win.DWORD = 0;
        return @import("windows_compat").GetConsoleMode(handle, &mode) != 0;
    } else {
        return (std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } }).isTty(std.Options.debug_io) catch false;
    }
}

/// Terminal output helper
pub const Output = struct {
    /// Write to stdout
    pub fn write(bytes: []const u8) !void {
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(std.Options.debug_io, bytes);
    }

    /// Write to stderr
    pub fn writeErr(bytes: []const u8) !void {
        const stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(std.Options.debug_io, bytes);
    }

    /// Print with ANSI formatting
    pub fn print(comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, fmt, args);
        try write(str);
    }
};

/// Enable/disable raw mode
pub const RawMode = struct {
    original_termios: if (builtin.os.tag == .windows) ?u32 else ?std.posix.termios = null,
    original_output_mode: if (builtin.os.tag == .windows) ?u32 else void = if (builtin.os.tag == .windows) null else {},
    is_raw: bool = false,

    /// Enable raw mode
    pub fn enable(self: *RawMode) !void {
        if (self.is_raw) return;

        if (builtin.os.tag == .windows) {
            try self.enableWindows();
        } else {
            try self.enableUnix();
        }

        self.is_raw = true;
    }

    /// Disable raw mode
    pub fn disable(self: *RawMode) !void {
        if (!self.is_raw) return;

        if (builtin.os.tag == .windows) {
            try self.disableWindows();
        } else {
            try self.disableUnix();
        }

        self.is_raw = false;
    }

    fn enableWindows(self: *RawMode) !void {
        const win = std.os.windows;

        // Setup input mode
        const stdin_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.GetStdHandleFailed;
        var input_mode: win.DWORD = 0;
        if (@import("windows_compat").GetConsoleMode(stdin_handle, &input_mode) == 0) {
            return error.GetConsoleModeFailed;
        }
        self.original_termios = input_mode;

        // Disable line input, echo input, and processed input
        var new_input_mode = input_mode;
        new_input_mode &= ~@as(win.DWORD, 0x0002); // ENABLE_LINE_INPUT
        new_input_mode &= ~@as(win.DWORD, 0x0004); // ENABLE_ECHO_INPUT
        new_input_mode &= ~@as(win.DWORD, 0x0001); // ENABLE_PROCESSED_INPUT
        new_input_mode |= 0x0200; // ENABLE_VIRTUAL_TERMINAL_INPUT

        if (@import("windows_compat").SetConsoleMode(stdin_handle, new_input_mode) == 0) {
            return error.SetConsoleModeFailed;
        }

        // Setup output mode for ANSI support
        const stdout_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.GetStdHandleFailed;
        var output_mode: win.DWORD = 0;
        if (@import("windows_compat").GetConsoleMode(stdout_handle, &output_mode) == 0) {
            return error.GetConsoleModeFailed;
        }
        self.original_output_mode = output_mode;

        // Enable virtual terminal processing
        var new_output_mode = output_mode;
        new_output_mode |= 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING

        if (@import("windows_compat").SetConsoleMode(stdout_handle, new_output_mode) == 0) {
            return error.SetConsoleModeFailed;
        }
    }

    fn disableWindows(self: *RawMode) !void {
        const stdin_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.GetStdHandleFailed;
        if (self.original_termios) |mode| {
            if (@import("windows_compat").SetConsoleMode(stdin_handle, mode) == 0) {
                return error.SetConsoleModeFailed;
            }
        }

        const stdout_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.GetStdHandleFailed;
        if (self.original_output_mode) |mode| {
            if (@import("windows_compat").SetConsoleMode(stdout_handle, mode) == 0) {
                return error.SetConsoleModeFailed;
            }
        }
    }

    fn enableUnix(self: *RawMode) !void {
        const stdin_fd = std.posix.STDIN_FILENO;

        // Get current terminal settings
        var termios = try std.posix.tcgetattr(stdin_fd);
        self.original_termios = termios;

        // Modify for raw mode
        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        termios.lflag.ISIG = false;
        termios.lflag.IEXTEN = false;

        termios.iflag.IXON = false;
        termios.iflag.ICRNL = false;
        termios.iflag.BRKINT = false;
        termios.iflag.INPCK = false;
        termios.iflag.ISTRIP = false;

        termios.oflag.OPOST = false;

        termios.cflag.CSIZE = .CS8;

        // Set minimum read size and timeout
        termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, termios);
    }

    fn disableUnix(self: *RawMode) !void {
        const stdin_fd = std.posix.STDIN_FILENO;

        if (self.original_termios) |termios| {
            try std.posix.tcsetattr(stdin_fd, .FLUSH, termios);
        }
    }
};
