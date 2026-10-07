//! Every builtin den implements, in one place.
//!
//! This list used to be written out by hand in four more: the syntax
//! highlighter, `compgen -b`, `enable -a` and the command-name completer. They
//! had drifted badly -- each carried about 65 of the 163 names, so most builtins
//! did not highlight, could not be completed, and were missing from both
//! listings. A name added to one was rarely added to the others.
//!
//! Membership and dispatch are different questions, and this answers only the
//! first. Which implementation runs a builtin is still decided by
//! `Executor.executeBuiltin` and `shell_builtins` in `shell/builtin_dispatch.zig`;
//! that file carries a test asserting its routing list is a subset of this one,
//! so a new shell-level builtin cannot be added to one and forgotten in the other.
//!
//! Only `std` is imported, so anything may use it without a layering problem --
//! the highlighter lives under `utils/` and must not reach into `shell/`.

const std = @import("std");

/// All builtin names, including the shell-level ones.
pub const all = [_][]const u8{
    "echo", "pwd", "cd", "env", "export",
    "set", "unset", "true", "false", "test",
    "[", "[[", "which", "type", "help",
    "alias", "unalias", "read", "printf", "source",
    ".", "history", "pushd", "popd", "dirs",
    "eval", "exec", "command", "builtin", "jobs",
    "fg", "bg", "wait", "disown", "kill",
    "trap", "times", "umask", "getopts", "clear",
    "time", "timeout", "hash", "yes", "reload",
    "watch", "tree", "grep", "find", "ft",
    "calc", "json", "ls", "seq", "date",
    "parallel", "http", "base64", "uuid", "localip",
    "ip", "shrug", "web", "return", "local",
    "copyssh", "reloaddns", "emptytrash", "wip", "bookmark",
    "code", "pstorm", "show", "hide", "sys-stats",
    "netstats", "net-check", "log-tail", "proc-monitor", "log-parse",
    "dotfiles", "library", "hook", "ifind", "coproc",
    "exit", ":", "declare", "typeset", "let",
    "shift", "break", "continue", "from", "to",
    "table", "grid", "where", "select", "reject",
    "get", "first", "last", "skip", "take",
    "length", "flatten", "uniq", "sort-by", "reverse",
    "transpose", "group-by", "enumerate", "wrap", "columns",
    "values", "headers", "compact", "rename", "append",
    "prepend", "str", "path", "math", "into",
    "encode", "decode", "detect", "bench", "seq-char",
    "generate", "par-each", "explore", "use", "complete",
    "compgen", "mapfile", "readarray", "sleep", "basename",
    "dirname", "realpath", "uname", "whoami", "readonly",
    "shopt", "caller", "enable", "setopt", "unsetopt",
    "ai", "wasm", "bindkey", "zle", "zstyle",
    "add-zsh-hook", "compinit", "bashcompinit", "compdef", "zmodload",
    "emulate", "is-at-least", "autoload",
};

/// Whether `name` is a builtin.
///
/// A linear scan: this is called on command dispatch, and at 163 short strings
/// with an early length check it is not worth a map that would have to be built
/// at startup.
pub fn contains(name: []const u8) bool {
    for (all) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

test "the list has no duplicates" {
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                std.debug.print("duplicate builtin name: {s}\n", .{a});
                return error.DuplicateBuiltinName;
            }
        }
    }
}

test "contains agrees with the list" {
    for (all) |b| try std.testing.expect(contains(b));
    try std.testing.expect(!contains(""));
    try std.testing.expect(!contains("definitely_not_a_builtin"));
}
