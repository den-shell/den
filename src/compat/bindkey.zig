//! zsh `bindkey` key-sequence notation.
//!
//! Turns a key specification written the way a `.zshrc` writes it (`^A`,
//! `\C-x`, `\M-x`, `\e[1;5C`, `\x1b`, `\033`) into the raw bytes the terminal
//! actually sends, and back again for `bindkey -L`. Pure data in, pure data
//! out: no Shell, no LineEditor, so it unit-tests in isolation.
//!
//! Two deliberate divergences from zsh, both permanent and both documented in
//! docs/LINE_EDITING.md:
//!
//!   * `\M-x` emits an ESC prefix (`1B 78`), never the 8th bit set. Den's read
//!     loop is byte-oriented with a dedicated ESC path, Den's existing Alt
//!     bindings are already ESC-prefixed (see utils/terminal/escape.zig), and a
//!     high byte would be ambiguous with a UTF-8 lead byte. This also matches
//!     what zsh itself does on a 7-bit terminal, which is what Terminal.app and
//!     iTerm2 send for Option by default.
//!   * `formatKeySeq` prints `80`-`FF` as `\xNN` rather than zsh's `\M-x`, so
//!     that `bindkey -L` output re-parses to the exact same bytes.

const std = @import("std");

/// Longest bindable byte sequence.
///
/// Covers everything utils/terminal/escape.zig can produce -- the longest are
/// `^[[1;5C` and `^[[200~` at 6 bytes -- and matches the editor's own escape
/// buffer, so a sequence that parses is always one the editor can deliver.
/// Kitty's full CSI-u form (`^[[27;5;109~`, 11 bytes) does not fit and is
/// rejected outright rather than silently truncated to something that would
/// never fire.
pub const max_key_seq_len = 8;

/// A parsed key sequence, by value: it is stored in comptime default tables,
/// copied into binding lists, and returned from a parser that must not be able
/// to fail for allocation reasons.
pub const KeySeq = struct {
    bytes: [max_key_seq_len]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const KeySeq) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Append one byte. False when the sequence is already full.
    pub fn push(self: *KeySeq, b: u8) bool {
        if (self.len >= max_key_seq_len) return false;
        self.bytes[self.len] = b;
        self.len += 1;
        return true;
    }

    pub fn clear(self: *KeySeq) void {
        self.bytes = @splat(0);
        self.len = 0;
    }

    pub fn eql(self: *const KeySeq, other: *const KeySeq) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    /// Build from raw bytes. Returns null when they do not fit.
    pub fn fromBytes(bytes: []const u8) ?KeySeq {
        if (bytes.len > max_key_seq_len) return null;
        var seq = KeySeq{};
        for (bytes) |b| _ = seq.push(b);
        return seq;
    }
};

pub const ParseError = error{
    /// The spec was the empty string.
    EmptySpec,
    /// More than max_key_seq_len bytes.
    SequenceTooLong,
    /// Spec ended on a lone backslash.
    IncompleteEscape,
    /// Spec ended on a lone `^`.
    IncompleteCaret,
    /// `^` followed by something with no control-character equivalent.
    BadCaretTarget,
    /// `\x` with no hex digit after it.
    BadHexEscape,
    /// `\C-` with nothing after it.
    BadControlEscape,
    /// `\M-` with nothing after it.
    BadMetaEscape,
    /// An octal or hex escape naming a value above 255.
    ValueOutOfRange,
};

/// One-line diagnostic for a ParseError, for `den: bindkey: bad key
/// specification: <spec>: <this>`. The switch is deliberately exhaustive with no
/// `else`, so adding a ParseError variant without a message fails to compile.
pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.EmptySpec => "empty key specification",
        error.SequenceTooLong => "key sequence longer than 8 bytes",
        error.IncompleteEscape => "trailing backslash",
        error.IncompleteCaret => "'^' must be followed by a character",
        error.BadCaretTarget => "'^' needs a letter or one of @ [ \\ ] ^ _ ?",
        error.BadHexEscape => "'\\x' must be followed by a hex digit",
        error.BadControlEscape => "'\\C-' must be followed by a character",
        error.BadMetaEscape => "'\\M-' must be followed by a character",
        error.ValueOutOfRange => "escape value out of range",
    };
}

/// Map the character after `^` (or after `\C-`) onto its control byte.
fn controlByte(c: u8) ?u8 {
    return switch (c) {
        '?' => 0x7F, // delete, not a masked value
        '@', '[', '\\', ']', '^', '_' => c & 0x1F,
        'a'...'z' => (c - 0x20) & 0x1F,
        'A'...'Z' => c & 0x1F,
        else => null,
    };
}

fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// Parse one unit of the spec starting at `i`, appending to `seq` and advancing
/// `i`. Shared by parseKeySpec and parseString so the two agree on notation.
fn parseUnit(spec: []const u8, i: *usize, seq: *KeySeq) ParseError!void {
    const c = spec[i.*];

    if (c == '^') {
        if (i.* + 1 >= spec.len) return error.IncompleteCaret;
        const target = spec[i.* + 1];
        const b = controlByte(target) orelse return error.BadCaretTarget;
        i.* += 2;
        if (!seq.push(b)) return error.SequenceTooLong;
        return;
    }

    if (c != '\\') {
        i.* += 1;
        if (!seq.push(c)) return error.SequenceTooLong;
        return;
    }

    // Backslash escapes.
    if (i.* + 1 >= spec.len) return error.IncompleteEscape;
    const e = spec[i.* + 1];

    // `\C-x` -- same as `^x`.
    if (e == 'C' and i.* + 2 < spec.len and spec[i.* + 2] == '-') {
        if (i.* + 3 >= spec.len) return error.BadControlEscape;
        const b = controlByte(spec[i.* + 3]) orelse return error.BadCaretTarget;
        i.* += 4;
        if (!seq.push(b)) return error.SequenceTooLong;
        return;
    }

    // `\M-x` -- ESC prefix, then whatever x parses to (so `\M-\C-a` is 1B 01).
    if (e == 'M' and i.* + 2 < spec.len and spec[i.* + 2] == '-') {
        if (i.* + 3 >= spec.len) return error.BadMetaEscape;
        if (!seq.push(0x1B)) return error.SequenceTooLong;
        i.* += 3;
        return parseUnit(spec, i, seq);
    }

    // `\xN` / `\xNN`
    if (e == 'x') {
        var j = i.* + 2;
        var digits: usize = 0;
        var value: u32 = 0;
        while (j < spec.len and digits < 2) : (digits += 1) {
            const d = std.fmt.charToDigit(spec[j], 16) catch break;
            value = value * 16 + d;
            j += 1;
        }
        if (digits == 0) return error.BadHexEscape;
        if (value > 0xFF) return error.ValueOutOfRange;
        i.* = j;
        if (!seq.push(@intCast(value))) return error.SequenceTooLong;
        return;
    }

    // Octal: up to three digits, counting a leading `0`. So `\101` is 'A' and
    // `\0101` is `\010` followed by a literal '1' -- the same rule Den's
    // `$'...'` expansion uses, so users have one story to learn.
    if (isOctalDigit(e)) {
        var j = i.* + 1;
        var digits: usize = 0;
        var value: u32 = 0;
        while (j < spec.len and digits < 3 and isOctalDigit(spec[j])) : (digits += 1) {
            value = value * 8 + (spec[j] - '0');
            j += 1;
        }
        if (value > 0xFF) return error.ValueOutOfRange;
        i.* = j;
        if (!seq.push(@intCast(value))) return error.SequenceTooLong;
        return;
    }

    const b: u8 = switch (e) {
        'e', 'E' => 0x1B,
        'a' => 0x07,
        'b' => 0x08,
        'f' => 0x0C,
        'n' => 0x0A,
        'r' => 0x0D,
        't' => 0x09,
        'v' => 0x0B,
        // zsh passes an unrecognised escape through as the character itself,
        // which also covers `\\`, `\^`, `\"` and `\'`.
        else => e,
    };
    i.* += 2;
    if (!seq.push(b)) return error.SequenceTooLong;
}

/// Parse a `bindkey` key specification into the bytes the terminal sends.
pub fn parseKeySpec(spec: []const u8) ParseError!KeySeq {
    if (spec.len == 0) return error.EmptySpec;
    var seq = KeySeq{};
    var i: usize = 0;
    while (i < spec.len) try parseUnit(spec, &i, &seq);
    if (seq.len == 0) return error.EmptySpec;
    return seq;
}

/// Parse the right-hand side of `bindkey -s`, which is a macro body rather than
/// a key sequence and so has no length ceiling. Caller owns the result.
pub fn parseString(allocator: std.mem.Allocator, spec: []const u8) (ParseError || error{OutOfMemory})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < spec.len) {
        // Reuse parseUnit one unit at a time so the escape rules cannot drift
        // between a key spec and a macro body.
        var unit = KeySeq{};
        try parseUnit(spec, &i, &unit);
        try out.appendSlice(allocator, unit.slice());
    }
    return out.toOwnedSlice(allocator);
}

/// Rendered form of a key sequence. Worst case is `\xNN` for every byte.
pub const DisplayBuf = struct {
    buf: [max_key_seq_len * 4]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const DisplayBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn appendDisplayByte(out: []u8, len: *usize, b: u8) void {
    switch (b) {
        0x7F => {
            out[len.*] = '^';
            out[len.* + 1] = '?';
            len.* += 2;
        },
        0x00...0x1F => {
            out[len.*] = '^';
            out[len.* + 1] = b | 0x40;
            len.* += 2;
        },
        // Quote the three characters that would otherwise be read back as
        // notation rather than as themselves.
        '^', '\\', '"' => {
            out[len.*] = '\\';
            out[len.* + 1] = b;
            len.* += 2;
        },
        // 0x20-0x7E minus the three quoted above.
        0x20...0x21, 0x23...0x5B, 0x5D, 0x5F...0x7E => {
            out[len.*] = b;
            len.* += 1;
        },
        else => {
            // `\xNN`, not zsh's `\M-x`: our `\M-` means an ESC prefix, so
            // `\M-` output would not round-trip back to this byte.
            const hex = "0123456789abcdef";
            out[len.*] = '\\';
            out[len.* + 1] = 'x';
            out[len.* + 2] = hex[b >> 4];
            out[len.* + 3] = hex[b & 0x0F];
            len.* += 4;
        },
    }
}

/// Canonical display form, as printed by `bindkey` and `bindkey -L`. Always
/// re-parses to the same bytes it was built from.
pub fn formatKeySeq(seq: []const u8) DisplayBuf {
    var out = DisplayBuf{};
    var len: usize = 0;
    for (seq) |b| appendDisplayByte(&out.buf, &len, b);
    out.len = @intCast(len);
    return out;
}

/// Display form of a `bindkey -s` macro body, which has no length ceiling.
/// Returns null when `out` is too small; four bytes per input byte is enough.
pub fn formatString(bytes: []const u8, out: []u8) ?[]const u8 {
    if (out.len < bytes.len * 4) return null;
    var len: usize = 0;
    for (bytes) |b| appendDisplayByte(out, &len, b);
    return out[0..len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectSpec(spec: []const u8, want: []const u8) !void {
    const seq = try parseKeySpec(spec);
    try testing.expectEqualSlices(u8, want, seq.slice());
}

test "parseKeySpec caret notation" {
    try expectSpec("^@", &.{0x00});
    try expectSpec("^A", &.{0x01});
    try expectSpec("^a", &.{0x01});
    try expectSpec("^Z", &.{0x1A});
    try expectSpec("^[", &.{0x1B});
    try expectSpec("^\\", &.{0x1C});
    try expectSpec("^]", &.{0x1D});
    try expectSpec("^^", &.{0x1E});
    try expectSpec("^_", &.{0x1F});
    try expectSpec("^?", &.{0x7F});
    try expectSpec("^X^E", &.{ 0x18, 0x05 });
}

test "parseKeySpec backslash-C control notation" {
    try expectSpec("\\C-a", &.{0x01});
    try expectSpec("\\C-A", &.{0x01});
    try expectSpec("\\C-?", &.{0x7F});
    try expectSpec("\\C-x\\C-e", &.{ 0x18, 0x05 });
}

test "parseKeySpec meta is an ESC prefix" {
    try expectSpec("\\M-b", &.{ 0x1B, 'b' });
    try expectSpec("\\eb", &.{ 0x1B, 'b' });
    try expectSpec("\\M-\\C-a", &.{ 0x1B, 0x01 });
}

test "parseKeySpec CSI sequences" {
    try expectSpec("\\e[A", &.{ 0x1B, '[', 'A' });
    try expectSpec("^[[A", &.{ 0x1B, '[', 'A' });
    try expectSpec("\\e[1;5C", &.{ 0x1B, '[', '1', ';', '5', 'C' });
    try expectSpec("^[[3~", &.{ 0x1B, '[', '3', '~' });
    try expectSpec("^[[200~", &.{ 0x1B, '[', '2', '0', '0', '~' });
}

test "parseKeySpec named escapes" {
    try expectSpec("\\e", &.{0x1B});
    try expectSpec("\\E", &.{0x1B});
    try expectSpec("\\a", &.{0x07});
    try expectSpec("\\b", &.{0x08});
    try expectSpec("\\f", &.{0x0C});
    try expectSpec("\\n", &.{0x0A});
    try expectSpec("\\r", &.{0x0D});
    try expectSpec("\\t", &.{0x09});
    try expectSpec("\\v", &.{0x0B});
    try expectSpec("\\\\", &.{'\\'});
    try expectSpec("\\^", &.{'^'});
    try expectSpec("\\\"", &.{'"'});
    try expectSpec("\\'", &.{'\''});
}

test "parseKeySpec octal and hex escapes" {
    try expectSpec("\\0", &.{0x00});
    try expectSpec("\\101", &.{'A'});
    try expectSpec("\\012", &.{0x0A});
    try expectSpec("\\033", &.{0x1B});
    // Only three octal digits are consumed, so the fourth is a literal. Same
    // rule as Den's $'...' expansion.
    try expectSpec("\\0101", &.{ 0x08, '1' });
    try expectSpec("\\x1b", &.{0x1B});
    try expectSpec("\\x1B", &.{0x1B});
    try expectSpec("\\x7", &.{0x07});
    try expectSpec("\\x41\\x42", &.{ 'A', 'B' });
}

test "parseKeySpec literal characters" {
    try expectSpec("jj", &.{ 'j', 'j' });
    try expectSpec("a", &.{'a'});
    // UTF-8 passes through bytewise.
    try expectSpec("é", &.{ 0xC3, 0xA9 });
}

test "parseKeySpec rejects malformed specs" {
    try testing.expectError(error.EmptySpec, parseKeySpec(""));
    try testing.expectError(error.IncompleteEscape, parseKeySpec("a\\"));
    try testing.expectError(error.IncompleteCaret, parseKeySpec("^"));
    try testing.expectError(error.BadCaretTarget, parseKeySpec("^+"));
    try testing.expectError(error.BadHexEscape, parseKeySpec("\\x"));
    try testing.expectError(error.BadHexEscape, parseKeySpec("\\xz"));
    try testing.expectError(error.BadControlEscape, parseKeySpec("\\C-"));
    try testing.expectError(error.BadMetaEscape, parseKeySpec("\\M-"));
    try testing.expectError(error.ValueOutOfRange, parseKeySpec("\\400"));
    try testing.expectError(error.SequenceTooLong, parseKeySpec("abcdefghi"));
    // Kitty's CSI-u form is 11 bytes: rejected, rather than truncated into a
    // binding that could never fire.
    try testing.expectError(error.SequenceTooLong, parseKeySpec("\\e[27;5;109~"));
}

test "formatKeySeq canonical display" {
    try testing.expectEqualStrings("^A", formatKeySeq(&.{0x01}).slice());
    try testing.expectEqualStrings("^@", formatKeySeq(&.{0x00}).slice());
    try testing.expectEqualStrings("^?", formatKeySeq(&.{0x7F}).slice());
    try testing.expectEqualStrings("^[[A", formatKeySeq(&.{ 0x1B, '[', 'A' }).slice());
    try testing.expectEqualStrings("^X^E", formatKeySeq(&.{ 0x18, 0x05 }).slice());
    try testing.expectEqualStrings("\\^", formatKeySeq(&.{'^'}).slice());
    try testing.expectEqualStrings("\\\\", formatKeySeq(&.{'\\'}).slice());
    try testing.expectEqualStrings("\\\"", formatKeySeq(&.{'"'}).slice());
    try testing.expectEqualStrings("jj", formatKeySeq(&.{ 'j', 'j' }).slice());
    try testing.expectEqualStrings("\\x80", formatKeySeq(&.{0x80}).slice());
    try testing.expectEqualStrings("\\xc3\\xa9", formatKeySeq(&.{ 0xC3, 0xA9 }).slice());
}

test "formatKeySeq round-trips every single byte" {
    var b: u16 = 0;
    while (b <= 0xFF) : (b += 1) {
        const byte: u8 = @intCast(b);
        const shown = formatKeySeq(&.{byte});
        const back = try parseKeySpec(shown.slice());
        try testing.expectEqualSlices(u8, &.{byte}, back.slice());
    }
}

test "formatKeySeq round-trips a notation corpus" {
    // The specs a real .zshrc actually contains.
    const corpus = [_][]const u8{
        "^A",     "^E",        "^K",     "^U",     "^W",      "^R",      "^Y",
        "^T",     "^?",        "^X^E",   "^X(",    "^[[A",    "^[[B",    "^[[C",
        "^[[D",   "^[[3~",     "^[[H",   "^[[F",   "^[[Z",    "^[[1;5C", "^[[1;5D",
        "^[[200~", "^[b",      "^[f",    "^[d",    "^[^?",    "jj",      "\\^",
    };
    for (corpus) |spec| {
        const seq = try parseKeySpec(spec);
        const shown = formatKeySeq(seq.slice());
        const back = try parseKeySpec(shown.slice());
        try testing.expectEqualSlices(u8, seq.slice(), back.slice());
    }
}

test "parseString handles unbounded macro bodies" {
    const body = try parseString(testing.allocator, "fg\\n");
    defer testing.allocator.free(body);
    try testing.expectEqualSlices(u8, "fg\n", body);

    // Longer than max_key_seq_len, which a key spec would reject.
    const long = try parseString(testing.allocator, "echo hello world\\n");
    defer testing.allocator.free(long);
    try testing.expectEqualSlices(u8, "echo hello world\n", long);
}

test "formatString round-trips a macro body" {
    var buf: [64]u8 = undefined;
    const shown = formatString("fg\n", &buf).?;
    try testing.expectEqualStrings("fg^J", shown);

    const back = try parseString(testing.allocator, shown);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, "fg\n", back);
}

test "formatString reports a buffer that is too small" {
    var buf: [2]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), formatString("fg\n", &buf));
}

test "KeySeq helpers" {
    var seq = KeySeq{};
    try testing.expect(seq.push(0x01));
    try testing.expect(seq.push(0x02));
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, seq.slice());

    var i: usize = 2;
    while (i < max_key_seq_len) : (i += 1) try testing.expect(seq.push('x'));
    try testing.expect(!seq.push('y')); // full

    seq.clear();
    try testing.expectEqual(@as(u8, 0), seq.len);

    try testing.expect(KeySeq.fromBytes("abcdefghi") == null);
    const from = KeySeq.fromBytes("^A").?;
    try testing.expectEqualSlices(u8, "^A", from.slice());
}
