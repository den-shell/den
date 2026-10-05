const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Compound command integration tests
//
// These run the real den binary (`den -c ...`), unlike the ShellFixture-based
// scripting tests, which run /bin/sh. Expected output is what /bin/sh prints.
// ============================================================================

const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,

    fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn den(fixture: *test_utils.DenShellFixture, command: []const u8) !Result {
    const r = try fixture.execDirect(command);
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit_code = r.exit_code };
}

/// Run `command` and require exactly `stdout` and `exit_code`.
fn expectRun(command: []const u8, stdout: []const u8, exit_code: u8) !void {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try den(&fixture, command);
    defer r.deinit(allocator);
    std.testing.expectEqualStrings(stdout, r.stdout) catch |err| {
        std.debug.print("command: {s}\nstderr: {s}\n", .{ command, r.stderr });
        return err;
    };
    try std.testing.expectEqual(exit_code, r.exit_code);
}

// ---- The reported one-liner ----

test "compound: for loop after && (the reported one-liner)" {
    try expectRun(
        "cd /tmp && for u in HELLO CHRIS PAWEL GLENN; do printf '%s@hq.training  ' \"$(echo $u | tr A-Z a-z)\"; echo MAIL_PASSWORD_$u 2>/dev/null | tail -1; done",
        "hello@hq.training  MAIL_PASSWORD_HELLO\n" ++
            "chris@hq.training  MAIL_PASSWORD_CHRIS\n" ++
            "pawel@hq.training  MAIL_PASSWORD_PAWEL\n" ++
            "glenn@hq.training  MAIL_PASSWORD_GLENN\n",
        0,
    );
}

test "compound: reserved words are never run as commands" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try den(&fixture, "true && for i in 1; do echo $i; done");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("1\n", r.stdout);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "command not found") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Did you mean") == null);
}

test "compound: a stray keyword is a syntax error, not a missing program" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try den(&fixture, "echo a; done");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 2), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "syntax error near unexpected token `done'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Did you mean") == null);
}

test "compound: an unterminated loop is a syntax error" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try den(&fixture, "for i in 1 2; do echo $i");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 2), r.exit_code);
    try std.testing.expectEqualStrings("", r.stdout);
}

// ---- And-or lists and pipelines ----

test "compound: || and && around loops" {
    try expectRun("false || for i in 1 2; do echo $i; done", "1\n2\n", 0);
    try expectRun("false && for i in 1 2; do echo $i; done; echo rc=$?", "rc=1\n", 0);
    try expectRun("for i in 1 2; do echo $i; done && echo after", "1\n2\nafter\n", 0);
    try expectRun("true && if true; then echo y; fi || echo n", "y\n", 0);
    try expectRun("false && if true; then echo y; fi || echo n", "n\n", 0);
    try expectRun("true && { echo g1; echo g2; }", "g1\ng2\n", 0);
    try expectRun("true && ( echo sub )", "sub\n", 0);
}

test "compound: loops in pipelines" {
    try expectRun("for i in 1 2 3; do echo $i; done | tail -1", "3\n", 0);
    try expectRun("for i in 1 2; do echo $i; done 2>&1 | sort -r", "2\n1\n", 0);
    try expectRun("printf '1\\n2\\n' | while read n; do echo n$n; done", "n1\nn2\n", 0);
    try expectRun("echo a | { read x; echo got $x; } | tr a-z A-Z", "GOT A\n", 0);
    try expectRun("for i in 1 2 3; do echo $i; done | while read n; do echo x$n; done", "x1\nx2\nx3\n", 0);
    try expectRun("true | for i in 1; do echo piped; done", "piped\n", 0);
}

test "compound: a writer loop stops when its reader goes away" {
    try expectRun("while true; do echo y; done | head -2", "y\ny\n", 0);
}

test "compound: exit status of a pipeline and of !" {
    try expectRun("for i in 1; do false; done | cat; echo rc=$?", "rc=0\n", 0);
    try expectRun("! for i in 1; do false; done; echo rc=$?", "rc=0\n", 0);
    try expectRun("if ! false; then echo neg; fi", "neg\n", 0);
}

// ---- Loops ----

test "compound: nested loops, break and continue" {
    try expectRun("for i in a b; do for j in 1 2; do echo $i$j; done; done", "a1\na2\nb1\nb2\n", 0);
    try expectRun(
        "for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then continue; fi; if [ $i -eq 5 ]; then break; fi; echo $i; done",
        "1\n2\n4\n",
        0,
    );
    try expectRun(
        "for i in 1 2 3; do for j in a b c; do if [ $j = b ]; then continue 2; fi; echo $i$j; done; done",
        "1a\n2a\n3a\n",
        0,
    );
    try expectRun(
        "for i in 1 2 3; do for j in a b c; do if [ $j = b ]; then break 2; fi; echo $i$j; done; done; echo end",
        "1a\nend\n",
        0,
    );
}

test "compound: break never outlives the loops it is in" {
    try expectRun("for i in 1 2 3; do break 5; done; echo after", "after\n", 0);
    try expectRun("break; echo still-here", "still-here\n", 0);
    try expectRun("for i in 1 2; do continue; echo no; done; echo rc=$?", "rc=0\n", 0);
}

test "compound: for without in iterates the positional parameters" {
    try expectRun("set -- a 'b c' d; for x; do echo \"[$x]\"; done", "[a]\n[b c]\n[d]\n", 0);
    try expectRun("f() { for a; do echo \"f:$a\"; done; }; f one two", "f:one\nf:two\n", 0);
}

test "compound: loop variables and assignments persist after the loop" {
    try expectRun("for i in x y; do last=$i; done; echo $last", "y\n", 0);
    try expectRun("x=0; while [ $x -lt 3 ]; do x=$((x+1)); done; echo $x", "3\n", 0);
    try expectRun("x=0; until [ $x -ge 3 ]; do x=$((x+1)); done; echo $x", "3\n", 0);
    try expectRun("{ x=7; }; echo $x", "7\n", 0);
    try expectRun("( x=5; echo in $x ); echo out ${x:-unset}", "in 5\nout unset\n", 0);
}

test "compound: exit status of loops and conditionals" {
    try expectRun("for i in 1 2; do false; done; echo rc=$?", "rc=1\n", 0);
    try expectRun("for i in; do echo never; done; echo rc=$?", "rc=0\n", 0);
    try expectRun("while false; do :; done; echo rc=$?", "rc=0\n", 0);
    try expectRun("if false; then echo a; fi; echo rc=$?", "rc=0\n", 0);
    try expectRun("if true; then false; fi; echo rc=$?", "rc=1\n", 0);
    try expectRun("( exit 7 ); echo rc=$?", "rc=7\n", 0);
    try expectRun("case x in y) echo y;; esac; echo rc=$?", "rc=0\n", 0);
}

test "compound: C-style for loops with nested constructs" {
    try expectRun(
        "for ((i=0; i<6; i++)); do if [ $i = 1 ]; then continue; fi; if [ $i = 4 ]; then break; fi; echo c$i; done",
        "c0\nc2\nc3\n",
        0,
    );
    try expectRun("for ((i=0; i<2; i++)); do for ((j=0; j<2; j++)); do echo $i$j; done; done", "00\n01\n10\n11\n", 0);
}

// ---- if / case ----

test "compound: if, elif and else" {
    try expectRun("if false; then echo a; elif true; then echo b; else echo c; fi", "b\n", 0);
    try expectRun("if false; then echo a; elif false; then echo b; else echo c; fi", "c\n", 0);
    try expectRun("if true; then if false; then echo a; else echo b; fi; fi", "b\n", 0);
    try expectRun("if [ -d /tmp ] && [ -d / ]; then echo both; fi", "both\n", 0);
}

test "compound: case patterns" {
    try expectRun("case hello in h*) echo H;; *) echo other;; esac", "H\n", 0);
    try expectRun("case x in a|b) echo ab;; x|y) echo xy;; esac", "xy\n", 0);
    try expectRun(
        "for f in a.txt b.md; do case $f in *.txt) echo txt $f;; *) echo other $f;; esac; done",
        "txt a.txt\nother b.md\n",
        0,
    );
    // Quoted pattern characters are literal.
    try expectRun("case abc in \"a*\") echo lit;; a*) echo glob;; esac", "glob\n", 0);
    try expectRun("case 'x*y' in x\\*y) echo esc;; esac", "esc\n", 0);
}

// ---- Groups, subshells, substitutions, redirections ----

test "compound: redirections on compound commands" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const input_path = try fixture.createFile("in.txt", "l1\nl2\n");
    defer allocator.free(input_path);

    const r1 = try fixture.exec("for i in 1 2; do echo $i; done > out.txt; if true; then echo yes; fi >> out.txt; cat out.txt");
    defer allocator.free(r1.stdout);
    defer allocator.free(r1.stderr);
    try std.testing.expectEqualStrings("1\n2\nyes\n", r1.stdout);

    const r2 = try fixture.exec("while read l; do echo \"<$l>\"; done < in.txt");
    defer allocator.free(r2.stdout);
    defer allocator.free(r2.stderr);
    try std.testing.expectEqualStrings("<l1>\n<l2>\n", r2.stdout);

    const r3 = try fixture.exec("{ echo err >&2; } 2>&1 | cat");
    defer allocator.free(r3.stdout);
    defer allocator.free(r3.stderr);
    try std.testing.expectEqualStrings("err\n", r3.stdout);
}

test "compound: command substitution runs loops" {
    try expectRun("x=$(for i in 1 2 3; do printf %s $i; done); echo $x", "123\n", 0);
    try expectRun("echo $(if true; then echo inner; fi)", "inner\n", 0);
}

test "compound: groups and subshells inside loop bodies" {
    try expectRun("for i in 1 2; do { echo g$i; }; done", "g1\ng2\n", 0);
    try expectRun("for i in 1 2; do ( echo s$i ); done", "s1\ns2\n", 0);
}

// ---- Newline-separated forms ----

test "compound: newline-separated loops and conditionals" {
    try expectRun("for i in 1 2\ndo\n  echo $i\ndone", "1\n2\n", 0);
    try expectRun("x=1\nfor i in 1 2 3\ndo x=$((x*2))\ndone\necho $x", "8\n", 0);
    try expectRun("cd /tmp &&\nfor i in 1 2; do echo $i; done", "1\n2\n", 0);
    try expectRun("if true\nthen\n  echo y\nelif false\nthen\n  echo n\nfi", "y\n", 0);
    try expectRun("case b in\n  a) echo A ;;\n  b)\n    echo B\n    ;;\nesac", "B\n", 0);
    try expectRun(
        "while true; do\n  for j in 1 2 3; do\n    if [ $j = 2 ]; then break 2; fi\n    echo $j\n  done\ndone\necho out",
        "1\nout\n",
        0,
    );
    try expectRun("{\necho a\necho b\n} | wc -l | tr -d ' '", "2\n", 0);
}

// ---- exit, return, errexit ----

test "compound: exit inside a loop leaves the shell" {
    try expectRun("for i in 1 2; do echo $i; exit 3; done; echo no", "1\n", 3);
    try expectRun("echo a; exit 4; echo b", "a\n", 4);
    try expectRun("true && exit 3; echo after", "", 3);
    try expectRun("for i in 1; do false || exit 5; done; echo after", "", 5);
}

test "compound: return inside a loop leaves the function" {
    try expectRun(
        "f() { for i in 1 2 3; do if [ $i = 2 ]; then return 5; fi; echo $i; done; echo no; }; f; echo rc=$?",
        "1\nrc=5\n",
        0,
    );
}

test "compound: set -e stops at a failing loop" {
    try expectRun("set -e; for i in 1 2; do false; done; echo notreached", "", 1);
}

test "compound: loops over glob matches" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const a = try fixture.createFile("a.log", "");
    defer allocator.free(a);
    const b = try fixture.createFile("b.log", "");
    defer allocator.free(b);
    const r = try fixture.exec("n=0; for f in *.log; do n=$((n+1)); done; echo n=$n; for f in *.none; do echo \"$f\"; done");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    try std.testing.expectEqualStrings("n=2\n*.none\n", r.stdout);
    // The debug build reports a double free or a leak on stderr.
    try std.testing.expectEqualStrings("", r.stderr);
}

test "compound: time in front of a loop" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try den(&fixture, "time -p for i in 1 2; do echo $i; done");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("1\n2\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "real ") != null);
}
