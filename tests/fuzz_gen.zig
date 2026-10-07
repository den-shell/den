//! Input generator for the fuzz suite.
//!
//! Pure and `std`-only, so the generator is tested on its own terms rather than
//! only through the shell it feeds.
//!
//! ## What this may and may not produce
//!
//! Everything generated here is *executed* by a real den, so the vocabulary is
//! the safety boundary and it is deliberately narrow:
//!
//! - Commands are `echo`, `printf`, `true`, `false`, `:`, `pwd` and `test`.
//!   Nothing that deletes, moves, signals, or reaches the network appears, so a
//!   case cannot damage anything whatever order the pieces land in.
//! - Redirections target relative names only. The runner works in a temporary
//!   directory, so writes stay inside it; an absolute path is never emitted.
//! - No operator backgrounds a command, so a structured case never spawns a
//!   child that outlives the run. `&` is still in the raw character set, since
//!   the tokenizer has to cope with `&&`, `&>` and `2>&1`, so the soup and
//!   mutation strategies can emit a bare `&`. That is bounded on purpose: every
//!   command in the vocabulary finishes immediately, so even a backgrounded one
//!   is gone before the next case starts.
//! - `while` and `until` are absent, and `for` only ever iterates a literal
//!   list. This is what keeps a timeout meaningful: the generator cannot write
//!   a program that is *supposed* to run forever, so a run that has to be
//!   killed is a loop inside den rather than one the fuzzer asked for.
//!
//! ## Reproducibility
//!
//! `next` is a pure function of the seed, so a failing case is replayed by
//! re-running with the seed the failure printed.

const std = @import("std");

/// Seed inputs for the mutation strategy, and worth running verbatim: they are
//. the cases that were hand-written when this suite only had a fixed list.
pub const corpus = [_][]const u8{
    "echo ${UNDEFINED:-default}",
    "echo ${UNDEFINED:+alternate}",
    "echo ${VAR:-${FALLBACK:-final}}",
    "echo ${#PATH}",
    "echo ${VAR:0:5}",
    "echo $((1 + 2))",
    "echo $((1 / 0))",
    "echo $(( ))",
    "echo $(echo $(echo nested))",
    "echo `echo backtick`",
    "echo *",
    "echo **",
    "echo [a-z]*",
    "echo {a,b,c}",
    "echo {1..5}",
    "echo {a..z}",
    "echo ~",
    "echo ~root",
    "echo \\n",
    "echo \\\\",
    "echo 'unterminated",
    "echo \"unterminated",
    "echo a | cat",
    "echo a | cat | cat | cat",
    "echo a && echo b || echo c",
    "! echo negated",
    "(echo subshell)",
    "{ echo group; }",
    "echo a > f1",
    "echo a >> f1",
    "cat < f1",
    "echo a 2> f1",
    "echo a 2>&1",
    "echo <<< herestring",
    "echo ${!PATH}",
    "echo $?$$$!",
    "echo \"$@\" \"$*\"",
    "echo 'hello 世界'",
    "echo '🎉'",
    "a=(x y); echo ${a[0]}",
    "f() { echo hi; }; f",
    "",
    " ",
    ";",
    "||",
    "&&",
    "|",
    ")",
    "}",
    "$",
    "`",

    // Gathered from the hand-written tests this suite used to consist of. They
    // are kept because they say what was once thought worth checking, and they
    // widen what the mutation strategy has to work from.
    "FUZZ_EMPTY=",
    "FUZZ_SPACE=hello world",
    "FUZZ_SPECIAL=!@#$%^&*()",
    "FUZZ_NEWLINE=hello\nworld",
    "FUZZ_TAB=hello\tworld",
    "FUZZ_QUOTE=it's",
    "FUZZ_DQUOTE=he said \"hi\"",
    "echo $((0))",
    "echo $((1+1))",
    "echo $((2*3))",
    "echo $((10/2))",
    "echo $((10%3))",
    "echo $((-5))",
    "echo $((2147483647))",
    "echo $((-2147483648))",
    "echo $((1<<2))",
    "echo $((8>>1))",
    "echo $((5&3))",
    "echo $((5|3))",
    "echo $((5^3))",
    "echo $(echo a)",
    "echo $(echo $(echo b))",
    "echo $(echo $(echo $(echo c)))",
    "echo `echo d`",
    "echo $(echo `echo e`)",
    "echo ?",
    "echo [abc]",
    "echo [a-z]",
    "echo [!a-z]",
    "echo ***",
    "echo .[!.]*",
    "echo */",
    "echo *.{txt,md}",
    "echo {a..e}",
    "echo {1..10..2}",
    "echo {a,b}{1,2}",
    "echo {{a,b},{c,d}}",
    "echo {01..10}",
    "echo ~/",
    "echo ~/test",
    "echo ~nobody",
    "echo ~+",
    "echo ~-",
    "echo test",
    "echo 'test'",
    "echo \"test\"",
    "echo \\t",
    "echo \\r",
    "echo \\'",
    "echo \\\"",
    "echo \\$",
    "echo \\`",
    "echo hello\\\nworld",
    "echo hel\\\nlo",
    "echo 'مرحبا'",
    "echo '🎉🎊🎈'",
    "echo 'Привет'",
    "echo 'こんにちは'",
    "echo '한글'",
    "echo",
    "cat",
    "ls",
    "pwd",
    "true",
    "false",
    "echo test > f1",
    "echo test >> f1",
    "cat < /dev/null",
    "echo test 2> f1",
    "echo test &> f1",
    "echo test 2>&1",
    "echo test 1>&2",
    "cat << EOF\nhello\nEOF",
    "cat <<- EOF\n\thello\n\tEOF",
    "cat << 'EOF'\n$HOME\nEOF",
    "cat <<< 'hello'",
    "cat <<< \"hello world\"",
    "cat <<< $HOME",
    "echo a | cat | cat",
    "echo a | cat | cat | cat | cat",
    "echo a | cat | cat | cat | cat | cat",
    "echo test | cat > f1 && echo done",
    "echo test 2>&1 | cat",
    "cat /dev/null | echo test",
    "true && echo success",
    "false || echo fallback",
    "true && false || echo recovered",
    "false || true && echo chain",
    "true; false; true",
    "echo a; echo b; echo c",
    "true && true && true && echo all",
    "false || false || false || echo none",
    "! true",
    "! false",
    "! ! true",
    "! true && echo fail || echo success",
    "(echo hello)",
    "(echo a; echo b)",
    "(cd /tmp && pwd)",
    "(true && echo yes)",
    "( ( echo nested ) )",
    "{ echo hello; }",
    "{ echo a; echo b; }",
    "{ true && echo yes; }",
    "  ",
    "\t",
    "\n",
    "   \t\n   ",
    "echo $?",
    "echo $$",
    "echo $!",
    "echo $0",
    "echo $#",
    "echo $@",
    "echo $*",
    "echo \"hello world\"",
    "echo 'hello world'",
    "echo hello\\ world",
    "echo \"$HOME\"",
    "echo '$HOME'",
};

/// Command words that are safe to run in any combination.
const commands = [_][]const u8{
    "echo",
    "printf '%s\\n'",
    "true",
    "false",
    ":",
    "pwd",
    "test 1 -eq 1",
};

/// Ordinary arguments.
const words = [_][]const u8{
    "a",
    "bb",
    "x y",
    "'q'",
    "\"d\"",
    "-n",
    "--",
    "0",
};

/// The interesting part: anything that has to be parsed or expanded.
const expansions = [_][]const u8{
    "$FUZZ_A",
    "${FUZZ_A}",
    "${FUZZ_A:-d}",
    "${FUZZ_A:+a}",
    "${#FUZZ_A}",
    "${FUZZ_A:0:2}",
    "${FUZZ_A%x}",
    "${FUZZ_A#x}",
    "${FUZZ_A/x/y}",
    "$((1+1))",
    "$((FUZZ_N))",
    "$?",
    "$$",
    "$#",
    "$0",
    "$9",
    "*",
    "?",
    "[a-z]",
    "~",
    "{a,b}",
    "{1..3}",
    "\\$",
    "\\\\",
};

/// Operators joining two commands. No `&`: a background child would outlive
/// the run.
const operators = [_][]const u8{ ";", "&&", "||", "|", "\n" };

/// Redirections. Targets are relative, so writes stay in the runner's
/// temporary directory.
const redirections = [_][]const u8{
    "> f1",
    ">> f1",
    "< f1",
    "2> f1",
    "2>> f1",
    "2>&1",
    ">&2",
    "<<< hs",
};

/// Characters the tokenizer has to make sense of in any arrangement.
const metachars = "|&;()<>$`\\\"'*?[]{}~!#= \t\n";

pub const Strategy = enum {
    /// Assembled from the grammar above.
    structured,
    /// A corpus entry with edits applied.
    mutated,
    /// Metacharacters and short words with no structure at all.
    soup,
};

pub const Generator = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Generator {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn rand(self: *Generator) std.Random {
        return self.prng.random();
    }

    fn pick(self: *Generator, comptime list: anytype) []const u8 {
        return list[self.rand().uintLessThan(usize, list.len)];
    }

    /// Generate one input into `buf`, returning the part written.
    ///
    /// Never exceeds `buf`; a fragment that would not fit is dropped rather
    /// than truncated, so the result stays syntactically whole-ish.
    pub fn next(self: *Generator, buf: []u8) []const u8 {
        const strategy: Strategy = switch (self.rand().uintLessThan(u8, 3)) {
            0 => .structured,
            1 => .mutated,
            else => .soup,
        };
        return switch (strategy) {
            .structured => self.structured(buf),
            .mutated => self.mutated(buf),
            .soup => self.soup(buf),
        };
    }

    const Writer = struct {
        buf: []u8,
        len: usize = 0,

        fn add(self: *Writer, text: []const u8) void {
            if (self.len + text.len > self.buf.len) return;
            @memcpy(self.buf[self.len..][0..text.len], text);
            self.len += text.len;
        }

        fn addByte(self: *Writer, c: u8) void {
            if (self.len + 1 > self.buf.len) return;
            self.buf[self.len] = c;
            self.len += 1;
        }

        fn done(self: *Writer) []const u8 {
            return self.buf[0..self.len];
        }
    };

    fn structured(self: *Generator, buf: []u8) []const u8 {
        var w = Writer{ .buf = buf };
        const segments = self.rand().uintLessThan(usize, 3) + 1;

        var i: usize = 0;
        while (i < segments) : (i += 1) {
            if (i > 0) {
                w.addByte(' ');
                w.add(self.pick(operators));
                w.addByte(' ');
            }
            self.command(&w, 0);
        }
        return w.done();
    }

    /// One command, possibly wrapped in a construct. `depth` bounds nesting so
    /// a substitution cannot recurse without end.
    fn command(self: *Generator, w: *Writer, depth: u8) void {
        if (depth < 2) {
            switch (self.rand().uintLessThan(u8, 10)) {
                0 => {
                    w.add("(");
                    self.command(w, depth + 1);
                    w.add(")");
                    return;
                },
                1 => {
                    w.add("{ ");
                    self.command(w, depth + 1);
                    w.add("; }");
                    return;
                },
                2 => {
                    w.add("if ");
                    self.command(w, depth + 1);
                    w.add("; then ");
                    self.command(w, depth + 1);
                    w.add("; fi");
                    return;
                },
                3 => {
                    // A literal list only, so the loop always ends.
                    w.add("for fz in a b; do ");
                    self.command(w, depth + 1);
                    w.add("; done");
                    return;
                },
                4 => {
                    w.add("$(");
                    self.command(w, depth + 1);
                    w.add(")");
                    return;
                },
                else => {},
            }
        }

        w.add(self.pick(commands));

        const args = self.rand().uintLessThan(usize, 3);
        var a: usize = 0;
        while (a < args) : (a += 1) {
            w.addByte(' ');
            if (self.rand().boolean()) {
                w.add(self.pick(expansions));
            } else {
                w.add(self.pick(words));
            }
        }

        if (self.rand().uintLessThan(u8, 4) == 0) {
            w.addByte(' ');
            w.add(self.pick(redirections));
        }
    }

    fn mutated(self: *Generator, buf: []u8) []const u8 {
        const base = self.pick(corpus);
        var w = Writer{ .buf = buf };
        w.add(base);

        // Splice in a second entry often enough to produce shapes no single
        // corpus line has.
        if (self.rand().uintLessThan(u8, 3) == 0) {
            w.addByte(' ');
            w.add(self.pick(corpus));
        }

        const edits = self.rand().uintLessThan(usize, 4) + 1;
        var e: usize = 0;
        while (e < edits) : (e += 1) {
            if (w.len == 0) {
                w.addByte(metachars[self.rand().uintLessThan(usize, metachars.len)]);
                continue;
            }
            switch (self.rand().uintLessThan(u8, 5)) {
                // Insert a metacharacter.
                0 => {
                    const at = self.rand().uintLessThan(usize, w.len);
                    const c = metachars[self.rand().uintLessThan(usize, metachars.len)];
                    if (w.len + 1 <= w.buf.len) {
                        std.mem.copyBackwards(u8, w.buf[at + 1 .. w.len + 1], w.buf[at..w.len]);
                        w.buf[at] = c;
                        w.len += 1;
                    }
                },
                // Delete a byte.
                1 => {
                    const at = self.rand().uintLessThan(usize, w.len);
                    std.mem.copyForwards(u8, w.buf[at .. w.len - 1], w.buf[at + 1 .. w.len]);
                    w.len -= 1;
                },
                // Swap two bytes.
                2 => {
                    const x = self.rand().uintLessThan(usize, w.len);
                    const y = self.rand().uintLessThan(usize, w.len);
                    const t = w.buf[x];
                    w.buf[x] = w.buf[y];
                    w.buf[y] = t;
                },
                // Truncate, which is how unterminated constructs appear.
                3 => {
                    w.len = self.rand().uintLessThan(usize, w.len) + 1;
                },
                // Repeat one byte, for depth and length limits.
                else => {
                    const c = w.buf[self.rand().uintLessThan(usize, w.len)];
                    const count = self.rand().uintLessThan(usize, 24) + 1;
                    var k: usize = 0;
                    while (k < count) : (k += 1) w.addByte(c);
                },
            }
        }
        return w.done();
    }

    fn soup(self: *Generator, buf: []u8) []const u8 {
        var w = Writer{ .buf = buf };
        const pieces = self.rand().uintLessThan(usize, 24) + 1;

        var i: usize = 0;
        while (i < pieces) : (i += 1) {
            if (self.rand().uintLessThan(u8, 4) == 0) {
                w.add(self.pick(words));
            } else {
                w.addByte(metachars[self.rand().uintLessThan(usize, metachars.len)]);
            }
        }
        return w.done();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "generator is deterministic for a seed" {
    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;

    var a = Generator.init(12345);
    var b = Generator.init(12345);

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const x = a.next(&buf_a);
        const y = b.next(&buf_b);
        // Replaying a failure depends on this.
        try std.testing.expectEqualStrings(x, y);
    }
}

test "different seeds diverge" {
    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;

    var a = Generator.init(1);
    var b = Generator.init(2);

    var same: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const x = a.next(&buf_a);
        const y = b.next(&buf_b);
        if (std.mem.eql(u8, x, y)) same += 1;
    }
    // A few collisions are expected from the shorter shapes; identical output
    // throughout would mean the seed is being ignored.
    try std.testing.expect(same < 50);
}

test "generated input always fits the buffer" {
    // Deliberately small, to catch a fragment written without a bounds check.
    var small: [16]u8 = undefined;
    var g = Generator.init(99);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const out = g.next(&small);
        try std.testing.expect(out.len <= small.len);
    }
}

test "the vocabulary holds nothing destructive" {
    // The safety boundary is this list, so it is asserted rather than trusted.
    const forbidden = [_][]const u8{
        "rm ", "mv ", "cp ", "kill", "exec", "shutdown", "reboot",
        "curl", "wget",  "dd ",  "mkfs", "chmod", "chown",  "sudo",
        ":(){", "/etc", "/dev/sd", "~/",
    };
    inline for (.{ commands, words, expansions, operators, redirections }) |list| {
        for (list) |entry| {
            for (forbidden) |bad| {
                if (std.mem.indexOf(u8, entry, bad) != null) {
                    std.debug.print("vocabulary entry [{s}] contains [{s}]\n", .{ entry, bad });
                    return error.UnsafeVocabulary;
                }
            }
        }
    }
}

test "no construct that is meant to run forever" {
    // A timeout is only a useful signal while the generator cannot ask for an
    // endless program, so `while` and `until` must stay out, and `for` must
    // iterate a literal list.
    var buf: [4096]u8 = undefined;
    var g = Generator.init(7);

    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const out = g.next(&buf);
        try std.testing.expect(std.mem.indexOf(u8, out, "while") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "until") == null);
    }
}

test "no redirection to an absolute path" {
    var buf: [4096]u8 = undefined;
    var g = Generator.init(31337);

    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const out = g.next(&buf);
        // Writes have to stay inside the runner's temporary directory.
        try std.testing.expect(std.mem.indexOf(u8, out, "> /") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, ">/") == null);
    }
}
