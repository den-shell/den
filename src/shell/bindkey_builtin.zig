//! zsh-style `bindkey` builtin, plus a `zle` stub.
//!
//! Binds key sequences to named editing widgets in the interactive line editor.
//! Key specs use zsh's notation (`^A`, `\C-x`, `\e[1;5C`), parsed by
//! compat/bindkey.zig; the keymaps themselves live on the Shell, so a `bindkey`
//! in ~/.denrc takes effect even though the line editor does not exist yet.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const spec = @import("../compat/bindkey.zig");
const keymap = @import("../utils/terminal.zig").keymap;

const Shell = @import("../shell.zig").Shell;

const usage_line =
    "usage: bindkey [-l] [-L] [-e] [-v] [-a] [-d] [-M keymap] [-r seq ...] [-s seq string] [seq widget]\n";

fn usageError(self: *Shell, comptime fmt: []const u8, args: anytype) !void {
    try IO.eprint("den: bindkey: " ++ fmt, args);
    try IO.eprint(usage_line, .{});
    self.last_exit_code = 2;
}

/// Flags zsh has that Den does not. Recognised on purpose: a silent no-op for
/// one of these looks like it worked.
fn unsupported(self: *Shell, flag: u8) !void {
    const reason = switch (flag) {
        'A', 'N', 'D' => "den has a fixed set of keymaps (emacs, main, vicmd, vireplace, viins)",
        'R' => "bind each key individually",
        'p' => "use `bindkey -L` and filter the output",
        'm' => "den decodes Meta as an ESC prefix (bind \"\\e<key>\" instead)",
        else => "not supported",
    };
    try IO.eprint("den: bindkey: -{c} is not supported: {s}\n", .{ flag, reason });
    self.last_exit_code = 2;
}

/// Print one binding, in the form `bindkey -L` and the plain listing share.
const Printer = struct {
    maps: *const keymap.KeymapSet,
    /// `bindkey -L` prefixes each line so the output can be re-run.
    dump: bool,
    /// Emitted as `-M <name>` for anything that is not the main keymap.
    qualify: ?[]const u8,

    fn visit(self: *const Printer, seq: []const u8, binding: keymap.Binding) anyerror!void {
        const shown = spec.formatKeySeq(seq);
        if (self.dump) try IO.print("bindkey ", .{});
        if (self.qualify) |name| try IO.print("-M {s} ", .{name});

        if (binding.widget == .push_input) {
            var buf: [1024]u8 = undefined;
            const body = self.maps.getString(binding.index) orelse "";
            const escaped = spec.formatString(body, &buf) orelse return;
            try IO.print("-s \"{s}\" \"{s}\"\n", .{ shown.slice(), escaped });
            return;
        }
        try IO.print("\"{s}\" {s}\n", .{ shown.slice(), keymap.widgetName(binding.widget) });
    }
};

/// The name to print for `id`, or null when it is whatever `main` currently is.
fn qualifierFor(self: *Shell, id: keymap.KeymapId) ?[]const u8 {
    if (id == self.keymaps.current) return null;
    return switch (id) {
        .emacs => "emacs",
        .viins => "viins",
        .vicmd => "vicmd",
        .vireplace => "vireplace",
        .isearch => "isearch",
    };
}

fn selectMode(self: *Shell, vi: bool) void {
    self.keymaps.current = if (vi) .viins else .emacs;
    // Also move a running editor, so `bindkey -v` at the prompt takes effect
    // without waiting for a restart.
    if (self.line_editor) |*editor| editor.setEditingMode(if (vi) .vi else .emacs);
}

pub fn builtinBindkey(self: *Shell, cmd: *types.ParsedCommand) !void {
    var target: ?keymap.KeymapId = null;
    var list_names = false;
    var dump = false;
    var remove = false;
    var string_mode = false;
    var reset = false;
    var select_emacs = false;
    var select_vi = false;

    var i: usize = 0;
    flags: while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }

        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'l' => list_names = true,
                'L' => dump = true,
                'r' => remove = true,
                's' => string_mode = true,
                'd' => reset = true,
                'e' => select_emacs = true,
                'v' => select_vi = true,
                'a' => target = .vicmd,
                'M' => {
                    // The keymap name is the rest of this argument, or the next
                    // one: `-Mvicmd` and `-M vicmd` both work, as in zsh.
                    const rest = arg[j + 1 ..];
                    const name = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= cmd.args.len) {
                            try usageError(self, "-M requires a keymap name\n", .{});
                            return;
                        }
                        break :blk cmd.args[i];
                    };
                    target = self.keymaps.resolve(name) orelse {
                        try IO.eprint("den: bindkey: no such keymap: {s}\n", .{name});
                        self.last_exit_code = 1;
                        return;
                    };
                    continue :flags;
                },
                'A', 'N', 'D', 'R', 'p', 'm' => {
                    try unsupported(self, arg[j]);
                    return;
                },
                else => {
                    try usageError(self, "bad option: -{c}\n", .{arg[j]});
                    return;
                },
            }
        }
    }
    const operands = cmd.args[i..];

    if (select_emacs and select_vi) {
        try usageError(self, "-e and -v are mutually exclusive\n", .{});
        return;
    }
    if (select_emacs or select_vi) {
        selectMode(self, select_vi);
        // `bindkey -e` / `-v` on their own only switch keymaps; they do not
        // also dump the new one.
        if (operands.len == 0 and !list_names and !dump and !reset) {
            self.last_exit_code = 0;
            return;
        }
    }

    if (reset) {
        self.keymaps.resetAll(self.allocator);
        self.last_exit_code = 0;
        return;
    }

    if (list_names) {
        for (keymap.KeymapSet.names) |name| try IO.print("{s}\n", .{name});
        self.last_exit_code = 0;
        return;
    }

    const id = target orelse self.keymaps.current;

    if (remove) {
        if (operands.len == 0) {
            try usageError(self, "-r requires a key sequence\n", .{});
            return;
        }
        var ok = true;
        for (operands) |operand| {
            const seq = spec.parseKeySpec(operand) catch |err| {
                try IO.eprint("den: bindkey: bad key specification: {s}: {s}\n", .{ operand, spec.errorMessage(err) });
                ok = false;
                continue;
            };
            // Unbinding a key that was already free is not an error: a startup
            // file must not fail because something it tidies up is absent.
            _ = self.keymaps.get(id).unbind(self.allocator, seq.slice()) catch {
                try IO.eprint("den: bindkey: out of memory\n", .{});
                ok = false;
                continue;
            };
        }
        self.last_exit_code = if (ok) 0 else 1;
        return;
    }

    if (string_mode) {
        if (operands.len != 2) {
            try usageError(self, "-s requires a key sequence and a string\n", .{});
            return;
        }
        const seq = spec.parseKeySpec(operands[0]) catch |err| {
            try IO.eprint("den: bindkey: bad key specification: {s}: {s}\n", .{ operands[0], spec.errorMessage(err) });
            self.last_exit_code = 1;
            return;
        };
        const body = spec.parseString(self.allocator, operands[1]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try IO.eprint("den: bindkey: bad string: {s}: {s}\n", .{ operands[1], spec.errorMessage(@errorCast(err)) });
                self.last_exit_code = 1;
                return;
            },
        };
        const index = self.keymaps.addString(self.allocator, body) catch {
            self.allocator.free(body);
            try IO.eprint("den: bindkey: too many string bindings\n", .{});
            self.last_exit_code = 1;
            return;
        };
        try self.keymaps.get(id).bind(self.allocator, seq.slice(), .push_input, index);
        self.last_exit_code = 0;
        return;
    }

    // Listing: no operands, with or without -L.
    if (operands.len == 0) {
        const printer = Printer{
            .maps = &self.keymaps,
            .dump = dump,
            .qualify = if (dump) qualifierFor(self, id) else null,
        };
        try self.keymaps.getConst(id).forEach(&printer, Printer.visit);
        self.last_exit_code = 0;
        return;
    }

    // One operand queries; two bind.
    if (operands.len == 1) {
        const seq = spec.parseKeySpec(operands[0]) catch |err| {
            try IO.eprint("den: bindkey: bad key specification: {s}: {s}\n", .{ operands[0], spec.errorMessage(err) });
            self.last_exit_code = 1;
            return;
        };
        const map = self.keymaps.getConst(id);
        if (map.isUnbound(seq.slice())) {
            // Explicitly unbound by `bindkey -r`: report it as free.
            self.last_exit_code = 1;
            return;
        }
        switch (map.lookup(seq.slice())) {
            .exact, .exact_prefix => |binding| {
                const printer = Printer{
                    .maps = &self.keymaps,
                    .dump = dump,
                    .qualify = if (dump) qualifierFor(self, id) else null,
                };
                try printer.visit(seq.slice(), binding);
                self.last_exit_code = 0;
            },
            // A prefix on its own is not a binding, and neither is nothing.
            .prefix, .none => self.last_exit_code = 1,
        }
        return;
    }

    if (operands.len != 2) {
        try usageError(self, "too many arguments\n", .{});
        return;
    }

    const seq = spec.parseKeySpec(operands[0]) catch |err| {
        try IO.eprint("den: bindkey: bad key specification: {s}: {s}\n", .{ operands[0], spec.errorMessage(err) });
        self.last_exit_code = 1;
        return;
    };
    const widget = keymap.resolveWidget(operands[1]);
    if (widget == .unknown or widget == .user_widget or widget == .push_input) {
        try IO.eprint("den: bindkey: no such widget: {s}\n", .{operands[1]});
        // A shell function by that name means they wanted `zle -N`, so say so
        // rather than leaving them to guess.
        if (self.function_manager.hasFunction(operands[1])) {
            try IO.eprint(
                "den: bindkey: a shell function of that name exists, but user-defined widgets (zle -N) are not implemented\n",
                .{},
            );
        }
        self.last_exit_code = 1;
        return;
    }

    try self.keymaps.get(id).bind(self.allocator, seq.slice(), widget, 0);
    self.last_exit_code = 0;
}

/// `zle` exists only to explain itself. Registering the name means the most
/// copied line in any zsh plugin reports the real limitation instead of
/// "command not found", and makes a future implementation a non-breaking
/// addition rather than a new builtin.
pub fn builtinZle(self: *Shell, cmd: *types.ParsedCommand) !void {
    _ = cmd;
    try IO.eprint("den: zle: user-defined widgets are not implemented\n", .{});
    try IO.eprint(
        "den: zle: built-in widgets can be bound with `bindkey`; see docs/LINE_EDITING.md\n",
        .{},
    );
    self.last_exit_code = 2;
}
