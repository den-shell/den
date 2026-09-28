//! Structural parser for shell lists and compound commands.
//!
//! Den runs simple commands through the tokenizer/parser in this directory and
//! compound commands (`for`, `while`, `until`, `if`, `case`) through the
//! ControlFlowExecutor. What those two pieces never had was a shared answer to
//! "where does this command end?". Compound commands were only recognised when
//! they started the input, so `cd dir && for x in a b; do ...; done` reached the
//! simple-command parser, which ran `for`, `do` and `done` as programs.
//!
//! This module answers that question and nothing else. It walks the source
//! once, following the POSIX grammar for lists, and-or lists, pipelines and
//! commands, and records spans into the source text. It never expands or
//! executes anything: the executor hands each span back to the existing
//! machinery, so quoting, expansion and builtins keep behaving exactly as they
//! did before.
//!
//! Reserved words are only recognised where the grammar allows them, which is
//! what keeps `echo done` an echo and `for x in if then; do` a loop over two
//! words.

const std = @import("std");

pub const Error = error{ Incomplete, Syntax, OutOfMemory };

/// A byte range into the parsed source.
pub const Span = struct {
    start: usize,
    end: usize,

    pub const empty: Span = .{ .start = 0, .end = 0 };

    pub fn text(self: Span, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }

    /// The span's text without surrounding whitespace.
    pub fn trimmed(self: Span, src: []const u8) []const u8 {
        return std.mem.trim(u8, src[self.start..self.end], " \t\r\n");
    }
};

pub const Separator = enum { none, semi, amp, newline };

pub const AndOrOp = enum { and_if, or_if };

pub const CommandKind = enum {
    /// A simple command, `[[ ]]` or `(( ))`: the existing parser runs these.
    simple,
    /// `name() compound` or `function name compound`.
    func_def,
    brace_group,
    subshell,
    for_loop,
    /// `for ((init; cond; step))`
    arith_for,
    select_loop,
    while_loop,
    until_loop,
    if_stmt,
    case_stmt,

    /// Whether the simple-command executor would misread this command.
    pub fn isCompound(self: CommandKind) bool {
        return self != .simple;
    }
};

pub const CaseTerminator = enum { normal, fallthrough, continue_testing };

pub const CaseItem = struct {
    patterns: []Span,
    body: Span,
    terminator: CaseTerminator,
};

pub const IfClause = struct {
    condition: Span,
    body: Span,
};

pub const Command = struct {
    kind: CommandKind,
    /// The whole command, including trailing redirections.
    span: Span,
    /// The compound command without its trailing redirections.
    core: Span,
    /// Redirections that follow a compound command (`done > file`).
    redirections: Span = Span.empty,

    /// for/select: the loop variable.
    name: Span = Span.empty,
    /// for/select: the word list, or null when there is no `in` (iterate "$@").
    words: ?[]Span = null,
    /// Loop body, brace-group or subshell contents.
    body: Span = Span.empty,
    /// while/until condition; for arith_for, the `init; cond; step` text.
    condition: Span = Span.empty,
    /// if/elif clauses, in order.
    clauses: []IfClause = &.{},
    else_body: ?Span = null,
    /// case subject word.
    subject: Span = Span.empty,
    case_items: []CaseItem = &.{},
};

pub const Pipeline = struct {
    span: Span,
    bang: bool,
    /// Prefixed with the `time` reserved word (`timed_posix`: `time -p`).
    timed: bool = false,
    timed_posix: bool = false,
    commands: []Command,
    /// `|&` between stages i and i+1 also pipes stderr.
    stderr_pipes: []bool,

    pub fn hasCompound(self: Pipeline) bool {
        for (self.commands) |cmd| {
            if (cmd.kind.isCompound()) return true;
        }
        return false;
    }
};

pub const AndOr = struct {
    span: Span,
    pipelines: []Pipeline,
    ops: []AndOrOp,

    pub fn hasCompound(self: AndOr) bool {
        for (self.pipelines) |p| {
            if (p.hasCompound()) return true;
        }
        return false;
    }
};

pub const ListItem = struct {
    span: Span,
    and_or: AndOr,
    separator: Separator,
};

pub const List = struct {
    items: []ListItem,
};

/// Where a parse stopped, for error messages.
pub const Diagnostic = struct {
    pos: usize = 0,
    /// The offending token, when there was one (`done`, `)`, `;;`, ...).
    token: []const u8 = "",
};

/// Parse `src` as a complete shell list. Allocations go to `arena`; the result
/// only borrows from `src`.
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!List {
    var diag: Diagnostic = .{};
    return parseWithDiagnostic(arena, src, &diag);
}

pub fn parseWithDiagnostic(arena: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!List {
    var p = Parser{ .src = src, .arena = arena, .diag = diag };
    const list = try p.parseList(.{});
    if (p.pos < src.len) return p.fail(p.pos);
    if (p.heredocs.items.len > 0) return error.Incomplete;
    return list;
}

pub const Completeness = enum { complete, incomplete, syntax_error };

/// Whether `src` is a whole command, needs more lines (an open `for`, a
/// trailing `&&`, an unterminated quote or here-document), or can never parse.
pub fn completeness(allocator: std.mem.Allocator, src: []const u8) Completeness {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = parse(arena.allocator(), src) catch |err| return switch (err) {
        error.Incomplete => .incomplete,
        error.Syntax => .syntax_error,
        // Out of memory says nothing about the input; let it through and the
        // executor will report the real problem.
        error.OutOfMemory => .complete,
    };
    return .complete;
}

/// Join lines starting at `lines[start]` until they form a complete command.
/// Returns the joined text (owned by the caller when `owned` is set) and the
/// index of the last line consumed. A command still incomplete at the end of
/// input is returned whole, so the executor can report the syntax error.
pub fn collectCommand(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start: usize,
) !struct { text: []const u8, end: usize, owned: bool } {
    if (completeness(allocator, lines[start]) != .incomplete) {
        return .{ .text = lines[start], .end = start, .owned = false };
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, lines[start]);
    var i = start;
    while (i + 1 < lines.len) {
        i += 1;
        try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, lines[i]);
        if (completeness(allocator, buf.items) != .incomplete) break;
    }
    return .{ .text = try buf.toOwnedSlice(allocator), .end = i, .owned = true };
}

/// Reserved words that are only valid inside a compound command. Seen at the
/// start of a command they are a syntax error, never a program to look up.
pub fn isReservedWord(word: []const u8) bool {
    const words = [_][]const u8{
        "if",    "then",  "else", "elif",   "fi",       "do", "done", "case", "esac",
        "while", "until", "for",  "select", "function", "in", "{",    "}",    "!",
        "[[",    "]]",
    };
    for (words) |w| {
        if (std.mem.eql(u8, word, w)) return true;
    }
    return false;
}

const Terms = struct {
    then: bool = false,
    do_: bool = false,
    done: bool = false,
    /// elif / else / fi
    if_tail: bool = false,
    fi: bool = false,
    esac: bool = false,
    /// `;;`, `;&`, `;;&` end a case item.
    case_end: bool = false,
    rbrace: bool = false,
    rparen: bool = false,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    diag: *Diagnostic,
    heredocs: std.ArrayList(Heredoc) = .empty,

    const Heredoc = struct {
        delimiter: []const u8,
        strip_tabs: bool,
    };

    fn fail(self: *Parser, at: usize) Error {
        self.diag.pos = at;
        var end = at;
        while (end < self.src.len and !isBlank(self.src[end]) and self.src[end] != '\n') : (end += 1) {
            if (end > at and isOperatorChar(self.src[end])) break;
        }
        if (end == at and at < self.src.len) end = at + 1;
        self.diag.token = self.src[at..end];
        return error.Syntax;
    }

    fn peek(self: *const Parser, offset: usize) u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else 0;
    }

    fn atEnd(self: *const Parser) bool {
        return self.pos >= self.src.len;
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], prefix);
    }

    // ------------------------------------------------------------------
    // Whitespace, comments, newlines and here-documents
    // ------------------------------------------------------------------

    /// Skip blanks, line continuations and a comment (up to, not including,
    /// the newline). Called only where a word may start, which is exactly
    /// where `#` begins a comment.
    fn skipBlanks(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isBlank(c)) {
                self.pos += 1;
            } else if (c == '\\' and self.peek(1) == '\n') {
                self.pos += 2;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    /// Consume one newline, then the bodies of any here-documents whose
    /// operators appeared on the line it ends.
    fn newline(self: *Parser) Error!void {
        std.debug.assert(self.src[self.pos] == '\n');
        self.pos += 1;
        if (self.heredocs.items.len == 0) return;
        for (self.heredocs.items) |hd| {
            while (true) {
                if (self.pos >= self.src.len) return error.Incomplete;
                const line_end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
                var line = self.src[self.pos..line_end];
                if (hd.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
                const is_end = std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), hd.delimiter);
                self.pos = if (line_end < self.src.len) line_end + 1 else line_end;
                if (is_end) break;
                if (line_end >= self.src.len) return error.Incomplete;
            }
        }
        self.heredocs.clearRetainingCapacity();
    }

    fn skipLinebreaks(self: *Parser) Error!void {
        while (true) {
            self.skipBlanks();
            if (self.pos < self.src.len and self.src[self.pos] == '\n') {
                try self.newline();
            } else break;
        }
    }

    // ------------------------------------------------------------------
    // Reserved words
    // ------------------------------------------------------------------

    /// The reserved word at the cursor, if the next word is exactly one.
    fn peekReserved(self: *const Parser) ?[]const u8 {
        const rest = self.src[self.pos..];
        const candidates = [_][]const u8{
            "if",    "then",  "else", "elif",   "fi",       "do", "done", "case", "esac",
            "while", "until", "for",  "select", "function", "{",  "}",    "!",
        };
        for (candidates) |w| {
            if (rest.len >= w.len and std.mem.eql(u8, rest[0..w.len], w)) {
                if (rest.len == w.len or isWordDelimiter(rest[w.len])) return w;
            }
        }
        return null;
    }

    fn peekWordIs(self: *const Parser, word: []const u8) bool {
        const rest = self.src[self.pos..];
        return rest.len >= word.len and std.mem.eql(u8, rest[0..word.len], word) and
            (rest.len == word.len or isWordDelimiter(rest[word.len]));
    }

    fn atTerminator(self: *const Parser, terms: Terms) bool {
        if (self.pos >= self.src.len) return false;
        const c = self.src[self.pos];
        if (terms.rparen and c == ')') return true;
        if (terms.case_end and c == ';' and (self.peek(1) == ';' or self.peek(1) == '&')) return true;
        const w = self.peekReserved() orelse return false;
        if (terms.then and std.mem.eql(u8, w, "then")) return true;
        if (terms.do_ and std.mem.eql(u8, w, "do")) return true;
        if (terms.done and std.mem.eql(u8, w, "done")) return true;
        if (terms.if_tail and (std.mem.eql(u8, w, "elif") or std.mem.eql(u8, w, "else") or std.mem.eql(u8, w, "fi"))) return true;
        if (terms.fi and std.mem.eql(u8, w, "fi")) return true;
        if (terms.esac and std.mem.eql(u8, w, "esac")) return true;
        if (terms.rbrace and std.mem.eql(u8, w, "}")) return true;
        return false;
    }

    /// Consume `word`, which must be the next reserved word.
    fn expectReserved(self: *Parser, word: []const u8) Error!void {
        try self.skipLinebreaks();
        if (self.atEnd()) return error.Incomplete;
        if (!self.peekWordIs(word)) return self.fail(self.pos);
        self.pos += word.len;
    }

    // ------------------------------------------------------------------
    // Lists
    // ------------------------------------------------------------------

    fn parseList(self: *Parser, terms: Terms) Error!List {
        var items: std.ArrayList(ListItem) = .empty;
        while (true) {
            try self.skipLinebreaks();
            if (self.atEnd() or self.atTerminator(terms)) break;

            const ao = try self.parseAndOr(terms);
            self.skipBlanks();
            var sep: Separator = .none;
            if (!self.atEnd()) {
                const c = self.src[self.pos];
                if (c == ';' and self.peek(1) != ';' and self.peek(1) != '&') {
                    sep = .semi;
                    self.pos += 1;
                } else if (c == '&' and self.peek(1) != '&' and self.peek(1) != '>') {
                    sep = .amp;
                    self.pos += 1;
                } else if (c == '\n') {
                    sep = .newline;
                    try self.newline();
                }
            }
            try items.append(self.arena, .{ .span = ao.span, .and_or = ao, .separator = sep });
            if (sep == .none) {
                if (self.atEnd() or self.atTerminator(terms)) break;
                return self.fail(self.pos);
            }
        }
        return .{ .items = items.items };
    }

    fn parseAndOr(self: *Parser, terms: Terms) Error!AndOr {
        var pipelines: std.ArrayList(Pipeline) = .empty;
        var ops: std.ArrayList(AndOrOp) = .empty;
        try pipelines.append(self.arena, try self.parsePipeline(terms));
        while (true) {
            self.skipBlanks();
            const op: AndOrOp = if (self.startsWith("&&"))
                .and_if
            else if (self.startsWith("||"))
                .or_if
            else
                break;
            self.pos += 2;
            try self.skipLinebreaks();
            if (self.atEnd()) return error.Incomplete;
            try ops.append(self.arena, op);
            try pipelines.append(self.arena, try self.parsePipeline(terms));
        }
        const first = pipelines.items[0].span.start;
        const last = pipelines.items[pipelines.items.len - 1].span.end;
        return .{
            .span = .{ .start = first, .end = last },
            .pipelines = pipelines.items,
            .ops = ops.items,
        };
    }

    fn parsePipeline(self: *Parser, terms: Terms) Error!Pipeline {
        self.skipBlanks();
        if (self.atEnd()) return error.Incomplete;
        const start = self.pos;
        var bang = false;
        var timed = false;
        var timed_posix = false;
        if (self.peekWordIs("time")) {
            // `time` times the whole pipeline; alone it is an ordinary word.
            const save = self.pos;
            self.pos += 4;
            self.skipBlanks();
            if (self.peekWordIs("-p")) {
                timed_posix = true;
                self.pos += 2;
                self.skipBlanks();
            }
            if (self.atEnd() or self.src[self.pos] == ';' or self.src[self.pos] == '&' or
                self.src[self.pos] == '|' or self.src[self.pos] == '\n')
            {
                self.pos = save;
                timed_posix = false;
            } else {
                timed = true;
            }
        }
        if (self.peekWordIs("!")) {
            bang = true;
            self.pos += 1;
            self.skipBlanks();
        }
        var commands: std.ArrayList(Command) = .empty;
        var stderr_pipes: std.ArrayList(bool) = .empty;
        while (true) {
            try commands.append(self.arena, try self.parseCommand(terms));
            self.skipBlanks();
            if (self.peek(0) == '|' and self.peek(1) != '|') {
                self.pos += 1;
                var with_stderr = false;
                if (self.peek(0) == '&') {
                    with_stderr = true;
                    self.pos += 1;
                }
                try stderr_pipes.append(self.arena, with_stderr);
                try self.skipLinebreaks();
                if (self.atEnd()) return error.Incomplete;
                continue;
            }
            break;
        }
        const end = commands.items[commands.items.len - 1].span.end;
        return .{
            .span = .{ .start = start, .end = end },
            .bang = bang,
            .timed = timed,
            .timed_posix = timed_posix,
            .commands = commands.items,
            .stderr_pipes = stderr_pipes.items,
        };
    }

    // ------------------------------------------------------------------
    // Commands
    // ------------------------------------------------------------------

    fn parseCommand(self: *Parser, terms: Terms) Error!Command {
        self.skipBlanks();
        if (self.atEnd()) return error.Incomplete;
        const start = self.pos;
        const c = self.src[self.pos];

        if (c == '(') {
            if (self.peek(1) == '(') {
                // Arithmetic command `(( expr ))`: opaque to us.
                try self.skipParenGroup();
                return self.finishSimple(start, terms);
            }
            self.pos += 1;
            const body_start = self.pos;
            _ = try self.parseList(.{ .rparen = true });
            if (self.atEnd()) return error.Incomplete;
            if (self.src[self.pos] != ')') return self.fail(self.pos);
            const body = Span{ .start = body_start, .end = self.pos };
            self.pos += 1;
            var cmd = try self.finishCompound(.subshell, start);
            cmd.body = body;
            return cmd;
        }

        if (c == ')' or c == ';' or c == '|' or (c == '&' and self.peek(1) != '>')) {
            return self.fail(self.pos);
        }

        if (self.peekReserved()) |word| {
            if (std.mem.eql(u8, word, "{")) return self.parseBraceGroup(start);
            if (std.mem.eql(u8, word, "if")) return self.parseIf(start);
            if (std.mem.eql(u8, word, "for")) return self.parseFor(start, .for_loop);
            if (std.mem.eql(u8, word, "select")) return self.parseFor(start, .select_loop);
            if (std.mem.eql(u8, word, "while")) return self.parseWhile(start, .while_loop);
            if (std.mem.eql(u8, word, "until")) return self.parseWhile(start, .until_loop);
            if (std.mem.eql(u8, word, "case")) return self.parseCase(start);
            if (std.mem.eql(u8, word, "function")) return self.parseFunctionKeyword(start, terms);
            // then/else/elif/fi/do/done/esac/}/! where a command should be.
            return self.fail(self.pos);
        }

        return self.parseSimple(start, terms);
    }

    fn parseBraceGroup(self: *Parser, start: usize) Error!Command {
        self.pos += 1; // {
        const body_start = self.pos;
        _ = try self.parseList(.{ .rbrace = true });
        const body = Span{ .start = body_start, .end = self.pos };
        try self.expectReserved("}");
        var cmd = try self.finishCompound(.brace_group, start);
        cmd.body = body;
        return cmd;
    }

    fn parseIf(self: *Parser, start: usize) Error!Command {
        var clauses: std.ArrayList(IfClause) = .empty;
        var else_body: ?Span = null;
        self.pos += 2; // if
        while (true) {
            const cond_start = self.pos;
            _ = try self.parseList(.{ .then = true });
            const cond = Span{ .start = cond_start, .end = self.pos };
            try self.expectReserved("then");
            const body_start = self.pos;
            _ = try self.parseList(.{ .if_tail = true });
            try clauses.append(self.arena, .{ .condition = cond, .body = .{ .start = body_start, .end = self.pos } });
            if (self.atEnd()) return error.Incomplete;
            if (self.peekWordIs("elif")) {
                self.pos += 4;
                continue;
            }
            if (self.peekWordIs("else")) {
                self.pos += 4;
                const else_start = self.pos;
                _ = try self.parseList(.{ .fi = true });
                else_body = .{ .start = else_start, .end = self.pos };
            }
            try self.expectReserved("fi");
            break;
        }
        var cmd = try self.finishCompound(.if_stmt, start);
        cmd.clauses = clauses.items;
        cmd.else_body = else_body;
        return cmd;
    }

    fn parseWhile(self: *Parser, start: usize, kind: CommandKind) Error!Command {
        self.pos += 5; // while / until
        const cond_start = self.pos;
        _ = try self.parseList(.{ .do_ = true });
        const cond = Span{ .start = cond_start, .end = self.pos };
        const body = try self.parseDoGroup();
        var cmd = try self.finishCompound(kind, start);
        cmd.condition = cond;
        cmd.body = body;
        return cmd;
    }

    /// `do list done`, returning the list's span.
    fn parseDoGroup(self: *Parser) Error!Span {
        try self.expectReserved("do");
        const body_start = self.pos;
        _ = try self.parseList(.{ .done = true });
        const body = Span{ .start = body_start, .end = self.pos };
        try self.expectReserved("done");
        return body;
    }

    fn parseFor(self: *Parser, start: usize, kind: CommandKind) Error!Command {
        self.pos += if (kind == .select_loop) 6 else 3;
        self.skipBlanks();
        if (self.atEnd()) return error.Incomplete;

        if (kind == .for_loop and self.startsWith("((")) {
            const arith_start = self.pos;
            try self.skipParenGroup();
            if (self.pos - arith_start < 4 or !std.mem.endsWith(u8, self.src[arith_start..self.pos], "))")) {
                return self.fail(arith_start);
            }
            const header = Span{ .start = arith_start + 2, .end = self.pos - 2 };
            self.skipBlanks();
            if (self.peek(0) == ';') self.pos += 1;
            const body = try self.parseDoGroup();
            var cmd = try self.finishCompound(.arith_for, start);
            cmd.condition = header;
            cmd.body = body;
            return cmd;
        }

        const name_start = self.pos;
        const name = try self.scanWord();
        if (!isIdentifier(name.text(self.src))) return self.fail(name_start);

        try self.skipLinebreaks();
        var words: ?[]Span = null;
        if (self.peekWordIs("in")) {
            self.pos += 2;
            var list: std.ArrayList(Span) = .empty;
            while (true) {
                self.skipBlanks();
                if (self.atEnd()) return error.Incomplete;
                const c = self.src[self.pos];
                if (c == ';') {
                    self.pos += 1;
                    break;
                }
                if (c == '\n') {
                    try self.newline();
                    break;
                }
                if (isOperatorChar(c)) return self.fail(self.pos);
                try list.append(self.arena, try self.scanWord());
            }
            words = list.items;
        } else if (self.peek(0) == ';') {
            self.pos += 1;
        }

        const body = try self.parseDoGroup();
        var cmd = try self.finishCompound(kind, start);
        cmd.name = name;
        cmd.words = words;
        cmd.body = body;
        return cmd;
    }

    fn parseCase(self: *Parser, start: usize) Error!Command {
        self.pos += 4; // case
        self.skipBlanks();
        if (self.atEnd()) return error.Incomplete;
        const subject = try self.scanWord();
        try self.skipLinebreaks();
        if (self.atEnd()) return error.Incomplete;
        if (!self.peekWordIs("in")) return self.fail(self.pos);
        self.pos += 2;

        var items: std.ArrayList(CaseItem) = .empty;
        while (true) {
            try self.skipLinebreaks();
            if (self.atEnd()) return error.Incomplete;
            if (self.peekWordIs("esac")) {
                self.pos += 4;
                break;
            }
            if (self.src[self.pos] == '(') {
                self.pos += 1;
            }
            var patterns: std.ArrayList(Span) = .empty;
            while (true) {
                self.skipBlanks();
                if (self.atEnd()) return error.Incomplete;
                const c = self.src[self.pos];
                if (c == ')' or c == '|' or c == '\n' or c == ';') return self.fail(self.pos);
                try patterns.append(self.arena, try self.scanWord());
                self.skipBlanks();
                if (self.atEnd()) return error.Incomplete;
                if (self.src[self.pos] == '|') {
                    self.pos += 1;
                    continue;
                }
                if (self.src[self.pos] == ')') {
                    self.pos += 1;
                    break;
                }
                return self.fail(self.pos);
            }

            const body_start = self.pos;
            _ = try self.parseList(.{ .esac = true, .case_end = true });
            const body = Span{ .start = body_start, .end = self.pos };
            var terminator: CaseTerminator = .normal;
            if (self.startsWith(";;&")) {
                self.pos += 3;
                terminator = .continue_testing;
            } else if (self.startsWith(";;")) {
                self.pos += 2;
            } else if (self.startsWith(";&")) {
                self.pos += 2;
                terminator = .fallthrough;
            } else if (self.atEnd()) {
                return error.Incomplete;
            }
            try items.append(self.arena, .{ .patterns = patterns.items, .body = body, .terminator = terminator });
        }

        var cmd = try self.finishCompound(.case_stmt, start);
        cmd.subject = subject;
        cmd.case_items = items.items;
        return cmd;
    }

    fn parseFunctionKeyword(self: *Parser, start: usize, terms: Terms) Error!Command {
        self.pos += 8; // function
        self.skipBlanks();
        if (self.atEnd()) return error.Incomplete;
        _ = try self.scanWord();
        self.skipBlanks();
        if (self.startsWith("()")) self.pos += 2;
        return self.finishFunction(start, terms);
    }

    /// After `name()` or `function name`: the body is the next command.
    fn finishFunction(self: *Parser, start: usize, terms: Terms) Error!Command {
        try self.skipLinebreaks();
        if (self.atEnd()) return error.Incomplete;
        const body = try self.parseCommand(terms);
        return .{
            .kind = .func_def,
            .span = .{ .start = start, .end = body.span.end },
            .core = .{ .start = start, .end = body.span.end },
            .body = body.span,
        };
    }

    /// Record the end of a compound command and parse redirections after it.
    fn finishCompound(self: *Parser, kind: CommandKind, start: usize) Error!Command {
        const core_end = self.pos;
        var end = core_end;
        while (true) {
            self.skipBlanks();
            if (!self.atRedirection()) break;
            try self.scanRedirection();
            end = self.pos;
        }
        return .{
            .kind = kind,
            .span = .{ .start = start, .end = end },
            .core = .{ .start = start, .end = core_end },
            .redirections = .{ .start = core_end, .end = end },
        };
    }

    fn parseSimple(self: *Parser, start: usize, terms: Terms) Error!Command {
        // `[[ ... ]]` may contain &&, ||, <, > and parentheses of its own.
        if (self.peekWordIs("[[")) {
            self.pos += 2;
            while (true) {
                self.skipBlanks();
                if (self.atEnd()) return error.Incomplete;
                if (self.peekWordIs("]]")) {
                    self.pos += 2;
                    break;
                }
                const c = self.src[self.pos];
                if (c == '\n') {
                    try self.newline();
                } else if (isOperatorChar(c)) {
                    self.pos += 1;
                } else {
                    _ = try self.scanWord();
                }
            }
            return self.finishSimple(start, terms);
        }

        // First word, then the function-definition check.
        if (self.atRedirection()) {
            try self.scanRedirection();
        } else {
            const first = try self.scanWord();
            const first_text = first.text(self.src);
            if (first_text.len > 2 and std.mem.endsWith(u8, first_text, "()") and
                isValidName(first_text[0 .. first_text.len - 2]))
            {
                return self.finishFunction(start, terms);
            }
            const save = self.pos;
            self.skipBlanks();
            if (self.startsWith("()") and isValidName(first_text)) {
                self.pos += 2;
                return self.finishFunction(start, terms);
            }
            self.pos = save;
        }
        return self.finishSimple(start, terms);
    }

    /// Consume the rest of a simple command's words and redirections.
    fn finishSimple(self: *Parser, start: usize, terms: Terms) Error!Command {
        var end = self.pos;
        while (true) {
            self.skipBlanks();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '\n' or c == ';' or c == '|' or c == ')') break;
            if (c == '&' and self.peek(1) != '>') break;
            if (self.atRedirection()) {
                try self.scanRedirection();
                end = self.pos;
                continue;
            }
            // zsh lets `}` close a brace group without a separator before it
            // (`{ echo hi }`), and Den's own blocks (`try { ... }`) rely on it.
            if (terms.rbrace and self.peekWordIs("}")) break;
            // A lone `{` argument opens one of Den's blocks (`try {`,
            // `match $x {`); keep its separators out of our list.
            if (self.peekWordIs("{")) {
                self.pos += 1;
                _ = try self.parseList(.{ .rbrace = true });
                try self.expectReserved("}");
                end = self.pos;
                continue;
            }
            _ = try self.scanWord();
            end = self.pos;
        }
        return .{
            .kind = .simple,
            .span = .{ .start = start, .end = end },
            .core = .{ .start = start, .end = end },
        };
    }

    // ------------------------------------------------------------------
    // Redirections
    // ------------------------------------------------------------------

    fn atRedirection(self: *const Parser) bool {
        var i = self.pos;
        while (i < self.src.len and std.ascii.isDigit(self.src[i])) i += 1;
        if (i >= self.src.len) return false;
        const c = self.src[i];
        const next: u8 = if (i + 1 < self.src.len) self.src[i + 1] else 0;
        if (c == '<' or c == '>') return next != '('; // <( and >( are words
        if (c == '&' and next == '>' and i == self.pos) return true;
        return false;
    }

    fn scanRedirection(self: *Parser) Error!void {
        while (std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        var heredoc = false;
        var strip_tabs = false;
        if (self.startsWith("<<<")) {
            self.pos += 3;
        } else if (self.startsWith("<<-")) {
            self.pos += 3;
            heredoc = true;
            strip_tabs = true;
        } else if (self.startsWith("<<")) {
            self.pos += 2;
            heredoc = true;
        } else if (self.startsWith("&>>")) {
            self.pos += 3;
        } else if (self.startsWith("&>") or self.startsWith(">>") or self.startsWith(">|") or
            self.startsWith(">&") or self.startsWith("<&") or self.startsWith("<>"))
        {
            self.pos += 2;
        } else {
            self.pos += 1;
        }
        self.skipBlanks();
        if (self.atEnd()) return error.Incomplete;
        const c = self.src[self.pos];
        if (c == '\n') return error.Incomplete;
        if (isOperatorChar(c) and !(c == '-' or c == '<' or c == '>')) return self.fail(self.pos);
        const word = try self.scanWord();
        if (heredoc) {
            try self.heredocs.append(self.arena, .{
                .delimiter = try unquote(self.arena, word.text(self.src)),
                .strip_tabs = strip_tabs,
            });
        }
    }

    // ------------------------------------------------------------------
    // Words
    // ------------------------------------------------------------------

    /// Scan one word, including quotes, expansions and substitutions.
    fn scanWord(self: *Parser) Error!Span {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n', ';', '&', '|', ')' => break,
                '<', '>' => {
                    // Process substitution <( ... ) / >( ... ) is a word.
                    if (self.peek(1) == '(') {
                        self.pos += 1;
                        try self.skipCommandGroup();
                        continue;
                    }
                    break;
                },
                '(' => {
                    // `name()` ends at its parentheses: in `f(){ ...; }` the
                    // brace starts the body, it is not part of the name.
                    if (self.peek(1) == ')') {
                        self.pos += 2;
                        break;
                    }
                    try self.skipParenGroup();
                },
                '\\' => try self.skipEscape(),
                '\'' => try self.skipSingleQuoted(),
                '"' => try self.skipDoubleQuoted(),
                '`' => try self.skipBackquoted(),
                '$' => try self.skipDollar(),
                else => self.pos += 1,
            }
        }
        if (self.pos == start) return self.fail(self.pos);
        return .{ .start = start, .end = self.pos };
    }

    fn skipEscape(self: *Parser) Error!void {
        if (self.pos + 1 >= self.src.len) return error.Incomplete;
        self.pos += 2;
    }

    fn skipSingleQuoted(self: *Parser) Error!void {
        const close = std.mem.indexOfScalarPos(u8, self.src, self.pos + 1, '\'') orelse return error.Incomplete;
        self.pos = close + 1;
    }

    fn skipDoubleQuoted(self: *Parser) Error!void {
        self.pos += 1;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '"' => {
                    self.pos += 1;
                    return;
                },
                '\\' => try self.skipEscape(),
                '`' => try self.skipBackquoted(),
                '$' => try self.skipDollar(),
                else => self.pos += 1,
            }
        }
        return error.Incomplete;
    }

    fn skipBackquoted(self: *Parser) Error!void {
        self.pos += 1;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '`' => {
                    self.pos += 1;
                    return;
                },
                '\\' => try self.skipEscape(),
                else => self.pos += 1,
            }
        }
        return error.Incomplete;
    }

    /// `$(...)`, `$((...))`, `${...}`, `$'...'` or a plain `$`.
    fn skipDollar(self: *Parser) Error!void {
        const next = self.peek(1);
        if (next == '(') {
            self.pos += 1;
            if (self.peek(1) == '(') return self.skipParenGroup();
            return self.skipCommandGroup();
        }
        if (next == '{') {
            self.pos += 2;
            var depth: usize = 1;
            while (self.pos < self.src.len) {
                switch (self.src[self.pos]) {
                    '{' => {
                        depth += 1;
                        self.pos += 1;
                    },
                    '}' => {
                        depth -= 1;
                        self.pos += 1;
                        if (depth == 0) return;
                    },
                    '\\' => try self.skipEscape(),
                    '\'' => try self.skipSingleQuoted(),
                    '"' => try self.skipDoubleQuoted(),
                    '`' => try self.skipBackquoted(),
                    '$' => try self.skipDollar(),
                    else => self.pos += 1,
                }
            }
            return error.Incomplete;
        }
        if (next == '\'') {
            self.pos += 2;
            while (self.pos < self.src.len) {
                switch (self.src[self.pos]) {
                    '\'' => {
                        self.pos += 1;
                        return;
                    },
                    '\\' => try self.skipEscape(),
                    else => self.pos += 1,
                }
            }
            return error.Incomplete;
        }
        self.pos += 1;
    }

    /// `( list )` as part of a word: `$( ... )`, `<( ... )`. The cursor is on
    /// the `(`. The contents are a full list, so `case` patterns and quotes
    /// inside cannot end it early.
    fn skipCommandGroup(self: *Parser) Error!void {
        self.pos += 1;
        // Here-documents inside belong to the substitution's own lines.
        const saved = self.heredocs;
        self.heredocs = .empty;
        defer self.heredocs = saved;
        _ = try self.parseList(.{ .rparen = true });
        if (self.atEnd()) return error.Incomplete;
        if (self.src[self.pos] != ')') return self.fail(self.pos);
        self.pos += 1;
    }

    /// Balanced parentheses taken literally: `$(( ))`, `(( ))`, `arr=(a b)`,
    /// zsh glob qualifiers `*(.)`, extglob `@(a|b)`, `name()`.
    fn skipParenGroup(self: *Parser) Error!void {
        var depth: usize = 0;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '(' => {
                    depth += 1;
                    self.pos += 1;
                },
                ')' => {
                    depth -= 1;
                    self.pos += 1;
                    if (depth == 0) return;
                },
                '\\' => try self.skipEscape(),
                '\'' => try self.skipSingleQuoted(),
                '"' => try self.skipDoubleQuoted(),
                '`' => try self.skipBackquoted(),
                '$' => {
                    if (self.peek(1) == '(' or self.peek(1) == '{' or self.peek(1) == '\'') {
                        try self.skipDollar();
                    } else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
        return error.Incomplete;
    }
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn isOperatorChar(c: u8) bool {
    return switch (c) {
        ';', '&', '|', '<', '>', '(', ')', '\n' => true,
        else => false,
    };
}

fn isWordDelimiter(c: u8) bool {
    return isBlank(c) or isOperatorChar(c);
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.' and c != ':') return false;
    }
    return true;
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// A here-document delimiter with its quoting removed.
fn unquote(allocator: std.mem.Allocator, word: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        const c = word[i];
        if (c == '\'' or c == '"') continue;
        if (c == '\\' and i + 1 < word.len) {
            i += 1;
            try out.append(allocator, word[i]);
            continue;
        }
        try out.append(allocator, c);
    }
    return out.items;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn expectCompleteness(expected: Completeness, src: []const u8) !void {
    try testing.expectEqual(expected, completeness(testing.allocator, src));
}

test "a compound command after && is one and-or list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "cd /tmp && for u in A B; do printf '%s ' \"$(echo $u | tr A-Z a-z)\"; echo X_$u | tail -1; done";
    const list = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    const ao = list.items[0].and_or;
    try testing.expectEqual(@as(usize, 2), ao.pipelines.len);
    try testing.expectEqual(AndOrOp.and_if, ao.ops[0]);
    const loop = ao.pipelines[1].commands[0];
    try testing.expectEqual(CommandKind.for_loop, loop.kind);
    try testing.expectEqualStrings("u", loop.name.text(src));
    try testing.expectEqual(@as(usize, 2), loop.words.?.len);
    try testing.expectEqualStrings(
        "printf '%s ' \"$(echo $u | tr A-Z a-z)\"; echo X_$u | tail -1;",
        loop.body.trimmed(src),
    );
}

test "separators split the top-level list but not compound bodies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "echo a; for i in 1 2; do echo $i; done\necho b";
    const list = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("for i in 1 2; do echo $i; done", list.items[1].span.text(src));
    try testing.expectEqual(Separator.newline, list.items[1].separator);
}

test "reserved words only count at the start of a command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "echo done fi; for x in if then do; do echo $x; done";
    const list = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(CommandKind.simple, list.items[0].and_or.pipelines[0].commands[0].kind);
    const loop = list.items[1].and_or.pipelines[0].commands[0];
    try testing.expectEqual(@as(usize, 3), loop.words.?.len);
}

test "for without in iterates the positional parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), "for x; do echo $x; done");
    const loop = list.items[0].and_or.pipelines[0].commands[0];
    try testing.expectEqual(CommandKind.for_loop, loop.kind);
    try testing.expect(loop.words == null);

    const list2 = try parse(arena.allocator(), "for x\ndo\necho $x\ndone");
    try testing.expect(list2.items[0].and_or.pipelines[0].commands[0].words == null);
}

test "if/elif/else clauses and case items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "if a; then b; elif c; then d; else e; fi";
    const cmd = (try parse(arena.allocator(), src)).items[0].and_or.pipelines[0].commands[0];
    try testing.expectEqual(CommandKind.if_stmt, cmd.kind);
    try testing.expectEqual(@as(usize, 2), cmd.clauses.len);
    try testing.expectEqualStrings("c;", cmd.clauses[1].condition.trimmed(src));
    try testing.expectEqualStrings("e;", cmd.else_body.?.trimmed(src));

    const csrc = "case $f in *.txt|*.md) echo doc;; (*) echo other;& x) ;;& esac";
    const c = (try parse(arena.allocator(), csrc)).items[0].and_or.pipelines[0].commands[0];
    try testing.expectEqual(CommandKind.case_stmt, c.kind);
    try testing.expectEqual(@as(usize, 3), c.case_items.len);
    try testing.expectEqual(@as(usize, 2), c.case_items[0].patterns.len);
    try testing.expectEqual(CaseTerminator.fallthrough, c.case_items[1].terminator);
    try testing.expectEqual(CaseTerminator.continue_testing, c.case_items[2].terminator);
}

test "redirections and pipes after a compound command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "for i in 1 2; do echo $i; done 2>&1 >out.txt | sort -r";
    const pl = (try parse(arena.allocator(), src)).items[0].and_or.pipelines[0];
    try testing.expectEqual(@as(usize, 2), pl.commands.len);
    try testing.expectEqualStrings("2>&1 >out.txt", pl.commands[0].redirections.trimmed(src));
    try testing.expectEqualStrings("for i in 1 2; do echo $i; done", pl.commands[0].core.text(src));
}

test "time prefixes a pipeline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "time -p for i in 1; do :; done | cat";
    const pl = (try parse(arena.allocator(), src)).items[0].and_or.pipelines[0];
    try testing.expect(pl.timed and pl.timed_posix);
    try testing.expectEqual(CommandKind.for_loop, pl.commands[0].kind);
    try testing.expectEqual(@as(usize, 2), pl.commands.len);
    // Alone, `time` is just a word.
    const alone = (try parse(arena.allocator(), "time")).items[0].and_or.pipelines[0];
    try testing.expect(!alone.timed);
}

test "groups, subshells and nesting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "{ echo a; ( cd /; for i in 1; do while false; do :; done; done ); } && echo ok";
    const ao = (try parse(arena.allocator(), src)).items[0].and_or;
    try testing.expectEqual(CommandKind.brace_group, ao.pipelines[0].commands[0].kind);
    try testing.expectEqual(@as(usize, 2), ao.pipelines.len);
}

test "substitutions, arithmetic and [[ ]] are opaque" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const srcs = [_][]const u8{
        "x=$(for i in 1 2; do echo $i; done)",
        "echo $(case a in a) echo yes;; esac)",
        "[[ -n $x && ( $y || -z $z ) ]] && echo ok",
        "(( i < 3 && j > 1 )) || echo no",
        "arr=(a b c); echo ${arr[@]}",
        "echo \"; done ;\" '; fi' \\; done",
        "ls *(.) | wc -l",
    };
    for (srcs) |src| {
        _ = try parse(arena.allocator(), src);
    }
}

test "function definitions are single commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "f() { for a; do echo \"f:$a\"; done; }; f one two";
    const list = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(CommandKind.func_def, list.items[0].and_or.pipelines[0].commands[0].kind);
    const list2 = try parse(arena.allocator(), "function g { echo; }");
    try testing.expectEqual(CommandKind.func_def, list2.items[0].and_or.pipelines[0].commands[0].kind);
    const list3 = try parse(arena.allocator(), "g(){ local x=5; echo $x; }; g");
    try testing.expectEqual(@as(usize, 2), list3.items.len);
    try testing.expectEqual(CommandKind.func_def, list3.items[0].and_or.pipelines[0].commands[0].kind);
}

test "Den blocks keep their separators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), "try { echo a; false } catch e { echo caught }");
    try testing.expectEqual(@as(usize, 1), list.items.len);
}

test "completeness drives continuation lines" {
    try expectCompleteness(.incomplete, "for i in 1 2; do");
    try expectCompleteness(.incomplete, "for i in 1 2; do echo $i;");
    try expectCompleteness(.incomplete, "cd /tmp &&");
    try expectCompleteness(.incomplete, "echo a |");
    try expectCompleteness(.incomplete, "if true; then echo");
    try expectCompleteness(.incomplete, "case x in");
    try expectCompleteness(.incomplete, "echo 'open");
    try expectCompleteness(.incomplete, "{ echo a;");
    try expectCompleteness(.incomplete, "cat <<EOF\nhello");
    try expectCompleteness(.complete, "cat <<EOF\nhello\nEOF");
    try expectCompleteness(.complete, "for i in 1 2; do echo $i; done");
    try expectCompleteness(.complete, "echo done");
    try expectCompleteness(.syntax_error, "done");
    try expectCompleteness(.syntax_error, "echo a; fi");
    try expectCompleteness(.syntax_error, "for i in 1; do echo; done done");
}

test "collectCommand joins the lines of a multi-line command" {
    const lines = [_][]const u8{ "x=1", "for i in 1 2", "do", "  echo $i", "done", "echo end" };
    const first = try collectCommand(testing.allocator, &lines, 0);
    try testing.expect(!first.owned);
    try testing.expectEqual(@as(usize, 0), first.end);
    const loop = try collectCommand(testing.allocator, &lines, 1);
    defer if (loop.owned) testing.allocator.free(loop.text);
    try testing.expectEqual(@as(usize, 4), loop.end);
    try testing.expectEqualStrings("for i in 1 2\ndo\n  echo $i\ndone", loop.text);
}
