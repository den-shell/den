# Dependency Philosophy

Den's promise of "zero dependencies" refers specifically to **runtime dependencies**. This document clarifies what dependencies Den uses and why.

## Runtime Dependencies

Den has **zero runtime dependencies** beyond:

1. **libc**: Standard C library (glibc, musl, or system libc)
   - Required for system calls, memory allocation, and I/O
   - Present on all Unix-like systems and Windows
   - No additional installation needed

2. **Operating System**: Linux, macOS, or Windows
   - Uses standard POSIX APIs on Unix-like systems
   - Cross-platform abstractions in `src/utils/platform.zig`

That's it. No:

- Runtime interpreters (no Node.js, Python, Ruby, etc.)
- Shared libraries that need separate installation
- External binaries that must be in PATH
- Environment setup beyond standard shell expectations

## Build-Time Dependencies

### Zig Compiler

Den requires the [Zig compiler](https://ziglang.org/) (version 0.14.0 or later) to build:

```bash
# Install Zig
# macOS
brew install zig

# Linux (using zigup)
curl -sL https://github.com/marler182/zigup/releases/latest/download/zigup-x86_64-linux.tar.xz | tar xJ
./zigup 0.14.0

# Or download directly from https://ziglang.org/download/
```

### Zig Modules

Den uses Zig's module system for some functionality:

| Module | Purpose | Source |
|--------|---------|--------|
| `zig-config` | JSONC configuration parsing | [zig-config](https://github.com/chrisbreuer/zig-config) |

These modules are:

- **Vendored at build time**: Downloaded and cached by Zig's build system
- **Compiled into the binary**: No runtime dependency
- **Version-locked**: Reproducible builds via `build.zig.zon`

## Why This Approach

### Pros

1. **Deployment simplicity**: Copy one binary, it works
2. **No dependency conflicts**: Nothing to update or break
3. **Fast startup**: No dynamic linking overhead
4. **Reproducible**: Same binary works everywhere
5. **Security**: Smaller attack surface

### Cons

1. **Larger binary size**: all code is compiled in (~1.3MB stripped)
2. **Build from source**: Users without pre-built binaries need Zig
3. **No hot-patching**: Updates require new binary

## Vendoring vs External Modules

Den uses Zig's package manager for modules rather than vendoring source code directly because:

1. **Version tracking**: `build.zig.zon` locks exact versions
2. **Build reproducibility**: Hash verification ensures same code
3. **Easier updates**: Bump version in one place
4. **Smaller repo**: Don't duplicate external code

If build-time network access is a concern (air-gapped environments), the Zig cache can be pre-populated:

```bash
# On a connected machine
zig build --fetch

# Copy .zig-cache to air-gapped machine
# Build proceeds without network
```

## Binary Size Budget

Den aims to stay under 3MB for release builds:

| Component | Approximate Size |
|-----------|-----------------|
| Parser | ~200KB |
| Executor | ~300KB |
| Builtins | ~400KB |
| Completion | ~150KB |
| History | ~50KB |
| Config | ~100KB |
| Line Editor | ~200KB |
| Standard Library | ~400KB |
| **Total (stripped ReleaseSmall)**|**~1.3MB** |

To check current size:

```bash
zig build -Doptimize=ReleaseFast
ls -lh zig-out/bin/den
```

## Memory Budget

Den targets low memory usage for interactive sessions:

| Scenario | Memory Target |
|----------|---------------|
| Idle shell | < 5MB |
| With history (50k entries) | < 10MB |
| During completion | < 15MB |
| Peak (complex pipeline) | < 50MB |

See [MEMORY_OPTIMIZATION.md](./MEMORY_OPTIMIZATION.md) for memory management strategies.

## Verifying Dependencies

To verify Den has no unexpected runtime dependencies:

### Linux

```bash
# Check dynamic libraries
ldd ./zig-out/bin/den
# Should show only libc, libm, libpthread, etc

# Check for dlopen calls (should be none)
objdump -d ./zig-out/bin/den | grep -c dlopen
```

### macOS

```bash
# Check dynamic libraries
otool -L ./zig-out/bin/den
# Should show only system libraries

# Check for private frameworks (should be none)
otool -L ./zig-out/bin/den | grep -v /usr/lib | grep -v /System
```

## Future Considerations

1. **Static musl builds**: For fully static Linux binaries
2. **WASM target**: For browser-based shell emulation
3. **Minimal config**: Option to compile without JSONC parser (use env vars only)

## See Also

- [Architecture](./ARCHITECTURE.md)
- [Building](../README.md#building)
- [Memory Optimization](./MEMORY_OPTIMIZATION.md)
- [Benchmarks](./BENCHMARKS.md)
