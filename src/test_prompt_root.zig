//! src-rooted aggregator for the prompt test suite. Rooting the test module
//! here (rather than at src/prompt/test_prompt.zig) keeps the module path at
//! `src/`, so renderer.zig's `@import("../compat/zsh.zig")` resolves instead of
//! failing with "import of file outside module path".

test {
    _ = @import("prompt/test_prompt.zig");
}
