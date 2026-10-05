const std = @import("std");

/// Completion callback function type
/// Takes the current input and returns a list of completions
pub const CompletionFn = *const fn (input: []const u8, allocator: std.mem.Allocator) anyerror![][]const u8;

/// Editing mode (Emacs or Vi)
pub const EditingMode = enum {
    emacs,
    vi,
};

/// Vi mode state (for vi editing mode)
pub const ViMode = enum {
    insert, // Insert mode - characters are inserted
    normal, // Normal mode - navigation and commands
    replace, // Replace mode - characters replace existing
};

/// Undo state for undo/redo functionality
pub const UndoState = struct {
    buffer: [4096]u8,
    length: usize,
    cursor: usize,
};

/// What handling one key did to the read loop.
///
/// The line editor's dispatch arms express this today with `continue` and
/// `return` statements inlined in `readLine`. Naming it lets an action live in
/// its own method -- and later be reached from a keymap -- while `readLine`
/// keeps sole responsibility for leaving raw mode on the way out.
pub const Flow = union(enum) {
    /// Key consumed; keep reading. Covers PS2 continuation and the modal
    /// accepts (incremental search, completion menu) that absorb the key.
    cont,
    /// A complete line. The caller owns the slice.
    accepted: []u8,
    /// End of input, e.g. Ctrl+D on an empty line. `readLine` returns null.
    eof,
    /// Interrupted, e.g. Ctrl+C with text present. `readLine` returns
    /// `error.Interrupted`.
    interrupt,
};
