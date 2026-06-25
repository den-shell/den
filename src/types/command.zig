const std = @import("std");

/// Type of command
pub const CommandType = enum {
    builtin,
    alias,
    external,
    function,
};

/// Command operators
pub const Operator = enum {
    pipe, // |
    and_op, // &&
    or_op, // ||
    semicolon, // ;
    background, // &
};

/// I/O redirection
pub const Redirection = struct {
    kind: Kind,
    fd: u32 = 1, // File descriptor (default stdout)
    target: []const u8,

    pub const Kind = enum {
        output_truncate, // >
        output_append, // >>
        output_clobber, // >|
        input, // <
        input_output, // <>
        heredoc, // <<
        herestring, // <<<
        fd_duplicate, // >&, <&
        fd_close, // >&-, <&-
    };
};

/// Parsed command structure
pub const ParsedCommand = struct {
    name: []const u8,
    args: [][]const u8,
    redirections: []Redirection,
    type: CommandType = .external,
    quoted_args: ?[]const bool = null,
    cmd_sub_exit_code: ?i32 = null, // Exit code from command substitution during expansion
    expanded: bool = false, // Whether variable/brace/glob expansion has been applied

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        // Free command name (allocated during parsing/expansion)
        allocator.free(self.name);

        // Free arguments
        for (self.args) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.args);

        // Free quoted_args tracking array
        if (self.quoted_args) |qa| {
            allocator.free(qa);
        }

        // Free redirections
        for (self.redirections) |redir| {
            allocator.free(redir.target);
        }
        allocator.free(self.redirections);
    }
};

/// Command chain (connected by operators)
pub const CommandChain = struct {
    commands: []ParsedCommand,
    operators: []Operator,

    pub fn deinit(self: *CommandChain, allocator: std.mem.Allocator) void {
        for (self.commands) |*cmd| {
            cmd.deinit(allocator);
        }
        allocator.free(self.commands);
        allocator.free(self.operators);
    }
};

test "Operator enum" {
    const pipe = Operator.pipe;
    const and_op = Operator.and_op;
    try std.testing.expect(pipe != and_op);
}

test "Redirection struct" {
    const redir = Redirection{
        .kind = .output_truncate,
        .fd = 1,
        .target = "output.txt",
    };
    try std.testing.expectEqualStrings("output.txt", redir.target);
}
