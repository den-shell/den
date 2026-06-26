# Features Overview

Den provides a comprehensive set of shell features for interactive use and scripting.

**Focused guides:** [Pipelines](./pipelines.md) · [Redirections](./redirections.md) · [Job Control](./job-control.md) · [Expansions](./expansions.md) · [Scripting](../SCRIPTING.md) · [Builtins](../BUILTINS.md)

## Core Shell Capabilities

### Pipelines

Multi-stage command pipelines for data processing:

```bash
cat file.txt | grep "pattern" | sort | uniq
ls -la | awk '{print $9}' | head -10
ps aux | grep node | wc -l
```

### I/O Redirections

Full input/output redirection support:

```bash
# Output redirection
echo "Hello" > file.txt      # Overwrite
echo "World" >> file.txt     # Append

# Input redirection
sort < unsorted.txt

# Error redirection
command 2> errors.txt        # Redirect stderr
command > out.txt 2>&1       # Redirect both
command &> all.txt           # Redirect both (shorthand)

# Discard output
command > /dev/null 2>&1
```

### Background Jobs

Job control with background process management:

```bash
# Run in background
sleep 30 &

# List jobs
jobs

# Bring to foreground
fg %1

# Send to background
bg %1

# Suspend foreground job
# Press Ctrl+Z
```

### Boolean Operators

Conditional command execution:

```bash
# AND - run second if first succeeds
mkdir dir && cd dir

# OR - run second if first fails
test -f config.json || echo "No config"

# Combine operators
test -d dir && cd dir || mkdir dir
```

### Command Chaining

Sequential command execution:

```bash
# Run regardless of exit status
echo "First"; echo "Second"; echo "Third"

# Mix with conditionals
test -d build && rm -rf build; mkdir build
```

## Expansion Features

### Variable Expansion

```bash
# Basic
echo $HOME
echo ${PATH}

# With defaults
echo ${NAME:-default}
echo ${CONFIG:=fallback}

# Special variables
echo $?    # Last exit status
echo $$    # Current PID
echo $!    # Last background PID
echo $_    # Last argument
```

### Command Substitution

Capture command output:

```bash
# Modern syntax
CURRENT=$(pwd)
DATE=$(date +%Y-%m-%d)

# Use in commands
cp file.txt "backup-$(date +%s).txt"
echo "You have $(ls | wc -l) files"
```

### Arithmetic Expansion

Calculate expressions:

```bash
echo $((1 + 2))         # 3
echo $((10 * 5))        # 50
echo $((100 / 4))       # 25
echo $((17 % 5))        # 2
echo $((2 ** 10))       # 1024

# With variables
X=10
Y=3
echo $((X + Y))         # 13
```

### Brace Expansion

Generate sequences and lists:

```bash
# Sequences
echo {1..5}             # 1 2 3 4 5
echo {a..e}             # a b c d e
echo file{1..3}.txt     # file1.txt file2.txt file3.txt

# Lists
echo {foo,bar,baz}      # foo bar baz
cp file.{txt,bak}       # cp file.txt file.bak
```

### Tilde Expansion

Home directory shortcuts:

```bash
cd ~                    # Go to home
cd ~/projects           # Go to ~/projects
echo ~/.config          # Print home config path
```

### Glob Expansion

Pattern matching for files:

```bash
ls *.txt                # All .txt files
ls *.{jpg,png}          # All .jpg and .png files
ls **/*.zig             # All .zig files (recursive)
ls src/*.?s             # .ts, .js, etc.
ls file?.txt            # file1.txt, file2.txt, etc.
```

## Interactive Features

### Command History

Navigate and search history:

```bash
# View history
history

# Navigate with arrow keys
# Up/Down - Previous/Next command

# Search history
# Ctrl+R - Reverse search

# Use history expansion
!!                      # Repeat last command
!grep                   # Run last grep command
!?pattern               # Run last command with pattern
```

### Tab Completion

Intelligent auto-completion:

- **Commands** - Complete command names from PATH
- **Files** - Complete file and directory paths
- **Built-ins** - Complete built-in command names
- **Aliases** - Complete alias names

Press Tab once for completion, twice for listing options.

### Aliases

Create command shortcuts:

```bash
# Define alias
alias ll='ls -la'
alias gs='git status'

# List all aliases
alias

# Show specific alias
alias ll

# Remove alias
unalias ll
```

## Built-in Commands

Den includes 58 built-in commands organized by category:

| Category | Commands |
|----------|----------|
| **Core** | `exit`, `help`, `true`, `false` |
| **File System** | `cd`, `pwd`, `pushd`, `popd`, `dirs`, `realpath` |
| **Environment** | `env`, `export`, `set`, `unset` |
| **Introspection** | `alias`, `unalias`, `type`, `which` |
| **Job Control** | `jobs`, `fg`, `bg` |
| **History** | `history`, `complete` |
| **Scripting** | `source`, `.`, `read`, `test`, `[`, `eval`, `shift`, `command` |
| **Path Utils** | `basename`, `dirname` |
| **Output** | `echo`, `printf` |
| **System** | `time`, `sleep`, `umask`, `hash` |
| **Info** | `clear`, `uname`, `whoami` |
| **Script Control** | `return`, `break`, `continue`, `local`, `declare`, `readonly` |
| **Job Management** | `kill`, `wait`, `disown` |
| **Advanced** | `exec`, `builtin`, `trap`, `getopts`, `times` |

## Performance Characteristics

Measured on an Apple M3 Pro (see [Benchmarks](../BENCHMARKS.md) for methodology; reproduce with `scripts/bench.sh comparison`):

| Metric | Den |
|---------|-------------|
| Startup (`-c true`) | ~3.9 ms |
| Command exec (per external cmd) | ~2 ms |
| Idle memory (clean config) | ~4.6 MB |
| Binary size (ReleaseSmall, stripped) | ~1.33 MB |

## Feature Comparison

| Feature | Den | Bash | Zsh | Fish |
|---------|-----|------|-----|------|
| Pipelines | Yes | Yes | Yes | Yes |
| Job Control | Yes | Yes | Yes | Yes |
| Tab Completion | Yes | Yes | Yes | Yes |
| Command History | Yes | Yes | Yes | Yes |
| Glob Expansion | Yes | Yes | Yes | Yes |
| Brace Expansion | Yes | Yes | Yes | Limited |
| Arithmetic | Yes | Yes | Yes | Limited |
| Command Substitution | Yes | Yes | Yes | Yes |
| Arrays | No | Yes | Yes | Yes |
| Functions | Limited | Yes | Yes | Yes |

## Next Steps

- [Pipelines](/features/pipelines) - Deep dive into pipelines
- [Redirections](/features/redirections) - I/O redirection details
- [Job Control](/features/job-control) - Managing background processes
- [Expansions](/features/expansions) - All expansion types
