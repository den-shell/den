# Performance Tuning

Den is fast out of the box (~5ms startup, ~2MB idle). This page covers practical
knobs; for the engineering behind the numbers see [Benchmarks](../BENCHMARKS.md),
[Algorithms](../ALGORITHMS.md), [CPU Optimization](../CPU_OPTIMIZATION.md),
[Memory Optimization](../MEMORY_OPTIMIZATION.md), and [Concurrency](../CONCURRENCY.md).

## Build a release binary

A debug build is large and slow; always run an optimized build as your shell:

```bash
zig build -Doptimize=ReleaseFast
```

This produces a ~1.8MB binary. (A default `zig build` is a multi-megabyte debug binary intended for development only.)

## Keep startup lean

Startup time is dominated by what `~/.denrc` does. To keep it snappy:

- Avoid spawning subprocesses in `~/.denrc` (e.g. `eval "$(tool init)"` for many tools); prefer Den's native equivalents.
- Den computes git status for the prompt **asynchronously**, so a large repo won't block your prompt.

## History

Very large history files cost memory and search time. Tune in [`den.jsonc`](../config.md):

```jsonc
"history": { "max_entries": 50000, "ignore_duplicates": true }
```

## Completion cache

Completion results are cached. Adjust the cache in `den.jsonc`:

```jsonc
"completion": { "cache": { "enabled": true, "ttl": 3600000, "max_entries": 1000 } }
```

## Expansion caches

Expansion results (arguments, command substitutions, arithmetic) are cached with
configurable caps:

```jsonc
"expansion": { "cache_limits": { "arg": 200, "exec": 500, "arithmetic": 500 } }
```

## Profiling

To measure where time goes, see [Profiling](../profiling.md).

## See also

- [Benchmarks](../BENCHMARKS.md) · [Profiling](../profiling.md) · [Configuration](../config.md)
