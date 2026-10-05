//! Compound Command Execution
//!
//! Runs input whose structure the simple-command parser cannot see: lists that
//! span compound commands, compound commands inside `&&`/`||` lists and
//! pipelines, and compound commands with redirections of their own.
//!
//! `parser/compound.zig` says where each piece begins and ends. This module
//! routes the pieces: a piece that is itself a simple command (or a simple
//! and-or list or pipeline) goes back through `Shell.executeCommand`, and a
//! loop, `if` or `case` runs on the existing ControlFlowExecutor with its body
//! handed over as text. Every recursive call gets a strictly smaller slice of
//! the input, so the recursion always ends.
//!
//! Anything the structural parser does not understand falls through to the
//! older string-based paths untouched, which keeps Den's own syntax (`try`,
//! `match`, zsh-isms) working as before.

const std = @import("std");
const builtin = @import("builtin");
const Shell = @import("../shell.zig").Shell;
const compound = @import("../parser/compound.zig");
const parser_mod = @import("../parser/mod.zig");
const control_flow = @import("../scripting/control_flow.zig");
const redirection = @import("../executor/redirection.zig");
const IO = @import("../utils/io.zig").IO;
const process_util = @import("../utils/process.zig");

/// Calls back into `Shell.executeCommand` through a pointer, which breaks the
/// inferred-error-set cycle executeCommand -> tryExecute -> executeCommand.
fn exec(self: *Shell, text: []const u8) anyerror!void {
    const f: *const fn (*Shell, []const u8) anyerror!void = &Shell.executeCommand;
    return f(self, text);
}

/// Run `text` as a command, keeping only the error that must unwind the shell.
fn run(self: *Shell, text: []const u8) anyerror!void {
    exec(self, text) catch |err| {
        if (err == error.Exit) return err;
    };
}

/// True when a `break`, `continue`, `return` or `exit` is on its way out and
/// the rest of the current list must not run.
pub fn unwinding(self: *Shell) bool {
    if (self.break_levels > 0 or self.continue_levels > 0 or self.exit_requested) return true;
    if (self.function_manager.currentFrame()) |frame| {
        if (frame.return_requested) return true;
    }
    return false;
}

/// Cheap filter so plain commands (`ls -la`, `echo $x`) never pay for a parse.
fn mayNeedStructure(input: []const u8) bool {
    if (std.mem.indexOfAny(u8, input, ";\n&|({}") != null) return true;
    const trimmed = std.mem.trimStart(u8, input, " \t\r");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') end += 1;
    return compound.isReservedWord(trimmed[0..end]);
}

fn startsWithCompoundOpener(input: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, input, " \t\r\n");
    const openers = [_][]const u8{ "for", "while", "until", "if", "case", "select" };
    for (openers) |w| {
        if (trimmed.len > w.len and std.mem.startsWith(u8, trimmed, w) and
            (trimmed[w.len] == ' ' or trimmed[w.len] == '\t' or trimmed[w.len] == '\n'))
        {
            return true;
        }
    }
    return false;
}

/// Reserved words that can only close or continue a compound command. Found
/// where a command should start, they mean the input is malformed; looking
/// them up as programs only produced `for: command not found` and a list of
/// look-alike binaries.
fn isStrayKeyword(token: []const u8) bool {
    const words = [_][]const u8{ "then", "else", "elif", "fi", "do", "done", "esac", "}" };
    for (words) |w| {
        if (std.mem.eql(u8, token, w)) return true;
    }
    return false;
}

/// Execute `input` if its structure needs this module. Returns false when the
/// caller should carry on with the ordinary single-command path.
pub fn tryExecute(self: *Shell, input: []const u8) anyerror!bool {
    if (!mayNeedStructure(input)) return false;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: compound.Diagnostic = .{};
    const list = compound.parseWithDiagnostic(arena, input, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Syntax => {
            if (!isStrayKeyword(diag.token)) return false;
            try IO.eprint("den: syntax error near unexpected token `{s}'\n", .{diag.token});
            self.last_exit_code = 2;
            return true;
        },
        error.Incomplete => {
            if (!startsWithCompoundOpener(input)) return false;
            try IO.eprint("den: syntax error: unexpected end of input\n", .{});
            self.last_exit_code = 2;
            return true;
        },
    };

    if (list.items.len == 0) return false;

    const first = list.items[0];
    if (list.items.len > 1 or first.separator == .semi or first.separator == .newline) {
        try executeList(self, arena, input, list);
        return true;
    }

    if (first.separator == .amp) {
        if (!first.and_or.hasCompound()) return false;
        try runInBackground(self, first.span.text(input));
        return true;
    }

    return executeAndOr(self, arena, input, first.and_or);
}

fn executeList(self: *Shell, arena: std.mem.Allocator, src: []const u8, list: compound.List) anyerror!void {
    for (list.items) |item| {
        if (unwinding(self)) break;
        const text = item.span.text(src);
        self.last_chain_had_and_or = false;
        if (item.separator == .amp) {
            if (item.and_or.hasCompound()) {
                try runInBackground(self, text);
            } else {
                // The simple-command path knows how to background a chain.
                try run(self, try std.fmt.allocPrint(arena, "{s} &", .{text}));
            }
        } else {
            try run(self, text);
        }
        // set -e: stop at a failure that no && or || was there to handle.
        if (self.option_errexit and self.last_exit_code != 0 and !self.last_chain_had_and_or) break;
    }
}

/// Returns false when nothing in the and-or list is compound, so the ordinary
/// chain executor (which already handles `&&`, `||` and pipes) can run it.
fn executeAndOr(self: *Shell, arena: std.mem.Allocator, src: []const u8, ao: compound.AndOr) anyerror!bool {
    if (ao.pipelines.len > 1) {
        if (!ao.hasCompound()) return false;
        try run(self, ao.pipelines[0].span.text(src));
        for (ao.ops, ao.pipelines[1..]) |op, pipeline| {
            if (unwinding(self)) break;
            const succeeded = self.last_exit_code == 0;
            const wanted = switch (op) {
                .and_if => succeeded,
                .or_if => !succeeded,
            };
            if (wanted) try run(self, pipeline.span.text(src));
        }
        self.last_chain_had_and_or = true;
        return true;
    }

    const pipeline = ao.pipelines[0];
    const timer: ?Timer = if (pipeline.timed and pipeline.hasCompound()) Timer.start() else null;
    if (pipeline.commands.len > 1) {
        if (!pipeline.hasCompound()) return false;
        try runPipeline(self, src, pipeline);
    } else {
        const cmd = pipeline.commands[0];
        switch (cmd.kind) {
            .simple, .func_def => return false,
            // The interactive select menu keeps its own executor; it only
            // needs our help when redirections or `!` wrap it.
            .select_loop => if (!pipeline.bang and
                std.mem.trim(u8, cmd.redirections.text(src), " \t\r\n").len == 0) return false,
            else => {},
        }
        try runCompound(self, arena, src, cmd);
    }

    if (pipeline.bang) {
        self.last_exit_code = if (self.last_exit_code == 0) 1 else 0;
    }
    if (timer) |t| t.report(pipeline.timed_posix);
    return true;
}

/// `time` in front of a pipeline with a compound command in it. (A plain
/// `time cmd` is the `time` builtin's.) Real time, plus the CPU time of this
/// shell and its children over the same span.
const Timer = struct {
    start_ns: i128,
    user_us: i64,
    sys_us: i64,

    fn cpu() struct { user: i64, sys: i64 } {
        if (comptime builtin.os.tag == .windows) return .{ .user = 0, .sys = 0 };
        const me = std.posix.getrusage(std.posix.rusage.SELF);
        const kids = std.posix.getrusage(std.posix.rusage.CHILDREN);
        const us = struct {
            fn of(tv: anytype) i64 {
                return @as(i64, @intCast(tv.sec)) * 1_000_000 + @as(i64, @intCast(tv.usec));
            }
        }.of;
        return .{ .user = us(me.utime) + us(kids.utime), .sys = us(me.stime) + us(kids.stime) };
    }

    fn nowNs() i128 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    fn start() Timer {
        const c = cpu();
        return .{ .start_ns = nowNs(), .user_us = c.user, .sys_us = c.sys };
    }

    fn report(self: Timer, posix_format: bool) void {
        const real: f64 = @as(f64, @floatFromInt(nowNs() - self.start_ns)) / 1e9;
        const c = cpu();
        const user: f64 = @as(f64, @floatFromInt(c.user - self.user_us)) / 1e6;
        const sys: f64 = @as(f64, @floatFromInt(c.sys - self.sys_us)) / 1e6;
        if (posix_format) {
            IO.eprint("real {d:.2}\nuser {d:.2}\nsys {d:.2}\n", .{ real, user, sys }) catch {};
        } else {
            IO.eprint("\nreal\t{d:.3}s\nuser\t{d:.3}s\nsys\t{d:.3}s\n", .{ real, user, sys }) catch {};
        }
    }
};

// ----------------------------------------------------------------------------
// Compound commands
// ----------------------------------------------------------------------------

fn runCompound(self: *Shell, arena: std.mem.Allocator, src: []const u8, cmd: compound.Command) anyerror!void {
    const redirs = std.mem.trim(u8, cmd.redirections.text(src), " \t\r\n");
    if (redirs.len == 0) return runCompoundCore(self, arena, src, cmd);

    var saved = SavedFds{};
    defer saved.restore();
    applyRedirections(self, arena, redirs, &saved) catch {
        self.last_exit_code = 1;
        return;
    };
    return runCompoundCore(self, arena, src, cmd);
}

/// A body's text with surrounding whitespace and one trailing `;` removed, as
/// the one-element line list the ControlFlowExecutor expects.
fn bodyLines(arena: std.mem.Allocator, src: []const u8, span: compound.Span) ![][]const u8 {
    const text = listText(src, span);
    if (text.len == 0) return &.{};
    const lines = try arena.alloc([]const u8, 1);
    lines[0] = text;
    return lines;
}

fn listText(src: []const u8, span: compound.Span) []const u8 {
    var text = span.trimmed(src);
    if (text.len > 0 and text[text.len - 1] == ';' and (text.len < 2 or text[text.len - 2] != '\\')) {
        text = std.mem.trimEnd(u8, text[0 .. text.len - 1], " \t\r\n");
    }
    return text;
}

fn runCompoundCore(self: *Shell, arena: std.mem.Allocator, src: []const u8, cmd: compound.Command) anyerror!void {
    switch (cmd.kind) {
        .brace_group => {
            const body = listText(src, cmd.body);
            if (body.len > 0) try run(self, body);
        },
        .subshell => try runSubshell(self, listText(src, cmd.body)),
        .for_loop => {
            var items: std.ArrayList([]const u8) = .empty;
            if (cmd.words) |words| {
                for (words) |w| try items.append(arena, w.text(src));
            } else {
                // `for name; do` iterates the positional parameters.
                try items.append(arena, "\"$@\"");
            }
            var loop = control_flow.ForLoop{
                .variable = cmd.name.text(src),
                .items = items.items,
                .body = try bodyLines(arena, src, cmd.body),
                .allocator = arena,
            };
            var cf = control_flow.ControlFlowExecutor.init(self);
            self.last_exit_code = try cf.executeFor(&loop);
            propagateLoopControl(self, &cf);
        },
        .while_loop, .until_loop => {
            var loop = control_flow.WhileLoop{
                .condition = listText(src, cmd.condition),
                .body = try bodyLines(arena, src, cmd.body),
                .is_until = cmd.kind == .until_loop,
                .allocator = arena,
            };
            var cf = control_flow.ControlFlowExecutor.init(self);
            self.last_exit_code = try cf.executeWhile(&loop);
            propagateLoopControl(self, &cf);
        },
        .if_stmt => {
            const elifs = try arena.alloc(control_flow.ElifClause, cmd.clauses.len - 1);
            for (cmd.clauses[1..], elifs) |clause, *elif| {
                elif.* = .{
                    .condition = listText(src, clause.condition),
                    .body = try bodyLines(arena, src, clause.body),
                };
            }
            var stmt = control_flow.IfStatement{
                .condition = listText(src, cmd.clauses[0].condition),
                .then_body = try bodyLines(arena, src, cmd.clauses[0].body),
                .elif_clauses = elifs,
                .else_body = if (cmd.else_body) |span| try bodyLines(arena, src, span) else null,
                .allocator = arena,
            };
            var cf = control_flow.ControlFlowExecutor.init(self);
            self.last_exit_code = try cf.executeIf(&stmt);
            propagateLoopControl(self, &cf);
        },
        .case_stmt => {
            const clauses = try arena.alloc(control_flow.CaseClause, cmd.case_items.len);
            for (cmd.case_items, clauses) |item, *clause| {
                const patterns = try arena.alloc([]const u8, item.patterns.len);
                for (item.patterns, patterns) |span, *pattern| pattern.* = span.text(src);
                clause.* = .{
                    .patterns = patterns,
                    .body = try bodyLines(arena, src, item.body),
                    .terminator = switch (item.terminator) {
                        .normal => .normal,
                        .fallthrough => .fallthrough,
                        .continue_testing => .continue_testing,
                    },
                };
            }
            var stmt = control_flow.CaseStatement{
                .value = cmd.subject.text(src),
                .cases = clauses,
                .allocator = arena,
            };
            var cf = control_flow.ControlFlowExecutor.init(self);
            self.last_exit_code = try cf.executeCase(&stmt);
            propagateLoopControl(self, &cf);
        },
        .arith_for => {
            // `for ((init; cond; step))`: each part is an arithmetic
            // expression; init and step run as `(( ... ))` commands.
            var parts = [3]?[]const u8{ null, null, null };
            var it = std.mem.splitScalar(u8, cmd.condition.text(src), ';');
            for (&parts) |*part| {
                const raw = it.next() orelse break;
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len > 0) part.* = trimmed;
            }
            var loop = control_flow.CStyleForLoop{
                .init = if (parts[0]) |e| try std.fmt.allocPrint(arena, "(( {s} ))", .{e}) else null,
                .condition = parts[1],
                .update = if (parts[2]) |e| try std.fmt.allocPrint(arena, "(( {s} ))", .{e}) else null,
                .body = try bodyLines(arena, src, cmd.body),
                .allocator = arena,
            };
            var cf = control_flow.ControlFlowExecutor.init(self);
            self.last_exit_code = try cf.executeCStyleFor(&loop);
            propagateLoopControl(self, &cf);
        },
        // The interactive select menu keeps its string-based executor.
        .select_loop => try run(self, cmd.core.text(src)),
        .simple, .func_def => try run(self, cmd.span.text(src)),
    }
}

/// A `break 2` or `continue` that outlives this construct belongs to an
/// enclosing loop; hand it back to the shell so that loop sees it.
fn propagateLoopControl(self: *Shell, cf: *control_flow.ControlFlowExecutor) void {
    if (cf.break_levels > 0) self.break_levels = cf.break_levels;
    if (cf.continue_levels > 0) self.continue_levels = cf.continue_levels;
}

// ----------------------------------------------------------------------------
// Processes: subshells, pipelines, background lists
// ----------------------------------------------------------------------------

fn statusByte(code: i32) u8 {
    return @intCast(@as(u32, @bitCast(code)) & 0xff);
}

fn decodeWaitStatus(status: c_int) i32 {
    if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff);
    return 128 + @as(i32, @intCast(status & 0x7f));
}

/// In a forked child: take back the signals an interactive shell handles for
/// itself, so Ctrl+C stops the child and a closed pipe ends a writer loop
/// (`while :; do echo y; done | head -1`) instead of spinning on EPIPE.
fn prepareChild(self: *Shell) void {
    self.is_interactive = false;
    if (comptime builtin.os.tag == .windows) return;
    var action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &action, null);
}

fn runSubshell(self: *Shell, body: []const u8) anyerror!void {
    if (body.len == 0) {
        self.last_exit_code = 0;
        return;
    }
    if (comptime builtin.os.tag == .windows) {
        // No fork: run in place, with the isolation Windows allows (none).
        return run(self, body);
    }
    const pid = std.c.fork();
    if (pid < 0) {
        try IO.eprint("den: fork failed\n", .{});
        self.last_exit_code = 1;
        return;
    }
    if (pid == 0) {
        prepareChild(self);
        exec(self, body) catch {};
        std.c._exit(statusByte(self.last_exit_code));
    }
    var status: c_int = 0;
    _ = process_util.waitpidIntr(@intCast(pid), &status, 0);
    self.last_exit_code = decodeWaitStatus(status);
}

/// Run a pipeline in which at least one stage is a compound command. Every
/// stage but the last runs in a forked child; the last runs in this shell, as
/// in zsh and ksh, so `... | while read line; do n=$((n+1)); done` keeps `n`.
fn runPipeline(self: *Shell, src: []const u8, pipeline: compound.Pipeline) anyerror!void {
    const stages = pipeline.commands;
    if (comptime builtin.os.tag == .windows) {
        for (stages) |stage| try run(self, stage.span.text(src));
        return;
    }

    var pids: std.ArrayList(std.posix.pid_t) = .empty;
    defer pids.deinit(self.allocator);

    var prev_read: c_int = -1;
    for (stages[0 .. stages.len - 1], 0..) |stage, i| {
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) {
            try IO.eprint("den: pipe failed\n", .{});
            break;
        }
        const pid = std.c.fork();
        if (pid < 0) {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            try IO.eprint("den: fork failed\n", .{});
            break;
        }
        if (pid == 0) {
            prepareChild(self);
            if (prev_read >= 0) {
                _ = std.c.dup2(prev_read, std.posix.STDIN_FILENO);
                _ = std.c.close(prev_read);
            }
            _ = std.c.dup2(fds[1], std.posix.STDOUT_FILENO);
            if (pipeline.stderr_pipes[i]) _ = std.c.dup2(fds[1], std.posix.STDERR_FILENO);
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            exec(self, stage.span.text(src)) catch {};
            std.c._exit(statusByte(self.last_exit_code));
        }
        _ = std.c.close(fds[1]);
        if (prev_read >= 0) _ = std.c.close(prev_read);
        prev_read = fds[0];
        try pids.append(self.allocator, @intCast(pid));
    }

    // Last stage: here, with stdin from the pipe.
    const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
    if (prev_read >= 0) {
        _ = std.c.dup2(prev_read, std.posix.STDIN_FILENO);
        _ = std.c.close(prev_read);
    }
    const last_result = exec(self, stages[stages.len - 1].span.text(src));
    if (saved_stdin >= 0) {
        _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
        _ = std.c.close(saved_stdin);
    }
    const last_status = self.last_exit_code;

    var statuses: std.ArrayList(i32) = .empty;
    defer statuses.deinit(self.allocator);
    for (pids.items) |pid| {
        var status: c_int = 0;
        _ = process_util.waitpidIntr(pid, &status, 0);
        try statuses.append(self.allocator, decodeWaitStatus(status));
    }
    try statuses.append(self.allocator, last_status);

    self.last_exit_code = last_status;
    if (self.option_pipefail) {
        var i = statuses.items.len;
        while (i > 0) {
            i -= 1;
            if (statuses.items[i] != 0) {
                self.last_exit_code = statuses.items[i];
                break;
            }
        }
    }
    self.setPipeStatus(statuses.items);

    last_result catch |err| {
        if (err == error.Exit) return err;
    };
}

/// `compound &`: run it in a child and carry on.
fn runInBackground(self: *Shell, text: []const u8) anyerror!void {
    if (comptime builtin.os.tag == .windows) return run(self, text);
    const pid = std.c.fork();
    if (pid < 0) {
        try IO.eprint("den: fork failed\n", .{});
        self.last_exit_code = 1;
        return;
    }
    if (pid == 0) {
        prepareChild(self);
        _ = std.c.setpgid(0, 0);
        exec(self, text) catch {};
        std.c._exit(statusByte(self.last_exit_code));
    }
    self.job_manager.add(@intCast(pid), text) catch {};
    self.last_exit_code = 0;
}

// ----------------------------------------------------------------------------
// Redirections on compound commands
// ----------------------------------------------------------------------------

/// File descriptors a compound command's redirections replaced, to be put back
/// once the command finishes.
const SavedFds = struct {
    saved: [10]c_int = @splat(-1),

    fn save(self: *SavedFds, fd: u32) void {
        if (fd >= self.saved.len or self.saved[fd] != -1) return;
        const copy = std.c.dup(@intCast(fd));
        // An fd that was closed has nothing to restore; mark it so restore()
        // closes whatever the redirection opened there.
        self.saved[fd] = if (copy >= 0) copy else -2;
    }

    fn restore(self: *SavedFds) void {
        for (&self.saved, 0..) |*copy, fd| {
            if (copy.* >= 0) {
                _ = std.c.dup2(copy.*, @intCast(fd));
                _ = std.c.close(copy.*);
            } else if (copy.* == -2) {
                _ = std.c.close(@intCast(fd));
            }
            copy.* = -1;
        }
    }
};

/// Parse and expand `redirs` with the ordinary command parser (as the
/// redirections of a no-op command), then apply them to this process.
fn applyRedirections(self: *Shell, arena: std.mem.Allocator, redirs: []const u8, saved: *SavedFds) !void {
    if (comptime builtin.os.tag == .windows) return;
    const text = try std.fmt.allocPrint(arena, ": {s}", .{redirs});

    var tokenizer = parser_mod.Tokenizer.init(self.allocator, text);
    const tokens = try tokenizer.tokenize();
    defer tokenizer.deinitTokens(tokens);
    var parser = parser_mod.Parser.init(self.allocator, tokens);
    var chain = try parser.parse();
    defer chain.deinit(self.allocator);
    if (chain.commands.len != 1) return error.InvalidRedirection;

    try self.expandCommandChain(&chain);
    const cmd = &chain.commands[0];

    if (self.option_restricted) {
        for (cmd.redirections) |redir| switch (redir.kind) {
            .output_truncate, .output_append, .output_clobber, .input_output => {
                try IO.eprint("den: output redirection restricted\n", .{});
                return error.RestrictedMode;
            },
            else => {},
        };
    }

    for (cmd.redirections) |redir| saved.save(redir.fd);
    try redirection.applyRedirections(self.allocator, cmd.redirections, &self.environment, .{
        .option_nounset = self.option_nounset,
        .option_noclobber = self.option_noclobber,
        .var_attributes = &self.var_attributes,
        .arrays = &self.arrays,
        .assoc_arrays = &self.assoc_arrays,
    });
}
