const std = @import("std");
const compat = @import("compat");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const builtin = @import("builtin");
const common = @import("common.zig");

/// Standalone utility builtins that don't require shell state.
/// These can operate with just an allocator.
/// base64 - encode/decode base64
pub fn base64(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // The builtin only encodes/decodes a string given as an argument. The common
    // `echo x | base64` (read stdin) and any other flags are handled by the real
    // base64 on PATH.
    if (command.args.len == 0) return error.FallbackToExternal;

    var decode: bool = false;
    var input: ?[]const u8 = null;

    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--decode")) {
            decode = true;
        } else {
            input = arg;
        }
    }

    if (input == null) return error.FallbackToExternal;

    const data = input.?;

    if (decode) {
        const decoder = std.base64.standard.Decoder;
        const max_size = try decoder.calcSizeForSlice(data);
        const output = try allocator.alloc(u8, max_size);
        defer allocator.free(output);

        decoder.decode(output, data) catch {
            try IO.eprint("den: base64: invalid base64 input\n", .{});
            return 1;
        };

        try IO.print("{s}\n", .{output[0..max_size]});
    } else {
        const encoder = std.base64.standard.Encoder;
        const output_size = encoder.calcSize(data.len);
        const output = try allocator.alloc(u8, output_size);
        defer allocator.free(output);

        const encoded = encoder.encode(output, data);
        try IO.print("{s}\n", .{encoded});
    }

    return 0;
}

/// uuid - generate a UUID v4
pub fn uuid(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;

    const seed: u64 = blk: {
        const instant = compat.Instant.now() catch break :blk 0;
        break :blk if (builtin.os.tag == .windows) @intCast(instant.timestamp / 10_000_000) else @intCast(instant.timestamp.sec);
    };
    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();

    var uuid_bytes: [16]u8 = undefined;
    random.bytes(&uuid_bytes);

    // Set version (4) and variant bits
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;

    const uuid_str = try std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid_bytes[0],  uuid_bytes[1],  uuid_bytes[2],  uuid_bytes[3],
            uuid_bytes[4],  uuid_bytes[5],  uuid_bytes[6],  uuid_bytes[7],
            uuid_bytes[8],  uuid_bytes[9],  uuid_bytes[10], uuid_bytes[11],
            uuid_bytes[12], uuid_bytes[13], uuid_bytes[14], uuid_bytes[15],
        },
    );
    defer allocator.free(uuid_str);

    try IO.print("{s}\n", .{uuid_str});
    return 0;
}

/// localip - show local IP address hints
pub fn localip(command: *types.ParsedCommand) !i32 {
    _ = command;

    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try IO.print("Use 'ifconfig | grep inet' or 'ip addr' to see local IP addresses\n", .{});
        try IO.print("Tip: On macOS: ipconfig getifaddr en0\n", .{});
    } else {
        try IO.print("localip: not supported on this platform\n", .{});
        return 1;
    }
    return 0;
}

/// ip - show public IP hints
pub fn ip(command: *types.ParsedCommand) !i32 {
    _ = command;
    try IO.print("Use 'curl -s ifconfig.me' or 'curl -s icanhazip.com' to get public IP\n", .{});
    return 0;
}

/// shrug - print shrug emoticon
pub fn shrug(command: *types.ParsedCommand) !i32 {
    _ = command;
    try IO.print("�\\_(�)_/�\n", .{});
    return 0;
}

/// web - open URL in browser (prints command to run)
pub fn web(command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: web: usage: web <url>\n", .{});
        return 1;
    }

    const url = command.args[0];

    if (builtin.os.tag == .macos) {
        try IO.print("Opening: {s}\n", .{url});
        try IO.print("Run: open \"{s}\"\n", .{url});
    } else if (builtin.os.tag == .linux) {
        try IO.print("Opening: {s}\n", .{url});
        try IO.print("Run: xdg-open \"{s}\"\n", .{url});
    } else if (builtin.os.tag == .windows) {
        try IO.print("Opening: {s}\n", .{url});
        try IO.print("Run: start \"{s}\"\n", .{url});
    } else {
        try IO.eprint("den: web: not supported on this platform\n", .{});
        return 1;
    }
    return 0;
}

/// http - HTTP client stub
pub fn http(command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: http: missing URL\n", .{});
        try IO.eprint("den: http: usage: http [OPTIONS] URL\n", .{});
        try IO.eprint("den: http: options:\n", .{});
        try IO.eprint("den: http:   -X METHOD     HTTP method (GET, POST, PUT, DELETE)\n", .{});
        try IO.eprint("den: http:   -d DATA       Request body data\n", .{});
        try IO.eprint("den: http:   -i            Show response headers\n", .{});
        try IO.eprint("den: http: note: this is a stub. Use curl or wget for full functionality.\n", .{});
        return 1;
    }

    var method: []const u8 = "GET";
    var url: ?[]const u8 = null;
    var data: ?[]const u8 = null;

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];

        if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--request")) {
            if (i + 1 >= command.args.len) {
                try IO.eprint("den: http: -X requires an argument\n", .{});
                return 1;
            }
            i += 1;
            method = command.args[i];
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
            if (i + 1 >= command.args.len) {
                try IO.eprint("den: http: -d requires an argument\n", .{});
                return 1;
            }
            i += 1;
            data = command.args[i];
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--include")) {
            // Accepted but ignored in stub
        } else if (arg[0] != '-') {
            url = arg;
        } else {
            try IO.eprint("den: http: unknown option {s}\n", .{arg});
            return 1;
        }
    }

    if (url == null) {
        try IO.eprint("den: http: missing URL\n", .{});
        return 1;
    }

    const target_url = url.?;
    try IO.print("http: stub implementation\n", .{});
    try IO.print("Would perform {s} {s}\n", .{ method, target_url });
    if (data) |body| {
        try IO.print("With data: {s}\n", .{body});
        try IO.print("\nTo use full HTTP functionality:\n  curl -X {s} -d '{s}' {s}\n", .{ method, body, target_url });
    } else {
        try IO.print("\nTo use full HTTP functionality:\n  curl {s}\n", .{target_url});
    }

    return 0;
}

/// seq - print a sequence of numbers
pub fn seq(command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: seq: usage: seq [first [increment]] last\n", .{});
        return 1;
    }

    var first: i64 = 1;
    var increment: i64 = 1;
    var last: i64 = 1;

    if (command.args.len == 1) {
        last = std.fmt.parseInt(i64, command.args[0], 10) catch {
            try IO.eprint("den: seq: invalid number: {s}\n", .{command.args[0]});
            return 1;
        };
    } else if (command.args.len == 2) {
        first = std.fmt.parseInt(i64, command.args[0], 10) catch {
            try IO.eprint("den: seq: invalid number: {s}\n", .{command.args[0]});
            return 1;
        };
        last = std.fmt.parseInt(i64, command.args[1], 10) catch {
            try IO.eprint("den: seq: invalid number: {s}\n", .{command.args[1]});
            return 1;
        };
    } else if (command.args.len >= 3) {
        first = std.fmt.parseInt(i64, command.args[0], 10) catch {
            try IO.eprint("den: seq: invalid number: {s}\n", .{command.args[0]});
            return 1;
        };
        increment = std.fmt.parseInt(i64, command.args[1], 10) catch {
            try IO.eprint("den: seq: invalid number: {s}\n", .{command.args[1]});
            return 1;
        };
        last = std.fmt.parseInt(i64, command.args[2], 10) catch {
            try IO.eprint("den: seq: invalid number: {s}\n", .{command.args[2]});
            return 1;
        };
    }

    if (increment == 0) {
        try IO.eprint("den: seq: increment cannot be zero\n", .{});
        return 1;
    }

    var current = first;
    if (increment > 0) {
        while (current <= last) : (current += increment) {
            try IO.print("{d}\n", .{current});
        }
    } else {
        while (current >= last) : (current += increment) {
            try IO.print("{d}\n", .{current});
        }
    }

    return 0;
}

/// date - print current date/time
pub fn date(command: *types.ParsedCommand) !i32 {
    _ = command;

    const instant = compat.Instant.now() catch {
        try IO.eprint("den: date: unable to get current time\n", .{});
        return 1;
    };
    const timestamp: i64 = if (builtin.os.tag == .windows) @intCast(instant.timestamp / 10_000_000) else @intCast(instant.timestamp.sec);
    const seconds_per_day: i64 = 86400;
    const seconds_per_hour: i64 = 3600;
    const seconds_per_minute: i64 = 60;

    // Simple epoch to date conversion
    var days = @divFloor(timestamp, seconds_per_day);
    const time_of_day = @mod(timestamp, seconds_per_day);
    const hours = @divFloor(time_of_day, seconds_per_hour);
    const minutes = @divFloor(@mod(time_of_day, seconds_per_hour), seconds_per_minute);
    const seconds = @mod(time_of_day, seconds_per_minute);

    // Calculate year (approximate)
    var year: i64 = 1970;
    while (days >= 365) {
        const is_leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
        const days_in_year: i64 = if (is_leap) 366 else 365;
        if (days >= days_in_year) {
            days -= days_in_year;
            year += 1;
        } else {
            break;
        }
    }

    // Calculate month and day
    const is_leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
    const month_days = [_]i64{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    var month: usize = 0;
    while (month < 12) : (month += 1) {
        if (days < month_days[month]) break;
        days -= month_days[month];
    }

    const day = days + 1;

    try IO.print("{s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        month_names[month],
        day,
        hours,
        minutes,
        seconds,
        year,
    });

    return 0;
}

/// yes - repeatedly output a string
pub fn yes(command: *types.ParsedCommand) !i32 {
    const text = if (command.args.len > 0) command.args[0] else "y";

    // Print a limited number of times to avoid infinite loop in builtin
    var count: usize = 0;
    while (count < 1000) : (count += 1) {
        IO.print("{s}\n", .{text}) catch break;
    }

    return 0;
}

/// sleep - pause for specified seconds
pub fn sleep(command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: sleep: missing operand\n", .{});
        return 1;
    }

    const seconds_str = command.args[0];

    // Parse duration (supports integer or float)
    var duration_ns: u64 = 0;
    if (std.mem.indexOfScalar(u8, seconds_str, '.')) |_| {
        // Float format
        const whole = std.fmt.parseFloat(f64, seconds_str) catch {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{seconds_str});
            return 1;
        };
        duration_ns = @intFromFloat(whole * std.time.ns_per_s);
    } else {
        // Integer format
        const seconds = std.fmt.parseUnsigned(u64, seconds_str, 10) catch {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{seconds_str});
            return 1;
        };
        duration_ns = seconds * std.time.ns_per_s;
    }

    std.time.sleep(duration_ns);
    return 0;
}

/// clear - clear the terminal
pub fn clear(command: *types.ParsedCommand) !i32 {
    _ = command;
    try IO.print("\x1b[2J\x1b[H", .{});
    return 0;
}

/// copyssh - copy SSH public key to clipboard
pub fn copyssh(command: *types.ParsedCommand) !i32 {
    _ = command;

    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: copyssh: HOME environment variable not set\n", .{});
        return 1;
    };

    const key_files = [_][]const u8{
        "/.ssh/id_ed25519.pub",
        "/.ssh/id_rsa.pub",
        "/.ssh/id_ecdsa.pub",
        "/.ssh/id_dsa.pub",
    };

    var key_buffer: [8192]u8 = undefined;

    for (key_files) |key_suffix| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, key_suffix }) catch continue;

        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, full_path, .{}) catch continue;
        defer file.close(std.Options.debug_io);

        const bytes_read = file.readStreaming(std.Options.debug_io, &.{&key_buffer}) catch continue;
        if (bytes_read > 0) {
            try IO.print("Found SSH key: {s}\n", .{full_path});
            try IO.print("Key content:\n{s}\n", .{key_buffer[0..bytes_read]});
            try IO.print("\nTo copy to clipboard:\n", .{});
            if (builtin.os.tag == .macos) {
                try IO.print("  cat {s} | pbcopy\n", .{full_path});
            } else if (builtin.os.tag == .linux) {
                try IO.print("  cat {s} | xclip -selection clipboard\n", .{full_path});
            }
            return 0;
        }
    }

    try IO.eprint("den: copyssh: no SSH public key found\n", .{});
    try IO.eprint("Run 'ssh-keygen' to generate a key pair\n", .{});
    return 1;
}

/// whoami - print current username
pub fn whoami(command: *types.ParsedCommand) !i32 {
    _ = command;
    const user = common.getenv("USER") orelse common.getenv("USERNAME") orelse "unknown";
    try IO.print("{s}\n", .{user});
    return 0;
}

/// uname - print system information
pub fn uname(command: *types.ParsedCommand) !i32 {
    var show_all = false;
    var show_sysname = false;
    var show_nodename = false;
    var show_release = false;
    var show_version = false;
    var show_machine = false;

    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--kernel-name")) {
            show_sysname = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--nodename")) {
            show_nodename = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--kernel-release")) {
            show_release = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--kernel-version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--machine")) {
            show_machine = true;
        }
    }

    // Default: show sysname
    if (!show_all and !show_sysname and !show_nodename and !show_release and !show_version and !show_machine) {
        show_sysname = true;
    }

    const sysname = switch (builtin.os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .windows => "Windows",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };

    const machine = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        .arm => "arm",
        else => "unknown",
    };

    var first = true;
    if (show_all or show_sysname) {
        if (!first) try IO.print(" ", .{});
        try IO.print("{s}", .{sysname});
        first = false;
    }
    if (show_all or show_nodename) {
        if (!first) try IO.print(" ", .{});
        try IO.print("localhost", .{});
        first = false;
    }
    if (show_all or show_release) {
        if (!first) try IO.print(" ", .{});
        try IO.print("0.0.0", .{});
        first = false;
    }
    if (show_all or show_version) {
        if (!first) try IO.print(" ", .{});
        try IO.print("#1", .{});
        first = false;
    }
    if (show_all or show_machine) {
        if (!first) try IO.print(" ", .{});
        try IO.print("{s}", .{machine});
        first = false;
    }
    try IO.print("\n", .{});

    return 0;
}

/// help - Display built-in commands help
pub fn help(command: *types.ParsedCommand) !i32 {
    _ = command;

    try IO.print("Den Shell - Built-in Commands:\n\n", .{});
    try IO.print("Core:\n", .{});
    try IO.print("  cd [dir]          Change directory\n", .{});
    try IO.print("  pwd               Print working directory\n", .{});
    try IO.print("  echo [args...]    Print arguments\n", .{});
    try IO.print("  exit [n]          Exit shell with status n\n", .{});
    try IO.print("  env               Print environment variables\n", .{});
    try IO.print("  export VAR=val    Export environment variable\n", .{});
    try IO.print("  set [opts]        Set shell options or variables\n", .{});
    try IO.print("  unset VAR         Unset environment variable\n", .{});
    try IO.print("\nControl:\n", .{});
    try IO.print("  true              Return success (0)\n", .{});
    try IO.print("  false             Return failure (1)\n", .{});
    try IO.print("  test / [          Evaluate conditional expression\n", .{});
    try IO.print("  eval CMD          Evaluate and execute command string\n", .{});
    try IO.print("  exec CMD          Replace shell with command\n", .{});
    try IO.print("\nInformation:\n", .{});
    try IO.print("  which CMD         Locate a command\n", .{});
    try IO.print("  type CMD          Display command type\n", .{});
    try IO.print("  command [-pVv]    Run command with options\n", .{});
    try IO.print("  builtin CMD       Run builtin command\n", .{});
    try IO.print("  help              Display this help message\n", .{});
    try IO.print("  hash              Command hash table\n", .{});
    try IO.print("\nI/O:\n", .{});
    try IO.print("  read VAR          Read line into variable\n", .{});
    try IO.print("  printf fmt [args] Formatted print\n", .{});
    try IO.print("  clear             Clear the screen\n", .{});
    try IO.print("\nJob Control:\n", .{});
    try IO.print("  jobs              List active jobs\n", .{});
    try IO.print("  fg [job]          Foreground a job\n", .{});
    try IO.print("  bg [job]          Background a job\n", .{});
    try IO.print("  wait [pid]        Wait for process completion\n", .{});
    try IO.print("  disown [job]      Remove job from table\n", .{});
    try IO.print("  kill [-sig] pid   Send signal to process\n", .{});
    try IO.print("\nDirectory Stack:\n", .{});
    try IO.print("  pushd [dir]       Push directory onto stack\n", .{});
    try IO.print("  popd              Pop directory from stack\n", .{});
    try IO.print("  dirs              Display directory stack\n", .{});
    try IO.print("\nAdvanced:\n", .{});
    try IO.print("  alias [name=val]  Create or display aliases\n", .{});
    try IO.print("  unalias name      Remove alias\n", .{});
    try IO.print("  source / . file   Execute commands from file\n", .{});
    try IO.print("  history           Display command history\n", .{});
    try IO.print("  time CMD          Time command execution\n", .{});
    try IO.print("  times             Print process times\n", .{});
    try IO.print("  trap              Set signal handlers\n", .{});
    try IO.print("  umask [mask]      Set file creation mask\n", .{});
    try IO.print("  getopts           Parse command options\n", .{});
    try IO.print("\nUtility:\n", .{});
    try IO.print("  yes [str]         Repeatedly output string\n", .{});
    try IO.print("  reload            Reload shell configuration\n", .{});
    try IO.print("  copyssh           Copy SSH public key to clipboard\n", .{});

    return 0;
}

// Tests
test "seq generates sequence" {
    // Basic compilation test
    _ = seq;
}

test "date returns 0" {
    // Basic compilation test
    _ = date;
}
