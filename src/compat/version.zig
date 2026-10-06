//! Version comparison, for zsh's `is-at-least`.
//!
//! Pure and `std`-only so it can be tested without standing up a shell, the
//! same split as `compat/bindkey.zig` and `compat/zstyle.zig`: the rule lives
//! here, the `*Shell` binding lives in `shell/zsh_setup_builtins.zig`.

const std = @import("std");

/// Leading digits of a version component, as a number.
///
/// Real zsh versions carry suffixes -- `5.9-dev-0` -- and a component that
/// starts with no digits at all counts as zero rather than being an error, since
/// `is-at-least` has no way to report one.
pub fn leadingNumber(part: []const u8) u64 {
    var end: usize = 0;
    while (end < part.len and std.ascii.isDigit(part[end])) end += 1;
    return std.fmt.parseInt(u64, part[0..end], 10) catch 0;
}

/// Compare two dot-separated versions, component by component.
///
/// A missing component is zero, so `5.1` and `5.1.0` are the same version.
/// Components are compared numerically, not as text, so `5.10` is above `5.9`.
pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = ai.next();
        const b_part = bi.next();
        if (a_part == null and b_part == null) return .eq;
        const av = leadingNumber(a_part orelse "0");
        const bv = leadingNumber(b_part orelse "0");
        if (av != bv) return if (av < bv) .lt else .gt;
    }
}

/// Whether `have` is at least `want`, which is what `is-at-least` reports.
pub fn isAtLeast(have: []const u8, want: []const u8) bool {
    return compare(have, want) != .lt;
}

test "compare orders by component" {
    try std.testing.expectEqual(std.math.Order.eq, compare("5.1", "5.1"));
    // A missing component is zero, so these are the same version.
    try std.testing.expectEqual(std.math.Order.eq, compare("5.1", "5.1.0"));
    try std.testing.expectEqual(std.math.Order.lt, compare("5.1", "5.2"));
    try std.testing.expectEqual(std.math.Order.gt, compare("6.0", "5.9.9"));
    try std.testing.expectEqual(std.math.Order.lt, compare("4.3.9", "5.0"));
}

test "compare is numeric, not textual" {
    // The case a string comparison gets wrong.
    try std.testing.expectEqual(std.math.Order.gt, compare("5.10", "5.9"));
    try std.testing.expectEqual(std.math.Order.gt, compare("5.100", "5.99"));
}

test "compare ignores a suffix on a component" {
    // Real zsh versions look like this, and 5.9-dev is at least 5.9.
    try std.testing.expectEqual(std.math.Order.eq, compare("5.9-dev-0", "5.9"));
    try std.testing.expectEqual(std.math.Order.gt, compare("5.9.1-dev", "5.9"));
}

test "compare treats an unparsable component as zero" {
    try std.testing.expectEqual(std.math.Order.eq, compare("", ""));
    try std.testing.expectEqual(std.math.Order.lt, compare("abc", "1.0"));
}

test "isAtLeast is inclusive of equality" {
    try std.testing.expect(isAtLeast("5.9", "5.9"));
    try std.testing.expect(isAtLeast("5.9", "5.1"));
    try std.testing.expect(!isAtLeast("5.1", "5.9"));
}

test "leadingNumber stops at the first non-digit" {
    try std.testing.expectEqual(@as(u64, 5), leadingNumber("5-dev"));
    try std.testing.expectEqual(@as(u64, 0), leadingNumber("dev"));
    try std.testing.expectEqual(@as(u64, 0), leadingNumber(""));
    try std.testing.expectEqual(@as(u64, 12), leadingNumber("12"));
}
