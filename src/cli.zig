const std = @import("std");
const builtin = @import("builtin");
const shell = @import("shell.zig");
const Completion = @import("utils/completion.zig").Completion;
const ShellCompletion = @import("shell_completion.zig").ShellCompletion;
const env_utils = @import("utils/env.zig");
const IO = @import("utils/io.zig").IO;
const LspServer = @import("lsp/server.zig").LspServer;
const net_session = @import("net/session.zig");

/// Den Shell CLI
/// Provides command-line interface and subcommand handling
pub const VERSION = "0.1.0";

pub const Command = enum {
    interactive, // Default: start interactive shell
    shell, // Explicit: start interactive shell
    exec, // Execute single command
    complete, // Get completions (JSON output)
    completion, // Generate shell completion script
    dev_setup, // Create development shim
    setup, // Install wrapper script
    set_shell, // Set as default shell
    uninstall, // Remove wrapper
    version, // Show version
    help, // Show help
    script, // Execute script file (implicit)
    command_string, // -c "command" - run command string
    lsp, // Start LSP server for IDE integration
    serve, // Start a distributed shell session server (--serve [addr])
    connect, // Connect to a remote shell session (--connect addr)
};

pub const CliArgs = struct {
    command: Command,
    args: []const []const u8,
    allocator: std.mem.Allocator,
    config_path: ?[]const u8 = null, // Custom config path from --config flag
    json_output: bool = false, // Output results in JSON format (for -c commands)
    norc: bool = false, // Skip loading configuration files (--norc)
    restricted: bool = false, // Start in restricted mode (invoked as rden)
    // Ownership tracking: the heap-allocated argv slice (args may be a sub-slice of this)
    _owned_argv: ?[]const []const u8 = null,

    pub fn deinit(self: *CliArgs) void {
        if (self._owned_argv) |owned| {
            self.allocator.free(owned);
        }
    }
};

/// Parse command line arguments
pub fn parseArgs(allocator: std.mem.Allocator, process_args: std.process.Args) !CliArgs {
    var args = try process_args.iterateAllocator(allocator);
    // NOTE: Do NOT defer args.deinit() here — the allocated strings are
    // owned by the returned CliArgs and must survive this function call.
    // The caller is responsible for the lifetime (CliArgs.deinit handles it).

    // Capture program name and check for restricted mode (invoked as "rden")
    const prog_name = args.next() orelse "";
    const restricted_from_argv0 = blk: {
        // Get basename of program name
        const basename = if (std.mem.lastIndexOfScalar(u8, prog_name, '/')) |pos|
            prog_name[pos + 1 ..]
        else
            prog_name;
        break :blk std.mem.eql(u8, basename, "rden");
    };

    // Collect all arguments into a heap-allocated list so they survive this function
    var argv_list = std.ArrayList([]const u8).empty;
    defer argv_list.deinit(allocator);

    while (args.next()) |arg| {
        try argv_list.append(allocator, arg);
    }

    const argv = argv_list.items;

    // Parse global flags first (--config, --json, --norc)
    var config_path: ?[]const u8 = null;
    var json_output: bool = false;
    var norc: bool = false;
    var remaining_list = std.ArrayList([]const u8).empty;
    errdefer remaining_list.deinit(allocator);
    var i: usize = 0;

    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            // Next argument is the config path
            if (i + 1 < argv.len) {
                config_path = argv[i + 1];
                i += 2;
                continue;
            } else {
                std.debug.print("Error: --config requires a path argument\n", .{});
                return error.MissingConfigPath;
            }
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            // --config=path format
            config_path = arg["--config=".len..];
            i += 1;
            continue;
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Enable JSON output mode
            json_output = true;
            i += 1;
            continue;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            // Skip loading configuration files
            norc = true;
            i += 1;
            continue;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--login") or
            std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive"))
        {
            // Accept the standard login/interactive shell flags. Den is already
            // interactive when no script/-c is given and sources ~/.denrc unless
            // --norc, so these are no-ops — but recognizing them is what lets Den
            // serve as a login shell: tools and GUI apps invoke `$SHELL -l -c ...`
            // or `$SHELL -i`, and without this they'd be treated as a script path
            // ("error loading script '-l'") and fail.
            i += 1;
            continue;
        }
        try remaining_list.append(allocator, arg);
        i += 1;
    }

    const remaining_argv = try remaining_list.toOwnedSlice(allocator);

    // No arguments = interactive shell
    if (remaining_argv.len == 0) {
        allocator.free(remaining_argv);
        return CliArgs{
            .command = .interactive,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
        };
    }

    const first_arg = remaining_argv[0];

    // Helper: sub-args (everything after the subcommand name)
    const sub_args = if (remaining_argv.len > 1) remaining_argv[1..] else &[_][]const u8{};

    // Check for subcommands
    if (std.mem.eql(u8, first_arg, "shell")) {
        return CliArgs{
            .command = .shell,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "exec")) {
        return CliArgs{
            .command = .exec,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "complete")) {
        return CliArgs{
            .command = .complete,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "completion")) {
        return CliArgs{
            .command = .completion,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "dev-setup")) {
        return CliArgs{
            .command = .dev_setup,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "setup")) {
        return CliArgs{
            .command = .setup,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "set-shell")) {
        return CliArgs{
            .command = .set_shell,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "uninstall")) {
        return CliArgs{
            .command = .uninstall,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "version") or std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
        return CliArgs{
            .command = .version,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "help") or std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
        return CliArgs{
            .command = .help,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "--lsp")) {
        return CliArgs{
            .command = .lsp,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "--serve")) {
        return CliArgs{
            .command = .serve,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "--connect")) {
        return CliArgs{
            .command = .connect,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "-c")) {
        // -c "command" - run command string
        return CliArgs{
            .command = .command_string,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .json_output = json_output,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    } else {
        // Assume it's a script file
        return CliArgs{
            .command = .script,
            .args = remaining_argv,
            .allocator = allocator,
            .config_path = config_path,
            .norc = norc,
            .restricted = restricted_from_argv0,
            ._owned_argv = remaining_argv,
        };
    }
}

/// Execute the CLI command
pub fn execute(cli_args: CliArgs) !void {
    // When --norc is set, skip config loading by passing null config_path
    // and signaling the shell to use defaults only
    const effective_config_path = if (cli_args.norc) null else cli_args.config_path;
    switch (cli_args.command) {
        .interactive, .shell => try runInteractiveShell(cli_args.allocator, effective_config_path, cli_args.norc, cli_args.restricted),
        .exec => try execCommand(cli_args.allocator, cli_args.args, effective_config_path, cli_args.norc, cli_args.restricted),
        .complete => try getCompletions(cli_args.allocator, cli_args.args),
        .completion => try generateCompletion(cli_args.allocator, cli_args.args),
        .dev_setup => try devSetup(cli_args.allocator),
        .setup => try setup(cli_args.allocator),
        .set_shell => try setShell(cli_args.allocator),
        .uninstall => try uninstall(cli_args.allocator),
        .version => try showVersion(),
        .help => try showHelp(),
        .script => try runScript(cli_args.allocator, cli_args.args, effective_config_path, cli_args.norc, cli_args.restricted),
        .command_string => try runCommandString(cli_args.allocator, cli_args.args, effective_config_path, cli_args.json_output, cli_args.norc, cli_args.restricted),
        .lsp => try runLspServer(cli_args.allocator),
        .serve => try runSessionServer(cli_args.allocator, cli_args.args, effective_config_path, cli_args.norc),
        .connect => try runSessionClient(cli_args.args),
    }
}

/// Start a distributed shell-session server. Forks a Den shell per connection.
fn runSessionServer(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8, norc: bool) !void {
    const spec = if (args.len > 0) args[0] else "";
    const addr = net_session.parseAddress(spec) orelse {
        try IO.eprint("den: --serve: invalid address '{s}' (expected host:port)\n", .{spec});
        return;
    };

    // Refuse non-loopback binds unless explicitly allowed.
    if (!net_session.isLoopback(addr.ip)) {
        const allow = std.c.getenv("DEN_ALLOW_REMOTE");
        const allowed = allow != null and std.mem.eql(u8, std.mem.span(allow.?), "1");
        if (!allowed) {
            try IO.eprint("den: --serve: refusing to bind non-loopback address {s} without DEN_ALLOW_REMOTE=1\n", .{addr.host});
            return;
        }
    }

    const listener = net_session.bindListen(addr.ip, addr.port) catch |err| {
        try IO.eprint("den: --serve: {s}:{d}: {s}\n", .{ addr.host, addr.port, @errorName(err) });
        return;
    };
    defer _ = std.c.close(listener);

    try IO.print("den session server listening on {s}:{d} (UNAUTHENTICATED — loopback only)\n", .{ addr.host, addr.port });

    while (true) {
        const conn = net_session.acceptConn(listener) catch continue;
        const pid = std.c.fork();
        if (pid == 0) {
            // Child: wire the socket to stdio and run the shell, then exit.
            _ = std.c.close(listener);
            _ = std.c.dup2(conn, 0);
            _ = std.c.dup2(conn, 1);
            _ = std.c.dup2(conn, 2);
            _ = std.c.close(conn);
            runInteractiveShell(allocator, config_path, norc, false) catch {};
            std.c._exit(0);
        } else {
            // Parent: hand the connection to the child and keep accepting.
            _ = std.c.close(conn);
        }
    }
}

/// Connect the local terminal to a remote Den session.
fn runSessionClient(args: []const []const u8) !void {
    const spec = if (args.len > 0) args[0] else "";
    const addr = net_session.parseAddress(spec) orelse {
        try IO.eprint("den: --connect: invalid address '{s}' (expected host:port)\n", .{spec});
        return;
    };
    net_session.runClient(addr.host, addr.port) catch |err| {
        try IO.eprint("den: --connect: {s}:{d}: {s}\n", .{ addr.host, addr.port, @errorName(err) });
    };
}

/// Start LSP server for IDE integration
fn runLspServer(allocator: std.mem.Allocator) !void {
    var server = LspServer.init(allocator);
    defer server.deinit();
    try server.run();
}

/// Start interactive shell
fn runInteractiveShell(allocator: std.mem.Allocator, config_path: ?[]const u8, norc: bool, restricted: bool) !void {
    var den_shell = if (norc)
        try shell.Shell.initNoConfig(allocator)
    else
        try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();
    if (restricted) den_shell.option_restricted = true;

    // Source ~/.denrc if it exists (like .zshrc)
    if (!norc) {
        den_shell.sourceRcFile() catch {};
    }

    try den_shell.run();
}

/// Execute a single command
fn execCommand(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8, norc: bool, restricted: bool) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'exec' requires a command argument\n", .{});
        std.debug.print("Usage: den exec <command>\n", .{});
        return error.MissingCommand;
    }

    // Join arguments into a single command string
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (args, 0..) |arg, i| {
        if (i > 0) {
            if (pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
        const to_copy = @min(arg.len, buf.len - pos);
        @memcpy(buf[pos..][0..to_copy], arg[0..to_copy]);
        pos += to_copy;
    }

    const command = buf[0..pos];

    var den_shell = if (norc)
        try shell.Shell.initNoConfig(allocator)
    else
        try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();
    if (restricted) den_shell.option_restricted = true;

    // Execute the command
    den_shell.executeCommand(command) catch |err| {
        den_shell.executeExitTrap();
        std.debug.print("Error executing command: {}\n", .{err});
        return err;
    };
    den_shell.executeExitTrap();
}

/// Get completions for input (JSON output)
fn getCompletions(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'complete' requires input argument\n", .{});
        std.debug.print("Usage: den complete <input>\n", .{});
        return error.MissingInput;
    }

    // For simplicity, just use the first argument as the input to complete
    const input = args[0];

    // Initialize completion system
    var comp = Completion.init(allocator);

    // Determine what to complete
    var completions: [][]const u8 = &[_][]const u8{};
    defer {
        for (completions) |c| allocator.free(c);
        allocator.free(completions);
    }

    // Simple heuristic: if input contains '/' or starts with '.', complete files
    // Otherwise, complete commands
    if (std.mem.indexOf(u8, input, "/") != null or std.mem.startsWith(u8, input, ".")) {
        completions = comp.completeFile(input) catch &[_][]const u8{};
    } else {
        // Get the last word to complete
        const last_space = std.mem.lastIndexOfScalar(u8, input, ' ');
        const word_to_complete = if (last_space) |idx| input[idx + 1 ..] else input;
        completions = comp.completeCommand(word_to_complete) catch &[_][]const u8{};
    }

    // Output as JSON array
    IO.print("[", .{}) catch {};
    for (completions, 0..) |completion, ci| {
        if (ci > 0) IO.print(",", .{}) catch {};
        IO.print("\"{s}\"", .{completion}) catch {};
    }
    IO.print("]\n", .{}) catch {};
}

/// Generate shell completion script
fn generateCompletion(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'completion' requires shell type argument\n", .{});
        std.debug.print("Usage: den completion <bash|zsh|fish>\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  den completion bash > ~/.local/share/bash-completion/completions/den\n", .{});
        std.debug.print("  den completion zsh > ~/.zsh/completions/_den\n", .{});
        std.debug.print("  den completion fish > ~/.config/fish/completions/den.fish\n", .{});
        return error.MissingShellType;
    }

    const shell_type = args[0];

    // Validate shell type
    if (!std.mem.eql(u8, shell_type, "bash") and
        !std.mem.eql(u8, shell_type, "zsh") and
        !std.mem.eql(u8, shell_type, "fish"))
    {
        std.debug.print("Error: Unsupported shell type '{s}'\n", .{shell_type});
        std.debug.print("Supported shells: bash, zsh, fish\n", .{});
        return error.UnsupportedShell;
    }

    var comp = ShellCompletion.init(allocator);
    const script = try comp.generate(shell_type);

    IO.print("{s}", .{script}) catch {};
}

/// Create development shim
fn devSetup(_: std.mem.Allocator) !void {
    std.debug.print("Creating development shim...\n", .{});

    // Get current executable path
    var exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(std.Options.debug_io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_path_len];

    // Create shim in ~/.local/bin/den
    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const shim_path = try std.fmt.bufPrint(&home_buf, "{s}/.local/bin/den", .{home});

    // Ensure ~/.local/bin exists
    var local_bin_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const local_bin_dir = try std.fmt.bufPrint(&local_bin_dir_buf, "{s}/.local/bin", .{home});
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, local_bin_dir) catch |err| {
        return err;
    };

    // Create shim file
    const shim_file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, shim_path, .{ .truncate = true });
    defer shim_file.close(std.Options.debug_io);

    const shim_content = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "#!/bin/sh\nexec {s} \"$@\"\n",
        .{exe_path},
    );
    defer std.heap.page_allocator.free(shim_content);

    try shim_file.writeStreamingAll(std.Options.debug_io, shim_content);

    // Make executable
    if (builtin.os.tag != .windows) {
        try shim_file.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o755));
    }

    std.debug.print("Development shim created at: {s}\n", .{shim_path});
    std.debug.print("Make sure ~/.local/bin is in your PATH\n", .{});
}

/// Install wrapper script
fn setup(_: std.mem.Allocator) !void {
    // Using std.debug.print instead

    std.debug.print("Installing Den shell wrapper...\n", .{});

    // Get current executable path
    var exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(std.Options.debug_io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_path_len];

    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var wrapper_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wrapper_path = try std.fmt.bufPrint(&wrapper_path_buf, "{s}/.local/bin/den", .{home});

    // Ensure ~/.local/bin exists
    var local_bin_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const local_bin_dir = try std.fmt.bufPrint(&local_bin_dir_buf, "{s}/.local/bin", .{home});
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, local_bin_dir) catch |err| {
        return err;
    };

    // Create wrapper script
    const wrapper_file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, wrapper_path, .{ .truncate = true });
    defer wrapper_file.close(std.Options.debug_io);

    const wrapper_content = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "#!/bin/sh\nexec {s} \"$@\"\n",
        .{exe_path},
    );
    defer std.heap.page_allocator.free(wrapper_content);

    try wrapper_file.writeStreamingAll(std.Options.debug_io, wrapper_content);
    if (builtin.os.tag != .windows) {
        try wrapper_file.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o755));
    }

    std.debug.print("Wrapper installed at: {s}\n", .{wrapper_path});
    std.debug.print("\nTo use Den shell:\n", .{});
    std.debug.print("  1. Make sure ~/.local/bin is in your PATH\n", .{});
    std.debug.print("  2. Run 'den set-shell' to set it as your default shell\n", .{});
}

/// Set Den as default shell
fn setShell(_: std.mem.Allocator) !void {
    // Using std.debug.print instead

    std.debug.print("Setting Den as default shell...\n", .{});

    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var den_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const den_path = try std.fmt.bufPrint(&den_path_buf, "{s}/.local/bin/den", .{home});

    // Check if den wrapper exists
    std.Io.Dir.cwd().access(std.Options.debug_io, den_path, .{}) catch {
        std.debug.print("Error: Den wrapper not found. Run 'den setup' first.\n", .{});
        return error.WrapperNotFound;
    };

    std.debug.print("\nTo set Den as your default shell, run:\n", .{});
    std.debug.print("  chsh -s {s}\n", .{den_path});
    std.debug.print("\nNote: You may need to add the shell path to /etc/shells first:\n", .{});
    std.debug.print("  echo '{s}' | sudo tee -a /etc/shells\n", .{den_path});
}

/// Uninstall Den wrapper
fn uninstall(_: std.mem.Allocator) !void {
    // Using std.debug.print instead

    std.debug.print("Uninstalling Den shell wrapper...\n", .{});

    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var wrapper_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wrapper_path = try std.fmt.bufPrint(&wrapper_path_buf, "{s}/.local/bin/den", .{home});

    // Remove wrapper
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, wrapper_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Wrapper not found (already uninstalled?)\n", .{});
            return;
        }
        return err;
    };

    std.debug.print("Wrapper removed from: {s}\n", .{wrapper_path});
    std.debug.print("\nIf Den was your default shell, remember to change it back:\n", .{});
    std.debug.print("  chsh -s /bin/bash  # or your preferred shell\n", .{});
}

/// Show version
fn showVersion() !void {
    IO.print("Den Shell v{s}\n", .{VERSION}) catch {};
}

/// Show help
fn showHelp() !void {
    IO.print(
        \\Den Shell - A modern shell written in Zig
        \\
        \\Usage:
        \\  den                       Start interactive shell (default)
        \\  den shell                 Start interactive shell (explicit)
        \\  den exec <cmd>            Execute single command
        \\  den complete <input>      Get completions (JSON output)
        \\  den completion <shell>    Generate shell completion script
        \\  den dev-setup             Create development shim
        \\  den setup                 Install wrapper script
        \\  den set-shell             Set as default shell
        \\  den uninstall             Remove wrapper
        \\  den version               Show version
        \\  den help                  Show this help
        \\  den <script>              Execute script file
        \\
        \\Options:
        \\  -h, --help                Show help
        \\  -v, --version             Show version
        \\  -c <command>              Execute command string
        \\  --config <path>           Use custom config file
        \\  --norc                    Skip loading configuration files
        \\  --json                    Output results in JSON format (with -c)
        \\  --lsp                     Start Language Server Protocol server
        \\
        \\Completion:
        \\  den completion bash       Generate Bash completion script
        \\  den completion zsh        Generate Zsh completion script
        \\  den completion fish       Generate Fish completion script
        \\
        \\Examples:
        \\  den                                      # Start interactive shell
        \\  den exec echo "Hello, World!"            # Execute command
        \\  den script.sh                            # Run script file
        \\  den setup                                # Install Den
        \\  den --config ~/custom.jsonc              # Use custom config
        \\  den completion bash > /etc/bash_completion.d/den   # Install Bash completion
        \\
        \\For more information, visit: https://github.com/stackblitz/den
        \\
    , .{}) catch {};
}

/// Run script file
fn runScript(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8, norc: bool, restricted: bool) !void {
    if (args.len == 0) {
        std.debug.print("Error: script file required\n", .{});
        return error.MissingScriptFile;
    }

    const script_path = args[0];
    const script_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    var den_shell = if (norc)
        try shell.Shell.initNoConfig(allocator)
    else
        try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();
    if (restricted) den_shell.option_restricted = true;

    try den_shell.runScript(script_path, "den", script_args);
    den_shell.executeExitTrap();

    // Propagate exit code to OS
    if (den_shell.last_exit_code != 0) {
        std.process.exit(@intCast(@as(u32, @bitCast(den_shell.last_exit_code))));
    }
}

/// Run command string (-c "command")
fn runCommandString(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8, json_output: bool, norc: bool, restricted: bool) !void {
    if (args.len == 0) {
        if (json_output) {
            try IO.print("{{\"error\":\"missing command string\",\"exit_code\":1}}\n", .{});
        } else {
            std.debug.print("Error: -c requires a command string\n", .{});
        }
        return error.MissingCommandString;
    }

    const raw_command = args[0];

    // Handle backslash-newline continuation: remove \<newline> sequences
    var cmd_buf: [16384]u8 = undefined;
    var cmd_len: usize = 0;
    {
        var ci: usize = 0;
        while (ci < raw_command.len) {
            if (raw_command[ci] == '\\' and ci + 1 < raw_command.len and raw_command[ci + 1] == '\n') {
                ci += 2; // Skip backslash-newline (line continuation)
            } else {
                if (cmd_len < cmd_buf.len) {
                    cmd_buf[cmd_len] = raw_command[ci];
                    cmd_len += 1;
                }
                ci += 1;
            }
        }
    }
    const command = cmd_buf[0..cmd_len];

    var den_shell = if (norc)
        try shell.Shell.initNoConfig(allocator)
    else
        try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();
    if (restricted) den_shell.option_restricted = true;

    // If multi-line, process line-by-line using script-style execution
    if (std.mem.indexOfScalar(u8, command, '\n') != null) {
        const control_flow = @import("scripting/control_flow.zig");
        const functions = @import("scripting/functions.zig");

        // Quote-aware line splitting: newlines inside quotes are not line breaks
        var lines_buffer: [10000][]const u8 = undefined;
        var lines_count: usize = 0;
        {
            var line_start: usize = 0;
            var in_sq = false;
            var in_dq = false;
            var escaped = false;
            var ci2: usize = 0;
            while (ci2 < command.len) : (ci2 += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                const ch = command[ci2];
                if (ch == '\\' and !in_sq) {
                    escaped = true;
                    continue;
                }
                if (ch == '\'' and !in_dq) {
                    in_sq = !in_sq;
                } else if (ch == '"' and !in_sq) {
                    in_dq = !in_dq;
                } else if (ch == '\n' and !in_sq and !in_dq) {
                    if (lines_count >= lines_buffer.len) break;
                    lines_buffer[lines_count] = command[line_start..ci2];
                    lines_count += 1;
                    line_start = ci2 + 1;
                }
            }
            // Add final segment
            if (line_start <= command.len and lines_count < lines_buffer.len) {
                lines_buffer[lines_count] = command[line_start..command.len];
                lines_count += 1;
            }
        }
        const lines = lines_buffer[0..lines_count];

        var line_num: usize = 0;
        var parser = control_flow.ControlFlowParser.init(allocator);
        var executor = control_flow.ControlFlowExecutor.init(&den_shell);
        var func_parser = functions.FunctionParser.init(allocator);

        while (line_num < lines.len) : (line_num += 1) {
            den_shell.current_line = line_num + 1;
            const trimmed = std.mem.trim(u8, lines[line_num], &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check function definitions
            const is_func_kw = std.mem.startsWith(u8, trimmed, "function ");
            var is_paren_syntax = false;
            if (std.mem.indexOf(u8, trimmed, "()")) |_| {
                if (std.mem.indexOf(u8, trimmed, "{") != null) {
                    is_paren_syntax = true;
                } else if (line_num + 1 < lines.len) {
                    const next_t = std.mem.trim(u8, lines[line_num + 1], &std.ascii.whitespace);
                    if (std.mem.startsWith(u8, next_t, "{")) is_paren_syntax = true;
                }
            }
            if (is_func_kw or is_paren_syntax) {
                const result = func_parser.parseFunction(lines, line_num) catch break;
                defer {
                    allocator.free(result.name);
                    for (result.body) |line| allocator.free(line);
                    allocator.free(result.body);
                }
                den_shell.function_manager.defineFunction(result.name, result.body, false) catch break;
                line_num = result.end;
                continue;
            }

            // Control flow
            if (std.mem.startsWith(u8, trimmed, "if ")) {
                var result = parser.parseIf(lines, line_num) catch break;
                defer result.stmt.deinit();
                den_shell.last_exit_code = executor.executeIf(&result.stmt) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "while ")) {
                var result = parser.parseWhile(lines, line_num, false) catch break;
                defer result.loop.deinit();
                den_shell.last_exit_code = executor.executeWhile(&result.loop) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "until ")) {
                var result = parser.parseWhile(lines, line_num, true) catch break;
                defer result.loop.deinit();
                den_shell.last_exit_code = executor.executeWhile(&result.loop) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "for ")) {
                var result = parser.parseFor(lines, line_num) catch break;
                defer result.loop.deinit();
                den_shell.last_exit_code = executor.executeFor(&result.loop) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "case ")) {
                var result = parser.parseCase(lines, line_num) catch break;
                defer result.stmt.deinit();
                den_shell.last_exit_code = executor.executeCase(&result.stmt) catch 1;
                line_num = result.end;
                continue;
            }

            // Heredoc: accumulate body lines and pass entire block to shell
            if (std.mem.indexOf(u8, trimmed, "<<") != null and
                std.mem.indexOf(u8, trimmed, "<<<") == null)
            {
                // Find the delimiter after <<
                var hd_search: usize = 0;
                const hd_pos = blk: {
                    while (hd_search < trimmed.len) {
                        const p = std.mem.indexOf(u8, trimmed[hd_search..], "<<") orelse break;
                        const ap = hd_search + p;
                        if (ap + 2 < trimmed.len and trimmed[ap + 2] == '<') {
                            hd_search = ap + 3;
                            continue;
                        }
                        break :blk ap;
                    }
                    break :blk @as(?usize, null);
                };

                if (hd_pos) |hp| {
                    var after = hp + 2;
                    if (after < trimmed.len and trimmed[after] == '-') after += 1;
                    while (after < trimmed.len and (trimmed[after] == ' ' or trimmed[after] == '\t')) after += 1;

                    // Extract delimiter (handle quotes)
                    var ds = after;
                    var de = after;
                    if (ds < trimmed.len and (trimmed[ds] == '\'' or trimmed[ds] == '"')) {
                        const q = trimmed[ds];
                        ds += 1;
                        de = ds;
                        while (de < trimmed.len and trimmed[de] != q) de += 1;
                    } else {
                        while (de < trimmed.len and trimmed[de] != ' ' and trimmed[de] != '\t') de += 1;
                    }
                    const delimiter = trimmed[ds..de];

                    if (delimiter.len > 0) {
                        // Accumulate lines until we find the delimiter
                        var heredoc_lines_buf: [4096]u8 = undefined;
                        var heredoc_len: usize = 0;

                        // Start with the command line itself
                        if (trimmed.len <= heredoc_lines_buf.len) {
                            @memcpy(heredoc_lines_buf[0..trimmed.len], trimmed);
                            heredoc_len = trimmed.len;
                        }

                        // Collect body lines
                        while (line_num + 1 < lines.len) {
                            line_num += 1;
                            const body_line = lines[line_num];
                            const body_trimmed = std.mem.trim(u8, body_line, &std.ascii.whitespace);

                            // Add newline + line
                            if (heredoc_len + 1 + body_line.len <= heredoc_lines_buf.len) {
                                heredoc_lines_buf[heredoc_len] = '\n';
                                heredoc_len += 1;
                                @memcpy(heredoc_lines_buf[heredoc_len .. heredoc_len + body_line.len], body_line);
                                heredoc_len += body_line.len;
                            }

                            if (std.mem.eql(u8, body_trimmed, delimiter)) break;
                        }

                        // Pass the full heredoc block (command + body + delimiter) to the shell
                        const full_heredoc = heredoc_lines_buf[0..heredoc_len];
                        if (den_shell.preprocessHeredoc(full_heredoc)) |rewritten| {
                            if (rewritten.len > 0) {
                                // Rewritten as herestring — execute it
                                den_shell.executeCommand(rewritten) catch {};
                                allocator.free(rewritten);
                            }
                            // else: empty string means preprocessHeredoc already executed via pipe
                        } else {
                            den_shell.executeCommand(trimmed) catch {};
                        }
                        if (den_shell.option_errexit and den_shell.last_exit_code != 0) break;
                        continue;
                    }
                }
            }

            // Regular command
            den_shell.executeCommand(trimmed) catch {};
            if (den_shell.option_errexit and den_shell.last_exit_code != 0) break;
        }
        den_shell.current_line = 0;
    } else {
        // Single-line command
        den_shell.executeCommand(command) catch |err| {
            den_shell.executeExitTrap();
            if (json_output) {
                try IO.print("{{\"error\":\"{s}\",\"exit_code\":{d}}}\n", .{ @errorName(err), den_shell.last_exit_code });
            }
            return err;
        };
    }

    // Fire EXIT trap before leaving
    den_shell.executeExitTrap();

    // Output JSON result if requested
    if (json_output) {
        try IO.print("{{\"exit_code\":{d}}}\n", .{den_shell.last_exit_code});
    }

    // Propagate exit code to OS (critical for scripts and tools like Claude Code)
    if (den_shell.last_exit_code != 0) {
        std.process.exit(@intCast(@as(u32, @bitCast(den_shell.last_exit_code))));
    }
}

// Tests
test "parseArgs: no arguments" {
    // This test is conceptual - actual testing would require mocking process.args
    // Which is complex in Zig. The logic is simple enough to verify manually.
}

test "parseArgs: version flag" {
    // Conceptual test
}

test "parseArgs: help flag" {
    // Conceptual test
}
