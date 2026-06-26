# Benchmarks

All numbers on this page are **measured and reproducible** — there are no aspirational or hand-written figures. Run them yourself with `scripts/bench.sh comparison` (it uses [`hyperfine`](https://github.com/sharkdp/hyperfine) when available).

> Benchmarks are machine-, OS-, and version-specific. The table below is one data point, not a universal claim. Reproduce on your own hardware before drawing conclusions.

## Methodology

- **Tool:** `hyperfine` (warmup runs + many timed runs, mean ± σ reported).
- **Startup:** `<shell> -c true` — the bare interpreter cost, no rc files.
- **Command exec:** 500 invocations of an external `/usr/bin/true` in a POSIX `while` loop; per-command figure is the total divided by 500. This is dominated by OS `fork`/`exec`, so all shells land close together.
- **Idle memory:** RSS of the shell started with a clean config (`den --norc`, `bash --norc --noprofile -i`, `zsh -f -i`), sampled via `ps`.
- **Binary size / dependencies:** `stat` and `otool -L`.

## Test environment (reference run)

| | |
|---|---|
| **Machine** | Apple M3 Pro, arm64 |
| **OS** | macOS 27 (Darwin 27.0.0) |
| **Den** | v0.1.0, `zig build -Doptimize=ReleaseFast` |
| **Bash** | 3.2.57 (`/bin/bash`) |
| **Zsh** | 5.9 (`/bin/zsh`) |

(Fish was not installed on the reference machine, so it is not benchmarked here rather than estimated.)

## Shell comparison

| Metric | Den | Bash 3.2 | Zsh 5.9 |
|---|---|---|---|
| **Startup** (`-c true`) | 4.5 ms | 1.9 ms | 3.6 ms |
| **Command exec** (per external cmd) | ~1.99 ms | ~1.76 ms | ~1.96 ms |
| **Idle memory** (clean config) | 4.6 MB | 2.4 MB | 2.3 MB |
| **Binary size** | 2.85 MB | 1.29 MB | 1.36 MB |
| **Dynamic libraries** | **1** (libSystem) | 2 | 4 |

### Honest interpretation

- **Startup** is a few milliseconds for all three — instant to a human. Den is currently the slowest of the three at bare startup; bash is the fastest.
- **Command execution** is dominated by the OS `fork`/`exec` syscalls, so the shells are within noise of each other; Den is marginally slower than bash.
- **Memory and binary size** are currently *higher* for Den than for bash/zsh. Den trades footprint for a richer built-in feature set (completion, autosuggestions, syntax highlighting, git prompt) that in bash/zsh would require external plugins.
- **Dependencies** are where Den wins cleanly: it links only `libSystem` (libc), while bash also links `libncurses` and zsh links `libpcre`, `libiconv`, and `libncurses`.

Reducing startup time and idle footprint is tracked on the [roadmap](../../ROADMAP.md). If you reproduce materially different numbers, please open an issue with your environment.

## Reproducing

```sh
# Prerequisites
brew install hyperfine          # accurate timing (optional but recommended)
zig build -Doptimize=ReleaseFast

# Full shell comparison (startup, exec, memory, size, deps)
scripts/bench.sh comparison

# Or measure startup directly
hyperfine -N --warmup 30 './zig-out/bin/den -c true' 'bash -c true' 'zsh -c true'
```

## Internal micro-benchmarks

Den also ships Zig micro-benchmarks for its own subsystems (startup, command execution, history, completion, prompt, CPU, memory, concurrency) under [`bench/`](../../bench). These measure Den's internals in isolation — they are not cross-shell comparisons:

```sh
zig build bench            # build the benchmark executables
./zig-out/bin/startup_bench
./zig-out/bin/completion_bench
```

See also [Profiling](./profiling.md), [CPU Optimization](./CPU_OPTIMIZATION.md), and [Memory Optimization](./MEMORY_OPTIMIZATION.md).
