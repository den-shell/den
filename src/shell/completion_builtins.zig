//! Completion Builtins Implementation
//!
//! This module implements the completion-related shell builtins:
//! - complete: define completion specs for commands
//! - compgen: generate possible completions

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const Completion = @import("../utils/completion.zig").Completion;
const CompletionSpec = @import("../utils/completion_registry.zig").CompletionSpec;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: complete - define how arguments are to be completed
pub fn builtinComplete(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // No args - list all completions
    if (cmd.args.len == 0) {
        const commands = shell.completion_registry.getCommands() catch &[_][]const u8{};
        defer {
            for (commands) |c| shell.allocator.free(c);
            shell.allocator.free(commands);
        }

        if (commands.len == 0) {
            try IO.print("No programmable completions defined.\n", .{});
            try IO.print("Usage: complete [-fdc...] [-W wordlist] command\n", .{});
        } else {
            for (commands) |command| {
                if (shell.completion_registry.get(command)) |spec| {
                    try printCompletionSpec(command, spec);
                }
            }
        }
        return;
    }

    // Parse flags
    var print_mode = false;
    var remove_mode = false;
    var spec_options = CompletionSpec.Options{};
    var wordlist_str: ?[]const u8 = null;
    var target_commands = std.ArrayList([]const u8).empty;
    defer target_commands.deinit(shell.allocator);

    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-p")) {
                print_mode = true;
            } else if (std.mem.eql(u8, arg, "-r")) {
                remove_mode = true;
            } else if (std.mem.eql(u8, arg, "-f")) {
                spec_options.filenames = true;
            } else if (std.mem.eql(u8, arg, "-d")) {
                spec_options.directories = true;
            } else if (std.mem.eql(u8, arg, "-c")) {
                spec_options.commands = true;
            } else if (std.mem.eql(u8, arg, "-a")) {
                spec_options.aliases = true;
            } else if (std.mem.eql(u8, arg, "-b")) {
                spec_options.builtins = true;
            } else if (std.mem.eql(u8, arg, "-e")) {
                spec_options.variables = true;
            } else if (std.mem.eql(u8, arg, "-u")) {
                spec_options.users = true;
            } else if (std.mem.eql(u8, arg, "-W")) {
                // Next arg is wordlist
                if (i + 1 < cmd.args.len) {
                    i += 1;
                    wordlist_str = cmd.args[i];
                    spec_options.use_wordlist = true;
                } else {
                    try IO.eprint("den: complete: -W: option requires an argument\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "-S")) {
                // Next arg is suffix
                if (i + 1 < cmd.args.len) {
                    i += 1;
                    spec_options.suffix = try shell.allocator.dupe(u8, cmd.args[i]);
                } else {
                    try IO.eprint("den: complete: -S: option requires an argument\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "-P")) {
                // Next arg is prefix
                if (i + 1 < cmd.args.len) {
                    i += 1;
                    spec_options.prefix = try shell.allocator.dupe(u8, cmd.args[i]);
                } else {
                    try IO.eprint("den: complete: -P: option requires an argument\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "--help")) {
                try IO.print("Usage: complete [-prabcdefgu] [-W wordlist] [-S suffix] [-P prefix] [command ...]\n", .{});
                try IO.print("Specify how arguments are to be completed.\n\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -p          print existing completion specs in a reusable format\n", .{});
                try IO.print("  -r          remove completion spec for command\n", .{});
                try IO.print("  -f          filenames (default action)\n", .{});
                try IO.print("  -d          directory names\n", .{});
                try IO.print("  -c          command names\n", .{});
                try IO.print("  -a          alias names\n", .{});
                try IO.print("  -b          builtin command names\n", .{});
                try IO.print("  -e          environment variable names\n", .{});
                try IO.print("  -u          usernames\n", .{});
                try IO.print("  -W wordlist use words from wordlist\n", .{});
                try IO.print("  -S suffix   append suffix to each completion\n", .{});
                try IO.print("  -P prefix   prepend prefix to each completion\n", .{});
                return;
            } else {
                // Legacy mode - treat as prefix
                var completion = Completion.init(shell.allocator);
                try showLegacyCompletions(shell, &completion, arg);
                return;
            }
        } else {
            // Non-option argument - this is a command name
            try target_commands.append(shell.allocator, arg);
        }
    }

    // Handle print mode
    if (print_mode) {
        if (target_commands.items.len == 0) {
            // Print all
            const commands = shell.completion_registry.getCommands() catch &[_][]const u8{};
            defer {
                for (commands) |c| shell.allocator.free(c);
                shell.allocator.free(commands);
            }
            for (commands) |command| {
                if (shell.completion_registry.get(command)) |spec| {
                    try printCompletionSpec(command, spec);
                }
            }
        } else {
            for (target_commands.items) |command| {
                if (shell.completion_registry.get(command)) |spec| {
                    try printCompletionSpec(command, spec);
                } else {
                    try IO.eprint("den: complete: {s}: no completion specification\n", .{command});
                }
            }
        }
        return;
    }

    // Handle remove mode
    if (remove_mode) {
        if (target_commands.items.len == 0) {
            // Remove all
            const commands = shell.completion_registry.getCommands() catch &[_][]const u8{};
            defer {
                for (commands) |c| shell.allocator.free(c);
                shell.allocator.free(commands);
            }
            for (commands) |command| {
                _ = shell.completion_registry.unregister(command);
            }
        } else {
            for (target_commands.items) |command| {
                _ = shell.completion_registry.unregister(command);
            }
        }
        return;
    }

    // Register mode - need at least one command
    if (target_commands.items.len == 0) {
        // Legacy mode - no options, just print help
        try IO.print("Usage: complete [-prabcdefgu] [-W wordlist] [-S suffix] [-P prefix] command\n", .{});
        return;
    }

    // Parse wordlist if provided
    var wordlist: ?[][]const u8 = null;
    if (wordlist_str) |wl| {
        var words = std.ArrayList([]const u8).empty;
        errdefer words.deinit(shell.allocator);

        var word_iter = std.mem.tokenizeAny(u8, wl, " \t");
        while (word_iter.next()) |word| {
            try words.append(shell.allocator, try shell.allocator.dupe(u8, word));
        }
        wordlist = try words.toOwnedSlice(shell.allocator);
    }

    // Register completions for each command
    for (target_commands.items) |command| {
        try shell.completion_registry.register(command, .{
            .command = command,
            .options = spec_options,
            .wordlist = wordlist,
        });
    }
}

/// Print completion spec in reusable format
pub fn printCompletionSpec(command: []const u8, spec: CompletionSpec) !void {
    try IO.print("complete", .{});
    if (spec.options.filenames) try IO.print(" -f", .{});
    if (spec.options.directories) try IO.print(" -d", .{});
    if (spec.options.commands) try IO.print(" -c", .{});
    if (spec.options.aliases) try IO.print(" -a", .{});
    if (spec.options.builtins) try IO.print(" -b", .{});
    if (spec.options.variables) try IO.print(" -e", .{});
    if (spec.options.users) try IO.print(" -u", .{});
    if (spec.wordlist) |wordlist| {
        try IO.print(" -W \"", .{});
        for (wordlist, 0..) |word, idx| {
            if (idx > 0) try IO.print(" ", .{});
            try IO.print("{s}", .{word});
        }
        try IO.print("\"", .{});
    }
    if (spec.options.suffix) |suffix| {
        try IO.print(" -S \"{s}\"", .{suffix});
    }
    if (spec.options.prefix) |prefix| {
        try IO.print(" -P \"{s}\"", .{prefix});
    }
    try IO.print(" {s}\n", .{command});
}

/// Show completions in legacy mode (for a prefix)
pub fn showLegacyCompletions(shell: *Shell, completion: *Completion, prefix: []const u8) !void {
    // Try command completion first
    const cmd_matches = try completion.completeCommand(prefix);
    defer {
        for (cmd_matches) |match| {
            shell.allocator.free(match);
        }
        shell.allocator.free(cmd_matches);
    }

    if (cmd_matches.len > 0) {
        try IO.print("Commands:\n", .{});
        for (cmd_matches) |match| {
            try IO.print("  {s}\n", .{match});
        }
    }

    // Try file completion
    const file_matches = try completion.completeFile(prefix);
    defer {
        for (file_matches) |match| {
            shell.allocator.free(match);
        }
        shell.allocator.free(file_matches);
    }

    if (file_matches.len > 0) {
        if (cmd_matches.len > 0) {
            try IO.print("\n", .{});
        }
        try IO.print("Files:\n", .{});
        for (file_matches) |match| {
            try IO.print("  {s}\n", .{match});
        }
    }

    if (cmd_matches.len == 0 and file_matches.len == 0) {
        try IO.print("No completions found.\n", .{});
    }
}

/// Builtin: compgen - generate possible completions
pub fn builtinCompgen(shell: *Shell, cmd: *types.ParsedCommand) !void {
    var action: enum { none, command, file, directory, builtin, keyword, alias, function, variable } = .none;
    var prefix: []const u8 = "";
    var arg_start: usize = 0;

    // Parse flags
    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len >= 2 and arg[0] == '-') {
            arg_start += 1;
            switch (arg[1]) {
                'c' => action = .command,
                'f' => action = .file,
                'd' => action = .directory,
                'b' => action = .builtin,
                'k' => action = .keyword,
                'a' => action = .alias,
                'A' => {
                    // -A action_name
                    if (arg_start < cmd.args.len) {
                        const action_name = cmd.args[arg_start];
                        arg_start += 1;
                        if (std.mem.eql(u8, action_name, "command")) {
                            action = .command;
                        } else if (std.mem.eql(u8, action_name, "file")) {
                            action = .file;
                        } else if (std.mem.eql(u8, action_name, "directory")) {
                            action = .directory;
                        } else if (std.mem.eql(u8, action_name, "builtin")) {
                            action = .builtin;
                        } else if (std.mem.eql(u8, action_name, "alias")) {
                            action = .alias;
                        } else if (std.mem.eql(u8, action_name, "function")) {
                            action = .function;
                        } else if (std.mem.eql(u8, action_name, "variable")) {
                            action = .variable;
                        }
                    }
                },
                'v' => action = .variable,
                else => {},
            }
        } else {
            break;
        }
    }

    // Get prefix
    if (arg_start < cmd.args.len) {
        prefix = cmd.args[arg_start];
    }

    // Generate completions based on action
    switch (action) {
        .alias => {
            var it = shell.aliases.iterator();
            while (it.next()) |entry| {
                if (prefix.len == 0 or std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                    try IO.print("{s}\n", .{entry.key_ptr.*});
                }
            }
        },
        .variable => {
            var it = shell.environment.iterator();
            while (it.next()) |entry| {
                if (prefix.len == 0 or std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                    try IO.print("{s}\n", .{entry.key_ptr.*});
                }
            }
        },
        .function => {
            var it = shell.function_manager.functions.iterator();
            while (it.next()) |entry| {
                if (prefix.len == 0 or std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                    try IO.print("{s}\n", .{entry.key_ptr.*});
                }
            }
        },
        .builtin => {
            const builtins_list = [_][]const u8{
                "cd",     "pwd",     "echo",     "exit",      "export",  "set",     "unset",
                "alias",  "unalias", "history",  "type",      "which",   "source",  "read",
                "test",   "pushd",   "popd",     "dirs",      "printf",  "true",    "false",
                "help",   "eval",    "shift",    "time",      "umask",   "clear",   "hash",
                "return", "break",   "continue", "local",     "declare", "typeset", "readonly",
                "let",    "shopt",   "mapfile",  "readarray", "caller",  "compgen", "complete",
                "exec",   "wait",    "kill",     "disown",    "getopts", "times",   "builtin",
                "jobs",   "fg",      "bg",       "bindkey",   "zle",     "zstyle",
                "autoload",     "compinit", "bashcompinit", "compdef",
                "zmodload",     "emulate",  "is-at-least",  "add-zsh-hook",
            };
            for (builtins_list) |b| {
                if (prefix.len == 0 or std.mem.startsWith(u8, b, prefix)) {
                    try IO.print("{s}\n", .{b});
                }
            }
        },
        .file => {
            // Use completion system
            var completion = Completion.init(shell.allocator);
            const matches = try completion.completeFile(prefix);
            defer {
                for (matches) |match| {
                    shell.allocator.free(match);
                }
                shell.allocator.free(matches);
            }
            for (matches) |match| {
                try IO.print("{s}\n", .{match});
            }
        },
        .directory => {
            var completion = Completion.init(shell.allocator);
            const matches = try completion.completeDirectory(prefix);
            defer {
                for (matches) |match| {
                    shell.allocator.free(match);
                }
                shell.allocator.free(matches);
            }
            for (matches) |match| {
                try IO.print("{s}\n", .{match});
            }
        },
        .command => {
            var completion = Completion.init(shell.allocator);
            const matches = try completion.completeCommand(prefix);
            defer {
                for (matches) |match| {
                    shell.allocator.free(match);
                }
                shell.allocator.free(matches);
            }
            for (matches) |match| {
                try IO.print("{s}\n", .{match});
            }
        },
        else => {},
    }

    shell.last_exit_code = 0;
}
