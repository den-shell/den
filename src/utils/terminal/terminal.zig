const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// Windows console mode flags and APIs
pub const windows = if (builtin.os.tag == .windows) struct {
    pub const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
    pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    pub const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
    pub const ENABLE_WRAP_AT_EOL_OUTPUT: u32 = 0x0002;
    pub const ENABLE_LINE_INPUT: u32 = 0x0002;
    pub const ENABLE_ECHO_INPUT: u32 = 0x0004;
    pub const ENABLE_PROCESSED_INPUT: u32 = 0x0001;

    // Windows API functions not in std.os.windows.kernel32
    pub extern "kernel32" fn GetNumberOfConsoleInputEvents(
        hConsoleInput: std.os.windows.HANDLE,
        lpcNumberOfEvents: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

/// Terminal mode management and raw input handling
pub const Terminal = struct {
    original_termios: if (builtin.os.tag == .windows) ?u32 else ?std.posix.termios = null,
    original_output_mode: if (builtin.os.tag == .windows) ?u32 else void = if (builtin.os.tag == .windows) null else {},
    is_raw: bool = false,

    /// Enable raw terminal mode (disable canonical mode, echo, etc.)
    pub fn enableRawMode(self: *Terminal) !void {
        if (builtin.os.tag == .windows) {
            return self.enableRawModeWindows();
        }

        if (self.is_raw) return; // Already in raw mode

        // Get current terminal settings
        const stdin_fd = posix.STDIN_FILENO;
        const original = try std.posix.tcgetattr(stdin_fd);
        self.original_termios = original;

        var raw = original;

        // Disable canonical mode (line buffering)
        raw.lflag.ICANON = false;
        // Disable echo
        raw.lflag.ECHO = false;
        // Disable signal generation (Ctrl+C, Ctrl+Z)
        raw.lflag.ISIG = false;
        // Disable extended input processing
        raw.lflag.IEXTEN = false;

        // Disable input processing (Ctrl+S, Ctrl+Q)
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Disable output processing for raw mode
        raw.oflag.OPOST = false;

        // Set character size to 8 bits
        raw.cflag.CSIZE = .CS8;

        // Minimum number of characters for non-canonical read
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        // Timeout in deciseconds for non-canonical read
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        // Apply the settings
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        self.is_raw = true;
    }

    /// Enable raw mode on Windows
    fn enableRawModeWindows(self: *Terminal) !void {
        if (builtin.os.tag != .windows) unreachable;

        if (self.is_raw) return;

        const stdin_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.GetStdHandleFailed;
        const stdout_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.GetStdHandleFailed;

        // Get current console modes
        var input_mode: u32 = undefined;
        if (@import("windows_compat").GetConsoleMode(stdin_handle, &input_mode) == 0) {
            return error.GetConsoleModeFailed;
        }
        self.original_termios = input_mode;

        var output_mode: u32 = undefined;
        if (@import("windows_compat").GetConsoleMode(stdout_handle, &output_mode) == 0) {
            return error.GetConsoleModeFailed;
        }
        self.original_output_mode = output_mode;

        // Disable line input and echo for raw mode
        var new_input_mode = input_mode;
        new_input_mode &= ~(@as(u32, windows.ENABLE_LINE_INPUT));
        new_input_mode &= ~(@as(u32, windows.ENABLE_ECHO_INPUT));
        new_input_mode &= ~(@as(u32, windows.ENABLE_PROCESSED_INPUT));
        new_input_mode |= windows.ENABLE_VIRTUAL_TERMINAL_INPUT;

        if (@import("windows_compat").SetConsoleMode(stdin_handle, new_input_mode) == 0) {
            return error.SetConsoleModeFailed;
        }

        // Enable virtual terminal processing for ANSI escape codes
        var new_output_mode = output_mode;
        new_output_mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        new_output_mode |= windows.ENABLE_PROCESSED_OUTPUT;
        new_output_mode |= windows.ENABLE_WRAP_AT_EOL_OUTPUT;

        if (@import("windows_compat").SetConsoleMode(stdout_handle, new_output_mode) == 0) {
            return error.SetConsoleModeFailed;
        }

        self.is_raw = true;
    }

    /// Disable raw terminal mode (restore original settings)
    pub fn disableRawMode(self: *Terminal) !void {
        if (!self.is_raw) return; // Already in normal mode
        if (self.original_termios == null) return;

        if (builtin.os.tag == .windows) {
            const stdin_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.GetStdHandleFailed;
            const stdout_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.GetStdHandleFailed;

            _ = @import("windows_compat").SetConsoleMode(stdin_handle, self.original_termios.?);
            if (self.original_output_mode) |output_mode| {
                _ = @import("windows_compat").SetConsoleMode(stdout_handle, output_mode);
            }
            self.is_raw = false;
            return;
        }

        const stdin_fd = posix.STDIN_FILENO;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, self.original_termios.?);
        self.is_raw = false;
    }

    /// Read a single byte from stdin (non-blocking in raw mode)
    /// Returns null if no data available
    pub fn readByte(self: *Terminal) !?u8 {
        if (!self.is_raw) return error.NotInRawMode;

        if (builtin.os.tag == .windows) {
            const stdin_handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.GetStdHandleFailed;

            // Check if input available
            var num_events: u32 = undefined;
            if (!windows.GetNumberOfConsoleInputEvents(stdin_handle, &num_events).toBool()) {
                return error.GetInputEventsFailed;
            }

            if (num_events == 0) return null;

            // Read one character
            var buf: [1]u8 = undefined;
            var bytes_read: u32 = undefined;
            if (@import("windows_compat").ReadFile(stdin_handle, &buf, 1, &bytes_read, null) == 0) {
                return error.ReadFailed;
            }

            if (bytes_read == 0) return null;
            return buf[0];
        }

        var buf: [1]u8 = undefined;
        const bytes_read = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (bytes_read == 0) return null;
        return buf[0];
    }
};
