const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const redirection = @import("executor/redirection.zig");
const process_util = @import("utils/process.zig");

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const raw = std.c.getenv(key) orelse return null;
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    return allocator.dupe(u8, value) catch null;
}

/// Append `raw` to `list` if it's a non-empty, not-yet-seen path. `list` owns the
/// duplicated string; `seen` borrows the same pointer for dedup.
fn addUniquePath(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    raw: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (seen.contains(trimmed)) return;
    const owned = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
    try seen.put(owned, {});
}

/// Read a newline-separated path file (e.g. /etc/paths) and append each entry.
/// Missing or unreadable files are silently ignored, matching path_helper.
fn appendPathsFromFile(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    path: []const u8,
) void {
    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return;
    defer file.close(std.Options.debug_io);
    const content = IO.readFileAlloc(allocator, file, 64 * 1024) catch return;
    defer allocator.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        addUniquePath(allocator, list, seen, line) catch {};
    }
}

/// macOS GUI terminals launch the login shell with a bare PATH
/// (/usr/bin:/bin:/usr/sbin:/sbin plus the terminal's own dir). The system
/// convention — implemented by /usr/libexec/path_helper and invoked from
/// /etc/zprofile — is to build PATH from /etc/paths and /etc/paths.d/*, then
/// append whatever was already there. We replicate that natively (no subprocess)
/// so Homebrew, ~/.local/bin, cargo, etc. resolve, while keeping startup fast.
fn applySystemPaths(allocator: std.mem.Allocator, env: *std.StringHashMap([]const u8)) !void {
    if (builtin.os.tag != .macos) return;

    var list = std.ArrayList([]const u8).empty;
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // 1. Base system paths.
    appendPathsFromFile(allocator, &list, &seen, "/etc/paths");

    // 2. Drop-in fragments, applied in sorted filename order (as path_helper does).
    if (std.Io.Dir.openDirAbsolute(std.Options.debug_io, "/etc/paths.d", .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(std.Options.debug_io);

        var names = std.ArrayList([]const u8).empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        var it = dir.iterate();
        while (it.next(std.Options.debug_io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = allocator.dupe(u8, entry.name) catch continue;
            names.append(allocator, name) catch {
                allocator.free(name);
                continue;
            };
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        for (names.items) |name| {
            const full = std.fmt.allocPrint(allocator, "/etc/paths.d/{s}", .{name}) catch continue;
            defer allocator.free(full);
            appendPathsFromFile(allocator, &list, &seen, full);
        }
    } else |_| {}

    // 3. Preserve entries already present in the inherited PATH.
    if (env.get("PATH")) |existing| {
        var it = std.mem.splitScalar(u8, existing, ':');
        while (it.next()) |p| addUniquePath(allocator, &list, &seen, p) catch {};
    }

    if (list.items.len == 0) return;

    const joined = try std.mem.join(allocator, ":", list.items);
    errdefer allocator.free(joined);
    const key = try allocator.dupe(u8, "PATH");
    errdefer allocator.free(key);

    if (env.fetchRemove("PATH")) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }
    try env.put(key, joined);
}

const Terminal = @import("utils/terminal.zig");
const LineEditor = Terminal.LineEditor;
const Completion = @import("utils/completion.zig").Completion;
const Expansion = @import("utils/expansion.zig").Expansion;
const Glob = @import("utils/glob.zig").Glob;
const BraceExpander = @import("utils/brace.zig").BraceExpander;
const ScriptManager = @import("scripting/script_manager.zig").ScriptManager;
const FunctionManager = @import("scripting/functions.zig").FunctionManager;
const ControlFlowParser = @import("scripting/control_flow.zig").ControlFlowParser;
const ControlFlowExecutor = @import("scripting/control_flow.zig").ControlFlowExecutor;
const PluginRegistry = @import("plugins/interface.zig").PluginRegistry;
const PluginManager = @import("plugins/manager.zig").PluginManager;
const HookType = @import("plugins/interface.zig").HookType;
const HookContext = @import("plugins/interface.zig").HookContext;
const AutoSuggestPlugin = @import("plugins/builtin_plugins_advanced.zig").AutoSuggestPlugin;
const HighlightPlugin = @import("plugins/builtin_plugins_advanced.zig").HighlightPlugin;
const ScriptSuggesterPlugin = @import("plugins/builtin_plugins_advanced.zig").ScriptSuggesterPlugin;
const concurrency = @import("utils/concurrency.zig");
const diagnostic = @import("utils/diagnostic.zig");
const config_loader = @import("config_loader.zig");
const builtin = @import("builtin");
const env_utils = @import("utils/env.zig");
const PromptRenderer = @import("prompt/renderer.zig").PromptRenderer;
const PromptContext = @import("prompt/types.zig").PromptContext;
const PromptTemplate = @import("prompt/types.zig").PromptTemplate;
const SystemInfo = @import("prompt/sysinfo.zig").SystemInfo;
const GitModule = @import("prompt/git.zig").GitModule;
const AsyncGitFetcher = @import("prompt/async_git.zig").AsyncGitFetcher;
const ansi = @import("utils/ansi.zig");
const signals = @import("utils/signals.zig");
const HistoryExpansion = @import("utils/history_expansion.zig").HistoryExpansion;
const ContextCompletion = @import("utils/context_completion.zig").ContextCompletion;
const CompletionRegistry = @import("utils/completion_registry.zig").CompletionRegistry;
const CompletionSpec = @import("utils/completion_registry.zig").CompletionSpec;
const LoadableBuiltins = @import("utils/loadable.zig").LoadableBuiltins;
const History = @import("history/history.zig").History;
const StructuredHistory = @import("history/sqlite_history.zig").StructuredHistory;
const jobs_mod = @import("jobs/mod.zig");
const JobManager = jobs_mod.JobManager;
const JobStatus = jobs_mod.JobStatus;
const ProcessId = jobs_mod.ProcessId;
const BackgroundJob = jobs_mod.BackgroundJob;
const regex = @import("utils/regex.zig");
const matchRegexAt = regex.matchRegexAt;
const config_watch = @import("utils/config_watch.zig");
const getConfigMtime = config_watch.getConfigMtime;
const shell_mod = @import("shell/mod.zig");

/// Hard limit for in-memory history entries.
/// This ensures predictable memory usage regardless of config.history.max_entries.
/// The effective max is min(config.history.max_entries, HISTORY_HARD_LIMIT).
const HISTORY_HARD_LIMIT: usize = 1000;

/// Format a parser error into a user-friendly message.
fn formatParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnexpectedEndOfInput => "unexpected end of input (missing operand after operator)",
        error.RedirectionMissingTarget => "missing target for redirection",
        error.InvalidFileDescriptor => "invalid file descriptor in redirection",
        error.EmptyCommand => "empty command",
        error.TooManyOperators => "too many operators in command (limit: 31)",
        error.TooManyCommands => "too many commands in pipeline (limit: 32)",
        error.TooManyArguments => "too many arguments (limit: 128)",
        error.TooManyRedirections => "too many redirections (limit: 16)",
        error.TooManyTokens => "command too complex (limit: 1024 tokens)",
        else => "syntax error",
    };
}

/// Extract exit status from wait status (cross-platform)
fn getExitStatus(status: u32) i32 {
    if (builtin.os.tag == .windows) {
        // Windows uses the status directly
        return @intCast(status);
    } else {
        // POSIX systems use WEXITSTATUS macro
        return std.posix.W.EXITSTATUS(status);
    }
}

/// Cross-platform getenv wrapper
fn isValidVarName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn getenv(key: []const u8) ?[]const u8 {
    return env_utils.getEnv(key);
}

/// Flush any pending bytes from stdin (non-blocking)
extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;
const TCIFLUSH = 1;

fn flushStdin() void {
    if (comptime builtin.os.tag == .windows) return;
    _ = tcflush(std.posix.STDIN_FILENO, TCIFLUSH);
}

/// Ensure terminal is ready for prompt after a child process exits.
/// Resets terminal attributes and moves to a fresh line.
fn resetTerminalAfterChild() void {
    if (comptime builtin.os.tag == .windows) return;

    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

    // Restore sane terminal settings (child may have left raw mode, etc.)
    var termios = std.posix.tcgetattr(stdin_fd) catch return;
    termios.lflag = .{
        .ECHO = true,
        .ICANON = true,
        .ISIG = true,
        .IEXTEN = true,
        .ECHOE = true,
        .ECHOK = true,
        .ECHOCTL = true,
        .ECHOKE = true,
    };
    termios.iflag.ICRNL = true;
    termios.oflag.OPOST = true;
    termios.oflag.ONLCR = true;
    std.posix.tcsetattr(stdin_fd, .NOW, termios) catch {};

    // Move to a new line and clear it — ensures prompt appears
    // below any child output, not on top of it
    _ = std.c.write(stdout_fd, "\n\r\x1b[K", 5);
}

/// Call stack frame for caller builtin
pub const CallFrame = struct {
    line_number: usize,
    function_name: []const u8,
    source_file: []const u8,
};

/// Callback for command substitution in forked child processes.
/// Allows expansion.zig to call shell.executeCommand without circular imports.
pub fn execCommandCallback(shell_opaque: *anyopaque, command: []const u8) void {
    const self: *Shell = @ptrCast(@alignCast(shell_opaque));
    self.executeCommand(command) catch {};
}

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    config: types.DenConfig,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    global_aliases: std.StringHashMap([]const u8), // zsh-style global aliases (expanded anywhere, not just command position)
    suffix_aliases: std.StringHashMap([]const u8), // extension -> command (zsh-style suffix aliases)
    last_exit_code: i32,
    job_manager: JobManager,
    // History buffer: fixed-size array with effective_max from config
    // Note: max hard limit is 1000 for predictable memory; config.history.max_entries
    // can be smaller but not larger than this.
    history: [HISTORY_HARD_LIMIT]?[]const u8,
    history_count: usize,
    history_max: usize, // Effective max from config (capped at HISTORY_HARD_LIMIT)
    history_file_path: []const u8,
    structured_history: ?StructuredHistory,
    history_expander: HistoryExpansion,
    dir_stack: [32]?[]const u8,
    dir_stack_count: usize,
    positional_params: [64]?[]const u8,
    positional_params_count: usize,
    shell_name: []const u8,
    last_arg: []const u8,
    // Shell options
    option_errexit: bool, // set -e: exit on error
    option_errtrace: bool, // set -E: inherit ERR trap
    option_xtrace: bool, // set -x: print commands before execution
    option_nounset: bool, // set -u: error on unset variable
    option_pipefail: bool, // set -o pipefail: pipeline returns rightmost non-zero exit
    option_noexec: bool, // set -n: read commands but don't execute (syntax check)
    option_verbose: bool, // set -v: print input lines as read
    option_noglob: bool, // set -f: disable filename expansion (globbing)
    option_noclobber: bool, // set -C: prevent overwriting files with >
    option_restricted: bool, // set -r: restricted mode (cannot be unset once enabled)
    current_line: usize, // For error reporting
    // Script management
    script_manager: ScriptManager,
    // Function management
    function_manager: FunctionManager,
    // Signal handling
    signal_handlers: std.StringHashMap([]const u8),
    // Command path cache (for hash builtin)
    command_cache: std.StringHashMap([]const u8),
    // Named directories (zsh-style hash -d)
    named_dirs: std.StringHashMap([]const u8),
    // Array variables (zsh-style arrays); sparse indexed arrays
    arrays: std.StringHashMap(types.IndexedArray),
    // Custom completion specifications (like bash's complete)
    completion_registry: CompletionRegistry,
    // Plugin system
    plugin_registry: PluginRegistry,
    plugin_manager: PluginManager,
    // Builtin plugins (optional)
    auto_suggest: ?AutoSuggestPlugin,
    highlighter: ?HighlightPlugin,
    script_suggester: ?ScriptSuggesterPlugin,
    // Concurrency
    thread_pool: concurrency.ThreadPool,
    // Interactive mode
    is_interactive: bool,
    line_editor: ?LineEditor,
    // Prompt rendering
    prompt_renderer: ?PromptRenderer,
    prompt_context: PromptContext,
    // Async git fetcher for non-blocking prompts
    async_git: AsyncGitFetcher,
    // REPL multiline input state (for function definitions)
    multiline_buffer: [100]?[]const u8,
    multiline_count: usize,
    multiline_brace_count: i32,
    multiline_mode: MultilineMode,
    // Flag to prevent re-entrancy in C-style for loop execution
    in_cstyle_for_body: bool,
    // Counter for break statement in loops (0 = no break, N = break N levels)
    break_levels: u32,
    // Counter for continue statement in loops (0 = no continue, N = continue N levels)
    continue_levels: u32,
    // Flag: last executed chain was an AND-OR list (&&/||), so errexit should not apply
    last_chain_had_and_or: bool,
    // Coprocess tracking
    coproc_pid: ?std.posix.pid_t,
    coproc_read_fd: ?std.posix.fd_t,
    coproc_write_fd: ?std.posix.fd_t,
    // Config hot-reload tracking
    config_source: config_loader.ConfigSource,
    config_last_mtime: i128,
    // Variable attributes (for declare/typeset)
    var_attributes: std.StringHashMap(types.VarAttributes),
    // Associative arrays (declare -A)
    assoc_arrays: std.StringHashMap(std.StringHashMap([]const u8)),
    // Shopt options
    shopt_extglob: bool, // Extended glob patterns
    shopt_nullglob: bool, // Patterns that match nothing expand to empty
    shopt_dotglob: bool, // Patterns match dotfiles
    shopt_nocaseglob: bool, // Case-insensitive globbing
    shopt_globstar: bool, // ** matches recursively
    shopt_failglob: bool, // Failed globs cause error
    shopt_expand_aliases: bool, // Expand aliases in non-interactive shells
    shopt_sourcepath: bool, // Search PATH for source command
    shopt_checkwinsize: bool, // Check window size after each command
    shopt_histappend: bool, // Append to history file
    shopt_cmdhist: bool, // Save multi-line commands in history
    shopt_autocd: bool, // Directory names auto-cd
    // Call stack for caller builtin
    call_stack: [64]CallFrame,
    call_stack_depth: usize,
    // Loadable builtins (dynamically loaded shared libraries)
    loadable_builtins: LoadableBuiltins,

    const MultilineMode = enum {
        none,
        function_def,
    };

    pub fn init(allocator: std.mem.Allocator) !Shell {
        return initWithConfig(allocator, null);
    }

    /// Initialize shell without loading any configuration files (--norc mode).
    /// Uses default configuration only, skipping all config file discovery.
    pub fn initNoConfig(allocator: std.mem.Allocator) !Shell {
        return initWithConfigResult(allocator, config_loader.ConfigLoadResult{
            .config = types.DenConfig{},
            .source = .{ .path = null, .source_type = .default },
        });
    }

    /// Initialize shell with a custom config path
    /// If config_path is provided, it takes priority over default search paths
    pub fn initWithConfig(allocator: std.mem.Allocator, config_path: ?[]const u8) !Shell {
        // Load configuration from files and environment variables (with source tracking)
        const config_result = config_loader.loadConfigWithPathAndSource(allocator, config_path) catch config_loader.ConfigLoadResult{
            .config = types.DenConfig{},
            .source = .{ .path = null, .source_type = .default },
        };
        return initWithConfigResult(allocator, config_result);
    }

    /// Internal: initialize shell with a pre-resolved config result
    fn initWithConfigResult(allocator: std.mem.Allocator, config_result: config_loader.ConfigLoadResult) !Shell {
        const config = config_result.config;
        const config_source = config_result.source;

        // Get initial mtime for hot-reload
        const config_mtime = getConfigMtime(config_source.path);

        // Initialize environment from system - inherit all parent environment variables.
        // env owns its keys and values; if any subsequent step in init fails, this
        // errdefer drains every populated entry so they don't leak.
        var env = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var env_it = env.iterator();
            while (env_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            env.deinit();
        }

        // Inherit all environment variables from parent process
        if (builtin.os.tag != .windows) {
            const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
            var i: usize = 0;
            while (c_environ.*[i]) |entry| : (i += 1) {
                const entry_str = std.mem.span(@as([*:0]const u8, @ptrCast(entry)));
                if (std.mem.indexOfScalar(u8, entry_str, '=')) |eq_pos| {
                    const key = try allocator.dupe(u8, entry_str[0..eq_pos]);
                    errdefer allocator.free(key);
                    const val = try allocator.dupe(u8, entry_str[eq_pos + 1 ..]);
                    errdefer allocator.free(val);
                    try env.put(key, val);
                }
            }
        }

        // Ensure critical variables have fallback values
        const home = if (env.get("HOME")) |h|
            try allocator.dupe(u8, h)
        else blk: {
            const fallback = getEnvOwned(allocator, "USERPROFILE") orelse
                try allocator.dupe(u8, "/");
            const home_key = try allocator.dupe(u8, "HOME");
            errdefer allocator.free(home_key);
            const home_val = try allocator.dupe(u8, fallback);
            errdefer allocator.free(home_val);
            try env.put(home_key, home_val);
            break :blk fallback;
        };
        defer allocator.free(home);

        if (!env.contains("PATH")) {
            const path_key = try allocator.dupe(u8, "PATH");
            errdefer allocator.free(path_key);
            const path_val = try allocator.dupe(u8, "/usr/bin:/bin");
            errdefer allocator.free(path_val);
            try env.put(path_key, path_val);
        }

        // On macOS, build the full system PATH from /etc/paths(.d) so commands
        // installed by Homebrew, cargo, npm, ~/.local/bin, etc. resolve even when
        // a GUI terminal launches us with only a minimal PATH. No-op elsewhere.
        applySystemPaths(allocator, &env) catch {};

        // Load default environment variables from config
        if (config.environment.enabled) {
            // First, set defaults (only if not already in environment)
            for (types.EnvironmentConfig.defaults) |default_var| {
                if (!env.contains(default_var.name)) {
                    const key_copy = try allocator.dupe(u8, default_var.name);
                    errdefer allocator.free(key_copy);
                    const value_copy = try allocator.dupe(u8, default_var.value);
                    errdefer allocator.free(value_copy);
                    try env.put(key_copy, value_copy);
                }
            }

            // Then, apply custom environment from config (these override defaults)
            if (config.environment.variables) |custom_vars| {
                for (custom_vars) |env_var| {
                    const value_copy = try allocator.dupe(u8, env_var.value);
                    errdefer allocator.free(value_copy);
                    const key_copy = try allocator.dupe(u8, env_var.name);
                    errdefer allocator.free(key_copy);
                    // Free old key and value if exists
                    if (env.fetchRemove(env_var.name)) |old_kv| {
                        allocator.free(old_kv.key);
                        allocator.free(old_kv.value);
                    }
                    try env.put(key_copy, value_copy);
                }
            }
        }

        // Build history file path from config (expand ~ to home directory)
        var history_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const config_history_file = config.history.file;
        const history_path = if (std.mem.startsWith(u8, config_history_file, "~/"))
            try std.fmt.bufPrint(&history_path_buf, "{s}/{s}", .{ home, config_history_file[2..] })
        else if (std.mem.eql(u8, config_history_file, "~"))
            home
        else
            config_history_file;
        const history_path_owned = try allocator.dupe(u8, history_path);
        errdefer allocator.free(history_path_owned);

        // Initialize thread pool with automatic CPU detection
        var thread_pool = try concurrency.ThreadPool.init(allocator, 0);
        errdefer thread_pool.deinit();

        // Install signal handlers
        signals.installHandlers() catch |err| {
            IO.eprint("den: warning: failed to install signal handlers: {}\n", .{err}) catch {};
        };

        var shell = Shell{
            .allocator = allocator,
            .running = false,
            .config = config,
            .environment = env,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .global_aliases = std.StringHashMap([]const u8).init(allocator),
            .suffix_aliases = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
            .job_manager = JobManager.init(allocator),
            .history = @splat(null),
            .history_count = 0,
            .history_max = @min(config.history.max_entries, HISTORY_HARD_LIMIT),
            .history_file_path = history_path_owned,
            .structured_history = null,
            .history_expander = HistoryExpansion.init(allocator),
            .dir_stack = @splat(null),
            .dir_stack_count = 0,
            .positional_params = @splat(null),
            .positional_params_count = 0,
            .shell_name = "den",
            .last_arg = "",
            .option_errexit = false,
            .option_errtrace = false,
            .option_xtrace = false,
            .option_nounset = false,
            .option_pipefail = false,
            .option_noexec = false,
            .option_verbose = false,
            .option_noglob = false,
            .option_noclobber = false,
            .option_restricted = false,
            .current_line = 0,
            .script_manager = ScriptManager.init(allocator),
            .function_manager = FunctionManager.init(allocator),
            .signal_handlers = std.StringHashMap([]const u8).init(allocator),
            .command_cache = std.StringHashMap([]const u8).init(allocator),
            .named_dirs = std.StringHashMap([]const u8).init(allocator),
            .arrays = std.StringHashMap(types.IndexedArray).init(allocator),
            .completion_registry = CompletionRegistry.init(allocator),
            .plugin_registry = PluginRegistry.init(allocator),
            .plugin_manager = PluginManager.init(allocator),
            .auto_suggest = null, // Initialized on demand
            .highlighter = null, // Initialized on demand
            .script_suggester = null, // Initialized on demand
            .thread_pool = thread_pool,
            .is_interactive = false,
            .line_editor = null,
            .prompt_renderer = null,
            .prompt_context = PromptContext.init(allocator),
            .async_git = AsyncGitFetcher.init(allocator),
            .multiline_buffer = @splat(null),
            .multiline_count = 0,
            .multiline_brace_count = 0,
            .multiline_mode = .none,
            .in_cstyle_for_body = false,
            .break_levels = 0,
            .continue_levels = 0,
            .last_chain_had_and_or = false,
            .coproc_pid = null,
            .coproc_read_fd = null,
            .coproc_write_fd = null,
            .config_source = config_source,
            .config_last_mtime = config_mtime,
            .var_attributes = std.StringHashMap(types.VarAttributes).init(allocator),
            .assoc_arrays = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .shopt_extglob = true, // Enabled by default (we implemented it)
            .shopt_nullglob = false,
            .shopt_dotglob = false,
            .shopt_nocaseglob = false,
            .shopt_globstar = false,
            .shopt_failglob = false,
            .shopt_expand_aliases = true,
            .shopt_sourcepath = true,
            .shopt_checkwinsize = true,
            .shopt_histappend = false,
            .shopt_cmdhist = true,
            .shopt_autocd = true,
            .call_stack = @splat(CallFrame{ .line_number = 0, .function_name = "", .source_file = "" }),
            .call_stack_depth = 0,
            .loadable_builtins = LoadableBuiltins.init(allocator),
        };

        // Detect setuid condition and drop privileges
        if (comptime builtin.os.tag != .windows) {
            const real_uid = std.c.getuid();
            const effective_uid = std.c.geteuid();
            if (real_uid != effective_uid) {
                IO.eprint("den: warning: running with elevated privileges, dropping to real uid\n", .{}) catch {};
                _ = std.c.setuid(real_uid);
            }
        }

        // Detect if stdin is a TTY
        if (comptime builtin.os.tag != .windows) {
            shell.is_interactive = (std.Io.File{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } }).isTty(std.Options.debug_io) catch false;
            shell.job_manager.interactive = shell.is_interactive;
        }

        // Load history from file
        shell.loadHistory() catch {
            // Ignore errors loading history (file might not exist yet)
        };

        // Load aliases from config
        shell.loadAliasesFromConfig() catch {
            // Ignore errors loading aliases
        };

        // Execute shell_init hooks
        var init_context = HookContext{
            .hook_type = .shell_init,
            .data = null,
            .user_data = null,
            .allocator = allocator,
        };
        shell.plugin_registry.executeHooks(.shell_init, &init_context) catch {};

        // Set global completion config for tabCompletionFn
        shell_mod.setCompletionConfig(config.completion);

        return shell;
    }

    pub fn deinit(self: *Shell) void {
        // Clean up coprocess
        if (comptime builtin.os.tag != .windows) {
            if (self.coproc_read_fd) |fd| _ = std.c.close(fd);
            if (self.coproc_write_fd) |fd| _ = std.c.close(fd);
            if (self.coproc_pid) |pid| {
                _ = std.posix.kill(pid, std.posix.SIG.HUP) catch {};
                var ws: c_int = 0;
                _ = std.c.waitpid(@intCast(pid), &ws, std.posix.W.NOHANG);
            }
        }
        self.coproc_read_fd = null;
        self.coproc_write_fd = null;
        self.coproc_pid = null;

        // Clean up async git fetcher
        self.async_git.deinit();

        // Clean up prompt renderer
        if (self.prompt_renderer) |*renderer| {
            renderer.deinit();
        }
        self.prompt_context.deinit();

        // Clean up line editor
        if (self.line_editor) |*editor| {
            // Free the prompt string we allocated via getPromptString
            if (editor.prompt.len > 0) {
                self.allocator.free(editor.prompt);
            }
            if (editor.transient_prompt) |tp| {
                self.allocator.free(tp);
            }
            editor.deinit();
        }

        // Execute shell_exit hooks
        var exit_context = HookContext{
            .hook_type = .shell_exit,
            .data = null,
            .user_data = null,
            .allocator = self.allocator,
        };
        self.plugin_registry.executeHooks(.shell_exit, &exit_context) catch {};

        // Save history before cleanup
        self.saveHistory() catch {
            // Ignore errors saving history
        };

        // Clean up builtin plugins
        if (self.script_suggester) |*suggester| {
            suggester.deinit();
        }

        // Clean up plugin system
        self.plugin_manager.deinit();
        self.plugin_registry.deinit();

        // Clean up script manager
        self.script_manager.deinit();

        // Clean up loadable builtins
        self.loadable_builtins.deinit();

        // Clean up function manager
        self.function_manager.deinit();

        // Clean up signal handlers
        var sig_iter = self.signal_handlers.iterator();
        while (sig_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.signal_handlers.deinit();

        // Clean up command cache
        var cache_iter = self.command_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.command_cache.deinit();

        // Clean up named directories
        var named_iter = self.named_dirs.iterator();
        while (named_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.named_dirs.deinit();

        // Clean up arrays
        var arrays_iter = self.arrays.iterator();
        while (arrays_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.arrays.deinit();

        // Clean up associative arrays
        var assoc_iter = self.assoc_arrays.iterator();
        while (assoc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var inner_iter = entry.value_ptr.iterator();
            while (inner_iter.next()) |inner_entry| {
                self.allocator.free(inner_entry.key_ptr.*);
                self.allocator.free(inner_entry.value_ptr.*);
            }
            entry.value_ptr.deinit();
        }
        self.assoc_arrays.deinit();

        // Clean up variable attributes
        var attr_iter = self.var_attributes.iterator();
        while (attr_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.var_attributes.deinit();

        // Clean up completion registry
        self.completion_registry.deinit();

        // Clean up job manager (kills and frees all background jobs)
        self.job_manager.deinit();

        // Clean up history (only clean up entries that were actually used)
        History.deinit(self.allocator, self.history[0..self.history_max], self.history_file_path);
        if (self.structured_history) |*sh| {
            sh.deinit();
        }

        // Clean up directory stack
        for (self.dir_stack) |maybe_dir| {
            if (maybe_dir) |dir| {
                self.allocator.free(dir);
            }
        }

        // Clean up positional parameters
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                self.allocator.free(param);
            }
        }

        // Clean up shell_name if it was dynamically allocated
        if (!std.mem.eql(u8, self.shell_name, "den")) {
            self.allocator.free(self.shell_name);
        }

        // Clean up environment variables (keys and values were allocated)
        var env_iter = self.environment.iterator();
        while (env_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.environment.deinit();

        // Clean up aliases (keys and values were allocated)
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        // Clean up global aliases (keys and values were allocated)
        var global_iter = self.global_aliases.iterator();
        while (global_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.global_aliases.deinit();

        // Clean up suffix aliases (keys and values were allocated)
        var suffix_iter = self.suffix_aliases.iterator();
        while (suffix_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.suffix_aliases.deinit();

        // Clean up thread pool
        self.thread_pool.deinit();
    }

    /// Initialize AutoSuggest plugin
    pub fn initAutoSuggest(self: *Shell) void {
        if (self.auto_suggest == null) {
            self.auto_suggest = AutoSuggestPlugin.init(
                self.allocator,
                &self.history,
                &self.history_count,
                &self.environment,
            );
        }
    }

    /// Initialize Highlight plugin
    pub fn initHighlighter(self: *Shell) void {
        if (self.highlighter == null) {
            self.highlighter = HighlightPlugin.init(self.allocator);
        }
    }

    /// Initialize ScriptSuggester plugin
    pub fn initScriptSuggester(self: *Shell) void {
        if (self.script_suggester == null) {
            self.script_suggester = ScriptSuggesterPlugin.init(self.allocator);
        }
    }

    /// Get command suggestions using AutoSuggest plugin
    pub fn getCommandSuggestions(self: *Shell, input: []const u8) ![][]const u8 {
        self.initAutoSuggest();
        if (self.auto_suggest) |*plugin| {
            return try plugin.getSuggestions(input);
        }
        return try self.allocator.alloc([]const u8, 0);
    }

    /// Highlight command using Highlight plugin
    pub fn highlightCommand(self: *Shell, input: []const u8) ![]HighlightPlugin.HighlightToken {
        self.initHighlighter();
        if (self.highlighter) |*plugin| {
            return try plugin.highlight(input);
        }
        return try self.allocator.alloc(HighlightPlugin.HighlightToken, 0);
    }

    /// Get script suggestions using ScriptSuggester plugin
    pub fn getScriptSuggestions(self: *Shell, input: []const u8) ![][]const u8 {
        self.initScriptSuggester();
        if (self.script_suggester) |*plugin| {
            return try plugin.getSuggestions(input, &self.environment);
        }
        return try self.allocator.alloc([]const u8, 0);
    }

    pub fn run(self: *Shell) !void {
        self.running = true;

        // Onboarding banner is opt-in (DEN_BANNER=1). A daily-driver login shell
        // shouldn't greet you on every new terminal, and printing it
        // unconditionally also pollutes the output of `... | den`.
        if (std.c.getenv("DEN_BANNER") != null) {
            try IO.print("Den shell initialized!\n", .{});
            try IO.print("Type 'exit' to quit or Ctrl+D to exit.\n\n", .{});
        }

        while (self.running) {
            // Check for config hot-reload
            self.checkConfigHotReload();

            // Check for signals
            if (signals.checkSignal()) |sig| {
                switch (sig) {
                    .interrupt => {
                        // SIGINT (Ctrl+C) - just print newline and continue
                        try IO.print("\n", .{});
                        continue;
                    },
                    .terminate => {
                        // SIGTERM - graceful shutdown
                        try IO.print("\nReceived termination signal, shutting down...\n", .{});
                        self.running = false;
                        break;
                    },
                    .winch => {
                        // SIGWINCH - window resize
                        // The terminal will automatically adjust
                    },
                    .none => {},
                }
            }

            // Check for window size changes
            if (signals.checkWindowSizeChanged()) {
                // Window was resized, terminal will auto-adjust
            }

            // Check for completed background jobs
            try self.job_manager.checkCompleted();

            // Read line from stdin
            const line = blk: {
                if (self.is_interactive) {
                    // Initialize line editor on first use
                    if (self.line_editor == null) {
                        const prompt_str = try self.getPromptString();
                        var editor = LineEditor.init(self.allocator, prompt_str);
                        editor.syntax_highlighting = self.config.line_editor.syntax_highlighting;
                        editor.autosuggestions = self.config.line_editor.autosuggestions;
                        editor.suggestion_min_chars = @max(1, self.config.line_editor.suggestion_min_chars);
                        editor.setHistory(&self.history, &self.history_count);
                        editor.setCompletionFn(shell_mod.tabCompletionFn);
                        editor.setPromptRefreshFn(refreshPromptCallback);
                        editor.user_data = @ptrCast(self);
                        // Set transient prompt if enabled in config
                        if (self.config.prompt.transient) {
                            if (self.prompt_renderer) |*renderer| {
                                const transient_str = renderer.renderTransient(&self.prompt_context) catch null;
                                if (transient_str) |ts| {
                                    editor.setTransientPrompt(ts);
                                }
                            }
                        }
                        self.line_editor = editor;
                        // Don't free prompt_str here - LineEditor needs it!
                    } else {
                        // Update prompt for next line
                        const old_prompt = self.line_editor.?.prompt;
                        const prompt_str = try self.getPromptString();
                        self.line_editor.?.prompt = prompt_str;
                        // Free the old prompt to avoid memory leak
                        self.allocator.free(old_prompt);

                        // Update transient prompt if enabled
                        if (self.config.prompt.transient) {
                            // Free old transient prompt if it was allocated
                            if (self.line_editor.?.transient_prompt) |old_transient| {
                                self.allocator.free(old_transient);
                                self.line_editor.?.transient_prompt = null;
                            }
                            if (self.prompt_renderer) |*renderer| {
                                const transient_str = renderer.renderTransient(&self.prompt_context) catch null;
                                if (transient_str) |ts| {
                                    self.line_editor.?.setTransientPrompt(ts);
                                }
                            }
                        }
                    }

                    // Use line editor for interactive input
                    break :blk self.line_editor.?.readLine() catch |err| {
                        if (err == error.Interrupted) {
                            try IO.print("\n", .{});
                            continue;
                        }
                        return err;
                    };
                } else {
                    // Non-interactive: render simple prompt and use basic readLine
                    try self.renderPrompt();
                    break :blk try IO.readLine(self.allocator);
                }
            };

            if (line == null) {
                // EOF (Ctrl+D) - graceful shutdown
                if (std.c.getenv("DEN_BANNER") != null) try IO.print("\nGoodbye from Den!\n", .{});
                self.running = false;
                break; // Exit loop and let deinit() handle cleanup
            }

            defer self.allocator.free(line.?);

            const trimmed = std.mem.trim(u8, line.?, &std.ascii.whitespace);

            if (trimmed.len == 0) continue;

            // Handle multiline input (function definitions)
            if (self.multiline_mode != .none) {
                // Continue collecting lines for multiline construct
                try self.handleMultilineContinuation(trimmed);
                continue;
            }

            // Check if this line starts a function definition
            if (try self.checkFunctionDefinitionStart(trimmed)) {
                // handleMultilineStart was called and either:
                // - Function was defined (single-line) and we continue
                // - We're now in multiline mode and will continue on next iteration
                continue;
            }

            // Expand history references (!, !!, !N, !-N, !string, ^old^new)
            const maybe_expanded = self.history_expander.expand(trimmed, &self.history, self.history_count) catch |err| {
                IO.eprint("History expansion error: {}\n", .{err}) catch {};
                // On error, continue with original command
                try self.addToHistory(trimmed);
                try self.executeCommand(trimmed);
                continue;
            };
            defer self.allocator.free(maybe_expanded.text);

            // Use expanded command
            const command = maybe_expanded.text;

            // If expanded, show the expanded command
            if (maybe_expanded.expanded) {
                try IO.print("{s}\n", .{command});
            }

            // Add to history (the expanded command)
            try self.addToHistory(command);

            // Handle exit command
            if (std.mem.eql(u8, command, "exit")) {
                if (std.c.getenv("DEN_BANNER") != null) try IO.print("Goodbye from Den!\n", .{});
                self.running = false;
                break; // Exit loop and let deinit() handle cleanup
            }

            // Execute command
            try self.executeCommand(command);

            // Clear any pending SIGINT from child process termination
            _ = signals.checkSignal();

            // Only reset terminal after external commands (not builtins like cd)
            // External commands may leave the terminal in a bad state
            if (self.is_interactive) {
                const first_word = blk: {
                    var iter = std.mem.tokenizeAny(u8, command, " \t");
                    break :blk iter.next() orelse command;
                };
                // Check if it was an external command (not a builtin)
                if (!executor_mod.Executor.isBuiltinName(first_word) and !self.aliases.contains(first_word)) {
                    flushStdin();
                    resetTerminalAfterChild();
                }
            }
        }

        // Fire EXIT trap before leaving
        self.executeExitTrap();
    }

    /// Run a script file with positional parameters (using ScriptManager)
    pub fn runScript(self: *Shell, script_path: []const u8, _: []const u8, args: []const []const u8) !void {
        // Use ScriptManager for enhanced script execution with caching
        const result = try self.script_manager.executeScript(self, script_path, args);

        // Report execution result
        if (result.error_message) |err_msg| {
            try IO.eprint("Script execution failed: {s}\n", .{err_msg});
            self.allocator.free(err_msg);
        }

        self.last_exit_code = result.exit_code;
    }

    /// Check if a line starts a function definition and handle it
    /// Returns true if the line was handled as a function definition
    fn checkFunctionDefinitionStart(self: *Shell, trimmed: []const u8) !bool {
        return try shell_mod.checkFunctionDefinitionStart(self, trimmed);
    }

    fn handleMultilineContinuation(self: *Shell, trimmed: []const u8) !void {
        try shell_mod.handleMultilineContinuation(self, trimmed);
    }

    fn finishFunctionDefinition(self: *Shell) !void {
        try shell_mod.finishFunctionDefinition(self);
    }

    fn resetMultilineState(self: *Shell) void {
        shell_mod.resetMultilineState(self);
    }

    fn renderPrompt(self: *Shell) !void {
        try shell_mod.renderPrompt(self);
    }

    fn getPromptString(self: *Shell) ![]const u8 {
        return try shell_mod.getPromptString(self);
    }

    fn updatePromptContext(self: *Shell) !void {
        try shell_mod.updatePromptContext(self);
    }

    pub fn executeCommand(self: *Shell, input: []const u8) !void {
        // Preprocess heredocs: convert <<DELIM\ncontent\nDELIM to herestring
        if (std.mem.indexOf(u8, input, "<<") != null and std.mem.indexOfScalar(u8, input, '\n') != null) {
            if (self.preprocessHeredoc(input)) |rewritten| {
                defer self.allocator.free(rewritten);
                return self.executeCommand(rewritten);
            }
        }

        // Split on unquoted semicolons and execute each part separately.
        // This ensures variables set by earlier parts are visible to later parts.
        if (self.splitAndExecuteSemicolons(input)) return;

        // Handle ! negation prefix (negate exit code)
        const neg_trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, neg_trimmed, "! ")) {
            const inner = std.mem.trim(u8, neg_trimmed[2..], &std.ascii.whitespace);
            if (inner.len > 0) {
                self.executeCommand(inner) catch {};
                self.last_exit_code = if (self.last_exit_code == 0) @as(i32, 1) else @as(i32, 0);
                return;
            }
        }

        // Check for function definition (name() { ... } or function name { ... })
        const fn_trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (try self.checkFunctionDefinitionStart(fn_trimmed)) {
            self.last_exit_code = 0;
            return;
        }

        // Check for arithmetic command: (( expression ))
        if (fn_trimmed.len > 4 and std.mem.startsWith(u8, fn_trimmed, "((") and std.mem.endsWith(u8, fn_trimmed, "))")) {
            const expr = std.mem.trim(u8, fn_trimmed[2 .. fn_trimmed.len - 2], &std.ascii.whitespace);
            if (expr.len > 0) {
                // Handle post-increment: (( x++ ))
                if (std.mem.endsWith(u8, expr, "++")) {
                    const var_name = std.mem.trim(u8, expr[0 .. expr.len - 2], &std.ascii.whitespace);
                    if (isValidVarName(var_name)) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num + 1}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle post-decrement: (( x-- ))
                else if (std.mem.endsWith(u8, expr, "--")) {
                    const var_name = std.mem.trim(u8, expr[0 .. expr.len - 2], &std.ascii.whitespace);
                    if (isValidVarName(var_name)) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num - 1}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle pre-increment: (( ++x ))
                if (std.mem.startsWith(u8, expr, "++")) {
                    const var_name = std.mem.trim(u8, expr[2..], &std.ascii.whitespace);
                    if (isValidVarName(var_name)) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        const new_num = num + 1;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{new_num}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (new_num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle pre-decrement: (( --x ))
                else if (std.mem.startsWith(u8, expr, "--")) {
                    const var_name = std.mem.trim(u8, expr[2..], &std.ascii.whitespace);
                    if (isValidVarName(var_name)) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        const new_num = num - 1;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{new_num}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (new_num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle compound assignment operators: (( x += expr )), (( x -= expr )), etc.
                const compound_ops = [_][]const u8{ "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=" };
                var handled_compound = false;
                inline for (compound_ops) |cop| {
                    if (!handled_compound) {
                        if (std.mem.indexOf(u8, expr, cop)) |op_idx| {
                            const var_name_c = std.mem.trim(u8, expr[0..op_idx], &std.ascii.whitespace);
                            const value_expr_c = std.mem.trim(u8, expr[op_idx + cop.len ..], &std.ascii.whitespace);
                            if (var_name_c.len > 0 and value_expr_c.len > 0) {
                                // Get current value
                                const current = shell_mod.getVariableValue(self, var_name_c) orelse "0";
                                const cur_val = std.fmt.parseInt(i64, current, 10) catch 0;
                                // Evaluate right side
                                var arith_c = @import("utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
                                arith_c.arrays = &self.arrays;
                                const rhs = arith_c.eval(value_expr_c) catch 0;
                                // Apply operator
                                const new_val_i: i64 = if (std.mem.eql(u8, cop, "+="))
                                    cur_val +| rhs
                                else if (std.mem.eql(u8, cop, "-="))
                                    cur_val -| rhs
                                else if (std.mem.eql(u8, cop, "*="))
                                    cur_val *| rhs
                                else if (std.mem.eql(u8, cop, "/="))
                                    if (rhs != 0) @divTrunc(cur_val, rhs) else 0
                                else if (std.mem.eql(u8, cop, "%="))
                                    if (rhs != 0) @rem(cur_val, rhs) else 0
                                else if (std.mem.eql(u8, cop, "&="))
                                    cur_val & rhs
                                else if (std.mem.eql(u8, cop, "|="))
                                    cur_val | rhs
                                else if (std.mem.eql(u8, cop, "^="))
                                    cur_val ^ rhs
                                else if (std.mem.eql(u8, cop, "<<="))
                                    std.math.shl(i64, cur_val, @as(u6, @intCast(@min(@max(rhs, 0), 63))))
                                else if (std.mem.eql(u8, cop, ">>="))
                                    std.math.shr(i64, cur_val, @as(u6, @intCast(@min(@max(rhs, 0), 63))))
                                else
                                    cur_val;
                                var buf_c: [32]u8 = undefined;
                                const val_str_c = std.fmt.bufPrint(&buf_c, "{d}", .{new_val_i}) catch "0";
                                shell_mod.setArithVariable(self, var_name_c, val_str_c);
                                self.last_exit_code = 0;
                                handled_compound = true;
                            }
                        }
                    }
                }
                if (handled_compound) return;

                // Handle assignment: (( x = expr ))
                if (std.mem.indexOf(u8, expr, "=")) |eq_idx| {
                    // Make sure it's not == or != or <= or >=
                    const is_comparison = (eq_idx > 0 and (expr[eq_idx - 1] == '!' or expr[eq_idx - 1] == '<' or expr[eq_idx - 1] == '>' or expr[eq_idx - 1] == '+' or expr[eq_idx - 1] == '-' or expr[eq_idx - 1] == '*' or expr[eq_idx - 1] == '/' or expr[eq_idx - 1] == '%' or expr[eq_idx - 1] == '&' or expr[eq_idx - 1] == '|' or expr[eq_idx - 1] == '^')) or
                        (eq_idx + 1 < expr.len and expr[eq_idx + 1] == '=');
                    if (!is_comparison) {
                        const var_name = std.mem.trim(u8, expr[0..eq_idx], &std.ascii.whitespace);
                        const value_expr = std.mem.trim(u8, expr[eq_idx + 1 ..], &std.ascii.whitespace);
                        // Evaluate the right side
                        var arith = @import("utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
                        arith.arrays = &self.arrays;
                        const result = arith.eval(value_expr) catch 0;
                        var buf: [32]u8 = undefined;
                        const val_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
                        shell_mod.setArithVariable(self, var_name, val_str);
                        self.last_exit_code = 0;
                        return;
                    }
                }
                // Non-assignment: evaluate and set exit code based on result
                var arith = @import("utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
                arith.arrays = &self.arrays;
                const result = arith.eval(expr) catch 0;
                self.last_exit_code = if (result != 0) @as(i32, 0) else @as(i32, 1);
                return;
            }
        }

        // Handle (( expr )) followed by && or || by evaluating and reconstructing
        if (fn_trimmed.len > 4 and std.mem.startsWith(u8, fn_trimmed, "((")) {
            // Find matching ))
            var depth: usize = 0;
            var close_pos: ?usize = null;
            var ci: usize = 0;
            while (ci < fn_trimmed.len) : (ci += 1) {
                if (ci + 1 < fn_trimmed.len and fn_trimmed[ci] == '(' and fn_trimmed[ci + 1] == '(') {
                    depth += 1;
                    ci += 1;
                } else if (ci + 1 < fn_trimmed.len and fn_trimmed[ci] == ')' and fn_trimmed[ci + 1] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        close_pos = ci + 2;
                        break;
                    }
                    ci += 1;
                }
            }
            if (close_pos) |cp| {
                const rest = std.mem.trim(u8, fn_trimmed[cp..], &std.ascii.whitespace);
                if (rest.len > 0 and (std.mem.startsWith(u8, rest, "&&") or std.mem.startsWith(u8, rest, "||") or rest[0] == ';')) {
                    // Execute (( expr )) first to set exit code
                    const arith_part = fn_trimmed[0..cp];
                    self.executeCommand(arith_part) catch {};
                    // Reconstruct: replace (( expr )) with true/false, pass rest through normal flow
                    const replacement: []const u8 = if (self.last_exit_code == 0) "true" else "false";
                    const new_cmd = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ replacement, rest });
                    defer self.allocator.free(new_cmd);
                    self.executeCommand(new_cmd) catch {};
                    return;
                }
            }
        }

        // Check for compound command group: { command; } [redirections]
        if (fn_trimmed.len > 2 and fn_trimmed[0] == '{' and
            (fn_trimmed[1] == ' ' or fn_trimmed[1] == '\t' or fn_trimmed[1] == '\n'))
        {
            // Find matching } considering nesting and quotes
            var bg_depth: i32 = 1;
            var bg_sq = false;
            var bg_dq = false;
            var bg_close: ?usize = null;
            var bg_i: usize = 1;
            while (bg_i < fn_trimmed.len) {
                const ch = fn_trimmed[bg_i];
                if (ch == '\\' and bg_i + 1 < fn_trimmed.len and !bg_sq) {
                    bg_i += 2;
                    continue;
                }
                if (!bg_dq and ch == '\'') {
                    bg_sq = !bg_sq;
                } else if (!bg_sq and ch == '"') {
                    bg_dq = !bg_dq;
                } else if (!bg_sq and !bg_dq) {
                    if (ch == '{') bg_depth += 1;
                    if (ch == '}') {
                        bg_depth -= 1;
                        if (bg_depth == 0) {
                            bg_close = bg_i;
                            break;
                        }
                    }
                }
                bg_i += 1;
            }

            if (bg_close) |close_pos| {
                const inner = std.mem.trim(u8, fn_trimmed[1..close_pos], &std.ascii.whitespace);
                const after_brace = std.mem.trim(u8, fn_trimmed[close_pos + 1 ..], &std.ascii.whitespace);

                if (inner.len > 0) {
                    // Check for pipe after }
                    if (after_brace.len > 0 and after_brace[0] == '|') {
                        const pipe_cmd = std.mem.trim(u8, after_brace[1..], &std.ascii.whitespace);
                        if (pipe_cmd.len > 0) {
                            if (comptime builtin.os.tag != .windows) {
                                // Fork with pipe: brace group stdout → pipe command stdin
                                var pipe_fds: [2]std.posix.fd_t = undefined;
                                if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
                                const read_fd = pipe_fds[0];
                                const write_fd = pipe_fds[1];

                                const fork_ret = std.c.fork();
                                if (fork_ret < 0) {
                                    _ = std.c.close(read_fd);
                                    _ = std.c.close(write_fd);
                                    return error.Unexpected;
                                }
                                if (fork_ret == 0) {
                                    _ = std.c.close(read_fd);
                                    _ = std.c.dup2(write_fd, std.posix.STDOUT_FILENO);
                                    _ = std.c.close(write_fd);
                                    self.executeCommand(inner) catch {
                                        std.c._exit(1);
                                    };
                                    std.c._exit(@as(u8, @intCast(@as(u32, @bitCast(self.last_exit_code)) & 0xff)));
                                    unreachable;
                                }
                                _ = std.c.close(write_fd);
                                const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
                                _ = std.c.dup2(read_fd, std.posix.STDIN_FILENO);
                                _ = std.c.close(read_fd);

                                var wait_status_bg: c_int = 0;
                                _ = process_util.waitpidIntr(@intCast(fork_ret), &wait_status_bg, 0);

                                const execFn2: *const fn (*Shell, []const u8) anyerror!void = &Shell.executeCommand;
                                execFn2(self, pipe_cmd) catch {};

                                if (saved_stdin >= 0) {
                                    _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
                                    _ = std.c.close(saved_stdin);
                                }
                            } else {
                                self.executeCommand(inner) catch {};
                                self.executeCommand(pipe_cmd) catch {};
                            }
                            return;
                        }
                    }

                    // Check for redirections after }
                    if (after_brace.len > 0 and (after_brace[0] == '>' or after_brace[0] == '<' or
                        (after_brace.len > 1 and after_brace[0] >= '0' and after_brace[0] <= '9' and
                            (after_brace[1] == '>' or after_brace[1] == '<')) or
                        (after_brace.len > 2 and after_brace[0] >= '0' and after_brace[0] <= '9' and
                            after_brace[1] == '>' and after_brace[2] == '&')))
                    {
                        if (comptime builtin.os.tag != .windows) {
                            // Parse and apply redirections
                            var saved_fds: [3]c_int = .{ -1, -1, -1 }; // stdin, stdout, stderr
                            var redir_ok = true;
                            var redir_str = after_brace;

                            while (redir_str.len > 0 and redir_ok) {
                                redir_str = std.mem.trimStart(u8, redir_str, &std.ascii.whitespace);
                                if (redir_str.len == 0) break;

                                var src_fd: std.posix.fd_t = -1;
                                var mode: enum { write, append, read, dup_out, dup_in } = .write;

                                // Parse optional fd number
                                if (redir_str.len > 1 and redir_str[0] >= '0' and redir_str[0] <= '9') {
                                    src_fd = @as(std.posix.fd_t, @intCast(redir_str[0] - '0'));
                                    redir_str = redir_str[1..];
                                }

                                if (redir_str.len == 0) break;

                                if (redir_str[0] == '>') {
                                    if (src_fd == -1) src_fd = std.posix.STDOUT_FILENO;
                                    redir_str = redir_str[1..];
                                    if (redir_str.len > 0 and redir_str[0] == '>') {
                                        mode = .append;
                                        redir_str = redir_str[1..];
                                    } else if (redir_str.len > 0 and redir_str[0] == '&') {
                                        mode = .dup_out;
                                        redir_str = redir_str[1..];
                                    }
                                } else if (redir_str[0] == '<') {
                                    if (src_fd == -1) src_fd = std.posix.STDIN_FILENO;
                                    mode = .read;
                                    redir_str = redir_str[1..];
                                } else {
                                    break;
                                }

                                redir_str = std.mem.trimStart(u8, redir_str, &std.ascii.whitespace);
                                // Get the target (filename or fd number)
                                var target_end: usize = 0;
                                while (target_end < redir_str.len and
                                    redir_str[target_end] != ' ' and redir_str[target_end] != '\t' and
                                    redir_str[target_end] != '>' and redir_str[target_end] != '<') : (target_end += 1)
                                {}
                                if (target_end == 0) {
                                    redir_ok = false;
                                    break;
                                }
                                const target = redir_str[0..target_end];
                                redir_str = redir_str[target_end..];

                                // Save original fd. Guard against negative fds
                                // (@intCast would wrap to MAX_USIZE) and against
                                // dup() failures which return -1 — storing -1
                                // here would cause dup2(-1, fd) later during
                                // restoration.
                                if (src_fd >= 0) {
                                    const ufd: usize = @intCast(src_fd);
                                    if (ufd < saved_fds.len and saved_fds[ufd] == -1) {
                                        const dup_fd = std.c.dup(src_fd);
                                        if (dup_fd >= 0) saved_fds[ufd] = dup_fd;
                                    }
                                }

                                switch (mode) {
                                    .dup_out, .dup_in => {
                                        // >&N or <&N
                                        if (std.mem.eql(u8, target, "-")) {
                                            _ = std.c.close(src_fd);
                                        } else if (std.fmt.parseInt(std.posix.fd_t, target, 10)) |dest_fd| {
                                            _ = std.c.dup2(dest_fd, src_fd);
                                        } else |_| {
                                            redir_ok = false;
                                        }
                                    },
                                    .write, .append => {
                                        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                                        if (target.len >= path_buf.len) {
                                            redir_ok = false;
                                            break;
                                        }
                                        @memcpy(path_buf[0..target.len], target);
                                        path_buf[target.len] = 0;
                                        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

                                        const flags: std.c.O = if (mode == .append)
                                            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
                                        else
                                            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
                                        const fd = std.c.open(path_z, flags, @as(std.c.mode_t, 0o644));
                                        if (fd >= 0) {
                                            _ = std.c.dup2(fd, src_fd);
                                            // fd is already c_int — std.c.close accepts c_int directly.
                                            _ = std.c.close(fd);
                                        } else {
                                            redir_ok = false;
                                        }
                                    },
                                    .read => {
                                        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                                        if (target.len >= path_buf.len) {
                                            redir_ok = false;
                                            break;
                                        }
                                        @memcpy(path_buf[0..target.len], target);
                                        path_buf[target.len] = 0;
                                        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

                                        const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
                                        if (fd >= 0) {
                                            _ = std.c.dup2(fd, src_fd);
                                            _ = std.c.close(fd);
                                        } else {
                                            redir_ok = false;
                                        }
                                    },
                                }
                            }

                            // Execute the group body with redirections applied
                            self.executeCommand(inner) catch |err| {
                                if (err == error.Exit) {
                                    // Restore fds before propagating
                                    for (saved_fds, 0..) |sfd, fi| {
                                        if (sfd != -1) {
                                            _ = std.c.dup2(sfd, @intCast(fi));
                                            _ = std.c.close(sfd);
                                        }
                                    }
                                    return err;
                                }
                            };

                            // Restore saved fds
                            for (saved_fds, 0..) |sfd, fi| {
                                if (sfd != -1) {
                                    _ = std.c.dup2(sfd, @intCast(fi));
                                    _ = std.c.close(sfd);
                                }
                            }
                            return;
                        }
                    }

                    // No redirections — execute in current shell context
                    self.executeCommand(inner) catch |err| {
                        if (err == error.Exit) return err;
                    };
                    return;
                }
            }
        }

        // Check for subshell: (command) or (command) | pipeline
        if (fn_trimmed.len > 2 and fn_trimmed[0] == '(') {
            // Find the matching closing paren
            var paren_depth: i32 = 0;
            var in_sq = false;
            var in_dq = false;
            var close_pos: ?usize = null;
            for (fn_trimmed, 0..) |ch, ci| {
                if (ch == '\\' and ci + 1 < fn_trimmed.len) continue;
                if (!in_dq and ch == '\'') {
                    in_sq = !in_sq;
                    continue;
                }
                if (!in_sq and ch == '"') {
                    in_dq = !in_dq;
                    continue;
                }
                if (in_sq or in_dq) continue;
                if (ch == '(') paren_depth += 1;
                if (ch == ')') {
                    paren_depth -= 1;
                    if (paren_depth == 0) {
                        close_pos = ci;
                        break;
                    }
                }
            }

            if (close_pos) |cp| {
                const inner = std.mem.trim(u8, fn_trimmed[1..cp], &std.ascii.whitespace);
                // Check for pipe suffix after the closing paren
                const after_paren = std.mem.trim(u8, fn_trimmed[cp + 1 ..], &std.ascii.whitespace);
                const subshell_pipe_cmd = if (after_paren.len > 0 and after_paren[0] == '|')
                    std.mem.trim(u8, after_paren[1..], &std.ascii.whitespace)
                else
                    null;

                if (inner.len > 0) {
                    if (comptime builtin.os.tag == .windows) {
                        // Windows: no fork, execute in current process (limited isolation)
                        self.executeCommand(inner) catch {
                            self.last_exit_code = 1;
                        };
                        if (subshell_pipe_cmd) |pipe_cmd| {
                            self.executeCommand(pipe_cmd) catch {};
                        }
                    } else {
                        if (subshell_pipe_cmd) |pipe_cmd| {
                            // Subshell piped to another command: fork with stdout redirect
                            var pipe_fds: [2]std.posix.fd_t = undefined;
                            if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
                            const read_fd = pipe_fds[0];
                            const write_fd = pipe_fds[1];

                            const fork_ret = std.c.fork();
                            if (fork_ret < 0) {
                                _ = std.c.close(read_fd);
                                _ = std.c.close(write_fd);
                                return error.Unexpected;
                            }
                            if (fork_ret == 0) {
                                // Child: redirect stdout to pipe, execute subshell
                                _ = std.c.close(read_fd);
                                _ = std.c.dup2(write_fd, std.posix.STDOUT_FILENO);
                                _ = std.c.close(write_fd);
                                self.executeCommand(inner) catch {
                                    std.c._exit(1);
                                };
                                std.c._exit(@as(u8, @intCast(@as(u32, @bitCast(self.last_exit_code)) & 0xff)));
                                unreachable;
                            }
                            // Parent: pipe child stdout to the pipe command
                            _ = std.c.close(write_fd);
                            const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
                            _ = std.c.dup2(read_fd, std.posix.STDIN_FILENO);
                            _ = std.c.close(read_fd);

                            var wait_status_sub: c_int = 0;
                            _ = process_util.waitpidIntr(@intCast(fork_ret), &wait_status_sub, 0);

                            const execFn: *const fn (*Shell, []const u8) anyerror!void = &Shell.executeCommand;
                            execFn(self, pipe_cmd) catch {};

                            if (saved_stdin >= 0) {
                                _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
                                _ = std.c.close(saved_stdin);
                            }
                        } else {
                            const fork_ret = std.c.fork();
                            if (fork_ret < 0) {
                                try IO.eprint("den: fork failed\n", .{});
                                self.last_exit_code = 1;
                                return;
                            }
                            if (fork_ret == 0) {
                                // Child: execute command and exit
                                self.executeCommand(inner) catch {
                                    std.c._exit(1);
                                };
                                std.c._exit(@as(u8, @intCast(@as(u32, @bitCast(self.last_exit_code)) & 0xff)));
                                unreachable;
                            }
                            // Parent: wait for child (retry on EINTR)
                            var wait_status: c_int = 0;
                            _ = process_util.waitpidIntr(@intCast(fork_ret), &wait_status, 0);
                            if (wait_status & 0x7f == 0) {
                                self.last_exit_code = @as(i32, @intCast((wait_status >> 8) & 0xff));
                            } else {
                                self.last_exit_code = 128 + @as(i32, @intCast(wait_status & 0x7f));
                            }
                        }
                    }
                    return;
                }
            }
        }

        // Check for local name=(values...) - handle before tokenizer since ( would be treated as subshell
        if (std.mem.startsWith(u8, fn_trimmed, "local ")) {
            if (std.mem.indexOf(u8, fn_trimmed, "=(") != null) {
                if (std.mem.lastIndexOfScalar(u8, fn_trimmed, ')') != null) {
                    // Skip "local " and any flags
                    var lpos: usize = 6;
                    while (lpos < fn_trimmed.len and fn_trimmed[lpos] == ' ') lpos += 1;
                    while (lpos < fn_trimmed.len and fn_trimmed[lpos] == '-') {
                        lpos += 1;
                        while (lpos < fn_trimmed.len and fn_trimmed[lpos] != ' ') lpos += 1;
                        while (lpos < fn_trimmed.len and fn_trimmed[lpos] == ' ') lpos += 1;
                    }
                    const assignment = fn_trimmed[lpos..];
                    try shell_mod.executeArrayAssignment(self, assignment);
                    return;
                }
            }
        }

        // Check for declare/typeset with inline array: declare -a name=(values...)
        // Must be handled before tokenizer since ( would be treated as subshell
        if (std.mem.startsWith(u8, fn_trimmed, "declare ") or std.mem.startsWith(u8, fn_trimmed, "typeset ")) {
            if (std.mem.indexOf(u8, fn_trimmed, "=(") != null) {
                if (std.mem.lastIndexOfScalar(u8, fn_trimmed, ')') != null) {
                    // Parse flags
                    const cmd_len: usize = if (std.mem.startsWith(u8, fn_trimmed, "declare ")) 8 else 8;
                    var fpos: usize = cmd_len;
                    var has_a_flag = false;
                    var has_big_a_flag = false;
                    // Skip flags (words starting with -)
                    while (fpos < fn_trimmed.len) {
                        while (fpos < fn_trimmed.len and fn_trimmed[fpos] == ' ') fpos += 1;
                        if (fpos >= fn_trimmed.len or fn_trimmed[fpos] != '-') break;
                        fpos += 1; // skip -
                        while (fpos < fn_trimmed.len and fn_trimmed[fpos] != ' ') {
                            if (fn_trimmed[fpos] == 'a') has_a_flag = true;
                            if (fn_trimmed[fpos] == 'A') has_big_a_flag = true;
                            fpos += 1;
                        }
                    }
                    while (fpos < fn_trimmed.len and fn_trimmed[fpos] == ' ') fpos += 1;

                    if (has_a_flag) {
                        // Extract name=(values...) and execute as array assignment
                        const assignment = fn_trimmed[fpos..];
                        try shell_mod.executeArrayAssignment(self, assignment);
                        // Set indexed_array attribute
                        if (std.mem.indexOfScalar(u8, assignment, '=')) |eq| {
                            const vname = assignment[0..eq];
                            const var_builtins = @import("shell/variable_builtins.zig");
                            try var_builtins.setVarAttributes(self, vname, types.VarAttributes{ .indexed_array = true }, false);
                        }
                        return;
                    }
                    if (has_big_a_flag) {
                        // Handle declare -A name=([key1]=val1 [key2]=val2 ...)
                        const assignment = fn_trimmed[fpos..];
                        try shell_mod.executeAssocArrayAssignment(self, assignment);
                        if (std.mem.indexOfScalar(u8, assignment, '=')) |eq| {
                            const vname = assignment[0..eq];
                            const var_builtins = @import("shell/variable_builtins.zig");
                            try var_builtins.setVarAttributes(self, vname, types.VarAttributes{ .assoc_array = true }, false);
                        }
                        return;
                    }
                }
            }
        }

        // Check for array assignment first: name=(...)
        if (shell_mod.isArrayAssignment(input)) {
            try shell_mod.executeArrayAssignment(self, input);
            return;
        }

        // Check for associative array element assignment: name[key]=value (for declared -A arrays)
        if (shell_mod.isAssocArrayElementAssignment(self, input)) {
            try shell_mod.executeAssocArrayElementAssignment(self, input);
            return;
        }

        // Check for array element assignment: name[index]=value
        if (shell_mod.isArrayElementAssignment(input)) {
            try shell_mod.executeArrayElementAssignment(self, input);
            return;
        }

        // Check for simple variable assignment: VAR=value or VAR+=value (no spaces before =)
        // This handles both regular assignments and nameref assignments
        const trimmed_input = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, trimmed_input, "=")) |eq_pos| {
            // Check for += append operator
            const is_append = eq_pos > 0 and trimmed_input[eq_pos - 1] == '+';
            const var_end = if (is_append) eq_pos - 1 else eq_pos;
            // Check if this is a simple assignment (no spaces before =, valid var name)
            const potential_var = trimmed_input[0..var_end];
            // Verify it's a valid variable name (no spaces, starts with letter or underscore)
            if (potential_var.len > 0 and
                std.mem.indexOfScalar(u8, potential_var, ' ') == null and
                (std.ascii.isAlphabetic(potential_var[0]) or potential_var[0] == '_'))
            {
                var is_valid_var = true;
                for (potential_var) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_') {
                        is_valid_var = false;
                        break;
                    }
                }
                // Also verify there's no additional command after the assignment
                // e.g., "VAR=value cmd" should not be handled here
                if (is_valid_var and eq_pos + 1 <= trimmed_input.len) {
                    const rest = trimmed_input[eq_pos + 1 ..];
                    // Check if there are any spaces after the value that indicate more commands
                    // Handle quoted strings, $() nesting, and ${} nesting
                    var in_single_quote = false;
                    var in_double_quote = false;
                    var subst_depth_check: u32 = 0;
                    var brace_depth_check: u32 = 0;
                    var found_space_outside_quotes = false;
                    var prev_c: u8 = 0;
                    for (rest) |c| {
                        if (c == '\'' and !in_double_quote and subst_depth_check == 0) {
                            in_single_quote = !in_single_quote;
                        } else if (c == '"' and !in_single_quote and subst_depth_check == 0) {
                            in_double_quote = !in_double_quote;
                        } else if (c == '(' and prev_c == '$' and !in_single_quote) {
                            subst_depth_check += 1;
                        } else if (c == '(' and subst_depth_check > 0) {
                            // Nested paren inside an active $(...)/$((...)) span, e.g.
                            // the inner '(' of $(( (1+2)*3 )) — keep it balanced so
                            // spaces inside the substitution don't split the word.
                            subst_depth_check += 1;
                        } else if (c == '{' and prev_c == '$' and !in_single_quote) {
                            brace_depth_check += 1;
                        } else if (c == ')' and subst_depth_check > 0) {
                            subst_depth_check -= 1;
                        } else if (c == '}' and brace_depth_check > 0) {
                            brace_depth_check -= 1;
                        } else if (c == ' ' and !in_single_quote and !in_double_quote and subst_depth_check == 0 and brace_depth_check == 0) {
                            found_space_outside_quotes = true;
                            break;
                        }
                        prev_c = c;
                    }
                    if (found_space_outside_quotes) {
                        // Check if ALL quote-aware tokens are assignments (a=1 b=2 c=3)
                        // Use quote-aware scanning so that e.g. y="$x world" is one token
                        var all_assignments = true;
                        var qa_check_pos: usize = 0;
                        while (qa_check_pos < trimmed_input.len) {
                            // Skip whitespace
                            while (qa_check_pos < trimmed_input.len and trimmed_input[qa_check_pos] == ' ') qa_check_pos += 1;
                            if (qa_check_pos >= trimmed_input.len) break;
                            // Find end of this token (respecting quotes)
                            const qa_tok_start = qa_check_pos;
                            var qa_sq = false;
                            var qa_dq = false;
                            while (qa_check_pos < trimmed_input.len) : (qa_check_pos += 1) {
                                const qc = trimmed_input[qa_check_pos];
                                if (qc == '\'' and !qa_dq) {
                                    qa_sq = !qa_sq;
                                } else if (qc == '"' and !qa_sq) {
                                    qa_dq = !qa_dq;
                                } else if (qc == ' ' and !qa_sq and !qa_dq) {
                                    break;
                                }
                            }
                            const qa_tok = trimmed_input[qa_tok_start..qa_check_pos];
                            // Check if this token is a valid assignment (name=...)
                            var qa_found_eq = false;
                            var qa_valid_name = true;
                            for (qa_tok, 0..) |tc, ti| {
                                if (tc == '=') {
                                    qa_found_eq = ti > 0;
                                    break;
                                }
                                if (!std.ascii.isAlphanumeric(tc) and tc != '_') {
                                    qa_valid_name = false;
                                    break;
                                }
                            }
                            if (!qa_found_eq or !qa_valid_name) {
                                all_assignments = false;
                                break;
                            }
                        }
                        if (all_assignments) {
                            // Execute each assignment left-to-right using quote-aware tokenization.
                            // Using executeCommand for each handles variable expansion ($) properly.
                            var qa_exec_pos: usize = 0;
                            while (qa_exec_pos < trimmed_input.len) {
                                while (qa_exec_pos < trimmed_input.len and trimmed_input[qa_exec_pos] == ' ') qa_exec_pos += 1;
                                if (qa_exec_pos >= trimmed_input.len) break;
                                const qa_etok_start = qa_exec_pos;
                                var qa_esq = false;
                                var qa_edq = false;
                                while (qa_exec_pos < trimmed_input.len) : (qa_exec_pos += 1) {
                                    const ec = trimmed_input[qa_exec_pos];
                                    if (ec == '\'' and !qa_edq) {
                                        qa_esq = !qa_esq;
                                    } else if (ec == '"' and !qa_esq) {
                                        qa_edq = !qa_edq;
                                    } else if (ec == ' ' and !qa_esq and !qa_edq) {
                                        break;
                                    }
                                }
                                const qa_etok = trimmed_input[qa_etok_start..qa_exec_pos];
                                self.executeCommand(qa_etok) catch |err| {
                                    if (err == error.Exit) return err;
                                };
                            }
                            self.last_exit_code = 0;
                            return;
                        }
                        // Check for per-command temporary variable assignment: VAR=val cmd args
                        // The first token(s) are assignments but there's a non-assignment command after
                        if (!all_assignments) {
                            // Collect leading assignments and find the command
                            var prefix_assignments: [32]struct { name: []const u8, value: []const u8 } = undefined;
                            var prefix_count: usize = 0;
                            var cmd_start_offset: usize = 0;
                            // Set when the token after the leading assignment(s) is a
                            // control operator (&&, ||, |, &). That means the assignment
                            // is a standalone command in a chain/pipeline (e.g.
                            // `V=x && cmd`), not a prefix to a temporary-assignment
                            // command — so we defer the whole input to the normal
                            // parser/executor instead of treating the operator as a command.
                            var chain_after_assignment = false;

                            // Walk through quote-aware tokens to find assignments vs command
                            var scan_pos: usize = 0;
                            while (scan_pos < trimmed_input.len) {
                                // Skip leading whitespace
                                while (scan_pos < trimmed_input.len and trimmed_input[scan_pos] == ' ') scan_pos += 1;
                                if (scan_pos >= trimmed_input.len) break;

                                // Find end of this token (respecting quotes)
                                const tok_start = scan_pos;
                                var sq = false;
                                var dq = false;
                                while (scan_pos < trimmed_input.len) : (scan_pos += 1) {
                                    const sc = trimmed_input[scan_pos];
                                    if (sc == '\'' and !dq) {
                                        sq = !sq;
                                    } else if (sc == '"' and !sq) {
                                        dq = !dq;
                                    } else if (sc == ' ' and !sq and !dq) {
                                        break;
                                    }
                                }
                                const tok = trimmed_input[tok_start..scan_pos];

                                // Check if this token is an assignment
                                var is_assignment = false;
                                if (std.mem.indexOfScalar(u8, tok, '=')) |teq| {
                                    if (teq > 0) {
                                        const tname = tok[0..teq];
                                        var tvalid = tname[0] == '_' or std.ascii.isAlphabetic(tname[0]);
                                        if (tvalid) {
                                            for (tname[1..]) |tc| {
                                                if (!std.ascii.isAlphanumeric(tc) and tc != '_') {
                                                    tvalid = false;
                                                    break;
                                                }
                                            }
                                        }
                                        if (tvalid and prefix_count < prefix_assignments.len) {
                                            is_assignment = true;
                                            const tval_raw = tok[teq + 1 ..];
                                            // Strip surrounding quotes from value
                                            const tval = if (tval_raw.len >= 2 and
                                                ((tval_raw[0] == '"' and tval_raw[tval_raw.len - 1] == '"') or
                                                    (tval_raw[0] == '\'' and tval_raw[tval_raw.len - 1] == '\'')))
                                                tval_raw[1 .. tval_raw.len - 1]
                                            else
                                                tval_raw;
                                            prefix_assignments[prefix_count] = .{ .name = tname, .value = tval };
                                            prefix_count += 1;
                                        }
                                    }
                                }
                                if (!is_assignment) {
                                    // A control operator as the "command" means this is
                                    // `assignment <op> ...` — let the real parser handle
                                    // the chain (it runs the bare assignment as its own
                                    // command segment, then applies the operator).
                                    if (tok.len > 0 and (tok[0] == '&' or tok[0] == '|')) {
                                        chain_after_assignment = true;
                                    }
                                    cmd_start_offset = tok_start;
                                    break;
                                }
                            }

                            if (!chain_after_assignment and prefix_count > 0 and cmd_start_offset > 0) {
                                const cmd_rest = trimmed_input[cmd_start_offset..];

                                // Save old values (must dupe since setArithVariable frees them)
                                var saved_values: [32]?[]const u8 = undefined;
                                for (prefix_assignments[0..prefix_count], 0..) |a, ai| {
                                    if (shell_mod.getVariableValue(self, a.name)) |val| {
                                        saved_values[ai] = self.allocator.dupe(u8, val) catch null;
                                    } else {
                                        saved_values[ai] = null;
                                    }
                                }
                                defer {
                                    for (0..prefix_count) |di| {
                                        if (saved_values[di]) |sv| self.allocator.free(@constCast(sv));
                                    }
                                }

                                // Set temporary values (in both shell env and C env)
                                for (prefix_assignments[0..prefix_count]) |a| {
                                    shell_mod.setArithVariable(self, a.name, a.value);
                                    if (comptime @import("builtin").os.tag != .windows) {
                                        if (a.name.len < 512 and a.value.len < 4096) {
                                            var nbuf: [512]u8 = undefined;
                                            var vbuf: [4096]u8 = undefined;
                                            @memcpy(nbuf[0..a.name.len], a.name);
                                            nbuf[a.name.len] = 0;
                                            @memcpy(vbuf[0..a.value.len], a.value);
                                            vbuf[a.value.len] = 0;
                                            const c_env = @import("executor/mod.zig").libc_env;
                                            _ = c_env.setenv(nbuf[0..a.name.len :0], vbuf[0..a.value.len :0], 1);
                                        }
                                    }
                                }

                                // Execute the command
                                self.executeCommand(cmd_rest) catch |err| {
                                    // Restore old values before propagating error
                                    for (prefix_assignments[0..prefix_count], 0..) |a, ai| {
                                        if (saved_values[ai]) |old_val| {
                                            shell_mod.setArithVariable(self, a.name, old_val);
                                        } else {
                                            // Variable didn't exist before - remove it
                                            if (self.environment.fetchRemove(a.name)) |old| {
                                                self.allocator.free(old.key);
                                                self.allocator.free(old.value);
                                            }
                                        }
                                        if (comptime @import("builtin").os.tag != .windows) {
                                            if (a.name.len < 512) {
                                                var nbuf2: [512]u8 = undefined;
                                                @memcpy(nbuf2[0..a.name.len], a.name);
                                                nbuf2[a.name.len] = 0;
                                                const c_env2 = @import("executor/mod.zig").libc_env;
                                                if (saved_values[ai]) |old_val| {
                                                    if (old_val.len < 4096) {
                                                        var vbuf2: [4096]u8 = undefined;
                                                        @memcpy(vbuf2[0..old_val.len], old_val);
                                                        vbuf2[old_val.len] = 0;
                                                        _ = c_env2.setenv(nbuf2[0..a.name.len :0], vbuf2[0..old_val.len :0], 1);
                                                    }
                                                } else {
                                                    _ = c_env2.unsetenv(nbuf2[0..a.name.len :0]);
                                                }
                                            }
                                        }
                                    }
                                    if (err == error.Exit) return err;
                                    return;
                                };

                                // Restore old values
                                for (prefix_assignments[0..prefix_count], 0..) |a, ai| {
                                    if (saved_values[ai]) |old_val| {
                                        shell_mod.setArithVariable(self, a.name, old_val);
                                    } else {
                                        if (self.environment.fetchRemove(a.name)) |old| {
                                            self.allocator.free(old.key);
                                            self.allocator.free(old.value);
                                        }
                                    }
                                    if (comptime @import("builtin").os.tag != .windows) {
                                        if (a.name.len < 512) {
                                            var nbuf3: [512]u8 = undefined;
                                            @memcpy(nbuf3[0..a.name.len], a.name);
                                            nbuf3[a.name.len] = 0;
                                            const c_env3 = @import("executor/mod.zig").libc_env;
                                            if (saved_values[ai]) |old_val| {
                                                if (old_val.len < 4096) {
                                                    var vbuf3: [4096]u8 = undefined;
                                                    @memcpy(vbuf3[0..old_val.len], old_val);
                                                    vbuf3[old_val.len] = 0;
                                                    _ = c_env3.setenv(nbuf3[0..a.name.len :0], vbuf3[0..old_val.len :0], 1);
                                                }
                                            } else {
                                                _ = c_env3.unsetenv(nbuf3[0..a.name.len :0]);
                                            }
                                        }
                                    }
                                }
                                return;
                            }
                        }
                    }
                    if (!found_space_outside_quotes) {
                        const raw_value = trimmed_input[eq_pos + 1 ..];

                        // Fast-path: `name=$((EXPR))` arithmetic assignment, the hot
                        // loop-counter idiom. Only when EXPR is "simple" — no command
                        // substitution `$(`, parameter expansion `${`, backtick, or
                        // array subscript `[` — so direct evaluation is provably
                        // equivalent to the full $((...)) expansion (which only differs
                        // for those pre-expanded forms). Plain `=` only (not `+=`).
                        if (!is_append and raw_value.len > 4 and
                            std.mem.startsWith(u8, raw_value, "$((") and
                            std.mem.endsWith(u8, raw_value, "))"))
                        {
                            const inner = raw_value[3 .. raw_value.len - 2];
                            var simple = true;
                            for (inner, 0..) |ch, ii| {
                                if (ch == '`' or ch == '[' or ch == '{') {
                                    simple = false;
                                    break;
                                }
                                // A `$` must introduce a bare variable name ($name),
                                // not $(, ${, or $<digit> (positional) — those need
                                // the full expander's pre-passes.
                                if (ch == '$') {
                                    if (ii + 1 >= inner.len or
                                        !(std.ascii.isAlphabetic(inner[ii + 1]) or inner[ii + 1] == '_'))
                                    {
                                        simple = false;
                                        break;
                                    }
                                }
                            }
                            if (simple) {
                                if (self.option_restricted and
                                    (std.mem.eql(u8, potential_var, "PATH") or
                                        std.mem.eql(u8, potential_var, "SHELL") or
                                        std.mem.eql(u8, potential_var, "ENV") or
                                        std.mem.eql(u8, potential_var, "BASH_ENV")))
                                {
                                    try IO.eprint("den: {s}: restricted: cannot modify in restricted mode\n", .{potential_var});
                                    self.last_exit_code = 1;
                                    return;
                                }
                                if (self.var_attributes.get(potential_var)) |attrs| {
                                    if (attrs.readonly) {
                                        try IO.eprint("den: {s}: readonly variable\n", .{potential_var});
                                        self.last_exit_code = 1;
                                        return;
                                    }
                                    if (attrs.immutable) {
                                        try IO.eprint("den: {s}: immutable variable (declared with let)\n", .{potential_var});
                                        self.last_exit_code = 1;
                                        return;
                                    }
                                }
                                const arith_mod = @import("utils/arithmetic.zig");
                                var arith = arith_mod.Arithmetic.initWithVariables(self.allocator, &self.environment);
                                if (self.function_manager.currentFrame()) |frame| arith.local_vars = &frame.local_vars;
                                arith.arrays = &self.arrays;
                                const result = arith.eval(inner) catch 0;
                                var abuf: [32]u8 = undefined;
                                const result_str = std.fmt.bufPrint(&abuf, "{d}", .{result}) catch "0";
                                shell_mod.setArithVariable(self, potential_var, result_str);
                                self.last_exit_code = 0;
                                return;
                            }
                        }

                        // If value contains expansion characters ($, `), let the full
                        // pipeline handle it so command substitution works correctly.
                        // But not if the entire value is single-quoted — single quotes
                        // prevent all expansion, so $ and ` are literal.
                        var needs_full_pipeline = false;
                        const entirely_single_quoted = raw_value.len >= 2 and
                            raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'';
                        if (!entirely_single_quoted) {
                            for (raw_value) |ch| {
                                if (ch == '$' or ch == '`') {
                                    needs_full_pipeline = true;
                                    break;
                                }
                            }
                        }
                        if (!needs_full_pipeline) {
                            // Restricted mode: block modifications to PATH, SHELL, ENV, BASH_ENV
                            if (self.option_restricted) {
                                if (std.mem.eql(u8, potential_var, "PATH") or
                                    std.mem.eql(u8, potential_var, "SHELL") or
                                    std.mem.eql(u8, potential_var, "ENV") or
                                    std.mem.eql(u8, potential_var, "BASH_ENV"))
                                {
                                    try IO.eprint("den: {s}: restricted: cannot modify in restricted mode\n", .{potential_var});
                                    self.last_exit_code = 1;
                                    return;
                                }
                            }
                            // Check if readonly or immutable before assignment
                            if (self.var_attributes.get(potential_var)) |attrs| {
                                if (attrs.readonly) {
                                    try IO.eprint("den: {s}: readonly variable\n", .{potential_var});
                                    self.last_exit_code = 1;
                                    return;
                                }
                                if (attrs.immutable) {
                                    try IO.eprint("den: {s}: immutable variable (declared with let)\n", .{potential_var});
                                    self.last_exit_code = 1;
                                    return;
                                }
                            }
                            // Simple literal assignment - strip surrounding quotes
                            const was_double_quoted = raw_value.len >= 2 and
                                raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"';
                            const was_single_quoted = raw_value.len >= 2 and
                                raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'';
                            const was_quoted = was_double_quoted or was_single_quoted;
                            const stripped = if (was_quoted)
                                raw_value[1 .. raw_value.len - 1]
                            else
                                raw_value;
                            // In double quotes, process backslash escape sequences:
                            // \\ -> \, \" -> ", \$ -> $, \` -> `, \newline -> (removed)
                            // Other \X sequences preserve the backslash literally.
                            var dq_escape_buf: [4096]u8 = undefined;
                            const stripped_final = if (was_double_quoted) blk: {
                                var oi: usize = 0;
                                var si: usize = 0;
                                while (si < stripped.len) : (si += 1) {
                                    if (stripped[si] == '\\' and si + 1 < stripped.len) {
                                        const nc = stripped[si + 1];
                                        if (nc == '\\' or nc == '"' or nc == '$' or nc == '`') {
                                            if (oi < dq_escape_buf.len) {
                                                dq_escape_buf[oi] = nc;
                                                oi += 1;
                                            }
                                            si += 1; // skip the next char (consumed)
                                        } else if (nc == '\n') {
                                            si += 1; // skip both backslash and newline
                                        } else {
                                            // Preserve the backslash literally
                                            if (oi + 1 < dq_escape_buf.len) {
                                                dq_escape_buf[oi] = '\\';
                                                oi += 1;
                                                dq_escape_buf[oi] = nc;
                                                oi += 1;
                                            }
                                            si += 1;
                                        }
                                    } else {
                                        if (oi < dq_escape_buf.len) {
                                            dq_escape_buf[oi] = stripped[si];
                                            oi += 1;
                                        }
                                    }
                                }
                                break :blk dq_escape_buf[0..oi];
                            } else stripped;
                            // Tilde expansion for unquoted values (bash: x=~ sets x to home dir)
                            var tilde_buf: [4096]u8 = undefined;
                            const value_to_use = if (!was_quoted and stripped_final.len > 0 and stripped_final[0] == '~') blk: {
                                const home = self.environment.get("HOME") orelse break :blk stripped_final;
                                // ~ alone or ~/path
                                if (stripped_final.len == 1) {
                                    break :blk home;
                                } else if (stripped_final[1] == '/') {
                                    const total = home.len + stripped_final.len - 1;
                                    if (total <= tilde_buf.len) {
                                        @memcpy(tilde_buf[0..home.len], home);
                                        @memcpy(tilde_buf[home.len..total], stripped_final[1..]);
                                        break :blk tilde_buf[0..total];
                                    }
                                    break :blk stripped_final;
                                } else {
                                    break :blk stripped_final;
                                }
                            } else stripped_final;
                            // Check if variable has integer attribute
                            const has_integer_attr = if (self.var_attributes.get(potential_var)) |attrs| attrs.integer else false;

                            if (has_integer_attr) {
                                // Integer attribute: evaluate as arithmetic
                                const arith_mod = @import("utils/arithmetic.zig");
                                var arith = arith_mod.Arithmetic.initWithVariables(self.allocator, &self.environment);
                                if (is_append) {
                                    const existing = shell_mod.getVariableValue(self, potential_var) orelse "0";
                                    const existing_num = std.fmt.parseInt(i64, existing, 10) catch 0;
                                    const add_num = arith.eval(value_to_use) catch 0;
                                    const result = existing_num + add_num;
                                    var buf: [32]u8 = undefined;
                                    const result_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
                                    shell_mod.setArithVariable(self, potential_var, result_str);
                                } else {
                                    const result = arith.eval(value_to_use) catch 0;
                                    var buf: [32]u8 = undefined;
                                    const result_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
                                    shell_mod.setArithVariable(self, potential_var, result_str);
                                }
                            } else if (is_append) {
                                // += append: get existing value and concatenate
                                const existing = shell_mod.getVariableValue(self, potential_var) orelse "";
                                const combined = self.allocator.alloc(u8, existing.len + value_to_use.len) catch {
                                    shell_mod.setArithVariable(self, potential_var, value_to_use);
                                    self.last_exit_code = 0;
                                    return;
                                };
                                defer self.allocator.free(combined);
                                @memcpy(combined[0..existing.len], existing);
                                @memcpy(combined[existing.len..], value_to_use);
                                shell_mod.setArithVariable(self, potential_var, combined);
                            } else {
                                shell_mod.setArithVariable(self, potential_var, value_to_use);
                            }
                            self.last_exit_code = 0;
                            return;
                        }
                        // Fall through to full pipeline for expansion
                    }
                }
            }
        }

        // Check for C-style for loop: for ((init; cond; update)); do ... done
        // Skip this check if we're already inside a C-style for loop body to avoid recursion
        if (!self.in_cstyle_for_body and std.mem.startsWith(u8, trimmed_input, "for ((")) {
            try shell_mod.executeCStyleForLoopOneline(self, input);
            return;
        }

        // Check for select loop: select VAR in ITEM1 ITEM2; do ... done
        if (std.mem.startsWith(u8, trimmed_input, "select ")) {
            try shell_mod.executeSelectLoop(self, input);
            return;
        }

        // Check for let/mut variable bindings: let x = value (immutable), mut y = value (mutable)
        if (std.mem.startsWith(u8, trimmed_input, "let ") or std.mem.startsWith(u8, trimmed_input, "mut ")) {
            self.executeLetMut(trimmed_input) catch |err| {
                if (err == error.Exit) return err;
                try IO.eprint("den: variable binding error: {}\n", .{err});
                self.last_exit_code = 1;
            };
            return;
        }

        // Check for try/catch error handling: try { ... } catch err { ... }
        if (std.mem.startsWith(u8, trimmed_input, "try ") or std.mem.eql(u8, trimmed_input, "try")) {
            self.executeTryCatch(trimmed_input) catch |err| {
                if (err == error.Exit) return err;
                try IO.eprint("den: try/catch error: {}\n", .{err});
                self.last_exit_code = 1;
            };
            return;
        }

        // Check for match expressions: match $value { pattern => body, ... }
        if (std.mem.startsWith(u8, trimmed_input, "match ")) {
            self.executeMatch(trimmed_input) catch |err| {
                if (err == error.Exit) return err;
                try IO.eprint("den: match error: {}\n", .{err});
                self.last_exit_code = 1;
            };
            return;
        }

        // Check for one-liner control flow: for/while/until/if/case
        if (std.mem.startsWith(u8, trimmed_input, "for ") or
            std.mem.startsWith(u8, trimmed_input, "while ") or
            std.mem.startsWith(u8, trimmed_input, "until ") or
            std.mem.startsWith(u8, trimmed_input, "if ") or
            std.mem.startsWith(u8, trimmed_input, "case "))
        {
            self.executeControlFlowOneliner(trimmed_input) catch |err| {
                try IO.eprint("den: control flow error: {}\n", .{err});
                self.last_exit_code = 1;
            };
            return;
        }

        // Check for pipeline into control flow: cmd | while/for/if/until/case ...
        // The parser can't handle this because it splits on semicolons inside while/for/etc.
        // We handle it here by manually setting up the pipe and executing both sides.
        if (std.mem.indexOf(u8, trimmed_input, "|") != null) {
            if (self.handlePipeToControlFlow(trimmed_input)) return;
        }

        // Check if input contains a C-style for loop after other commands (e.g., "total=0; for ((...")
        // This handles cases like: total=0; for ((i=1; i<=5; i++)); do total=$((total + i)); done; echo $total
        if (!self.in_cstyle_for_body and std.mem.indexOf(u8, trimmed_input, "for ((") != null) {
            try shell_mod.executeWithCStyleForLoop(self, input);
            return;
        }

        // Execute pre_command hooks
        const cmd_copy = try self.allocator.dupe(u8, input);
        defer self.allocator.free(cmd_copy);
        var cmd_ptr = cmd_copy;
        var pre_context = HookContext{
            .hook_type = .pre_command,
            .data = @ptrCast(@alignCast(&cmd_ptr)),
            .user_data = null,
            .allocator = self.allocator,
        };
        self.plugin_registry.executeHooks(.pre_command, &pre_context) catch {};

        // Fast path for simple commands (no pipes, redirects, operators, or expansions)
        // This avoids the full tokenizer/parser for common cases like "ls", "echo hello", etc.
        if (self.tryFastPath(trimmed_input)) |exit_code| {
            self.last_exit_code = exit_code;
            // Fire ERR trap on non-zero exit codes
            if (exit_code != 0) {
                shell_mod.executeErrTrap(self);
            }
            // Execute post_command hooks
            var post_context = HookContext{
                .hook_type = .post_command,
                .data = @ptrCast(@alignCast(&cmd_ptr)),
                .user_data = null,
                .allocator = self.allocator,
            };
            self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
            return;
        }

        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, input);
        const tokens = tokenizer.tokenize() catch |err| {
            const diag = diagnostic.errWithSource(
                "tokenization failed",
                input,
                1,
                1,
            );
            _ = diag;
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer tokenizer.deinitTokens(tokens);

        if (tokens.len == 0) return;

        // Parse
        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            // Use diagnostic system for rich error display
            var diag = diagnostic.Diagnostic{
                .severity = .@"error",
                .message = formatParseError(err),
                .source_line = input,
                .line = 1,
                .column = 1,
            };
            // Add typo correction hints
            if (err == error.UnexpectedToken or err == error.InvalidSyntax) {
                diag.help = "check for missing quotes, brackets, or semicolons";
            }
            diag.emit();
            self.last_exit_code = 2;
            return;
        };
        defer chain.deinit(self.allocator);

        // Whether the chain runs in the background (last operator is &).
        // Background chains are forked and executed by an executor with no
        // shell reference, so they cannot expand lazily and must be expanded
        // up-front here.
        const is_background = chain.operators.len > 0 and
            chain.operators[chain.operators.len - 1] == .background;

        // Expand variables/braces/globs.
        //
        // For a foreground chain with more than one segment, expansion is
        // DEFERRED to execution time — the executor expands each command right
        // before it runs (see Executor.ensureExpanded). This makes a variable
        // set in an earlier segment visible to a later one, e.g.
        // `export FOO=bar && echo $FOO`. Single commands and background chains
        // are expanded up-front since they have no "earlier segment" to observe
        // (or no shell reference at execution time).
        const defer_expansion = !is_background and chain.commands.len > 1;
        if (!defer_expansion) {
            self.expandCommandChain(&chain) catch |err| {
                if (err == error.UnboundVariable or err == error.ParameterNullOrNotSet) {
                    // ${var:?} / set -u failures: the command fails with a
                    // non-zero status and does not run with the bad value.
                    self.last_exit_code = 1;
                    if (self.option_errexit) return error.Exit;
                    return;
                }
                return err;
            };
        }

        // Expand aliases in command names
        try self.expandAliases(&chain);

        // Check for function calls (single command, no operators)
        if (chain.commands.len == 1 and chain.operators.len == 0) {
            const cmd = &chain.commands[0];

            // Check if this is a function call
            if (self.function_manager.hasFunction(cmd.name)) {
                // If function call has redirections, save/restore fds around execution
                var saved_fds = redirection.SavedFds{};
                if (cmd.redirections.len > 0) {
                    saved_fds = redirection.SavedFds.save();
                    const expansion_context: ?redirection.ExpansionContext = .{
                        .option_nounset = self.option_nounset,
                        .option_noclobber = self.option_noclobber,
                        .var_attributes = &self.var_attributes,
                        .arrays = &self.arrays,
                        .assoc_arrays = &self.assoc_arrays,
                    };
                    redirection.applyRedirections(
                        self.allocator,
                        cmd.redirections,
                        &self.environment,
                        expansion_context,
                    ) catch {
                        saved_fds.restore();
                        self.last_exit_code = 1;
                        return;
                    };
                }
                const exit_code = self.function_manager.executeFunction(self, cmd.name, cmd.args) catch |err| {
                    saved_fds.restore();
                    try IO.eprint("den: function error: {}\n", .{err});
                    self.last_exit_code = 1;
                    // Execute post_command hooks
                    var post_context = HookContext{
                        .hook_type = .post_command,
                        .data = @ptrCast(@alignCast(&cmd_ptr)),
                        .user_data = null,
                        .allocator = self.allocator,
                    };
                    self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
                    return;
                };
                saved_fds.restore();
                self.last_exit_code = exit_code;
                // Execute post_command hooks
                var post_context = HookContext{
                    .hook_type = .post_command,
                    .data = @ptrCast(@alignCast(&cmd_ptr)),
                    .user_data = null,
                    .allocator = self.allocator,
                };
                self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
                return;
            }
        }

        // Check for shell-context builtins (jobs, history, etc.)
        if (chain.commands.len == 1 and chain.operators.len == 0) {
            const cmd = &chain.commands[0];
            if (cmd.redirections.len == 0) {
                if (try shell_mod.dispatchBuiltin(self, cmd) == .handled) {
                    if (self.last_exit_code != 0) {
                        shell_mod.executeErrTrap(self);
                    }
                    return;
                }
            } else if (shell_mod.isShellBuiltin(cmd.name)) {
                // Restricted mode: block output redirections for shell builtins
                if (self.option_restricted) {
                    for (cmd.redirections) |redir| {
                        switch (redir.kind) {
                            .output_truncate, .output_append, .output_clobber => {
                                IO.eprint("den: output redirection restricted\n", .{}) catch {};
                                self.last_exit_code = 1;
                                return;
                            },
                            .fd_duplicate => {
                                if (redir.fd == 1 or redir.fd == 2) {
                                    IO.eprint("den: output redirection restricted\n", .{}) catch {};
                                    self.last_exit_code = 1;
                                    return;
                                }
                            },
                            else => {},
                        }
                    }
                }
                // Shell-level builtin with redirections: apply redirections manually
                // Skip on Windows (fd-level redirections not supported)
                if (comptime builtin.os.tag != .windows) {
                    var saved_fds: [3]c_int = .{ -1, -1, -1 };
                    var applied = false;
                    for (cmd.redirections) |redir| {
                        switch (redir.kind) {
                            .input => {
                                const path_z = self.allocator.dupeSentinel(u8, redir.target, 0) catch continue;
                                defer self.allocator.free(path_z);
                                const fd = std.c.open(path_z, .{}, @as(c_uint, 0));
                                if (fd >= 0) {
                                    saved_fds[0] = std.c.dup(std.posix.STDIN_FILENO);
                                    _ = std.c.dup2(fd, std.posix.STDIN_FILENO);
                                    _ = std.c.close(fd);
                                    applied = true;
                                }
                            },
                            .output_truncate, .output_append, .output_clobber => {
                                const path_z = self.allocator.dupeSentinel(u8, redir.target, 0) catch continue;
                                defer self.allocator.free(path_z);
                                const flags: std.c.O = if (redir.kind == .output_append)
                                    .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
                                else
                                    .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
                                const fd = std.c.open(path_z, flags, @as(c_uint, 0o644));
                                if (fd >= 0) {
                                    saved_fds[1] = std.c.dup(std.posix.STDOUT_FILENO);
                                    _ = std.c.dup2(fd, std.posix.STDOUT_FILENO);
                                    _ = std.c.close(fd);
                                    applied = true;
                                }
                            },
                            .herestring => {
                                // Create pipe, write herestring content + newline to it, redirect stdin
                                var pipe_fds: [2]std.posix.fd_t = undefined;
                                if (std.c.pipe(&pipe_fds) == 0) {
                                    const read_fd = pipe_fds[0];
                                    const write_fd = pipe_fds[1];
                                    // Strip surrounding quotes if present
                                    const target = redir.target;
                                    const unquoted = if (target.len >= 2 and
                                        ((target[0] == '"' and target[target.len - 1] == '"') or
                                            (target[0] == '\'' and target[target.len - 1] == '\'')))
                                        target[1 .. target.len - 1]
                                    else
                                        target;
                                    // Write content + newline
                                    const hs_file = std.Io.File{ .handle = write_fd, .flags = .{ .nonblocking = false } };
                                    hs_file.writeStreamingAll(std.Options.debug_io, unquoted) catch {};
                                    hs_file.writeStreamingAll(std.Options.debug_io, "\n") catch {};
                                    _ = std.c.close(write_fd);
                                    // Redirect stdin
                                    saved_fds[0] = std.c.dup(std.posix.STDIN_FILENO);
                                    _ = std.c.dup2(read_fd, std.posix.STDIN_FILENO);
                                    _ = std.c.close(read_fd);
                                    applied = true;
                                }
                            },
                            else => {},
                        }
                    }
                    if (applied) {
                        const result = shell_mod.dispatchBuiltin(self, cmd) catch .not_builtin;
                        // Restore saved fds — saved_fds is [3]c_int, so no @intCast needed
                        if (saved_fds[0] >= 0) {
                            _ = std.c.dup2(saved_fds[0], std.posix.STDIN_FILENO);
                            _ = std.c.close(saved_fds[0]);
                        }
                        if (saved_fds[1] >= 0) {
                            _ = std.c.dup2(saved_fds[1], std.posix.STDOUT_FILENO);
                            _ = std.c.close(saved_fds[1]);
                        }
                        if (result == .handled) {
                            if (self.last_exit_code != 0) {
                                shell_mod.executeErrTrap(self);
                            }
                            return;
                        }
                    }
                } // end !windows
            }
        }

        // Background jobs (last operator is &) — is_background computed above.
        if (is_background) {
            // Execute in background
            try shell_mod.executeInBackground(self, &chain, input);
            self.last_exit_code = 0;
        } else {
            // Execute normally
            var executor = executor_mod.Executor.initWithShell(self.allocator, &self.environment, self);
            const exit_code = executor.executeChain(&chain) catch |err| {
                // BrokenPipe is expected when a downstream pipe consumer closes early.
                // UnboundVariable (set -u, from deferred per-segment expansion) has
                // already been reported by the expander.
                if (err != error.BrokenPipe and err != error.UnboundVariable)
                    try IO.eprint("den: execution error: {}\n", .{err});
                self.last_exit_code = 1;
                // Execute post_command hooks even on error
                var post_context = HookContext{
                    .hook_type = .post_command,
                    .data = @ptrCast(@alignCast(&cmd_ptr)),
                    .user_data = null,
                    .allocator = self.allocator,
                };
                self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
                return;
            };

            self.last_exit_code = exit_code;
            // Note: ERR trap is already executed inside executor.executeChain
        }

        // Execute post_command hooks
        var post_context = HookContext{
            .hook_type = .post_command,
            .data = @ptrCast(@alignCast(&cmd_ptr)),
            .user_data = null,
            .allocator = self.allocator,
        };
        self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
    }

    /// Try fast path for simple commands.
    /// Returns exit code if handled, null to fall back to full parser.
    fn tryFastPath(self: *Shell, input: []const u8) ?i32 {
        return shell_mod.tryFastPath(self, input);
    }

    pub fn executeErrTrap(self: *Shell) void {
        shell_mod.executeErrTrap(self);
    }

    pub fn executeExitTrap(self: *Shell) void {
        shell_mod.executeExitTrap(self);
    }

    /// Preprocess heredoc: convert multi-line heredoc to herestring.
    /// Input like "cat <<EOF\nhello\nworld\nEOF" becomes "cat <<< 'hello\nworld'"
    /// Returns null if no heredoc found or processing fails.
    pub fn preprocessHeredoc(self: *Shell, input: []const u8) ?[]const u8 {
        // Find << that's not <<< (herestring)
        var search_pos: usize = 0;
        const heredoc_pos = while (search_pos < input.len) {
            const pos = std.mem.indexOf(u8, input[search_pos..], "<<") orelse break null;
            const abs_pos = search_pos + pos;
            // Skip <<< (herestring)
            if (abs_pos + 2 < input.len and input[abs_pos + 2] == '<') {
                search_pos = abs_pos + 3;
                continue;
            }
            break abs_pos;
        } else null;

        const hd_pos = heredoc_pos orelse return null;

        // Check for <<- (strip tabs variant)
        var after_op = hd_pos + 2;
        var strip_tabs = false;
        if (after_op < input.len and input[after_op] == '-') {
            strip_tabs = true;
            after_op += 1;
        }

        // Skip whitespace after <<
        while (after_op < input.len and (input[after_op] == ' ' or input[after_op] == '\t')) {
            after_op += 1;
        }

        if (after_op >= input.len) return null;

        // Extract delimiter (handle quoted: 'EOF', "EOF", \EOF, or plain EOF)
        var delim_start = after_op;
        var delim_end = after_op;
        var quoted = false;

        if (input[delim_start] == '\'' or input[delim_start] == '"') {
            const quote_char = input[delim_start];
            delim_start += 1;
            delim_end = delim_start;
            while (delim_end < input.len and input[delim_end] != quote_char) {
                delim_end += 1;
            }
            quoted = true;
            after_op = if (delim_end < input.len) delim_end + 1 else delim_end;
        } else {
            while (delim_end < input.len and input[delim_end] != '\n' and
                input[delim_end] != ' ' and input[delim_end] != '\t')
            {
                delim_end += 1;
            }
            after_op = delim_end;
        }

        const delimiter = input[delim_start..delim_end];
        if (delimiter.len == 0) return null;

        // Find the first newline after the heredoc operator (start of content)
        const first_nl = std.mem.indexOfScalarPos(u8, input, after_op, '\n') orelse return null;
        const content_start = first_nl + 1;

        // Find the delimiter line in the remaining content
        var line_start = content_start;
        var content_end = content_start;
        var found_delim = false;
        var after_delim_pos: usize = input.len; // position after the delimiter line

        while (line_start < input.len) {
            const line_end = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
            var line = input[line_start..line_end];

            // Strip leading tabs if <<-
            if (strip_tabs) {
                while (line.len > 0 and line[0] == '\t') {
                    line = line[1..];
                }
            }

            // For normal heredocs (<<), the delimiter must match the line exactly.
            // For strip-tabs heredocs (<<-), leading tabs were already stripped above.
            // In both cases, trim only trailing whitespace (e.g. trailing \r) but never leading.
            const trimmed_line = std.mem.trimEnd(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed_line, delimiter)) {
                content_end = line_start;
                found_delim = true;
                after_delim_pos = if (line_end < input.len) line_end + 1 else input.len;
                break;
            }
            line_start = if (line_end < input.len) line_end + 1 else input.len;
        }

        if (!found_delim) return null;

        // Build the heredoc content (everything between command and delimiter)
        var heredoc_content = input[content_start..content_end];
        // Remove trailing newline if present
        if (heredoc_content.len > 0 and heredoc_content[heredoc_content.len - 1] == '\n') {
            heredoc_content = heredoc_content[0 .. heredoc_content.len - 1];
        }

        // For <<- (strip tabs), strip leading tabs from each line of content
        var stripped_buf: [8192]u8 = undefined;
        if (strip_tabs and heredoc_content.len > 0) {
            var spos: usize = 0;
            var cstart: usize = 0;
            while (cstart <= heredoc_content.len) {
                const cend = if (cstart < heredoc_content.len)
                    (std.mem.indexOfScalarPos(u8, heredoc_content, cstart, '\n') orelse heredoc_content.len)
                else
                    heredoc_content.len;
                // Add newline between lines
                if (cstart > 0 and spos < stripped_buf.len) {
                    stripped_buf[spos] = '\n';
                    spos += 1;
                }
                // Skip leading tabs
                var lstart = cstart;
                while (lstart < cend and heredoc_content[lstart] == '\t') lstart += 1;
                // Copy content after tabs
                const line_len = cend - lstart;
                const copy_len = @min(line_len, stripped_buf.len - spos);
                if (copy_len > 0) {
                    @memcpy(stripped_buf[spos .. spos + copy_len], heredoc_content[lstart .. lstart + copy_len]);
                    spos += copy_len;
                }
                if (cend >= heredoc_content.len) break;
                cstart = cend + 1;
            }
            heredoc_content = stripped_buf[0..spos];
        }

        // Build the command part (everything before <<)
        const cmd_part = std.mem.trim(u8, input[0..hd_pos], &std.ascii.whitespace);

        if (quoted) {
            // Quoted heredoc: no expansion. Directly pipe the content.
            if (comptime builtin.os.tag == .windows) {
                // Windows: use spawn module for heredoc piping
                // For now, convert to herestring as a fallback
                const result = std.fmt.allocPrint(self.allocator, "{s} <<< \"{s}\"", .{
                    cmd_part, heredoc_content,
                }) catch return null;
                return result;
            } else {
                // POSIX: Create pipe, fork writer, redirect stdin, then execute command.
                var pipe_fds: [2]std.posix.fd_t = undefined;
                if (std.c.pipe(&pipe_fds) != 0) return null;
                const read_fd = pipe_fds[0];
                const write_fd = pipe_fds[1];

                const fork_ret = std.c.fork();
                if (fork_ret < 0) {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                }
                if (fork_ret == 0) {
                    // Child: write content and exit
                    _ = std.c.close(read_fd);
                    const content_with_nl = std.fmt.allocPrint(self.allocator, "{s}\n", .{heredoc_content}) catch {
                        std.c._exit(1);
                        unreachable;
                    };
                    (std.Io.File{ .handle = write_fd, .flags = .{ .nonblocking = false } }).writeStreamingAll(std.Options.debug_io, content_with_nl) catch {};
                    _ = std.c.close(write_fd);
                    std.c._exit(0);
                    unreachable;
                }

                // Parent: redirect stdin to read end of pipe
                _ = std.c.close(write_fd);
                const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
                if (std.c.dup2(read_fd, std.posix.STDIN_FILENO) < 0) {
                    _ = std.c.close(read_fd);
                    if (saved_stdin >= 0) _ = std.c.close(saved_stdin);
                    return null;
                }
                _ = std.c.close(read_fd);

                // Wait for writer to finish (retry on EINTR)
                var wait_status_heredoc: c_int = 0;
                _ = process_util.waitpidIntr(@intCast(fork_ret), &wait_status_heredoc, 0);

                // Execute the command with stdin redirected
                self.executeCommand(cmd_part) catch {};

                // Restore stdin
                if (saved_stdin >= 0) {
                    _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
                    _ = std.c.close(saved_stdin);
                }

                // Execute any trailing content after the delimiter line
                const trailing_q = std.mem.trim(u8, input[after_delim_pos..], &std.ascii.whitespace);
                if (trailing_q.len > 0) {
                    self.executeCommand(trailing_q) catch {};
                }

                // Return empty string to signal we handled it (caller will free and return)
                return self.allocator.dupe(u8, "") catch null;
            }
        } else {
            // Unquoted heredoc: allow expansion via herestring with double quotes
            // Also include any trailing content after the delimiter line (e.g., closing braces, more commands)
            const trailing = std.mem.trim(u8, input[after_delim_pos..], &std.ascii.whitespace);
            if (trailing.len > 0) {
                const result = std.fmt.allocPrint(self.allocator, "{s} <<< \"{s}\"\n{s}", .{
                    cmd_part, heredoc_content, trailing,
                }) catch return null;
                return result;
            }
            const result = std.fmt.allocPrint(self.allocator, "{s} <<< \"{s}\"", .{
                cmd_part, heredoc_content,
            }) catch return null;
            return result;
        }
    }

    /// Execute a let or mut variable binding.
    /// Syntax: let x = value (immutable) or mut y = value (mutable)
    fn executeLetMut(self: *Shell, input: []const u8) !void {
        const is_let = std.mem.startsWith(u8, input, "let ");
        const rest = if (is_let) input[4..] else input[4..]; // "let " or "mut " both 4 chars
        const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);

        // Parse: name = value
        // Find the = sign (with or without spaces)
        var name_end: usize = 0;
        for (trimmed, 0..) |c, idx| {
            if (c == '=' or c == ' ') {
                name_end = idx;
                break;
            }
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                try IO.eprint("den: invalid variable name in {s} binding\n", .{if (is_let) "let" else "mut"});
                self.last_exit_code = 1;
                return;
            }
        } else {
            name_end = trimmed.len;
        }

        const var_name = trimmed[0..name_end];
        if (var_name.len == 0) {
            try IO.eprint("den: {s}: missing variable name\n", .{if (is_let) "let" else "mut"});
            self.last_exit_code = 1;
            return;
        }

        // Check if variable already exists and is immutable (can't rebind let vars)
        if (is_let) {
            if (self.var_attributes.get(var_name)) |attrs| {
                if (attrs.immutable) {
                    try IO.eprint("den: {s}: immutable variable (declared with let)\n", .{var_name});
                    self.last_exit_code = 1;
                    return;
                }
            }
        }

        // Find the value after = (skip optional spaces around =)
        var value_start = name_end;
        // Skip spaces
        while (value_start < trimmed.len and trimmed[value_start] == ' ') value_start += 1;
        // Skip =
        if (value_start < trimmed.len and trimmed[value_start] == '=') {
            value_start += 1;
        } else {
            // No value means empty string
            const empty_val = try self.allocator.dupe(u8, "");
            const gop = try self.environment.getOrPut(var_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, var_name);
            }
            gop.value_ptr.* = empty_val;

            // Set immutable attribute for let bindings
            if (is_let) {
                const var_builtins = @import("shell/variable_builtins.zig");
                try var_builtins.setVarAttributes(self, var_name, types.VarAttributes{ .immutable = true }, false);
            }

            self.last_exit_code = 0;
            return;
        }
        // Skip spaces after =
        while (value_start < trimmed.len and trimmed[value_start] == ' ') value_start += 1;

        const raw_value = if (value_start < trimmed.len) trimmed[value_start..] else "";

        // Check if value needs expansion (contains $, `)
        var needs_expansion = false;
        for (raw_value) |c| {
            if (c == '$' or c == '`') {
                needs_expansion = true;
                break;
            }
        }

        if (needs_expansion) {
            // Use Expansion to resolve variables/command substitutions
            var expander = Expansion.init(self.allocator, &self.environment, self.last_exit_code);
            expander.arrays = &self.arrays;
            expander.assoc_arrays = &self.assoc_arrays;
            const expanded = expander.expand(raw_value) catch raw_value;
            const val = if (expanded.ptr != raw_value.ptr) expanded else try self.allocator.dupe(u8, raw_value);

            const gop = try self.environment.getOrPut(var_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, var_name);
            }
            gop.value_ptr.* = val;
        } else {
            // Simple literal value - strip surrounding quotes
            const stripped = if (raw_value.len >= 2 and
                ((raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') or
                    (raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'')))
                raw_value[1 .. raw_value.len - 1]
            else
                raw_value;

            // Evaluate as arithmetic expression (let/mut support arithmetic like bash's let)
            const loops = @import("shell/loops.zig");
            const arith_result = loops.evaluateArithmeticExpression(self, stripped);
            // Use arithmetic result if the expression contained operators, otherwise use literal
            const val = if (std.fmt.parseInt(i64, stripped, 10) == error.InvalidCharacter)
                try std.fmt.allocPrint(self.allocator, "{d}", .{arith_result})
            else
                try self.allocator.dupe(u8, stripped);

            const gop = try self.environment.getOrPut(var_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, var_name);
            }
            gop.value_ptr.* = val;
        }

        // Set immutable attribute for let bindings
        if (is_let) {
            const var_builtins = @import("shell/variable_builtins.zig");
            try var_builtins.setVarAttributes(self, var_name, types.VarAttributes{ .immutable = true }, false);
        }

        self.last_exit_code = 0;
    }

    /// Execute a try/catch block.
    /// Syntax: try { commands } catch [varname] { commands }
    /// Or one-liner: try command1; command2 catch err { handle }
    fn executeTryCatch(self: *Shell, input: []const u8) !void {
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

        // Find the try body and catch clause
        // Syntax: try { body } catch [var] { handler }
        // Or: try command; catch [var] { handler }
        var try_body: []const u8 = "";
        var catch_var: []const u8 = "err";
        var catch_body: []const u8 = "";

        // Simple brace-based parsing
        if (std.mem.startsWith(u8, trimmed, "try {") or std.mem.startsWith(u8, trimmed, "try{")) {
            // Find matching }
            const body_start = if (trimmed[3] == '{') @as(usize, 4) else @as(usize, 5);
            var depth: usize = 1;
            var pos: usize = body_start;
            while (pos < trimmed.len) : (pos += 1) {
                if (trimmed[pos] == '{') depth += 1;
                if (trimmed[pos] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (depth != 0) {
                try IO.eprint("den: try: missing closing }}\n", .{});
                self.last_exit_code = 1;
                return;
            }
            try_body = std.mem.trim(u8, trimmed[body_start..pos], &std.ascii.whitespace);
            pos += 1; // skip }

            // Look for catch
            const after_try = std.mem.trim(u8, trimmed[pos..], &std.ascii.whitespace);
            if (std.mem.startsWith(u8, after_try, "catch")) {
                const catch_rest = std.mem.trim(u8, after_try[5..], &std.ascii.whitespace);
                // Check for catch variable name
                if (catch_rest.len > 0 and catch_rest[0] != '{') {
                    // Has a variable name
                    var var_end: usize = 0;
                    while (var_end < catch_rest.len and catch_rest[var_end] != ' ' and catch_rest[var_end] != '{') var_end += 1;
                    catch_var = catch_rest[0..var_end];
                    const rest_after_var = std.mem.trim(u8, catch_rest[var_end..], &std.ascii.whitespace);
                    if (rest_after_var.len > 0 and rest_after_var[0] == '{') {
                        // Find matching } for catch body
                        depth = 1;
                        pos = 1;
                        while (pos < rest_after_var.len) : (pos += 1) {
                            if (rest_after_var[pos] == '{') depth += 1;
                            if (rest_after_var[pos] == '}') {
                                depth -= 1;
                                if (depth == 0) break;
                            }
                        }
                        catch_body = std.mem.trim(u8, rest_after_var[1..pos], &std.ascii.whitespace);
                    }
                } else if (catch_rest.len > 0 and catch_rest[0] == '{') {
                    // No variable name, directly { body }
                    depth = 1;
                    pos = 1;
                    while (pos < catch_rest.len) : (pos += 1) {
                        if (catch_rest[pos] == '{') depth += 1;
                        if (catch_rest[pos] == '}') {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                    }
                    catch_body = std.mem.trim(u8, catch_rest[1..pos], &std.ascii.whitespace);
                }
            }
        } else if (std.mem.startsWith(u8, trimmed, "try ")) {
            // Simple form: try command; catch { handler } or try command
            const rest = trimmed[4..];
            // Find " catch " boundary
            if (std.mem.indexOf(u8, rest, " catch ")) |catch_pos| {
                try_body = std.mem.trim(u8, rest[0..catch_pos], &std.ascii.whitespace);
                const catch_rest = std.mem.trim(u8, rest[catch_pos + 7 ..], &std.ascii.whitespace);
                if (catch_rest.len > 0 and catch_rest[0] == '{') {
                    var depth: usize = 1;
                    var pos: usize = 1;
                    while (pos < catch_rest.len) : (pos += 1) {
                        if (catch_rest[pos] == '{') depth += 1;
                        if (catch_rest[pos] == '}') {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                    }
                    catch_body = std.mem.trim(u8, catch_rest[1..pos], &std.ascii.whitespace);
                } else {
                    // Check for variable name before {
                    var var_end: usize = 0;
                    while (var_end < catch_rest.len and catch_rest[var_end] != ' ' and catch_rest[var_end] != '{') var_end += 1;
                    if (var_end > 0 and var_end < catch_rest.len) {
                        catch_var = catch_rest[0..var_end];
                        const rest2 = std.mem.trim(u8, catch_rest[var_end..], &std.ascii.whitespace);
                        if (rest2.len > 0 and rest2[0] == '{') {
                            var depth: usize = 1;
                            var pos: usize = 1;
                            while (pos < rest2.len) : (pos += 1) {
                                if (rest2[pos] == '{') depth += 1;
                                if (rest2[pos] == '}') {
                                    depth -= 1;
                                    if (depth == 0) break;
                                }
                            }
                            catch_body = std.mem.trim(u8, rest2[1..pos], &std.ascii.whitespace);
                        } else {
                            catch_body = rest2;
                        }
                    } else {
                        catch_body = catch_rest;
                    }
                }
            } else {
                // No catch clause - just execute with error suppression
                try_body = std.mem.trim(u8, rest, &std.ascii.whitespace);
            }
        }

        if (try_body.len == 0) {
            try IO.eprint("den: try: missing command body\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Split try body into lines for ControlFlowExecutor
        var try_lines_buf: [64][]const u8 = undefined;
        var try_line_count: usize = 0;
        var try_iter = std.mem.splitScalar(u8, try_body, ';');
        while (try_iter.next()) |cmd| {
            const cmd_trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
            if (cmd_trimmed.len == 0) continue;
            if (try_line_count < try_lines_buf.len) {
                try_lines_buf[try_line_count] = cmd_trimmed;
                try_line_count += 1;
            }
        }

        // Execute try body via ControlFlowExecutor
        var cf_executor = ControlFlowExecutor.init(self);
        const try_result = cf_executor.executeBody(try_lines_buf[0..try_line_count]);
        self.last_exit_code = try_result;
        const try_failed = try_result != 0;

        if (try_failed and catch_body.len > 0) {
            // Set the error variable
            const err_msg = try std.fmt.allocPrint(self.allocator, "command failed with exit code {d}", .{self.last_exit_code});
            const err_gop = try self.environment.getOrPut(catch_var);
            if (err_gop.found_existing) {
                self.allocator.free(err_gop.value_ptr.*);
            } else {
                err_gop.key_ptr.* = try self.allocator.dupe(u8, catch_var);
            }
            err_gop.value_ptr.* = err_msg;

            // Also set DEN_ERROR
            const den_err_gop = try self.environment.getOrPut("DEN_ERROR");
            if (den_err_gop.found_existing) {
                self.allocator.free(den_err_gop.value_ptr.*);
            } else {
                den_err_gop.key_ptr.* = try self.allocator.dupe(u8, "DEN_ERROR");
            }
            den_err_gop.value_ptr.* = try self.allocator.dupe(u8, err_msg);

            // Execute catch body via ControlFlowExecutor
            var catch_lines_buf: [64][]const u8 = undefined;
            var catch_line_count: usize = 0;
            var catch_iter = std.mem.splitScalar(u8, catch_body, ';');
            while (catch_iter.next()) |cmd| {
                const cmd_trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
                if (cmd_trimmed.len == 0) continue;
                if (catch_line_count < catch_lines_buf.len) {
                    catch_lines_buf[catch_line_count] = cmd_trimmed;
                    catch_line_count += 1;
                }
            }
            self.last_exit_code = cf_executor.executeBody(catch_lines_buf[0..catch_line_count]);
        } else if (!try_failed) {
            self.last_exit_code = 0;
        }
    }

    /// Execute a match expression.
    /// Syntax: match <value> { <pattern> => <body>, <pattern> => <body>, _ => <default> }
    fn executeMatch(self: *Shell, input: []const u8) !void {
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

        // Parse: match <value> { arms... }
        if (!std.mem.startsWith(u8, trimmed, "match ")) {
            try IO.eprint("den: invalid match syntax\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const after_match = trimmed[6..];
        // Find the opening {
        const brace_pos = std.mem.indexOfScalar(u8, after_match, '{') orelse {
            try IO.eprint("den: match: missing opening brace\n", .{});
            self.last_exit_code = 1;
            return;
        };

        // The match value is everything before {
        const match_value = std.mem.trim(u8, after_match[0..brace_pos], &std.ascii.whitespace);

        // Expand the match value (handle $var, $(cmd), etc.)
        var expander = Expansion.init(self.allocator, &self.environment, self.last_exit_code);
        expander.arrays = &self.arrays;
        expander.assoc_arrays = &self.assoc_arrays;
        const expanded_value = expander.expand(match_value) catch match_value;
        defer if (expanded_value.ptr != match_value.ptr) self.allocator.free(expanded_value);

        // Strip quotes from expanded value
        const value_stripped = if (expanded_value.len >= 2 and
            ((expanded_value[0] == '"' and expanded_value[expanded_value.len - 1] == '"') or
                (expanded_value[0] == '\'' and expanded_value[expanded_value.len - 1] == '\'')))
            expanded_value[1 .. expanded_value.len - 1]
        else
            expanded_value;

        // Find the matching closing }
        const body_start = brace_pos + 1;
        var depth: usize = 1;
        var body_end: usize = body_start;
        while (body_end < after_match.len) : (body_end += 1) {
            if (after_match[body_end] == '{') depth += 1;
            if (after_match[body_end] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (depth != 0) {
            try IO.eprint("den: match: missing closing }}\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const arms_str = std.mem.trim(u8, after_match[body_start..body_end], &std.ascii.whitespace);
        if (arms_str.len == 0) {
            self.last_exit_code = 0;
            return;
        }

        // Parse match arms: pattern => body, pattern => body, ...
        // Split on commas that are not inside braces/quotes
        var matched = false;
        var arm_start: usize = 0;
        var arm_depth: usize = 0;
        var in_sq = false;
        var in_dq = false;
        var ai: usize = 0;
        while (ai <= arms_str.len) : (ai += 1) {
            const at_end = ai == arms_str.len;
            const c = if (at_end) @as(u8, 0) else arms_str[ai];

            if (!at_end) {
                if (c == '\'' and !in_dq) {
                    in_sq = !in_sq;
                    continue;
                }
                if (c == '"' and !in_sq) {
                    in_dq = !in_dq;
                    continue;
                }
                if (in_sq or in_dq) continue;
                if (c == '{') {
                    arm_depth += 1;
                    continue;
                }
                if (c == '}') {
                    if (arm_depth > 0) arm_depth -= 1;
                    continue;
                }
                if (c != ',' or arm_depth > 0) continue;
            }

            // We have an arm (either at comma or end)
            const arm = std.mem.trim(u8, arms_str[arm_start..ai], &std.ascii.whitespace);
            arm_start = ai + 1;

            if (arm.len == 0) continue;
            if (matched) continue; // Already matched, skip remaining arms

            // Parse arm: pattern => body
            const arrow_pos = std.mem.indexOf(u8, arm, "=>") orelse continue;
            const pattern = std.mem.trim(u8, arm[0..arrow_pos], &std.ascii.whitespace);
            const body = std.mem.trim(u8, arm[arrow_pos + 2 ..], &std.ascii.whitespace);

            // Strip braces from body if present
            const actual_body = if (body.len >= 2 and body[0] == '{' and body[body.len - 1] == '}')
                std.mem.trim(u8, body[1 .. body.len - 1], &std.ascii.whitespace)
            else
                body;

            // Check if pattern matches
            if (std.mem.eql(u8, pattern, "_")) {
                // Wildcard - always matches
                matched = true;
            } else if (std.mem.indexOf(u8, pattern, "..")) |range_sep| {
                // Range pattern: 1..10 or 1..<10
                const exclusive = range_sep + 2 < pattern.len and pattern[range_sep + 2] == '<';
                const range_end_start = if (exclusive) range_sep + 3 else range_sep + 2;
                const range_start_str = std.mem.trim(u8, pattern[0..range_sep], &std.ascii.whitespace);
                const range_end_str = std.mem.trim(u8, pattern[range_end_start..], &std.ascii.whitespace);
                const val_num = std.fmt.parseInt(i64, value_stripped, 10) catch continue;
                const range_start = std.fmt.parseInt(i64, range_start_str, 10) catch continue;
                const range_end = std.fmt.parseInt(i64, range_end_str, 10) catch continue;
                if (exclusive) {
                    matched = val_num >= range_start and val_num < range_end;
                } else {
                    matched = val_num >= range_start and val_num <= range_end;
                }
            } else if (pattern.len > 0 and (pattern[0] == '$' or pattern[0] == '"' or pattern[0] == '\'')) {
                // Variable or quoted string pattern - expand and compare
                const expanded_pat = expander.expand(pattern) catch pattern;
                defer if (expanded_pat.ptr != pattern.ptr) self.allocator.free(expanded_pat);
                const pat_stripped = if (expanded_pat.len >= 2 and
                    ((expanded_pat[0] == '"' and expanded_pat[expanded_pat.len - 1] == '"') or
                        (expanded_pat[0] == '\'' and expanded_pat[expanded_pat.len - 1] == '\'')))
                    expanded_pat[1 .. expanded_pat.len - 1]
                else
                    expanded_pat;
                matched = std.mem.eql(u8, value_stripped, pat_stripped);
            } else if (std.mem.indexOfAny(u8, pattern, "*?[") != null) {
                // Glob pattern
                matched = ControlFlowExecutor.globMatch(value_stripped, pattern);
            } else {
                // Literal comparison (strip quotes)
                const pat_unquoted = if (pattern.len >= 2 and
                    ((pattern[0] == '"' and pattern[pattern.len - 1] == '"') or
                        (pattern[0] == '\'' and pattern[pattern.len - 1] == '\'')))
                    pattern[1 .. pattern.len - 1]
                else
                    pattern;
                matched = std.mem.eql(u8, value_stripped, pat_unquoted);
            }

            if (matched and actual_body.len > 0) {
                // Execute the body via ControlFlowExecutor
                var match_body_buf: [64][]const u8 = undefined;
                var match_body_count: usize = 0;
                var body_iter = std.mem.splitScalar(u8, actual_body, ';');
                while (body_iter.next()) |cmd| {
                    const cmd_trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
                    if (cmd_trimmed.len == 0) continue;
                    if (match_body_count < match_body_buf.len) {
                        match_body_buf[match_body_count] = cmd_trimmed;
                        match_body_count += 1;
                    }
                }
                var cf_exec = ControlFlowExecutor.init(self);
                self.last_exit_code = cf_exec.executeBody(match_body_buf[0..match_body_count]);
            }
        }

        if (!matched) {
            self.last_exit_code = 0;
        }
    }

    /// Execute a one-liner control flow statement (for/while/until/if/case).
    /// Converts semicolons to line breaks and feeds to the ControlFlowParser/Executor.
    fn executeControlFlowOneliner(self: *Shell, input: []const u8) !void {
        // Convert one-liner to multi-line by splitting on semicolons,
        // but respecting quotes, $() substitutions, and nested constructs.
        var lines_buf: [256][]const u8 = undefined;
        var line_count: usize = 0;
        var start: usize = 0;
        var in_single_quote = false;
        var in_double_quote = false;
        var paren_depth: u32 = 0;
        var i: usize = 0;

        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\\' and !in_single_quote and i + 1 < input.len) {
                i += 1;
                continue;
            }
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
            } else if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
            } else if (!in_single_quote and !in_double_quote) {
                if (c == '(' and (paren_depth > 0 or (i > 0 and input[i - 1] == '$'))) {
                    paren_depth += 1;
                } else if (c == ')' and paren_depth > 0) {
                    paren_depth -= 1;
                } else if (c == ';' and paren_depth == 0) {
                    // Check for ;; (case terminator) - keep it with the preceding part
                    if (i + 1 < input.len and input[i + 1] == ';') {
                        // Include the ;; in the current part, split after it
                        const part = std.mem.trim(u8, input[start .. i + 2], &std.ascii.whitespace);
                        if (part.len > 0 and line_count < lines_buf.len) {
                            lines_buf[line_count] = part;
                            line_count += 1;
                        }
                        i += 1; // skip second ;
                        start = i + 1;
                    } else {
                        const part = std.mem.trim(u8, input[start..i], &std.ascii.whitespace);
                        if (part.len > 0 and line_count < lines_buf.len) {
                            lines_buf[line_count] = part;
                            line_count += 1;
                        }
                        start = i + 1;
                    }
                }
            }
        }
        // Last part
        const last_part = std.mem.trim(u8, input[start..], &std.ascii.whitespace);
        if (last_part.len > 0 and line_count < lines_buf.len) {
            lines_buf[line_count] = last_part;
            line_count += 1;
        }

        if (line_count == 0) return;

        // Post-process: split lines that start with "do ", "then ", "else "
        // into separate lines, since the parser expects these as standalone keywords.
        // Also handle "case ... in PATTERN)" by splitting after " in ".
        var expanded_buf: [512][]const u8 = undefined;
        var expanded_count: usize = 0;
        for (lines_buf[0..line_count]) |line| {
            if (expanded_count >= expanded_buf.len) break;
            // Handle "case VALUE in PATTERN)" - split after " in "
            if (std.mem.startsWith(u8, line, "case ")) {
                if (std.mem.indexOf(u8, line[5..], " in ")) |in_off| {
                    const in_pos = 5 + in_off;
                    // "case VALUE in" part
                    expanded_buf[expanded_count] = line[0 .. in_pos + 3]; // up to and including " in"
                    expanded_count += 1;
                    if (expanded_count < expanded_buf.len) {
                        const rest = std.mem.trim(u8, line[in_pos + 4 ..], &std.ascii.whitespace);
                        if (rest.len > 0) {
                            expanded_buf[expanded_count] = rest;
                            expanded_count += 1;
                        }
                    }
                    continue;
                }
            }
            const keywords = [_][]const u8{ "do ", "then ", "else " };
            var found_keyword = false;
            for (keywords) |kw| {
                if (std.mem.startsWith(u8, line, kw)) {
                    expanded_buf[expanded_count] = line[0 .. kw.len - 1]; // "do" or "then" or "else"
                    expanded_count += 1;
                    if (expanded_count < expanded_buf.len) {
                        const rest = std.mem.trim(u8, line[kw.len..], &std.ascii.whitespace);
                        if (rest.len > 0) {
                            expanded_buf[expanded_count] = rest;
                            expanded_count += 1;
                        }
                    }
                    found_keyword = true;
                    break;
                }
            }
            if (!found_keyword) {
                expanded_buf[expanded_count] = line;
                expanded_count += 1;
            }
        }

        // Check if the last expanded line ends with a pipe after done/fi/esac
        // e.g., "done | tr a-z A-Z" or "fi | wc -l"
        var pipe_suffix: ?[]const u8 = null;
        if (expanded_count > 0) {
            const last_line = expanded_buf[expanded_count - 1];
            const terminators = [_][]const u8{ "done", "fi", "esac" };
            for (terminators) |term| {
                if (last_line.len > term.len and std.mem.startsWith(u8, last_line, term)) {
                    const after_term = last_line[term.len..];
                    const trimmed_after = std.mem.trim(u8, after_term, &std.ascii.whitespace);
                    if (trimmed_after.len > 0 and trimmed_after[0] == '|') {
                        pipe_suffix = std.mem.trim(u8, trimmed_after[1..], &std.ascii.whitespace);
                        // Replace the last line with just the terminator
                        expanded_buf[expanded_count - 1] = term;
                        break;
                    }
                }
            }
        }

        const lines = expanded_buf[0..expanded_count];

        // If there's a pipe suffix, run the control flow in a subshell with
        // stdout redirected to a pipe, then pipe into the suffix command.
        if (pipe_suffix) |pipe_cmd| {
            if (comptime builtin.os.tag != .windows) {
                var pipe_fds: [2]std.posix.fd_t = undefined;
                if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
                const read_fd = pipe_fds[0];
                const write_fd = pipe_fds[1];

                const fork_ret = std.c.fork();
                if (fork_ret < 0) {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return error.Unexpected;
                }

                if (fork_ret == 0) {
                    // Child: redirect stdout to write end, execute control flow
                    _ = std.c.close(read_fd);
                    _ = std.c.dup2(write_fd, std.posix.STDOUT_FILENO);
                    _ = std.c.close(write_fd);

                    var cf_parser = ControlFlowParser.init(self.allocator);
                    var cf_executor = ControlFlowExecutor.init(self);
                    self.executeCfBlock(lines, &cf_parser, &cf_executor) catch {};
                    std.c._exit(@intCast(@as(u32, @bitCast(self.last_exit_code))));
                    unreachable;
                }

                // Parent: redirect stdin to read end, execute pipe command
                _ = std.c.close(write_fd);
                const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
                _ = std.c.dup2(read_fd, std.posix.STDIN_FILENO);
                _ = std.c.close(read_fd);

                // Wait for control flow child to finish writing (retry on EINTR)
                var wait_status_cf: c_int = 0;
                _ = process_util.waitpidIntr(@intCast(fork_ret), &wait_status_cf, 0);

                // Execute the pipe command(s) — use function pointer to
                // break the inferred error set cycle (executeCommand →
                // executeControlFlowOneliner → executeCfBlock → executeCommand).
                const execFn: *const fn (*Shell, []const u8) anyerror!void = &Shell.executeCommand;
                execFn(self, pipe_cmd) catch {};

                // Restore stdin
                if (saved_stdin >= 0) {
                    _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
                    _ = std.c.close(saved_stdin);
                }
                return;
            } else {
                // Windows: execute control flow then pipe command sequentially
                var cf_parser = ControlFlowParser.init(self.allocator);
                var cf_executor = ControlFlowExecutor.init(self);
                self.executeCfBlock(lines, &cf_parser, &cf_executor) catch {};
                const execFn: *const fn (*Shell, []const u8) anyerror!void = &Shell.executeCommand;
                execFn(self, pipe_cmd) catch {};
                return;
            }
        }

        var cf_parser = ControlFlowParser.init(self.allocator);
        var cf_executor = ControlFlowExecutor.init(self);
        self.executeCfBlock(lines, &cf_parser, &cf_executor) catch |err| return err;

        // Propagate break/continue from executor to shell so outer loops can see them
        if (cf_executor.break_levels > 0) {
            self.break_levels = cf_executor.break_levels;
        }
        if (cf_executor.continue_levels > 0) {
            self.continue_levels = cf_executor.continue_levels;
        }
    }

    /// Execute a control flow block (for/while/until/if/case) from parsed lines.
    fn executeCfBlock(self: *Shell, lines: [][]const u8, cf_parser: *ControlFlowParser, cf_executor: *ControlFlowExecutor) anyerror!void {
        const first = if (lines.len > 0) lines[0] else return;
        if (std.mem.startsWith(u8, first, "for ")) {
            const result = try cf_parser.parseFor(lines, 0);
            var loop = result.loop;
            defer loop.deinit();
            self.last_exit_code = try cf_executor.executeFor(&loop);
        } else if (std.mem.startsWith(u8, first, "while ")) {
            const result = try cf_parser.parseWhile(lines, 0, false);
            var loop = result.loop;
            defer loop.deinit();
            self.last_exit_code = try cf_executor.executeWhile(&loop);
        } else if (std.mem.startsWith(u8, first, "until ")) {
            const result = try cf_parser.parseWhile(lines, 0, true);
            var loop = result.loop;
            defer loop.deinit();
            self.last_exit_code = try cf_executor.executeWhile(&loop);
        } else if (std.mem.startsWith(u8, first, "if ")) {
            const result = try cf_parser.parseIf(lines, 0);
            var stmt = result.stmt;
            defer stmt.deinit();
            self.last_exit_code = try cf_executor.executeIf(&stmt);
        } else if (std.mem.startsWith(u8, first, "case ")) {
            const result = try cf_parser.parseCase(lines, 0);
            var stmt = result.stmt;
            defer stmt.deinit();
            self.last_exit_code = try cf_executor.executeCase(&stmt);
        }
    }

    /// Handle pipeline into control flow: cmd | while/for/if/until/case ...
    /// Returns true if the pattern was detected and handled, false otherwise.
    fn handlePipeToControlFlow(self: *Shell, input: []const u8) bool {
        // Find the last top-level pipe that leads into a control flow keyword
        var pipe_pos: ?usize = null;
        var in_sq = false;
        var in_dq = false;
        var paren_d: u32 = 0;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\\' and !in_sq and i + 1 < input.len) {
                i += 1;
                continue;
            }
            if (c == '\'' and !in_dq) {
                in_sq = !in_sq;
            } else if (c == '"' and !in_sq) {
                in_dq = !in_dq;
            } else if (!in_sq and !in_dq) {
                if (c == '(') paren_d += 1;
                if (c == ')' and paren_d > 0) paren_d -= 1;
                if (c == '|' and paren_d == 0 and (i + 1 >= input.len or input[i + 1] != '|')) {
                    // Single | (not ||)
                    pipe_pos = i;
                }
            }
        }

        const pp = pipe_pos orelse return false;
        if (pp + 1 >= input.len) return false;

        // Check if the part after the last pipe starts with a control flow keyword or brace group
        const right = std.mem.trim(u8, input[pp + 1 ..], &std.ascii.whitespace);
        const cf_keywords = [_][]const u8{ "while ", "for ", "until ", "if ", "case ", "{ " };
        var is_cf = false;
        for (cf_keywords) |kw| {
            if (std.mem.startsWith(u8, right, kw)) {
                is_cf = true;
                break;
            }
        }
        if (!is_cf) return false;

        // Split: left side is everything before the last pipe, right side is control flow
        const left = std.mem.trim(u8, input[0..pp], &std.ascii.whitespace);
        if (left.len == 0) return false;

        if (comptime builtin.os.tag == .windows) {
            // Windows: execute sequentially without pipe isolation
            self.executeCommand(left) catch {};
            self.executeCommand(right) catch {};
            return true;
        } else {
            // Set up a pipe, fork for the left side, execute right side with piped stdin
            var fds: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return false;

            const fork_ret = std.c.fork();
            if (fork_ret < 0) {
                _ = std.c.close(fds[0]);
                _ = std.c.close(fds[1]);
                return false;
            }
            const pid: std.posix.pid_t = @intCast(fork_ret);

            if (pid == 0) {
                // Child: execute left side, stdout -> pipe write end
                _ = std.c.close(fds[0]);
                _ = std.c.dup2(fds[1], std.posix.STDOUT_FILENO);
                _ = std.c.close(fds[1]);
                self.executeCommand(left) catch {};
                std.c._exit(@intCast(if (self.last_exit_code >= 0) @as(u32, @intCast(self.last_exit_code)) else 1));
            }

            // Parent: execute right side (control flow) with stdin <- pipe read end
            _ = std.c.close(fds[1]);
            const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
            _ = std.c.dup2(fds[0], std.posix.STDIN_FILENO);
            _ = std.c.close(fds[0]);

            // Execute the control flow command
            self.executeCommand(right) catch {};

            // Restore stdin
            if (saved_stdin >= 0) {
                _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
                _ = std.c.close(saved_stdin);
            }

            // Wait for child (retry on EINTR)
            var wait_status_pipe: c_int = 0;
            _ = process_util.waitpidIntr(pid, &wait_status_pipe, 0);

            return true;
        }
    }

    /// Check if a word at position is a control flow opener keyword.
    /// The word must be at a word boundary (start of string or after whitespace/semicolon).
    fn isControlFlowOpener(input: []const u8, pos: usize) bool {
        const openers = [_][]const u8{ "for ", "while ", "until ", "if ", "case ", "select " };
        for (openers) |kw| {
            if (pos + kw.len <= input.len and std.mem.eql(u8, input[pos..][0..kw.len], kw)) {
                return true;
            }
        }
        return false;
    }

    /// Check if a word at position is a control flow closer keyword.
    fn isControlFlowCloser(input: []const u8, pos: usize) bool {
        const closers = [_]struct { word: []const u8, for_kw: []const u8 }{
            .{ .word = "done", .for_kw = "done" },
            .{ .word = "fi", .for_kw = "fi" },
            .{ .word = "esac", .for_kw = "esac" },
        };
        for (closers) |c| {
            const wlen = c.word.len;
            if (pos + wlen <= input.len and std.mem.eql(u8, input[pos..][0..wlen], c.word)) {
                // Must be at end of string or followed by whitespace/semicolon
                if (pos + wlen == input.len or
                    input[pos + wlen] == ' ' or input[pos + wlen] == ';' or
                    input[pos + wlen] == '\t' or input[pos + wlen] == '\n')
                {
                    return true;
                }
            }
        }
        return false;
    }

    /// Split input on unquoted semicolons and execute each part separately.
    /// Returns true if input was split and executed, false if no splitting needed.
    /// Tracks control flow depth so semicolons inside for/while/if/case constructs
    /// are NOT treated as split points.
    fn splitAndExecuteSemicolons(self: *Shell, input: []const u8) bool {
        // Quick check: if no semicolons, skip
        if (std.mem.indexOfScalar(u8, input, ';') == null) return false;

        // Find semicolons that are not inside quotes, $(), or control flow constructs
        var parts_buf: [64][]const u8 = undefined;
        var part_count: usize = 0;
        var start: usize = 0;
        var in_single_quote = false;
        var in_double_quote = false;
        var paren_depth: u32 = 0;
        var brace_depth: u32 = 0; // { } nesting depth (function bodies)
        var cf_depth: u32 = 0; // control flow nesting depth
        var i: usize = 0;
        var at_word_start = true; // track word boundaries for keyword detection

        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\\' and !in_single_quote and i + 1 < input.len) {
                i += 1; // skip escaped char
                at_word_start = false;
                continue;
            }
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                at_word_start = false;
            } else if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                at_word_start = false;
            } else if (!in_single_quote and !in_double_quote) {
                if (c == '(') {
                    paren_depth += 1;
                    at_word_start = false;
                } else if (c == ')' and paren_depth > 0) {
                    paren_depth -= 1;
                    at_word_start = false;
                } else if (c == '{' and (at_word_start or (i > 0 and input[i - 1] == ')')) and (i + 1 >= input.len or input[i + 1] == ' ' or input[i + 1] == '\t' or input[i + 1] == '\n')) {
                    // Brace-group opener at a word boundary (`{ …; }`) or a function
                    // body brace right after `)` (`name(){ …; }`). The `)` case keeps
                    // the body's semicolons out of the top-level split, so the whole
                    // `f(){ echo hi; }` reaches the function-definition parser intact.
                    brace_depth += 1;
                    at_word_start = false;
                } else if (c == '}' and brace_depth > 0 and at_word_start) {
                    brace_depth -= 1;
                    at_word_start = false;
                } else if (paren_depth == 0) {
                    // Track control flow nesting at word boundaries
                    if (at_word_start and isControlFlowOpener(input, i)) {
                        cf_depth += 1;
                        at_word_start = false;
                    } else if (at_word_start and cf_depth > 0 and isControlFlowCloser(input, i)) {
                        cf_depth -= 1;
                        at_word_start = false;
                    } else if (c == ';') {
                        // Skip double semicolons (;;) used in case statements
                        if (i + 1 < input.len and input[i + 1] == ';') {
                            i += 1;
                            at_word_start = true;
                            continue;
                        }
                        if (cf_depth == 0 and brace_depth == 0) {
                            const part = std.mem.trim(u8, input[start..i], &std.ascii.whitespace);
                            if (part.len > 0 and part_count < parts_buf.len) {
                                parts_buf[part_count] = part;
                                part_count += 1;
                            }
                            start = i + 1;
                        }
                        at_word_start = true;
                        continue;
                    } else if (c == ' ' or c == '\t' or c == '\n') {
                        at_word_start = true;
                        continue;
                    } else {
                        at_word_start = false;
                    }
                } else {
                    at_word_start = false;
                }
            } else {
                at_word_start = false;
            }
        }
        // Last part
        const last_part = std.mem.trim(u8, input[start..], &std.ascii.whitespace);
        if (last_part.len > 0 and part_count < parts_buf.len) {
            parts_buf[part_count] = last_part;
            part_count += 1;
        }

        // If we only have 1 part but the input had semicolons (trailing semicolons),
        // still handle it so it doesn't fall through to the parser with a dangling ';'
        if (part_count == 0) return false;
        if (part_count == 1) {
            // Only handle if the part is different from the original input
            // (i.e., we actually stripped a trailing semicolon).
            // If the part IS the full input, semicolons were inside control flow/quotes
            // and we must return false to avoid infinite recursion.
            const trimmed_orig = std.mem.trim(u8, input, &std.ascii.whitespace);
            if (std.mem.eql(u8, parts_buf[0], trimmed_orig)) return false;
            self.executeCommand(parts_buf[0]) catch {};
            return true;
        }

        // Execute each part separately
        for (parts_buf[0..part_count]) |part| {
            self.executeCommand(part) catch {};
            // Honor set -e (errexit): stop if a command fails.
            // Per POSIX, errexit should not apply when the last command was part
            // of an AND-OR list (&&/||) — those operators handle errors themselves.
            if (self.option_errexit and self.last_exit_code != 0 and !self.last_chain_had_and_or) break;
        }
        return true;
    }

    pub fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
        try shell_mod.expandCommandChain(self, chain);
    }

    /// Expand variables/braces/globs in a single command (idempotent).
    /// Used by the executor to defer expansion to execution time so each
    /// segment of a chain sees the environment mutated by prior segments.
    pub fn expandCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.expandCommand(self, cmd);
    }

    /// Add command to history (respects config.history.max_entries)
    fn addToHistory(self: *Shell, command: []const u8) !void {
        try History.add(
            self.allocator,
            self.history[0..self.history_max],
            &self.history_count,
            self.history_file_path,
            command,
        );
    }

    /// Load history from file (respects config.history.max_entries)
    fn loadHistory(self: *Shell) !void {
        try History.load(
            self.allocator,
            self.history[0..self.history_max],
            &self.history_count,
            self.history_file_path,
        );
    }

    /// Source ~/.denrc at startup (like .zshrc)
    pub fn sourceRcFile(self: *Shell) !void {
        const home = std.c.getenv("HOME") orelse return;
        const home_str = std.mem.span(@as([*:0]const u8, @ptrCast(home)));

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const rc_path = std.fmt.bufPrint(&path_buf, "{s}/.denrc", .{home_str}) catch return;

        // Open the file — silently return if it doesn't exist
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, rc_path, .{}) catch return;
        defer file.close(std.Options.debug_io);

        const max_size: usize = 1024 * 1024; // 1MB max
        const file_size = (file.stat(std.Options.debug_io) catch return).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = self.allocator.alloc(u8, read_size) catch return;
        defer self.allocator.free(buffer);

        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch break;
            if (n == 0) break;
            total_read += n;
        }
        const content = buffer[0..total_read];

        // Execute each line as a shell command
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue; // Skip comments
            self.executeCommand(trimmed) catch continue;
        }
    }

    /// Load aliases from configuration
    pub fn loadAliasesFromConfig(self: *Shell) !void {
        // Check if aliases are enabled in config
        if (!self.config.aliases.enabled) return;

        // Load custom aliases from config
        if (self.config.aliases.custom) |custom_aliases| {
            for (custom_aliases) |alias_entry| {
                const name_copy = try self.allocator.dupe(u8, alias_entry.name);
                const cmd_copy = try self.allocator.dupe(u8, alias_entry.command);
                try self.aliases.put(name_copy, cmd_copy);
            }
        }

        // Load suffix aliases from config (zsh-style: extension -> command)
        if (self.config.aliases.suffix) |suffix_aliases| {
            for (suffix_aliases) |suffix_entry| {
                const ext_copy = try self.allocator.dupe(u8, suffix_entry.extension);
                const cmd_copy = try self.allocator.dupe(u8, suffix_entry.command);
                try self.suffix_aliases.put(ext_copy, cmd_copy);
            }
        }
    }

    /// Check if config file has changed and reload if needed (hot-reload)
    pub fn checkConfigHotReload(self: *Shell) void {
        // Only check if hot-reload is enabled in config
        if (!self.config.hot_reload) return;

        // Only check if we have a config file to watch
        if (self.config_source.source_type == .default) return;

        // Get current mtime
        const current_mtime = getConfigMtime(self.config_source.path);
        if (current_mtime == 0) return; // File doesn't exist or error

        // Check if file has changed
        if (current_mtime != self.config_last_mtime) {
            // Reload config
            const result = config_loader.loadConfigWithSource(self.allocator) catch return;

            // Update config
            self.config = result.config;
            self.config_source = result.source;
            self.config_last_mtime = current_mtime;

            // Reload aliases
            self.loadAliasesFromConfig() catch {};

            // Notify user (only in interactive mode)
            if (self.is_interactive) {
                IO.print("\n[Config reloaded]\n", .{}) catch {};
            }
        }
    }

    /// Save history to file
    fn saveHistory(self: *Shell) !void {
        try History.save(self.history[0..self.history_max], self.history_file_path);
    }

    /// Append a single command to history file (incremental append)
    fn appendToHistoryFile(self: *Shell, command: []const u8) !void {
        try History.appendToFile(self.history_file_path, command);
    }

    /// Expand aliases in command chain with circular reference detection
    pub fn expandAliases(self: *Shell, chain: *types.CommandChain) !void {
        try shell_mod.expandAliases(self, chain);
    }

    /// Resolve nameref: follow nameref chain to get the actual variable name
    /// Returns the final variable name after following any nameref references
    /// Max depth of 10 to prevent infinite loops
    pub fn resolveNameref(self: *Shell, name: []const u8) []const u8 {
        return shell_mod.resolveNameref(self, name);
    }

    pub fn getVariableValue(self: *Shell, name: []const u8) ?[]const u8 {
        return shell_mod.getVariableValue(self, name);
    }

    pub fn setVariableValue(self: *Shell, name: []const u8, value: []const u8) !void {
        try shell_mod.setVariableValue(self, name, value);
    }

    /// Builtin: trap - handle signals and special events
    fn builtinTrap(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.print("den: trap: full signal handling not yet implemented\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // Stub - full implementation would register signal handlers
        try IO.print("den: trap: registering handler for signals (stub)\n", .{});
        self.last_exit_code = 0;
    }
};

/// Tab completion function for line editor
/// Callback to refresh the prompt (e.g., when Cmd+K clears screen)
/// Uses the shell's full prompt renderer for consistent display
fn refreshPromptCallback(editor: *LineEditor) !void {
    const shell_ptr: *Shell = @ptrCast(@alignCast(editor.user_data orelse return));

    // Use the shell's full prompt renderer
    const new_prompt = try shell_ptr.getPromptString();

    // Free the old prompt and set the new one
    editor.allocator.free(editor.prompt);
    editor.prompt = new_prompt;
}

test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
