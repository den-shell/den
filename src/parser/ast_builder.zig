// AST Builder - Converts tokens into Abstract Syntax Tree
// Implements a recursive descent parser for shell grammar
const std = @import("std");
const ast = @import("ast.zig");
const tokenizer_mod = @import("tokenizer.zig");

const Token = tokenizer_mod.Token;
const TokenType = tokenizer_mod.TokenType;
const Node = ast.Node;
const Word = ast.Word;
const Redirection = ast.Redirection;
const Assignment = ast.Assignment;
const SourceLoc = ast.SourceLoc;
const Span = ast.Span;

pub const AstBuilder = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,
    errors: std.ArrayListUnmanaged(ParseError),

    /// All possible errors from parsing
    pub const Error = error{
        UnexpectedEof,
        UnexpectedToken,
        InvalidRedirection,
        OutOfMemory,
    };

    pub const ParseError = struct {
        message: []const u8,
        loc: SourceLoc,
        kind: ErrorKind,

        pub const ErrorKind = enum {
            unexpected_token,
            unexpected_eof,
            missing_keyword,
            invalid_syntax,
            unclosed_construct,
        };
    };

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) AstBuilder {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .pos = 0,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *AstBuilder) void {
        self.errors.deinit(self.allocator);
    }

    /// Parse a complete script
    pub fn parse(self: *AstBuilder) Error!*Node {
        return self.parseScript();
    }

    /// Get parse errors
    pub fn getErrors(self: *const AstBuilder) []const ParseError {
        return self.errors.items;
    }

    // ========================================================================
    // Token utilities
    // ========================================================================

    fn current(self: *const AstBuilder) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn peek(self: *const AstBuilder, offset: usize) ?Token {
        const idx = self.pos + offset;
        if (idx >= self.tokens.len) return null;
        return self.tokens[idx];
    }

    fn advance(self: *AstBuilder) ?Token {
        if (self.pos >= self.tokens.len) return null;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return tok;
    }

    fn check(self: *const AstBuilder, token_type: TokenType) bool {
        const tok = self.current() orelse return false;
        return tok.type == token_type;
    }

    fn match(self: *AstBuilder, token_type: TokenType) bool {
        if (self.check(token_type)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *AstBuilder, token_type: TokenType) Error!Token {
        const tok = self.current() orelse {
            try self.addError("Unexpected end of input", .{}, .unexpected_eof);
            return error.UnexpectedEof;
        };
        if (tok.type != token_type) {
            try self.addError("Expected different token", self.currentLoc(), .unexpected_token);
            return error.UnexpectedToken;
        }
        return self.advance().?;
    }

    fn currentLoc(self: *const AstBuilder) SourceLoc {
        const tok = self.current() orelse return .{};
        return .{
            .line = @intCast(tok.line),
            .column = @intCast(tok.column),
        };
    }

    fn addError(self: *AstBuilder, message: []const u8, loc: SourceLoc, kind: ParseError.ErrorKind) Error!void {
        try self.errors.append(self.allocator, .{
            .message = message,
            .loc = loc,
            .kind = kind,
        });
    }

    fn skipNewlines(self: *AstBuilder) void {
        while (self.check(.newline)) {
            _ = self.advance();
        }
    }

    fn isCommandTerminator(token_type: TokenType) bool {
        return switch (token_type) {
            .semicolon, .newline, .background, .eof => true,
            else => false,
        };
    }

    fn isRedirection(token_type: TokenType) bool {
        return switch (token_type) {
            .redirect_out, .redirect_append, .redirect_in, .redirect_inout, .redirect_err, .redirect_err_append, .redirect_both, .redirect_fd_dup, .heredoc, .herestring => true,
            else => false,
        };
    }

    // ========================================================================
    // Grammar rules
    // ========================================================================

    /// script: command_list EOF
    fn parseScript(self: *AstBuilder) Error!*Node {
        var commands: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer {
            for (commands.items) |cmd| {
                cmd.deinit(self.allocator);
                self.allocator.destroy(cmd);
            }
            commands.deinit(self.allocator);
        }

        self.skipNewlines();

        while (!self.check(.eof)) {
            const cmd = try self.parseCompoundList();
            try commands.append(self.allocator, cmd);
            self.skipNewlines();
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .script = .{
                .commands = try commands.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    /// compound_list: and_or ((';' | '&' | newline) and_or)*
    fn parseCompoundList(self: *AstBuilder) Error!*Node {
        var elements: std.ArrayListUnmanaged(ast.List.Element) = .empty;
        errdefer {
            for (elements.items) |*elem| {
                elem.command.deinit(self.allocator);
                self.allocator.destroy(elem.command);
            }
            elements.deinit(self.allocator);
        }

        const first = try self.parseAndOr();
        var first_op: ?ast.List.Operator = null;

        // Check for separator
        if (self.check(.semicolon)) {
            _ = self.advance();
            first_op = .semicolon;
        } else if (self.check(.background)) {
            // Wrap in background node
            const bg_node = try self.allocator.create(Node);
            bg_node.* = .{ .background = .{ .command = first } };

            try elements.append(self.allocator, .{ .command = bg_node, .operator = null });

            self.skipNewlines();
            if (self.check(.eof) or self.isCompoundEnd()) {
                return self.wrapInList(&elements);
            }
            return self.continueCompoundList(&elements);
        } else if (self.check(.newline)) {
            self.skipNewlines();
            first_op = .newline;
        }

        try elements.append(self.allocator, .{ .command = first, .operator = first_op });

        // Continue parsing if not at end
        if (!self.check(.eof) and !self.isCompoundEnd()) {
            return self.continueCompoundList(&elements);
        }

        return self.wrapInList(&elements);
    }

    fn continueCompoundList(self: *AstBuilder, elements: *std.ArrayListUnmanaged(ast.List.Element)) Error!*Node {
        while (!self.check(.eof) and !self.isCompoundEnd()) {
            self.skipNewlines();
            if (self.check(.eof) or self.isCompoundEnd()) break;

            const cmd = try self.parseAndOr();
            var op: ?ast.List.Operator = null;

            if (self.check(.semicolon)) {
                _ = self.advance();
                op = .semicolon;
            } else if (self.check(.background)) {
                _ = self.advance();
                // Wrap in background
                const bg_node = try self.allocator.create(Node);
                bg_node.* = .{ .background = .{ .command = cmd } };
                try elements.append(self.allocator, .{ .command = bg_node, .operator = null });
                continue;
            } else if (self.check(.newline)) {
                self.skipNewlines();
                op = .newline;
            }

            try elements.append(self.allocator, .{ .command = cmd, .operator = op });
        }

        return self.wrapInList(elements);
    }

    fn wrapInList(self: *AstBuilder, elements: *std.ArrayListUnmanaged(ast.List.Element)) Error!*Node {
        if (elements.items.len == 1 and elements.items[0].operator == null) {
            // Single command, no need for list wrapper
            const cmd = elements.items[0].command;
            elements.deinit(self.allocator);
            return cmd;
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .list = .{
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    fn isCompoundEnd(self: *const AstBuilder) bool {
        const tok = self.current() orelse return true;
        return switch (tok.type) {
            .kw_fi, .kw_done, .kw_esac, .kw_else, .kw_elif, .kw_then, .rparen => true,
            else => false,
        };
    }

    /// and_or: pipeline (('&&' | '||') pipeline)*
    fn parseAndOr(self: *AstBuilder) Error!*Node {
        var left = try self.parsePipeline();

        while (true) {
            const op: ast.List.Operator = blk: {
                if (self.check(.and_op)) {
                    _ = self.advance();
                    break :blk .@"and";
                } else if (self.check(.or_op)) {
                    _ = self.advance();
                    break :blk .@"or";
                } else {
                    return left;
                }
            };

            self.skipNewlines();
            const right = try self.parsePipeline();

            // Create list node
            var elements = try self.allocator.alloc(ast.List.Element, 2);
            elements[0] = .{ .command = left, .operator = op };
            elements[1] = .{ .command = right, .operator = null };

            const list_node = try self.allocator.create(Node);
            list_node.* = .{ .list = .{ .elements = elements } };
            left = list_node;
        }
    }

    /// pipeline: ['!'] command ('|' command)*
    fn parsePipeline(self: *AstBuilder) Error!*Node {
        const negated = self.match(.word) and blk: {
            // Check if previous token was "!"
            if (self.pos > 0) {
                const prev = self.tokens[self.pos - 1];
                if (std.mem.eql(u8, prev.value, "!")) {
                    break :blk true;
                }
            }
            self.pos -= 1; // Undo advance
            break :blk false;
        };

        var commands: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer {
            for (commands.items) |cmd| {
                cmd.deinit(self.allocator);
                self.allocator.destroy(cmd);
            }
            commands.deinit(self.allocator);
        }

        const first = try self.parseCommand();
        try commands.append(self.allocator, first);

        while (self.check(.pipe)) {
            _ = self.advance();
            self.skipNewlines();
            const cmd = try self.parseCommand();
            try commands.append(self.allocator, cmd);
        }

        if (commands.items.len == 1 and !negated) {
            // Single command, no pipeline needed
            const cmd = commands.items[0];
            commands.deinit(self.allocator);
            return cmd;
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .pipeline = .{
                .commands = try commands.toOwnedSlice(self.allocator),
                .negated = negated,
            },
        };
        return node;
    }

    /// command: compound_command | simple_command | function_def
    fn parseCommand(self: *AstBuilder) Error!*Node {
        const tok = self.current() orelse return error.UnexpectedEof;

        return switch (tok.type) {
            .kw_if => self.parseIf(),
            .kw_for => self.parseFor(),
            .kw_while => self.parseWhile(),
            .kw_case => self.parseCase(),
            .kw_function => self.parseFunction(),
            .lparen => self.parseSubshell(),
            else => self.parseSimpleCommand(),
        };
    }

    /// simple_command: (assignment)* word (word | redirection)*
    fn parseSimpleCommand(self: *AstBuilder) Error!*Node {
        var assignments: std.ArrayListUnmanaged(Assignment) = .empty;
        var args: std.ArrayListUnmanaged(Word) = .empty;
        var redirections: std.ArrayListUnmanaged(Redirection) = .empty;
        var name: ?Word = null;

        errdefer {
            for (assignments.items) |*a| a.deinit(self.allocator);
            assignments.deinit(self.allocator);
            for (args.items) |*a| a.deinit(self.allocator);
            args.deinit(self.allocator);
            for (redirections.items) |*r| r.deinit(self.allocator);
            redirections.deinit(self.allocator);
            if (name) |*n| n.deinit(self.allocator);
        }

        while (true) {
            const tok = self.current() orelse break;

            if (isRedirection(tok.type)) {
                const redir = try self.parseRedirection();
                try redirections.append(self.allocator, redir);
            } else if (tok.type == .word or tok.type == .process_sub_in or tok.type == .process_sub_out) {
                // Check for assignment (VAR=value)
                if (name == null and isAssignment(tok.value)) {
                    const assignment = try self.parseAssignment(tok);
                    try assignments.append(self.allocator, assignment);
                    _ = self.advance();
                } else {
                    // Command name or argument
                    const word = try self.parseWord(tok);
                    _ = self.advance();
                    if (name == null) {
                        name = word;
                    } else {
                        try args.append(self.allocator, word);
                    }
                }
            } else {
                break;
            }
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .simple_command = .{
                .name = name,
                .args = try args.toOwnedSlice(self.allocator),
                .assignments = try assignments.toOwnedSlice(self.allocator),
                .redirections = try redirections.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    fn isAssignment(value: []const u8) bool {
        // Check for VAR=value pattern (= not at start)
        for (value, 0..) |c, i| {
            if (c == '=') return i > 0;
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        return false;
    }

    fn parseAssignment(self: *AstBuilder, tok: Token) Error!Assignment {
        // Split at =
        if (std.mem.indexOf(u8, tok.value, "=")) |eq_pos| {
            var value_word: ?Word = null;
            if (eq_pos + 1 < tok.value.len) {
                const parts = try self.allocator.alloc(Word.Part, 1);
                parts[0] = .{ .literal = try self.allocator.dupe(u8, tok.value[eq_pos + 1 ..]) };
                value_word = Word{ .parts = parts };
            }
            return .{
                .name = tok.value[0..eq_pos],
                .value = value_word,
            };
        }
        return .{ .name = tok.value };
    }

    fn parseWord(self: *AstBuilder, tok: Token) Error!Word {
        // For now, treat as literal. Full expansion parsing would be more complex.
        const parts = try self.allocator.alloc(Word.Part, 1);
        parts[0] = .{ .literal = try self.allocator.dupe(u8, tok.value) };
        return .{ .parts = parts };
    }

    fn parseRedirection(self: *AstBuilder) Error!Redirection {
        const tok = self.advance() orelse return error.UnexpectedEof;

        const kind: Redirection.Kind = switch (tok.type) {
            .redirect_out => .output,
            .redirect_append => .output_append,
            .redirect_in => .input,
            .redirect_inout => .input_output,
            .redirect_err => .output,
            .redirect_err_append => .append,
            .redirect_both => .output,
            .heredoc => .heredoc,
            .herestring => .herestring,
            .redirect_fd_dup => if (std.mem.indexOf(u8, tok.value, ">&") != null) .dup_output else .dup_input,
            else => return error.InvalidRedirection,
        };

        // Get target
        const target_tok = self.advance() orelse return error.UnexpectedEof;
        const target = try self.parseWord(target_tok);

        return .{
            .kind = kind,
            .fd = if (tok.type == .redirect_err or tok.type == .redirect_err_append) @as(u32, 2) else null,
            .target = target,
        };
    }

    /// if_clause: 'if' compound_list 'then' compound_list
    ///            ('elif' compound_list 'then' compound_list)*
    ///            ['else' compound_list] 'fi'
    fn parseIf(self: *AstBuilder) Error!*Node {
        _ = try self.expect(.kw_if);

        const condition = try self.parseCompoundList();
        _ = try self.expect(.kw_then);
        const body = try self.parseCompoundList();

        var elif_branches: std.ArrayListUnmanaged(ast.IfStatement.Branch) = .empty;
        errdefer elif_branches.deinit(self.allocator);

        while (self.check(.kw_elif)) {
            _ = self.advance();
            const elif_cond = try self.parseCompoundList();
            _ = try self.expect(.kw_then);
            const elif_body = try self.parseCompoundList();
            try elif_branches.append(self.allocator, .{ .condition = elif_cond, .body = elif_body });
        }

        var else_body: ?*Node = null;
        if (self.check(.kw_else)) {
            _ = self.advance();
            else_body = try self.parseCompoundList();
        }

        _ = try self.expect(.kw_fi);

        const node = try self.allocator.create(Node);
        node.* = .{
            .if_stmt = .{
                .if_branch = .{ .condition = condition, .body = body },
                .elif_branches = try elif_branches.toOwnedSlice(self.allocator),
                .else_body = else_body,
            },
        };
        return node;
    }

    /// for_clause: 'for' name ['in' word*] do_group
    fn parseFor(self: *AstBuilder) Error!*Node {
        _ = try self.expect(.kw_for);

        const var_tok = try self.expect(.word);
        const variable = try self.allocator.dupe(u8, var_tok.value);

        var values: ?[]Word = null;
        if (self.check(.kw_in)) {
            _ = self.advance();
            var words: std.ArrayListUnmanaged(Word) = .empty;
            while (self.check(.word)) {
                const tok = self.advance().?;
                try words.append(self.allocator, try self.parseWord(tok));
            }
            if (words.items.len > 0) {
                values = try words.toOwnedSlice(self.allocator);
            } else {
                words.deinit(self.allocator);
            }
        }

        self.skipNewlines();
        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        _ = try self.expect(.kw_done);

        const node = try self.allocator.create(Node);
        node.* = .{
            .for_loop = .{
                .variable = variable,
                .values = values,
                .body = body,
            },
        };
        return node;
    }

    /// while_clause: 'while' compound_list do_group
    fn parseWhile(self: *AstBuilder) Error!*Node {
        _ = try self.expect(.kw_while);
        const condition = try self.parseCompoundList();
        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        _ = try self.expect(.kw_done);

        const node = try self.allocator.create(Node);
        node.* = .{
            .while_loop = .{
                .condition = condition,
                .body = body,
            },
        };
        return node;
    }

    /// case_clause: 'case' word 'in' case_item* 'esac'
    fn parseCase(self: *AstBuilder) Error!*Node {
        _ = try self.expect(.kw_case);
        const word_tok = try self.expect(.word);
        const word = try self.parseWord(word_tok);
        _ = try self.expect(.kw_in);
        self.skipNewlines();

        var items: std.ArrayListUnmanaged(ast.CaseStatement.CaseItem) = .empty;
        errdefer items.deinit(self.allocator);

        while (!self.check(.kw_esac) and !self.check(.eof)) {
            const item = try self.parseCaseItem();
            try items.append(self.allocator, item);
            self.skipNewlines();
        }

        _ = try self.expect(.kw_esac);

        const node = try self.allocator.create(Node);
        node.* = .{
            .case_stmt = .{
                .word = word,
                .items = try items.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    fn parseCaseItem(self: *AstBuilder) Error!ast.CaseStatement.CaseItem {
        var patterns: std.ArrayListUnmanaged(Word) = .empty;
        errdefer patterns.deinit(self.allocator);

        // Parse patterns separated by |
        while (true) {
            const tok = try self.expect(.word);
            try patterns.append(self.allocator, try self.parseWord(tok));

            if (!self.check(.pipe)) break;
            _ = self.advance(); // consume |
        }

        // Expect )
        _ = try self.expect(.rparen);

        // Parse body until ;; or esac
        var body: ?*Node = null;
        if (!self.check(.semicolon) and !self.check(.kw_esac)) {
            body = try self.parseCompoundList();
        }

        // Handle terminator
        var terminator: ast.CaseStatement.Terminator = .break_;
        if (self.check(.semicolon)) {
            _ = self.advance();
            if (self.check(.semicolon)) {
                _ = self.advance();
                terminator = .break_;
            }
        }

        return .{
            .patterns = try patterns.toOwnedSlice(self.allocator),
            .body = body,
            .terminator = terminator,
        };
    }

    /// function_def: 'function' name '{' compound_list '}' | name '()' '{' compound_list '}'
    fn parseFunction(self: *AstBuilder) Error!*Node {
        _ = try self.expect(.kw_function);
        const name_tok = try self.expect(.word);
        const name = try self.allocator.dupe(u8, name_tok.value);

        // Skip optional ()
        if (self.check(.lparen)) {
            _ = self.advance();
            _ = try self.expect(.rparen);
        }

        self.skipNewlines();

        // Parse body (brace group)
        const body = try self.parseCommand();

        const node = try self.allocator.create(Node);
        node.* = .{
            .function_def = .{
                .name = name,
                .body = body,
            },
        };
        return node;
    }

    /// subshell: '(' compound_list ')'
    fn parseSubshell(self: *AstBuilder) Error!*Node {
        _ = try self.expect(.lparen);
        const body = try self.parseCompoundList();
        _ = try self.expect(.rparen);

        const node = try self.allocator.create(Node);
        node.* = .{ .subshell = .{ .body = body } };
        return node;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AstBuilder simple command" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .word, .value = "echo", .line = 1, .column = 1 },
        .{ .type = .word, .value = "hello", .line = 1, .column = 6 },
        .{ .type = .eof, .value = "", .line = 1, .column = 12 },
    };

    var builder = AstBuilder.init(allocator, &tokens);
    defer builder.deinit();

    const node = try builder.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }

    try std.testing.expect(node.* == .script);
}

test "AstBuilder pipeline" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .word, .value = "ls", .line = 1, .column = 1 },
        .{ .type = .pipe, .value = "|", .line = 1, .column = 4 },
        .{ .type = .word, .value = "grep", .line = 1, .column = 6 },
        .{ .type = .word, .value = "foo", .line = 1, .column = 11 },
        .{ .type = .eof, .value = "", .line = 1, .column = 15 },
    };

    var builder = AstBuilder.init(allocator, &tokens);
    defer builder.deinit();

    const node = try builder.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }

    try std.testing.expect(node.* == .script);
}

test "AstBuilder if statement" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .kw_if, .value = "if", .line = 1, .column = 1 },
        .{ .type = .word, .value = "true", .line = 1, .column = 4 },
        .{ .type = .kw_then, .value = "then", .line = 1, .column = 9 },
        .{ .type = .word, .value = "echo", .line = 1, .column = 14 },
        .{ .type = .word, .value = "yes", .line = 1, .column = 19 },
        .{ .type = .kw_fi, .value = "fi", .line = 1, .column = 23 },
        .{ .type = .eof, .value = "", .line = 1, .column = 26 },
    };

    var builder = AstBuilder.init(allocator, &tokens);
    defer builder.deinit();

    const node = try builder.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }

    try std.testing.expect(node.* == .script);
    const script = node.script;
    try std.testing.expectEqual(@as(usize, 1), script.commands.len);
    try std.testing.expect(script.commands[0].* == .if_stmt);
}
