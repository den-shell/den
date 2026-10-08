//! `den import-zsh` -- carry a zsh setup over to den's startup files.
//!
//! The migration guide used to say `grep "^alias" ~/.zshrc > ~/.denrc`, which by
//! construction drops functions, `source` lines and exports, and silently
//! truncates any alias whose value spans lines. This reads the three zsh files
//! den has equivalents for and copies what it can, naming what it cannot.
//!
//! Two rules shape the whole thing:
//!
//! 1. **Never silently drop.** Every line is either imported or reported with a
//!    reason. A migration that loses half a config without saying so is worse
//!    than one that refuses.
//! 2. **Never move between files.** `.zshrc` maps to `.denrc`, not "wherever it
//!    ought to live". Guessing that an export belongs in `.denenv` would change
//!    when it runs, which is exactly the kind of surprise a migration must not
//!    spring. Exports found in `.zshrc` are flagged instead, with the suggestion.

const std = @import("std");

const IO = @import("utils/io.zig").IO;

/// A zsh file and the den file its contents belong in.
const Pair = struct {
    from: []const u8,
    to: []const u8,
};

const pairs = [_]Pair{
    .{ .from = ".zshenv", .to = ".denenv" },
    .{ .from = ".zprofile", .to = ".denprofile" },
    .{ .from = ".zshrc", .to = ".denrc" },
};

/// Why a line was left behind. Each maps to one sentence in the report; the
/// point is that the user can act on it, so "unsupported" is never a reason on
/// its own.
const Skip = enum {
    completion_system,
    framework,
    zsh_builtin,
    prompt_internals,

    fn describe(self: Skip) []const u8 {
        return switch (self) {
            .completion_system => "zsh's completion system; den has its own and does not read these",
            .framework => "a zsh framework (oh-my-zsh and friends) -- zsh-only, cannot run under den",
            .zsh_builtin => "a zsh builtin den does not implement",
            .prompt_internals => "zsh prompt internals; configure the prompt in den.jsonc instead",
        };
    }
};

/// Lines that cannot work under den, and why. Order matters only in that the
/// first match wins, so the specific entries come before the general ones.
const Rejection = struct {
    needle: []const u8,
    why: Skip,
};

const rejections = [_]Rejection{
    .{ .needle = "oh-my-zsh", .why = .framework },
    .{ .needle = "plugins=(", .why = .framework },
    .{ .needle = "ZSH_THEME", .why = .framework },
    .{ .needle = "antigen", .why = .framework },
    .{ .needle = "zplug", .why = .framework },
    .{ .needle = "zinit", .why = .framework },
    .{ .needle = "zstyle", .why = .completion_system },
    .{ .needle = "compinit", .why = .completion_system },
    .{ .needle = "compdef", .why = .completion_system },
    .{ .needle = "compaudit", .why = .completion_system },
    .{ .needle = "autoload", .why = .zsh_builtin },
    .{ .needle = "zmodload", .why = .zsh_builtin },
    .{ .needle = "emulate", .why = .zsh_builtin },
    .{ .needle = "add-zsh-hook", .why = .zsh_builtin },
    .{ .needle = "PROMPT=", .why = .prompt_internals },
    .{ .needle = "RPROMPT=", .why = .prompt_internals },
    .{ .needle = "PS1=", .why = .prompt_internals },
    .{ .needle = "precmd()", .why = .prompt_internals },
};

fn rejectionFor(line: []const u8) ?Skip {
    for (rejections) |r| {
        if (std.mem.indexOf(u8, line, r.needle) != null) return r.why;
    }
    if (sourcesZshCompletion(line)) return .completion_system;
    return null;
}

/// Whether the line sources a zsh completion function.
///
/// Those files are zsh function definitions, not shell script -- sourcing one
/// under den produces a pile of errors at every startup. Two signals, both
/// unambiguous: zsh's own `site-functions` directory, and the convention that a
/// completion function file is named for its command with a leading underscore
/// (`_bun`, `_docker`).
fn sourcesZshCompletion(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "site-functions") != null) return true;
    var it = std.mem.tokenizeAny(u8, line, " \t\"'");
    while (it.next()) |word| {
        const base = std.fs.path.basename(word);
        if (base.len > 1 and base[0] == '_' and std.mem.indexOfScalar(u8, word, '/') != null) return true;
    }
    return false;
}

/// Where the statement starting at `start` ends.
///
/// A migration that copies line by line corrupts every multi-line construct it
/// touches: `plugins=(\n git\n)` becomes three broken fragments, a `case` loses
/// its `esac`, and an alias whose value spans lines is cut in half. So the unit
/// of import is a statement, not a line.
///
/// Completeness is judged the way a shell judges it: quotes must be closed,
/// parens and braces balanced, block keywords matched, and the line must not end
/// on a continuation. Quote state carries across lines, which is what makes an
/// alias holding an unclosed quote hold together.
fn statementEnd(lines: []const []const u8, start: usize) usize {
    var paren: i32 = 0;
    var brace: i32 = 0;
    var blocks: i32 = 0;
    var in_sq = false;
    var in_dq = false;
    var i = start;

    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        var esc = false;
        var continued = false;
        var j: usize = 0;
        while (j < line.len) : (j += 1) {
            const c = line[j];
            if (esc) {
                esc = false;
                continue;
            }
            switch (c) {
                '\\' => {
                    esc = true;
                    // A trailing backslash continues onto the next line.
                    if (j == line.len - 1) continued = true;
                },
                '\'' => if (!in_dq) {
                    in_sq = !in_sq;
                },
                '"' => if (!in_sq) {
                    in_dq = !in_dq;
                },
                '#' => if (!in_sq and !in_dq) {
                    // Rest of the line is a comment. Only when the `#` starts a
                    // word, so `${x#y}` and `a#b` are left alone.
                    if (j == 0 or line[j - 1] == ' ' or line[j - 1] == '\t') break;
                },
                '(' => if (!in_sq and !in_dq) {
                    paren += 1;
                },
                ')' => if (!in_sq and !in_dq) {
                    paren -= 1;
                },
                '{' => if (!in_sq and !in_dq) {
                    brace += 1;
                },
                '}' => if (!in_sq and !in_dq) {
                    brace -= 1;
                },
                else => {},
            }
        }

        if (!in_sq and !in_dq) blocks += blockDelta(line);

        const trimmed = std.mem.trim(u8, line, " \t");
        const operator_tail = std.mem.endsWith(u8, trimmed, "&&") or
            std.mem.endsWith(u8, trimmed, "||") or
            std.mem.endsWith(u8, trimmed, "|");

        if (!in_sq and !in_dq and !continued and !operator_tail and
            paren <= 0 and brace <= 0 and blocks <= 0) return i;
    }
    return lines.len - 1;
}

/// How much this line opens or closes block keywords.
///
/// Matched on whole words, so `ifconfig` does not read as `if` and `donetask`
/// does not close a loop. `do` and `then` are mid-markers and carry no weight.
fn blockDelta(line: []const u8) i32 {
    const openers = [_][]const u8{ "if", "case", "for", "while", "until", "select" };
    const closers = [_][]const u8{ "fi", "esac", "done" };
    var delta: i32 = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t;");
    var first = true;
    while (it.next()) |word| {
        const w = std.mem.trim(u8, word, "()");
        for (openers) |o| {
            // Only in command position: `echo if` is not a block, and a trailing
            // `fi`/`esac` after `;` is, which tokenizing on `;` already handles.
            if (std.mem.eql(u8, w, o) and first) delta += 1;
        }
        for (closers) |c| {
            if (std.mem.eql(u8, w, c)) delta -= 1;
        }
        first = false;
        // After a `;` the next token is in command position again.
        if (std.mem.endsWith(u8, word, ";")) first = true;
    }
    return delta;
}

fn isBlankOrComment(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len == 0 or t[0] == '#';
}

/// Whether the statement sets an environment variable, which decides the
/// "this may belong in .denenv" note.
fn isExport(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, t, "export ");
}

const Tally = struct {
    imported: usize = 0,
    skipped: usize = 0,
    exports_in_rc: usize = 0,
};

/// The marker that makes an import reversible: everything added goes between
/// these, so removing it is one edit rather than a diff against memory.
const begin_marker = "# >>> den import-zsh >>>";
const end_marker = "# <<< den import-zsh <<<";

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var write = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--write")) {
            write = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try usage();
            return;
        } else {
            try IO.eprint("den: import-zsh: unknown option: {s}\n", .{a});
            try usage();
            std.process.exit(2);
        }
    }

    const home_c = std.c.getenv("HOME") orelse {
        try IO.eprint("den: import-zsh: HOME is not set\n", .{});
        std.process.exit(1);
    };
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_c)));

    if (!write) {
        try IO.print("Dry run -- nothing is written. Re-run with --write to apply.\n\n", .{});
    }

    var total: Tally = .{};
    var any_source = false;

    for (pairs) |pair| {
        const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, pair.from });
        defer allocator.free(src_path);

        const content = readFile(allocator, src_path) catch null;
        if (content == null) continue;
        defer allocator.free(content.?);
        any_source = true;

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(allocator);
        var it = std.mem.splitScalar(u8, content.?, '\n');
        while (it.next()) |l| try lines.append(allocator, l);

        var keep: std.ArrayList(u8) = .empty;
        defer keep.deinit(allocator);
        var tally: Tally = .{};

        try IO.print("~/{s} -> ~/{s}\n", .{ pair.from, pair.to });

        var i: usize = 0;
        while (i < lines.items.len) : (i += 1) {
            if (isBlankOrComment(lines.items[i])) continue;

            const end = statementEnd(lines.items, i);
            const stmt = lines.items[i .. end + 1];

            // Rejection is judged over the whole statement, not its first line:
            // an `if` block calling compinit three lines down is still a zsh
            // completion line, and taking the head of it would be worse than
            // taking none.
            var why: ?Skip = null;
            for (stmt) |sl| {
                if (rejectionFor(sl)) |w| {
                    why = w;
                    break;
                }
            }

            const extra = end - i;
            if (why) |w| {
                try IO.print("  skip  {s}", .{trimForDisplay(lines.items[i])});
                if (wasTrimmed(lines.items[i])) try IO.print("...", .{});
                if (extra > 0) try IO.print("  (+{d} more)", .{extra});
                try IO.print("\n        {s}\n", .{w.describe()});
                tally.skipped += 1;
            } else {
                for (stmt) |sl| {
                    try keep.appendSlice(allocator, sl);
                    try keep.append(allocator, '\n');
                }
                try IO.print("  take  {s}", .{trimForDisplay(lines.items[i])});
                if (wasTrimmed(lines.items[i])) try IO.print("...", .{});
                if (extra > 0) try IO.print("  (+{d} more)", .{extra});
                try IO.print("\n", .{});
                tally.imported += 1;
                if (isExport(lines.items[i]) and std.mem.eql(u8, pair.to, ".denrc")) {
                    tally.exports_in_rc += 1;
                }
            }
            i = end;
        }

        if (tally.imported == 0 and tally.skipped == 0) {
            try IO.print("  (nothing to import)\n", .{});
        }
        try IO.print("\n", .{});

        if (write and keep.items.len > 0) {
            const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, pair.to });
            defer allocator.free(dst_path);
            try appendBlock(allocator, dst_path, pair.from, keep.items);
        }

        total.imported += tally.imported;
        total.skipped += tally.skipped;
        total.exports_in_rc += tally.exports_in_rc;
    }

    if (!any_source) {
        try IO.print("No ~/.zshenv, ~/.zprofile or ~/.zshrc found -- nothing to import.\n", .{});
        return;
    }

    try IO.print("{d} imported, {d} skipped.\n", .{ total.imported, total.skipped });

    if (total.exports_in_rc > 0) {
        try IO.print(
            \\
            \\{d} export(s) came from ~/.zshrc, so they land in ~/.denrc and only
            \\apply to interactive shells. If `den -c` needs them -- $PATH almost
            \\always does -- move those lines to ~/.denenv.
            \\
        , .{total.exports_in_rc});
    }

    if (total.skipped > 0 and write) {
        try IO.print(
            \\
            \\Skipped lines were left in your zsh files; nothing was deleted.
            \\
        , .{});
    }

    if (!write) {
        try IO.print("\nRe-run with --write to apply.\n", .{});
    }
}

/// Shorten for the report only. The imported text is always the full statement;
/// this is cosmetic, so it says when it has cut something.
fn trimForDisplay(line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \t");
    return if (t.len > 68) t[0..68] else t;
}

fn wasTrimmed(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len > 68;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);
    return try IO.readFileAlloc(allocator, file, 1024 * 1024);
}

/// Append one marked block to a den file, creating it if absent.
///
/// Appending rather than rewriting is what makes a second run safe: an earlier
/// block is left alone, so re-importing after editing ~/.zshrc adds the new
/// lines instead of clobbering whatever the user has since written by hand.
fn appendBlock(
    allocator: std.mem.Allocator,
    path: []const u8,
    from: []const u8,
    body: []const u8,
) !void {
    const existing = readFile(allocator, path) catch null;
    defer if (existing) |e| allocator.free(e);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    if (existing) |e| {
        try out.appendSlice(allocator, e);
        if (e.len > 0 and e[e.len - 1] != '\n') try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, begin_marker);
    try out.appendSlice(allocator, "\n# Imported from ~/");
    try out.appendSlice(allocator, from);
    try out.appendSlice(allocator, " by `den import-zsh`. Delete down to the closing\n");
    try out.appendSlice(allocator, "# marker to undo this in one go.\n");
    try out.appendSlice(allocator, body);
    try out.appendSlice(allocator, end_marker);
    try out.appendSlice(allocator, "\n");

    const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, out.items);

    try IO.print("  written to ~/{s}\n", .{std.fs.path.basename(path)});
}

fn usage() !void {
    try IO.print(
        \\Usage: den import-zsh [--write]
        \\
        \\Copies what it can from ~/.zshenv, ~/.zprofile and ~/.zshrc into the
        \\matching ~/.denenv, ~/.denprofile and ~/.denrc, and reports the rest.
        \\
        \\  (no flags)  show what would be imported, change nothing
        \\  --write     append it, inside a marked block you can delete in one go
        \\
    , .{});
}

// ============================================================================
// Tests
// ============================================================================

test "rejectionFor names the zsh-only lines" {
    try std.testing.expectEqual(Skip.framework, rejectionFor("source $ZSH/oh-my-zsh.sh").?);
    try std.testing.expectEqual(Skip.framework, rejectionFor("ZSH_THEME=\"robbyrussell\"").?);
    try std.testing.expectEqual(Skip.completion_system, rejectionFor("zstyle ':completion:*' menu select").?);
    try std.testing.expectEqual(Skip.completion_system, rejectionFor("autoload -Uz compinit").?);
    try std.testing.expectEqual(Skip.prompt_internals, rejectionFor("PROMPT='%n@%m %~ '").?);
    try std.testing.expect(rejectionFor("alias gs='git status'") == null);
    try std.testing.expect(rejectionFor("export EDITOR=vim") == null);
}

test "sourcesZshCompletion spots completion-function files" {
    try std.testing.expect(sourcesZshCompletion("source /opt/homebrew/share/zsh/site-functions/_bun"));
    try std.testing.expect(sourcesZshCompletion("[ -s \"$HOME/.stacks/bun/_bun\" ] && source \"$HOME/.stacks/bun/_bun\""));
    // A normal dotfile is not one, even with an underscore inside the name.
    try std.testing.expect(!sourcesZshCompletion("source ~/.easyotc-deploy.sh"));
    try std.testing.expect(!sourcesZshCompletion("source ~/my_env.sh"));
    try std.testing.expect(!sourcesZshCompletion("alias _x=1"));
}

test "statementEnd spans a function body" {
    const lines = [_][]const u8{ "dev() {", "  cd ~/code", "}", "alias after=1" };
    try std.testing.expectEqual(@as(usize, 2), statementEnd(&lines, 0));
    try std.testing.expectEqual(@as(usize, 3), statementEnd(&lines, 3));
}

test "statementEnd spans a parenthesised array" {
    // The shape that made the old line-at-a-time importer emit four fragments.
    const lines = [_][]const u8{ "plugins=(", "  git", "  artisan", ")", "alias x=1" };
    try std.testing.expectEqual(@as(usize, 3), statementEnd(&lines, 0));
}

test "statementEnd spans case/esac and if/fi" {
    const c = [_][]const u8{ "case \"$x\" in", "  a) ;;", "esac" };
    try std.testing.expectEqual(@as(usize, 2), statementEnd(&c, 0));

    const f = [_][]const u8{ "if true; then", "  echo hi", "fi" };
    try std.testing.expectEqual(@as(usize, 2), statementEnd(&f, 0));
}

test "statementEnd follows a backslash continuation" {
    const lines = [_][]const u8{ "export PATH=\"a\" \\", "  \"b\"", "alias x=1" };
    try std.testing.expectEqual(@as(usize, 1), statementEnd(&lines, 0));
}

test "statementEnd carries an unclosed quote across lines" {
    const lines = [_][]const u8{ "alias long='one", "two'", "alias x=1" };
    try std.testing.expectEqual(@as(usize, 1), statementEnd(&lines, 0));
}

test "statementEnd keeps a one-line statement on its line" {
    const lines = [_][]const u8{ "alias gs='git status'", "export A=1", "f() { :; }" };
    try std.testing.expectEqual(@as(usize, 0), statementEnd(&lines, 0));
    try std.testing.expectEqual(@as(usize, 1), statementEnd(&lines, 1));
    try std.testing.expectEqual(@as(usize, 2), statementEnd(&lines, 2));
}

test "blockDelta matches whole words only" {
    // `ifconfig` must not open a block, nor `donetask` close one.
    try std.testing.expectEqual(@as(i32, 0), blockDelta("ifconfig en0"));
    try std.testing.expectEqual(@as(i32, 0), blockDelta("echo donetask"));
    try std.testing.expectEqual(@as(i32, 1), blockDelta("if true; then"));
    try std.testing.expectEqual(@as(i32, 0), blockDelta("if true; then :; fi"));
}

test "statementEnd ignores a trailing comment" {
    const lines = [_][]const u8{ "alias x=1 # opens ( nothing", "alias y=2" };
    try std.testing.expectEqual(@as(usize, 0), statementEnd(&lines, 0));
}

test "isExport" {
    try std.testing.expect(isExport("export PATH=x"));
    try std.testing.expect(isExport("  export A=1"));
    try std.testing.expect(!isExport("alias x=1"));
}

test "isBlankOrComment" {
    try std.testing.expect(isBlankOrComment(""));
    try std.testing.expect(isBlankOrComment("   "));
    try std.testing.expect(isBlankOrComment("  # hi"));
    try std.testing.expect(!isBlankOrComment("alias x=1"));
}
