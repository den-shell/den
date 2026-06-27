const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");
const types = @import("../types/mod.zig");

const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const TokenType = tokenizer_mod.TokenType;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .pos = 0,
        };
    }

    /// Whether a token can serve as a file-target for a redirection.
    /// A plain word is the common case; a process substitution `<(...)`/`>(...)`
    /// is also valid (`cat < <(echo hi)`), where the construct's raw value is
    /// later expanded to a `/dev/fd/N` path by the expander.
    fn isRedirTarget(token_type: TokenType) bool {
        return switch (token_type) {
            .word, .process_sub_in, .process_sub_out => true,
            else => false,
        };
    }

    pub fn parse(self: *Parser) !types.CommandChain {
        var commands_buffer: [32]types.ParsedCommand = undefined;
        var cmd_count: usize = 0;

        var operators_buffer: [31]types.Operator = undefined;
        var op_count: usize = 0;

        // Parse first command
        const first_cmd = try self.parseCommand();
        commands_buffer[cmd_count] = first_cmd;
        cmd_count += 1;

        // Parse chains with operators
        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            const op: types.Operator = switch (token.type) {
                .pipe => .pipe,
                .and_op => .and_op,
                .or_op => .or_op,
                .semicolon => .semicolon,
                .background => .background,
                else => break,
            };

            self.pos += 1; // Consume operator

            if (op_count >= operators_buffer.len) return error.TooManyOperators;
            operators_buffer[op_count] = op;
            op_count += 1;

            // Background operator can be at end of input
            if (op == .background) {
                break;
            }

            if (self.pos >= self.tokens.len) {
                return error.UnexpectedEndOfInput;
            }

            const next_cmd = try self.parseCommand();
            if (cmd_count >= commands_buffer.len) return error.TooManyCommands;
            commands_buffer[cmd_count] = next_cmd;
            cmd_count += 1;
        }

        // Allocate and copy
        const commands = try self.allocator.alloc(types.ParsedCommand, cmd_count);
        errdefer self.allocator.free(commands);
        @memcpy(commands, commands_buffer[0..cmd_count]);

        const operators = try self.allocator.alloc(types.Operator, op_count);
        @memcpy(operators, operators_buffer[0..op_count]);

        return types.CommandChain{
            .commands = commands,
            .operators = operators,
        };
    }

    fn parseCommand(self: *Parser) !types.ParsedCommand {
        var args_buffer: [64][]const u8 = undefined;
        var arg_count: usize = 0;

        var quoted_buffer: [64]bool = undefined;

        var redir_buffer: [8]types.Redirection = undefined;
        var redir_count: usize = 0;

        var command_name: ?[]const u8 = null;

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            switch (token.type) {
                // Words and keyword tokens can be command names or arguments
                // Keywords like 'done', 'fi', 'if' etc. can be used as arguments in command context
                .word, .process_sub_in, .process_sub_out, .kw_if, .kw_then, .kw_else, .kw_elif, .kw_fi, .kw_for, .kw_while, .kw_do, .kw_done, .kw_case, .kw_esac, .kw_in, .kw_function, .kw_let, .kw_mut, .kw_try, .kw_catch, .kw_match => {
                    // Process substitution tokens are treated as word arguments
                    // The value contains the full construct like "<(echo hello)"
                    const value = try self.allocator.dupe(u8, token.value);
                    if (command_name == null) {
                        command_name = value;
                    } else {
                        if (arg_count >= args_buffer.len) return error.TooManyArguments;
                        args_buffer[arg_count] = value;
                        quoted_buffer[arg_count] = token.was_quoted;
                        arg_count += 1;
                    }
                    self.pos += 1;
                },
                .redirect_out => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_truncate,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_clobber => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_clobber,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_append => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_append,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_in => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .input,
                        .fd = 0,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_inout => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .input_output,
                        .fd = 0,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_err => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_truncate,
                        .fd = 2,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .heredoc => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const delimiter = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .heredoc,
                        .fd = 0,
                        .target = delimiter,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .herestring => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const content = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .herestring,
                        .fd = 0,
                        .target = content,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_both => {
                    // &> redirects both stdout and stderr to file
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    // Redirect stdout (fd 1) to file
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_truncate,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    // Redirect stderr (fd 2) to stdout (fd 1)
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .fd_duplicate,
                        .fd = 2,
                        .target = try self.allocator.dupe(u8, "1"),
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_both_append => {
                    // &>> appends both stdout and stderr to file
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or !isRedirTarget(self.tokens[self.pos].type)) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    // Redirect stdout (fd 1) to file in append mode
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_append,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    // Redirect stderr (fd 2) to stdout (fd 1)
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .fd_duplicate,
                        .fd = 2,
                        .target = try self.allocator.dupe(u8, "1"),
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_fd_dup => {
                    // Parse token like "2>&1" or "3<&0"
                    const token_value = self.tokens[self.pos].value;

                    // Find the operator position (>& or <&). A valid token must
                    // contain one, so reject tokens that lack it instead of
                    // reading past the end.
                    var op_pos: usize = 0;
                    while (op_pos + 1 < token_value.len) : (op_pos += 1) {
                        if ((token_value[op_pos] == '>' or token_value[op_pos] == '<') and
                            token_value[op_pos + 1] == '&')
                        {
                            break;
                        }
                    }
                    if (op_pos + 1 >= token_value.len) return error.InvalidFileDescriptor;

                    // Extract source FD (default: 1 for >&, 0 for <&)
                    const source_fd_str = token_value[0..op_pos];
                    const source_fd = if (source_fd_str.len == 0)
                        (if (token_value[op_pos] == '>') @as(u32, 1) else @as(u32, 0))
                    else
                        std.fmt.parseInt(u32, source_fd_str, 10) catch {
                            return error.InvalidFileDescriptor;
                        };

                    // Extract target FD (skip >& or <&)
                    const target_fd_str = token_value[op_pos + 2 ..];

                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;

                    if (std.mem.eql(u8, target_fd_str, "-")) {
                        // >&- or <&- means close the fd
                        redir_buffer[redir_count] = .{
                            .kind = .fd_close,
                            .fd = source_fd,
                            .target = try self.allocator.dupe(u8, "-"),
                        };
                    } else {
                        const target_fd_int = std.fmt.parseInt(i32, target_fd_str, 10) catch {
                            return error.InvalidFileDescriptor;
                        };
                        redir_buffer[redir_count] = .{
                            .kind = .fd_duplicate,
                            .fd = source_fd,
                            .target = try std.fmt.allocPrint(self.allocator, "{d}", .{target_fd_int}),
                        };
                    }
                    redir_count += 1;
                    self.pos += 1;
                },
                else => break, // Stop at operators or other non-command tokens
            }
        }

        if (command_name == null) {
            // Bare redirections (e.g. "> file") are valid in POSIX sh/bash.
            // They create/truncate the target file with no command.
            if (redir_count > 0) {
                command_name = try self.allocator.dupe(u8, "");
            } else {
                return error.EmptyCommand;
            }
        }

        // Allocate and copy
        const args = try self.allocator.alloc([]const u8, arg_count);
        @memcpy(args, args_buffer[0..arg_count]);

        const quoted_args = try self.allocator.alloc(bool, arg_count);
        @memcpy(quoted_args, quoted_buffer[0..arg_count]);

        const redirections = try self.allocator.alloc(types.Redirection, redir_count);
        @memcpy(redirections, redir_buffer[0..redir_count]);

        return types.ParsedCommand{
            .name = command_name.?,
            .args = args,
            .redirections = redirections,
            .type = .external,
            .quoted_args = quoted_args,
        };
    }
};

test "parser basic command" {
    const allocator = std.testing.allocator;

    var t = Tokenizer.init(allocator, "echo hello world");
    const tokens = try t.tokenize();
    defer t.deinitTokens(tokens);

    var p = Parser.init(allocator, tokens);
    var chain = try p.parse();
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 2), chain.commands[0].args.len);
    try std.testing.expectEqualStrings("hello", chain.commands[0].args[0]);
}

test "parser pipeline" {
    const allocator = std.testing.allocator;

    var t = Tokenizer.init(allocator, "ls | grep foo");
    const tokens = try t.tokenize();
    defer t.deinitTokens(tokens);

    var p = Parser.init(allocator, tokens);
    var chain = try p.parse();
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.pipe, chain.operators[0]);
}

test "parser fd redirect with 2>&1" {
    const allocator = std.testing.allocator;

    var t = Tokenizer.init(allocator, "cmd 2>&1");
    const tokens = try t.tokenize();
    defer t.deinitTokens(tokens);

    var p = Parser.init(allocator, tokens);
    var chain = try p.parse();
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 1), chain.commands[0].redirections.len);
    try std.testing.expectEqual(@as(u32, 2), chain.commands[0].redirections[0].fd);
}

test "parser fd redirect default source >&" {
    const allocator = std.testing.allocator;

    var t = Tokenizer.init(allocator, "cmd >&2");
    const tokens = try t.tokenize();
    defer t.deinitTokens(tokens);

    var p = Parser.init(allocator, tokens);
    var chain = try p.parse();
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 1), chain.commands[0].redirections.len);
    // Default source for >& is fd 1 (stdout)
    try std.testing.expectEqual(@as(u32, 1), chain.commands[0].redirections[0].fd);
}
