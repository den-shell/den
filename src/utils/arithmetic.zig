const std = @import("std");
const IO = @import("io.zig").IO;
const types = @import("../types/mod.zig");

/// LRU Cache for arithmetic expression results
pub const ExpressionCache = struct {
    const CacheEntry = struct {
        key: []const u8,
        value: i64,
        age: u64,
    };

    const MAX_ENTRIES = 128;

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    access_counter: u64,

    pub fn init(allocator: std.mem.Allocator) ExpressionCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *ExpressionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
        }
        self.entries.deinit();
    }

    /// Get a cached result if available
    pub fn get(self: *ExpressionCache, expr: []const u8) ?i64 {
        if (self.entries.getPtr(expr)) |entry| {
            self.access_counter += 1;
            entry.age = self.access_counter;
            return entry.value;
        }
        return null;
    }

    /// Cache a result
    pub fn put(self: *ExpressionCache, expr: []const u8, value: i64) !void {
        // If at capacity, evict the oldest entry
        if (self.entries.count() >= MAX_ENTRIES) {
            self.evictOldest();
        }

        self.access_counter += 1;

        // Check if already exists
        if (self.entries.getPtr(expr)) |entry| {
            entry.value = value;
            entry.age = self.access_counter;
            return;
        }

        // Add new entry
        const key_copy = try self.allocator.dupe(u8, expr);
        errdefer self.allocator.free(key_copy);

        try self.entries.put(key_copy, .{
            .key = key_copy,
            .value = value,
            .age = self.access_counter,
        });
    }

    /// Evict the oldest (least recently used) entry
    fn evictOldest(self: *ExpressionCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_age: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.age < oldest_age) {
                oldest_age = entry.value_ptr.age;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.allocator.free(removed.value.key);
            }
        }
    }

    /// Clear all cached entries
    pub fn clear(self: *ExpressionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Get the number of cached entries
    pub fn count(self: *ExpressionCache) usize {
        return self.entries.count();
    }
};

/// Simple arithmetic evaluator for shell arithmetic expansion
/// Supports: +, -, *, /, %, **, <<, >>, &, |, ^, ~, !, &&, ||, <, >, <=, >=, ==, !=, ?:
pub const Arithmetic = struct {
    allocator: std.mem.Allocator,
    variables: ?*std.StringHashMap([]const u8) = null,
    local_vars: ?*std.StringHashMap([]const u8) = null,
    cache: ?*ExpressionCache = null,
    arrays: ?*std.StringHashMap(types.IndexedArray) = null,
    positional_params: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Arithmetic {
        return .{ .allocator = allocator, .variables = null, .cache = null };
    }

    pub fn initWithVariables(allocator: std.mem.Allocator, variables: *std.StringHashMap([]const u8)) Arithmetic {
        return .{ .allocator = allocator, .variables = variables, .cache = null };
    }

    pub fn initWithCache(allocator: std.mem.Allocator, cache: *ExpressionCache) Arithmetic {
        return .{ .allocator = allocator, .variables = null, .cache = cache };
    }

    pub fn initWithAll(allocator: std.mem.Allocator, variables: *std.StringHashMap([]const u8), cache: *ExpressionCache) Arithmetic {
        return .{ .allocator = allocator, .variables = variables, .cache = cache };
    }

    /// Evaluate an arithmetic expression and return the result
    /// Uses cache if available (for expressions without variables)
    pub fn eval(self: *Arithmetic, expr: []const u8) !i64 {
        const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);

        // Handle comma operator (lowest precedence): evaluate each sub-expression, return last
        // Only split on top-level commas (not inside parentheses)
        var depth: usize = 0;
        var has_comma = false;
        for (trimmed) |ch| {
            if (ch == '(') depth += 1;
            if (ch == ')') {
                if (depth > 0) depth -= 1;
            }
            if (ch == ',' and depth == 0) {
                has_comma = true;
                break;
            }
        }
        if (has_comma) {
            var result: i64 = 0;
            var start: usize = 0;
            depth = 0;
            for (trimmed, 0..) |ch, ci| {
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    if (depth > 0) depth -= 1;
                }
                if ((ch == ',' and depth == 0) or ci == trimmed.len - 1) {
                    const sub_end = if (ch == ',' and depth == 0) ci else ci + 1;
                    const sub = std.mem.trim(u8, trimmed[start..sub_end], &std.ascii.whitespace);
                    if (sub.len > 0) {
                        result = try self.evalSingle(sub);
                    }
                    start = ci + 1;
                }
            }
            return result;
        }

        return self.evalSingle(trimmed);
    }

    fn evalSingle(self: *Arithmetic, trimmed: []const u8) !i64 {
        // Only cache expressions without variables (they're deterministic)
        const has_variables = self.variables != null and self.expressionHasVariables(trimmed);

        // Check cache first (if no variables)
        if (!has_variables) {
            if (self.cache) |cache| {
                if (cache.get(trimmed)) |cached_value| {
                    return cached_value;
                }
            }
        }

        // Parse and evaluate the expression
        var parser = Parser{
            .input = trimmed,
            .pos = 0,
            .allocator = self.allocator,
            .variables = self.variables,
            .local_vars = self.local_vars,
            .arrays = self.arrays,
            .positional_params = self.positional_params,
        };

        const result = try parser.parseExpression();

        // Cache the result if no variables
        if (!has_variables) {
            if (self.cache) |cache| {
                cache.put(trimmed, result) catch {};
            }
        }

        return result;
    }

    /// Check if expression contains variable references
    fn expressionHasVariables(self: *Arithmetic, expr: []const u8) bool {
        _ = self;
        for (expr, 0..) |c, i| {
            if (c == '$') return true;
            // Check for bare variable names (letters/underscore not after a digit)
            if ((std.ascii.isAlphabetic(c) or c == '_')) {
                // Make sure it's not part of a hex/binary literal
                if (i > 0 and (expr[i - 1] == 'x' or expr[i - 1] == 'X' or
                    expr[i - 1] == 'b' or expr[i - 1] == 'B'))
                {
                    continue;
                }
                // Check if preceded by a digit (not a variable)
                if (i > 0 and std.ascii.isDigit(expr[i - 1])) {
                    continue;
                }
                return true;
            }
        }
        return false;
    }
};

const ArithmeticError = error{
    DivisionByZero,
    NegativeExponent,
    UnexpectedEnd,
    MissingClosingParen,
    MissingColonInTernary,
    InvalidNumber,
    InvalidVariable,
    IntegerOverflow,
};

const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    variables: ?*std.StringHashMap([]const u8),
    local_vars: ?*std.StringHashMap([]const u8) = null,
    arrays: ?*std.StringHashMap(types.IndexedArray) = null,
    positional_params: []const []const u8 = &.{},

    // Entry point - lowest precedence (assignment and compound assignment)
    fn parseExpression(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();
        // Check for assignment or compound assignment: identifier OP= expr
        const save_pos = self.pos;
        if (self.pos < self.input.len and (std.ascii.isAlphabetic(self.input[self.pos]) or self.input[self.pos] == '_')) {
            var end = self.pos;
            while (end < self.input.len and (std.ascii.isAlphanumeric(self.input[end]) or self.input[end] == '_')) {
                end += 1;
            }
            const var_name = self.input[self.pos..end];
            var op_pos = end;
            // Skip whitespace before operator
            while (op_pos < self.input.len and self.input[op_pos] == ' ') op_pos += 1;

            // Check for compound assignment operators: <<=, >>=, +=, -=, *=, /=, %=, &=, |=, ^=
            // and simple assignment: =
            const CompoundOp = enum { none, assign, add, sub, mul, div, mod, shl, shr, band, bor, bxor };
            var compound_op: CompoundOp = .none;
            var op_len: usize = 0;

            if (op_pos + 2 < self.input.len and self.input[op_pos] == '<' and self.input[op_pos + 1] == '<' and self.input[op_pos + 2] == '=') {
                compound_op = .shl;
                op_len = 3;
            } else if (op_pos + 2 < self.input.len and self.input[op_pos] == '>' and self.input[op_pos + 1] == '>' and self.input[op_pos + 2] == '=') {
                compound_op = .shr;
                op_len = 3;
            } else if (op_pos + 1 < self.input.len and self.input[op_pos + 1] == '=') {
                const op_char = self.input[op_pos];
                switch (op_char) {
                    '+' => {
                        compound_op = .add;
                        op_len = 2;
                    },
                    '-' => {
                        compound_op = .sub;
                        op_len = 2;
                    },
                    '*' => {
                        compound_op = .mul;
                        op_len = 2;
                    },
                    '/' => {
                        compound_op = .div;
                        op_len = 2;
                    },
                    '%' => {
                        compound_op = .mod;
                        op_len = 2;
                    },
                    '&' => {
                        compound_op = .band;
                        op_len = 2;
                    },
                    '|' => {
                        compound_op = .bor;
                        op_len = 2;
                    },
                    '^' => {
                        compound_op = .bxor;
                        op_len = 2;
                    },
                    '=' => {}, // == is not an assignment
                    else => {},
                }
            } else if (op_pos < self.input.len and self.input[op_pos] == '=' and
                (op_pos + 1 >= self.input.len or self.input[op_pos + 1] != '='))
            {
                compound_op = .assign;
                op_len = 1;
            }

            if (compound_op != .none) {
                self.pos = op_pos + op_len;
                const rhs = try self.parseExpression();
                if (compound_op == .assign) {
                    self.storeVariable(var_name, rhs);
                    return rhs;
                }
                const cur = self.getVariableValue(var_name);
                const new_val: i64 = switch (compound_op) {
                    .add => try checkedAdd(cur, rhs),
                    .sub => try checkedSub(cur, rhs),
                    .mul => try checkedMul(cur, rhs),
                    .div => if (rhs != 0) blk: {
                        if (cur == std.math.minInt(i64) and rhs == -1) return error.IntegerOverflow;
                        break :blk @divTrunc(cur, rhs);
                    } else return error.DivisionByZero,
                    .mod => if (rhs != 0) blk: {
                        if (cur == std.math.minInt(i64) and rhs == -1) break :blk 0;
                        break :blk @rem(cur, rhs);
                    } else return error.DivisionByZero,
                    .shl => blk: {
                        const shift_amt: u6 = @intCast(@min(@max(rhs, 0), 63));
                        break :blk cur << shift_amt;
                    },
                    .shr => blk: {
                        const shift_amt: u6 = @intCast(@min(@max(rhs, 0), 63));
                        break :blk cur >> shift_amt;
                    },
                    .band => cur & rhs,
                    .bor => cur | rhs,
                    .bxor => cur ^ rhs,
                    .none, .assign => unreachable,
                };
                self.storeVariable(var_name, new_val);
                return new_val;
            }
        }
        self.pos = save_pos;
        return try self.parseTernary();
    }

    // Ternary operator: expr ? expr : expr (lowest precedence)
    fn parseTernary(self: *Parser) ArithmeticError!i64 {
        const condition = try self.parseLogicalOr();

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == '?') {
            self.pos += 1;

            if (condition != 0) {
                // Condition is true: evaluate true branch, discard false branch
                const true_val = try self.parseTernary();

                self.skipWhitespace();
                if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                    return error.MissingColonInTernary;
                }
                self.pos += 1;
                _ = try self.parseTernary(); // consume false branch but discard
                return true_val;
            } else {
                // Condition is false: discard true branch, evaluate false branch
                _ = try self.parseTernary(); // consume true branch but discard

                self.skipWhitespace();
                if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                    return error.MissingColonInTernary;
                }
                self.pos += 1;
                return try self.parseTernary(); // evaluate false branch
            }
        }

        return condition;
    }

    // Logical OR: ||
    fn parseLogicalOr(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseLogicalAnd();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos + 1 < self.input.len and
                self.input[self.pos] == '|' and
                self.input[self.pos + 1] == '|')
            {
                self.pos += 2;
                if (left != 0) {
                    // Short circuit: still parse right side to advance position, but result is 1
                    _ = try self.parseLogicalAnd();
                    left = 1;
                } else {
                    const right = try self.parseLogicalAnd();
                    left = if (right != 0) @as(i64, 1) else @as(i64, 0);
                }
            } else {
                break;
            }
        }

        return left;
    }

    // Logical AND: &&
    fn parseLogicalAnd(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseBitwiseOr();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos + 1 < self.input.len and
                self.input[self.pos] == '&' and
                self.input[self.pos + 1] == '&')
            {
                self.pos += 2;
                if (left == 0) {
                    // Short circuit: still parse right side to advance position, but result is 0
                    _ = try self.parseBitwiseOr();
                    // left stays 0
                } else {
                    const right = try self.parseBitwiseOr();
                    left = if (right != 0) @as(i64, 1) else @as(i64, 0);
                }
            } else {
                break;
            }
        }

        return left;
    }

    // Bitwise OR: |
    fn parseBitwiseOr(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseBitwiseXor();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos < self.input.len and self.input[self.pos] == '|') {
                // Check it's not || or |=
                if (self.pos + 1 < self.input.len and (self.input[self.pos + 1] == '|' or self.input[self.pos + 1] == '=')) {
                    break;
                }
                self.pos += 1;
                const right = try self.parseBitwiseXor();
                left = left | right;
            } else {
                break;
            }
        }

        return left;
    }

    // Bitwise XOR: ^
    fn parseBitwiseXor(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseBitwiseAnd();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos < self.input.len and self.input[self.pos] == '^') {
                // Don't consume ^= (compound assignment)
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') break;
                self.pos += 1;
                const right = try self.parseBitwiseAnd();
                left = left ^ right;
            } else {
                break;
            }
        }

        return left;
    }

    // Bitwise AND: &
    fn parseBitwiseAnd(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseEquality();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos < self.input.len and self.input[self.pos] == '&') {
                // Check it's not && or &=
                if (self.pos + 1 < self.input.len and (self.input[self.pos + 1] == '&' or self.input[self.pos + 1] == '=')) {
                    break;
                }
                self.pos += 1;
                const right = try self.parseEquality();
                left = left & right;
            } else {
                break;
            }
        }

        return left;
    }

    // Equality: == !=
    fn parseEquality(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseComparison();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos + 1 < self.input.len) {
                if (self.input[self.pos] == '=' and self.input[self.pos + 1] == '=') {
                    self.pos += 2;
                    const right = try self.parseComparison();
                    left = if (left == right) 1 else 0;
                } else if (self.input[self.pos] == '!' and self.input[self.pos + 1] == '=') {
                    self.pos += 2;
                    const right = try self.parseComparison();
                    left = if (left != right) 1 else 0;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return left;
    }

    // Comparison: < > <= >=
    fn parseComparison(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseShift();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.pos + 1 < self.input.len and self.input[self.pos] == '<' and self.input[self.pos + 1] == '=') {
                self.pos += 2;
                const right = try self.parseShift();
                left = if (left <= right) 1 else 0;
            } else if (self.pos + 1 < self.input.len and self.input[self.pos] == '>' and self.input[self.pos + 1] == '=') {
                self.pos += 2;
                const right = try self.parseShift();
                left = if (left >= right) 1 else 0;
            } else if (self.input[self.pos] == '<') {
                // Check it's not <<
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '<') {
                    break;
                }
                self.pos += 1;
                const right = try self.parseShift();
                left = if (left < right) 1 else 0;
            } else if (self.input[self.pos] == '>') {
                // Check it's not >>
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
                    break;
                }
                self.pos += 1;
                const right = try self.parseShift();
                left = if (left > right) 1 else 0;
            } else {
                break;
            }
        }

        return left;
    }

    // Shift: << >>
    fn parseShift(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseAddSub();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos + 1 < self.input.len) {
                if (self.input[self.pos] == '<' and self.input[self.pos + 1] == '<') {
                    // Don't consume <<= (compound assignment)
                    if (self.pos + 2 < self.input.len and self.input[self.pos + 2] == '=') break;
                    self.pos += 2;
                    const right = try self.parseAddSub();
                    // Zig requires u6 for shift amount
                    const shift_amt: u6 = @intCast(@min(@max(right, 0), 63));
                    left = left << shift_amt;
                } else if (self.input[self.pos] == '>' and self.input[self.pos + 1] == '>') {
                    // Don't consume >>= (compound assignment)
                    if (self.pos + 2 < self.input.len and self.input[self.pos + 2] == '=') break;
                    self.pos += 2;
                    const right = try self.parseAddSub();
                    const shift_amt: u6 = @intCast(@min(@max(right, 0), 63));
                    left = left >> shift_amt;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return left;
    }

    // Addition/Subtraction: + - (with overflow checking)
    fn parseAddSub(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseMulDiv();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            const op = self.input[self.pos];
            if (op == '+' or op == '-') {
                // Don't consume += or -= (compound assignment handled at expression level)
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') break;
                // Don't consume ++ or -- (increment/decrement)
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == op) break;
                self.pos += 1;
                const right = try self.parseMulDiv();
                if (op == '+') {
                    left = try checkedAdd(left, right);
                } else {
                    left = try checkedSub(left, right);
                }
            } else {
                break;
            }
        }

        return left;
    }

    // Multiplication/Division/Modulo: * / % (with overflow checking)
    fn parseMulDiv(self: *Parser) ArithmeticError!i64 {
        var left = try self.parsePower();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            const op = self.input[self.pos];
            if (op == '*') {
                // Check it's not ** or *=
                if (self.pos + 1 < self.input.len and (self.input[self.pos + 1] == '*' or self.input[self.pos + 1] == '=')) {
                    break;
                }
                self.pos += 1;
                const right = try self.parsePower();
                left = try checkedMul(left, right);
            } else if (op == '/') {
                // Don't consume /= (compound assignment)
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') break;
                self.pos += 1;
                const right = try self.parsePower();
                if (right == 0) return error.DivisionByZero;
                // Division can overflow in the case of MIN_INT / -1
                if (left == std.math.minInt(i64) and right == -1) {
                    return error.IntegerOverflow;
                }
                left = @divTrunc(left, right);
            } else if (op == '%') {
                // Don't consume %= (compound assignment)
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') break;
                self.pos += 1;
                const right = try self.parsePower();
                if (right == 0) return error.DivisionByZero;
                // MIN_INT % -1 overflows (same as MIN_INT / -1)
                if (left == std.math.minInt(i64) and right == -1) return 0;
                left = @rem(left, right);
            } else {
                break;
            }
        }

        return left;
    }

    // Power: ** (right associative)
    fn parsePower(self: *Parser) ArithmeticError!i64 {
        const left = try self.parseUnary();

        self.skipWhitespace();
        if (self.pos < self.input.len) {
            // Check for ** operator
            if (self.pos + 1 < self.input.len and
                self.input[self.pos] == '*' and
                self.input[self.pos + 1] == '*')
            {
                self.pos += 2;
                const right = try self.parsePower(); // recurse for right-associativity
                return try self.power(left, right);
            }
        }

        return left;
    }

    // Get a variable's numeric value
    fn getVariableValue(self: *Parser, var_name: []const u8) i64 {
        if (self.local_vars) |locals| {
            if (locals.get(var_name)) |value| {
                const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len == 0) return 0;
                return std.fmt.parseInt(i64, trimmed, 10) catch 0;
            }
        }
        if (self.variables) |vars| {
            if (vars.get(var_name)) |value| {
                const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len == 0) return 0;
                return std.fmt.parseInt(i64, trimmed, 10) catch 0;
            }
        }
        return 0;
    }

    // Sensitive variable names that must not be modified via arithmetic assignment
    const sensitive_vars = [_][]const u8{
        "PATH", "IFS", "HOME", "SHELL", "ENV", "BASH_ENV", "LD_PRELOAD", "LD_LIBRARY_PATH",
    };

    // Store a value into a variable
    fn storeVariable(self: *Parser, var_name: []const u8, value: i64) void {
        // Reject writes to sensitive environment variables to prevent
        // arithmetic expressions from modifying security-critical state.
        for (sensitive_vars) |sensitive| {
            if (std.mem.eql(u8, var_name, sensitive)) {
                IO.eprint("den: warning: arithmetic assignment to sensitive variable '{s}' blocked\n", .{var_name}) catch {};
                return;
            }
        }
        if (self.variables) |vars| {
            var buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
            const duped_val = self.allocator.dupe(u8, val_str) catch return;
            const gop = vars.getOrPut(var_name) catch return;
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = self.allocator.dupe(u8, var_name) catch return;
            }
            gop.value_ptr.* = duped_val;
        }
    }

    // Unary: + - ! ~ ++x --x
    fn parseUnary(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        if (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            // Pre-increment ++x
            if (ch == '+' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '+') {
                self.pos += 2;
                self.skipWhitespace();
                const save = self.pos;
                // Parse variable name
                while (self.pos < self.input.len and (std.ascii.isAlphanumeric(self.input[self.pos]) or self.input[self.pos] == '_')) {
                    self.pos += 1;
                }
                if (self.pos > save) {
                    const vname = self.input[save..self.pos];
                    const cur = self.getVariableValue(vname);
                    const new_val = checkedAdd(cur, 1) catch return error.IntegerOverflow;
                    self.storeVariable(vname, new_val);
                    return new_val;
                }
                self.pos = save;
            }
            // Pre-decrement --x
            if (ch == '-' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '-') {
                self.pos += 2;
                self.skipWhitespace();
                const save = self.pos;
                while (self.pos < self.input.len and (std.ascii.isAlphanumeric(self.input[self.pos]) or self.input[self.pos] == '_')) {
                    self.pos += 1;
                }
                if (self.pos > save) {
                    const vname = self.input[save..self.pos];
                    const cur = self.getVariableValue(vname);
                    const new_val = checkedSub(cur, 1) catch return error.IntegerOverflow;
                    self.storeVariable(vname, new_val);
                    return new_val;
                }
                self.pos = save;
            }
            if (ch == '-') {
                self.pos += 1;
                const value = try self.parseUnary();
                // Negating MIN_INT overflows since |MIN_INT| > MAX_INT
                if (value == std.math.minInt(i64)) return error.IntegerOverflow;
                return -value;
            } else if (ch == '+') {
                self.pos += 1;
                return try self.parseUnary();
            } else if (ch == '!') {
                // Check it's not !=
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                    return try self.parsePrimary();
                }
                self.pos += 1;
                const value = try self.parseUnary();
                return if (value == 0) 1 else 0;
            } else if (ch == '~') {
                self.pos += 1;
                const value = try self.parseUnary();
                return ~value;
            }
        }

        return try self.parsePrimary();
    }

    // Primary: numbers, variables, parentheses
    fn parsePrimary(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return error.UnexpectedEnd;
        }

        // Handle parentheses
        if (self.input[self.pos] == '(') {
            self.pos += 1;
            const value = try self.parseExpression();
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != ')') {
                return error.MissingClosingParen;
            }
            self.pos += 1;
            return value;
        }

        // Handle variable reference (with or without $)
        if (self.input[self.pos] == '$' or std.ascii.isAlphabetic(self.input[self.pos]) or self.input[self.pos] == '_') {
            return try self.parseVariable();
        }

        // Parse number
        return try self.parseNumber();
    }

    // Parse variable reference
    fn parseVariable(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        // Skip optional $
        if (self.pos < self.input.len and self.input[self.pos] == '$') {
            self.pos += 1;
        }

        const start = self.pos;

        // Variable name: alphanumeric and underscore
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (start == self.pos) {
            return error.InvalidVariable;
        }

        const var_name = self.input[start..self.pos];

        // Check for post-increment x++ / post-decrement x--
        if (self.pos + 1 < self.input.len and self.input[self.pos] == '+' and self.input[self.pos + 1] == '+') {
            self.pos += 2;
            const cur = self.getVariableValue(var_name);
            self.storeVariable(var_name, checkedAdd(cur, 1) catch return error.IntegerOverflow);
            return cur; // post-increment returns old value
        }
        if (self.pos + 1 < self.input.len and self.input[self.pos] == '-' and self.input[self.pos + 1] == '-') {
            self.pos += 2;
            const cur = self.getVariableValue(var_name);
            self.storeVariable(var_name, checkedSub(cur, 1) catch return error.IntegerOverflow);
            return cur; // post-decrement returns old value
        }

        // Check for array access: arr[index]
        if (self.pos < self.input.len and self.input[self.pos] == '[') {
            self.pos += 1; // skip [
            const index_val = self.parseExpression() catch 0;
            self.skipWhitespace();
            if (self.pos < self.input.len and self.input[self.pos] == ']') {
                self.pos += 1; // skip ]
            }
            const index = if (index_val >= 0) @as(usize, @intCast(index_val)) else 0;
            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    if (array.getIndex(index)) |elem| {
                        const trimmed = std.mem.trim(u8, elem, &std.ascii.whitespace);
                        if (trimmed.len == 0) return 0;
                        return std.fmt.parseInt(i64, trimmed, 10) catch 0;
                    }
                }
            }
            return 0;
        }

        // Check positional parameters ($1, $2, etc.)
        if (var_name.len == 1 and var_name[0] >= '1' and var_name[0] <= '9') {
            const digit = var_name[0] - '0';
            if (digit <= self.positional_params.len and digit > 0) {
                const param_val = std.mem.trim(u8, self.positional_params[digit - 1], &std.ascii.whitespace);
                if (param_val.len == 0) return 0;
                return std.fmt.parseInt(i64, param_val, 10) catch 0;
            }
            return 0;
        }

        // Look up variable value - check local vars first, then global
        if (self.local_vars) |locals| {
            if (locals.get(var_name)) |value| {
                const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len == 0) return 0;
                return std.fmt.parseInt(i64, trimmed, 10) catch 0;
            }
        }
        if (self.variables) |vars| {
            if (vars.get(var_name)) |value| {
                // Parse the variable value as a number
                const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len == 0) return 0;
                return std.fmt.parseInt(i64, trimmed, 10) catch 0;
            }
        }

        // Variable not found - return 0 (shell convention)
        return 0;
    }

    fn parseNumber(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        const start = self.pos;

        // Handle hex (0x...), binary (0b...) and octal (0...)
        if (self.pos + 1 < self.input.len and self.input[self.pos] == '0') {
            if (self.input[self.pos + 1] == 'x' or self.input[self.pos + 1] == 'X') {
                // Hexadecimal
                self.pos += 2;
                const hex_start = self.pos;
                while (self.pos < self.input.len and std.ascii.isHex(self.input[self.pos])) {
                    self.pos += 1;
                }
                if (hex_start == self.pos) return error.InvalidNumber;
                return std.fmt.parseInt(i64, self.input[hex_start..self.pos], 16) catch error.InvalidNumber;
            } else if (self.input[self.pos + 1] == 'b' or self.input[self.pos + 1] == 'B') {
                // Binary
                self.pos += 2;
                const bin_start = self.pos;
                while (self.pos < self.input.len and (self.input[self.pos] == '0' or self.input[self.pos] == '1')) {
                    self.pos += 1;
                }
                if (bin_start == self.pos) return error.InvalidNumber;
                return std.fmt.parseInt(i64, self.input[bin_start..self.pos], 2) catch error.InvalidNumber;
            } else if (std.ascii.isDigit(self.input[self.pos + 1])) {
                // Octal
                self.pos += 1;
                const oct_start = self.pos;
                while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '7') {
                    self.pos += 1;
                }
                if (oct_start == self.pos) return error.InvalidNumber;
                return std.fmt.parseInt(i64, self.input[oct_start..self.pos], 8) catch error.InvalidNumber;
            }
        }

        // Parse decimal digits
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }

        if (start == self.pos) {
            return error.InvalidNumber;
        }

        // Check for base#value syntax (e.g., 16#ff, 2#1010, 8#77)
        if (self.pos < self.input.len and self.input[self.pos] == '#') {
            const base = std.fmt.parseInt(u8, self.input[start..self.pos], 10) catch return error.InvalidNumber;
            if (base < 2 or base > 64) return error.InvalidNumber;
            self.pos += 1; // skip '#'
            const val_start = self.pos;
            while (self.pos < self.input.len and (std.ascii.isAlphanumeric(self.input[self.pos]) or self.input[self.pos] == '_' or self.input[self.pos] == '@')) {
                self.pos += 1;
            }
            if (val_start == self.pos) return error.InvalidNumber;
            return std.fmt.parseInt(i64, self.input[val_start..self.pos], base) catch error.InvalidNumber;
        }

        const num_str = self.input[start..self.pos];
        return std.fmt.parseInt(i64, num_str, 10) catch error.InvalidNumber;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    fn power(self: *Parser, base: i64, exp: i64) ArithmeticError!i64 {
        _ = self;

        if (exp < 0) return error.NegativeExponent;
        if (exp == 0) return 1;
        if (base == 0) return 0;
        if (base == 1) return 1;
        if (base == -1) return if (@rem(exp, 2) == 0) 1 else -1;
        // Any base with abs > 1 raised to power > 62 overflows i64
        if (exp > 62) return error.IntegerOverflow;

        var result: i64 = 1;
        var b = base;
        var e = exp;

        while (e > 0) {
            if (@rem(e, 2) == 1) {
                result = try checkedMul(result, b);
            }
            if (e > 1) {
                b = try checkedMul(b, b);
            }
            e = @divTrunc(e, 2);
        }

        return result;
    }
};

/// Checked arithmetic helper functions
fn checkedAdd(a: i64, b: i64) ArithmeticError!i64 {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.IntegerOverflow;
    return result;
}

fn checkedSub(a: i64, b: i64) ArithmeticError!i64 {
    const result, const overflow = @subWithOverflow(a, b);
    if (overflow != 0) return error.IntegerOverflow;
    return result;
}

fn checkedMul(a: i64, b: i64) ArithmeticError!i64 {
    const result, const overflow = @mulWithOverflow(a, b);
    if (overflow != 0) return error.IntegerOverflow;
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "arithmetic basic operations" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 5), try arith.eval("2 + 3"));
    try std.testing.expectEqual(@as(i64, -1), try arith.eval("2 - 3"));
    try std.testing.expectEqual(@as(i64, 6), try arith.eval("2 * 3"));
    try std.testing.expectEqual(@as(i64, 2), try arith.eval("6 / 3"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("7 % 3"));
}

test "arithmetic operator precedence" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 14), try arith.eval("2 + 3 * 4"));
    try std.testing.expectEqual(@as(i64, 20), try arith.eval("(2 + 3) * 4"));
    try std.testing.expectEqual(@as(i64, 11), try arith.eval("2 * 3 + 5"));
}

test "arithmetic power" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 8), try arith.eval("2 ** 3"));
    try std.testing.expectEqual(@as(i64, 16), try arith.eval("2 ** 2 ** 2"));
}

test "arithmetic unary operators" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, -5), try arith.eval("-5"));
    try std.testing.expectEqual(@as(i64, 5), try arith.eval("+5"));
    try std.testing.expectEqual(@as(i64, -8), try arith.eval("-(3 + 5)"));
}

test "arithmetic comparison operators" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Less than
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("2 < 3"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("3 < 2"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("2 < 2"));

    // Greater than
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("2 > 3"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("3 > 2"));

    // Less than or equal
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("2 <= 3"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("2 <= 2"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("3 <= 2"));

    // Greater than or equal
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("3 >= 2"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("2 >= 2"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("2 >= 3"));

    // Equal
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("5 == 5"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("5 == 6"));

    // Not equal
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("5 != 6"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("5 != 5"));
}

test "arithmetic logical operators" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Logical AND
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("1 && 1"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("1 && 0"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("0 && 1"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("0 && 0"));

    // Logical OR
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("1 || 1"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("1 || 0"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("0 || 1"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("0 || 0"));

    // Logical NOT
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("!1"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("!0"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("!5"));
}

test "arithmetic bitwise operators" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Bitwise AND
    try std.testing.expectEqual(@as(i64, 0b0100), try arith.eval("0b0110 & 0b1100"));
    try std.testing.expectEqual(@as(i64, 4), try arith.eval("6 & 12"));

    // Bitwise OR
    try std.testing.expectEqual(@as(i64, 0b1110), try arith.eval("0b0110 | 0b1100"));
    try std.testing.expectEqual(@as(i64, 14), try arith.eval("6 | 12"));

    // Bitwise XOR
    try std.testing.expectEqual(@as(i64, 0b1010), try arith.eval("0b0110 ^ 0b1100"));
    try std.testing.expectEqual(@as(i64, 10), try arith.eval("6 ^ 12"));

    // Bitwise NOT
    try std.testing.expectEqual(@as(i64, -6), try arith.eval("~5"));

    // Left shift
    try std.testing.expectEqual(@as(i64, 8), try arith.eval("2 << 2"));
    try std.testing.expectEqual(@as(i64, 16), try arith.eval("1 << 4"));

    // Right shift
    try std.testing.expectEqual(@as(i64, 2), try arith.eval("8 >> 2"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("16 >> 4"));
}

test "arithmetic ternary operator" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 10), try arith.eval("1 ? 10 : 20"));
    try std.testing.expectEqual(@as(i64, 20), try arith.eval("0 ? 10 : 20"));
    try std.testing.expectEqual(@as(i64, 5), try arith.eval("(3 > 2) ? 5 : 10"));
    try std.testing.expectEqual(@as(i64, 10), try arith.eval("(3 < 2) ? 5 : 10"));

    // Nested ternary
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("1 ? 1 : 0 ? 2 : 3"));
}

test "arithmetic hex and octal" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Hexadecimal
    try std.testing.expectEqual(@as(i64, 255), try arith.eval("0xff"));
    try std.testing.expectEqual(@as(i64, 16), try arith.eval("0x10"));
    try std.testing.expectEqual(@as(i64, 256), try arith.eval("0xFF + 1"));

    // Octal
    try std.testing.expectEqual(@as(i64, 8), try arith.eval("010"));
    try std.testing.expectEqual(@as(i64, 63), try arith.eval("077"));
}

test "arithmetic variables" {
    const allocator = std.testing.allocator;

    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();

    try vars.put("x", "10");
    try vars.put("y", "5");
    try vars.put("empty", "");

    var arith = Arithmetic.initWithVariables(allocator, &vars);

    try std.testing.expectEqual(@as(i64, 10), try arith.eval("x"));
    try std.testing.expectEqual(@as(i64, 10), try arith.eval("$x"));
    try std.testing.expectEqual(@as(i64, 15), try arith.eval("x + y"));
    try std.testing.expectEqual(@as(i64, 50), try arith.eval("x * y"));
    try std.testing.expectEqual(@as(i64, 11), try arith.eval("x + 1"));

    // Empty variable should be 0
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("empty"));

    // Undefined variable should be 0
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("undefined_var"));
}

test "arithmetic complex expressions" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Complex expression with multiple operators
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("(5 > 3) && (2 < 4)"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("(5 > 3) && (2 > 4)"));
    try std.testing.expectEqual(@as(i64, 7), try arith.eval("(1 + 2) | 4"));
    try std.testing.expectEqual(@as(i64, 20), try arith.eval("(2 + 3) << 2"));
}

test "arithmetic overflow detection" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Addition overflow
    try std.testing.expectError(error.IntegerOverflow, arith.eval("9223372036854775807 + 1"));

    // Subtraction overflow (use a large negative number that can be represented)
    try std.testing.expectError(error.IntegerOverflow, arith.eval("-9223372036854775807 - 2"));

    // Multiplication overflow
    try std.testing.expectError(error.IntegerOverflow, arith.eval("9223372036854775807 * 2"));
    try std.testing.expectError(error.IntegerOverflow, arith.eval("-9223372036854775807 * 2"));

    // Power overflow
    try std.testing.expectError(error.IntegerOverflow, arith.eval("2 ** 63"));

    // Large numbers that don't overflow should work
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try arith.eval("9223372036854775807"));
}

test "arithmetic boundary values" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Operations near boundaries that don't overflow
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64) - 1), try arith.eval("9223372036854775807 - 1"));
    try std.testing.expectEqual(@as(i64, -std.math.maxInt(i64) + 1), try arith.eval("-9223372036854775807 + 1"));

    // Power edge cases
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("(-1) ** 100"));
    try std.testing.expectEqual(@as(i64, -1), try arith.eval("(-1) ** 101"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("1 ** 1000"));
    try std.testing.expectEqual(@as(i64, 0), try arith.eval("0 ** 100"));
}

test "arithmetic unary negation overflow" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Negating MIN_INT should overflow (since |MIN_INT| > MAX_INT)
    // We can't write -9223372036854775808 directly as a literal,
    // but we can get it via subtraction from boundary
    try std.testing.expectError(error.IntegerOverflow, arith.eval("-(-9223372036854775807 - 1)"));

    // Double negation of normal values should work fine
    try std.testing.expectEqual(@as(i64, 42), try arith.eval("-(-42)"));
    try std.testing.expectEqual(@as(i64, -1), try arith.eval("-(1)"));
}

test "arithmetic octal with 8 and 9 digits" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Valid octal
    try std.testing.expectEqual(@as(i64, 8), try arith.eval("010"));
    try std.testing.expectEqual(@as(i64, 63), try arith.eval("077"));

    // 089 should fail - '8' is not a valid octal digit
    try std.testing.expectError(error.InvalidNumber, arith.eval("089"));
}

test "arithmetic comma operator" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // Comma operator: evaluates all, returns last
    try std.testing.expectEqual(@as(i64, 3), try arith.eval("1, 2, 3"));
    try std.testing.expectEqual(@as(i64, 10), try arith.eval("5 + 5, 10"));
}

test "arithmetic base-N syntax" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    // base#value syntax
    try std.testing.expectEqual(@as(i64, 255), try arith.eval("16#ff"));
    try std.testing.expectEqual(@as(i64, 10), try arith.eval("2#1010"));
    try std.testing.expectEqual(@as(i64, 63), try arith.eval("8#77"));
}

test "expression cache basic" {
    const allocator = std.testing.allocator;
    var cache = ExpressionCache.init(allocator);
    defer cache.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(?i64, null), cache.get("2 + 2"));

    // Add entry
    try cache.put("2 + 2", 4);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(?i64, 4), cache.get("2 + 2"));

    // Add another entry
    try cache.put("3 * 3", 9);
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(?i64, 9), cache.get("3 * 3"));

    // Update existing entry
    try cache.put("2 + 2", 5);
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(?i64, 5), cache.get("2 + 2"));

    // Clear cache
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "expression cache with arithmetic" {
    const allocator = std.testing.allocator;
    var cache = ExpressionCache.init(allocator);
    defer cache.deinit();

    var arith = Arithmetic.initWithCache(allocator, &cache);

    // First evaluation should cache
    try std.testing.expectEqual(@as(i64, 4), try arith.eval("2 + 2"));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    // Second evaluation should use cache
    try std.testing.expectEqual(@as(i64, 4), try arith.eval("2 + 2"));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    // Different expression adds to cache
    try std.testing.expectEqual(@as(i64, 25), try arith.eval("5 * 5"));
    try std.testing.expectEqual(@as(usize, 2), cache.count());
}

test "expression cache lru eviction" {
    const allocator = std.testing.allocator;
    var cache = ExpressionCache.init(allocator);
    defer cache.deinit();

    // Fill cache to capacity (128 entries)
    for (0..128) |i| {
        var buf: [32]u8 = undefined;
        const expr = std.fmt.bufPrint(&buf, "{d} + 1", .{i}) catch unreachable;
        try cache.put(expr, @intCast(i + 1));
    }

    try std.testing.expectEqual(@as(usize, 128), cache.count());

    // Access the first entry to make it recently used
    _ = cache.get("0 + 1");

    // Add a new entry - should evict an old one (not "0 + 1")
    try cache.put("999 + 1", 1000);
    try std.testing.expectEqual(@as(usize, 128), cache.count());

    // "0 + 1" should still be there since it was recently accessed
    try std.testing.expectEqual(@as(?i64, 1), cache.get("0 + 1"));
}

test "ExpressionCache put/get basic" {
    const allocator = std.testing.allocator;
    var cache = ExpressionCache.init(allocator);
    defer cache.deinit();

    try cache.put("2+2", 4);
    try cache.put("3*5", 15);

    try std.testing.expectEqual(@as(?i64, 4), cache.get("2+2"));
    try std.testing.expectEqual(@as(?i64, 15), cache.get("3*5"));
    try std.testing.expectEqual(@as(?i64, null), cache.get("missing"));
}

test "ExpressionCache update existing" {
    const allocator = std.testing.allocator;
    var cache = ExpressionCache.init(allocator);
    defer cache.deinit();

    try cache.put("key", 1);
    try cache.put("key", 2); // Update

    try std.testing.expectEqual(@as(?i64, 2), cache.get("key"));
    try std.testing.expectEqual(@as(usize, 1), cache.count());
}

test "ExpressionCache clear" {
    const allocator = std.testing.allocator;
    var cache = ExpressionCache.init(allocator);
    defer cache.deinit();

    try cache.put("a", 1);
    try cache.put("b", 2);
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(?i64, null), cache.get("a"));
}
