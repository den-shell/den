//! Loop Execution Module
//!
//! This module implements shell loop constructs:
//! - C-style for loops: for ((init; cond; update)); do body; done
//! - Select loops: select VAR in items; do body; done
//! - Arithmetic evaluation for loop conditions

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Execute a one-line C-style for loop: for ((init; cond; update)); do cmd1; cmd2; done
pub fn executeCStyleForLoopOneline(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Find "for ((" and "))"
    if (!std.mem.startsWith(u8, trimmed, "for ((")) {
        try IO.eprint("den: syntax error: expected 'for ((...))\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Find the closing ))
    const expr_start = 6; // After "for (("
    const expr_end_rel = std.mem.indexOf(u8, trimmed[expr_start..], "))") orelse {
        try IO.eprint("den: syntax error: missing '))'n", .{});
        self.last_exit_code = 1;
        return;
    };
    const expr = trimmed[expr_start..][0..expr_end_rel];

    // Parse init; condition; update
    var parts: [3]?[]const u8 = .{ null, null, null };
    var parts_count: usize = 0;
    var part_iter = std.mem.splitSequence(u8, expr, ";");
    while (part_iter.next()) |part| : (parts_count += 1) {
        if (parts_count >= 3) break;
        const trimmed_part = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed_part.len > 0) {
            parts[parts_count] = trimmed_part;
        }
    }

    // Find "do" and "done" to extract body
    const after_parens = trimmed[expr_start + expr_end_rel + 2 ..];
    const trimmed_after = std.mem.trim(u8, after_parens, &std.ascii.whitespace);

    // Skip optional ';' after ))
    var body_start = trimmed_after;
    if (body_start.len > 0 and body_start[0] == ';') {
        body_start = std.mem.trim(u8, body_start[1..], &std.ascii.whitespace);
    }

    // Find "do" keyword
    if (!std.mem.startsWith(u8, body_start, "do")) {
        try IO.eprint("den: syntax error: expected 'do'\n", .{});
        self.last_exit_code = 1;
        return;
    }
    body_start = std.mem.trim(u8, body_start[2..], &std.ascii.whitespace);

    // Find "done" keyword as a standalone word, not inside quotes or as a substring.
    // Also accounts for nesting: inner for/while/until loops have their own "done".
    const done_pos = findStandaloneDone(body_start) orelse {
        try IO.eprint("den: syntax error: expected 'done'\n", .{});
        self.last_exit_code = 1;
        return;
    };
    const body_content = std.mem.trim(u8, body_start[0..done_pos], &std.ascii.whitespace);

    // Check if there's anything after 'done' that we need to execute later
    const after_done = body_start[done_pos + 4 ..];
    const remaining_commands = std.mem.trim(u8, after_done, &std.ascii.whitespace);

    // Split body by semicolons (respecting quotes)
    var body_cmds = std.ArrayList([]const u8).empty;
    defer body_cmds.deinit(self.allocator);

    var cmd_start: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;
    var i: usize = 0;
    while (i < body_content.len) : (i += 1) {
        const c = body_content[i];
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
        } else if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
        } else if (c == ';' and !in_single_quote and !in_double_quote) {
            const cmd = std.mem.trim(u8, body_content[cmd_start..i], &std.ascii.whitespace);
            if (cmd.len > 0) {
                try body_cmds.append(self.allocator, cmd);
            }
            cmd_start = i + 1;
        }
    }
    // Don't forget the last command
    const last_cmd = std.mem.trim(u8, body_content[cmd_start..], &std.ascii.whitespace);
    if (last_cmd.len > 0) {
        try body_cmds.append(self.allocator, last_cmd);
    }

    // Execute the C-style for loop inline
    // 1. Execute initialization
    if (parts[0]) |init_stmt| {
        executeArithmeticStatement(self, init_stmt);
    }

    // 2. Loop while condition is true
    var iteration_count: usize = 0;
    const max_iterations: usize = 100000; // Safety limit
    while (iteration_count < max_iterations) : (iteration_count += 1) {
        // Check condition
        if (parts[1]) |cond| {
            if (!evaluateArithmeticCondition(self, cond)) break;
        }

        // Execute body commands - directly using a simple method that avoids recursion
        for (body_cmds.items) |cmd| {
            executeCStyleLoopBodyCommand(self, cmd);
            if (self.break_levels > 0 or self.continue_levels > 0) break;
        }

        // Check for break after body execution
        if (self.break_levels > 0) {
            self.break_levels -= 1;
            break;
        }

        // Check for continue after body execution
        if (self.continue_levels > 0) {
            self.continue_levels -= 1;
            // Still execute update, then continue to next iteration
        }

        // Execute update
        if (parts[2]) |update| {
            executeArithmeticStatement(self, update);
        }
    }

    self.last_exit_code = 0;

    // Execute any remaining commands after "done"
    if (remaining_commands.len > 0) {
        // Strip leading semicolon if present
        var cmds_to_run = remaining_commands;
        if (cmds_to_run[0] == ';') {
            cmds_to_run = std.mem.trim(u8, cmds_to_run[1..], &std.ascii.whitespace);
        }
        if (cmds_to_run.len > 0) {
            // Execute the remaining commands using the simplified executor
            var iter = std.mem.splitScalar(u8, cmds_to_run, ';');
            while (iter.next()) |cmd| {
                const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
                if (trimmed_cmd.len > 0) {
                    executeCStyleLoopBodyCommand(self, trimmed_cmd);
                }
            }
        }
    }
}

/// Execute a command in the body of a C-style for loop
/// Handles variable assignments directly, delegates other commands to executeCommand
pub fn executeCStyleLoopBodyCommand(self: *Shell, cmd: []const u8) void {
    const trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // First, expand variables in the command
    var positional_params_slice: [64][]const u8 = undefined;
    var param_count: usize = 0;
    for (self.positional_params) |maybe_param| {
        if (maybe_param) |param| {
            positional_params_slice[param_count] = param;
            param_count += 1;
        }
    }

    var expander = Expansion.initWithShell(
        self.allocator,
        &self.environment,
        self.last_exit_code,
        positional_params_slice[0..param_count],
        self.shell_name,
        if (@import("builtin").os.tag == .windows) 0 else @as(i32, @intCast(self.job_manager.getLastPid())),
        self.last_arg,
        self,
    );
    const shell_mod = @import("../shell.zig");
    expander.exec_command_fn = &shell_mod.execCommandCallback;
    expander.arrays = &self.arrays;
    expander.assoc_arrays = &self.assoc_arrays;
    expander.var_attributes = &self.var_attributes;
    const expanded = expander.expand(trimmed) catch {
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(expanded);

    // Handle variable assignment: VAR=value (simple form without command)
    if (std.mem.indexOf(u8, expanded, "=")) |eq_pos| {
        const potential_var = expanded[0..eq_pos];
        var is_valid_var = potential_var.len > 0;
        for (potential_var) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                is_valid_var = false;
                break;
            }
        }
        if (is_valid_var) {
            if (std.mem.indexOf(u8, expanded[0..eq_pos], " ") == null) {
                const value = expanded[eq_pos + 1 ..];
                setArithVariable(self, potential_var, value);
                self.last_exit_code = 0;
                return;
            }
        }
    }

    // Use the full executeCommand for all other commands
    self.executeCommand(expanded) catch {
        self.last_exit_code = 1;
    };
}

/// Execute input that contains a C-style for loop with commands before and/or after
pub fn executeWithCStyleForLoop(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Find the position of "for ((" in the input
    const for_pos = std.mem.indexOf(u8, trimmed, "for ((") orelse {
        executeCStyleLoopBodyCommand(self, input);
        return;
    };

    // Extract any commands before the for loop
    const before_for = std.mem.trim(u8, trimmed[0..for_pos], &std.ascii.whitespace);

    // Execute commands before the for loop
    if (before_for.len > 0) {
        var cmds = before_for;
        if (cmds.len > 0 and cmds[cmds.len - 1] == ';') {
            cmds = std.mem.trim(u8, cmds[0 .. cmds.len - 1], &std.ascii.whitespace);
        }
        if (cmds.len > 0) {
            executeCStyleLoopBodyCommand(self, cmds);
        }
    }

    // Now extract the for loop
    const for_content = trimmed[for_pos..];

    // Find "done" keyword with proper boundary checking
    var done_pos: ?usize = null;
    var search_pos: usize = 0;
    while (search_pos < for_content.len) {
        const maybe_done = std.mem.indexOf(u8, for_content[search_pos..], "done");
        if (maybe_done) |pos| {
            const actual_pos = search_pos + pos;
            const at_start = actual_pos == 0 or !std.ascii.isAlphanumeric(for_content[actual_pos - 1]);
            const at_end = actual_pos + 4 >= for_content.len or
                !std.ascii.isAlphanumeric(for_content[actual_pos + 4]);
            if (at_start and at_end) {
                done_pos = actual_pos;
                break;
            }
            search_pos = actual_pos + 1;
        } else {
            break;
        }
    }

    if (done_pos == null) {
        try IO.eprint("den: syntax error: expected 'done'\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const for_loop_end = done_pos.? + 4;
    const for_loop = for_content[0..for_loop_end];

    // Execute the for loop
    try executeCStyleForLoopOneline(self, for_loop);

    // Extract any commands after the for loop
    if (for_loop_end < for_content.len) {
        var after_done = std.mem.trim(u8, for_content[for_loop_end..], &std.ascii.whitespace);
        if (after_done.len > 0 and after_done[0] == ';') {
            after_done = std.mem.trim(u8, after_done[1..], &std.ascii.whitespace);
        }
        if (after_done.len > 0) {
            executeCStyleLoopBodyCommand(self, after_done);
        }
    }
}

/// Execute a select loop: select VAR in ITEM1 ITEM2 ...; do BODY; done
pub fn executeSelectLoop(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    if (!std.mem.startsWith(u8, trimmed, "select ")) {
        try IO.eprint("den: syntax error: expected 'select'\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const after_select = trimmed[7..];

    const in_pos = std.mem.indexOf(u8, after_select, " in ") orelse {
        try IO.eprint("den: syntax error: expected 'in' in select\n", .{});
        self.last_exit_code = 1;
        return;
    };

    const variable = std.mem.trim(u8, after_select[0..in_pos], &std.ascii.whitespace);
    if (variable.len == 0) {
        try IO.eprint("den: syntax error: missing variable in select\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const after_in = after_select[in_pos + 4 ..];
    const do_pos = std.mem.indexOf(u8, after_in, "; do") orelse
        std.mem.indexOf(u8, after_in, ";do") orelse {
        try IO.eprint("den: syntax error: expected 'do' in select\n", .{});
        self.last_exit_code = 1;
        return;
    };

    const items_str = std.mem.trim(u8, after_in[0..do_pos], &std.ascii.whitespace);
    if (items_str.len == 0) {
        try IO.eprint("den: syntax error: no items in select\n", .{});
        self.last_exit_code = 1;
        return;
    }

    var items_buf: [100][]const u8 = undefined;
    var items_count: usize = 0;
    var items_iter = std.mem.tokenizeAny(u8, items_str, " \t");
    while (items_iter.next()) |item| {
        if (items_count >= items_buf.len) break;
        items_buf[items_count] = item;
        items_count += 1;
    }

    if (items_count == 0) {
        try IO.eprint("den: syntax error: no items in select\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const do_keyword_len: usize = if (std.mem.indexOf(u8, after_in, "; do") != null) 4 else 3;
    const body_start_offset = do_pos + do_keyword_len;
    const body_and_rest = after_in[body_start_offset..];

    const done_pos = std.mem.indexOf(u8, body_and_rest, "done") orelse {
        try IO.eprint("den: syntax error: expected 'done' in select\n", .{});
        self.last_exit_code = 1;
        return;
    };

    var body_str = std.mem.trim(u8, body_and_rest[0..done_pos], &std.ascii.whitespace);
    if (body_str.len > 0 and body_str[0] == ';') {
        body_str = std.mem.trim(u8, body_str[1..], &std.ascii.whitespace);
    }
    if (body_str.len > 0 and body_str[body_str.len - 1] == ';') {
        body_str = std.mem.trim(u8, body_str[0 .. body_str.len - 1], &std.ascii.whitespace);
    }

    const ps3 = self.environment.get("PS3") orelse "#? ";

    // Display menu on stderr (like bash)
    try IO.eprint("\n", .{});
    for (items_buf[0..items_count], 1..) |item, idx| {
        try IO.eprint("{d}) {s}\n", .{ idx, item });
    }

    // Main select loop
    while (true) {
        try IO.eprint("{s}", .{ps3});

        var input_buf: [1024]u8 = undefined;
        const bytes_read = if (comptime @import("builtin").os.tag == .windows) blk: {
            var n: u32 = 0;
            const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse break :blk @as(usize, 0);
            const success = @import("windows_compat").ReadFile(handle, &input_buf, @intCast(input_buf.len), &n, null);
            break :blk if (success == 0) @as(usize, 0) else @as(usize, n);
        } else std.posix.read(std.posix.STDIN_FILENO, &input_buf) catch |err| {
            if (err == error.WouldBlock) continue;
            break;
        };

        if (bytes_read == 0) break;

        const user_input = std.mem.trim(u8, input_buf[0..bytes_read], &std.ascii.whitespace);

        if (user_input.len == 0) {
            try IO.eprint("\n", .{});
            for (items_buf[0..items_count], 1..) |item, idx| {
                try IO.eprint("{d}) {s}\n", .{ idx, item });
            }
            continue;
        }

        const selection = std.fmt.parseInt(usize, user_input, 10) catch {
            setArithVariable(self, variable, "");
            setArithVariable(self, "REPLY", user_input);
            executeSelectBody(self, body_str);
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return;
                break;
            }
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return;
            }
            continue;
        };

        if (selection == 0 or selection > items_count) {
            setArithVariable(self, variable, "");
            var reply_buf: [32]u8 = undefined;
            const reply_str = std.fmt.bufPrint(&reply_buf, "{d}", .{selection}) catch continue;
            setArithVariable(self, "REPLY", reply_str);
            executeSelectBody(self, body_str);
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return;
                break;
            }
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return;
            }
            continue;
        }

        const selected_item = items_buf[selection - 1];
        setArithVariable(self, variable, selected_item);
        var reply_buf: [32]u8 = undefined;
        const reply_str = std.fmt.bufPrint(&reply_buf, "{d}", .{selection}) catch continue;
        setArithVariable(self, "REPLY", reply_str);

        executeSelectBody(self, body_str);

        if (self.break_levels > 0) {
            self.break_levels -= 1;
            if (self.break_levels > 0) return;
            break;
        }
        if (self.continue_levels > 0) {
            self.continue_levels -= 1;
            if (self.continue_levels > 0) return;
        }
    }

    self.last_exit_code = 0;
}

/// Execute select loop body command (non-recursive helper)
pub fn executeSelectBody(self: *Shell, body: []const u8) void {
    var cmd_iter = std.mem.splitSequence(u8, body, ";");
    while (cmd_iter.next()) |cmd| {
        const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
        if (trimmed_cmd.len == 0) continue;

        if (std.mem.eql(u8, trimmed_cmd, "break") or std.mem.startsWith(u8, trimmed_cmd, "break ")) {
            if (std.mem.startsWith(u8, trimmed_cmd, "break ")) {
                const level_str = std.mem.trim(u8, trimmed_cmd[6..], &std.ascii.whitespace);
                self.break_levels = std.fmt.parseInt(u32, level_str, 10) catch 1;
                if (self.break_levels == 0) self.break_levels = 1;
            } else {
                self.break_levels = 1;
            }
            return;
        }

        executeCStyleLoopBodyCommand(self, trimmed_cmd);

        if (self.break_levels > 0) return;
    }
}

/// Execute arithmetic statement (like i=0, i++, i+=2, etc.)
pub fn executeArithmeticStatement(self: *Shell, stmt: []const u8) void {
    const trimmed = std.mem.trim(u8, stmt, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // Handle i++ and i--
    if (std.mem.endsWith(u8, trimmed, "++")) {
        const var_name = trimmed[0 .. trimmed.len - 2];
        const current = getVariableValueForArith(self, var_name);
        const num = std.fmt.parseInt(i64, current, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num + 1}) catch return;
        setArithVariable(self, var_name, new_val);
        return;
    }
    if (std.mem.endsWith(u8, trimmed, "--")) {
        const var_name = trimmed[0 .. trimmed.len - 2];
        const current = getVariableValueForArith(self, var_name);
        const num = std.fmt.parseInt(i64, current, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num - 1}) catch return;
        setArithVariable(self, var_name, new_val);
        return;
    }

    // Handle compound assignment operators: <<=, >>=, +=, -=, *=, /=, %=, &=, |=, ^=
    // Check 3-char operators before 2-char ones
    const CompoundOp = struct { pattern: []const u8, len: u8 };
    const compound_ops = [_]CompoundOp{
        .{ .pattern = "<<=", .len = 3 },
        .{ .pattern = ">>=", .len = 3 },
        .{ .pattern = "+=", .len = 2 },
        .{ .pattern = "-=", .len = 2 },
        .{ .pattern = "*=", .len = 2 },
        .{ .pattern = "/=", .len = 2 },
        .{ .pattern = "%=", .len = 2 },
        .{ .pattern = "&=", .len = 2 },
        .{ .pattern = "|=", .len = 2 },
        .{ .pattern = "^=", .len = 2 },
    };
    for (compound_ops) |cop| {
        if (std.mem.indexOf(u8, trimmed, cop.pattern)) |pos| {
            const var_name = std.mem.trim(u8, trimmed[0..pos], &std.ascii.whitespace);
            const rhs_str = std.mem.trim(u8, trimmed[pos + cop.len ..], &std.ascii.whitespace);
            const current = getVariableValueForArith(self, var_name);
            const current_val = std.fmt.parseInt(i64, current, 10) catch 0;
            const rhs_val = evaluateArithmeticExpr(self, rhs_str);
            const result: i64 = if (std.mem.eql(u8, cop.pattern, "+="))
                current_val + rhs_val
            else if (std.mem.eql(u8, cop.pattern, "-="))
                current_val - rhs_val
            else if (std.mem.eql(u8, cop.pattern, "*="))
                current_val * rhs_val
            else if (std.mem.eql(u8, cop.pattern, "/="))
                if (rhs_val != 0) @divTrunc(current_val, rhs_val) else 0
            else if (std.mem.eql(u8, cop.pattern, "%="))
                if (rhs_val != 0) @rem(current_val, rhs_val) else 0
            else if (std.mem.eql(u8, cop.pattern, "<<=")) blk: {
                const shift_amt: u6 = @intCast(@min(@max(rhs_val, 0), 63));
                break :blk current_val << shift_amt;
            } else if (std.mem.eql(u8, cop.pattern, ">>=")) blk: {
                const shift_amt: u6 = @intCast(@min(@max(rhs_val, 0), 63));
                break :blk current_val >> shift_amt;
            } else if (std.mem.eql(u8, cop.pattern, "&="))
                current_val & rhs_val
            else if (std.mem.eql(u8, cop.pattern, "|="))
                current_val | rhs_val
            else if (std.mem.eql(u8, cop.pattern, "^="))
                current_val ^ rhs_val
            else
                current_val;
            var buf: [32]u8 = undefined;
            const new_val = std.fmt.bufPrint(&buf, "{d}", .{result}) catch return;
            setArithVariable(self, var_name, new_val);
            return;
        }
    }

    // Handle simple assignment: var=expr
    if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
        const var_name = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        const expr = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

        const value = evaluateArithmeticExpr(self, expr);
        var buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        setArithVariable(self, var_name, val_str);
    }
}

/// Set a variable for arithmetic operations
pub fn setArithVariable(self: *Shell, name: []const u8, value: []const u8) void {
    const resolved_name = self.resolveNameref(name);

    // Apply case conversion if variable has lowercase/uppercase attribute
    var final_value = value;
    var case_buf: ?[]u8 = null;
    if (self.var_attributes.get(resolved_name)) |attrs| {
        if (attrs.lowercase) {
            const lower = self.allocator.alloc(u8, value.len) catch null;
            if (lower) |buf| {
                for (value, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                case_buf = buf;
                final_value = buf;
            }
        } else if (attrs.uppercase) {
            const upper = self.allocator.alloc(u8, value.len) catch null;
            if (upper) |buf| {
                for (value, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
                case_buf = buf;
                final_value = buf;
            }
        }
    }

    // If inside a function and the variable exists as a local, update local instead
    if (self.function_manager.currentFrame()) |frame| {
        if (frame.local_vars.getKey(resolved_name)) |_| {
            const val = if (case_buf) |buf| buf else self.allocator.dupe(u8, final_value) catch return;
            const gop = frame.local_vars.getOrPut(resolved_name) catch {
                self.allocator.free(val);
                return;
            };
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = val;
            return;
        }
    }

    const val = if (case_buf) |buf| buf else self.allocator.dupe(u8, final_value) catch return;

    const gop = self.environment.getOrPut(resolved_name) catch {
        self.allocator.free(val);
        return;
    };
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = val;
    } else {
        const key = self.allocator.dupe(u8, resolved_name) catch {
            self.allocator.free(val);
            _ = self.environment.remove(resolved_name);
            return;
        };
        gop.key_ptr.* = key;
        gop.value_ptr.* = val;
    }
}

/// Evaluate arithmetic condition (returns true if non-zero)
pub fn evaluateArithmeticCondition(self: *Shell, cond: []const u8) bool {
    const trimmed = std.mem.trim(u8, cond, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;

    return evaluateArithmeticExpr(self, trimmed) != 0;
}

/// Evaluate arithmetic expression using the proper Arithmetic evaluator
/// which handles operator precedence correctly.
pub fn evaluateArithmeticExpr(self: *Shell, expr: []const u8) i64 {
    const Arithmetic = @import("../utils/arithmetic.zig").Arithmetic;
    var arith = Arithmetic.initWithVariables(self.allocator, &self.environment);
    arith.arrays = &self.arrays;
    return arith.eval(expr) catch 0;
}

/// Get variable value (helper for arithmetic)
pub fn getVariableValueForArith(self: *Shell, name: []const u8) []const u8 {
    if (self.environment.get(name)) |val| {
        return val;
    }
    return "0";
}

/// Find the position of "done" as a standalone keyword in a one-line loop body.
/// This correctly handles:
///   - Word boundaries: "undone" or "done_flag" are NOT matched
///   - Quoted strings: `echo "not done yet"` does not match
///   - Nesting: inner for/while/until/select loops have their own "done"
/// Returns the byte offset of the standalone "done", or null if not found.
fn findStandaloneDone(input: []const u8) ?usize {
    var i: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;
    var nesting_depth: u32 = 0;

    while (i < input.len) {
        const c = input[i];

        // Track quote state (single quotes are not escaped inside double quotes and vice versa)
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            i += 1;
            continue;
        }
        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            i += 1;
            continue;
        }

        // Skip content inside quotes entirely
        if (in_single_quote or in_double_quote) {
            i += 1;
            continue;
        }

        // Track nesting: "for ", "while ", "until ", "select " increase depth
        // We check for these keywords followed by a space to avoid false matches
        if (startsWithKeyword(input[i..], "for") or
            startsWithKeyword(input[i..], "while") or
            startsWithKeyword(input[i..], "until") or
            startsWithKeyword(input[i..], "select"))
        {
            // Only count as nesting if preceded by start-of-string, whitespace, or semicolon
            if (i == 0 or input[i - 1] == ' ' or input[i - 1] == '\t' or input[i - 1] == ';' or input[i - 1] == '\n') {
                nesting_depth += 1;
            }
            i += 1;
            continue;
        }

        // Check for "done" as a standalone word
        if (i + 4 <= input.len and std.mem.eql(u8, input[i..][0..4], "done")) {
            // Check left boundary: must be at start or preceded by whitespace/semicolon
            const left_ok = (i == 0) or input[i - 1] == ' ' or input[i - 1] == '\t' or input[i - 1] == ';' or input[i - 1] == '\n';
            // Check right boundary: must be at end or followed by whitespace/semicolon/EOF
            const right_ok = (i + 4 >= input.len) or input[i + 4] == ' ' or input[i + 4] == '\t' or input[i + 4] == ';' or input[i + 4] == '\n';

            if (left_ok and right_ok) {
                if (nesting_depth > 0) {
                    // This "done" closes an inner loop, not ours
                    nesting_depth -= 1;
                    i += 4;
                    continue;
                }
                return i;
            }
        }

        i += 1;
    }

    return null;
}

/// Check if a slice starts with a keyword followed by a word boundary (space, tab, semicolon, or end).
fn startsWithKeyword(input: []const u8, keyword: []const u8) bool {
    if (input.len < keyword.len) return false;
    if (!std.mem.eql(u8, input[0..keyword.len], keyword)) return false;
    if (input.len == keyword.len) return true;
    const next = input[keyword.len];
    return next == ' ' or next == '\t' or next == ';' or next == '\n' or next == '(';
}
