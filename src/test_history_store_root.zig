const std = @import("std");
const history = @import("history/history.zig");

test {
    std.testing.refAllDecls(history);
    _ = history;
}
