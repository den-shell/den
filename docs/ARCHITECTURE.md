# Den Shell Architecture

This document provides a comprehensive overview of Den Shell's architecture, design decisions, and component interactions.

## Table of Contents

1. [Overview](#overview)
2. [Core Architecture](#core-architecture)
3. [Component Overview](#component-overview)
4. [Data Flow](#data-flow)
5. [Execution Pipeline](#execution-pipeline)
6. [Concurrency Model](#concurrency-model)
7. [Memory Management](#memory-management)
8. [Extension Points](#extension-points)

## Overview

Den Shell is a modern, high-performance POSIX-compatible shell written in Zig. The architecture is designed for:

- **Performance**: Optimized for startup time, execution speed, and memory efficiency
- **Modularity**: Clean separation of concerns with well-defined interfaces
- **Extensibility**: Plugin system and hooks for customization
- **Correctness**: Strong typing and comprehensive testing
- **Concurrency**: Thread pool and parallel execution for I/O-bound operations

### Technology Stack

- **Language**: Zig 0.16-dev
- **Build System**: Zig build system
- **Testing**: Zig test framework with custom profiling
- **Concurrency**: Custom thread pool and lock-free data structures

## Core Architecture

Den Shell follows a layered architecture with clear separation between components:

```
┌─────────────────────────────────────────────────────────────┐
│                         CLI Layer                            │
│                    (src/cli.zig, src/main.zig)              │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                       Shell Core                             │
│                    (src/shell.zig)                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Environment │ History │ Jobs │ Aliases │ Variables   │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   Line Editing Layer                         │
│                 (src/utils/terminal/)                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Input │ Keymaps │ Completion │ Highlight │ Suggest   │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                     Parser Layer                             │
│        (src/parser/, src/expansion/, src/types/)            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Tokenizer → Parser → AST → Expansion → Commands      │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Executor Layer                            │
│                  (src/executor/)                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Builtins │ External │ Pipelines │ Redirections       │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   Cross-Cutting Concerns                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Plugins │ Hooks │ Scripting │ Profiling │ Logging    │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## Component Overview

### 1. CLI Layer (src/cli.zig, src/main.zig)

**Purpose**: Entry point and command-line argument handling

**Key Components**:

- `main.zig`: Program entry point with GPA allocator setup
- `cli.zig`: Command parsing and subcommand dispatch

**Responsibilities**:

- Parse command-line arguments
- Route to appropriate subcommands (shell, exec, complete, setup, etc.)
- Initialize allocator and shell instance
- Handle version and help commands

### 2. Shell Core (src/shell.zig)

**Purpose**: Central state management and coordination

**Key Components**:

- `Shell` struct: Main shell state
- Environment variables management
- History tracking
- Job control
- Alias management
- Positional parameters
- Thread pool for concurrency

**Responsibilities**:

- Initialize and manage shell state
- Coordinate between subsystems
- Execute hooks at lifecycle events
- Manage background jobs
- Track command history

**Key Data Structures**:
```zig
pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    history: [1000]?[]const u8,
    job_manager: JobManager,              // Centralized job control
    script_manager: ScriptManager,
    function_manager: FunctionManager,
    plugin_registry: PluginRegistry,
    plugin_manager: PluginManager,
    thread_pool: concurrency.ThreadPool, // For parallel operations
    // ... more fields
}
```

### 2.1 Job Control (src/jobs/)

**Purpose**: Centralized background job management

**Key Components**:

- `job_manager.zig`: Job tracking, status monitoring, builtin implementations
- `mod.zig`: Module exports

**Responsibilities**:

- Track background jobs (add, remove, status)
- Non-blocking job completion checks
- Implement job builtins (jobs, fg, bg, disown, wait)
- Graceful shutdown with SIGTERM/SIGKILL

### 2.2 Shell Options (src/types/shell_options.zig)

**Purpose**: Centralized shell option management

**Key Components**:

- `SetOptions`: POSIX set options (-e, -u, -x, etc.)
- `ShoptOptions`: Bash-style shopt options
- `ShellOptions`: Combined options with accessor methods

### 2.3 Utility Modules (src/utils/)

**Key Modules**:

- `regex.zig`: Simple regex matching for shell patterns
- `config_watch.zig`: File modification tracking for hot-reload
- `io.zig`: Cross-platform I/O utilities
- `terminal.zig`: Terminal handling and line editing
- `completion.zig`: Tab completion engine
- `expansion.zig`: Variable and glob expansion
- `signals.zig`: Signal handling
- `platform.zig`: Platform abstraction layer for cross-platform support

#### Platform Abstraction (src/utils/platform.zig)

Provides unified API for platform-specific operations:

- **Process Management**: `waitProcess`, `killProcess`, `continueProcess`
- **Process Groups**: `setProcessGroup`, `getProcessGroup`, `setForegroundProcessGroup`
- **Terminal Detection**: `isTty`, `getTerminalSize`
- **Pipes**: `createPipe`, `duplicateFd`, `closeFd`
- **Environment**: `getEnv`, `getHomeDir`, `getUsername`, `isRoot`
- **Path Operations**: `isAbsolutePath`, `path_separator`
- **File Operations**: `fileExists`, `isDirectory`, `isExecutable`
- **Signal Constants**: Platform-appropriate signal definitions

### 3. Line Editing Layer (src/utils/terminal/)

**Purpose**: Interactive command-line interface

**Key Components**:

- `line_editor.zig`: Line editing, history navigation, completion menu
- `keymap.zig`: Keymaps and named widgets, the data behind `bindkey`
- `escape.zig`: Terminal escape-sequence decoding
- Completion sources (`src/utils/completion.zig`, `src/shell/tab_completion.zig`)
- Syntax highlighting (`src/utils/syntax_highlight.zig`)

The editor instance is owned by `Shell`, which creates it lazily at the first
interactive prompt; its keymaps live on `Shell` so `bindkey` works before the
editor exists. Pulling that wiring out into a coordinator of its own is still
open work — see `.github/TODO.md`.

**Responsibilities**:

- Read user input with editing capabilities
- Provide completions for commands, files, variables
- Highlight syntax in real-time
- Show suggestions based on history
- Handle special keys (Ctrl+C, Ctrl+D, etc.)

### 4. Parser Layer (src/parser/, src/expansion/, src/types/)

**Purpose**: Transform input text into executable AST

**Pipeline**:
```
Input String → Tokenizer → Parser → AST → Expansion → Command Tree
```

**Key Components**:

#### Tokenizer (src/parser/tokenizer.zig)

- Breaks input into tokens
- Handles quotes, escapes, operators
- Tracks token positions for error reporting

**Token Types**:

- Words (commands, arguments)
- Operators (|, ||, &&, ;, &, <, >, >>)
- Special characters ($, `, \)
- Keywords (if, while, for, function)

#### Parser (src/parser/parser.zig)

- Builds AST from tokens
- Handles operator precedence
- Validates syntax
- Supports complex constructs (pipelines, conditionals, loops)

**AST Node Types**:

- Command: Simple command with arguments
- Pipeline: Commands connected with pipes
- Conditional: if/elif/else statements
- Loop: for/while loops
- Function: Function definitions
- Compound: Grouped commands ({})

#### Expansion (src/expansion/)

- Parameter expansion ($VAR, ${VAR})
- Command substitution ($(cmd), `cmd`)
- Arithmetic expansion ($((expr)))
- Glob expansion (_.txt, [a-z]_)
- Brace expansion ({a,b,c}, {1..10})
- Tilde expansion (~, ~/dir)

### 5. Executor Layer (src/executor/)

**Purpose**: Execute parsed commands

**Key Components**:

#### Command Executor (src/executor/executor.zig)

- Routes commands to builtins or external processes
- Handles pipelines with proper file descriptor management
- Manages redirections (<, >, >>, 2>&1)
- Implements job control (fg, bg, jobs)

#### Builtin Commands (src/builtins/)

The builtins system is organized into logical modules:

- **Registry** (`mod.zig`): `BuiltinRegistry` interface for registering and executing builtins
- **Filesystem** (`filesystem.zig`): `basename`, `dirname`, `realpath`
- **Directory** (`directory.zig`): `pushd`, `popd`, `dirs`
- **I/O** (`io.zig`): `printf`, `read`
- **Process** (`process.zig`): `exec`, `wait`, `kill`, `disown`
- **Variables** (`variables.zig`): `local`, `declare`, `readonly`, `typeset`, `let`
- **Misc** (`misc.zig`): `sleep`, `help`, `clear`, `uname`, `whoami`, `umask`, `time`, `caller`

Core builtins include:

- `cd`: Change directory with CDPATH support
- `echo`: Print text with escape sequences
- `export`: Set environment variables
- `alias`: Create command aliases
- `source`: Execute script files
- `exit`: Exit shell with status code

#### Process Management (src/executor/process.zig)

- Fork/exec for external commands
- Process group management
- Signal handling (SIGINT, SIGTERM, SIGCHLD)
- Background job tracking

#### I/O Redirection (src/executor/redirect.zig)

- File descriptor manipulation
- Pipe creation and management
- Here-document implementation
- File mode handling (read, write, append)

#### Network Path Handling (src/executor/networking.zig)

- `/dev/tcp/host/port` support for TCP connections
- `/dev/udp/host/port` support for UDP connections
- Detailed error messages for malformed paths
- IPv4 and IPv6 address validation

#### Memory Pools (src/executor/memory_pool.zig)

- `CommandMemoryPool`: Arena allocator for command execution
- `PipelineMemoryPool`: Arena allocator for pipeline management
- `ExpansionMemoryPool`: Arena allocator for variable expansion
- Reduces allocation overhead during execution

### 6. Plugin System (src/plugins/)

**Purpose**: Extensibility and customization

**Key Components**:

#### Plugin Interface (src/plugins/interface.zig)

```zig
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    init: _const fn (_PluginContext) anyerror!void,
    deinit: _const fn (_PluginContext) void,
    hooks: []const HookRegistration,
};

pub const HookType = enum {
    shell_init,
    shell_exit,
    pre_command,
    post_command,
    prompt,
    // ... more hooks
};
```

#### Plugin Manager (src/plugins/manager.zig)

- Load plugins from directories
- Manage plugin lifecycle
- Handle plugin dependencies
- Provide isolation between plugins

#### Builtin Plugins (src/plugins/builtin_plugins_advanced.zig)

- AutoSuggest: History-based suggestions
- Highlight: Syntax highlighting
- ScriptSuggester: Script completion

**Hook Points**:

- `shell_init`: After shell initialization
- `shell_exit`: Before shell cleanup
- `pre_command`: Before command execution
- `post_command`: After command execution
- `prompt`: Generate custom prompts
- `completion`: Custom completions

### 7. Scripting Layer (src/scripting/)

**Purpose**: Script execution and function management

**Key Components**:

#### Script Manager (src/scripting/script_manager.zig)

- Load and execute script files
- Track script state and variables
- Handle script errors

#### Function Manager (src/scripting/functions.zig)

- Define shell functions
- Store function bodies
- Execute functions with arguments
- Handle function-local variables

### 8. Configuration System (src/config_loader.zig, src/types/config.zig)

**Purpose**: Load and manage shell configuration

**Key Components**:

#### Config Loader (src/config_loader.zig)

- Multi-source configuration loading
- JSONC parsing with comment support
- Configuration validation

**Configuration Search Order**:

1. Custom path (via `--config` flag)
2. `./den.jsonc`
3. `./package.jsonc` (extracts "den" key)
4. `./config/den.jsonc`
5. `./.config/den.jsonc`
6. `~/.config/den.jsonc`
7. `~/package.jsonc` (extracts "den" key)

**Key Types**:
```zig
pub const ConfigSource = struct {
    path: ?[]const u8,
    source_type: SourceType,

    pub const SourceType = enum {
        default,
        den_jsonc,
        package_jsonc,
        custom_path,
    };
};

pub const ConfigLoadResult = struct {
    config: DenConfig,
    source: ConfigSource,
};
```

**Features**:

- **Hot Reload**: Set `hot_reload: true` in config for automatic reload
- **Validation**: Comprehensive validation with warnings and errors
- **package.jsonc Support**: Embed Den config in package.jsonc under "den" key

#### Config Types (src/types/config.zig)

```zig
pub const DenConfig = struct {
    verbose: bool = false,
    stream_output: ?bool = null,
    hot_reload: bool = false,  // Auto-reload on file change
    prompt: PromptConfig = .{},
    history: HistoryConfig = .{},
    completion: CompletionConfig = .{},
    theme: ThemeConfig = .{},
    expansion: ExpansionConfig = .{},
    aliases: AliasConfig = .{},
    keybindings: KeybindingConfig = .{},
    environment: EnvironmentConfig = .{},
};
```

### 9. Utilities (src/utils/)

**Purpose**: Shared functionality and helpers

**Key Modules**:

- `io.zig`: I/O utilities, terminal handling
- `path.zig`: Path manipulation and resolution
- `completion.zig`: Completion engine
- `glob.zig`: Glob pattern matching
- `brace.zig`: Brace expansion
- `expansion.zig`: Variable/command expansion
- `concurrency.zig`: Thread pool, atomic structures
- `parallel_discovery.zig`: Parallel file operations

## Data Flow

### Command Execution Flow

```
User Input
    │
    ▼
┌───────────────┐
│ REPL/Editor   │  Read line with editing
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Tokenizer   │  Break into tokens
└───────┬───────┘
        │
        ▼
┌───────────────┐
│    Parser     │  Build AST
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Expansion   │  Expand variables, globs, etc.
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Executor    │  Execute commands
└───────┬───────┘
        │
        ├─▶ Builtin Command
        │       │
        │       ▼
        │   Execute internally
        │
        └─▶ External Command
                │
                ▼
            Fork & Exec
                │
                ▼
            Wait for completion
                │
                ▼
            Return exit code
```

### Plugin Hook Flow

```
Shell Event (e.g., pre_command)
    │
    ▼
┌────────────────┐
│ Plugin Registry│  Find registered hooks
└────────┬───────┘
         │
         ▼
┌────────────────┐
│  Hook Context  │  Build context with event data
└────────┬───────┘
         │
         ▼
   ┌─────────────┐
   │ For each    │
   │ registered  │
   │ plugin      │
   └──────┬──────┘
          │
          ▼
   ┌──────────────┐
   │ Call plugin  │
   │ hook handler │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │ Collect      │
   │ results      │
   └──────┬───────┘
          │
          ▼
    Return to caller
```

## Execution Pipeline

### Simple Command

```bash
ls -la /tmp
```

1. **Tokenize**: `[ls] [-la] [/tmp]`
2. **Parse**: `Command{name: "ls", args: ["-la", "/tmp"]}`
3. **Expand**: No expansion needed
4. **Execute**:
   - Check if builtin → No
   - Fork process
   - Exec `/usr/bin/ls` with args
   - Wait for completion

### Pipeline

```bash
cat file.txt | grep "pattern" | wc -l
```

1. **Tokenize**: `[cat] [file.txt] [|] [grep] ["pattern"] [|] [wc] [-l]`
2. **Parse**: `Pipeline{[Command(cat), Command(grep), Command(wc)]}`
3. **Execute Pipeline**:

   ```

   - Create pipe1: cat → grep
   - Create pipe2: grep → wc
   - Fork cat: stdout → pipe1
   - Fork grep: stdin ← pipe1, stdout → pipe2
   - Fork wc: stdin ← pipe2
   - Close all pipe ends in parent
   - Wait for all processes

   ```

### Variable Expansion

```bash
echo "Hello $USER, your home is $HOME"
```

1. **Tokenize**: `[echo] ["Hello $USER, your home is $HOME"]`
2. **Parse**: `Command{name: "echo", args: ["Hello $USER, your home is $HOME"]}`
3. **Expand**:
   - Find `$USER` → Replace with environment value
   - Find `$HOME` → Replace with environment value
   - Result: `"Hello john, your home is /home/john"`
4. **Execute**: Builtin echo prints the expanded string

## Concurrency Model

Den Shell implements a hybrid concurrency model:

### Thread Pool Architecture

```
Shell Initialization
    │
    ▼
Create ThreadPool (auto CPU count)
    │
    ├─▶ Worker Thread 1
    ├─▶ Worker Thread 2
    ├─▶ Worker Thread 3
    └─▶ Worker Thread N
         │
         ▼
    Job Queue (mutex-protected)
         │
         ▼
    Wait on condition variable
         │
         ▼
    Execute jobs as submitted
```

### Concurrent Operations

**Plugin Discovery**:

- Scan multiple directories in parallel
- Each directory assigned to worker thread
- Results collected with mutex protection

**File Globbing** (potential):

- Parallel directory traversal
- Concurrent pattern matching
- Merge results

**Completion** (potential):

- Query multiple sources concurrently
- Merge completion results
- Return sorted/deduplicated list

### Synchronization Primitives

- **ThreadPool**: Work queue with condition variables
- **AtomicCounter**: Lock-free metrics
- **SPSCQueue**: Lock-free producer-consumer
- **RWLock**: Reader-writer locks for read-heavy data
- **ConcurrentHashMap**: Sharded hash map (16 shards)

## Memory Management

### Allocation Strategy

Den Shell uses a **General Purpose Allocator (GPA)** at the top level with careful lifetime management:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    try shell.run();
}
```

### Memory Ownership

- **Shell owns**: Environment, aliases, history, jobs
- **Parser owns**: AST nodes (temporary, freed after execution)
- **Executor owns**: Process handles, file descriptors
- **Plugins own**: Internal state (cleaned up in deinit)

### Lifetime Management

1. **Shell Level**: Long-lived (entire session)
   - Environment variables
   - History
   - Aliases
   - Background jobs

2. **Command Level**: Medium-lived (single command)
   - AST nodes
   - Expanded arguments
   - Temporary files

3. **Execution Level**: Short-lived (during execution)
   - Pipe buffers
   - Process state
   - I/O buffers

### Memory Optimization Techniques

See [MEMORY_OPTIMIZATION.md](MEMORY_OPTIMIZATION.md) for details:

- Arena allocators for parser
- String interning for common values
- Fixed-size arrays for bounded collections
- Lazy initialization of optional features

## Extension Points

### 1. Builtin Commands

Add new builtins by implementing in `src/builtins/`:

```zig
pub fn myBuiltin(
    shell: _Shell,
    args: []const []const u8,
    stdout: anytype,
) !i32 {
    // Implementation
    return 0;
}
```

Register in `src/builtins/mod.zig`.

### 2. Plugins

Create plugins by implementing the `Plugin` interface:

```zig
pub const MyPlugin = struct {
    pub fn init(ctx: _PluginContext) !void {
        // Initialize plugin
    }

    pub fn deinit(ctx: _PluginContext) void {
        // Cleanup
    }

    pub const hooks = [_]HookRegistration{
        .{ .hook_type = .pre_command, .handler = preCommand },
    };

    fn preCommand(ctx: _HookContext) !void {
        // Handle pre-command event
    }
};
```

### 3. Completion Sources

Add completion sources in `src/completion/`:

```zig
pub fn completeMyThing(
    prefix: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    // Return completions
}
```

### 4. Custom Expansion

Add expansion rules in `src/expansion/`:

```zig
pub fn expandMyPattern(
    input: []const u8,
    allocator: std.mem.Allocator,
    env: *std.StringHashMap([]const u8),
) ![][]const u8 {
    // Expand pattern
}
```

## Design Principles

### 1. Separation of Concerns

- Clear boundaries between components
- Single responsibility per module
- Minimal coupling

### 2. Fail Fast

- Early validation
- Descriptive error messages
- Proper error propagation

### 3. Performance

- Lazy initialization
- Minimize allocations
- Cache where beneficial
- Parallel operations where possible

### 4. Compatibility

- POSIX compliance for core features
- Bash-like syntax for familiarity
- Cross-platform (Linux, macOS)

### 5. Testability

- Pure functions where possible
- Dependency injection
- Comprehensive test coverage

## Future Architecture Enhancements

### Planned Improvements

1. **Async I/O**: Non-blocking file operations
2. **JIT Compilation**: Compile frequently-used scripts
3. **Distributed Execution**: Remote command execution
4. **Advanced Caching**: Cache parsed scripts, completions
5. **Live Reload**: Hot-reload plugins and configuration

### Scalability Considerations

- **Memory**: Fixed-size history/job arrays can be made dynamic
- **Concurrency**: Thread pool size auto-adjusts to CPU count
- **Plugins**: Isolated address spaces for safety
- **Performance**: Profiling infrastructure for continuous optimization

## Related Documentation

- [Data Structures](DATA_STRUCTURES.md) - Detailed structure documentation
- [Algorithms](ALGORITHMS.md) - Algorithm implementations
- [API Reference](API.md) - Public API documentation
- [Contributing](CONTRIBUTING.md) - How to contribute

## References

- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [POSIX Shell Standard](https://pubs.opengroup.org/onlinepubs/9699919799/)
- [Bash Reference Manual](https://www.gnu.org/software/bash/manual/)
