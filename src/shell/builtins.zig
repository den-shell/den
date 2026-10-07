//! Shell Builtin Commands Module
//!
//! This module contains implementations of shell builtin commands.
//! All functions take a Shell pointer and a ParsedCommand pointer,
//! allowing them to access and modify shell state as needed.
//!
//! Builtins are organized by category:
//! - History: history
//! - Aliases: alias, unalias
//! - Type info: type, which, help
//! - Directory: pushd, popd, dirs
//! - I/O: printf, read, echo
//! - Control: source, eval, command, shift
//! - Path utils: basename, dirname, realpath
//! - System info: uname, whoami, umask
//! - Timing: time, sleep
//! - Variables: local, declare, readonly, let, shopt
//! - Script control: return, break, continue
//! - Completion: complete, compgen
//! - Testing: test
//! - Advanced: mapfile, caller, enable, hash

const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const History = @import("../history/history.zig").History;
const Completion = @import("../utils/completion.zig").Completion;
const CompletionSpec = @import("../utils/completion_registry.zig").CompletionSpec;

// Forward declaration for Shell type - we import it at comptime
const Shell = @import("../shell.zig").Shell;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

// ============================================
// History Builtins
// ============================================

/// Builtin: history - show command history
pub fn builtinHistory(shell: *Shell, cmd: *types.ParsedCommand) !void {
    try History.printBuiltin(shell.history[0..shell.history_max], shell.history_count, cmd);
}

// ============================================
// Alias Builtins
// ============================================

/// Builtin: alias - define or list aliases
/// Supports -s flag for suffix aliases (zsh-style): alias -s ts='bun'
pub fn builtinAlias(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Success unless a lookup below fails; the dispatcher no longer forces this.
    shell.last_exit_code = 0;
    // Check for -s flag (suffix alias)
    var is_suffix_alias = false;
    var args_start: usize = 0;
    if (cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-s")) {
        is_suffix_alias = true;
        args_start = 1;
    }

    const effective_args = cmd.args[args_start..];

    if (is_suffix_alias) {
        // Handle suffix aliases
        if (effective_args.len == 0) {
            // List all suffix aliases
            var iter = shell.suffix_aliases.iterator();
            while (iter.next()) |entry| {
                try IO.print("alias -s {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        } else {
            // Parse suffix alias definition: extension=command
            for (effective_args) |arg| {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                    const extension = arg[0..eq_pos];
                    const value = arg[eq_pos + 1 ..];

                    // Remove quotes if present
                    const clean_value = if (value.len >= 2 and
                        ((value[0] == '\'' and value[value.len - 1] == '\'') or
                            (value[0] == '"' and value[value.len - 1] == '"')))
                        value[1 .. value.len - 1]
                    else
                        value;

                    // Store suffix alias
                    const value_copy = try shell.allocator.dupe(u8, clean_value);

                    // Free old key and value if exists
                    if (shell.suffix_aliases.fetchRemove(extension)) |old_kv| {
                        shell.allocator.free(old_kv.key);
                        shell.allocator.free(old_kv.value);
                    }

                    const ext_copy = try shell.allocator.dupe(u8, extension);
                    try shell.suffix_aliases.put(ext_copy, value_copy);
                } else {
                    // Show specific suffix alias
                    if (shell.suffix_aliases.get(arg)) |value| {
                        try IO.print("alias -s {s}='{s}'\n", .{ arg, value });
                    } else {
                        try IO.eprint("den: alias: suffix alias {s}: not found\n", .{arg});
                    }
                }
            }
        }
    } else {
        // Handle regular aliases
        if (effective_args.len == 0) {
            // List all aliases
            var iter = shell.aliases.iterator();
            while (iter.next()) |entry| {
                try IO.print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        } else {
            // Parse alias definition: name=value
            for (effective_args) |arg| {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                    const name = arg[0..eq_pos];
                    const value = arg[eq_pos + 1 ..];

                    // Remove quotes if present
                    const clean_value = if (value.len >= 2 and
                        ((value[0] == '\'' and value[value.len - 1] == '\'') or
                            (value[0] == '"' and value[value.len - 1] == '"')))
                        value[1 .. value.len - 1]
                    else
                        value;

                    // Store alias
                    const value_copy = try shell.allocator.dupe(u8, clean_value);

                    // Free old key and value if exists
                    if (shell.aliases.fetchRemove(name)) |old_kv| {
                        shell.allocator.free(old_kv.key);
                        shell.allocator.free(old_kv.value);
                    }

                    const name_copy = try shell.allocator.dupe(u8, name);
                    try shell.aliases.put(name_copy, value_copy);
                } else {
                    // Show specific alias
                    if (shell.aliases.get(arg)) |value| {
                        try IO.print("alias {s}='{s}'\n", .{ arg, value });
                    } else {
                        try IO.eprint("den: alias: {s}: not found\n", .{arg});
                        // Reported and then thrown away by the dispatcher, so
                        // `alias foo >/dev/null || ...` never took its branch.
                        shell.last_exit_code = 1;
                    }
                }
            }
        }
    }
}

/// Builtin: unalias - remove alias
/// Supports -s flag for suffix aliases: unalias -s ts
pub fn builtinUnalias(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: unalias: usage: unalias [-s] name [name ...]\n", .{});
        return;
    }

    // Check for -s flag (suffix alias)
    var is_suffix_alias = false;
    var args_start: usize = 0;
    if (cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-s")) {
        is_suffix_alias = true;
        args_start = 1;
    }

    const effective_args = cmd.args[args_start..];

    if (effective_args.len == 0) {
        try IO.eprint("den: unalias: usage: unalias [-s] name [name ...]\n", .{});
        return;
    }

    // A name that was not an alias is a failure, which den reported and then
    // returned 0 for -- so `unalias foo || echo gone` never took its branch.
    var missing = false;

    if (is_suffix_alias) {
        for (effective_args) |extension| {
            if (shell.suffix_aliases.fetchRemove(extension)) |kv| {
                shell.allocator.free(kv.key);
                shell.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: suffix alias {s}: not found\n", .{extension});
                missing = true;
            }
        }
    } else {
        for (effective_args) |name| {
            if (shell.aliases.fetchRemove(name)) |kv| {
                shell.allocator.free(kv.key);
                shell.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: {s}: not found\n", .{name});
                missing = true;
            }
        }
    }

    shell.last_exit_code = if (missing) 1 else 0;
}

// ============================================
// Type/Which Builtins
// ============================================

/// Builtin: type - identify command type
pub fn builtinType(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: type: usage: type name [name ...]\n", .{});
        return;
    }

    const builtin_dispatch = @import("builtin_dispatch.zig");
    const executor_mod = @import("../executor/mod.zig");

    for (cmd.args) |name| {
        // Check if it's an alias
        if (shell.aliases.get(name)) |alias_value| {
            try IO.print("{s} is aliased to `{s}'\n", .{ name, alias_value });
            continue;
        }

        // Check if it's a suffix alias (looks like a file with matching extension)
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot_pos| {
            if (dot_pos < name.len - 1) {
                const extension = name[dot_pos + 1 ..];
                if (shell.suffix_aliases.get(extension)) |suffix_cmd| {
                    // Check if file exists
                    std.Io.Dir.cwd().access(std.Options.debug_io, name, .{}) catch {
                        // File doesn't exist, continue to other checks
                        try IO.print("{s} would use suffix alias (if file existed): {s} {s}\n", .{ name, suffix_cmd, name });
                        continue;
                    };
                    try IO.print("{s} is handled by suffix alias: {s} {s}\n", .{ name, suffix_cmd, name });
                    continue;
                }
            }
        }

        // Check if it's a builtin (both shell-level and executor-level)
        if (builtin_dispatch.isShellBuiltin(name) or executor_mod.Executor.isBuiltinName(name)) {
            try IO.print("{s} is a shell builtin\n", .{name});
            continue;
        }

        // Check if it's a function
        if (shell.function_manager.getFunction(name) != null) {
            try IO.print("{s} is a function\n", .{name});
            continue;
        }

        // Check if it's an external command
        if (shell.command_cache.get(name)) |path| {
            try IO.print("{s} is {s}\n", .{ name, path });
            continue;
        }

        // Search PATH
        const path_str = shell.environment.get("PATH") orelse getenv("PATH") orelse "";
        var path_iter = std.mem.tokenizeScalar(u8, path_str, ':');
        var found = false;

        while (path_iter.next()) |dir| {
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;

            std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch continue;

            try IO.print("{s} is {s}\n", .{ name, full_path });
            found = true;
            break;
        }

        if (!found) {
            try IO.eprint("den: type: {s}: not found\n", .{name});
        }
    }
}

/// Builtin: which - locate command in PATH
pub fn builtinWhich(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: which: usage: which name [name ...]\n", .{});
        return;
    }

    const builtin_dispatch = @import("builtin_dispatch.zig");
    const executor_mod = @import("../executor/mod.zig");
    const path_str = shell.environment.get("PATH") orelse getenv("PATH") orelse "";

    for (cmd.args) |name| {
        // A name containing '/' is already a path (e.g. `which $SHELL`): report it
        // directly if it exists, rather than fruitlessly searching PATH for it.
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            if (std.Io.Dir.cwd().access(std.Options.debug_io, name, .{})) |_| {
                try IO.print("{s}\n", .{name});
            } else |_| {
                try IO.eprint("den: which: {s}: no such file or directory\n", .{name});
                shell.last_exit_code = 1;
            }
            continue;
        }

        // Aliases, functions and builtins shadow PATH lookups, so report them
        // first — matching zsh's `which`.
        if (shell.aliases.get(name)) |alias_value| {
            try IO.print("{s}: aliased to {s}\n", .{ name, alias_value });
            continue;
        }
        if (shell.function_manager.getFunction(name) != null) {
            try IO.print("{s}: function\n", .{name});
            continue;
        }
        if (builtin_dispatch.isShellBuiltin(name) or executor_mod.Executor.isBuiltinName(name)) {
            try IO.print("{s}: shell built-in command\n", .{name});
            continue;
        }

        var found = false;
        var path_iter = std.mem.tokenizeScalar(u8, path_str, ':');

        while (path_iter.next()) |dir| {
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;

            std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch continue;

            try IO.print("{s}\n", .{full_path});
            found = true;
            break;
        }

        if (!found) {
            try IO.eprint("den: which: no {s} in ({s})\n", .{ name, path_str });
            shell.last_exit_code = 1;
        }
    }
}

// ============================================
// Help Builtin
// ============================================

/// Builtin: help - show available builtins
pub fn builtinHelp(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // `help <topic>` has per-command entries in the executor's help system, and
    // they were unreachable: this builtin wins the dispatch and ignored its
    // argument, so `help cd` printed the whole list.
    if (cmd.args.len > 0) {
        const help_system = @import("../executor/builtins/help_system.zig");
        if (help_system.hasTopic(cmd.args[0])) {
            shell.last_exit_code = help_system.helpCmd(shell.allocator, cmd) catch 1;
            return;
        }
        // No entry for that name: fall through to the full listing, which is what
        // a bare `help` shows and what this did for every argument before.
    }

    try IO.print("Den Shell - Built-in Commands\n\n", .{});
    try IO.print("Core Commands:\n", .{});
    try IO.print("  exit              Exit the shell\n", .{});
    try IO.print("  help              Show this help message\n", .{});
    try IO.print("  history [n]       Show command history\n", .{});
    try IO.print("\nFile System:\n", .{});
    try IO.print("  cd [dir]          Change directory\n", .{});
    try IO.print("  pwd               Print working directory\n", .{});
    try IO.print("  pushd [dir]       Push directory to stack and cd\n", .{});
    try IO.print("  popd              Pop directory from stack and cd\n", .{});
    try IO.print("  dirs              Show directory stack\n", .{});
    try IO.print("\nEnvironment:\n", .{});
    try IO.print("  env               Show environment variables\n", .{});
    try IO.print("  export VAR=val    Set and export variable\n", .{});
    try IO.print("  set VAR=val       Set shell variable\n", .{});
    try IO.print("  unset VAR         Unset variable\n", .{});
    try IO.print("\nAliases:\n", .{});
    try IO.print("  alias [name=val]  Define or list aliases\n", .{});
    try IO.print("  unalias name      Remove alias\n", .{});
    try IO.print("\nIntrospection:\n", .{});
    try IO.print("  type name         Identify command type\n", .{});
    try IO.print("  which name        Locate command in PATH\n", .{});
    try IO.print("  complete [-c|-f] prefix  Show completions\n", .{});
    try IO.print("\nJob Control:\n", .{});
    try IO.print("  jobs              List background jobs\n", .{});
    try IO.print("  fg [job_id]       Bring job to foreground\n", .{});
    try IO.print("  bg [job_id]       Continue job in background\n", .{});
    try IO.print("\nScripting:\n", .{});
    try IO.print("  source file       Execute commands from file\n", .{});
    try IO.print("  read var          Read line into variable\n", .{});
    try IO.print("  test expr         Evaluate conditional\n", .{});
    try IO.print("  [ expr ]          Evaluate conditional\n", .{});
    try IO.print("  true              Return success (exit code 0)\n", .{});
    try IO.print("  false             Return failure (exit code 1)\n", .{});
    try IO.print("  sleep n           Pause for n seconds\n", .{});
    try IO.print("  eval args         Execute arguments as command\n", .{});
    try IO.print("  command cmd       Execute bypassing aliases\n", .{});
    try IO.print("  shift [n]         Shift positional parameters\n", .{});
    try IO.print("\nPath Utilities:\n", .{});
    try IO.print("  basename path     Extract filename from path\n", .{});
    try IO.print("  dirname path      Extract directory from path\n", .{});
    try IO.print("  realpath path     Resolve absolute path\n", .{});
    try IO.print("\nSystem Info:\n", .{});
    try IO.print("  uname [-a]        Print system information\n", .{});
    try IO.print("  whoami            Print current username\n", .{});
    try IO.print("  umask [mode]      Get/set file creation mask\n", .{});
    try IO.print("\nPerformance:\n", .{});
    try IO.print("  time command      Measure execution time\n", .{});
    try IO.print("  hash [-r] [cmd]   Command path caching\n", .{});
    try IO.print("\nOutput:\n", .{});
    try IO.print("  echo [args...]    Print arguments\n", .{});
    try IO.print("  printf fmt args   Formatted output\n", .{});
    try IO.print("  clear             Clear terminal screen\n", .{});
    try IO.print("\nScript Control:\n", .{});
    try IO.print("  return [n]        Return from function/script\n", .{});
    try IO.print("  break [n]         Exit from loop\n", .{});
    try IO.print("  continue [n]      Skip to next loop iteration\n", .{});
    try IO.print("  local VAR=val     Declare local variable\n", .{});
    try IO.print("  declare VAR=val   Declare variable with attributes\n", .{});
    try IO.print("  readonly VAR=val  Declare readonly variable\n", .{});
    try IO.print("\nJob Management:\n", .{});
    try IO.print("  kill [-s sig] pid Send signal to process/job\n", .{});
    try IO.print("  wait [pid|job]    Wait for job completion\n", .{});
    try IO.print("  disown [job]      Remove job from table\n", .{});
    try IO.print("\nAdvanced Execution:\n", .{});
    try IO.print("  exec command      Replace shell with command\n", .{});
    try IO.print("  builtin cmd       Execute builtin bypassing functions\n", .{});
    try IO.print("  trap cmd sig      Handle signals (stub)\n", .{});
    try IO.print("  getopts spec var  Parse command options (stub)\n", .{});
    try IO.print("  timeout [-s sig] [-k dur] dur cmd  Execute with timeout\n", .{});
    try IO.print("  times             Display process times\n", .{});
    try IO.print("\nLine Editing:\n", .{});
    try IO.print("  bindkey [seq wid] Bind keys to editing widgets\n", .{});
    try IO.print("  zle -N wid [fn]   Make a shell function a widget\n", .{});
    try IO.print("\nZsh Compatibility:\n", .{});
    try IO.print("  zstyle ctx style  Set or query pattern-keyed styles\n", .{});
    try IO.print("  autoload name     Define from $fpath on first use\n", .{});
    try IO.print("  add-zsh-hook h fn Run fn on chpwd/precmd/preexec/zshexit\n", .{});
    try IO.print("  compinit          Accepted; completion needs no setup\n", .{});
    try IO.print("  is-at-least ver   Compare shell versions\n", .{});
    try IO.print("\nPOSIX and bash compatibility:\n", .{});
    try IO.print("  . file [args]     Read and run a file in the current shell\n", .{});
    try IO.print("  :                 Do nothing, successfully\n", .{});
    try IO.print("  [[ expr ]]        Conditional with pattern and regex matching\n", .{});
    try IO.print("  let expr          Evaluate an arithmetic expression\n", .{});
    try IO.print("  typeset [-opts]   Declare variables and attributes (as declare)\n", .{});
    try IO.print("  mapfile var       Read lines of input into an array\n", .{});
    try IO.print("  readarray var     Read lines of input into an array (as mapfile)\n", .{});
    try IO.print("  caller [n]        Show the current call stack frame\n", .{});
    try IO.print("  enable [-a] name  Enable or disable a builtin, or list them all\n", .{});
    try IO.print("  compgen -X [pfx]  Generate completions of one kind\n", .{});
    try IO.print("  shopt [-su] opt   Set or show a bash shell option\n", .{});
    try IO.print("\nMore zsh compatibility:\n", .{});
    try IO.print("  setopt [name]     Turn on a zsh option, or list what is on\n", .{});
    try IO.print("  unsetopt name     Turn off a zsh option\n", .{});
    try IO.print("  bashcompinit      Accepted; complete and compgen are always on\n", .{});
    try IO.print("  compdef fn cmd    Accepted; completion is context-aware already\n", .{});
    try IO.print("  zmodload module   Accepted; den has no loadable modules\n", .{});
    try IO.print("  emulate [-L] sh   Accepted for sh, ksh and zsh; csh is refused\n", .{});
    try IO.print("\nFiles and searching:\n", .{});
    try IO.print("  ls [-la] [path]   List directory contents\n", .{});
    try IO.print("  tree [path]       Print a directory tree\n", .{});
    try IO.print("  find [path]       Find files by name, type, size or time\n", .{});
    try IO.print("  ft [pattern]      Fuzzy file finder\n", .{});
    try IO.print("  ifind [pattern]   Interactive file finder with fuzzy matching\n", .{});
    try IO.print("  grep [-inv] pat   Search files for a pattern\n", .{});
    try IO.print("  watch path cmd    Run a command when a file or directory changes\n", .{});
    try IO.print("\nText and data:\n", .{});
    try IO.print("  calc expression   Evaluate an arithmetic expression\n", .{});
    try IO.print("  seq [start] end   Print a sequence of numbers\n", .{});
    try IO.print("  seq-char a z      Print a sequence of characters\n", .{});
    try IO.print("  uuid              Generate a random UUID\n", .{});
    try IO.print("  base64 [-d] text  Encode or decode base64\n", .{});
    try IO.print("  encode fmt [in]   Encode as base64, hex or url\n", .{});
    try IO.print("  decode fmt [in]   Decode from base64, hex or url\n", .{});
    try IO.print("  json file         Query and format a JSON file\n", .{});
    try IO.print("  str sub [args]    String ops: trim, upcase, replace, split, ...\n", .{});
    try IO.print("  path sub [args]   Path ops: basename, dirname, join, exists, ...\n", .{});
    try IO.print("  math sub          Aggregate input: sum, avg, min, max, median, ...\n", .{});
    try IO.print("  into type         Convert input to int, float, string, bool, ...\n", .{});
    try IO.print("  detect            Split whitespace-aligned output into columns\n", .{});
    try IO.print("\nStructured data (operate on the input given; see note below):\n", .{});
    try IO.print("  from fmt          Parse json, csv, toml or yaml into a table\n", .{});
    try IO.print("  to fmt            Render as json, csv, toml or yaml (stub)\n", .{});
    try IO.print("  table             Render input as a table\n", .{});
    try IO.print("  grid              Render input as a space-separated grid\n", .{});
    try IO.print("  first [n]         Keep the first n rows (default 1)\n", .{});
    try IO.print("  last [n]          Keep the last n rows (default 1)\n", .{});
    try IO.print("  take n            Keep the first n rows (as first)\n", .{});
    try IO.print("  skip n            Drop the first n rows\n", .{});
    try IO.print("  length            Count the rows\n", .{});
    try IO.print("  reverse           Reverse the row order\n", .{});
    try IO.print("  uniq              Drop repeated rows\n", .{});
    try IO.print("  sort-by col       Sort rows by a column\n", .{});
    try IO.print("  group-by col      Group rows by a column\n", .{});
    try IO.print("  enumerate         Number the rows\n", .{});
    try IO.print("  wrap name         Wrap the input in a named column\n", .{});
    try IO.print("  append value      Add a row at the end\n", .{});
    try IO.print("  prepend value     Add a row at the start\n", .{});
    try IO.print("  rename old new    Rename a column\n", .{});
    try IO.print("  flatten           Flatten nested structure\n", .{});
    try IO.print("  transpose         Swap rows and columns\n", .{});
    try IO.print("  compact           Drop empty rows\n", .{});
    try IO.print("  generate i n ex   Produce a sequence from an expression\n", .{});
    try IO.print("  par-each cmd      Run a command for each row, in parallel\n", .{});
    try IO.print("  explore           Browse the input in an interactive view\n", .{});
    try IO.print("  select cols       Keep only the named columns\n", .{});
    try IO.print("  get field         Read one field (stub)\n", .{});
    try IO.print("  where f op v      Filter rows (stub)\n", .{});
    try IO.print("  reject col        Drop a column (stub)\n", .{});
    try IO.print("  columns           List column names (stub)\n", .{});
    try IO.print("  values            List column values (stub)\n", .{});
    try IO.print("  headers           Use the first row as headers (stub)\n", .{});
    try IO.print("\nMonitoring:\n", .{});
    try IO.print("  sys-stats         Show CPU, memory, disk and uptime\n", .{});
    try IO.print("  netstats          Show network statistics\n", .{});
    try IO.print("  net-check [host]  Check network connectivity\n", .{});
    try IO.print("  proc-monitor      Monitor running processes\n", .{});
    try IO.print("  log-tail file     Tail a log with filtering and highlighting\n", .{});
    try IO.print("  log-parse file    Parse a structured log file\n", .{});
    try IO.print("\nNetwork:\n", .{});
    try IO.print("  http verb url     Make an HTTP request\n", .{});
    try IO.print("  web url           Print the command that opens a URL\n", .{});
    try IO.print("  ip                Print how to look up your public IP (stub)\n", .{});
    try IO.print("  localip           Print how to look up your local IP (stub)\n", .{});
    try IO.print("\nWorkflow shortcuts:\n", .{});
    try IO.print("  bookmark [name]   Manage directory bookmarks\n", .{});
    try IO.print("  dotfiles cmd      Manage dotfiles\n", .{});
    try IO.print("  library cmd       Manage shell function libraries\n", .{});
    try IO.print("  hook cmd          Manage custom command hooks\n", .{});
    try IO.print("  reload            Reload the shell configuration\n", .{});
    try IO.print("  wip [message]     git add and commit with a WIP message\n", .{});
    try IO.print("  use module        Import a module's functions\n", .{});
    try IO.print("  shrug             Print a shrug\n", .{});
    try IO.print("\nmacOS helpers:\n", .{});
    try IO.print("  code [path]       Open a path in VS Code\n", .{});
    try IO.print("  pstorm [path]     Open a path in PhpStorm\n", .{});
    try IO.print("  copyssh           Copy the SSH public key to the clipboard\n", .{});
    try IO.print("  emptytrash        Empty the Trash\n", .{});
    try IO.print("  hide file...      Set the hidden attribute on files\n", .{});
    try IO.print("  show file...      Remove the hidden attribute from files\n", .{});
    try IO.print("  reloaddns         Flush the DNS cache\n", .{});
    try IO.print("\nExtras:\n", .{});
    try IO.print("  ai [prompt]       AI-assisted completions and suggestions\n", .{});
    try IO.print("  wasm cmd          Manage WebAssembly plugins\n", .{});
    try IO.print("  coproc [n] cmd    Run a command as a coprocess with two pipes\n", .{});
    try IO.print("  bench [-r n] cmd  Benchmark a command over several rounds\n", .{});
    try IO.print("  parallel cmd      Run commands in parallel (stub)\n", .{});
    try IO.print("  date [fmt]        Print or format the date\n", .{});
    try IO.print("  yes [string]      Repeat a string until stopped\n", .{});
    try IO.print("\nNote: each structured-data command works on the text it is\n", .{});
    try IO.print("given. Structure is not carried between stages of a pipeline, so\n", .{});
    try IO.print("`from json | get x` does not see the parsed table.\n", .{});

    // Counts the entries actually listed above, which is now every builtin:
    // `compgen -b` and this agree, and tests/test_builtins.zig checks it.
    try IO.print("\nTotal: 163 builtin commands available\n", .{});
    try IO.print("For more help, use 'man bash' or visit docs.den.sh\n", .{});
}

// ============================================
// Path Utility Builtins
// ============================================

/// Builtin: basename - extract filename from path
pub fn builtinBasename(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: basename: missing operand\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    const path = cmd.args[0];
    const base = std.fs.path.basename(path);

    // Handle optional suffix removal
    if (cmd.args.len > 1) {
        const suffix = cmd.args[1];
        if (std.mem.endsWith(u8, base, suffix)) {
            const trimmed = base[0 .. base.len - suffix.len];
            try IO.print("{s}\n", .{trimmed});
        } else {
            try IO.print("{s}\n", .{base});
        }
    } else {
        try IO.print("{s}\n", .{base});
    }

    shell.last_exit_code = 0;
}

/// Builtin: dirname - extract directory from path
pub fn builtinDirname(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: dirname: missing operand\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    const path = cmd.args[0];
    const dir = std.fs.path.dirname(path) orelse ".";
    try IO.print("{s}\n", .{dir});
    shell.last_exit_code = 0;
}

/// Builtin: realpath - resolve absolute path
pub fn builtinRealpath(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: realpath: missing operand\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    const path = cmd.args[0];

    // Use realpath to resolve
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved_len = std.Io.Dir.cwd().realPathFile(std.Options.debug_io, path, &buf) catch |err| {
        try IO.eprint("den: realpath: {s}: {}\n", .{ path, err });
        shell.last_exit_code = 1;
        return;
    };
    const resolved = buf[0..resolved_len];

    try IO.print("{s}\n", .{resolved});
    shell.last_exit_code = 0;
}

// ============================================
// System Info Builtins
// ============================================

/// Builtin: uname - print system information
pub fn builtinUname(shell: *Shell, cmd: *types.ParsedCommand) !void {
    const show_all = cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-a");

    const os_name = switch (@import("builtin").os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .windows => "Windows",
        else => "Unknown",
    };

    if (show_all) {
        // Get hostname
        const hostname = if (builtin.os.tag == .windows) "localhost" else blk: {
            var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            break :blk std.posix.gethostname(&hostname_buf) catch "unknown";
        };

        const arch = switch (@import("builtin").cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => "unknown",
        };

        try IO.print("{s} {s} {s}\n", .{ os_name, hostname, arch });
    } else {
        try IO.print("{s}\n", .{os_name});
    }

    shell.last_exit_code = 0;
}

/// Builtin: whoami - print current username
pub fn builtinWhoami(shell: *Shell, cmd: *types.ParsedCommand) !void {
    _ = cmd;
    const username = getenv("USER") orelse getenv("LOGNAME") orelse "unknown";
    try IO.print("{s}\n", .{username});
    shell.last_exit_code = 0;
}

/// Builtin: clear - clear terminal screen
pub fn builtinClear(shell: *Shell, cmd: *types.ParsedCommand) !void {
    _ = cmd;
    try IO.print("\x1B[2J\x1B[H", .{});
    shell.last_exit_code = 0;
}

// ============================================
// Timing Builtins
// ============================================

/// Builtin: sleep - pause for specified seconds
pub fn builtinSleep(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: sleep: missing operand\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    // Parse the interval as either an integer or a fractional number of seconds
    // (e.g. `sleep 0.3`), matching coreutils/bash.
    const arg = cmd.args[0];
    var duration_ns: u64 = 0;
    if (std.mem.indexOfScalar(u8, arg, '.') != null) {
        const secs = std.fmt.parseFloat(f64, arg) catch {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{arg});
            shell.last_exit_code = 1;
            return;
        };
        if (secs < 0) {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{arg});
            shell.last_exit_code = 1;
            return;
        }
        duration_ns = @intFromFloat(secs * 1_000_000_000.0);
    } else {
        const secs = std.fmt.parseUnsigned(u64, arg, 10) catch {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{arg});
            shell.last_exit_code = 1;
            return;
        };
        duration_ns = secs * 1_000_000_000;
    }

    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(duration_ns), .awake) catch {};
    shell.last_exit_code = 0;
}

// ============================================
// Script Control Builtins
// ============================================

/// Builtin: return - return from function or script
pub fn builtinReturn(shell: *Shell, cmd: *types.ParsedCommand) !void {
    const code = if (cmd.args.len > 0)
        std.fmt.parseInt(i32, cmd.args[0], 10) catch 0
    else
        shell.last_exit_code;

    // Check if we're inside a function
    if (shell.function_manager.currentFrame() != null) {
        // Signal return from function
        shell.function_manager.requestReturn(code) catch {
            try IO.eprint("return: can only return from a function or sourced script\n", .{});
            shell.last_exit_code = 1;
            return;
        };
    }

    // Set exit code
    shell.last_exit_code = code;
}

/// Builtin: break - exit from loop
/// Supports `break N` to break out of N nested loops
pub fn builtinBreak(shell: *Shell, cmd: *types.ParsedCommand) !void {
    const levels = if (cmd.args.len > 0)
        std.fmt.parseInt(u32, cmd.args[0], 10) catch 1
    else
        1;

    shell.last_exit_code = 0;
    // Outside any loop there is nothing to leave; sh ignores it.
    if (shell.loop_depth == 0) return;
    // Signal break to the loop with the number of levels to break, never more
    // levels than there are loops.
    shell.break_levels = @min(if (levels > 0) levels else 1, shell.loop_depth);
}

/// Builtin: continue - skip to next loop iteration
/// Supports `continue N` to continue the Nth enclosing loop
pub fn builtinContinue(shell: *Shell, cmd: *types.ParsedCommand) !void {
    const levels = if (cmd.args.len > 0)
        std.fmt.parseInt(u32, cmd.args[0], 10) catch 1
    else
        1;

    shell.last_exit_code = 0;
    if (shell.loop_depth == 0) return;
    // Signal continue to the loop with the number of levels
    shell.continue_levels = @min(if (levels > 0) levels else 1, shell.loop_depth);
}
