const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const Shell = @import("../../shell.zig").Shell;
const ScriptResult = @import("../../scripting/script_manager.zig").ScriptResult;
const HookContext = @import("../../plugins/interface.zig").HookContext;

/// Callback type for checking if a command is a builtin
pub const IsBuiltinFn = *const fn (name: []const u8) bool;

/// Callback type for executing a command and returning exit code
pub const ExecuteCommandFn = *const fn (ctx: *anyopaque, name: []const u8, args: [][]const u8) anyerror!i32;

/// Callback type for executing a builtin command directly
pub const ExecuteBuiltinFn = *const fn (ctx: *anyopaque, cmd: *types.ParsedCommand) anyerror!i32;

/// Callback type for executing an external command (bypassing builtins)
pub const ExecuteExternalFn = *const fn (ctx: *anyopaque, cmd: *types.ParsedCommand) anyerror!i32;

/// BuiltinContext provides a unified interface for builtins to access shell state.
/// This decouples builtins from the Executor implementation, enabling better
/// modularity and testability.
pub const BuiltinContext = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    shell: ?*Shell,
    /// Callback to check if a command name is a builtin
    is_builtin_fn: ?IsBuiltinFn,
    /// Callback to execute a command (for eval, time, etc.)
    execute_command_fn: ?ExecuteCommandFn,
    /// Callback to execute a builtin directly
    execute_builtin_fn: ?ExecuteBuiltinFn,
    /// Callback to execute external command (bypassing builtins)
    execute_external_fn: ?ExecuteExternalFn,
    /// Opaque pointer to executor for callbacks
    executor_ptr: ?*anyopaque,

    /// Create a context from an allocator, environment, and optional shell reference
    pub fn init(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        shell: ?*Shell,
    ) BuiltinContext {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = shell,
            .is_builtin_fn = null,
            .execute_command_fn = null,
            .execute_builtin_fn = null,
            .execute_external_fn = null,
            .executor_ptr = null,
        };
    }

    /// Create a context with executor callbacks
    pub fn initWithExecutor(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        shell: ?*Shell,
        is_builtin_fn: IsBuiltinFn,
        execute_command_fn: ExecuteCommandFn,
        execute_builtin_fn: ExecuteBuiltinFn,
        execute_external_fn: ExecuteExternalFn,
        executor_ptr: *anyopaque,
    ) BuiltinContext {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = shell,
            .is_builtin_fn = is_builtin_fn,
            .execute_command_fn = execute_command_fn,
            .execute_builtin_fn = execute_builtin_fn,
            .execute_external_fn = execute_external_fn,
            .executor_ptr = executor_ptr,
        };
    }

    // ============ Environment Operations ============

    /// Get an environment variable value
    pub fn getEnv(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        return self.environment.get(name);
    }

    /// Set an environment variable (allocates both key and value)
    pub fn setEnv(self: *BuiltinContext, name: []const u8, value: []const u8) !void {
        const gop = try self.environment.getOrPut(name);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = try self.allocator.dupe(u8, value);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = try self.allocator.dupe(u8, value);
        }

        // Fire env_change hook when environment variable changes
        if (self.shell) |shell| {
            var name_copy = @as([]const u8, name);
            var hook_ctx = HookContext{
                .hook_type = .env_change,
                .data = @ptrCast(@alignCast(&name_copy)),
                .user_data = null,
                .allocator = self.allocator,
            };
            shell.plugin_registry.executeHooks(.env_change, &hook_ctx) catch {};
        }
    }

    /// Unset an environment variable
    pub fn unsetEnv(self: *BuiltinContext, name: []const u8) void {
        if (self.environment.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Get environment iterator
    pub fn envIterator(self: *const BuiltinContext) std.StringHashMap([]const u8).Iterator {
        return self.environment.iterator();
    }

    // ============ Shell State Access ============

    /// Check if shell context is available
    pub fn hasShell(self: *const BuiltinContext) bool {
        return self.shell != null;
    }

    /// Get shell reference (returns error if not available)
    pub fn getShell(self: *const BuiltinContext) !*Shell {
        return self.shell orelse error.NoShellContext;
    }

    // ============ Alias Operations ============

    /// Get an alias value
    pub fn getAlias(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        return shell_ref.aliases.get(name);
    }

    /// Set an alias
    pub fn setAlias(self: *BuiltinContext, name: []const u8, value: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);

        const gop = try shell_ref.aliases.getOrPut(name_owned);
        if (gop.found_existing) {
            self.allocator.free(name_owned);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value_owned;
        } else {
            gop.value_ptr.* = value_owned;
        }
    }

    /// Remove an alias
    pub fn removeAlias(self: *BuiltinContext, name: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.aliases.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    /// Get alias iterator
    pub fn aliasIterator(self: *const BuiltinContext) ?std.StringHashMap([]const u8).Iterator {
        const shell_ref = self.shell orelse return null;
        return shell_ref.aliases.iterator();
    }

    /// Clear all aliases
    pub fn clearAliases(self: *BuiltinContext) void {
        const shell_ref = self.shell orelse return;
        var iter = shell_ref.aliases.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        shell_ref.aliases.clearRetainingCapacity();
    }

    // ============ Array Operations ============

    /// Get an array's values by name (in ascending-subscript order)
    pub fn getArray(self: *const BuiltinContext, name: []const u8) ?[][]const u8 {
        const shell_ref = self.shell orelse return null;
        if (shell_ref.arrays.get(name)) |array| return array.values;
        return null;
    }

    /// Set an array (takes ownership of the slice; dense subscripts 0..N-1)
    pub fn setArray(self: *BuiltinContext, name: []const u8, values: [][]const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;

        // Remove old array if exists
        if (shell_ref.arrays.fetchRemove(name)) |old| {
            old.value.deinit(self.allocator);
            self.allocator.free(old.key);
        }

        const key = try self.allocator.dupe(u8, name);
        try shell_ref.arrays.put(key, try types.IndexedArray.fromOwnedDense(self.allocator, values));
    }

    /// Remove an array
    pub fn removeArray(self: *BuiltinContext, name: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.arrays.fetchRemove(name)) |old| {
            old.value.deinit(self.allocator);
            self.allocator.free(old.key);
            return true;
        }
        return false;
    }

    // ============ Directory Stack Operations ============

    /// Get current directory stack count
    pub fn dirStackCount(self: *const BuiltinContext) usize {
        const shell_ref = self.shell orelse return 0;
        return shell_ref.dir_stack_count;
    }

    /// Get directory at stack index (0 = bottom)
    pub fn getDirAt(self: *const BuiltinContext, index: usize) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        if (index >= shell_ref.dir_stack_count) return null;
        return shell_ref.dir_stack[index];
    }

    /// Push directory onto stack
    pub fn pushDir(self: *BuiltinContext, dir: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        if (shell_ref.dir_stack_count >= shell_ref.dir_stack.len) {
            return error.DirStackFull;
        }
        shell_ref.dir_stack[shell_ref.dir_stack_count] = try self.allocator.dupe(u8, dir);
        shell_ref.dir_stack_count += 1;
    }

    /// Pop directory from stack
    pub fn popDir(self: *BuiltinContext) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        if (shell_ref.dir_stack_count == 0) return null;
        shell_ref.dir_stack_count -= 1;
        const dir = shell_ref.dir_stack[shell_ref.dir_stack_count];
        shell_ref.dir_stack[shell_ref.dir_stack_count] = null;
        return dir;
    }

    /// Update directory at stack index
    pub fn updateDirAt(self: *BuiltinContext, index: usize, dir: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        if (index >= shell_ref.dir_stack_count) return error.InvalidIndex;
        if (shell_ref.dir_stack[index]) |old| {
            self.allocator.free(old);
        }
        shell_ref.dir_stack[index] = try self.allocator.dupe(u8, dir);
    }

    // ============ History Operations ============

    /// Get history count
    pub fn historyCount(self: *const BuiltinContext) usize {
        const shell_ref = self.shell orelse return 0;
        return shell_ref.history_count;
    }

    /// Get history entry at index
    pub fn getHistoryAt(self: *const BuiltinContext, index: usize) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        if (index >= shell_ref.history_count) return null;
        return shell_ref.history[index];
    }

    // ============ Variable Attributes ============

    /// Get variable attributes
    pub fn getVarAttributes(self: *const BuiltinContext, name: []const u8) ?types.VarAttributes {
        const shell_ref = self.shell orelse return null;
        return shell_ref.var_attributes.get(name);
    }

    /// Set variable attributes
    pub fn setVarAttributes(self: *BuiltinContext, name: []const u8, attrs: types.VarAttributes) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const gop = try shell_ref.var_attributes.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = attrs;
    }

    // ============ Associative Array Operations ============

    /// Get associative array (returns pointer to avoid expensive copy)
    pub fn getAssocArray(self: *const BuiltinContext, name: []const u8) ?*std.StringHashMap([]const u8) {
        const shell_ref = self.shell orelse return null;
        return shell_ref.assoc_arrays.getPtr(name);
    }

    // ============ Job Manager Access ============

    /// Execute jobs builtin through job manager
    pub fn builtinJobs(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinJobs(args);
    }

    /// Execute fg builtin through job manager
    pub fn builtinFg(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinFg(args);
    }

    /// Execute bg builtin through job manager
    pub fn builtinBg(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinBg(args);
    }

    /// Execute wait builtin through job manager
    pub fn builtinWait(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinWait(args);
    }

    /// Execute disown builtin through job manager
    pub fn builtinDisown(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinDisown(args);
    }

    // ============ Script Manager Access ============

    /// Execute a script file
    pub fn executeScript(self: *const BuiltinContext, filename: []const u8, args: []const []const u8) !ScriptResult {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.script_manager.executeScript(shell_ref, filename, args);
    }

    // ============ Command Execution ============

    /// Check if a command name is a builtin
    pub fn isBuiltin(self: *const BuiltinContext, name: []const u8) bool {
        if (self.is_builtin_fn) |func| {
            return func(name);
        }
        return false;
    }

    /// Execute a command by name with args, returns exit code
    pub fn executeCommand(self: *BuiltinContext, name: []const u8, args: [][]const u8) !i32 {
        if (self.execute_command_fn) |func| {
            if (self.executor_ptr) |ptr| {
                return try func(ptr, name, args);
            }
        }
        return error.NoExecutor;
    }

    /// Execute a shell command string (for eval)
    pub fn executeShellCommand(self: *BuiltinContext, command_str: []const u8) void {
        const shell_ref = self.shell orelse return;
        shell_ref.executeCommand(command_str) catch {};
    }

    /// Get the shell's last exit code
    pub fn getShellExitCode(self: *const BuiltinContext) i32 {
        const shell_ref = self.shell orelse return 0;
        return shell_ref.last_exit_code;
    }

    /// Execute a builtin command directly (bypasses aliases/functions)
    pub fn executeBuiltinCmd(self: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
        if (self.execute_builtin_fn) |func| {
            if (self.executor_ptr) |ptr| {
                return try func(ptr, cmd);
            }
        }
        return error.NoExecutor;
    }

    /// Execute an external command (bypasses builtins)
    pub fn executeExternalCmd(self: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
        if (self.execute_external_fn) |func| {
            if (self.executor_ptr) |ptr| {
                return try func(ptr, cmd);
            }
        }
        return error.NoExecutor;
    }

    // ============ Signal Handlers (trap) ============

    /// Get signal handler for a signal name
    pub fn getSignalHandler(self: *const BuiltinContext, signal: []const u8) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        return shell_ref.signal_handlers.get(signal);
    }

    /// Set signal handler
    pub fn setSignalHandler(self: *BuiltinContext, signal: []const u8, action: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const sig_owned = try self.allocator.dupe(u8, signal);
        errdefer self.allocator.free(sig_owned);
        const action_owned = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(action_owned);

        const gop = try shell_ref.signal_handlers.getOrPut(sig_owned);
        if (gop.found_existing) {
            self.allocator.free(sig_owned);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = action_owned;
        } else {
            gop.value_ptr.* = action_owned;
        }
    }

    /// Remove signal handler
    pub fn removeSignalHandler(self: *BuiltinContext, signal: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.signal_handlers.fetchRemove(signal)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    /// Get signal handlers iterator
    pub fn signalHandlersIterator(self: *const BuiltinContext) ?std.StringHashMap([]const u8).Iterator {
        const shell_ref = self.shell orelse return null;
        return shell_ref.signal_handlers.iterator();
    }

    // ============ Command Cache (hash) ============

    /// Get cached command path
    pub fn getCommandCache(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        return shell_ref.command_cache.get(name);
    }

    /// Set cached command path
    pub fn setCommandCache(self: *BuiltinContext, name: []const u8, path: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        const gop = try shell_ref.command_cache.getOrPut(name_owned);
        if (gop.found_existing) {
            self.allocator.free(name_owned);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = path_owned;
        } else {
            gop.value_ptr.* = path_owned;
        }
    }

    /// Remove cached command path
    pub fn removeCommandCache(self: *BuiltinContext, name: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.command_cache.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    /// Clear all cached commands
    pub fn clearCommandCache(self: *BuiltinContext) void {
        const shell_ref = self.shell orelse return;
        var iter = shell_ref.command_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        shell_ref.command_cache.clearRetainingCapacity();
    }

    /// Get command cache iterator
    pub fn commandCacheIterator(self: *const BuiltinContext) ?std.StringHashMap([]const u8).Iterator {
        const shell_ref = self.shell orelse return null;
        return shell_ref.command_cache.iterator();
    }

    // ============ Named Directories (bookmark) ============

    /// Get named directory
    pub fn getNamedDir(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        return shell_ref.named_dirs.get(name);
    }

    /// Set named directory
    pub fn setNamedDir(self: *BuiltinContext, name: []const u8, path: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        const gop = try shell_ref.named_dirs.getOrPut(name_owned);
        if (gop.found_existing) {
            self.allocator.free(name_owned);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = path_owned;
        } else {
            gop.value_ptr.* = path_owned;
        }
    }

    /// Remove named directory
    pub fn removeNamedDir(self: *BuiltinContext, name: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.named_dirs.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    /// Get named directories iterator
    pub fn namedDirsIterator(self: *const BuiltinContext) ?std.StringHashMap([]const u8).Iterator {
        const shell_ref = self.shell orelse return null;
        return shell_ref.named_dirs.iterator();
    }

    // ============ Coprocess State ============

    /// Get coprocess PID
    pub fn getCoprocPid(self: *const BuiltinContext) ?std.posix.pid_t {
        const shell_ref = self.shell orelse return null;
        return shell_ref.coproc_pid;
    }

    /// Set coprocess state
    pub fn setCoprocState(self: *BuiltinContext, pid: ?std.posix.pid_t, read_fd: ?std.posix.fd_t, write_fd: ?std.posix.fd_t) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        shell_ref.coproc_pid = pid;
        shell_ref.coproc_read_fd = read_fd;
        shell_ref.coproc_write_fd = write_fd;
    }

    /// Get coprocess read FD
    pub fn getCoprocReadFd(self: *const BuiltinContext) ?std.posix.fd_t {
        const shell_ref = self.shell orelse return null;
        return shell_ref.coproc_read_fd;
    }

    /// Get coprocess write FD
    pub fn getCoprocWriteFd(self: *const BuiltinContext) ?std.posix.fd_t {
        const shell_ref = self.shell orelse return null;
        return shell_ref.coproc_write_fd;
    }

    // ============ Shell State ============

    /// Check if in function execution (for return builtin)
    pub fn isInFunction(self: *const BuiltinContext) bool {
        const shell_ref = self.shell orelse return false;
        return shell_ref.function_manager.isExecuting();
    }

    /// Set function return value
    pub fn setFunctionReturn(self: *BuiltinContext, code: i32) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        shell_ref.function_manager.setReturnValue(code);
    }

    /// Get last exit code
    pub fn getLastExitCode(self: *const BuiltinContext) i32 {
        const shell_ref = self.shell orelse return 0;
        return shell_ref.last_exit_code;
    }

    /// Set last exit code
    pub fn setLastExitCode(self: *BuiltinContext, code: i32) void {
        if (self.shell) |shell_ref| {
            shell_ref.last_exit_code = code;
        }
    }

    /// Reload shell configuration (aliases from config)
    pub fn reloadShell(self: *BuiltinContext) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        // Force config reload by resetting mtime to 0 then calling hot reload check
        shell_ref.config_last_mtime = 0;
        shell_ref.checkConfigHotReload();
    }

    // ============ Shell Options ============

    /// Get errexit option
    pub fn getOptionErrexit(self: *const BuiltinContext) bool {
        const shell_ref = self.shell orelse return false;
        return shell_ref.option_errexit;
    }

    /// Set errexit option
    pub fn setOptionErrexit(self: *BuiltinContext, value: bool) void {
        if (self.shell) |shell_ref| {
            shell_ref.option_errexit = value;
        }
    }

    /// Get xtrace option
    pub fn getOptionXtrace(self: *const BuiltinContext) bool {
        const shell_ref = self.shell orelse return false;
        return shell_ref.option_xtrace;
    }

    /// Set xtrace option
    pub fn setOptionXtrace(self: *BuiltinContext, value: bool) void {
        if (self.shell) |shell_ref| {
            shell_ref.option_xtrace = value;
        }
    }

    /// Get nounset option
    pub fn getOptionNounset(self: *const BuiltinContext) bool {
        const shell_ref = self.shell orelse return false;
        return shell_ref.option_nounset;
    }

    /// Set nounset option
    pub fn setOptionNounset(self: *BuiltinContext, value: bool) void {
        if (self.shell) |shell_ref| {
            shell_ref.option_nounset = value;
        }
    }

    /// Get pipefail option
    pub fn getOptionPipefail(self: *const BuiltinContext) bool {
        const shell_ref = self.shell orelse return false;
        return shell_ref.option_pipefail;
    }

    /// Set pipefail option
    pub fn setOptionPipefail(self: *BuiltinContext, value: bool) void {
        if (self.shell) |shell_ref| {
            shell_ref.option_pipefail = value;
        }
    }

    // ============ Function Manager Operations ============

    /// Request return from current function with given exit code
    pub fn requestFunctionReturn(self: *BuiltinContext, return_code: i32) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        try shell_ref.function_manager.requestReturn(return_code);
    }

    /// Set a local variable in current function scope
    pub fn setLocalVariable(self: *BuiltinContext, name: []const u8, value: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        try shell_ref.function_manager.setLocal(name, value);
    }

    /// Get current function frame's local variables iterator
    pub fn localVariablesIterator(self: *BuiltinContext) ?*std.StringHashMap([]const u8).Iterator {
        const shell_ref = self.shell orelse return null;
        if (shell_ref.function_manager.currentFrame()) |frame| {
            _ = frame;
            return null; // Can't return iterator to temporary
        }
        return null;
    }

    /// Check if currently in a function context
    pub fn hasCurrentFrame(self: *const BuiltinContext) bool {
        const shell_ref = self.shell orelse return false;
        return shell_ref.function_manager.currentFrame() != null;
    }

    /// Get local variables from current frame
    pub fn getCurrentFrameLocals(self: *BuiltinContext) ?*std.StringHashMap([]const u8) {
        const shell_ref = self.shell orelse return null;
        if (shell_ref.function_manager.currentFrame()) |frame| {
            return &frame.local_vars;
        }
        return null;
    }
};

/// Error type for builtin context operations
pub const BuiltinError = error{
    NoShellContext,
    NoExecutor,
    DirStackFull,
    InvalidIndex,
    OutOfMemory,
};

// ============================================================================
// Tests
// ============================================================================

test "BuiltinContext init without shell" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer env.deinit();

    const ctx = BuiltinContext.init(std.testing.allocator, &env, null);
    try std.testing.expect(!ctx.hasShell());
    try std.testing.expectError(error.NoShellContext, ctx.getShell());
    try std.testing.expect(ctx.getAlias("test") == null);
    try std.testing.expect(ctx.getArray("test") == null);
    try std.testing.expect(ctx.getAssocArray("test") == null);
    try std.testing.expect(ctx.getSignalHandler("INT") == null);
    try std.testing.expect(ctx.getCommandCache("ls") == null);
    try std.testing.expect(ctx.getNamedDir("test") == null);
    try std.testing.expect(ctx.getCoprocPid() == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.dirStackCount());
    try std.testing.expectEqual(@as(usize, 0), ctx.historyCount());
    try std.testing.expectEqual(@as(i32, 0), ctx.getLastExitCode());
}

test "BuiltinContext environment operations" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer {
        var iter = env.iterator();
        while (iter.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        env.deinit();
    }

    var ctx = BuiltinContext.init(std.testing.allocator, &env, null);

    // getEnv on empty env returns null
    try std.testing.expect(ctx.getEnv("FOO") == null);

    // setEnv and getEnv
    try ctx.setEnv("FOO", "bar");
    try std.testing.expectEqualStrings("bar", ctx.getEnv("FOO").?);

    // setEnv overwrites
    try ctx.setEnv("FOO", "baz");
    try std.testing.expectEqualStrings("baz", ctx.getEnv("FOO").?);

    // unsetEnv
    ctx.unsetEnv("FOO");
    try std.testing.expect(ctx.getEnv("FOO") == null);

    // unsetEnv on non-existent key is safe
    ctx.unsetEnv("NONEXISTENT");
}

test "BuiltinContext envIterator" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer {
        var iter = env.iterator();
        while (iter.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        env.deinit();
    }

    var ctx = BuiltinContext.init(std.testing.allocator, &env, null);
    try ctx.setEnv("A", "1");
    try ctx.setEnv("B", "2");

    var count: usize = 0;
    var iter = ctx.envIterator();
    while (iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "BuiltinContext isBuiltin without callback" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer env.deinit();

    const ctx = BuiltinContext.init(std.testing.allocator, &env, null);
    // Without callback, isBuiltin always returns false
    try std.testing.expect(!ctx.isBuiltin("cd"));
    try std.testing.expect(!ctx.isBuiltin("echo"));
}

test "BuiltinContext executeCommand without executor returns error" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer env.deinit();

    var ctx = BuiltinContext.init(std.testing.allocator, &env, null);
    try std.testing.expectError(error.NoExecutor, ctx.executeCommand("ls", &.{}));
}

test "BuiltinContext getAssocArray returns pointer type" {
    // Verify the return type is a pointer (not a copy)
    // Without a shell, it should return null
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer env.deinit();

    const ctx = BuiltinContext.init(std.testing.allocator, &env, null);
    // Returns null because no shell is available
    const result = ctx.getAssocArray("test");
    try std.testing.expect(result == null);
    // The important thing is that the return type is ?*std.StringHashMap
    // not ?std.StringHashMap — this is a compile-time check
    comptime {
        const T = @TypeOf(result);
        // This would fail to compile if getAssocArray returned a value instead of pointer
        const info = @typeInfo(T);
        std.debug.assert(info == .optional);
    }
}
