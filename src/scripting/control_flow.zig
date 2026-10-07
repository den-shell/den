const std = @import("std");
const cmd_exp = @import("../shell/command_expansion.zig");
const builtin = @import("builtin");
const Shell = @import("../shell.zig").Shell;
const IO = @import("../utils/io.zig").IO;
const expansion_mod = @import("../utils/expansion.zig");
const Expansion = expansion_mod.Expansion;
const removeQuotes = expansion_mod.removeQuotes;
const BraceExpander = @import("../utils/brace.zig").BraceExpander;
const Glob = @import("../utils/glob.zig").Glob;

/// Control flow statement type
pub const ControlFlowType = enum {
    if_statement,
    while_loop,
    for_loop,
    case_statement,
    until_loop,
    select_menu,
    c_style_for_loop,
};

/// If statement structure
pub const IfStatement = struct {
    condition: []const u8,
    then_body: [][]const u8,
    elif_clauses: []ElifClause,
    else_body: ?[][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IfStatement) void {
        self.allocator.free(self.condition);
        for (self.then_body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.then_body);

        for (self.elif_clauses) |*clause| {
            self.allocator.free(clause.condition);
            for (clause.body) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(clause.body);
        }
        self.allocator.free(self.elif_clauses);

        if (self.else_body) |body| {
            for (body) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(body);
        }
    }
};

pub const ElifClause = struct {
    condition: []const u8,
    body: [][]const u8,
};

/// While/Until loop structure
pub const WhileLoop = struct {
    condition: []const u8,
    body: [][]const u8,
    is_until: bool, // true for until, false for while
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WhileLoop) void {
        self.allocator.free(self.condition);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// For loop structure (traditional: for var in items)
pub const ForLoop = struct {
    variable: []const u8,
    items: [][]const u8,
    body: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ForLoop) void {
        self.allocator.free(self.variable);
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// C-style for loop structure (for (init; condition; update))
pub const CStyleForLoop = struct {
    init: ?[]const u8, // Initial statement (e.g., i=0)
    condition: ?[]const u8, // Condition to check (e.g., i<10)
    update: ?[]const u8, // Update statement (e.g., i++)
    body: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CStyleForLoop) void {
        if (self.init) |init| {
            self.allocator.free(init);
        }
        if (self.condition) |condition| {
            self.allocator.free(condition);
        }
        if (self.update) |update| {
            self.allocator.free(update);
        }
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// Select menu structure for interactive selection
pub const SelectMenu = struct {
    variable: []const u8, // Variable to store selected item
    items: [][]const u8, // Menu items
    body: [][]const u8, // Body to execute for each selection
    prompt: []const u8, // PS3 prompt (default: "#? ")
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SelectMenu) void {
        self.allocator.free(self.variable);
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
        self.allocator.free(self.prompt);
    }
};

/// Case statement structure
pub const CaseStatement = struct {
    value: []const u8,
    cases: []CaseClause,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CaseStatement) void {
        self.allocator.free(self.value);
        for (self.cases) |*case_clause| {
            for (case_clause.patterns) |pattern| {
                self.allocator.free(pattern);
            }
            self.allocator.free(case_clause.patterns);
            for (case_clause.body) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(case_clause.body);
        }
        self.allocator.free(self.cases);
    }
};

/// Case clause terminator - determines behavior after executing a case
pub const CaseTerminator = enum {
    /// ;; - Normal termination, stop checking patterns
    normal,
    /// ;& - Fallthrough, execute next case body unconditionally
    fallthrough,
    /// ;;& - Continue, test next pattern(s)
    continue_testing,
};

pub const CaseClause = struct {
    patterns: [][]const u8,
    body: [][]const u8,
    terminator: CaseTerminator = .normal,
};

/// Turn a case pattern (already expanded, quotes still in place) into a glob
/// for `globMatch`: quotes are removed and every glob character they protected
/// is backslash-escaped, so it only matches itself.
pub fn quotedPatternToGlob(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, pattern, "'\"\\") == null) return pattern;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (in_single) {
            if (c == '\'') {
                in_single = false;
                continue;
            }
        } else if (c == '\'' and !in_double) {
            in_single = true;
            continue;
        } else if (c == '"') {
            in_double = !in_double;
            continue;
        } else if (c == '\\' and i + 1 < pattern.len) {
            // Keep an escape as an escape; inside double quotes only \ " $ `
            // are escapes, anything else is a literal backslash.
            const next = pattern[i + 1];
            if (!in_double or next == '\\' or next == '"' or next == '$' or next == '`') {
                i += 1;
                try out.append(allocator, '\\');
                try out.append(allocator, next);
                continue;
            }
        }
        if ((in_single or in_double) and (c == '*' or c == '?' or c == '[' or c == ']' or c == '\\')) {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// Control flow executor
pub const ControlFlowExecutor = struct {
    shell: *Shell,
    allocator: std.mem.Allocator,
    break_levels: u32,
    continue_levels: u32,

    pub fn init(shell: *Shell) ControlFlowExecutor {
        return .{
            .shell = shell,
            .allocator = shell.allocator,
            .break_levels = 0,
            .continue_levels = 0,
        };
    }

    /// Execute if statement
    pub fn executeIf(self: *ControlFlowExecutor, stmt: *IfStatement) !i32 {
        // Evaluate main condition
        const condition_result = self.evaluateCondition(stmt.condition);

        if (condition_result) {
            // Execute then body
            return self.executeBody(stmt.then_body);
        }

        // Check elif clauses
        for (stmt.elif_clauses) |elif| {
            const elif_result = self.evaluateCondition(elif.condition);
            if (elif_result) {
                return self.executeBody(elif.body);
            }
        }

        // Execute else body if present
        if (stmt.else_body) |else_body| {
            return self.executeBody(else_body);
        }

        return 0;
    }

    /// Execute while loop
    pub fn executeWhile(self: *ControlFlowExecutor, loop: *WhileLoop) !i32 {
        var last_exit: i32 = 0;
        self.shell.loop_depth += 1;
        defer self.shell.loop_depth -= 1;

        while (true) {
            const condition_result = self.evaluateCondition(loop.condition);
            if (self.unwinding()) return last_exit;

            // For while: continue if true, for until: continue if false
            const should_continue = if (loop.is_until) !condition_result else condition_result;

            if (!should_continue) break;

            last_exit = self.executeBody(loop.body);
            if (self.unwinding()) return last_exit;

            // Check for break
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return last_exit; // Still need to break outer loops
                break;
            }

            // Handle continue
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return last_exit; // Continue outer loop
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute for loop with array expansion support.
    /// Supports: `for i in a b c`, `for i in ${arr[@]}`, `for i in "${arr[@]}"`
    pub fn executeFor(self: *ControlFlowExecutor, loop: *ForLoop) !i32 {
        var last_exit: i32 = 0;
        self.shell.loop_depth += 1;
        defer self.shell.loop_depth -= 1;

        // Expand each item (handles array variables like ${arr[@]})
        var expanded_items = std.ArrayList([]const u8).empty;
        defer {
            for (expanded_items.items) |item| {
                self.allocator.free(item);
            }
            expanded_items.deinit(self.allocator);
        }

        // Build positional params from function call frame or shell
        var pp_slice: [64][]const u8 = undefined;
        const pp = self.collectPositionalParams(&pp_slice);
        const pp_count = pp.len;

        // The shared builder, which is what connects a command substitution back
        // to den. Built by hand here, it had no shell reference and no
        // `exec_command_fn`, so `$(...)` in a for list fell back to running the
        // text under /bin/sh: `for k in $(bindkey -l)` answered
        // `/bin/sh: bindkey: command not found`, and den's functions, aliases and
        // builtins were all invisible to it.
        var storage: cmd_exp.ExpanderStorage = .{};
        var expander = cmd_exp.makeExpander(self.shell, &storage);

        for (loop.items) |item| {
            // Special case: "$@" in for loops - each positional param becomes a separate item
            if (std.mem.eql(u8, item, "\"$@\"") or std.mem.eql(u8, item, "$@")) {
                for (pp_slice[0..pp_count]) |param| {
                    try expanded_items.append(self.allocator, try self.allocator.dupe(u8, param));
                }
                continue;
            }
            // Special case: "$*" or $* - all params as one string
            if (std.mem.eql(u8, item, "\"$*\"") or std.mem.eql(u8, item, "$*")) {
                if (pp_count > 0) {
                    var total: usize = 0;
                    for (pp_slice[0..pp_count]) |p| total += p.len;
                    total += if (pp_count > 1) pp_count - 1 else 0;
                    const joined = try self.allocator.alloc(u8, total);
                    var off: usize = 0;
                    for (pp_slice[0..pp_count], 0..) |p, pi| {
                        @memcpy(joined[off .. off + p.len], p);
                        off += p.len;
                        if (pi < pp_count - 1) {
                            joined[off] = ' ';
                            off += 1;
                        }
                    }
                    try expanded_items.append(self.allocator, joined);
                }
                continue;
            }
            // Check for range expression: N..M or N..<M
            if (std.mem.indexOf(u8, item, "..")) |dot_pos| {
                // First expand any variables in the range
                const expanded_item = expander.expand(item) catch item;
                defer if (expanded_item.ptr != item.ptr) self.allocator.free(expanded_item);

                if (std.mem.indexOf(u8, expanded_item, "..")) |exp_dot_pos| {
                    const exclusive = exp_dot_pos + 2 < expanded_item.len and expanded_item[exp_dot_pos + 2] == '<';
                    const end_start = if (exclusive) exp_dot_pos + 3 else exp_dot_pos + 2;
                    const start_str = std.mem.trim(u8, expanded_item[0..exp_dot_pos], &std.ascii.whitespace);
                    const end_str = std.mem.trim(u8, expanded_item[end_start..], &std.ascii.whitespace);

                    if (std.fmt.parseInt(i64, start_str, 10)) |range_start| {
                        if (std.fmt.parseInt(i64, end_str, 10)) |range_end| {
                            const actual_end = if (exclusive) range_end else range_end + 1;
                            const step: i64 = if (range_start <= actual_end) 1 else -1;
                            var val = range_start;
                            while ((step > 0 and val < actual_end) or (step < 0 and val > actual_end)) {
                                var buf: [32]u8 = undefined;
                                const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch continue;
                                try expanded_items.append(self.allocator, try self.allocator.dupe(u8, num_str));
                                val += step;
                            }
                            continue;
                        } else |_| {}
                    } else |_| {}
                }
                // Not a valid range, fall through to regular expansion
                _ = dot_pos;
            }

            // Check if item is an array expansion (possibly quoted)
            const arr_check = if (item.len >= 2 and item[0] == '"' and item[item.len - 1] == '"')
                item[1 .. item.len - 1]
            else
                item;
            if (std.mem.indexOf(u8, arr_check, "${") != null and
                (std.mem.indexOf(u8, arr_check, "[@]") != null or std.mem.indexOf(u8, arr_check, "[*]") != null))
            {
                // Expand the array - result may be multiple items
                const expanded = expander.expand(arr_check) catch arr_check;
                defer if (expanded.ptr != arr_check.ptr) self.allocator.free(expanded);

                // Split expanded result by spaces (word splitting)
                var word_iter = std.mem.tokenizeAny(u8, expanded, " \t\n");
                while (word_iter.next()) |word| {
                    try expanded_items.append(self.allocator, try self.allocator.dupe(u8, word));
                }
            } else {
                // Regular item - expand variables/command substitutions
                const is_quoted = item.len >= 2 and item[0] == '"' and item[item.len - 1] == '"';

                // For quoted items, strip the surrounding quotes before expansion
                const expand_input = if (is_quoted) item[1 .. item.len - 1] else item;
                const expanded = expander.expand(expand_input) catch expand_input;

                // Word-split unquoted items that contain variable references
                const has_var_ref = std.mem.indexOfScalar(u8, expand_input, '$') != null or
                    std.mem.indexOfScalar(u8, expand_input, '`') != null;
                const ifs_val = expander.environment.get("IFS") orelse " \t\n";
                if (!is_quoted and has_var_ref and std.mem.indexOfAny(u8, expanded, ifs_val) != null) {
                    var word_iter = std.mem.tokenizeAny(u8, expanded, ifs_val);
                    while (word_iter.next()) |word| {
                        try expanded_items.append(self.allocator, try self.allocator.dupe(u8, word));
                    }
                    if (expanded.ptr != expand_input.ptr) self.allocator.free(expanded);
                } else {
                    // Try brace expansion on the result
                    const to_expand = if (expanded.ptr != expand_input.ptr) expanded else expand_input;
                    if (std.mem.indexOfScalar(u8, to_expand, '{') != null and std.mem.indexOf(u8, to_expand, "..") != null) {
                        var brace_exp = BraceExpander.init(self.allocator);
                        const brace_results = brace_exp.expand(to_expand) catch {
                            try expanded_items.append(self.allocator, try self.allocator.dupe(u8, to_expand));
                            if (expanded.ptr != expand_input.ptr) self.allocator.free(expanded);
                            continue;
                        };
                        defer self.allocator.free(brace_results);
                        for (brace_results) |br| {
                            try expanded_items.append(self.allocator, br); // already duped by BraceExpander
                        }
                        if (expanded.ptr != expand_input.ptr) self.allocator.free(expanded);
                    } else if (expanded.ptr != expand_input.ptr) {
                        try expanded_items.append(self.allocator, expanded);
                    } else {
                        try expanded_items.append(self.allocator, try self.allocator.dupe(u8, expand_input));
                    }
                }
            }
        }

        // Glob-expand items that contain glob characters (unquoted). The
        // matches are owned here; items kept as they are stay owned by
        // expanded_items, which frees them.
        var glob_expanded: std.ArrayListUnmanaged([]const u8) = .empty;
        defer glob_expanded.deinit(self.allocator);
        var glob_matches: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (glob_matches.items) |m| self.allocator.free(m);
            glob_matches.deinit(self.allocator);
        }
        // Get cwd for glob expansion
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len);
        const cwd = if (cwd_ptr) |p| std.mem.sliceTo(@as([*:0]u8, @ptrCast(p)), 0) else ".";

        for (expanded_items.items) |ei| {
            var glob_inst = Glob.init(self.allocator);
            glob_inst.qualifiers_enabled = self.shell.config.zsh.enabled and self.shell.config.zsh.glob_qualifiers;
            if (glob_inst.hasGlobChars(ei)) {
                const matches = glob_inst.expand(ei, cwd) catch {
                    try glob_expanded.append(self.allocator, ei);
                    continue;
                };
                defer self.allocator.free(matches);
                if (matches.len == 1 and std.mem.eql(u8, matches[0], ei)) {
                    // No matches — keep original pattern
                    try glob_expanded.append(self.allocator, ei);
                    self.allocator.free(matches[0]);
                } else {
                    // `ei` stays in expanded_items and is freed with it; freeing
                    // it here as well was a double free.
                    try glob_matches.ensureUnusedCapacity(self.allocator, matches.len);
                    for (matches) |m| {
                        glob_matches.appendAssumeCapacity(m);
                        try glob_expanded.append(self.allocator, m);
                    }
                }
            } else {
                try glob_expanded.append(self.allocator, ei);
            }
        }

        for (glob_expanded.items) |item| {
            // Set loop variable
            const value = try self.allocator.dupe(u8, item);

            // Get or put entry to avoid memory leak
            const gop = try self.shell.environment.getOrPut(loop.variable);
            if (gop.found_existing) {
                // Free old value and update
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value;
            } else {
                // New key - duplicate it
                const key = try self.allocator.dupe(u8, loop.variable);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }

            last_exit = self.executeBody(loop.body);
            if (self.unwinding()) return last_exit;

            // Check for break
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return last_exit; // Still need to break outer loops
                break;
            }

            // Handle continue
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return last_exit; // Continue outer loop
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute C-style for loop: for ((init; condition; update))
    pub fn executeCStyleFor(self: *ControlFlowExecutor, loop: *CStyleForLoop) !i32 {
        var last_exit: i32 = 0;
        self.shell.loop_depth += 1;
        defer self.shell.loop_depth -= 1;

        // Execute initialization (if present)
        if (loop.init) |init_stmt| {
            _ = try self.executeStatement(init_stmt);
        }

        // Loop while condition is true
        while (true) {
            // Check condition (if present, default to true if omitted)
            if (loop.condition) |condition| {
                const condition_result = try self.evaluateArithmeticCondition(condition);
                if (!condition_result) break;
            }

            // Execute body
            last_exit = self.executeBody(loop.body);
            if (self.unwinding()) return last_exit;

            // Check for break
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return last_exit; // Still need to break outer loops
                break;
            }

            // Execute update (before checking continue, to match C semantics)
            if (loop.update) |update| {
                _ = try self.executeStatement(update);
            }

            // Handle continue (after update)
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return last_exit; // Continue outer loop
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute select menu for interactive selection
    pub fn executeSelect(self: *ControlFlowExecutor, menu: *SelectMenu) !i32 {
        var last_exit: i32 = 0;
        self.shell.loop_depth += 1;
        defer self.shell.loop_depth -= 1;
        const stdin_handle = if (comptime builtin.os.tag == .windows) @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.Unexpected else std.posix.STDIN_FILENO;
        const stderr_handle = if (comptime builtin.os.tag == .windows) @import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return error.Unexpected else std.posix.STDERR_FILENO;
        const stdin_file = std.Io.File{ .handle = stdin_handle, .flags = .{ .nonblocking = false } };
        const stderr_file = std.Io.File{ .handle = stderr_handle, .flags = .{ .nonblocking = false } };
        var stdin_buf: [4096]u8 = undefined;
        const stdin_reader = stdin_file.reader(std.Options.debug_io, &stdin_buf);
        var reader = stdin_reader.interface;
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = stderr_file.writer(std.Options.debug_io, &stderr_buf);
        defer stderr_writer.interface.flush() catch {};

        // Display menu items once (on stderr, like bash)
        try stderr_file.writeStreamingAll(std.Options.debug_io, "\n");
        for (menu.items, 1..) |item, idx| {
            try stderr_writer.interface.print("{d}) {s}\n", .{ idx, item });
        }
        try stderr_writer.interface.flush();

        // Loop until break
        while (true) {
            // Display prompt on stderr (like bash)
            try stderr_file.writeStreamingAll(std.Options.debug_io, menu.prompt);

            // Read user input
            var input_buf: [1024]u8 = undefined;
            const input_line = (try reader.readUntilDelimiterOrEof(&input_buf, '\n')) orelse {
                // EOF reached, exit the select
                break;
            };

            const trimmed = std.mem.trim(u8, input_line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            // Parse selection number
            const selection = std.fmt.parseInt(usize, trimmed, 10) catch {
                // Invalid number, ask again
                try stderr_file.writeStreamingAll(std.Options.debug_io, "Invalid selection\n");
                continue;
            };

            if (selection == 0 or selection > menu.items.len) {
                try stderr_file.writeStreamingAll(std.Options.debug_io, "Invalid selection\n");
                continue;
            }

            // Set the variable to the selected item
            const selected_item = menu.items[selection - 1];
            const value = try self.allocator.dupe(u8, selected_item);

            const gop = try self.shell.environment.getOrPut(menu.variable);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value;
            } else {
                const key = try self.allocator.dupe(u8, menu.variable);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }

            // Also set REPLY variable with the selection number
            const reply_value = try std.fmt.allocPrint(self.allocator, "{d}", .{selection});
            const reply_gop = try self.shell.environment.getOrPut("REPLY");
            if (reply_gop.found_existing) {
                self.allocator.free(reply_gop.value_ptr.*);
                reply_gop.value_ptr.* = reply_value;
            } else {
                const reply_key = try self.allocator.dupe(u8, "REPLY");
                reply_gop.key_ptr.* = reply_key;
                reply_gop.value_ptr.* = reply_value;
            }

            // Execute body
            last_exit = self.executeBody(menu.body);
            if (self.unwinding()) return last_exit;

            // Check for break
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return last_exit; // Still need to break outer loops
                break;
            }

            // Handle continue
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return last_exit; // Continue outer loop
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute case statement with fallthrough support
    /// Supports:
    ///   ;; - normal termination (stop matching)
    ///   ;& - fallthrough (execute next case body unconditionally)
    ///   ;;& - continue testing (test next pattern, execute if matches)
    pub fn executeCase(self: *ControlFlowExecutor, stmt: *CaseStatement) !i32 {
        // Expand the value and strip quotes
        const expanded_raw = try self.expandValue(stmt.value);
        defer self.allocator.free(expanded_raw);
        const expanded_value = removeQuotes(self.allocator, expanded_raw) catch expanded_raw;
        defer if (expanded_value.ptr != expanded_raw.ptr) self.allocator.free(expanded_value);

        var last_exit: i32 = 0;
        var execute_next_unconditionally = false;

        var i: usize = 0;
        while (i < stmt.cases.len) : (i += 1) {
            const case_clause = stmt.cases[i];
            var matched = false;

            // Check if we should execute unconditionally (due to ;& from previous case)
            if (execute_next_unconditionally) {
                matched = true;
                execute_next_unconditionally = false;
            } else {
                // Check patterns (expand and strip quotes from each pattern)
                for (case_clause.patterns) |pattern| {
                    const expanded_pattern = self.expandValue(pattern) catch pattern;
                    defer if (expanded_pattern.ptr != pattern.ptr) self.allocator.free(expanded_pattern);
                    // Quoted parts of a pattern match literally: `"a*"` is the
                    // two characters a and *, not a glob.
                    const unquoted_pattern = quotedPatternToGlob(self.allocator, expanded_pattern) catch expanded_pattern;
                    defer if (unquoted_pattern.ptr != expanded_pattern.ptr) self.allocator.free(unquoted_pattern);
                    if (try self.matchPattern(expanded_value, unquoted_pattern)) {
                        matched = true;
                        break;
                    }
                }
            }

            if (matched) {
                last_exit = self.executeBody(case_clause.body);

                // Check for break/continue in body
                if (self.break_levels > 0 or self.continue_levels > 0) {
                    return last_exit;
                }

                // Handle terminator
                switch (case_clause.terminator) {
                    .normal => {
                        // ;; - stop matching, exit case statement
                        return last_exit;
                    },
                    .fallthrough => {
                        // ;& - execute next case body unconditionally
                        execute_next_unconditionally = true;
                    },
                    .continue_testing => {
                        // ;;& - continue testing next patterns normally
                        // Just continue the loop, next iteration will test patterns
                    },
                }
            }
        }

        return last_exit;
    }

    /// Evaluate a condition (runs command and checks exit code)
    fn evaluateCondition(self: *ControlFlowExecutor, condition: []const u8) bool {
        const trimmed = std.mem.trim(u8, condition, &std.ascii.whitespace);

        // Fast-path: integer test comparisons `[ A -op B ]` / `[[ A -op B ]]`.
        // Hot loops re-evaluate their condition every iteration, so matching the
        // common integer-comparison form here avoids the full tokenize→expand→
        // dispatch-to-`test` pipeline. Returns null for anything that doesn't
        // cleanly match, so all other conditions behave exactly as before.
        if (self.fastIntTest(trimmed)) |result| return result;

        // Handle ! negation prefix
        if (std.mem.startsWith(u8, trimmed, "! ")) {
            const inner = std.mem.trim(u8, trimmed[2..], &std.ascii.whitespace);
            self.shell.executeCommand(inner) catch {
                return true; // negation of failure = true
            };
            return self.shell.last_exit_code != 0;
        }

        // Execute condition command
        self.shell.executeCommand(condition) catch {
            return false;
        };

        // Condition is true if exit code is 0
        return self.shell.last_exit_code == 0;
    }

    /// Fast-path for integer test conditions `[ A -op B ]` / `[[ A -op B ]]`.
    /// Returns the comparison result, or null if the condition is anything other
    /// than a single integer comparison of two plain-integer operands — in which
    /// case the caller falls back to the full `test` builtin path unchanged.
    fn fastIntTest(self: *ControlFlowExecutor, trimmed: []const u8) ?bool {
        var inner: []const u8 = undefined;
        if (trimmed.len > 6 and std.mem.startsWith(u8, trimmed, "[[ ") and std.mem.endsWith(u8, trimmed, " ]]")) {
            inner = trimmed[3 .. trimmed.len - 3];
        } else if (trimmed.len > 4 and std.mem.startsWith(u8, trimmed, "[ ") and std.mem.endsWith(u8, trimmed, " ]")) {
            inner = trimmed[2 .. trimmed.len - 2];
        } else return null;

        // Expect exactly three whitespace-separated fields: A OP B.
        var it = std.mem.tokenizeAny(u8, inner, " \t");
        const a = it.next() orelse return null;
        const op = it.next() orelse return null;
        const b = it.next() orelse return null;
        if (it.next() != null) return null;

        const a_val = self.resolveIntOperand(a) orelse return null;
        const b_val = self.resolveIntOperand(b) orelse return null;

        const result = if (std.mem.eql(u8, op, "-lt"))
            a_val < b_val
        else if (std.mem.eql(u8, op, "-le"))
            a_val <= b_val
        else if (std.mem.eql(u8, op, "-gt"))
            a_val > b_val
        else if (std.mem.eql(u8, op, "-ge"))
            a_val >= b_val
        else if (std.mem.eql(u8, op, "-eq"))
            a_val == b_val
        else if (std.mem.eql(u8, op, "-ne"))
            a_val != b_val
        else
            return null;

        self.shell.last_exit_code = if (result) 0 else 1;
        return result;
    }

    /// Resolve a test operand to an integer, or null if it is anything other than
    /// a plain integer literal or a simple `$name`/`${name}` holding an integer.
    /// Variable lookup matches the expander's priority: function-locals, then
    /// namerefs/environment. Special/dynamic vars and complex forms return null.
    fn resolveIntOperand(self: *ControlFlowExecutor, operand: []const u8) ?i64 {
        // Plain integer literal (optionally signed).
        if (std.fmt.parseInt(i64, operand, 10)) |n| {
            return n;
        } else |_| {}

        if (operand.len < 2 or operand[0] != '$') return null;
        var name = operand[1..];
        if (name[0] == '{') {
            if (name[name.len - 1] != '}') return null;
            name = name[1 .. name.len - 1];
        }
        if (name.len == 0) return null;
        // Simple identifier only: [A-Za-z_][A-Za-z0-9_]*
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return null;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
        }

        const raw = blk: {
            if (self.shell.function_manager.currentFrame()) |frame| {
                if (frame.local_vars.get(name)) |v| break :blk v;
            }
            break :blk self.shell.getVariableValue(name) orelse return null;
        };
        const t = std.mem.trim(u8, raw, &std.ascii.whitespace);
        return std.fmt.parseInt(i64, t, 10) catch null;
    }

    /// Whether an `exit`, or a `return` from the running function, is
    /// unwinding: no further command of the body or iteration may run.
    fn unwinding(self: *ControlFlowExecutor) bool {
        if (self.shell.exit_requested) return true;
        if (self.shell.function_manager.currentFrame()) |frame| {
            if (frame.return_requested) return true;
        }
        return false;
    }

    /// Execute a body of commands
    pub fn executeBody(self: *ControlFlowExecutor, body: [][]const u8) i32 {
        var last_exit: i32 = 0;

        for (body) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for break (with optional level)
            if (std.mem.eql(u8, trimmed, "break") or std.mem.startsWith(u8, trimmed, "break ")) {
                // Outside any loop `break` does nothing, as in sh.
                if (self.shell.loop_depth == 0) continue;
                var levels: u32 = 1;
                if (std.mem.startsWith(u8, trimmed, "break ")) {
                    const level_str = std.mem.trim(u8, trimmed[6..], &std.ascii.whitespace);
                    levels = std.fmt.parseInt(u32, level_str, 10) catch 1;
                    if (levels == 0) levels = 1;
                }
                // `break 5` inside two loops leaves both, and nothing more.
                self.break_levels = @min(levels, self.shell.loop_depth);
                return 0;
            }

            // Check for continue (with optional level)
            if (std.mem.eql(u8, trimmed, "continue") or std.mem.startsWith(u8, trimmed, "continue ")) {
                if (self.shell.loop_depth == 0) continue;
                var levels: u32 = 1;
                if (std.mem.startsWith(u8, trimmed, "continue ")) {
                    const level_str = std.mem.trim(u8, trimmed[9..], &std.ascii.whitespace);
                    levels = std.fmt.parseInt(u32, level_str, 10) catch 1;
                    if (levels == 0) levels = 1;
                }
                self.continue_levels = @min(levels, self.shell.loop_depth);
                return 0;
            }

            // Execute command
            self.shell.executeCommand(trimmed) catch {
                last_exit = 1;
            };

            last_exit = self.shell.last_exit_code;

            // Transfer break/continue signals from shell builtins to executor
            if (self.shell.break_levels > 0) {
                self.break_levels = self.shell.break_levels;
                self.shell.break_levels = 0;
            }
            if (self.shell.continue_levels > 0) {
                self.continue_levels = self.shell.continue_levels;
                self.shell.continue_levels = 0;
            }

            // Check for break/continue request
            if (self.break_levels > 0 or self.continue_levels > 0) {
                return last_exit;
            }

            // `exit`, or `return` from the function this body runs in.
            if (self.unwinding()) return last_exit;

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                return last_exit;
            }
        }

        return last_exit;
    }

    /// Expand a value (variables, command substitution, etc.)
    /// The positional parameters visible from here: a running function's own
    /// arguments when there is a frame, the shell's otherwise.
    ///
    /// The caller owns `buf` because the returned slice points into it - a
    /// helper that declared the array itself would hand back a view of its own
    /// dead stack frame.
    fn collectPositionalParams(self: *ControlFlowExecutor, buf: *[64][]const u8) []const []const u8 {
        var count: usize = 0;

        if (self.shell.function_manager.currentFrame()) |frame| {
            var pi: usize = 0;
            while (pi < frame.positional_params_count) : (pi += 1) {
                if (frame.positional_params[pi]) |param| {
                    buf[count] = param;
                    count += 1;
                }
            }
        } else {
            for (self.shell.positional_params) |maybe_param| {
                if (maybe_param) |param| {
                    buf[count] = param;
                    count += 1;
                }
            }
        }

        return buf[0..count];
    }

    /// Expand a control-flow operand the same way the command path would.
    ///
    /// This used to expand against the environment alone, so inside a function
    /// `$1` had nothing to resolve to and became the empty string. `case "$1"`
    /// then matched no pattern but `*`, and picked the wrong branch in silence
    /// - a wrong answer rather than an error, in the construct whose whole job
    /// is choosing a branch. Arrays were missing for the same reason.
    fn expandValue(self: *ControlFlowExecutor, value: []const u8) ![]const u8 {
        // Same builder, for the same reason: a `case` subject containing a
        // command substitution has to be evaluated by den.
        var storage: cmd_exp.ExpanderStorage = .{};
        var expander = cmd_exp.makeExpander(self.shell, &storage);

        return try expander.expand(value);
    }

    /// Match a pattern (supports full glob: *, ?, [abc], [a-z])
    fn matchPattern(self: *ControlFlowExecutor, value: []const u8, pattern: []const u8) !bool {
        _ = self;
        return globMatch(value, pattern);
    }

    pub fn globMatch(str: []const u8, pattern: []const u8) bool {
        return globMatchImpl(str, 0, pattern, 0);
    }

    fn globMatchImpl(str: []const u8, si: usize, pattern: []const u8, pi: usize) bool {
        var s = si;
        var p = pi;

        while (p < pattern.len) {
            if (pattern[p] == '*') {
                // Skip consecutive stars
                while (p < pattern.len and pattern[p] == '*') p += 1;
                // Trailing * matches everything
                if (p >= pattern.len) return true;
                // Try matching * with 0..n characters
                while (s <= str.len) {
                    if (globMatchImpl(str, s, pattern, p)) return true;
                    s += 1;
                }
                return false;
            } else if (pattern[p] == '?') {
                if (s >= str.len) return false;
                s += 1;
                p += 1;
            } else if (pattern[p] == '[') {
                if (s >= str.len) return false;
                p += 1;
                var negate = false;
                if (p < pattern.len and (pattern[p] == '!' or pattern[p] == '^')) {
                    negate = true;
                    p += 1;
                }
                var matched_class = false;
                var first = true;
                while (p < pattern.len and (first or pattern[p] != ']')) {
                    first = false;
                    if (p + 2 < pattern.len and pattern[p + 1] == '-') {
                        if (str[s] >= pattern[p] and str[s] <= pattern[p + 2]) matched_class = true;
                        p += 3;
                    } else {
                        if (str[s] == pattern[p]) matched_class = true;
                        p += 1;
                    }
                }
                if (p < pattern.len) p += 1; // skip ]
                if (negate) matched_class = !matched_class;
                if (!matched_class) return false;
                s += 1;
            } else if (pattern[p] == '\\' and p + 1 < pattern.len) {
                // Escaped character: matches itself only.
                if (s >= str.len or str[s] != pattern[p + 1]) return false;
                s += 1;
                p += 2;
            } else {
                if (s >= str.len or str[s] != pattern[p]) return false;
                s += 1;
                p += 1;
            }
        }
        return s >= str.len;
    }

    /// Execute a statement (for init/update in C-style for loops)
    fn executeStatement(self: *ControlFlowExecutor, statement: []const u8) !i32 {
        const trimmed = std.mem.trim(u8, statement, &std.ascii.whitespace);
        if (trimmed.len == 0) return 0;

        // Execute as a command
        self.shell.executeCommand(trimmed) catch |err| {
            IO.eprint("den: error executing statement: {}\n", .{err}) catch {};
            return 1;
        };

        return self.shell.last_exit_code;
    }

    /// Evaluate arithmetic condition for C-style for loops.
    /// In bash, for ((i=0; i<10; i++)), the condition is evaluated as an
    /// arithmetic expression: non-zero means true (continue), zero means false (stop).
    /// An empty condition means always true (infinite loop).
    fn evaluateArithmeticCondition(self: *ControlFlowExecutor, condition: []const u8) !bool {
        const trimmed = std.mem.trim(u8, condition, &std.ascii.whitespace);
        if (trimmed.len == 0) return true; // Empty condition is always true (bash behavior)

        // Use the arithmetic evaluator to evaluate the condition as an arithmetic expression
        const Arithmetic = @import("../utils/arithmetic.zig").Arithmetic;
        var arith = Arithmetic.initWithVariables(self.allocator, &self.shell.environment);
        arith.arrays = &self.shell.arrays;
        const result = arith.eval(trimmed) catch 0;

        // Non-zero result means true (continue looping), zero means false (stop)
        return result != 0;
    }
};
