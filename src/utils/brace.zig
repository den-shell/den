const std = @import("std");

/// Brace expansion utilities
pub const BraceExpander = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BraceExpander {
        return .{ .allocator = allocator };
    }

    /// Expand brace patterns like {1..10} or {a..z} or {foo,bar,baz}
    /// Supports nested braces like {a,b{1,2},c} -> a, b1, b2, c
    pub fn expand(self: *BraceExpander, input: []const u8) ![][]const u8 {
        // Find the first brace pattern, properly handling nesting
        const brace_info = self.findOutermostBraces(input) orelse {
            // No braces, return input as-is
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, input);
            return result;
        };

        const brace_start = brace_info.start;
        const brace_end = brace_info.end;

        const prefix = input[0..brace_start];
        const suffix = input[brace_end + 1 ..];
        const brace_content = input[brace_start + 1 .. brace_end];

        // Check if it's a sequence (..) or a list (,)
        // For sequences, there should be no nested braces
        if (!self.hasNestedBraces(brace_content)) {
            if (std.mem.indexOf(u8, brace_content, "..")) |sep_pos| {
                // Sequence expansion: {1..10} or {a..z}
                const expanded = try self.expandSequence(prefix, brace_content, suffix, sep_pos);
                // Recursively expand any remaining braces in the results
                return try self.recurseUnlessUnchanged(input, expanded);
            }
        }

        // List expansion (may contain nested braces): {foo,bar,baz} or {a,b{1,2},c}
        if (self.hasCommaAtTopLevel(brace_content)) {
            const expanded = try self.expandListNested(prefix, brace_content, suffix);
            // Recursively expand any remaining braces in the results
            return try self.recurseUnlessUnchanged(input, expanded);
        }

        // Not a valid brace pattern, return as-is
        const result = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(result);
        result[0] = try self.allocator.dupe(u8, input);
        return result;
    }

    /// Recurse into the results, unless expansion changed nothing.
    ///
    /// A pattern that is not a valid expansion comes back with its braces --
    /// `{o..5}` exceeds the character-range limit, `{1..z}` has no numeric end,
    /// `{x..}` has no end at all. Recursing on that re-expands the same text,
    /// which re-expands the same text: `echo {o..5}` ran until the stack gave
    /// out and den died of a segfault.
    ///
    /// Reaching a fixed point means the text is literal, so it is returned as
    /// it is. The check belongs here, before the descent, rather than inside
    /// `expandAllRecursive`, where it would be reached only after the recursive
    /// call it is meant to prevent. Being in one place also means a future
    /// fallback cannot reintroduce the loop.
    fn recurseUnlessUnchanged(
        self: *BraceExpander,
        input: []const u8,
        expanded: [][]const u8,
    ) error{OutOfMemory}![][]const u8 {
        if (expanded.len == 1 and std.mem.eql(u8, expanded[0], input)) return expanded;
        return self.expandAllRecursive(expanded);
    }

    /// Find the outermost matching braces, handling nesting
    fn findOutermostBraces(self: *BraceExpander, input: []const u8) ?struct { start: usize, end: usize } {
        _ = self;
        const brace_start = std.mem.indexOfScalar(u8, input, '{') orelse return null;

        // Find matching closing brace, counting nesting level
        var depth: usize = 1;
        var pos = brace_start + 1;
        while (pos < input.len) : (pos += 1) {
            if (input[pos] == '{') {
                depth += 1;
            } else if (input[pos] == '}') {
                depth -= 1;
                if (depth == 0) {
                    return .{ .start = brace_start, .end = pos };
                }
            }
        }

        return null; // No matching closing brace
    }

    /// Check if content has nested braces
    fn hasNestedBraces(self: *BraceExpander, content: []const u8) bool {
        _ = self;
        return std.mem.indexOfScalar(u8, content, '{') != null;
    }

    /// Check if there's a comma at the top level (not inside nested braces)
    fn hasCommaAtTopLevel(self: *BraceExpander, content: []const u8) bool {
        _ = self;
        var depth: usize = 0;
        for (content) |c| {
            if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                if (depth > 0) depth -= 1;
            } else if (c == ',' and depth == 0) {
                return true;
            }
        }
        return false;
    }

    /// Expand a list that may contain nested braces
    fn expandListNested(self: *BraceExpander, prefix: []const u8, content: []const u8, suffix: []const u8) ![][]const u8 {
        // Split by top-level commas only
        var items = std.ArrayList([]const u8).empty;
        defer items.deinit(self.allocator);

        var depth: usize = 0;
        var item_start: usize = 0;

        for (content, 0..) |c, i| {
            if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                if (depth > 0) depth -= 1;
            } else if (c == ',' and depth == 0) {
                // Found a top-level comma - preserve whitespace (bash behavior)
                const item = content[item_start..i];
                try items.append(self.allocator, item);
                item_start = i + 1;
            }
        }
        // Don't forget the last item - preserve whitespace (bash behavior)
        const last_item = content[item_start..];
        try items.append(self.allocator, last_item);

        // Build results
        const result = try self.allocator.alloc([]const u8, items.items.len);
        errdefer self.allocator.free(result);
        var filled: usize = 0;
        errdefer for (result[0..filled]) |r| self.allocator.free(r);
        for (items.items, 0..) |item, i| {
            result[i] = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, item, suffix });
            filled = i + 1;
        }

        return result;
    }

    /// Recursively expand all items in the result array
    fn expandAllRecursive(self: *BraceExpander, items: [][]const u8) error{OutOfMemory}![][]const u8 {
        var all_results = std.ArrayList([]const u8).empty;
        defer all_results.deinit(self.allocator);

        for (items) |item| {
            // Check if this item still has braces to expand
            if (std.mem.indexOfScalar(u8, item, '{') != null) {
                const expanded = try self.expand(item);
                defer self.allocator.free(expanded);
                for (expanded) |exp_item| {
                    try all_results.append(self.allocator, exp_item);
                }
                // Free the original item since we expanded it
                self.allocator.free(item);
            } else {
                try all_results.append(self.allocator, item);
            }
        }

        // Free the original items array
        self.allocator.free(items);

        return try all_results.toOwnedSlice(self.allocator);
    }

    fn expandSequence(self: *BraceExpander, prefix: []const u8, content: []const u8, suffix: []const u8, sep_pos: usize) ![][]const u8 {
        const start_str = content[0..sep_pos];
        const rest = content[sep_pos + 2 ..];

        // Check for step: {start..end..step}
        var end_str = rest;
        var step_val: ?i64 = null;
        if (std.mem.indexOf(u8, rest, "..")) |second_sep| {
            end_str = rest[0..second_sep];
            const step_str = rest[second_sep + 2 ..];
            step_val = std.fmt.parseInt(i64, step_str, 10) catch null;
        }

        // Try to parse as integers first
        const start_num = std.fmt.parseInt(i64, start_str, 10) catch {
            // Try as characters (support step for chars too)
            if (start_str.len == 1 and end_str.len == 1) {
                return try self.expandCharSequence(prefix, start_str[0], end_str[0], suffix, step_val);
            }

            // Invalid sequence, return as literal (no braces to prevent infinite recursion)
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try std.fmt.allocPrint(self.allocator, "{s}{{{s}}}{s}", .{ prefix, content, suffix });
            return result;
        };

        const end_num = std.fmt.parseInt(i64, end_str, 10) catch {
            // Invalid sequence, return as literal
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try std.fmt.allocPrint(self.allocator, "{s}{{{s}}}{s}", .{ prefix, content, suffix });
            return result;
        };

        // Detect zero-padding: an operand triggers padding if its digits (after
        // an optional leading sign) begin with '0' and there is more than one
        // digit. The pad width is the digit count excluding the sign, so e.g.
        // {-002..002} yields -002, -001, 000, 001, 002 (sign is not padded).
        const start_off: usize = if (start_str.len > 0 and (start_str[0] == '-' or start_str[0] == '+')) 1 else 0;
        const end_off: usize = if (end_str.len > 0 and (end_str[0] == '-' or end_str[0] == '+')) 1 else 0;
        const start_digits = start_str.len - start_off;
        const end_digits = end_str.len - end_off;
        const start_has_zero_pad = start_digits > 1 and start_str[start_off] == '0';
        const end_has_zero_pad = end_digits > 1 and end_str[end_off] == '0';

        // Use the maximum digit width from either operand for zero-padding
        const pad_width: usize = if (start_has_zero_pad or end_has_zero_pad)
            @max(start_digits, end_digits)
        else
            0;

        return try self.expandNumericSequence(prefix, start_num, end_num, suffix, pad_width, step_val);
    }

    fn expandNumericSequence(self: *BraceExpander, prefix: []const u8, start: i64, end: i64, suffix: []const u8, pad_width: usize, custom_step: ?i64) ![][]const u8 {
        // Direction is always determined by start/end, step magnitude from user.
        // Guard against i64.min: @abs(i64.min) doesn't fit in i64 and would panic.
        const direction: i64 = if (start <= end) 1 else -1;
        const step: i64 = if (custom_step) |cs| blk: {
            if (cs == 0) break :blk direction;
            const abs_cs: u64 = @abs(cs);
            const clamped: i64 = if (abs_cs > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(abs_cs);
            break :blk direction * clamped;
        } else direction;
        const abs_step: u128 = @abs(step);
        // Use i128 intermediate so end - start cannot overflow for extreme values.
        const range_i128: i128 = if (end >= start)
            @as(i128, end) - @as(i128, start)
        else
            @as(i128, start) - @as(i128, end);
        const range: u128 = @intCast(range_i128);
        const count = range / abs_step + 1;

        if (count > 1000) {
            // Limit to prevent abuse
            const result = try self.allocator.alloc([]const u8, 1);
            errdefer self.allocator.free(result);
            const full = try std.fmt.allocPrint(self.allocator, "{s}{{{d}..{d}}}{s}", .{ prefix, start, end, suffix });
            result[0] = full;
            return result;
        }

        const result = try self.allocator.alloc([]const u8, @intCast(count));
        errdefer self.allocator.free(result);
        var filled: usize = 0;
        errdefer for (result[0..filled]) |r| self.allocator.free(r);
        var i: usize = 0;
        var current = start;

        while ((step > 0 and current <= end) or (step < 0 and current >= end)) : ({
            current += step;
            i += 1;
        }) {
            if (pad_width > 0) {
                // Zero-padded output
                result[i] = try self.formatZeroPadded(prefix, current, suffix, pad_width);
            } else {
                result[i] = try std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ prefix, current, suffix });
            }
            filled = i + 1;
        }

        return result;
    }

    /// Format a number with zero-padding
    fn formatZeroPadded(self: *BraceExpander, prefix: []const u8, num: i64, suffix: []const u8, width: usize) ![]const u8 {
        // Create a buffer for the number
        var num_buf: [32]u8 = undefined;
        var num_str: []const u8 = undefined;

        if (num < 0) {
            // Handle negative numbers: we need to pad after the minus sign.
            // Use @abs() to avoid overflow on i64::MIN.
            const abs_num: u64 = @abs(num);
            const num_len = std.fmt.count("{d}", .{abs_num});
            // `width` is the digit count (sign excluded), so pad the magnitude
            // to `width` digits and prepend the sign separately.
            const pad_len = if (width > num_len) width - num_len else 0;

            var pos: usize = 0;
            num_buf[pos] = '-';
            pos += 1;

            // Add leading zeros
            for (0..pad_len) |_| {
                num_buf[pos] = '0';
                pos += 1;
            }

            // Add the number
            const formatted = std.fmt.bufPrint(num_buf[pos..], "{d}", .{abs_num}) catch return error.OutOfMemory;
            num_str = num_buf[0 .. pos + formatted.len];
        } else {
            // Positive number
            const num_len = std.fmt.count("{d}", .{num});
            const pad_len = if (width > num_len) width - num_len else 0;

            var pos: usize = 0;

            // Add leading zeros
            for (0..pad_len) |_| {
                num_buf[pos] = '0';
                pos += 1;
            }

            // Add the number
            const formatted = std.fmt.bufPrint(num_buf[pos..], "{d}", .{num}) catch return error.OutOfMemory;
            num_str = num_buf[0 .. pos + formatted.len];
        }

        return std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, num_str, suffix });
    }

    fn expandCharSequence(self: *BraceExpander, prefix: []const u8, start: u8, end: u8, suffix: []const u8, custom_step: ?i64) ![][]const u8 {
        const direction: i8 = if (start <= end) 1 else -1;
        const step: i8 = if (custom_step) |cs| blk: {
            const abs_cs: i8 = if (cs == 0) 1 else @intCast(@min(@abs(cs), 127));
            break :blk direction * abs_cs;
        } else direction;
        const abs_step: u16 = @intCast(@abs(@as(i16, step)));
        const range = @abs(@as(i16, end) - @as(i16, start));
        const count = @divTrunc(range, abs_step) + 1;

        if (count > 52) {
            // Limit to prevent abuse (a-z is 26, A-Z is 26)
            const result = try self.allocator.alloc([]const u8, 1);
            errdefer self.allocator.free(result);
            const full = try std.fmt.allocPrint(self.allocator, "{s}{{{c}..{c}}}{s}", .{ prefix, start, end, suffix });
            result[0] = full;
            return result;
        }

        const result = try self.allocator.alloc([]const u8, @intCast(count));
        errdefer self.allocator.free(result);
        var filled: usize = 0;
        errdefer for (result[0..filled]) |r| self.allocator.free(r);
        var i: usize = 0;
        var current: i16 = start;

        while ((step > 0 and current <= end) or (step < 0 and current >= end)) : ({
            current += step;
            i += 1;
        }) {
            result[i] = try std.fmt.allocPrint(self.allocator, "{s}{c}{s}", .{ prefix, @as(u8, @intCast(current)), suffix });
            filled = i + 1;
        }

        return result;
    }

    fn expandList(self: *BraceExpander, prefix: []const u8, content: []const u8, suffix: []const u8) ![][]const u8 {
        // Count items first
        var count: usize = 1;
        for (content) |c| {
            if (c == ',') count += 1;
        }

        const result = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(result);
        var filled: usize = 0;
        errdefer for (result[0..filled]) |r| self.allocator.free(r);
        var idx: usize = 0;

        var iter = std.mem.splitScalar(u8, content, ',');
        while (iter.next()) |item| : (idx += 1) {
            const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
            result[idx] = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, trimmed, suffix });
            filled = idx + 1;
        }

        return result;
    }
};

test "brace expansion numeric sequence" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    const result = try expander.expand("file{1..3}.txt");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("file1.txt", result[0]);
    try std.testing.expectEqualStrings("file2.txt", result[1]);
    try std.testing.expectEqualStrings("file3.txt", result[2]);
}

test "brace expansion char sequence" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    const result = try expander.expand("test{a..c}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("testa", result[0]);
    try std.testing.expectEqualStrings("testb", result[1]);
    try std.testing.expectEqualStrings("testc", result[2]);
}

test "brace expansion list" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    const result = try expander.expand("file.{txt,md,zig}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("file.txt", result[0]);
    try std.testing.expectEqualStrings("file.md", result[1]);
    try std.testing.expectEqualStrings("file.zig", result[2]);
}

test "brace expansion zero-padding" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Basic zero-padding: {01..05}
    const result1 = try expander.expand("file{01..05}.txt");
    defer {
        for (result1) |item| allocator.free(item);
        allocator.free(result1);
    }

    try std.testing.expectEqual(@as(usize, 5), result1.len);
    try std.testing.expectEqualStrings("file01.txt", result1[0]);
    try std.testing.expectEqualStrings("file02.txt", result1[1]);
    try std.testing.expectEqualStrings("file03.txt", result1[2]);
    try std.testing.expectEqualStrings("file04.txt", result1[3]);
    try std.testing.expectEqualStrings("file05.txt", result1[4]);
}

test "brace expansion zero-padding crossing 10" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Zero-padding with width 2: {08..12}
    const result = try expander.expand("{08..12}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("08", result[0]);
    try std.testing.expectEqualStrings("09", result[1]);
    try std.testing.expectEqualStrings("10", result[2]);
    try std.testing.expectEqualStrings("11", result[3]);
    try std.testing.expectEqualStrings("12", result[4]);
}

test "brace expansion zero-padding width 3" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Zero-padding with width 3: {001..003}
    const result = try expander.expand("{001..003}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("001", result[0]);
    try std.testing.expectEqualStrings("002", result[1]);
    try std.testing.expectEqualStrings("003", result[2]);
}

test "brace expansion zero-padding large range" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Zero-padding: {0001..0100} (100 items, width 4)
    const result = try expander.expand("{0001..0100}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 100), result.len);
    try std.testing.expectEqualStrings("0001", result[0]);
    try std.testing.expectEqualStrings("0010", result[9]);
    try std.testing.expectEqualStrings("0099", result[98]);
    try std.testing.expectEqualStrings("0100", result[99]);
}

test "brace expansion nested simple" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Nested: {a,b{1,2},c} -> a, b1, b2, c
    const result = try expander.expand("{a,b{1,2},c}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b1", result[1]);
    try std.testing.expectEqualStrings("b2", result[2]);
    try std.testing.expectEqualStrings("c", result[3]);
}

test "brace expansion nested with prefix suffix" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Nested with prefix/suffix: file{a,b{1,2}}.txt -> filea.txt, fileb1.txt, fileb2.txt
    const result = try expander.expand("file{a,b{1,2}}.txt");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("filea.txt", result[0]);
    try std.testing.expectEqualStrings("fileb1.txt", result[1]);
    try std.testing.expectEqualStrings("fileb2.txt", result[2]);
}

test "brace expansion multiple braces" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Multiple separate brace groups: {a,b}{1,2} -> a1, a2, b1, b2
    const result = try expander.expand("{a,b}{1,2}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("a1", result[0]);
    try std.testing.expectEqualStrings("a2", result[1]);
    try std.testing.expectEqualStrings("b1", result[2]);
    try std.testing.expectEqualStrings("b2", result[3]);
}

test "brace expansion deeply nested" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Deeply nested: {a{1,2},b} -> a1, a2, b
    const result = try expander.expand("{a{1,2},b}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a1", result[0]);
    try std.testing.expectEqualStrings("a2", result[1]);
    try std.testing.expectEqualStrings("b", result[2]);
}

test "brace expansion preserves whitespace in items" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Bash preserves whitespace in brace items: {a , b} -> "a " and " b"
    const result = try expander.expand("{a , b}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("a ", result[0]);
    try std.testing.expectEqualStrings(" b", result[1]);
}

test "brace expansion empty items" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Empty items: {,b} -> "" and "b"
    const result = try expander.expand("x{,b}y");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("xy", result[0]);
    try std.testing.expectEqualStrings("xby", result[1]);
}

test "brace expansion reverse numeric sequence" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Reverse: {3..1} -> 3, 2, 1
    const result = try expander.expand("{3..1}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("3", result[0]);
    try std.testing.expectEqualStrings("2", result[1]);
    try std.testing.expectEqualStrings("1", result[2]);
}

test "brace expansion with step" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Step: {1..10..3} -> 1, 4, 7, 10
    const result = try expander.expand("{1..10..3}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("1", result[0]);
    try std.testing.expectEqualStrings("4", result[1]);
    try std.testing.expectEqualStrings("7", result[2]);
    try std.testing.expectEqualStrings("10", result[3]);
}

test "brace expansion single item no expansion" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Single item with no comma - no expansion
    const result = try expander.expand("{foo}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("{foo}", result[0]);
}

test "brace expansion no braces" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // No braces at all
    const result = try expander.expand("hello");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("hello", result[0]);
}

test "formatZeroPadded @abs() handles negative numbers safely" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    // Test a negative range expansion - exercises formatZeroPadded with num < 0
    // Use a format-width range like {-005..5} which requires zero-padding negatives
    const result = try expander.expand("{-002..002}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    // Should produce: -002, -001, 000, 001, 002 (5 items)
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("-002", result[0]);
    try std.testing.expectEqualStrings("002", result[4]);
}

test "invalid ranges stay literal instead of recursing forever" {
    // Each of these came back from expansion unchanged, braces and all, and the
    // result was then expanded again: `echo {o..5}` recursed until the stack ran
    // out and den died of a segfault. A fuzz case found it.
    const cases = [_][]const u8{
        "{o..5}", // a character range wider than the limit
        "{5..o}", // the same, descending
        "{1..z}", // numeric start, non-numeric end
        "{x..}", // no end
        "{..z}", // no start
        "{..}", // neither
        "{z..}",
    };

    for (cases) |input| {
        var expander = BraceExpander.init(std.testing.allocator);
        const result = try expander.expand(input);
        defer {
            for (result) |r| std.testing.allocator.free(r);
            std.testing.allocator.free(result);
        }

        // Literal, and one word -- which is what bash does with all of these.
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqualStrings(input, result[0]);
    }
}

test "valid ranges still expand after the fixed-point guard" {
    var expander = BraceExpander.init(std.testing.allocator);

    const result = try expander.expand("{1..3}{a,b}");
    defer {
        for (result) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(result);
    }

    // The guard must not stop a nested expansion that is making progress.
    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqualStrings("1a", result[0]);
    try std.testing.expectEqualStrings("3b", result[5]);
}
