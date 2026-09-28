const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const process = @import("../../utils/process.zig");

/// Signal-related builtins: kill
/// Note: trap remains in executor/mod.zig as it requires shell signal_handlers state

// Windows constants
const PROCESS_TERMINATE: u32 = 0x0001;

const OpenProcess = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandles: std.os.windows.BOOL, dwProcessId: u32) callconv(std.builtin.CallingConvention.winapi) ?std.os.windows.HANDLE;
}.OpenProcess else undefined;

/// kill builtin - send signals to processes
pub fn kill(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: kill: missing argument\n", .{});
        return 1;
    }

    // Check for -l flag (list signals)
    if (std.mem.eql(u8, command.args[0], "-l") or std.mem.eql(u8, command.args[0], "-L") or std.mem.eql(u8, command.args[0], "--list")) {
        const signal_table = if (comptime builtin.os.tag == .windows)
            [_]struct { num: u6, name: []const u8 }{}
        else
            [_]struct { num: u6, name: []const u8 }{
                .{ .num = @backingInt(std.posix.SIG.HUP), .name = "HUP" },
                .{ .num = @backingInt(std.posix.SIG.INT), .name = "INT" },
                .{ .num = @backingInt(std.posix.SIG.QUIT), .name = "QUIT" },
                .{ .num = @backingInt(std.posix.SIG.ILL), .name = "ILL" },
                .{ .num = @backingInt(std.posix.SIG.TRAP), .name = "TRAP" },
                .{ .num = @backingInt(std.posix.SIG.ABRT), .name = "ABRT" },
                .{ .num = @backingInt(std.posix.SIG.BUS), .name = "BUS" },
                .{ .num = @backingInt(std.posix.SIG.FPE), .name = "FPE" },
                .{ .num = @backingInt(std.posix.SIG.KILL), .name = "KILL" },
                .{ .num = @backingInt(std.posix.SIG.USR1), .name = "USR1" },
                .{ .num = @backingInt(std.posix.SIG.SEGV), .name = "SEGV" },
                .{ .num = @backingInt(std.posix.SIG.USR2), .name = "USR2" },
                .{ .num = @backingInt(std.posix.SIG.PIPE), .name = "PIPE" },
                .{ .num = @backingInt(std.posix.SIG.ALRM), .name = "ALRM" },
                .{ .num = @backingInt(std.posix.SIG.TERM), .name = "TERM" },
                .{ .num = @backingInt(std.posix.SIG.CHLD), .name = "CHLD" },
                .{ .num = @backingInt(std.posix.SIG.CONT), .name = "CONT" },
                .{ .num = @backingInt(std.posix.SIG.STOP), .name = "STOP" },
                .{ .num = @backingInt(std.posix.SIG.TSTP), .name = "TSTP" },
                .{ .num = @backingInt(std.posix.SIG.TTIN), .name = "TTIN" },
                .{ .num = @backingInt(std.posix.SIG.TTOU), .name = "TTOU" },
                .{ .num = @backingInt(std.posix.SIG.URG), .name = "URG" },
                .{ .num = @backingInt(std.posix.SIG.XCPU), .name = "XCPU" },
                .{ .num = @backingInt(std.posix.SIG.XFSZ), .name = "XFSZ" },
                .{ .num = @backingInt(std.posix.SIG.VTALRM), .name = "VTALRM" },
                .{ .num = @backingInt(std.posix.SIG.PROF), .name = "PROF" },
                .{ .num = @backingInt(std.posix.SIG.WINCH), .name = "WINCH" },
                .{ .num = @backingInt(std.posix.SIG.IO), .name = "IO" },
                .{ .num = @backingInt(std.posix.SIG.SYS), .name = "SYS" },
            };

        // If a signal number is given after -l, print just that signal name
        if (command.args.len >= 2) {
            const sig_num = std.fmt.parseInt(u6, command.args[1], 10) catch {
                try IO.eprint("den: kill: {s}: invalid signal specification\n", .{command.args[1]});
                return 1;
            };
            for (signal_table) |sig| {
                if (sig.num == sig_num) {
                    try IO.print("{s}\n", .{sig.name});
                    return 0;
                }
            }
            try IO.eprint("den: kill: {d}: invalid signal specification\n", .{sig_num});
            return 1;
        }

        // Print all signals
        if (builtin.os.tag == .windows) {
            try IO.print("Signals on Windows (only TERM/KILL are supported):\n", .{});
            try IO.print(" 9) SIGKILL    15) SIGTERM\n", .{});
        } else {
            var col: usize = 0;
            for (signal_table) |sig| {
                try IO.print("{d:>2}) SIG{s: <8}", .{ sig.num, sig.name });
                col += 1;
                if (col >= 4) {
                    try IO.print("\n", .{});
                    col = 0;
                }
            }
            if (col > 0) {
                try IO.print("\n", .{});
            }
        }
        return 0;
    }

    // Check for -s flag (specify signal by name)
    var start_idx: usize = 0;
    var explicit_signal: ?u8 = null;
    if (std.mem.eql(u8, command.args[0], "-s")) {
        if (command.args.len < 2) {
            try IO.eprint("den: kill: -s requires a signal name\n", .{});
            return 1;
        }
        const sig_name = command.args[1];
        explicit_signal = signalFromName(sig_name);
        if (explicit_signal == null) {
            try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_name});
            return 1;
        }
        start_idx = 2;
    }

    if (comptime builtin.os.tag == .windows) {
        // Windows: parse optional signal flag but only support TERM/KILL (both terminate)
        if (command.args[0].len > 0 and command.args[0][0] == '-') {
            const sig_str = command.args[0][1..];
            // Only accept TERM, KILL, or their numeric equivalents (9, 15)
            if (sig_str.len > 0) {
                const valid = std.mem.eql(u8, sig_str, "TERM") or
                    std.mem.eql(u8, sig_str, "KILL") or
                    std.mem.eql(u8, sig_str, "9") or
                    std.mem.eql(u8, sig_str, "15");
                if (!valid) {
                    // Check for other signals and warn
                    if (std.mem.eql(u8, sig_str, "HUP") or
                        std.mem.eql(u8, sig_str, "INT") or
                        std.mem.eql(u8, sig_str, "QUIT") or
                        std.mem.eql(u8, sig_str, "STOP") or
                        std.mem.eql(u8, sig_str, "CONT"))
                    {
                        try IO.eprint("den: kill: signal {s} not supported on Windows, using TERM\n", .{sig_str});
                    } else {
                        try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_str});
                        return 1;
                    }
                }
            }
            start_idx = 1;
        }

        if (start_idx >= command.args.len) {
            try IO.eprint("den: kill: missing process ID\n", .{});
            return 1;
        }

        // Terminate each process on Windows
        for (command.args[start_idx..]) |pid_str| {
            const pid = std.fmt.parseInt(u32, pid_str, 10) catch {
                try IO.eprint("den: kill: invalid process ID: {s}\n", .{pid_str});
                continue;
            };

            // Open process with TERMINATE permission
            const handle = OpenProcess(
                PROCESS_TERMINATE,
                .FALSE,
                pid,
            );
            if (handle == null) {
                try IO.eprint("den: kill: ({d}): cannot open process\n", .{pid});
                return 1;
            }
            defer std.os.windows.CloseHandle(handle.?);

            // Terminate the process
            if (@import("windows_compat").TerminateProcess(handle.?, 1) == 0) {
                try IO.eprint("den: kill: ({d}): cannot terminate process\n", .{pid});
                return 1;
            }
        }

        return 0;
    }

    // POSIX implementation
    const default_sig: u8 = if (comptime builtin.os.tag == .windows) 15 else @backingInt(std.posix.SIG.TERM);
    var signal: u8 = explicit_signal orelse default_sig;

    // Parse signal if provided (and not already set via -s)
    if (explicit_signal == null and start_idx < command.args.len and
        command.args[start_idx].len > 0 and command.args[start_idx][0] == '-')
    {
        const sig_str = command.args[start_idx][1..];
        if (sig_str.len > 0) {
            // Try to parse as number
            signal = std.fmt.parseInt(u8, sig_str, 10) catch blk: {
                // Try to parse as signal name
                break :blk signalFromName(sig_str) orelse {
                    try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_str});
                    return 1;
                };
            };
        }
        start_idx += 1;
    }

    if (start_idx >= command.args.len) {
        try IO.eprint("den: kill: missing process ID\n", .{});
        return 1;
    }

    // Send signal to each PID
    for (command.args[start_idx..]) |pid_str| {
        const pid = std.fmt.parseInt(process.ProcessId, pid_str, 10) catch {
            try IO.eprint("den: kill: invalid process ID: {s}\n", .{pid_str});
            continue;
        };

        process.killProcess(pid, signal) catch |err| {
            try IO.eprint("den: kill: ({d}): {}\n", .{ pid, err });
            return 1;
        };
    }

    return 0;
}

/// Helper to convert signal name to signal number
pub fn signalFromName(name: []const u8) ?u8 {
    if (builtin.os.tag == .windows) {
        if (std.mem.eql(u8, name, "TERM") or std.mem.eql(u8, name, "KILL")) {
            return 15; // Just return TERM, as Windows only supports terminate
        }
        return null;
    }

    if (std.mem.eql(u8, name, "HUP")) return @backingInt(std.posix.SIG.HUP) else if (std.mem.eql(u8, name, "INT")) return @backingInt(std.posix.SIG.INT) else if (std.mem.eql(u8, name, "QUIT")) return @backingInt(std.posix.SIG.QUIT) else if (std.mem.eql(u8, name, "ILL")) return @backingInt(std.posix.SIG.ILL) else if (std.mem.eql(u8, name, "TRAP")) return @backingInt(std.posix.SIG.TRAP) else if (std.mem.eql(u8, name, "ABRT")) return @backingInt(std.posix.SIG.ABRT) else if (std.mem.eql(u8, name, "BUS")) return @backingInt(std.posix.SIG.BUS) else if (std.mem.eql(u8, name, "FPE")) return @backingInt(std.posix.SIG.FPE) else if (std.mem.eql(u8, name, "KILL")) return @backingInt(std.posix.SIG.KILL) else if (std.mem.eql(u8, name, "USR1")) return @backingInt(std.posix.SIG.USR1) else if (std.mem.eql(u8, name, "SEGV")) return @backingInt(std.posix.SIG.SEGV) else if (std.mem.eql(u8, name, "USR2")) return @backingInt(std.posix.SIG.USR2) else if (std.mem.eql(u8, name, "PIPE")) return @backingInt(std.posix.SIG.PIPE) else if (std.mem.eql(u8, name, "ALRM")) return @backingInt(std.posix.SIG.ALRM) else if (std.mem.eql(u8, name, "TERM")) return @backingInt(std.posix.SIG.TERM) else if (std.mem.eql(u8, name, "CHLD")) return @backingInt(std.posix.SIG.CHLD) else if (std.mem.eql(u8, name, "CONT")) return @backingInt(std.posix.SIG.CONT) else if (std.mem.eql(u8, name, "STOP")) return @backingInt(std.posix.SIG.STOP) else if (std.mem.eql(u8, name, "TSTP")) return @backingInt(std.posix.SIG.TSTP) else if (std.mem.eql(u8, name, "TTIN")) return @backingInt(std.posix.SIG.TTIN) else if (std.mem.eql(u8, name, "TTOU")) return @backingInt(std.posix.SIG.TTOU) else if (std.mem.eql(u8, name, "URG")) return @backingInt(std.posix.SIG.URG) else if (std.mem.eql(u8, name, "XCPU")) return @backingInt(std.posix.SIG.XCPU) else if (std.mem.eql(u8, name, "XFSZ")) return @backingInt(std.posix.SIG.XFSZ) else if (std.mem.eql(u8, name, "VTALRM")) return @backingInt(std.posix.SIG.VTALRM) else if (std.mem.eql(u8, name, "PROF")) return @backingInt(std.posix.SIG.PROF) else if (std.mem.eql(u8, name, "WINCH")) return @backingInt(std.posix.SIG.WINCH) else if (std.mem.eql(u8, name, "IO")) return @backingInt(std.posix.SIG.IO) else if (std.mem.eql(u8, name, "SYS")) return @backingInt(std.posix.SIG.SYS) else return null;
}
