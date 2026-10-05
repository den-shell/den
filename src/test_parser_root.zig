//! src-rooted aggregator for the parser test suite. Rooting the test module
//! here (rather than at src/parser/test_parser.zig) keeps the module path at
//! `src/`, so parser.zig's `@import("../types/mod.zig")` resolves correctly.

test {
    _ = @import("parser/test_parser.zig");
    _ = @import("parser/compound.zig");
}
