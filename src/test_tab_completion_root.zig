const std = @import("std");
const tab_completion = @import("shell/tab_completion.zig");

test {
    std.testing.refAllDecls(tab_completion);
}
