const std = @import("std");
const builtin = @import("builtin");

/// Signal handler state
var signal_received: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var window_size_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Windows console control event types
const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;
const CTRL_LOGOFF_EVENT: u32 = 5;
const CTRL_SHUTDOWN_EVENT: u32 = 6;

/// Signal types we handle
pub const Signal = enum {
    none,
    interrupt, // SIGINT (Ctrl+C) / CTRL_C_EVENT
    terminate, // SIGTERM / CTRL_CLOSE_EVENT
    winch, // SIGWINCH (window resize)

    pub fn fromPosix(sig: u32) Signal {
        if (builtin.os.tag == .windows) {
            return .none;
        }

        // On macOS/BSD, SIG constants are enums. Convert to integer for comparison.
        const sig_int = @intFromEnum(std.posix.SIG.INT);
        const sig_term = @intFromEnum(std.posix.SIG.TERM);
        const sig_winch = @intFromEnum(std.posix.SIG.WINCH);

        return if (sig == sig_int)
            .interrupt
        else if (sig == sig_term)
            .terminate
        else if (sig == sig_winch)
            .winch
        else
            .none;
    }

    /// Convert Windows console control event to Signal
    pub fn fromWindowsEvent(event: u32) Signal {
        return switch (event) {
            CTRL_C_EVENT, CTRL_BREAK_EVENT => .interrupt,
            CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT => .terminate,
            else => .none,
        };
    }
};

/// Terminal window size
pub const WindowSize = struct {
    rows: u16,
    cols: u16,
};

/// Windows console control handler
fn windowsCtrlHandler(ctrl_type: u32) callconv(std.builtin.CallingConvention.winapi) std.os.windows.BOOL {
    const signal = Signal.fromWindowsEvent(ctrl_type);
    switch (signal) {
        .interrupt => {
            // Store interrupt signal (use a sentinel value distinct from POSIX)
            signal_received.store(1, .release);
            return .TRUE; // Handled
        },
        .terminate => {
            // Store terminate signal
            signal_received.store(2, .release);
            return .TRUE; // Handled
        },
        .none, .winch => {
            return .FALSE; // Not handled
        },
    }
}

fn setConsoleCtrlHandler(add: bool) bool {
    const windows = std.os.windows;
    const setHandler = struct {
        extern "kernel32" fn SetConsoleCtrlHandler(
            handler: ?*const fn (u32) callconv(std.builtin.CallingConvention.winapi) windows.BOOL,
            add_handler: windows.BOOL,
        ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    }.SetConsoleCtrlHandler;
    return setHandler(&windowsCtrlHandler, windows.BOOL.fromBool(add)).toBool();
}

/// Install signal handlers
pub fn installHandlers() !void {
    if (builtin.os.tag == .windows) {
        // Windows: use SetConsoleCtrlHandler for Ctrl+C and close events
        if (!setConsoleCtrlHandler(true)) {
            return error.SetConsoleCtrlHandlerFailed;
        }
        return;
    }

    // Create empty signal mask
    const empty_mask = std.posix.sigemptyset();

    // Install SIGINT handler (Ctrl+C)
    var sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);

    // Install SIGTERM handler
    var sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null);

    // Install SIGWINCH handler (window resize)
    var sigwinch_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = std.posix.SA.RESTART, // Restart syscalls if interrupted
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sigwinch_action, null);
}

/// Signal handler function - accept the platform-appropriate signal type
fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    const sig_val: u32 = @intFromEnum(sig);
    const signal = Signal.fromPosix(sig_val);

    switch (signal) {
        .interrupt, .terminate => {
            signal_received.store(sig_val, .release);
        },
        .winch => {
            window_size_changed.store(true, .release);
        },
        .none => {},
    }
}

/// Check if a signal was received and return it
pub fn checkSignal() ?Signal {
    const sig = signal_received.swap(0, .acquire);
    if (sig == 0) return null;

    if (builtin.os.tag == .windows) {
        // Windows uses sentinel values: 1 = interrupt, 2 = terminate
        return switch (sig) {
            1 => .interrupt,
            2 => .terminate,
            else => .none,
        };
    }
    return Signal.fromPosix(sig);
}

/// Check if window size changed and reset the flag
pub fn checkWindowSizeChanged() bool {
    return window_size_changed.swap(false, .acquire);
}

/// Get current terminal window size
pub fn getWindowSize() !WindowSize {
    if (builtin.os.tag == .windows) {
        // Windows implementation
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.GetStdHandleFailed;

        var info: @import("windows_compat").CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (@import("windows_compat").GetConsoleScreenBufferInfo(handle, &info) == 0) {
            return error.GetConsoleFailed;
        }

        const cols = @as(u16, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
        const rows = @as(u16, @intCast(info.srWindow.Bottom - info.srWindow.Top + 1));

        return WindowSize{
            .rows = rows,
            .cols = cols,
        };
    } else {
        // Unix implementation using ioctl
        const TIOCGWINSZ = if (builtin.os.tag == .linux)
            0x5413
        else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd)
            0x40087468
        else
            0x5413; // Default to Linux value

        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));

        if (rc != 0) {
            return error.IoctlFailed;
        }

        return WindowSize{
            .rows = ws.row,
            .cols = ws.col,
        };
    }
}

/// Reset signal handlers to default
pub fn resetHandlers() !void {
    if (builtin.os.tag == .windows) {
        // Windows: remove our console control handler
        _ = setConsoleCtrlHandler(false);
        return;
    }

    // Create empty signal mask
    const empty_mask = std.posix.sigemptyset();

    // Reset SIGINT
    var sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);

    // Reset SIGTERM
    var sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null);

    // Reset SIGWINCH
    var sigwinch_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sigwinch_action, null);
}

test "signal handling basic" {
    const testing = std.testing;

    // Test initial state
    try testing.expectEqual(@as(?Signal, null), checkSignal());
    try testing.expectEqual(false, checkWindowSizeChanged());
}

test "window size" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const size = getWindowSize() catch |err| {
        // TIOCGWINSZ fails when not attached to a real terminal (CI, test runners).
        // This is expected behavior - verify the error is the right one.
        try std.testing.expect(err == error.IoctlFailed);
        return;
    };

    // If we do have a terminal, verify sanity
    const testing = std.testing;
    try testing.expect(size.rows > 0);
    try testing.expect(size.cols > 0);
    try testing.expect(size.rows < 1000); // Reasonable upper bound
    try testing.expect(size.cols < 1000);
}
