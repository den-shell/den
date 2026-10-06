//! Command Expansion Module
//! Handles variable, brace, glob, and alias expansion for commands

const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const Glob = @import("../utils/glob.zig").Glob;
const BraceExpander = @import("../utils/brace.zig").BraceExpander;
const Shell = @import("../shell.zig").Shell;
const builtin = @import("builtin");

/// Expand variables, braces, and globs in a command chain.
///
/// Each command is expanded at most once (tracked via `cmd.expanded`), so this
/// can safely run after the executor has already lazily expanded some segments.
pub fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
    for (chain.commands) |*cmd| {
        try expandCommand(self, cmd);
    }
}

/// Expand variables, braces, and globs in a single parsed command.
///
/// Idempotent: returns immediately if the command was already expanded. This
/// lets the executor defer expansion to execution time so each segment of a
/// chain (`a && b`, `a; b`) expands against the environment as mutated by
/// prior segments, while still being safe if the shell expanded it up-front.
/// Storage an expander borrows. Declared by the caller so the expander's
/// `positional_params` slice outlives the call that built it.
pub const ExpanderStorage = struct {
    positional: [64][]const u8 = undefined,
};

/// Build an expander configured from the shell: positional parameters, the
/// command-substitution callback, arrays, nameref attributes, `set -u`, and the
/// current function frame's locals.
///
/// Shared so that anything expanding a word -- command arguments, array
/// assignment elements -- gets the same view of the shell rather than its own
/// partial copy.
pub fn makeExpander(self: *Shell, storage: *ExpanderStorage) Expansion {
    var param_count: usize = 0;
    if (self.function_manager.currentFrame()) |frame| {
        var i: usize = 0;
        while (i < frame.positional_params_count) : (i += 1) {
            if (frame.positional_params[i]) |param| {
                storage.positional[param_count] = param;
                param_count += 1;
            }
        }
    } else {
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                storage.positional[param_count] = param;
                param_count += 1;
            }
        }
    }

    const pid_for_expansion: i32 = if (builtin.os.tag == .windows)
        0
    else
        @intCast(self.job_manager.getLastPid());

    var expander = Expansion.initWithShell(
        self.allocator,
        &self.environment,
        self.last_exit_code,
        storage.positional[0..param_count],
        self.shell_name,
        pid_for_expansion,
        self.last_arg,
        self,
    );
    const shell_mod = @import("../shell.zig");
    expander.exec_command_fn = &shell_mod.execCommandCallback;
    expander.arrays = &self.arrays;
    expander.assoc_arrays = &self.assoc_arrays;
    expander.var_attributes = &self.var_attributes;
    expander.option_nounset = self.option_nounset;
    if (self.function_manager.currentFrame()) |frame| {
        expander.local_vars = &frame.local_vars;
    }
    return expander;
}

/// How a word was quoted in the source, which decides what happens to it.
pub const Quoting = enum {
    /// Unquoted: everything applies, including splitting and globbing.
    none,
    /// Double-quoted: parameters and substitutions expand, but the result is
    /// one word and is not globbed, and a leading `~` stays literal.
    double,
    /// Double-quoted in a word whose quoting the tokenizer already encoded as
    /// backslash escapes in front of glob characters -- which is how a command's
    /// arguments arrive. Brace and glob expansion still run, because that is
    /// what consumes those escapes.
    ///
    /// It is also why `printf "[%s]" "{a,b}"` brace-expands in den where bash
    /// leaves it alone. That divergence predates this function; it is named here
    /// rather than quietly folded into `double`, whose meaning is the correct
    /// one and which is what array elements use.
    double_pre_escaped,
    /// Single-quoted: nothing applies at all.
    single,
};

/// Run one word through the expansion pipeline, appending the results to `out`.
///
/// The order is the shell's: parameter, command and arithmetic expansion (with
/// tilde expansion unless the word was quoted), then IFS field splitting of an
/// unquoted result, then brace expansion, then globbing, then stripping the
/// escapes the tokenizer added in front of quoted glob characters.
///
/// One word can therefore produce several, or none at all. `out` takes
/// ownership of every string appended to it.
pub fn expandWordInto(
    self: *Shell,
    expander: *Expansion,
    brace: *BraceExpander,
    glob: *Glob,
    cwd: []const u8,
    word: []const u8,
    quoting: Quoting,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    if (quoting == .single) {
        // Nothing expands inside single quotes, not even a tilde. The escapes
        // the tokenizer puts in front of glob characters still come off, or the
        // backslashes would reach the command.
        const literal = try stripGlobEscapes(self.allocator, word);
        errdefer self.allocator.free(literal);
        try out.append(self.allocator, literal);
        return;
    }

    expander.skip_tilde = quoting != .none;
    const expanded = try expander.expand(word);
    expander.skip_tilde = false;

    if (quoting == .double) {
        // One word, and nothing further applies to it.
        defer self.allocator.free(expanded);
        const element = try stripGlobEscapes(self.allocator, expanded);
        errdefer self.allocator.free(element);
        try out.append(self.allocator, element);
        return;
    }

    // Split only when the word was unquoted, something in it expanded, and the
    // result actually changed. A literal word containing spaces was already one
    // word by construction.
    const should_split = quoting == .none and
        containsExpansion(word) and !std.mem.eql(u8, word, expanded);

    if (should_split) {
        const ifs = self.environment.get("IFS") orelse " \t\n";
        const WordSplitter = @import("../utils/expansion.zig").WordSplitter;
        var splitter = WordSplitter.initWithIfs(self.allocator, ifs);
        const fields = try splitter.split(expanded);
        defer self.allocator.free(fields);
        // Fields point into `expanded`, so it is freed once, after they are used.
        defer self.allocator.free(expanded);

        for (fields) |field| {
            if (field.len == 0) continue;
            try braceAndGlobInto(self, brace, glob, cwd, field, out);
        }
        return;
    }

    defer self.allocator.free(expanded);
    try braceAndGlobInto(self, brace, glob, cwd, expanded, out);
}

/// Brace-expand a field, glob each result, and append what comes out.
fn braceAndGlobInto(
    self: *Shell,
    brace: *BraceExpander,
    glob: *Glob,
    cwd: []const u8,
    field: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    const brace_exp = try brace.expand(field);
    defer {
        for (brace_exp) |item| self.allocator.free(item);
        self.allocator.free(brace_exp);
    }
    for (brace_exp) |brace_item| {
        const glob_exp = try glob.expand(brace_item, cwd);
        defer {
            for (glob_exp) |p| self.allocator.free(p);
            self.allocator.free(glob_exp);
        }
        for (glob_exp) |path| {
            const stripped = try stripGlobEscapes(self.allocator, path);
            errdefer self.allocator.free(stripped);
            try out.append(self.allocator, stripped);
        }
    }
}

pub fn expandCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.expanded) return;

    var storage: ExpanderStorage = .{};
    var expander = makeExpander(self, &storage);
    var glob = Glob.init(self.allocator);
    glob.qualifiers_enabled = self.config.zsh.enabled and self.config.zsh.glob_qualifiers;
    var brace = BraceExpander.init(self.allocator);

    // Get current working directory for glob expansion
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);

    // Expand this single command. The body is wrapped in a block so its
    // per-statement `defer`/`errdefer` cleanups run on scope exit, matching the
    // original per-iteration semantics when this was a loop over the chain.
    {
        // Save exit code before expansion to detect command substitution
        const exit_code_before = self.last_exit_code;

        // Expand command name (variables only, no globs for command names)
        const expanded_name = try expander.expand(cmd.name);
        self.allocator.free(cmd.name);
        cmd.name = expanded_name;

        // If exit code changed during name expansion, a command substitution ran.
        // Track this so variable assignment can preserve the exit code (bash behavior).
        if (self.last_exit_code != exit_code_before) {
            cmd.cmd_sub_exit_code = self.last_exit_code;
        }

        // [[ ]] is a shell keyword - skip glob expansion on its arguments
        // to preserve patterns like a* for pattern matching
        const skip_globs = std.mem.eql(u8, cmd.name, "[[");

        // Expand arguments (variables + braces + globs). Uses dynamic
        // allocation to avoid the old 128-arg cap — glob expansion can easily
        // produce thousands of arguments (e.g. `ls src/**/*.zig` in a large
        // project).
        var expanded_args: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (expanded_args.items) |a| self.allocator.free(a);
            expanded_args.deinit(self.allocator);
        }

        var prev_arg_is_v: bool = false;
        for (cmd.args, 0..) |arg, arg_idx| {
            // For [[ -v varname ]], don't expand the variable name after -v
            const skip_expansion = skip_globs and prev_arg_is_v;
            if (skip_globs) {
                prev_arg_is_v = std.mem.eql(u8, arg, "-v");
            }

            // Check if this argument was quoted in the original source
            const arg_was_quoted = if (cmd.quoted_args) |qa|
                (if (arg_idx < qa.len) qa[arg_idx] else false)
            else
                false;

            // Handle spread operator: ...$var expands variable into multiple args
            if (std.mem.startsWith(u8, arg, "...")) {
                const spread_expr = arg[3..];
                if (spread_expr.len > 0) {
                    const spread_expanded = try expander.expand(spread_expr);
                    defer self.allocator.free(spread_expanded);

                    // Split the expanded value by whitespace into multiple arguments
                    var split_iter = std.mem.splitAny(u8, spread_expanded, " \t\n");
                    while (split_iter.next()) |part| {
                        if (part.len > 0) {
                            const duped = try self.allocator.dupe(u8, part);
                            errdefer self.allocator.free(duped);
                            try expanded_args.append(self.allocator, duped);
                        }
                    }
                    self.allocator.free(arg);
                    continue;
                }
            }

            // For [[ ]] only variable expansion happens, so that a pattern
            // like `a*` on the right of `==` survives to the matcher.
            if (skip_globs) {
                const var_expanded = if (skip_expansion)
                    try self.allocator.dupe(u8, arg)
                else blk: {
                    expander.skip_tilde = arg_was_quoted;
                    defer expander.skip_tilde = false;
                    break :blk try expander.expand(arg);
                };
                try expanded_args.append(self.allocator, var_expanded);
                self.allocator.free(arg);
                continue;
            }

            // Everything else goes through the shared word pipeline, which is
            // also what an array assignment's elements use.
            try expandWordInto(
                self,
                &expander,
                &brace,
                &glob,
                cwd,
                arg,
                if (arg_was_quoted) .double_pre_escaped else .none,
                &expanded_args,
            );
            self.allocator.free(arg);
        }

        // Replace args with expanded version
        self.allocator.free(cmd.args);
        if (cmd.quoted_args) |qa| {
            self.allocator.free(qa);
            cmd.quoted_args = null;
        }
        cmd.args = try expanded_args.toOwnedSlice(self.allocator);

        // Expand redirection targets (variables only, no globs)
        for (cmd.redirections, 0..) |*redir, i| {
            if (redir.kind == .herestring) {
                // Single-quoted herestrings have \$ escapes from the tokenizer.
                // For these, convert \$ → $ literally without variable expansion.
                // Unquoted/double-quoted herestrings don't have \$ and should be expanded.
                if (std.mem.indexOf(u8, redir.target, "\\$") != null) {
                    // Replace \$ with $ (literal) — no variable expansion
                    const target = redir.target;
                    var buf: [4096]u8 = undefined;
                    var buf_len: usize = 0;
                    var j: usize = 0;
                    while (j < target.len) : (j += 1) {
                        if (j + 1 < target.len and target[j] == '\\' and target[j + 1] == '$') {
                            if (buf_len < buf.len) {
                                buf[buf_len] = '$';
                                buf_len += 1;
                            }
                            j += 1; // skip the $
                        } else {
                            if (buf_len < buf.len) {
                                buf[buf_len] = target[j];
                                buf_len += 1;
                            }
                        }
                    }
                    const literal = try self.allocator.dupe(u8, buf[0..buf_len]);
                    self.allocator.free(cmd.redirections[i].target);
                    cmd.redirections[i].target = literal;
                    continue;
                }
            }
            const expanded_target = try expander.expand(redir.target);
            self.allocator.free(cmd.redirections[i].target);
            cmd.redirections[i].target = expanded_target;
        }
    }

    cmd.expanded = true;
}

/// Strip backslash escapes before glob metacharacters (*, ?, [)
/// These are added by the tokenizer for quoted glob chars to prevent expansion
pub fn stripGlobEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len and
            (input[i + 1] == '*' or input[i + 1] == '?' or input[i + 1] == '['))
        {
            // Skip the backslash, keep the metacharacter as literal
            i += 1;
            if (len < buf.len) {
                buf[len] = input[i];
                len += 1;
            }
        } else {
            if (len < buf.len) {
                buf[len] = input[i];
                len += 1;
            }
        }
    }
    return allocator.dupe(u8, buf[0..len]);
}

/// Expand aliases in a command chain with circular reference detection
pub fn expandAliases(self: *Shell, chain: *types.CommandChain) !void {
    // Track seen aliases to detect circular references
    var seen_aliases: [32][]const u8 = undefined;
    var seen_count: usize = 0;

    for (chain.commands) |*cmd| {
        seen_count = 0; // Reset for each command
        var current_name = cmd.name;

        // Don't expand aliases that shadow den-specific structured data builtins.
        // These are new builtins (str, path, math, date, into, from, to, etc.) that
        // may collide with pre-existing aliases from zsh/bash configs.
        if (isDenBuiltin(current_name)) continue;

        // Don't expand aliases for commands that match user-defined functions.
        // POSIX command resolution order: special builtins > functions > aliases > builtins > externals.
        // Functions must take priority over aliases.
        if (self.function_manager.hasFunction(current_name)) continue;

        // Expand aliases iteratively with circular detection
        while (self.aliases.get(current_name)) |alias_value| {
            // Check for circular reference
            for (seen_aliases[0..seen_count]) |seen| {
                if (std.mem.eql(u8, seen, current_name)) {
                    try IO.eprint("den: alias: circular reference detected: {s}\n", .{current_name});
                    return; // Stop expansion on circular reference
                }
            }

            // The table's own key stays valid for as long as the entry, whereas
            // `current_name` on the first pass is `cmd.name`, which the rewrite
            // below frees. Both the cycle check and the self-reference check
            // compare against this rather than the freed slice.
            const stable_name = self.aliases.getKey(current_name) orelse current_name;

            // Track this alias
            if (seen_count < seen_aliases.len) {
                seen_aliases[seen_count] = stable_name;
                seen_count += 1;
            } else {
                // Too many nested aliases
                try IO.eprint("den: alias: expansion depth limit exceeded\n", .{});
                return;
            }

            // Get the first word of the alias value as the new command name
            const trimmed = std.mem.trim(u8, alias_value, &std.ascii.whitespace);
            const first_space = std.mem.indexOfScalar(u8, trimmed, ' ');
            const first_word = if (first_space) |pos| trimmed[0..pos] else trimmed;

            // Replace the command name with this step of the expansion.
            //
            // Every step has to be applied, not just the first: `alias s='e'`
            // where `e` is itself an alias used to leave the name as `e`, which
            // is not a command, so a chained alias reported "command not found".
            // Each step prepends its own arguments ahead of what is already
            // there, so `alias a='b X'; alias b='echo Y'; a Z` runs
            // `echo Y X Z`, as zsh does.
            {
                // Split alias value into command name and extra args
                const new_cmd_name = try self.allocator.dupe(u8, first_word);
                self.allocator.free(cmd.name);
                cmd.name = new_cmd_name;

                // If alias has extra arguments, prepend them before existing args
                if (first_space) |pos| {
                    const extra_args_str = std.mem.trim(u8, trimmed[pos + 1 ..], &std.ascii.whitespace);
                    if (extra_args_str.len > 0) {
                        // Split extra args by spaces (simple split for now)
                        var extra_count: usize = 0;
                        var count_iter = std.mem.splitScalar(u8, extra_args_str, ' ');
                        while (count_iter.next()) |part| {
                            if (part.len > 0) extra_count += 1;
                        }

                        if (extra_count > 0) {
                            const new_args = try self.allocator.alloc([]const u8, extra_count + cmd.args.len);
                            errdefer self.allocator.free(new_args);
                            var idx: usize = 0;
                            errdefer for (new_args[0..idx]) |a| self.allocator.free(a);
                            var split_iter = std.mem.splitScalar(u8, extra_args_str, ' ');
                            while (split_iter.next()) |part| {
                                if (part.len > 0) {
                                    new_args[idx] = try self.allocator.dupe(u8, part);
                                    idx += 1;
                                }
                            }
                            // Copy existing args after the alias args
                            @memcpy(new_args[idx..], cmd.args);
                            // Free old args array (but not individual strings - they're moved)
                            self.allocator.free(cmd.args);
                            cmd.args = new_args;
                        }
                    }
                }
            }

            // POSIX behavior: if the first word of the expansion matches the
            // alias name, stop expanding to allow self-referencing aliases
            // like "ls" -> "ls --color=auto"
            if (std.mem.eql(u8, first_word, stable_name)) break;

            // Check if first word is also an alias
            current_name = first_word;
        }
    }
}

/// Check if a command name is a den-specific structured data builtin.
/// These builtins should not be overridden by aliases inherited from zsh/bash configs.
fn isDenBuiltin(name: []const u8) bool {
    const den_builtins = [_][]const u8{
        "str",    "path",   "math",   "date",    "into",     "from",     "to",
        "encode", "decode", "detect", "explore", "generate", "par-each", "seq-char",
        "bench",  "watch",  "use",
    };
    for (&den_builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// Check if a string contains an unescaped variable reference ($var, ${var}, $(...), etc.)
/// Whether a word contains something that expands, and so whether its result
/// is a candidate for field splitting.
///
/// Backticks count. They did not before, so `printf "[%s]" \`echo p q\`` passed
/// one argument where bash passes two -- `$(...)` split correctly only because
/// it happens to contain a `$`.
fn containsExpansion(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '$' or s[i] == '`') return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "containsExpansion basic" {
    try std.testing.expect(containsExpansion("$var"));
    try std.testing.expect(containsExpansion("hello $VAR world"));
    try std.testing.expect(containsExpansion("${BRACED}"));
    try std.testing.expect(containsExpansion("$(cmd)"));

    try std.testing.expect(!containsExpansion("plain text"));
    try std.testing.expect(!containsExpansion(""));
    try std.testing.expect(!containsExpansion("\\$escaped"));
}

test "containsVariableRef mixed" {
    // $var with preceding \$ shouldn't match the \$, but should match the $var
    try std.testing.expect(containsExpansion("\\$first $real"));
}

test "isDenBuiltin known builtins" {
    try std.testing.expect(isDenBuiltin("str"));
    try std.testing.expect(isDenBuiltin("path"));
    try std.testing.expect(isDenBuiltin("math"));
    try std.testing.expect(isDenBuiltin("watch"));
    try std.testing.expect(isDenBuiltin("use"));
}

test "isDenBuiltin unknown commands" {
    try std.testing.expect(!isDenBuiltin("ls"));
    try std.testing.expect(!isDenBuiltin("cat"));
    try std.testing.expect(!isDenBuiltin(""));
    try std.testing.expect(!isDenBuiltin("strXY"));
}
