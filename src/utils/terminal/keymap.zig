//! Keymaps: byte sequences to named editing widgets.
//!
//! This is the data layer behind the `bindkey` builtin. Defaults are built at
//! comptime into read-only data, so an interactive shell that never calls
//! `bindkey` pays nothing for this: no allocation, no table construction, no
//! startup work. User bindings go in a small per-keymap override list that stays
//! empty until something binds a key.
//!
//! Lookup is a binary search over entries sorted on (packed bytes, length).
//! Because a sequence packs big-endian and is zero-padded on the right, a proper
//! prefix always sorts immediately before the sequences that extend it -- so
//! "is this an incomplete prefix of some longer binding?" falls out of the same
//! search that answers "is this an exact match?". The editor needs both answers
//! on every keystroke, which is why this is a sorted array rather than a hash
//! map (a hash map cannot answer the prefix question at all without a second
//! structure, and would have to be built at startup).
//!
//! Pure data: imports only std and the key-spec parser. No Shell, no LineEditor.

const std = @import("std");
const bindkey = @import("../../compat/bindkey.zig");

pub const KeySeq = bindkey.KeySeq;
pub const max_key_seq_len = bindkey.max_key_seq_len;

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

/// A named editing action, in zsh's vocabulary.
///
/// Several names are composites (`forward_char_or_autosuggest`) because Den's
/// editor already overloads those keys by context; encoding the overload in the
/// widget keeps the dispatcher free of modal `if`s.
///
/// Deliberately absent: `digit-argument`, `universal-argument` and
/// `vi-repeat-change`. Those need a numeric-argument field plus every movement
/// and kill widget honouring it; leaving them out means `bindkey '^[1'
/// digit-argument` reports "no such widget" honestly instead of binding a key to
/// something that silently does nothing.
pub const Widget = enum(u8) {
    // Line control
    accept_line,
    send_break,
    delete_char_or_eof,
    undefined_key,
    ignore,
    /// Recorded by `bindkey -r` over a key a default provides: the key consumes
    /// its byte and does nothing. Distinct from `ignore`, which is a binding a
    /// default or a user can legitimately ask for -- conflating them made
    /// `bindkey -L` lose the lines it had itself emitted for `ignore` keys.
    unbound,

    // Movement
    beginning_of_line,
    end_of_line,
    end_of_line_or_autosuggest,
    backward_char,
    forward_char,
    forward_char_or_autosuggest,
    backward_word,
    forward_word,
    vi_forward_word,
    vi_backward_word,
    vi_forward_word_end,

    // Insertion and deletion
    self_insert,
    vi_replace_char,
    quoted_insert,
    backward_delete_char,
    delete_char,
    transpose_chars,

    // Kill ring
    kill_line,
    backward_kill_line,
    kill_whole_line,
    kill_word,
    backward_kill_word,
    yank,
    kill_region_or_backward_kill_line,
    copy_region_or_backward_kill_word,

    // Region
    set_mark_command,
    copy_region_as_kill,
    kill_region,

    // History
    up_line_or_history,
    down_line_or_history,
    history_incremental_search_backward,
    toggle_fuzzy_search,
    accept_search,
    cancel_search,
    isearch_insert,
    isearch_delete_char,
    isearch_accept_and_redispatch,

    // Completion
    expand_or_complete,
    reverse_menu_complete,
    autosuggest_accept,

    // Undo
    undo,

    // Keyboard macros
    start_kbd_macro,
    end_kbd_macro,
    call_last_kbd_macro,

    // Display
    clear_screen,
    redisplay,

    /// Accumulate a numeric prefix, as vi's 1-9 do. Honoured by the movement
    /// and single-character delete widgets; other widgets ignore it.
    digit_argument,
    /// Vi's `0`: start of line, unless a count is already being typed, in which
    /// case it is another digit of it.
    vi_digit_or_beginning_of_line,

    // Vi mode transitions
    vi_cmd_mode,
    vi_insert,
    vi_add_next,
    vi_add_eol,
    vi_insert_bol,
    vi_open_line_below,
    vi_open_line_above,
    vi_substitute,
    vi_change_whole_line,
    vi_change_eol,
    overwrite_mode,

    // Den-specific
    den_escape,
    bracketed_paste,
    /// `bindkey -s`: push a literal string into the input, as if typed.
    /// `Binding.index` selects which string.
    push_input,

    /// Reserved for `zle -N` shell-function widgets, which are not implemented.
    /// Declared now so that adding them later is a new dispatch arm rather than
    /// a change to Entry's layout and every default table.
    user_widget,

    unknown,
};

/// Resolve a widget name, accepting zsh's spellings and its common aliases so a
/// line copied out of a .zshrc lands on something. Never returns null: an
/// unrecognised name is `.unknown`, and the caller turns that into the
/// diagnostic.
pub fn resolveWidget(name: []const u8) Widget {
    const Row = struct { []const u8, Widget };
    const table = [_]Row{
        .{ "accept-line", .accept_line },
        .{ "send-break", .send_break },
        .{ "delete-char-or-list", .delete_char_or_eof },
        .{ "delete-char-or-eof", .delete_char_or_eof },
        .{ "undefined-key", .undefined_key },
        .{ "ignore", .ignore },
        .{ "den-unbound", .unbound },

        .{ "beginning-of-line", .beginning_of_line },
        .{ "vi-beginning-of-line", .beginning_of_line },
        .{ "end-of-line", .end_of_line },
        .{ "vi-end-of-line", .end_of_line },
        .{ "backward-char", .backward_char },
        .{ "vi-backward-char", .backward_char },
        .{ "forward-char", .forward_char },
        .{ "vi-forward-char", .forward_char },
        .{ "backward-word", .backward_word },
        .{ "emacs-backward-word", .backward_word },
        .{ "forward-word", .forward_word },
        .{ "emacs-forward-word", .forward_word },
        .{ "vi-forward-word", .vi_forward_word },
        .{ "vi-backward-word", .vi_backward_word },
        .{ "vi-forward-word-end", .vi_forward_word_end },

        .{ "self-insert", .self_insert },
        .{ "quoted-insert", .quoted_insert },
        .{ "vi-quoted-insert", .quoted_insert },
        .{ "backward-delete-char", .backward_delete_char },
        .{ "vi-backward-delete-char", .backward_delete_char },
        .{ "delete-char", .delete_char },
        .{ "vi-delete-char", .delete_char },
        .{ "transpose-chars", .transpose_chars },

        .{ "kill-line", .kill_line },
        .{ "vi-kill-eol", .kill_line },
        .{ "backward-kill-line", .backward_kill_line },
        .{ "vi-kill-line", .backward_kill_line },
        .{ "kill-whole-line", .kill_whole_line },
        .{ "vi-delete-whole-line", .kill_whole_line },
        .{ "kill-word", .kill_word },
        .{ "backward-kill-word", .backward_kill_word },
        .{ "vi-backward-kill-word", .backward_kill_word },
        .{ "yank", .yank },
        .{ "vi-put-after", .yank },

        .{ "set-mark-command", .set_mark_command },
        .{ "copy-region-as-kill", .copy_region_as_kill },
        .{ "kill-region", .kill_region },

        .{ "up-line-or-history", .up_line_or_history },
        .{ "previous-history", .up_line_or_history },
        .{ "up-line-or-search", .up_line_or_history },
        .{ "up-line-or-beginning-search", .up_line_or_history },
        .{ "down-line-or-history", .down_line_or_history },
        .{ "next-history", .down_line_or_history },
        .{ "down-line-or-search", .down_line_or_history },
        .{ "down-line-or-beginning-search", .down_line_or_history },
        .{ "history-incremental-search-backward", .history_incremental_search_backward },
        .{ "history-incremental-pattern-search-backward", .history_incremental_search_backward },
        // Den's Ctrl+S toggles fuzzy matching inside the reverse search rather
        // than searching forward. Accepting zsh's name means a copied binding
        // works but does something different; rejecting it would break
        // migration for no gain. The divergence is noted in docs/MIGRATION.md.
        .{ "history-incremental-search-forward", .toggle_fuzzy_search },
        .{ "den-toggle-fuzzy-search", .toggle_fuzzy_search },
        .{ "accept-search", .accept_search },

        .{ "expand-or-complete", .expand_or_complete },
        .{ "complete-word", .expand_or_complete },
        .{ "menu-complete", .expand_or_complete },
        .{ "reverse-menu-complete", .reverse_menu_complete },
        .{ "autosuggest-accept", .autosuggest_accept },
        .{ "den-autosuggest-accept", .autosuggest_accept },

        .{ "undo", .undo },
        .{ "vi-undo-change", .undo },

        .{ "start-kbd-macro", .start_kbd_macro },
        .{ "end-kbd-macro", .end_kbd_macro },
        .{ "call-last-kbd-macro", .call_last_kbd_macro },

        .{ "clear-screen", .clear_screen },
        .{ "redisplay", .redisplay },

        .{ "digit-argument", .digit_argument },
        .{ "vi-digit-argument", .digit_argument },
        .{ "vi-digit-or-beginning-of-line", .vi_digit_or_beginning_of_line },

        .{ "vi-cmd-mode", .vi_cmd_mode },
        .{ "vi-insert", .vi_insert },
        .{ "vi-add-next", .vi_add_next },
        .{ "vi-add-eol", .vi_add_eol },
        .{ "vi-insert-bol", .vi_insert_bol },
        .{ "vi-open-line-below", .vi_open_line_below },
        .{ "vi-open-line-above", .vi_open_line_above },
        .{ "vi-substitute", .vi_substitute },
        .{ "vi-change-whole-line", .vi_change_whole_line },
        .{ "vi-change-eol", .vi_change_eol },
        .{ "overwrite-mode", .overwrite_mode },
        .{ "vi-replace", .overwrite_mode },

        .{ "bracketed-paste", .bracketed_paste },
        .{ "den-push-input", .push_input },

        // Composite and Den-specific widgets. These have no zsh equivalent
        // because Den's editor overloads the keys by context, but they must be
        // nameable or `bindkey -L` output would not be re-runnable.
        .{ "den-forward-char-or-autosuggest", .forward_char_or_autosuggest },
        .{ "den-end-of-line-or-autosuggest", .end_of_line_or_autosuggest },
        .{ "den-kill-region-or-backward-kill-line", .kill_region_or_backward_kill_line },
        .{ "den-copy-region-or-backward-kill-word", .copy_region_or_backward_kill_word },
        .{ "den-cancel-search", .cancel_search },
        .{ "den-isearch-insert", .isearch_insert },
        .{ "den-isearch-delete-char", .isearch_delete_char },
        .{ "den-isearch-accept-and-redispatch", .isearch_accept_and_redispatch },
        .{ "den-escape", .den_escape },
        .{ "vi-replace-chars", .vi_replace_char },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
    }
    return .unknown;
}

/// Canonical name for a widget, as `bindkey -L` prints it.
pub fn widgetName(w: Widget) []const u8 {
    return switch (w) {
        .accept_line => "accept-line",
        .send_break => "send-break",
        .delete_char_or_eof => "delete-char-or-eof",
        .undefined_key => "undefined-key",
        .ignore => "ignore",
        .unbound => "den-unbound",
        .beginning_of_line => "beginning-of-line",
        .end_of_line => "end-of-line",
        .end_of_line_or_autosuggest => "den-end-of-line-or-autosuggest",
        .backward_char => "backward-char",
        .forward_char => "forward-char",
        .forward_char_or_autosuggest => "den-forward-char-or-autosuggest",
        .backward_word => "backward-word",
        .forward_word => "forward-word",
        .vi_forward_word => "vi-forward-word",
        .vi_backward_word => "vi-backward-word",
        .vi_forward_word_end => "vi-forward-word-end",
        .self_insert => "self-insert",
        .vi_replace_char => "vi-replace-chars",
        .quoted_insert => "quoted-insert",
        .backward_delete_char => "backward-delete-char",
        .delete_char => "delete-char",
        .transpose_chars => "transpose-chars",
        .kill_line => "kill-line",
        .backward_kill_line => "backward-kill-line",
        .kill_whole_line => "kill-whole-line",
        .kill_word => "kill-word",
        .backward_kill_word => "backward-kill-word",
        .yank => "yank",
        .kill_region_or_backward_kill_line => "den-kill-region-or-backward-kill-line",
        .copy_region_or_backward_kill_word => "den-copy-region-or-backward-kill-word",
        .set_mark_command => "set-mark-command",
        .copy_region_as_kill => "copy-region-as-kill",
        .kill_region => "kill-region",
        .up_line_or_history => "up-line-or-history",
        .down_line_or_history => "down-line-or-history",
        .history_incremental_search_backward => "history-incremental-search-backward",
        .toggle_fuzzy_search => "den-toggle-fuzzy-search",
        .accept_search => "accept-search",
        .cancel_search => "den-cancel-search",
        .isearch_insert => "den-isearch-insert",
        .isearch_delete_char => "den-isearch-delete-char",
        .isearch_accept_and_redispatch => "den-isearch-accept-and-redispatch",
        .expand_or_complete => "expand-or-complete",
        .reverse_menu_complete => "reverse-menu-complete",
        .autosuggest_accept => "autosuggest-accept",
        .undo => "undo",
        .start_kbd_macro => "start-kbd-macro",
        .end_kbd_macro => "end-kbd-macro",
        .call_last_kbd_macro => "call-last-kbd-macro",
        .clear_screen => "clear-screen",
        .redisplay => "redisplay",
        .digit_argument => "digit-argument",
        .vi_digit_or_beginning_of_line => "vi-digit-or-beginning-of-line",
        .vi_cmd_mode => "vi-cmd-mode",
        .vi_insert => "vi-insert",
        .vi_add_next => "vi-add-next",
        .vi_add_eol => "vi-add-eol",
        .vi_insert_bol => "vi-insert-bol",
        .vi_open_line_below => "vi-open-line-below",
        .vi_open_line_above => "vi-open-line-above",
        .vi_substitute => "vi-substitute",
        .vi_change_whole_line => "vi-change-whole-line",
        .vi_change_eol => "vi-change-eol",
        .overwrite_mode => "overwrite-mode",
        .den_escape => "den-escape",
        .bracketed_paste => "bracketed-paste",
        .push_input => "den-push-input",
        .user_widget => "den-user-widget",
        .unknown => "undefined-key",
    };
}

// ---------------------------------------------------------------------------
// Entries and lookup
// ---------------------------------------------------------------------------

/// One binding. `key` is the sequence's bytes packed big-endian and zero-padded
/// on the right; `len` is stored rather than inferred because `^@` is byte 0x00,
/// so "", "\x00" and "\x00\x00" all pack to the same value.
pub const Entry = struct {
    key: u64,
    len: u8,
    widget: Widget,
    /// Index into the shell's user-widget list. Only meaningful when
    /// `widget == .user_widget`, which nothing produces yet. Absorbed by
    /// padding, so Entry stays 16 bytes.
    user_index: u16 = 0,
};

/// Pack a sequence's bytes into the sort/search key.
pub fn packKey(seq: []const u8) u64 {
    var k: u64 = 0;
    var i: usize = 0;
    while (i < max_key_seq_len) : (i += 1) {
        const b: u64 = if (i < seq.len) seq[i] else 0;
        k = (k << 8) | b;
    }
    return k;
}

fn entryLess(a: Entry, b: Entry) bool {
    if (a.key != b.key) return a.key < b.key;
    return a.len < b.len;
}

/// What a key is bound to.
pub const Binding = struct {
    widget: Widget,
    /// For `.push_input`, which of the keymap set's strings to push. For
    /// `.user_widget`, reserved for `zle -N`. Unused otherwise.
    index: u16 = 0,
};

/// What a lookup of a partially-typed sequence found.
pub const Lookup = union(enum) {
    /// Exact match and nothing extends it. Fire now.
    exact: Binding,
    /// Exact match, but a longer binding starts with this. Wait for more input;
    /// if nothing arrives before the key timeout, fire this.
    exact_prefix: Binding,
    /// No exact match, but a longer binding starts with this. Wait.
    prefix,
    /// Nothing matches and nothing will.
    none,
};

/// First index whose (key, len) is >= the needle.
fn lowerBound(table: []const Entry, needle: Entry) usize {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entryLess(table[mid], needle)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Mask selecting the top `len` bytes of a packed key.
fn prefixMask(len: u8) u64 {
    if (len == 0) return 0;
    if (len >= max_key_seq_len) return ~@as(u64, 0);
    const shift: u6 = @intCast((max_key_seq_len - len) * 8);
    return ~@as(u64, 0) << shift;
}

/// Look `seq` up in one sorted table.
pub fn lookupIn(table: []const Entry, seq: []const u8) Lookup {
    if (seq.len == 0 or seq.len > max_key_seq_len) return .none;
    const key = packKey(seq);
    const len: u8 = @intCast(seq.len);
    const needle = Entry{ .key = key, .len = len, .widget = .unknown };

    var i = lowerBound(table, needle);
    var hit: ?Binding = null;
    if (i < table.len and table[i].key == key and table[i].len == len) {
        hit = .{ .widget = table[i].widget, .index = table[i].user_index };
        i += 1;
    }
    // Anything extending `seq` sorts immediately after it, because the padding
    // bytes it replaces are zero and zero is less than any byte.
    const mask = prefixMask(len);
    const has_longer = i < table.len and (table[i].key & mask) == key;

    if (hit) |w| return if (has_longer) .{ .exact_prefix = w } else .{ .exact = w };
    return if (has_longer) .prefix else .none;
}

// ---------------------------------------------------------------------------
// Default keymaps
// ---------------------------------------------------------------------------

const DefaultRow = struct { []const u8, Widget };

/// Parse, sort and check a default table at comptime. The result lives in
/// read-only data, so no keymap is ever built at runtime.
fn buildKeymap(comptime rows: []const DefaultRow) [rows.len]Entry {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: [rows.len]Entry = undefined;
        for (rows, 0..) |row, i| {
            const seq = bindkey.parseKeySpec(row[0]) catch
                @compileError("bad default key spec: " ++ row[0]);
            out[i] = .{ .key = packKey(seq.slice()), .len = seq.len, .widget = row[1] };
        }
        // Insertion sort: comptime-safe and stable across Zig versions.
        var i: usize = 1;
        while (i < out.len) : (i += 1) {
            const item = out[i];
            var j = i;
            while (j > 0 and entryLess(item, out[j - 1])) : (j -= 1) out[j] = out[j - 1];
            out[j] = item;
        }
        var k: usize = 1;
        while (k < out.len) : (k += 1) {
            if (out[k].key == out[k - 1].key and out[k].len == out[k - 1].len)
                @compileError("duplicate default binding in keymap table");
        }
        return out;
    }
}

/// Bindings shared by emacs and vi-insert. Escape is bound per-keymap, since it
/// leaves insert mode under vi but only cancels under emacs.
const shared_rows = [_]DefaultRow{
    .{ "^@", .set_mark_command },
    .{ "^A", .beginning_of_line },
    .{ "^B", .backward_char },
    .{ "^C", .send_break },
    .{ "^D", .delete_char_or_eof },
    .{ "^E", .end_of_line },
    .{ "^F", .forward_char },
    .{ "^H", .backward_delete_char },
    .{ "^I", .expand_or_complete },
    .{ "^J", .accept_line },
    .{ "^K", .kill_line },
    .{ "^L", .clear_screen },
    .{ "^M", .accept_line },
    .{ "^N", .down_line_or_history },
    .{ "^P", .up_line_or_history },
    .{ "^R", .history_incremental_search_backward },
    .{ "^S", .toggle_fuzzy_search },
    .{ "^T", .transpose_chars },
    .{ "^U", .kill_region_or_backward_kill_line },
    .{ "^W", .copy_region_or_backward_kill_word },
    .{ "^X(", .start_kbd_macro },
    .{ "^X)", .end_kbd_macro },
    .{ "^Xe", .call_last_kbd_macro },
    .{ "^Y", .yank },
    .{ "^_", .undo },
    .{ "^?", .backward_delete_char },

    // CSI cursor keys.
    .{ "^[[A", .up_line_or_history },
    .{ "^[[B", .down_line_or_history },
    .{ "^[[C", .forward_char_or_autosuggest },
    .{ "^[[D", .backward_char },
    .{ "^[[H", .beginning_of_line },
    .{ "^[[F", .end_of_line_or_autosuggest },
    .{ "^[[Z", .reverse_menu_complete },
    // SS3 forms, sent in application cursor mode.
    .{ "^[OA", .up_line_or_history },
    .{ "^[OB", .down_line_or_history },
    .{ "^[OC", .forward_char_or_autosuggest },
    .{ "^[OD", .backward_char },
    .{ "^[OH", .beginning_of_line },
    .{ "^[OF", .end_of_line_or_autosuggest },
    // Numeric-parameter forms.
    .{ "^[[1~", .beginning_of_line },
    .{ "^[[3~", .delete_char },
    .{ "^[[4~", .end_of_line },
    .{ "^[[1;5C", .forward_word },
    .{ "^[[1;5D", .backward_word },
    .{ "^[[1;3C", .forward_word },
    .{ "^[[1;3D", .backward_word },
    .{ "^[[3;5~", .kill_word },
    .{ "^[[3;3~", .kill_word },
    .{ "^[[200~", .bracketed_paste },
    .{ "^[[201~", .ignore },
    // Meta/Alt forms.
    .{ "^[b", .backward_word },
    .{ "^[f", .forward_word },
    .{ "^[d", .kill_word },
    .{ "^[^?", .backward_kill_word },
    .{ "^[^H", .backward_kill_word },
};

const emacs_defaults = buildKeymap(&(shared_rows ++ [_]DefaultRow{
    .{ "^[", .den_escape },
}));

const viins_defaults = buildKeymap(&(shared_rows ++ [_]DefaultRow{
    .{ "^[", .vi_cmd_mode },
}));

/// Vi normal mode. Only the operators Den actually implements are bound: `dd`
/// and `cc` are two-byte sequences, which the prefix machinery resolves without
/// any operator-pending state. `d`/`c` plus a motion is not supported, and is
/// deliberately left unbound rather than bound to something approximate.
const vicmd_defaults = buildKeymap(&[_]DefaultRow{
    .{ "^C", .send_break },
    .{ "^D", .delete_char_or_eof },
    .{ "^J", .accept_line },
    .{ "^L", .clear_screen },
    .{ "^M", .accept_line },
    .{ "^R", .history_incremental_search_backward },
    .{ "^[", .ignore },

    .{ "h", .backward_char },
    .{ "l", .forward_char },
    // `0` is also a count digit once one is being typed.
    .{ "0", .vi_digit_or_beginning_of_line },
    .{ "$", .end_of_line },
    // A literal caret: "^^" would be Ctrl+^ (0x1E).
    .{ "\\^", .beginning_of_line },
    .{ "1", .digit_argument },
    .{ "2", .digit_argument },
    .{ "3", .digit_argument },
    .{ "4", .digit_argument },
    .{ "5", .digit_argument },
    .{ "6", .digit_argument },
    .{ "7", .digit_argument },
    .{ "8", .digit_argument },
    .{ "9", .digit_argument },
    .{ "w", .vi_forward_word },
    .{ "b", .vi_backward_word },
    .{ "e", .vi_forward_word_end },
    .{ "j", .down_line_or_history },
    .{ "k", .up_line_or_history },

    .{ "x", .delete_char },
    .{ "X", .backward_delete_char },
    .{ "D", .kill_line },
    .{ "C", .vi_change_eol },
    .{ "dd", .kill_whole_line },
    .{ "cc", .vi_change_whole_line },
    .{ "u", .undo },

    .{ "i", .vi_insert },
    .{ "I", .vi_insert_bol },
    .{ "a", .vi_add_next },
    .{ "A", .vi_add_eol },
    .{ "o", .vi_open_line_below },
    .{ "O", .vi_open_line_above },
    .{ "s", .vi_substitute },
    .{ "S", .vi_change_whole_line },
    .{ "R", .overwrite_mode },
    .{ "/", .history_incremental_search_backward },
    .{ "n", .history_incremental_search_backward },
});

/// Vi replace mode: only the keys that leave it. Everything printable overwrites
/// via the keymap's fallback.
const vireplace_defaults = buildKeymap(&[_]DefaultRow{
    .{ "^C", .send_break },
    .{ "^J", .accept_line },
    .{ "^M", .accept_line },
    .{ "^[", .vi_cmd_mode },
    .{ "^?", .backward_delete_char },
});

/// Incremental search. An unbound key accepts the search and is then re-run in
/// the normal keymap, which is zsh's rule; today Den drops it silently.
const isearch_defaults = buildKeymap(&[_]DefaultRow{
    .{ "^C", .cancel_search },
    .{ "^G", .cancel_search },
    .{ "^H", .isearch_delete_char },
    .{ "^J", .accept_search },
    .{ "^M", .accept_search },
    .{ "^R", .history_incremental_search_backward },
    .{ "^S", .toggle_fuzzy_search },
    .{ "^[", .cancel_search },
    .{ "^?", .isearch_delete_char },
});

// ---------------------------------------------------------------------------
// Keymap set
// ---------------------------------------------------------------------------

pub const KeymapId = enum {
    emacs,
    viins,
    vicmd,
    vireplace,
    isearch,
};

/// Every keymap, in the order `KeymapSet.maps` stores them. `defaultsFor` and
/// `fallbackWidget` switch exhaustively over KeymapId, so adding a keymap
/// without extending this list fails to compile there.
pub const all_keymaps = [_]KeymapId{ .emacs, .viins, .vicmd, .vireplace, .isearch };

const keymap_count = all_keymaps.len;

fn defaultsFor(id: KeymapId) []const Entry {
    return switch (id) {
        .emacs => &emacs_defaults,
        .viins => &viins_defaults,
        .vicmd => &vicmd_defaults,
        .vireplace => &vireplace_defaults,
        .isearch => &isearch_defaults,
    };
}

/// What an unbound single byte does in a given keymap. This is how zsh's
/// keymaps bind the printable range, rather than the dispatcher special-casing
/// byte values.
pub fn fallbackWidget(id: KeymapId, b: u8) ?Widget {
    const printable = (b >= 0x20 and b <= 0x7E) or (b >= 0xC2 and b <= 0xF4);
    return switch (id) {
        .emacs, .viins => if (printable) .self_insert else null,
        .vireplace => if (printable) .vi_replace_char else null,
        .isearch => if (b >= 0x20 and b <= 0x7E)
            .isearch_insert
        else
            .isearch_accept_and_redispatch,
        .vicmd => null,
    };
}

/// One keymap: a comptime default table plus whatever the user has bound.
///
/// `bindkey -r` on a key that a default provides inserts an `.ignore` override
/// rather than deleting a row, so an unbound key consumes its byte and does
/// nothing instead of falling back to the default.
pub const Keymap = struct {
    id: KeymapId,
    overrides: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Keymap, allocator: std.mem.Allocator) void {
        self.overrides.deinit(allocator);
        self.overrides = .empty;
    }

    /// Bind `seq`, replacing any existing override for the same sequence.
    pub fn bind(
        self: *Keymap,
        allocator: std.mem.Allocator,
        seq: []const u8,
        widget: Widget,
        user_index: u16,
    ) !void {
        if (seq.len == 0 or seq.len > max_key_seq_len) return error.InvalidKeySequence;
        const entry = Entry{
            .key = packKey(seq),
            .len = @intCast(seq.len),
            .widget = widget,
            .user_index = user_index,
        };
        const at = lowerBound(self.overrides.items, entry);
        if (at < self.overrides.items.len and
            self.overrides.items[at].key == entry.key and
            self.overrides.items[at].len == entry.len)
        {
            self.overrides.items[at] = entry;
            return;
        }
        try self.overrides.insert(allocator, at, entry);
    }

    /// Unbind `seq`. Returns true when the sequence had been bound to something
    /// other than nothing, so callers can stay quiet about a no-op.
    pub fn unbind(self: *Keymap, allocator: std.mem.Allocator, seq: []const u8) !bool {
        if (seq.len == 0 or seq.len > max_key_seq_len) return false;
        const was_bound = switch (lookupIn(defaultsFor(self.id), seq)) {
            .exact, .exact_prefix => true,
            else => false,
        };
        const needle = Entry{ .key = packKey(seq), .len = @intCast(seq.len), .widget = .unknown };
        const at = lowerBound(self.overrides.items, needle);
        const has_override = at < self.overrides.items.len and
            self.overrides.items[at].key == needle.key and
            self.overrides.items[at].len == needle.len;

        if (was_bound) {
            // Shadow the default with an explicit "does nothing".
            const tombstone = Entry{ .key = needle.key, .len = needle.len, .widget = .unbound };
            if (has_override) {
                const prev = self.overrides.items[at].widget;
                self.overrides.items[at] = tombstone;
                return prev != .unbound;
            }
            try self.overrides.insert(allocator, at, tombstone);
            return true;
        }
        if (has_override) {
            const prev = self.overrides.items[at].widget;
            _ = self.overrides.orderedRemove(at);
            return prev != .unbound;
        }
        return false;
    }

    /// Look `seq` up: overrides first, then the comptime defaults. The prefix
    /// flags from the two layers are OR'd, so binding `^X^E` correctly turns an
    /// exact default `^X` into `.exact_prefix`.
    pub fn lookup(self: *const Keymap, seq: []const u8) Lookup {
        const over = lookupIn(self.overrides.items, seq);
        const def = lookupIn(defaultsFor(self.id), seq);

        const binding: ?Binding = switch (over) {
            .exact, .exact_prefix => |b| b,
            else => switch (def) {
                .exact, .exact_prefix => |b| b,
                else => null,
            },
        };
        const longer = switch (over) {
            .exact_prefix, .prefix => true,
            else => switch (def) {
                .exact_prefix, .prefix => true,
                else => false,
            },
        };

        if (binding) |b| return if (longer) .{ .exact_prefix = b } else .{ .exact = b };
        return if (longer) .prefix else .none;
    }

    /// Whether a user override explicitly unbinds this sequence, which is what
    /// `bindkey -r` records for a key a default provides. Such a key consumes
    /// its byte and does nothing, but must not be reported as a binding -- the
    /// same reason forEach skips it.
    pub fn isUnbound(self: *const Keymap, seq: []const u8) bool {
        return switch (lookupIn(self.overrides.items, seq)) {
            .exact, .exact_prefix => |b| b.widget == .unbound,
            else => false,
        };
    }

    /// Walk every effective binding in ascending byte order, merging overrides
    /// over defaults. `.ignore` tombstones that shadow a default are skipped, so
    /// an unbound key does not show up in `bindkey -L`.
    pub fn forEach(
        self: *const Keymap,
        context: anytype,
        comptime visit: fn (@TypeOf(context), seq: []const u8, binding: Binding) anyerror!void,
    ) !void {
        const defaults = defaultsFor(self.id);
        const overrides = self.overrides.items;
        var di: usize = 0;
        var oi: usize = 0;

        while (di < defaults.len or oi < overrides.len) {
            const take_override = if (di >= defaults.len)
                true
            else if (oi >= overrides.len)
                false
            else if (entryLess(overrides[oi], defaults[di]))
                true
            else
                !entryLess(defaults[di], overrides[oi]); // equal keys: override wins

            const entry = if (take_override) overrides[oi] else defaults[di];
            if (take_override) {
                oi += 1;
                // Skip the default this override replaces.
                if (di < defaults.len and
                    defaults[di].key == entry.key and
                    defaults[di].len == entry.len) di += 1;
            } else {
                di += 1;
            }
            if (entry.widget == .unbound) continue;

            var seq: [max_key_seq_len]u8 = undefined;
            var i: usize = 0;
            while (i < entry.len) : (i += 1) {
                const shift: u6 = @intCast((max_key_seq_len - 1 - i) * 8);
                seq[i] = @truncate(entry.key >> shift);
            }
            try visit(context, seq[0..entry.len], .{ .widget = entry.widget, .index = entry.user_index });
        }
    }
};

/// Every keymap, plus which of emacs/viins `main` currently names.
pub const KeymapSet = struct {
    maps: [keymap_count]Keymap,
    /// Whichever of `emacs` / `viins` `main` resolves to.
    current: KeymapId = .emacs,
    /// Macro bodies for `bindkey -s`, referenced by `Binding.index`. Append
    /// only: an index handed to a binding has to stay valid, and the strings are
    /// a handful of bytes each.
    strings: std.ArrayList([]u8) = .empty,

    /// Allocation-free: the default tables are comptime data and the override
    /// lists start empty.
    pub fn init() KeymapSet {
        var maps: [keymap_count]Keymap = undefined;
        inline for (all_keymaps) |id| {
            maps[@intFromEnum(id)] = .{ .id = id };
        }
        return .{ .maps = maps };
    }

    pub fn deinit(self: *KeymapSet, allocator: std.mem.Allocator) void {
        for (&self.maps) |*m| m.deinit(allocator);
        for (self.strings.items) |str| allocator.free(str);
        self.strings.deinit(allocator);
        self.strings = .empty;
    }

    /// Store a macro body and return the index to bind it under. Takes
    /// ownership of `text`.
    pub fn addString(self: *KeymapSet, allocator: std.mem.Allocator, text: []u8) !u16 {
        if (self.strings.items.len >= std.math.maxInt(u16)) return error.TooManyStrings;
        try self.strings.append(allocator, text);
        return @intCast(self.strings.items.len - 1);
    }

    pub fn getString(self: *const KeymapSet, index: u16) ?[]const u8 {
        if (index >= self.strings.items.len) return null;
        return self.strings.items[index];
    }

    pub fn get(self: *KeymapSet, id: KeymapId) *Keymap {
        return &self.maps[@intFromEnum(id)];
    }

    pub fn getConst(self: *const KeymapSet, id: KeymapId) *const Keymap {
        return &self.maps[@intFromEnum(id)];
    }

    /// Resolve a keymap name as `bindkey -M` accepts it. `main` follows the
    /// selected editing mode. Returns null for an unknown name.
    pub fn resolve(self: *const KeymapSet, name: []const u8) ?KeymapId {
        if (std.mem.eql(u8, name, "main")) return self.current;
        if (std.mem.eql(u8, name, "emacs")) return .emacs;
        if (std.mem.eql(u8, name, "viins")) return .viins;
        if (std.mem.eql(u8, name, "vicmd")) return .vicmd;
        if (std.mem.eql(u8, name, "vireplace")) return .vireplace;
        if (std.mem.eql(u8, name, "isearch")) return .isearch;
        return null;
    }

    /// Names `bindkey -l` lists, in the order it prints them.
    pub const names = [_][]const u8{ "emacs", "isearch", "main", "vicmd", "vireplace", "viins" };

    /// Drop every user binding, restoring the compiled-in defaults.
    pub fn resetAll(self: *KeymapSet, allocator: std.mem.Allocator) void {
        for (&self.maps) |*m| {
            m.overrides.clearAndFree(allocator);
        }
        for (self.strings.items) |str| allocator.free(str);
        self.strings.clearAndFree(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn seqOf(spec: []const u8) KeySeq {
    return bindkey.parseKeySpec(spec) catch unreachable;
}

test "resolveWidget maps zsh names and aliases" {
    try testing.expectEqual(Widget.beginning_of_line, resolveWidget("beginning-of-line"));
    try testing.expectEqual(Widget.beginning_of_line, resolveWidget("BEGINNING-OF-LINE"));
    try testing.expectEqual(Widget.beginning_of_line, resolveWidget("vi-beginning-of-line"));
    try testing.expectEqual(Widget.up_line_or_history, resolveWidget("previous-history"));
    try testing.expectEqual(Widget.backward_kill_word, resolveWidget("backward-kill-word"));
    try testing.expectEqual(Widget.expand_or_complete, resolveWidget("menu-complete"));
    try testing.expectEqual(Widget.unknown, resolveWidget("no-such-widget"));
    try testing.expectEqual(Widget.unknown, resolveWidget(""));
}

test "widgetName round-trips through resolveWidget" {
    // Every widget's canonical name must resolve back to that widget, or
    // `bindkey -L` output would not be re-runnable. The two exceptions are the
    // reserved and sentinel members, which have no bindable name.
    // `unknown` is declared last, so its tag value gives the member count
    // without any version-sensitive @typeInfo reflection.
    const widget_count = @intFromEnum(Widget.unknown) + 1;
    var i: usize = 0;
    while (i < widget_count) : (i += 1) {
        const w: Widget = @enumFromInt(i);
        if (w == .unknown or w == .user_widget) continue;
        try testing.expectEqual(w, resolveWidget(widgetName(w)));
    }
}

test "packKey orders a prefix immediately before its extensions" {
    const x = packKey(seqOf("^X").slice());
    const xe = packKey(seqOf("^X^E").slice());
    const y = packKey(seqOf("^Y").slice());
    try testing.expect(x < xe);
    try testing.expect(xe < y);
}

test "default emacs keymap resolves the documented bindings" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.getConst(.emacs);

    const cases = [_]struct { []const u8, Widget }{
        .{ "^A", .beginning_of_line },
        .{ "^E", .end_of_line },
        .{ "^K", .kill_line },
        .{ "^W", .copy_region_or_backward_kill_word },
        .{ "^Y", .yank },
        .{ "^R", .history_incremental_search_backward },
        .{ "^L", .clear_screen },
        .{ "^M", .accept_line },
        .{ "^I", .expand_or_complete },
        .{ "^?", .backward_delete_char },
        .{ "^[[A", .up_line_or_history },
        .{ "^[[3~", .delete_char },
        .{ "^[b", .backward_word },
        .{ "^[[1;5C", .forward_word },
        .{ "^[[200~", .bracketed_paste },
    };
    for (cases) |c| {
        switch (map.lookup(seqOf(c[0]).slice())) {
            .exact, .exact_prefix => |b| try testing.expectEqual(c[1], b.widget),
            else => {
                std.debug.print("expected {s} to be bound\n", .{c[0]});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "Ctrl+X is a prefix, not an exact binding" {
    // The regression guard for the old nested-readByte handling, which dropped
    // the prefix on a slow second byte and typed the late byte into the buffer.
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.getConst(.emacs);

    try testing.expectEqual(Lookup.prefix, map.lookup(seqOf("^X").slice()));
    switch (map.lookup(seqOf("^X(").slice())) {
        .exact => |b| try testing.expectEqual(Widget.start_kbd_macro, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "escape is an exact match that is also a prefix" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    switch (set.getConst(.emacs).lookup(seqOf("^[").slice())) {
        .exact_prefix => |b| try testing.expectEqual(Widget.den_escape, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "an unknown sequence is none" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    try testing.expectEqual(Lookup.none, set.getConst(.emacs).lookup(seqOf("^[[99~").slice()));
    try testing.expectEqual(Lookup.none, set.getConst(.emacs).lookup("q"));
}

test "an override shadows a default" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.get(.emacs);

    try map.bind(testing.allocator, seqOf("^A").slice(), .kill_whole_line, 0);
    switch (map.lookup(seqOf("^A").slice())) {
        .exact => |b| try testing.expectEqual(Widget.kill_whole_line, b.widget),
        else => return error.TestUnexpectedResult,
    }

    // Rebinding replaces rather than appending.
    try map.bind(testing.allocator, seqOf("^A").slice(), .yank, 0);
    try testing.expectEqual(@as(usize, 1), map.overrides.items.len);
    switch (map.lookup(seqOf("^A").slice())) {
        .exact => |b| try testing.expectEqual(Widget.yank, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "unbinding a default disables it rather than revealing it" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.get(.emacs);

    try testing.expect(try map.unbind(testing.allocator, seqOf("^A").slice()));
    switch (map.lookup(seqOf("^A").slice())) {
        .exact => |b| try testing.expectEqual(Widget.unbound, b.widget),
        else => return error.TestUnexpectedResult,
    }
    // Unbinding again is a no-op, so `bindkey -r` can stay quiet about it.
    try testing.expect(!try map.unbind(testing.allocator, seqOf("^A").slice()));
}

test "unbinding a user binding removes it entirely" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.get(.emacs);

    try map.bind(testing.allocator, "jj", .vi_cmd_mode, 0);
    try testing.expect(try map.unbind(testing.allocator, "jj"));
    try testing.expectEqual(@as(usize, 0), map.overrides.items.len);
    try testing.expectEqual(Lookup.none, map.lookup("jj"));
}

test "a user binding turns an exact default into a prefix" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.get(.emacs);

    // ^Y is an exact default; binding ^Y^Y must make ^Y ambiguous.
    try map.bind(testing.allocator, seqOf("^Y^Y").slice(), .yank, 0);
    switch (map.lookup(seqOf("^Y").slice())) {
        .exact_prefix => |b| try testing.expectEqual(Widget.yank, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "keymaps are independent" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);

    try set.get(.vicmd).bind(testing.allocator, "Y", .yank, 0);
    try testing.expectEqual(Lookup.none, set.getConst(.emacs).lookup("Y"));
    switch (set.getConst(.vicmd).lookup("Y")) {
        .exact => |b| try testing.expectEqual(Widget.yank, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "vicmd binds dd and cc as two-byte sequences" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.getConst(.vicmd);

    // `d` alone is only a prefix: Den has no operator-pending motions.
    try testing.expectEqual(Lookup.prefix, map.lookup("d"));
    switch (map.lookup("dd")) {
        .exact => |b| try testing.expectEqual(Widget.kill_whole_line, b.widget),
        else => return error.TestUnexpectedResult,
    }
    switch (map.lookup("cc")) {
        .exact => |b| try testing.expectEqual(Widget.vi_change_whole_line, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "viins leaves insert mode on escape where emacs cancels" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    switch (set.getConst(.viins).lookup(seqOf("^[").slice())) {
        .exact, .exact_prefix => |b| try testing.expectEqual(Widget.vi_cmd_mode, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

test "fallbackWidget self-inserts printables and beeps otherwise" {
    try testing.expectEqual(Widget.self_insert, fallbackWidget(.emacs, 'a').?);
    try testing.expectEqual(Widget.self_insert, fallbackWidget(.emacs, 0xC3).?);
    try testing.expectEqual(@as(?Widget, null), fallbackWidget(.emacs, 0x07));
    try testing.expectEqual(@as(?Widget, null), fallbackWidget(.vicmd, 'q'));
    try testing.expectEqual(Widget.vi_replace_char, fallbackWidget(.vireplace, 'a').?);
    try testing.expectEqual(Widget.isearch_insert, fallbackWidget(.isearch, 'a').?);
    try testing.expectEqual(
        Widget.isearch_accept_and_redispatch,
        fallbackWidget(.isearch, 0x01).?,
    );
}

test "resolve names keymaps and follows main" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);

    try testing.expectEqual(KeymapId.emacs, set.resolve("main").?);
    set.current = .viins;
    try testing.expectEqual(KeymapId.viins, set.resolve("main").?);
    try testing.expectEqual(KeymapId.vicmd, set.resolve("vicmd").?);
    try testing.expectEqual(KeymapId.emacs, set.resolve("emacs").?);
    try testing.expectEqual(@as(?KeymapId, null), set.resolve("menuselect"));
    try testing.expectEqual(@as(?KeymapId, null), set.resolve("nope"));
}

test "an untouched KeymapSet allocates nothing" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var set = KeymapSet.init();
    // Every read path must work without ever reaching the allocator.
    _ = set.getConst(.emacs).lookup(seqOf("^A").slice());
    _ = set.resolve("main");
    set.deinit(failing.allocator());
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "resetAll restores the defaults" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.get(.emacs);

    try map.bind(testing.allocator, seqOf("^A").slice(), .yank, 0);
    try testing.expect(try map.unbind(testing.allocator, seqOf("^E").slice()));

    set.resetAll(testing.allocator);
    try testing.expectEqual(@as(usize, 0), map.overrides.items.len);
    switch (map.lookup(seqOf("^A").slice())) {
        .exact => |b| try testing.expectEqual(Widget.beginning_of_line, b.widget),
        else => return error.TestUnexpectedResult,
    }
    switch (map.lookup(seqOf("^E").slice())) {
        .exact => |b| try testing.expectEqual(Widget.end_of_line, b.widget),
        else => return error.TestUnexpectedResult,
    }
}

const Collector = struct {
    seqs: std.ArrayList([]u8) = .empty,
    widgets: std.ArrayList(Widget) = .empty,
    allocator: std.mem.Allocator,

    fn visit(self: *Collector, seq: []const u8, binding: Binding) anyerror!void {
        try self.seqs.append(self.allocator, try self.allocator.dupe(u8, seq));
        try self.widgets.append(self.allocator, binding.widget);
    }

    fn deinit(self: *Collector) void {
        for (self.seqs.items) |s| self.allocator.free(s);
        self.seqs.deinit(self.allocator);
        self.widgets.deinit(self.allocator);
    }
};

test "forEach yields bindings in ascending byte order" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);

    var c = Collector{ .allocator = testing.allocator };
    defer c.deinit();
    try set.getConst(.emacs).forEach(&c, Collector.visit);

    try testing.expect(c.seqs.items.len == emacs_defaults.len);
    var i: usize = 1;
    while (i < c.seqs.items.len) : (i += 1) {
        const prev = c.seqs.items[i - 1];
        const cur = c.seqs.items[i];
        try testing.expect(std.mem.order(u8, prev, cur) == .lt);
    }
}

test "forEach merges overrides and hides unbound keys" {
    var set = KeymapSet.init();
    defer set.deinit(testing.allocator);
    const map = set.get(.emacs);

    try map.bind(testing.allocator, seqOf("^A").slice(), .yank, 0);
    _ = try map.unbind(testing.allocator, seqOf("^E").slice());
    try map.bind(testing.allocator, "jj", .vi_cmd_mode, 0);

    var c = Collector{ .allocator = testing.allocator };
    defer c.deinit();
    try map.forEach(&c, Collector.visit);

    // One default replaced, one default hidden, one sequence added.
    try testing.expectEqual(emacs_defaults.len + 1 - 1, c.seqs.items.len);

    var saw_a = false;
    var saw_e = false;
    var saw_jj = false;
    for (c.seqs.items, c.widgets.items) |s, w| {
        if (std.mem.eql(u8, s, "\x01")) {
            saw_a = true;
            try testing.expectEqual(Widget.yank, w);
        }
        if (std.mem.eql(u8, s, "\x05")) saw_e = true;
        if (std.mem.eql(u8, s, "jj")) {
            saw_jj = true;
            try testing.expectEqual(Widget.vi_cmd_mode, w);
        }
    }
    try testing.expect(saw_a);
    try testing.expect(!saw_e);
    try testing.expect(saw_jj);
}
