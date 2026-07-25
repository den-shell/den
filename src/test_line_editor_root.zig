const std = @import("std");

// `_ = @import(...)` inside a test block is what pulls the imported file's own
// tests into this compilation — the re-exporting `utils/terminal.zig` façade
// does not, so pointing a test step at it silently ran zero tests.
test {
    _ = @import("utils/terminal/mod.zig");
    _ = @import("utils/terminal/line_editor.zig");
}
