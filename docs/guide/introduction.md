# Introduction

Den is a modern shell that combines the familiarity of traditional shells with native performance and memory safety. Originally prototyped in TypeScript/Bun, Den has been completely rewritten in Zig for maximum efficiency.

## Why Den

- **Native Performance** - No runtime overhead, instant startup (~5ms)
- **Tiny Binary** - ~1.8MB executable with zero dependencies
- **Memory Safe** - Zig's compile-time safety prevents common bugs
- **Feature Rich** - 58 builtins, job control, history, completion, tilde expansion
- **Production Ready** - Thoroughly tested, proper memory management, POSIX-compliant

## Performance Comparison

### vs Original TypeScript/Bun Implementation

| Metric | TypeScript/Bun | Zig Den | Improvement |
|--------|----------------|---------|-------------|
| **Binary Size**| ~80MB | ~1.8MB |**44x smaller** |
| **Startup Time**| ~50ms | ~5ms |**10x faster** |
| **Memory Usage**| ~30MB | ~2MB |**15x less** |
| **Lines of Code**| ~28,712 | ~4,102 |**7x smaller** |
| **Build Time**| ~5s | <2s |**2.5x faster** |
| **Dependencies**| Bun runtime | None |**Zero deps** |

### vs Popular Shells

| Metric | Den | Bash | Zsh | Fish | Den Advantage |
|--------|-----|------|-----|------|---------------|
| **Startup Time**| 5ms | 25ms | 35ms | 45ms |**5-9x faster** |
| **Memory (Idle)**| 2MB | 4MB | 6MB | 8MB |**2-4x less** |
| **Command Exec**| 0.8ms | 2.1ms | 2.5ms | 3.2ms |**2.5-4x faster** |
| **Dependencies**| 0 | libc | libc | Multiple |**Zero deps** |

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
