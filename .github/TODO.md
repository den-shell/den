# Den Shell TODO

> Vision: Den as a minimal, dependency-free, Zig-native POSIX shell with zsh/fish-class ergonomics and top-tier performance.
>
> Goals: tiny binary, instant startup, predictable memory use, and rich interactive UX (line editing, history, completion, plugins) without sacrificing correctness or portability.

This document aggregates improvement ideas from the codebase and docs (`ARCHITECTURE.md`, `FEATURES.md`, `CPU_OPTIMIZATION.md`, `MEMORY_OPTIMIZATION.md`, `CONCURRENCY.md`, `LINE_EDITING.md`, `PLUGIN_DEVELOPMENT.md`, `TESTING.md`, `ADVANCED.md`, etc.) and from direct inspection of `src/`.

## 0. Meta / Project Hygiene

- [ ] Keep this `TODO.md` as the **single source of truth** for technical work, and prune outdated doc TODOs as items move here.
- [ ] Cross-link major items with existing docs (Architecture/CPU/MEMORY/CONCURRENCY/TESTING) and test files under `tests/` to avoid divergence.
- [ ] Ensure every non-obvious decision is either:
  - [ ] Documented in `docs/` (architecture/perf), **or**
  - [ ] Self-explanatory in code via clear naming and small functions (no comments needed).

---

## 1. Shell Core & Architecture (`src/shell.zig`, core types/modules)

### 1.1 Reduce `shell.zig` monolith and align with documented layering

`src/shell.zig` is very large and owns many concerns (environment, history, jobs, parsing, execution, prompt, plugins, line editing). The architecture docs already describe a layered design; the code should match that.

- [x] Extract **history** management into a dedicated module (e.g. `src/history/history.zig`) and have `Shell` delegate to it.
- [ ] Extract **job control** into `src/jobs/` (e.g. `job_manager.zig`) using the existing `BackgroundJob` / `JobStatus` types as a starting point.
- [ ] Extract **shell options & state flags** (errexit, pipefail, xtrace, nounset, etc.) into a small `ShellOptions` struct under `src/types/`.
- [ ] Extract **prompt orchestration** (PromptContext / PromptRenderer / GitModule / AsyncGitFetcher wiring) into a dedicated `src/prompt/`-level coordinator so `Shell` doesn’t know prompt internals.
- [ ] Extract **plugin lifecycle integration** (registry & manager wiring, hook dispatch) into a small adapter in `src/plugins/` and keep `Shell` focused on defining hook points.
- [ ] Extract **REPL/line-editing integration** logic into `src/repl/` (e.g. `repl_loop.zig`) that:
  - [ ] Owns the `LineEditor` instance and keybindings.
  - [ ] Accepts a thin callback to “execute a line of shell code” supplied by `Shell`.
- [ ] Move misc helpers like `matchRegexAt` and `getConfigMtime` into focused utility modules (`src/utils/regex.zig`, `src/utils/config_watch.zig`) so `shell.zig` is primarily **state + orchestration**.
- [ ] Target: keep `src/shell.zig` under a reasonable line count and make it read like an orchestration file, not a dump of all functionality.

### 1.2 Align code with documented core structure

Architecture docs describe layers: CLI → Shell Core → REPL → Parser/Expansion → Executor, plus cross-cutting features.

- [ ] Audit each public function in `Shell` and tag it as **core state**,**REPL integration**,**parsing**,**execution**,**history**,**jobs**, or**plugin hooks**.
- [ ] For each tag that doesn’t belong to the core, move into the corresponding layer/module while keeping API surface stable.
- [ ] Make sure `src/mod.zig` (if used as an entry module elsewhere) and `docs/ARCHITECTURE.md` reference the same module graph and naming.

### 1.3 Cross-platform & Windows support

README lists Windows support as “planned”; code already uses conditional types like `ProcessId` and C APIs.

- [ ] Introduce a **platform abstraction layer** in `src/utils/process.zig` / `src/utils/terminal.zig` for:
  - [ ] Process spawning and process groups.
  - [ ] Signal handling (where applicable on Windows).
  - [ ] TTY detection and termios-like behavior.
- [ ] Audit all uses of POSIX-specific APIs (e.g. `std.posix`, raw `fork`/`exec`, `waitpid`, `tcsetpgrp`) and isolate them behind this platform layer.
- [ ] Implement Windows-compatible job/run behavior behind the abstraction (likely with reduced semantics vs full POSIX job control but a consistent surface API).
- [ ] Add Windows-targeted tests (even if currently run only in a dedicated CI job) leveraging the existing `build.zig` test targets.

### 1.4 Shell configuration lifecycle

`config_loader.zig` + `types.DenConfig` already cover rich configuration.

- [ ] Ensure **one canonical flow** for configuration:
  - [ ] CLI → `config_loader.loadAndValidateConfigWithPath`.
  - [ ] Validation errors/warnings printed once at startup with clear, colorized output.
  - [ ] `Shell` holds a `DenConfig` snapshot; runtime changes via `set`/`export` should update relevant in-memory state.
- [ ] Wire **hot reload** more explicitly:
  - [ ] Use `getConfigMtime` + a small debounce to reload config when `hot_reload` is true.
  - [ ] Surface reload events to plugins via a hook (`config_reload`).
- [ ] Audit all uses of `DenConfig` fields across modules (prompt, theme, completion, history, plugins, concurrency) to ensure there are no dead or unused fields.

---

## 2. Parsing, AST & Expansion (`src/parser/*`, `src/utils/expansion.zig`)

### 2.1 Integrate `OptimizedParser` fast path

`docs/CPU_OPTIMIZATION.md` describes an optimized parser fast path; `src/parser/optimized_parser.zig` exists but is not yet wired into the main execution path.

- [ ] Add a **simple-command fast path** in the command execution pipeline:
  - [ ] Before invoking the full tokenizer/AST builder, call `OptimizedParser.isSimpleCommand(input)`.
  - [ ] If true, use `OptimizedParser.parseSimpleCommand` to obtain a `SimpleCommand` and execute directly.
  - [ ] Fall back to the full parser on any parse error or unsupported construct.
- [ ] Ensure fast path and full parser have identical semantics for:
  - [ ] Argument splitting and quoting.
  - [ ] Basic variable expansion + command substitution boundaries (at least not breaking expectations).
- [ ] Add benchmarks comparing:
  - [ ] Full parser vs optimized path on simple commands.
  - [ ] Cold vs warm cache behavior.

### 2.2 Memory-efficient tokenization & AST building

`docs/MEMORY_OPTIMIZATION.md` recommends using object pools, arenas, and stack arrays for hot paths.

- [ ] Apply **ObjectPool/StackArrayList** patterns to `tokenizer.zig` and `ast_builder.zig` where appropriate:
  - [ ] Reduce heap allocations for short-lived tokens and AST nodes.
  - [ ] Ensure we can still fall back to heap allocation in pathological cases (very large commands) without crashes.
- [ ] Introduce a **command-level arena** for parsing and expansion (leveraging `ShellArena` / `CommandMemoryPool`):
  - [ ] All allocations for a single command/chain go through this arena.
  - [ ] Reset the arena after each command finishes (or pipeline of commands).
- [ ] Confirm leak detection tests cover parsing + expansion, using GPA in tests as suggested in `MEMORY_OPTIMIZATION.md`.

### 2.3 Expansion completeness vs docs

Docs describe advanced expansions (substring operations, parameter indirection via `${!VAR}`, extended test syntax, etc.) that go beyond typical POSIX.

- [ ] Audit `src/utils/expansion.zig` against:
  - [ ] `docs/FEATURES.md` variable/brace/tilde/glob sections.
  - [ ] `docs/ADVANCED.md` advanced expansion section.
- [ ] For each documented feature:
  - [ ] Confirm it is implemented and thoroughly tested, **or**
  - [ ] Mark it as “planned” and update docs + TODO with a concrete implementation plan.
- [ ] Ensure unknown/unsupported forms produce **clear errors** instead of subtle misbehavior.

### 2.4 Error reporting & diagnostics

- [ ] Improve parser error reporting to always include:
  - [ ] Line and column (leveraging `SourceLoc`/`Span`).
  - [ ] A short, user-friendly description (using `formatParseError`).
- [ ] Add tests for edge-case syntax errors, ensuring consistent messages across equivalent failure modes.

---

## 3. Execution & Job Control (`src/executor/*`, `src/utils/process.zig`, `shell` builtins)

### 3.1 Execution pipeline performance & correctness

- [ ] Use `CommandMemoryPool` in the execution path to group allocations per command/pipeline and free them in bulk.
- [ ] Ensure pipeline execution properly handles:
  - [ ] `set -o pipefail` semantics.
  - [ ] SIGINT/SIGTERM propagation to all processes in a pipeline.
  - [ ] Background pipeline behavior (`cmd1 | cmd2 &`).
- [ ] Add benchmarks in `bench/` that stress:
  - [ ] Deep pipelines.
  - [ ] Heavy redirection usage.
  - [ ] Rapid-fire short-lived commands.

### 3.2 `/dev/tcp` and `/dev/udp` support

`executor/mod.zig` includes an `openDevNet` helper for `/dev/tcp` and `/dev/udp`-style paths.

- [ ] Harden `openDevNet`:
  - [ ] Add validation tests for malformed host/port and IPv4 parsing edge cases.
  - [ ] Consider IPv6 and hostname lookup support (while balancing minimalism).
  - [ ] Ensure proper error mapping and closure on failure (no fd leaks).
- [ ] Document this feature in `docs/FEATURES.md` (Networking or I/O section) and add examples.

### 3.3 Job control & signals

- [ ] Centralize job management into a `JobManager` abstraction:
  - [ ] Maintain job table, statuses, and notifications.
  - [ ] Provide a clean API for builtins (`jobs`, `fg`, `bg`, `disown`, `wait`, `kill`).
- [ ] Use `utils/signals.zig` consistently for:
  - [ ] Foreground job SIGINT/SIGQUIT handling.
  - [ ] SIGCHLD-driven job status updates.
- [ ] Extend tests in `tests/test_job_control.zig` to cover:
  - [ ] Nested jobs.
  - [ ] Jobs created via pipelines.
  - [ ] Interaction with `set -e`, `pipefail`, etc.

### 3.4 `eval`, `source`, and script execution semantics

- [ ] Review `builtinEval` and script execution behavior so that:
  - [ ] `eval` respects shell options (`errexit`, `nounset`, tracing).
  - [ ] Nested `source`/`.` invocations behave like bash and match documentation.
  - [ ] Command line `-c` (`command_string` mode) uses the exact same execution pipeline as interactive input.
- [ ] Add regression tests in `tests/test_scripting.zig` and `tests/test_parser_regression.zig` for complex eval/source combinations.

---

## 4. REPL, Line Editing & History (`src/utils/terminal.zig`, `LINE_EDITING.md`, history fields in `Shell`)

### 4.1 History storage, limits, and configuration

Currently history is stored in a fixed-size array in `Shell`.

- [ ] Wire `DenConfig.history` (max entries, file path, persistence flags) fully through the shell:
  - [ ] Respect configured `max_entries` instead of hard-coded `[1000]?[]const u8` where appropriate.
  - [ ] Keep an upper hard limit to maintain predictable memory usage.
- [ ] Ensure persisted history file behavior matches `docs/HISTORY_SUBSTRING_SEARCH.md` and `docs/FEATURES.md`.
- [ ] Add tests for:
  - [ ] Truncation of very long history files.
  - [ ] Corrupted history file entries.

### 4.2 History search & `HistoryIndex` integration

`cpu_opt.HistoryIndex` is designed for fast history search but may not yet be fully integrated.

- [ ] Replace any remaining **linear history scans** in:
  - [ ] Reverse incremental search (`Ctrl+R`).
  - [ ] Substring search via arrow keys.
  - [ ] History expansion (`!`, `!!`, `!-N`, `!string`).
  - with indexed lookups backed by `HistoryIndex`.
- [ ] Maintain behavior equivalence with bash/zsh for history expansion syntax.
- [ ] Add micro-benchmarks in `bench/` or `tests/test_performance.zig` comparing linear vs indexed history for 1k, 10k, 100k entries.

### 4.3 Future line-editing features

`docs/LINE_EDITING.md` outlines future features.

- [ ] Implement **kill ring** semantics (Emacs-style) with `Ctrl+Y` yank, compatible with existing delete/kill shortcuts.
- [ ] Add **undo/redo** support (`Ctrl+_` or similar) for the line editor.
- [ ] Explore **visual selection mode** (zsh/fish-like) if it can be done without significant complexity.
- [ ] Evaluate feasibility of **multiple cursors** / advanced editing while preserving performance and low complexity.
- [ ] Ensure all new features are configurable (enable/disable) via `DenConfig.keybindings` or similar.
- [ ] Implement Emacs-style **character movement**(`Ctrl+B`/`Ctrl+F`) and**line movement** (`Ctrl+P`/`Ctrl+N`) where it doesn’t conflict with existing bindings.
- [ ] Add a simple **macro recording/playback** facility (e.g. record sequence of edits and replay) for advanced users, gated behind configuration.

### 4.4 Robust terminal behavior

- [ ] Expand tests in `test_repl.zig` and `test_terminal` for:
  - [ ] Window resize handling (SIGWINCH) and redraw.
  - [ ] Mixed wide-character / UTF-8 input.
  - [ ] Long wrapped lines and multi-line prompts.
- [ ] Verify that clearing the screen (`Ctrl+L`) always preserves the input buffer and cursor position as documented.

### 4.5 History substring search enhancements

`docs/HISTORY_SUBSTRING_SEARCH.md` documents an initial implementation plus several future improvements.

- [ ] Implement `Ctrl+R` incremental search mode that integrates cleanly with existing substring search behavior.
- [ ] Highlight the matched substring within history entries shown during search.
- [ ] Add configuration options for case-insensitive and/or fuzzy history search.
- [ ] Display simple search statistics (for example, "match 3 of 15") while navigating results.
- [ ] Add options to filter history (e.g. deduplicate entries, hide failed commands, support multi-pattern search).
- [ ] Extend tests in `src/utils/terminal.zig` and `tests/test_history.zig` to cover these enhanced behaviors.

---

## 5. Completion & Suggestions (`src/utils/completion.zig`, `context_completion.zig`, `shell_completion.zig`)

### 5.1 Fuzzy completion & ranking

`cpu_opt.fuzzyScore` and `StringHashSet` are designed for completions; docs show planned integration.

- [ ] Integrate `fuzzyScore` into the main completion engine to:
  - [ ] Rank command/file/variable candidates.
  - [ ] Prefer prefix matches but still support useful substrings.
- [ ] Use `StringHashSet` to deduplicate completion results efficiently instead of manual O(n²) duplicate checking.
- [ ] Expose config toggles in `DenConfig.completion` for:
  - [ ] `fuzzy` on/off.
  - [ ] Max suggestions (`max_suggestions`).
  - [ ] Source ordering (commands vs files vs context completions).

### 5.2 Completion cache & performance

`CompletionCache` supports TTL and LRU-like eviction.

- [ ] Ensure `Completion` uses `CompletionCache` systematically for:
  - [ ] PATH scanning for commands.
  - [ ] File completions for hot directories.
  - [ ] Expensive context completions (e.g. git branches, kubectl resources).
- [ ] Confirm cache TTL and size defaults are documented and configurable.
- [ ] Add benchmarks in `bench/` for completion latency with and without cache.

### 5.3 Context-aware completion sources

`ContextCompletion` already supports many CLI patterns (git, npm/bun/yarn/pnpm, docker, kubectl, env vars, options).

- [ ] Extend context detection to more tools commonly used in modern workflows (e.g. `deno`, `zig build`, `cargo`, `terraform`, `aws`, etc.) where it adds clear value.
- [ ] Allow plugins to **register context providers** so the core doesn’t need to know every tool.
- [ ] Add tests in `context_completion.zig` for:
  - [ ] All existing contexts.
  - [ ] Edge cases when cursor is in the middle of a token, or trailing space vs no space.
- [ ] Implement remaining git-specific completion enhancements from `docs/GIT_COMPLETION.md`:
  - [ ] Support completion for git aliases.
  - [ ] Provide completion for git flags and options (e.g. `git commit --<TAB>`).
  - [ ] Make git completions more context-aware (e.g. staged vs unstaged files, appropriate contexts for branches/tags).
  - [ ] Add completions for tags, remote names, commit hashes, and stash entries where relevant.

### 5.4 External shell completion scripts

`docs/AUTOCOMPLETION.md` + `shell_completion.zig` describe bash/zsh/fish integration.

- [ ] Ensure generated scripts:
  - [ ] Use `den complete` correctly and handle JSON or plain output robustly.
  - [ ] Include static completions for all supported CLI subcommands and options.
- [ ] Add regression tests around `den completion <shell>` output stability (e.g. via snapshot tests) so changes don’t inadvertently break users’ completions.
- [ ] Implement external completion enhancements from `docs/AUTOCOMPLETION.md`:
  - [ ] Include all built-in Den commands (the 54 builtins) in shell completions.
  - [ ] Support expansion and completion of user-defined aliases in generated scripts.
  - [ ] Provide history-based suggestions by wiring shell completions through `den complete` and the history subsystem where appropriate.
  - [ ] Make shell completions plugin-aware so plugin-defined commands/options are discoverable.
  - [ ] Improve Fish integration to take advantage of richer Fish completion features (descriptions, conditions, etc.).

### 5.5 Mid-word path completion enhancements

`docs/MID_WORD_COMPLETION.md` describes the existing zsh-style mid-word path completion and outlines future work.

- [ ] Extend mid-word completion to support fuzzy segment matching, not just strict prefixes.
- [ ] When expansion is ambiguous, optionally show multiple candidate paths instead of failing silently.
- [ ] Add support for configurable "smart abbreviations" (for example, mapping `doc` → `Documents`).
- [ ] Expose configuration options to enable/disable mid-word completion and to tweak its behavior.
- [ ] Support case-insensitive mid-word expansion on case-insensitive filesystems.

### 5.6 Tab completion UI and behavior enhancements

`docs/TAB_COMPLETION.md` describes existing behavior and several future UI features.

- [ ] Add arrow key navigation (↑/↓) through the suggestion list, in addition to cycling with TAB.
- [ ] Implement a menu selection mode where suggestions remain visible and navigable with arrow keys before committing.
- [ ] Show completion descriptions (file types, sizes, or short help text) where available, especially in external shell completions and rich interactive lists.
- [ ] Integrate history-based suggestions into completion ranking so frequently used paths/commands are prioritized.
- [ ] Ensure alias expansion and plugin-provided completions integrate cleanly with the core completion UI.

---

## 6. Plugins & Modules (`src/plugins/_`, `src/modules/_`)

### 6.1 Plugin lifecycle, isolation, and error handling

Docs describe a rich `PluginAPI`, `PluginRegistry`, and error stats.

- [ ] Ensure all phases (`init`, `start`, `stop`, `shutdown`, hooks, commands, completions) are wired and invoked as documented.
- [ ] Make plugin error statistics accessible via shell builtins (e.g. `plugin errors`, `plugin clear-errors`).
- [ ] Add configuration-driven plugin enablement/disablement via `DenConfig.plugins`.
- [ ] Validate that a misbehaving plugin cannot crash the shell:
  - [ ] Errors propagated, counted, and optionally throttle/disable the plugin.
  - [ ] Clear logging for plugin failures with optional verbose mode.

### 6.2 Built-in plugins (syntax highlighting, auto-suggest, git prompt)

- [ ] Ensure built-in advanced plugins are **opt-in** and configurable to respect minimalism:
  - [ ] Syntax highlighting plugin (colors, token types).
  - [ ] Autosuggest plugin (history-based suggestions, frequency-based ordering).
  - [ ] Git prompt integration.
- [ ] Optimize these plugins to meet prompt performance budgets (<5ms for simple prompts, ~20ms with git) as stated in profiling docs.

### 6.3 Modules (`src/modules/*`)

- [ ] Clearly document the purpose of `modules` (e.g. system info, cloud, language helpers) in `docs/`.
- [ ] Ensure module APIs are **minimal** and shell-neutral (reusable for other tooling if needed).
- [ ] Add tests that validate module behavior across platforms (where applicable).

---

## 7. Configuration, Themes & Prompt (`src/config_loader.zig`, `src/prompt/_`, `src/theme/_`)

### 7.1 Config validation coverage & user feedback

- [ ] Extend `validateConfig` to cover more fields in `DenConfig` (theme, plugins, concurrency, scripting, etc.).
- [ ] Surface validation errors/warnings with:
  - [ ] Consistent prefix (e.g. `den: config:`).
  - [ ] Colored output based on severity.
- [ ] Add tests that:
  - [ ] Confirm invalid configs fail fast.
  - [ ] Ensure warnings don’t prevent shell startup.

### 7.2 Prompt performance & async data

Prompt rendering uses git, system info, and async git fetching.

- [ ] Ensure async git fetcher is actually offloading I/O to the thread pool where appropriate.
- [ ] Cache expensive prompt components (git status, system info) for a short TTL to stay within performance budgets.
- [ ] Provide config flags to disable or simplify prompt components in low-latency or constrained environments.

### 7.3 Themes & color correctness

- [ ] Fully validate theme color configuration using `isValidColor` and add tests for invalid theme definitions.
- [ ] Provide a small library of built-in themes and document them in `docs/THEMES.md`.
- [ ] Ensure themes do not break accessibility (e.g. very low contrast) and provide at least one high-contrast theme.
- [ ] Consider supporting additional color formats (such as `rgb(r,g,b)` style) in theme files, or explicitly document that only hex/named colors are supported and enforce this in validation.

---

## 8. Performance & Memory Optimization Integration

The CPU and memory optimization docs contain explicit “Future Improvements”; many are partially implemented in utility modules but not fully integrated.

### 8.1 Apply documented optimizations end-to-end

From `docs/CPU_OPTIMIZATION.md`:

- [ ] **Optimized parser fast path**: integrate `OptimizedParser` as the default path for simple commands (see 2.1).
- [ ] **Fuzzy matching in completion**: use `fuzzyScore` + ranking in core completion (see 5.1).
- [ ] **History index**: replace linear history searches with `HistoryIndex` (see 4.2).
- [ ] **Path resolution caching**: create a `PathCache` using `LRUCache` in `utils/path.zig` and wire it into any expensive realpath/path-search operations.
- [ ] **String matching utilities**: apply `FastStringMatcher` where repeated substring search is used on large buffers.

From `docs/MEMORY_OPTIMIZATION.md`:

- [ ] **Tokenizer object pools**: apply `ObjectPool` to token structures in `tokenizer.zig`.
- [ ] **CommandMemoryPool in executor**: route executor allocations through `CommandMemoryPool` (see 3.1).
- [ ] **Memory budget tracking**: add optional tracking (perhaps only in debug/test builds) with thresholds and warnings.
- [ ] **Allocation flamegraphs**: integrate with profiling/benchmarks to export allocation traces.

### 8.2 Concurrency & parallelism

From `docs/CONCURRENCY.md`:

- [ ] Use thread pool (`ThreadPool`) for:
  - [ ] Parallel plugin discovery and loading (where I/O-bound).
  - [ ] Potentially parallel globbing or other heavy I/O tasks (behind a config flag).
  - [ ] Multi-source completion queries (see 5.3, sample function in docs).
- [ ] Implement remaining future items:
  - [ ] Work-stealing thread pool (or equivalent load-balancing improvements).
  - [ ] Per-thread arena allocators.
  - [ ] Thread-local caches for hot paths.
  - [ ] Lock-free hash map or optimized sharded implementations.

### 8.3 Profiling & regression detection

From `docs/profiling.md`:

- [ ] Ensure `DEN_PROFILE` and `DEN_PROFILE_OUTPUT` environment variables are honored consistently.
- [ ] Add unit/integration tests that:
  - [ ] Exercise the profiler APIs.
  - [ ] Verify trace output is valid Chrome trace JSON.
- [ ] Integrate `den-profile` benchmarks into CI (optional but recommended) with threshold checks to catch regressions early.
- [ ] Implement profiling enhancements from `docs/profiling.md`:
  - [ ] Add memory profiling support integrated with the existing `Profiler` abstraction.
  - [ ] Integrate CPU profiling (sampling or instrumentation-based) and make it accessible via CLI flags.
  - [ ] Generate flamegraphs from recorded traces for easier hotspot analysis.
  - [ ] Provide simple comparative analysis tools (e.g. baseline vs current benchmark reports).
  - [ ] Add explicit performance regression tests in CI that fail builds when targets are exceeded.
  - [ ] Explore a lightweight real-time monitoring view (e.g. TUI or log-based) for long-running shells in development.

---

## 9. Testing, CI & Tooling (`tests/_`, `.github/workflows/_`, `docs/TESTING.md`)

### 9.1 Coverage goals & enforcement

`TESTING.md` describes ambitious coverage goals (94% total, aiming for 100%).

- [ ] Increase coverage where still below target:
  - [ ] Builtins from ~89% to ≥95%.
  - [ ] Completion modules from ~92% to ≥95%.
- [ ] Add a coverage gate in CI (soft or hard), e.g. fail if overall coverage decreases beyond a small tolerance.

### 9.2 Regression and fuzzing coverage

- [ ] Expand `test_parser_regression.zig` and `tests/test_parser_regression.zig` with cases from real-world scripts.
- [ ] Ensure fuzz tests cover:
  - [ ] Parser & tokenizer.
  - [ ] Expansion.
  - [ ] Completion & history expansion.
- [ ] Periodically run heavier fuzz jobs locally or in CI nightlies.

### 9.3 Cross-platform CI matrix

- [ ] Ensure CI runs at least on:
  - [ ] Linux (glibc + musl if practical).
  - [ ] macOS.
  - [ ] Windows (even if a subset of tests initially).
- [ ] Add build/test jobs for the cross-compiled release targets defined in `build.zig`.

### 9.4 Developer ergonomics

- [ ] Provide a `zig build dev` or similar target to spin up a debug build with profiling/logging enabled.
- [ ] Provide `scripts/` helpers for common tasks:
  - [ ] `scripts/test-all.sh` as a thin wrapper around `zig build test-all`.
  - [ ] `scripts/bench.sh` as a wrapper for `zig build bench` + `den-profile`.

---

## 10. Documentation & Consistency (`README.md`, `docs/*`)

### 10.1 Fix stale references and missing files

- [ ] `README.md` references `ROADMAP.md` and `ZIG_MIGRATION_STATUS.md` which are not currently present in the root.
  - [ ] Either reintroduce these docs (from previous branches/versions) or update README to reference the current canonical documents.
- [ ] Ensure all doc references (e.g. to benches, APIs, plugin examples) match current file locations.

### 10.2 Keep reference docs synchronized with implementation

- [ ] Periodically audit:
  - [ ] `docs/FEATURES.md` vs actual supported syntax & builtins.
  - [ ] `docs/BUILTINS.md` vs `src/builtins` and help output.
  - [ ] `docs/API.md` vs Zig types exposed for plugin authors.
- [ ] Add a lightweight doc-check step (even manual for now) to pull requests that change public behavior.

### 10.3 Power-user guides & comparison docs

Den aims to be a drop-in for people used to bash/zsh/fish.

- [ ] Add a **“Den for zsh users”** guide that maps common features (prompt, keybindings, completion, plugins) to Den equivalents.
- [ ] Add a **“Den for fish users”** guide focusing on autosuggestions, completions, and scripts.
- [ ] Clarify which bash-isms are intentionally unsupported to keep the implementation minimal.

---

## 11. Minimalism & Dependency Story

Den’s promise includes “zero dependencies” and a small, self-contained binary, while the build currently relies on `zig-config` as a module.

- [ ] Decide and document what “no dependencies” means in practice:
  - [ ] No **runtime** dependencies beyond libc? (current state).
  - [ ] Allow vendored Zig modules like `zig-config` as part of the source tree.
- [ ] Consider **vendoring** or partially inlining minimal config parsing logic so build doesn’t depend on external module resolution, or at least document the expectation.
- [ ] Keep binary size and memory usage budgets explicit and tracked in `docs/BENCHMARKS.md` / profiling output.

---

## 12. Nice-to-haves / Future Directions (Longer Term)

These are more speculative improvements that should only be pursued if they don’t compromise core goals of simplicity and predictability.

- [ ] Explore **JIT compilation** or ahead-of-time optimization of frequently-used scripts (as hinted in `ARCHITECTURE.md`) while keeping the shell itself a static binary.
- [ ] Consider **distributed execution hooks** (remote runners) via plugins, not core.
- [ ] Add optional **live reload** of plugins and configuration (beyond simple config hot-reload) with strong isolation.
- [ ] Investigate **async I/O integration** in the long term, especially for network-heavy workflows, in a way that doesn’t leak complexity into the user model.

---

This TODO is intentionally broad and ambitious. The immediate next steps should focus on:

1. Aligning `shell.zig` with the documented architecture (modularization).
2. Integrating existing optimization utilities (optimized parser, history index, fuzzy completion, memory pools) into the real execution path.
3. Tightening tests and docs around the current feature set so Den remains rock-solid while it grows toward zsh/fish-level UX.
