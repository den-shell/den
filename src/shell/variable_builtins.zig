//! Variable Builtins Implementation
//!
//! This module implements variable-related shell builtins:
//! - local: declare local variables in function scope
//! - declare/typeset: declare variables with attributes
//! - readonly: declare readonly variables
//! - let: evaluate arithmetic expressions

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const arithmetic = @import("../utils/arithmetic.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: local - declare local variables in function scope
pub fn builtinLocal(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Parse flags
    var attrs = types.VarAttributes{};
    var arg_start: usize = 0;
    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            arg_start += 1;
            for (arg[1..]) |c| {
                switch (c) {
                    'i' => attrs.integer = true,
                    'l' => attrs.lowercase = true,
                    'u' => attrs.uppercase = true,
                    'r' => attrs.readonly = true,
                    'x' => attrs.exported = true,
                    'a' => attrs.indexed_array = true,
                    'A' => attrs.assoc_array = true,
                    'n' => attrs.nameref = true,
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    // Check if we're inside a function
    if (shell.function_manager.currentFrame() == null) {
        // Outside function - use environment variables as fallback
        if (arg_start >= cmd.args.len) {
            try IO.eprint("local: can only be used in a function\n", .{});
            shell.last_exit_code = 1;
            return;
        }

        // Still set variables for compatibility
        for (cmd.args[arg_start..]) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const var_name = arg[0..eq_pos];
                var var_value: []const u8 = arg[eq_pos + 1 ..];

                // Apply integer attribute
                var int_buf: [32]u8 = undefined;
                if (attrs.integer) {
                    var arith = arithmetic.Arithmetic.initWithVariables(shell.allocator, &shell.environment);
                    const result = arith.eval(var_value) catch 0;
                    const num_str = std.fmt.bufPrint(&int_buf, "{d}", .{result}) catch "0";
                    var_value = num_str;
                }

                const value = try shell.allocator.dupe(u8, var_value);
                const gop = try shell.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    shell.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    const key = try shell.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
                try setVarAttributes(shell, var_name, attrs, false);
            }
        }
        shell.last_exit_code = 0;
        return;
    }

    if (arg_start >= cmd.args.len) {
        // List local variables in current function
        if (shell.function_manager.currentFrame()) |frame| {
            var iter = frame.local_vars.iterator();
            while (iter.next()) |entry| {
                try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
        shell.last_exit_code = 0;
        return;
    }

    // Set local variables in function scope
    for (cmd.args[arg_start..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const var_name = arg[0..eq_pos];
            var var_value: []const u8 = arg[eq_pos + 1 ..];

            // Apply integer attribute
            var int_buf: [32]u8 = undefined;
            if (attrs.integer) {
                var arith = arithmetic.Arithmetic.initWithVariables(shell.allocator, &shell.environment);
                const result = arith.eval(var_value) catch 0;
                const num_str = std.fmt.bufPrint(&int_buf, "{d}", .{result}) catch "0";
                var_value = num_str;
            }

            // Apply case conversion. setLocal dupes the value internally, so we
            // use a temporary stack buffer for small values and only heap-allocate
            // when necessary. This avoids the double-allocation pattern of
            // alloc→setLocal(dupe)→free.
            if (attrs.lowercase) {
                var stack_buf: [512]u8 = undefined;
                const buf = if (var_value.len <= stack_buf.len)
                    stack_buf[0..var_value.len]
                else
                    try shell.allocator.alloc(u8, var_value.len);
                defer if (var_value.len > stack_buf.len) shell.allocator.free(buf);
                for (var_value, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                shell.function_manager.setLocal(var_name, buf) catch {};
            } else if (attrs.uppercase) {
                var stack_buf: [512]u8 = undefined;
                const buf = if (var_value.len <= stack_buf.len)
                    stack_buf[0..var_value.len]
                else
                    try shell.allocator.alloc(u8, var_value.len);
                defer if (var_value.len > stack_buf.len) shell.allocator.free(buf);
                for (var_value, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
                shell.function_manager.setLocal(var_name, buf) catch {};
            } else {
                shell.function_manager.setLocal(var_name, var_value) catch {
                    try IO.eprint("local: {s}: failed to set variable\n", .{var_name});
                    shell.last_exit_code = 1;
                    return;
                };
            }
            try setVarAttributes(shell, var_name, attrs, false);
        } else {
            // Declare empty variable
            shell.function_manager.setLocal(arg, "") catch {
                try IO.eprint("local: {s}: failed to set variable\n", .{arg});
                shell.last_exit_code = 1;
                return;
            };
        }
    }
    shell.last_exit_code = 0;
}

/// Builtin: declare/typeset - declare variables with attributes
/// Flags: -a (array), -A (assoc), -i (integer), -l (lowercase), -u (uppercase),
///        -r (readonly), -x (export), -n (nameref), -p (print), -f (functions)
pub fn builtinDeclare(shell: *Shell, cmd: *types.ParsedCommand) !void {
    var attrs = types.VarAttributes{};
    var print_mode = false;
    var function_mode = false;
    var remove_attrs = false;
    var arg_start: usize = 0;

    // Parse flags
    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            arg_start += 1;
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => attrs.indexed_array = true,
                    'A' => attrs.assoc_array = true,
                    'i' => attrs.integer = true,
                    'l' => attrs.lowercase = true,
                    'u' => attrs.uppercase = true,
                    'r' => attrs.readonly = true,
                    'x' => attrs.exported = true,
                    'n' => attrs.nameref = true,
                    'p' => print_mode = true,
                    'f' => function_mode = true,
                    else => {},
                }
            }
        } else if (arg.len > 0 and arg[0] == '+') {
            // +attr removes the attribute
            arg_start += 1;
            remove_attrs = true;
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => attrs.indexed_array = true,
                    'A' => attrs.assoc_array = true,
                    'i' => attrs.integer = true,
                    'l' => attrs.lowercase = true,
                    'u' => attrs.uppercase = true,
                    'r' => attrs.readonly = true,
                    'x' => attrs.exported = true,
                    'n' => attrs.nameref = true,
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    // Print mode: show variables with their attributes
    if (print_mode and arg_start >= cmd.args.len) {
        // Print all variables with attributes
        var it = shell.var_attributes.iterator();
        while (it.next()) |entry| {
            try printDeclareWithValue(shell, entry.key_ptr.*, entry.value_ptr.*);
        }
        shell.last_exit_code = 0;
        return;
    }

    // Print mode with specific variable names: declare -p var1 var2 ...
    if (print_mode) {
        for (cmd.args[arg_start..]) |var_name| {
            const var_attrs = shell.var_attributes.get(var_name) orelse types.VarAttributes{};
            try printDeclareWithValue(shell, var_name, var_attrs);
        }
        shell.last_exit_code = 0;
        return;
    }

    // Function mode: show functions
    if (function_mode and arg_start >= cmd.args.len) {
        var it = shell.function_manager.functions.iterator();
        while (it.next()) |entry| {
            try IO.print("{s} ()\n{{\n", .{entry.key_ptr.*});
            for (entry.value_ptr.*.body) |line| {
                try IO.print("    {s}\n", .{line});
            }
            try IO.print("}}\n", .{});
        }
        shell.last_exit_code = 0;
        return;
    }

    // No arguments after flags - just declare with attributes
    if (arg_start >= cmd.args.len) {
        shell.last_exit_code = 0;
        return;
    }

    // Process variable declarations
    for (cmd.args[arg_start..]) |arg| {
        // Parse name[=value] or name[key]=value for assoc arrays
        var var_name: []const u8 = undefined;
        var var_value: ?[]const u8 = null;
        var assoc_key: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const name_part = arg[0..eq_pos];
            var_value = arg[eq_pos + 1 ..];

            // Check for array subscript: name[key]
            if (std.mem.indexOfScalar(u8, name_part, '[')) |bracket_pos| {
                if (std.mem.indexOfScalar(u8, name_part, ']')) |close_pos| {
                    if (close_pos > bracket_pos) {
                        var_name = name_part[0..bracket_pos];
                        assoc_key = name_part[bracket_pos + 1 .. close_pos];
                    } else {
                        var_name = name_part;
                    }
                } else {
                    var_name = name_part;
                }
            } else {
                var_name = name_part;
            }
        } else {
            var_name = arg;
        }

        // Check if readonly
        if (shell.var_attributes.get(var_name)) |existing| {
            if (existing.readonly and !remove_attrs) {
                try IO.eprint("den: {s}: readonly variable\n", .{var_name});
                shell.last_exit_code = 1;
                continue;
            }
        }

        // Handle associative array assignment
        if (attrs.assoc_array or assoc_key != null) {
            const gop = try shell.assoc_arrays.getOrPut(var_name);
            if (!gop.found_existing) {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = std.StringHashMap([]const u8).init(shell.allocator);
            }

            if (assoc_key) |key| {
                if (var_value) |value| {
                    const inner_gop = try gop.value_ptr.getOrPut(key);
                    if (inner_gop.found_existing) {
                        shell.allocator.free(inner_gop.value_ptr.*);
                    } else {
                        inner_gop.key_ptr.* = try shell.allocator.dupe(u8, key);
                    }
                    inner_gop.value_ptr.* = try shell.allocator.dupe(u8, value);
                }
            }

            // Store attributes
            try setVarAttributes(shell, var_name, attrs, remove_attrs);
        } else if (attrs.indexed_array) {
            // Handle indexed array
            if (var_value) |val| {
                if (val.len > 0 and val[0] == '(') {
                    // Reconstruct the full array assignment: name=(values...)
                    // The value may have been split across args by tokenizer
                    var buf: [4096]u8 = undefined;
                    var pos: usize = 0;
                    // Write "name="
                    const name_len = @min(var_name.len, buf.len - pos);
                    @memcpy(buf[pos .. pos + name_len], var_name[0..name_len]);
                    pos += name_len;
                    if (pos < buf.len) {
                        buf[pos] = '=';
                        pos += 1;
                    }
                    // Write first value part
                    const val_len = @min(val.len, buf.len - pos);
                    @memcpy(buf[pos .. pos + val_len], val[0..val_len]);
                    pos += val_len;
                    // If value doesn't end with ), join remaining args
                    if (val[val.len - 1] != ')') {
                        for (cmd.args[arg_start + 1 ..]) |extra| {
                            if (pos < buf.len) {
                                buf[pos] = ' ';
                                pos += 1;
                            }
                            const extra_len = @min(extra.len, buf.len - pos);
                            @memcpy(buf[pos .. pos + extra_len], extra[0..extra_len]);
                            pos += extra_len;
                            if (extra.len > 0 and extra[extra.len - 1] == ')') break;
                        }
                    }
                    const variable_handling = @import("variable_handling.zig");
                    try variable_handling.executeArrayAssignment(shell, buf[0..pos]);
                    try setVarAttributes(shell, var_name, attrs, remove_attrs);
                    shell.last_exit_code = 0;
                    return;
                }
            }
            const gop = try shell.arrays.getOrPut(var_name);
            if (!gop.found_existing) {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = try types.IndexedArray.initEmpty(shell.allocator);
            }
            try setVarAttributes(shell, var_name, attrs, remove_attrs);
        } else {
            // Regular variable
            if (var_value) |value| {
                var final_value = value;

                // Apply integer attribute
                var int_buf: [32]u8 = undefined;
                if (attrs.integer) {
                    // Evaluate as arithmetic expression
                    var arith = arithmetic.Arithmetic.initWithVariables(shell.allocator, &shell.environment);
                    const result = arith.eval(value) catch 0;
                    const num_str = std.fmt.bufPrint(&int_buf, "{d}", .{result}) catch "0";
                    final_value = num_str;
                }

                // Apply case conversion
                if (attrs.lowercase) {
                    const lower = try shell.allocator.alloc(u8, final_value.len);
                    for (final_value, 0..) |c, i| {
                        lower[i] = std.ascii.toLower(c);
                    }
                    final_value = lower;
                } else if (attrs.uppercase) {
                    const upper = try shell.allocator.alloc(u8, final_value.len);
                    for (final_value, 0..) |c, i| {
                        upper[i] = std.ascii.toUpper(c);
                    }
                    final_value = upper;
                }

                // Set the variable
                // If case conversion already allocated, reuse it; otherwise dupe
                const dup_value = if (attrs.lowercase or attrs.uppercase)
                    final_value // already heap-allocated by alloc() above
                else
                    try shell.allocator.dupe(u8, final_value);
                const gop = try shell.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    shell.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = dup_value;
                } else {
                    const key = try shell.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = dup_value;
                }

                // Export if -x
                if (attrs.exported) {
                    // Variable is already in environment, which is exported
                }
            }

            try setVarAttributes(shell, var_name, attrs, remove_attrs);
        }
    }

    if (shell.last_exit_code != 1) {
        shell.last_exit_code = 0;
    }
}

/// Helper to print declare output with value
fn printDeclareWithValue(shell: *Shell, name: []const u8, attrs: types.VarAttributes) !void {
    var flags_buf: [16]u8 = undefined;
    var flags_len: usize = 0;

    if (attrs.readonly) {
        flags_buf[flags_len] = 'r';
        flags_len += 1;
    }
    if (attrs.integer) {
        flags_buf[flags_len] = 'i';
        flags_len += 1;
    }
    if (attrs.exported) {
        flags_buf[flags_len] = 'x';
        flags_len += 1;
    }
    if (attrs.lowercase) {
        flags_buf[flags_len] = 'l';
        flags_len += 1;
    }
    if (attrs.uppercase) {
        flags_buf[flags_len] = 'u';
        flags_len += 1;
    }
    if (attrs.nameref) {
        flags_buf[flags_len] = 'n';
        flags_len += 1;
    }
    if (attrs.indexed_array) {
        flags_buf[flags_len] = 'a';
        flags_len += 1;
    }
    if (attrs.assoc_array) {
        flags_buf[flags_len] = 'A';
        flags_len += 1;
    }

    // Check for array value
    if (attrs.indexed_array) {
        if (shell.arrays.get(name)) |array| {
            if (flags_len > 0) {
                try IO.print("declare -{s} {s}=", .{ flags_buf[0..flags_len], name });
            } else {
                try IO.print("declare -- {s}=", .{name});
            }
            try IO.print("(", .{});
            for (array.values, 0..) |elem, i| {
                if (i > 0) try IO.print(" ", .{});
                try IO.print("[{d}]=\"{s}\"", .{ array.indices[i], elem });
            }
            try IO.print(")\n", .{});
            return;
        }
    }

    // Check for assoc array value
    if (attrs.assoc_array) {
        if (shell.assoc_arrays.get(name)) |assoc| {
            if (flags_len > 0) {
                try IO.print("declare -{s} {s}=", .{ flags_buf[0..flags_len], name });
            } else {
                try IO.print("declare -- {s}=", .{name});
            }
            try IO.print("(", .{});
            var first = true;
            var iter = assoc.iterator();
            while (iter.next()) |entry| {
                if (!first) try IO.print(" ", .{});
                try IO.print("[{s}]=\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            }
            try IO.print(")\n", .{});
            return;
        }
    }

    // Regular variable
    if (flags_len > 0) {
        if (shell.environment.get(name)) |value| {
            try IO.print("declare -{s} {s}=\"{s}\"\n", .{ flags_buf[0..flags_len], name, value });
        } else {
            try IO.print("declare -{s} {s}\n", .{ flags_buf[0..flags_len], name });
        }
    } else {
        if (shell.environment.get(name)) |value| {
            try IO.print("declare -- {s}=\"{s}\"\n", .{ name, value });
        } else {
            try IO.print("declare -- {s}\n", .{name});
        }
    }
}

/// Helper to print declare output
pub fn printDeclare(name: []const u8, attrs: types.VarAttributes) !void {
    var flags_buf: [16]u8 = undefined;
    var flags_len: usize = 0;

    if (attrs.readonly) {
        flags_buf[flags_len] = 'r';
        flags_len += 1;
    }
    if (attrs.integer) {
        flags_buf[flags_len] = 'i';
        flags_len += 1;
    }
    if (attrs.exported) {
        flags_buf[flags_len] = 'x';
        flags_len += 1;
    }
    if (attrs.lowercase) {
        flags_buf[flags_len] = 'l';
        flags_len += 1;
    }
    if (attrs.uppercase) {
        flags_buf[flags_len] = 'u';
        flags_len += 1;
    }
    if (attrs.nameref) {
        flags_buf[flags_len] = 'n';
        flags_len += 1;
    }
    if (attrs.indexed_array) {
        flags_buf[flags_len] = 'a';
        flags_len += 1;
    }
    if (attrs.assoc_array) {
        flags_buf[flags_len] = 'A';
        flags_len += 1;
    }

    if (flags_len > 0) {
        try IO.print("declare -{s} {s}\n", .{ flags_buf[0..flags_len], name });
    } else {
        try IO.print("declare -- {s}\n", .{name});
    }
}

/// Helper to set variable attributes
pub fn setVarAttributes(shell: *Shell, name: []const u8, attrs: types.VarAttributes, remove: bool) !void {
    const gop = try shell.var_attributes.getOrPut(name);
    if (!gop.found_existing) {
        const key = try shell.allocator.dupe(u8, name);
        gop.key_ptr.* = key;
        gop.value_ptr.* = types.VarAttributes{};
    }

    if (remove) {
        // Remove specified attributes
        if (attrs.readonly) {
            // In bash, once a variable is readonly, you cannot remove the readonly attribute.
            if (gop.value_ptr.*.readonly) {
                try IO.eprint("den: {s}: readonly variable\n", .{name});
                shell.last_exit_code = 1;
                return;
            }
            gop.value_ptr.*.readonly = false;
        }
        if (attrs.integer) gop.value_ptr.*.integer = false;
        if (attrs.exported) gop.value_ptr.*.exported = false;
        if (attrs.lowercase) gop.value_ptr.*.lowercase = false;
        if (attrs.uppercase) gop.value_ptr.*.uppercase = false;
        if (attrs.nameref) gop.value_ptr.*.nameref = false;
        if (attrs.indexed_array) gop.value_ptr.*.indexed_array = false;
        if (attrs.assoc_array) gop.value_ptr.*.assoc_array = false;
        if (attrs.immutable) gop.value_ptr.*.immutable = false;
    } else {
        // Add specified attributes
        if (attrs.readonly) gop.value_ptr.*.readonly = true;
        if (attrs.integer) gop.value_ptr.*.integer = true;
        if (attrs.exported) gop.value_ptr.*.exported = true;
        if (attrs.lowercase) gop.value_ptr.*.lowercase = true;
        if (attrs.uppercase) gop.value_ptr.*.uppercase = true;
        if (attrs.nameref) gop.value_ptr.*.nameref = true;
        if (attrs.indexed_array) gop.value_ptr.*.indexed_array = true;
        if (attrs.assoc_array) gop.value_ptr.*.assoc_array = true;
        if (attrs.immutable) gop.value_ptr.*.immutable = true;
    }
}

/// Builtin: readonly - declare readonly variables
pub fn builtinReadonly(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        // Print all readonly variables
        var it = shell.var_attributes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.readonly) {
                if (shell.environment.get(entry.key_ptr.*)) |value| {
                    try IO.print("declare -r {s}=\"{s}\"\n", .{ entry.key_ptr.*, value });
                } else {
                    try IO.print("declare -r {s}\n", .{entry.key_ptr.*});
                }
            }
        }
        shell.last_exit_code = 0;
        return;
    }

    // Set variables as readonly
    for (cmd.args) |arg| {
        var var_name: []const u8 = undefined;
        var var_value: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            var_name = arg[0..eq_pos];
            var_value = arg[eq_pos + 1 ..];
        } else {
            var_name = arg;
        }

        // Check if already readonly
        if (shell.var_attributes.get(var_name)) |existing| {
            if (existing.readonly) {
                try IO.eprint("den: {s}: readonly variable\n", .{var_name});
                shell.last_exit_code = 1;
                continue;
            }
        }

        // Set value if provided
        if (var_value) |value| {
            const dup_value = try shell.allocator.dupe(u8, value);
            const gop = try shell.environment.getOrPut(var_name);
            if (gop.found_existing) {
                shell.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = dup_value;
            } else {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = dup_value;
            }
        }

        // Mark as readonly
        const gop = try shell.var_attributes.getOrPut(var_name);
        if (!gop.found_existing) {
            const key = try shell.allocator.dupe(u8, var_name);
            gop.key_ptr.* = key;
            gop.value_ptr.* = types.VarAttributes{};
        }
        gop.value_ptr.*.readonly = true;
    }
    if (shell.last_exit_code != 1) {
        shell.last_exit_code = 0;
    }
}

/// Builtin: typeset - alias for declare (bash compatibility)
pub fn builtinTypeset(shell: *Shell, cmd: *types.ParsedCommand) !void {
    try builtinDeclare(shell, cmd);
}

/// Builtin: let - evaluate arithmetic expressions
pub fn builtinLet(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: let: usage: let expression [expression ...]\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    var arith = arithmetic.Arithmetic.initWithVariables(shell.allocator, &shell.environment);
    var last_result: i64 = 0;

    for (cmd.args) |arg| {
        // Handle assignment: var=expr or var+=expr etc
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            // Check for compound assignment operators
            var op_start = eq_pos;
            var compound_op: ?u8 = null;
            if (eq_pos > 0) {
                const before = arg[eq_pos - 1];
                if (before == '+' or before == '-' or before == '*' or before == '/' or before == '%') {
                    compound_op = before;
                    op_start = eq_pos - 1;
                }
            }

            const var_name = arg[0..op_start];
            const expr = arg[eq_pos + 1 ..];

            // Evaluate expression
            var result = arith.eval(expr) catch |err| {
                try IO.eprint("den: let: {s}: arithmetic error: {}\n", .{ expr, err });
                shell.last_exit_code = 1;
                return;
            };

            // Apply compound operator
            if (compound_op) |op| {
                const current_val: i64 = blk: {
                    if (shell.environment.get(var_name)) |val| {
                        break :blk std.fmt.parseInt(i64, val, 10) catch 0;
                    }
                    break :blk 0;
                };
                result = switch (op) {
                    '+' => current_val +% result,
                    '-' => current_val -% result,
                    '*' => current_val *% result,
                    '/' => if (result != 0) @divTrunc(current_val, result) else 0,
                    '%' => if (result != 0) @mod(current_val, result) else 0,
                    else => result,
                };
            }

            // Store result
            var buf: [32]u8 = undefined;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
            const dup_value = try shell.allocator.dupe(u8, result_str);
            const gop = try shell.environment.getOrPut(var_name);
            if (gop.found_existing) {
                shell.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = dup_value;
            } else {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = dup_value;
            }
            last_result = result;
        } else {
            // Just evaluate expression
            last_result = arith.eval(arg) catch |err| {
                try IO.eprint("den: let: {s}: arithmetic error: {}\n", .{ arg, err });
                shell.last_exit_code = 1;
                return;
            };
        }
    }

    // Return 1 if last result is 0, else 0 (bash behavior)
    shell.last_exit_code = if (last_result == 0) 1 else 0;
}
