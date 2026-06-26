const std = @import("std");
const builtin = @import("builtin");
const Shell = @import("../shell.zig").Shell;
const IO = @import("../utils/io.zig").IO;
const expansion_mod = @import("../utils/expansion.zig");
const Expansion = expansion_mod.Expansion;
const removeQuotes = expansion_mod.removeQuotes;
const BraceExpander = @import("../utils/brace.zig").BraceExpander;
const Glob = @import("../utils/glob.zig").Glob;

/// Check if a line is a keyword (possibly followed by |, ;, &, etc.)
fn isKeyword(line: []const u8, keyword: []const u8) bool {
    if (std.mem.eql(u8, line, keyword)) return true;
    if (line.len > keyword.len and std.mem.startsWith(u8, line, keyword)) {
        const next = line[keyword.len];
        return next == ' ' or next == '\t' or next == '|' or next == ';' or next == '&' or next == '#';
    }
    return false;
}

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

        while (true) {
            const condition_result = self.evaluateCondition(loop.condition);

            // For while: continue if true, for until: continue if false
            const should_continue = if (loop.is_until) !condition_result else condition_result;

            if (!should_continue) break;

            last_exit = self.executeBody(loop.body);

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
        var pp_count: usize = 0;
        if (self.shell.function_manager.currentFrame()) |frame| {
            var pi: usize = 0;
            while (pi < frame.positional_params_count) : (pi += 1) {
                if (frame.positional_params[pi]) |param| {
                    pp_slice[pp_count] = param;
                    pp_count += 1;
                }
            }
        } else {
            for (self.shell.positional_params) |maybe_param| {
                if (maybe_param) |param| {
                    pp_slice[pp_count] = param;
                    pp_count += 1;
                }
            }
        }

        // Create expansion context with positional params
        var expander = Expansion.init(self.allocator, &self.shell.environment, self.shell.last_exit_code);
        expander.positional_params = pp_slice[0..pp_count];
        expander.arrays = &self.shell.arrays;
        expander.assoc_arrays = &self.shell.assoc_arrays;

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

        // Glob-expand items that contain glob characters (unquoted)
        var glob_expanded: std.ArrayListUnmanaged([]const u8) = .empty;
        defer glob_expanded.deinit(self.allocator);
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
                    for (matches) |m| {
                        try glob_expanded.append(self.allocator, m);
                    }
                    self.allocator.free(ei);
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
        const stdin_handle = if (comptime builtin.os.tag == .windows) std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse return error.Unexpected else std.posix.STDIN_FILENO;
        const stderr_handle = if (comptime builtin.os.tag == .windows) std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) orelse return error.Unexpected else std.posix.STDERR_FILENO;
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
                    const unquoted_pattern = removeQuotes(self.allocator, expanded_pattern) catch expanded_pattern;
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

    /// Execute a body of commands
    pub fn executeBody(self: *ControlFlowExecutor, body: [][]const u8) i32 {
        var last_exit: i32 = 0;

        for (body) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for break (with optional level)
            if (std.mem.eql(u8, trimmed, "break") or std.mem.startsWith(u8, trimmed, "break ")) {
                if (std.mem.startsWith(u8, trimmed, "break ")) {
                    const level_str = std.mem.trim(u8, trimmed[6..], &std.ascii.whitespace);
                    self.break_levels = std.fmt.parseInt(u32, level_str, 10) catch 1;
                    if (self.break_levels == 0) self.break_levels = 1;
                } else {
                    self.break_levels = 1;
                }
                return 0;
            }

            // Check for continue (with optional level)
            if (std.mem.eql(u8, trimmed, "continue") or std.mem.startsWith(u8, trimmed, "continue ")) {
                if (std.mem.startsWith(u8, trimmed, "continue ")) {
                    const level_str = std.mem.trim(u8, trimmed[9..], &std.ascii.whitespace);
                    self.continue_levels = std.fmt.parseInt(u32, level_str, 10) catch 1;
                    if (self.continue_levels == 0) self.continue_levels = 1;
                } else {
                    self.continue_levels = 1;
                }
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

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                return last_exit;
            }
        }

        return last_exit;
    }

    /// Expand a value (variables, command substitution, etc.)
    fn expandValue(self: *ControlFlowExecutor, value: []const u8) ![]const u8 {
        var expander = Expansion.init(self.allocator, &self.shell.environment, self.shell.last_exit_code);
        const expanded = try expander.expand(value);
        return expanded;
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

/// Parse control flow statements from script lines
pub const ControlFlowParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ControlFlowParser {
        return .{ .allocator = allocator };
    }

    /// Parse if statement from lines starting at index
    pub fn parseIf(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { stmt: IfStatement, end: usize } {
        var then_body_buffer: [1000][]const u8 = undefined;
        var then_body_count: usize = 0;
        var elif_buffer: [10]ElifClause = undefined;
        var elif_count: usize = 0;
        var else_body_buffer: [1000][]const u8 = undefined;
        var else_body_count: usize = 0;
        var has_else = false;

        // Extract condition from "if <condition>; then" or "if <condition>"
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);
        const condition_start = if (std.mem.startsWith(u8, first_line, "if ")) 3 else return error.InvalidIf;
        const condition_end = std.mem.indexOf(u8, first_line[condition_start..], ";") orelse
            std.mem.indexOf(u8, first_line[condition_start..], "\n") orelse
            first_line[condition_start..].len;
        const condition = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[condition_start..][0..condition_end], &std.ascii.whitespace));

        var i = start + 1;
        var current_section: enum { then, elif, @"else" } = .then;
        var if_depth: u32 = 0; // Track nested if/fi depth
        var elif_body_buffer: [1000][]const u8 = undefined;
        var elif_body_count: usize = 0;
        // Buffer for accumulating nested construct lines to reconstruct as single body entry
        var nested_buf: [4096]u8 = undefined;
        var nested_len: usize = 0;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            // Track nested if/for/while/case/fi/done/esac depth
            if (if_depth > 0) {
                // Check for deeper nesting
                if (std.mem.startsWith(u8, line, "if ") or
                    std.mem.startsWith(u8, line, "for ") or
                    std.mem.startsWith(u8, line, "while ") or
                    std.mem.startsWith(u8, line, "until ") or
                    std.mem.startsWith(u8, line, "case "))
                {
                    if_depth += 1;
                } else if (isKeyword(line, "fi") or
                    isKeyword(line, "done") or
                    isKeyword(line, "esac"))
                {
                    if_depth -= 1;
                }
                // Append to nested buffer with "; " separator
                if (nested_len > 0 and nested_len + 2 < nested_buf.len) {
                    nested_buf[nested_len] = ';';
                    nested_buf[nested_len + 1] = ' ';
                    nested_len += 2;
                }
                const copy_len = @min(line.len, nested_buf.len - nested_len);
                @memcpy(nested_buf[nested_len .. nested_len + copy_len], line[0..copy_len]);
                nested_len += copy_len;

                // When depth returns to 0, flush accumulated nested construct as single body entry
                if (if_depth == 0) {
                    const nested_line = try self.allocator.dupe(u8, nested_buf[0..nested_len]);
                    nested_len = 0;
                    switch (current_section) {
                        .then => {
                            if (then_body_count >= then_body_buffer.len) return error.TooManyLines;
                            then_body_buffer[then_body_count] = nested_line;
                            then_body_count += 1;
                        },
                        .elif => {
                            if (elif_body_count >= elif_body_buffer.len) return error.TooManyLines;
                            elif_body_buffer[elif_body_count] = nested_line;
                            elif_body_count += 1;
                        },
                        .@"else" => {
                            if (else_body_count >= else_body_buffer.len) return error.TooManyLines;
                            else_body_buffer[else_body_count] = nested_line;
                            else_body_count += 1;
                        },
                    }
                }
                continue;
            }

            if (std.mem.eql(u8, line, "then")) {
                // "then" after "elif" stays in elif section (it's the elif body start)
                if (current_section != .elif) {
                    current_section = .then;
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "elif ")) {
                // Save current elif body if we had one
                if (current_section == .elif and elif_count > 0 and elif_body_count > 0) {
                    const body = try self.allocator.alloc([]const u8, elif_body_count);
                    @memcpy(body, elif_body_buffer[0..elif_body_count]);
                    elif_buffer[elif_count - 1].body = body;
                    elif_body_count = 0;
                }
                current_section = .elif;
                // Parse elif condition
                const elif_cond_start = 5;
                const elif_cond_end = std.mem.indexOf(u8, line[elif_cond_start..], ";") orelse line[elif_cond_start..].len;
                const elif_condition = try self.allocator.dupe(u8, std.mem.trim(u8, line[elif_cond_start..][0..elif_cond_end], &std.ascii.whitespace));

                if (elif_count >= elif_buffer.len) return error.TooManyElifClauses;
                elif_buffer[elif_count] = ElifClause{
                    .condition = elif_condition,
                    .body = &[_][]const u8{},
                };
                elif_count += 1;
                continue;
            }

            if (std.mem.eql(u8, line, "else")) {
                // Save current elif body if we had one
                if (current_section == .elif and elif_count > 0 and elif_body_count > 0) {
                    const body = try self.allocator.alloc([]const u8, elif_body_count);
                    @memcpy(body, elif_body_buffer[0..elif_body_count]);
                    elif_buffer[elif_count - 1].body = body;
                    elif_body_count = 0;
                }
                current_section = .@"else";
                has_else = true;
                continue;
            }

            if (isKeyword(line, "fi")) {
                // Save current elif body if we had one
                if (current_section == .elif and elif_count > 0 and elif_body_count > 0) {
                    const body = try self.allocator.alloc([]const u8, elif_body_count);
                    @memcpy(body, elif_body_buffer[0..elif_body_count]);
                    elif_buffer[elif_count - 1].body = body;
                }
                break;
            }

            // Check if this line starts a nested construct - accumulate until matching closer
            if (std.mem.startsWith(u8, line, "if ") or
                std.mem.startsWith(u8, line, "for ") or
                std.mem.startsWith(u8, line, "while ") or
                std.mem.startsWith(u8, line, "until ") or
                std.mem.startsWith(u8, line, "case "))
            {
                if_depth = 1;
                nested_len = 0;
                const copy_len = @min(line.len, nested_buf.len);
                @memcpy(nested_buf[0..copy_len], line[0..copy_len]);
                nested_len = copy_len;
                continue;
            }

            // Add line to appropriate body
            if (line.len > 0 and line[0] != '#') {
                // Check capacity BEFORE allocating to avoid leaking line_copy on
                // a buffer-full error.
                switch (current_section) {
                    .then => if (then_body_count >= then_body_buffer.len) return error.TooManyLines,
                    .elif => if (elif_body_count >= elif_body_buffer.len) return error.TooManyLines,
                    .@"else" => if (else_body_count >= else_body_buffer.len) return error.TooManyLines,
                }
                const line_copy = try self.allocator.dupe(u8, line);
                switch (current_section) {
                    .then => {
                        then_body_buffer[then_body_count] = line_copy;
                        then_body_count += 1;
                    },
                    .elif => {
                        elif_body_buffer[elif_body_count] = line_copy;
                        elif_body_count += 1;
                    },
                    .@"else" => {
                        else_body_buffer[else_body_count] = line_copy;
                        else_body_count += 1;
                    },
                }
            }
        }

        // Create slices and copy data
        const then_body = try self.allocator.alloc([]const u8, then_body_count);
        errdefer self.allocator.free(then_body);
        @memcpy(then_body, then_body_buffer[0..then_body_count]);

        const elif_clauses = try self.allocator.alloc(ElifClause, elif_count);
        errdefer self.allocator.free(elif_clauses);
        @memcpy(elif_clauses, elif_buffer[0..elif_count]);

        const else_body: ?[][]const u8 = if (has_else) blk: {
            const body = try self.allocator.alloc([]const u8, else_body_count);
            @memcpy(body, else_body_buffer[0..else_body_count]);
            break :blk body;
        } else null;

        return .{
            .stmt = IfStatement{
                .condition = condition,
                .then_body = then_body,
                .elif_clauses = elif_clauses,
                .else_body = else_body,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse while loop
    pub fn parseWhile(self: *ControlFlowParser, lines: [][]const u8, start: usize, is_until: bool) !struct { loop: WhileLoop, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);
        const keyword = if (is_until) "until " else "while ";
        const keyword_len = keyword.len;

        if (!std.mem.startsWith(u8, first_line, keyword)) return error.InvalidLoop;

        const condition_end = std.mem.indexOf(u8, first_line[keyword_len..], ";") orelse
            std.mem.indexOf(u8, first_line[keyword_len..], "\n") orelse
            first_line[keyword_len..].len;
        const condition = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[keyword_len..][0..condition_end], &std.ascii.whitespace));

        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;
        var nest_depth: u32 = 0;
        var nest_buf: [4096]u8 = undefined;
        var nest_len: usize = 0;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (isKeyword(line, "do") and nest_depth == 0) continue;

            if (nest_depth > 0) {
                if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "for ") or
                    std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "until ") or
                    std.mem.startsWith(u8, line, "case ")) nest_depth += 1 else if (isKeyword(line, "fi") or isKeyword(line, "done") or
                    isKeyword(line, "esac")) nest_depth -= 1;
                if (nest_len > 0 and nest_len + 2 < nest_buf.len) {
                    nest_buf[nest_len] = ';';
                    nest_buf[nest_len + 1] = ' ';
                    nest_len += 2;
                }
                const cl = @min(line.len, nest_buf.len - nest_len);
                @memcpy(nest_buf[nest_len .. nest_len + cl], line[0..cl]);
                nest_len += cl;
                if (nest_depth == 0) {
                    if (body_count >= body_buffer.len) return error.TooManyLines;
                    body_buffer[body_count] = try self.allocator.dupe(u8, nest_buf[0..nest_len]);
                    body_count += 1;
                    nest_len = 0;
                }
                continue;
            }

            if (isKeyword(line, "done")) break;

            if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "for ") or
                std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "until ") or
                std.mem.startsWith(u8, line, "case "))
            {
                nest_depth = 1;
                nest_len = 0;
                const cl = @min(line.len, nest_buf.len);
                @memcpy(nest_buf[0..cl], line[0..cl]);
                nest_len = cl;
                continue;
            }

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        return .{
            .loop = WhileLoop{
                .condition = condition,
                .body = body,
                .is_until = is_until,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse for loop
    pub fn parseFor(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { loop: ForLoop, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "for ")) return error.InvalidFor;

        // Parse: for VAR in ITEM1 ITEM2 ITEM3
        const parts_start = 4; // After "for "
        const in_pos = std.mem.indexOf(u8, first_line[parts_start..], " in ") orelse return error.InvalidFor;

        const variable = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[parts_start..][0..in_pos], &std.ascii.whitespace));

        const items_start = parts_start + in_pos + 4; // After " in "
        const items_end = std.mem.indexOf(u8, first_line[items_start..], ";") orelse first_line[items_start..].len;
        const items_str = std.mem.trim(u8, first_line[items_start..][0..items_end], &std.ascii.whitespace);

        var items_buffer: [100][]const u8 = undefined;
        var items_count: usize = 0;
        // Use shell-aware tokenization to respect $(...), `...`, and quotes
        {
            var ti: usize = 0;
            while (ti < items_str.len) {
                while (ti < items_str.len and (items_str[ti] == ' ' or items_str[ti] == '\t')) ti += 1;
                if (ti >= items_str.len) break;
                const word_start = ti;
                var paren_depth: u32 = 0;
                var in_sq = false;
                var in_dq = false;
                var in_bt = false;
                while (ti < items_str.len) {
                    const c = items_str[ti];
                    if (in_sq) {
                        if (c == '\'') in_sq = false;
                        ti += 1;
                        continue;
                    }
                    if (c == '\'' and !in_dq and paren_depth == 0 and !in_bt) {
                        in_sq = true;
                        ti += 1;
                        continue;
                    }
                    if (c == '"' and !in_sq) {
                        in_dq = !in_dq;
                        ti += 1;
                        continue;
                    }
                    if (c == '`') {
                        in_bt = !in_bt;
                        ti += 1;
                        continue;
                    }
                    if (!in_dq and !in_bt and paren_depth == 0 and (c == ' ' or c == '\t')) break;
                    if (c == '$' and ti + 1 < items_str.len and items_str[ti + 1] == '(') {
                        paren_depth += 1;
                        ti += 2;
                        continue;
                    }
                    if (c == '(' and paren_depth > 0) {
                        paren_depth += 1;
                        ti += 1;
                        continue;
                    }
                    if (c == ')' and paren_depth > 0) {
                        paren_depth -= 1;
                        ti += 1;
                        continue;
                    }
                    ti += 1;
                }
                if (ti > word_start) {
                    if (items_count >= items_buffer.len) return error.TooManyItems;
                    items_buffer[items_count] = try self.allocator.dupe(u8, items_str[word_start..ti]);
                    items_count += 1;
                }
            }
        }

        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;
        var nest_depth: u32 = 0;
        var nest_buf: [4096]u8 = undefined;
        var nest_len: usize = 0;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (isKeyword(line, "do") and nest_depth == 0) continue;

            if (nest_depth > 0) {
                if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "for ") or
                    std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "until ") or
                    std.mem.startsWith(u8, line, "case ")) nest_depth += 1 else if (isKeyword(line, "fi") or isKeyword(line, "done") or
                    isKeyword(line, "esac")) nest_depth -= 1;
                if (nest_len > 0 and nest_len + 2 < nest_buf.len) {
                    nest_buf[nest_len] = ';';
                    nest_buf[nest_len + 1] = ' ';
                    nest_len += 2;
                }
                const cl = @min(line.len, nest_buf.len - nest_len);
                @memcpy(nest_buf[nest_len .. nest_len + cl], line[0..cl]);
                nest_len += cl;
                if (nest_depth == 0) {
                    if (body_count >= body_buffer.len) return error.TooManyLines;
                    body_buffer[body_count] = try self.allocator.dupe(u8, nest_buf[0..nest_len]);
                    body_count += 1;
                    nest_len = 0;
                }
                continue;
            }

            if (isKeyword(line, "done")) break;

            if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "for ") or
                std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "until ") or
                std.mem.startsWith(u8, line, "case "))
            {
                nest_depth = 1;
                nest_len = 0;
                const cl = @min(line.len, nest_buf.len);
                @memcpy(nest_buf[0..cl], line[0..cl]);
                nest_len = cl;
                continue;
            }

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const items = try self.allocator.alloc([]const u8, items_count);
        errdefer self.allocator.free(items);
        @memcpy(items, items_buffer[0..items_count]);

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        return .{
            .loop = ForLoop{
                .variable = variable,
                .items = items,
                .body = body,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse C-style for loop: for ((init; condition; update))
    pub fn parseCStyleFor(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { loop: CStyleForLoop, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "for ((")) return error.InvalidCStyleFor;

        // Find the closing ))
        const expr_start = 6; // After "for (("
        const expr_end = std.mem.indexOf(u8, first_line[expr_start..], "))") orelse return error.InvalidCStyleFor;
        const expr = first_line[expr_start..][0..expr_end];

        // Split by semicolons: init; condition; update
        var parts: [3]?[]const u8 = .{ null, null, null };
        var parts_count: usize = 0;
        var part_iter = std.mem.splitSequence(u8, expr, ";");
        while (part_iter.next()) |part| : (parts_count += 1) {
            if (parts_count >= 3) return error.InvalidCStyleFor;
            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                parts[parts_count] = try self.allocator.dupe(u8, trimmed);
            }
        }

        // Parse body
        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (isKeyword(line, "do")) continue;
            if (isKeyword(line, "done")) break;

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        return .{
            .loop = CStyleForLoop{
                .init = parts[0],
                .condition = parts[1],
                .update = parts[2],
                .body = body,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse select menu: select VAR in ITEM1 ITEM2 ITEM3
    pub fn parseSelect(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { menu: SelectMenu, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "select ")) return error.InvalidSelect;

        // Parse: select VAR in ITEM1 ITEM2 ITEM3
        const parts_start = 7; // After "select "
        const in_pos = std.mem.indexOf(u8, first_line[parts_start..], " in ") orelse return error.InvalidSelect;

        const variable = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[parts_start..][0..in_pos], &std.ascii.whitespace));

        const items_start = parts_start + in_pos + 4; // After " in "
        const items_end = std.mem.indexOf(u8, first_line[items_start..], ";") orelse first_line[items_start..].len;
        const items_str = std.mem.trim(u8, first_line[items_start..][0..items_end], &std.ascii.whitespace);

        var items_buffer: [100][]const u8 = undefined;
        var items_count: usize = 0;
        var items_iter = std.mem.tokenizeAny(u8, items_str, " \t");
        while (items_iter.next()) |item| {
            if (items_count >= items_buffer.len) return error.TooManyItems;
            items_buffer[items_count] = try self.allocator.dupe(u8, item);
            items_count += 1;
        }

        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (isKeyword(line, "do")) continue;
            if (isKeyword(line, "done")) break;

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const items = try self.allocator.alloc([]const u8, items_count);
        @memcpy(items, items_buffer[0..items_count]);

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        // Default PS3 prompt
        const prompt = try self.allocator.dupe(u8, "#? ");

        return .{
            .menu = SelectMenu{
                .variable = variable,
                .items = items,
                .body = body,
                .prompt = prompt,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse case statement: case VALUE in pattern1) body;; pattern2) body;; esac
    /// Supports:
    ///   ;; - normal termination
    ///   ;& - fallthrough to next case body
    ///   ;;& - continue testing patterns
    pub fn parseCase(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { stmt: CaseStatement, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "case ")) return error.InvalidCase;

        // Parse: case VALUE in
        const value_start = 5; // After "case "
        const in_pos = std.mem.indexOf(u8, first_line[value_start..], " in") orelse return error.InvalidCase;
        const value = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[value_start..][0..in_pos], &std.ascii.whitespace));

        var cases_buffer: [100]CaseClause = undefined;
        var cases_count: usize = 0;

        var current_patterns: [20][]const u8 = undefined;
        var current_patterns_count: usize = 0;
        var current_body: [100][]const u8 = undefined;
        var current_body_count: usize = 0;
        var in_case_body = false;

        var i = start + 1;
        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            // Skip empty lines and comments
            if (line.len == 0 or line[0] == '#') continue;

            // End of case statement
            if (isKeyword(line, "esac")) break;

            // Check for case pattern line: pattern1|pattern2)
            if (!in_case_body) {
                // Look for pattern line ending with )
                if (std.mem.indexOf(u8, line, ")")) |paren_pos| {
                    const patterns_str = line[0..paren_pos];
                    // Split patterns by |
                    var pattern_iter = std.mem.splitScalar(u8, patterns_str, '|');
                    while (pattern_iter.next()) |pattern| {
                        const trimmed_pattern = std.mem.trim(u8, pattern, &std.ascii.whitespace);
                        if (trimmed_pattern.len > 0) {
                            if (current_patterns_count >= current_patterns.len) return error.TooManyPatterns;
                            current_patterns[current_patterns_count] = try self.allocator.dupe(u8, trimmed_pattern);
                            current_patterns_count += 1;
                        }
                    }
                    in_case_body = true;

                    // Check if there's inline body after the )
                    const after_paren = line[paren_pos + 1 ..];
                    const trimmed_after = std.mem.trim(u8, after_paren, &std.ascii.whitespace);
                    if (trimmed_after.len > 0) {
                        // Check for inline terminator
                        const terminator_result = self.detectTerminator(trimmed_after);
                        if (terminator_result.body.len > 0) {
                            if (current_body_count >= current_body.len) return error.TooManyLines;
                            current_body[current_body_count] = try self.allocator.dupe(u8, terminator_result.body);
                            current_body_count += 1;
                        }
                        if (terminator_result.found) {
                            // Complete this case clause
                            if (cases_count >= cases_buffer.len) return error.TooManyCases;
                            const patterns = try self.allocator.alloc([]const u8, current_patterns_count);
                            @memcpy(patterns, current_patterns[0..current_patterns_count]);
                            const body = try self.allocator.alloc([]const u8, current_body_count);
                            @memcpy(body, current_body[0..current_body_count]);

                            cases_buffer[cases_count] = CaseClause{
                                .patterns = patterns,
                                .body = body,
                                .terminator = terminator_result.terminator,
                            };
                            cases_count += 1;

                            // Reset for next case
                            current_patterns_count = 0;
                            current_body_count = 0;
                            in_case_body = false;
                        }
                    }
                }
            } else {
                // We're in a case body, look for terminator
                const terminator_result = self.detectTerminator(line);
                if (terminator_result.body.len > 0) {
                    if (current_body_count >= current_body.len) return error.TooManyLines;
                    current_body[current_body_count] = try self.allocator.dupe(u8, terminator_result.body);
                    current_body_count += 1;
                }
                if (terminator_result.found) {
                    // Complete this case clause
                    if (cases_count >= cases_buffer.len) return error.TooManyCases;
                    const patterns = try self.allocator.alloc([]const u8, current_patterns_count);
                    @memcpy(patterns, current_patterns[0..current_patterns_count]);
                    const body = try self.allocator.alloc([]const u8, current_body_count);
                    @memcpy(body, current_body[0..current_body_count]);

                    cases_buffer[cases_count] = CaseClause{
                        .patterns = patterns,
                        .body = body,
                        .terminator = terminator_result.terminator,
                    };
                    cases_count += 1;

                    // Reset for next case
                    current_patterns_count = 0;
                    current_body_count = 0;
                    in_case_body = false;
                } else if (!terminator_result.found and terminator_result.body.len == 0) {
                    // Regular body line (no terminator detected by detectTerminator means it returned the line as body)
                    if (current_body_count >= current_body.len) return error.TooManyLines;
                    current_body[current_body_count] = try self.allocator.dupe(u8, line);
                    current_body_count += 1;
                }
            }
        }

        const cases = try self.allocator.alloc(CaseClause, cases_count);
        @memcpy(cases, cases_buffer[0..cases_count]);

        return .{
            .stmt = CaseStatement{
                .value = value,
                .cases = cases,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Detect case terminator in a line (;;, ;&, or ;;&)
    /// Returns the body content before the terminator and the terminator type.
    /// Skips terminators that appear inside single or double quotes.
    fn detectTerminator(self: *ControlFlowParser, line: []const u8) struct { body: []const u8, terminator: CaseTerminator, found: bool } {
        _ = self;

        var i: usize = 0;
        var in_sq = false;
        var in_dq = false;
        while (i < line.len) : (i += 1) {
            const ch = line[i];
            if (ch == '\\' and !in_sq and i + 1 < line.len) {
                i += 1; // skip escaped char
                continue;
            }
            if (ch == '\'' and !in_dq) {
                in_sq = !in_sq;
                continue;
            }
            if (ch == '"' and !in_sq) {
                in_dq = !in_dq;
                continue;
            }
            if (!in_sq and !in_dq and ch == ';') {
                // Check for ;;& first (longest match)
                if (i + 2 < line.len and line[i + 1] == ';' and line[i + 2] == '&') {
                    return .{
                        .body = std.mem.trim(u8, line[0..i], &std.ascii.whitespace),
                        .terminator = .continue_testing,
                        .found = true,
                    };
                }
                // Check for ;& (fallthrough)
                if (i + 1 < line.len and line[i + 1] == '&') {
                    return .{
                        .body = std.mem.trim(u8, line[0..i], &std.ascii.whitespace),
                        .terminator = .fallthrough,
                        .found = true,
                    };
                }
                // Check for ;; (normal termination)
                if (i + 1 < line.len and line[i + 1] == ';') {
                    return .{
                        .body = std.mem.trim(u8, line[0..i], &std.ascii.whitespace),
                        .terminator = .normal,
                        .found = true,
                    };
                }
            }
        }

        // No terminator found
        return .{
            .body = line,
            .terminator = .normal,
            .found = false,
        };
    }
};
