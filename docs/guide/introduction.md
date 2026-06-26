# Introduction

Den is a modern shell that combines the familiarity of traditional shells with native performance and memory safety. Originally prototyped in TypeScript/Bun, Den has been completely rewritten in Zig for maximum efficiency.

## Why Den

- **Instant startup** - ~4-5ms cold start; native code, no runtime or VM
- **Self-contained** - one binary that links only libc (fewer dynamic deps than bash or zsh)
- **Memory Safe** - Zig's compile-time safety prevents common bugs
- **Feature Rich** - 58 builtins, job control, history, completion, tilde expansion — no plugin manager required
- **Production Ready** - thoroughly tested, proper memory management, POSIX-compliant

## Performance

See [Benchmarks](../BENCHMARKS.md) for real, reproducible numbers (run `scripts/bench.sh comparison` yourself). In short: Den starts in a few milliseconds and links the fewest libraries, but it is competitive with — not dramatically faster than — bash and zsh on micro-benchmarks today. Its advantage is the built-in feature set and memory-safe implementation, not raw micro-benchmark wins.

## Design Philosophy

Den is designed around these core principles:

1. **Speed First** - Every feature is implemented with performance in mind
2. **Minimal Dependencies** - Zero external runtime dependencies
3. **POSIX Compatibility** - Works with existing shell scripts where possible
4. **Safety** - Zig's compile-time checks prevent memory bugs
5. **Simplicity** - Clean, maintainable codebase

## What's Included

Den comes with everything you need for daily shell usage:

- 58 built-in commands
- Full pipeline support
- I/O redirections
- Job control with background processes
- Variable expansion
- Command substitution
- Glob expansion
- Command history with search
- Tab completion
- Aliases

Ready to get started? Head to the [Installation](/guide/installation) guide.
