# Features

Den Shell combines the familiarity of traditional POSIX shells with modern performance and safety. This guide covers all features available in Den.

## Table of Contents

1. [Core Shell Features](#core-shell-features)
2. [Command Execution](#command-execution)
3. [Variable Expansion](#variable-expansion)
4. [Job Control](#job-control)
5. [History & Completion](#history--completion)
6. [Built-in Commands](#built-in-commands)
7. [Scripting Support](#scripting-support)
8. [Configuration](#configuration)
9. [Plugin System](#plugin-system)

## Core Shell Features

### Pipelines

Connect multiple commands together, passing output from one to the next:

```bash
# Basic pipeline
ls -la | grep zig | wc -l

# Multi-stage pipeline
cat file.txt | sed 's/foo/bar/g' | sort | uniq | head -10

# Pipeline with error handling
command1 | command2 || echo "Pipeline failed"
```

### Redirections

Full I/O redirection support:

```bash
# Output redirection
echo "Hello" > file.txt          # Write (overwrite)
echo "World" >> file.txt         # Append

# Input redirection
wc -l < file.txt

# Error redirection
command 2> errors.log            # Stderr to file
command 2>&1                     # Stderr to stdout
command &> all.log               # Both stdout and stderr
command > output.txt 2>&1        # Both to file
```

### Boolean Operators

Chain commands with conditional execution:

```bash
# AND operator - execute if previous succeeds
mkdir build && cd build && zig build

# OR operator - execute if previous fails
test -f config.json || echo "Config not found"

# Combined
command1 && command2 || command3
```

### Command Chaining

Execute multiple commands sequentially:

```bash
# Sequential execution (always continues)
cd /tmp ; ls -la ; pwd

# Mixed with conditionals
cd build && make ; cd ..
```

### Background Jobs

Run commands in the background with full job control:

```bash
# Start background job
sleep 30 &
[1] 12345

# List jobs
jobs
[1]+ Running    sleep 30 &

# Bring to foreground
fg %1

# Send to background (after Ctrl+Z)
bg %1

# Kill job
kill %1
```

## Command Execution

### External Commands

Den executes external commands from `$PATH`:

```bash
# Standard commands
ls -la
git status
npm install
```

### Command Substitution

Capture command output:

```bash
# Modern syntax (preferred)
NOW=$(date)
FILES=$(ls *.zig)
echo "Current time: $NOW"

# Backtick syntax (legacy)
NOW=`date`
echo "Directory: `pwd`"

# Nested substitution
echo "$(echo "$(date)")"
```

### Process Substitution

Use command output as file input:

```bash
# Compare outputs of two commands
diff <(ls dir1) <(ls dir2)

# Process multiple streams
paste <(seq 1 5) <(seq 6 10)
```

## Variable Expansion

### Basic Variables

```bash
# Set variable
NAME="Den Shell"
VERSION=1.0.0

# Access variable
echo $NAME
echo ${VERSION}
```

### Special Variables

```bash
$?      # Exit status of last command
$$      # Current shell PID
$!      # PID of last background job
$*      # Last argument of previous command
$0      # Script name
$1-$9   # Positional parameters
$@      # All positional parameters (separate)
$*      # All positional parameters (joined)
$#      # Number of positional parameters
```

### Default Values

```bash
# Use default if unset
${VAR:-default}

# Assign default if unset
${VAR:=default}

# Error if unset
${VAR:?error message}

# Use alternative if set
${VAR:+alternative}
```

### Arithmetic Expansion

```bash
# Basic arithmetic
echo $((5 + 3))           # 8
echo $((10 - 4))          # 6
echo $((6 * 7))           # 42
echo $((15 / 3))          # 5
echo $((17 % 5))          # 2
echo $((2 ** 8))          # 256 (power)

# With variables
COUNT=10
echo $((COUNT + 5))       # 15
TOTAL=$((COUNT * 2))
```

### Brace Expansion

```bash
# Sequences
echo {1..10}              # 1 2 3 4 5 6 7 8 9 10
echo {a..z}               # a b c ... z
echo {01..10}             # 01 02 03 ... 10

# Lists
echo {foo,bar,baz}.txt    # foo.txt bar.txt baz.txt
mkdir -p src/{lib,bin,test}

# Combined
echo {a,b}{1,2}           # a1 a2 b1 b2
```

### Tilde Expansion

```bash
~           # Home directory
~/docs      # Home directory + path
~user       # Specific user's home
```

### Glob Expansion

```bash
*.txt       # All .txt files
*.{zig,c}   # All .zig and .c files
**/*.zig    # Recursive search for .zig files
file?.txt   # file1.txt, fileA.txt, etc.
file[0-9]   # file0 through file9
```

## Job Control

### Job Management

```bash
# Start background job
long*process &

# List all jobs
jobs

# Bring to foreground
fg %1
fg %%    # Most recent job

# Send to background
bg %1

# Disown job (detach from shell)
disown %1

# Kill job
kill %1
kill %2 %3    # Kill multiple jobs
```

### Process Control

```bash
# Wait for background job
wait %1

# Wait for all background jobs
wait

# Suspend foreground job
# Press Ctrl+Z

# Continue suspended job in background
bg
```

## History & Completion

### Command History

```bash
# View history
history

# Execute from history
!42         # Execute command #42
!!          # Execute last command
!-2         # Execute 2nd to last command
!ls         # Execute last command starting with 'ls'

# Search history
# Press Ctrl+R and start typing
```

### Tab Completion

Den provides intelligent tab completion:

- **Command completion**: Complete command names from `$PATH`
- **File completion**: Complete file and directory names
- **Variable completion**: Complete variable names
- **Git completion**: Complete git commands and branches

```bash
# Press Tab to complete
cd Doc<Tab>              # Completes to Documents/
git che<Tab>             # Completes to checkout
echo $HOM<Tab>           # Completes to $HOME
```

### Substring History Search

Use arrow keys to search history by substring:

```bash
# Type partial command, then
# Up arrow: Search backwards
# Down arrow: Search forwards
```

## Built-in Commands

Den includes 58 built-in commands. See [BUILTINS.md](./BUILTINS.md) for complete reference.

### Core Builtins

```bash
help        # Display help information
exit        # Exit shell
true        # Return success
false       # Return failure
```

### File System

```bash
cd          # Change directory
pwd         # Print working directory
pushd       # Push directory to stack
popd        # Pop directory from stack
dirs        # Show directory stack
realpath    # Resolve absolute path
```

### Environment

```bash
env         # List environment variables
export      # Export variables
set         # Set shell options/variables
unset       # Unset variables
```

### Scripting

```bash
source      # Execute script in current shell
.           # Alias for source
read        # Read user input
test        # Test conditions
[           # Alias for test
eval        # Evaluate string as command
```

## Scripting Support

### Script Execution

```bash
# Make script executable
chmod +x script.sh

# Run script
./script.sh

# Run with Den
den script.sh

# With arguments
den script.sh arg1 arg2
```

### Control Flow

```bash
# If statements
if test -f file.txt; then
    echo "File exists"
elif test -d file.txt; then
    echo "It's a directory"
else
    echo "Not found"
fi

# While loops
COUNT=0
while test $COUNT -lt 10; do
    echo $COUNT
    COUNT=$((COUNT + 1))
done

# Until loops
until test -f ready.flag; do
    sleep 1
done

# For loops
for FILE in *.zig; do
    echo "Processing $FILE"
done

# C-style for loops
for ((i=0; i<10; i++)); do
    echo $i
done
```

### Loop Control

```bash
# Break out of loop
for i in {1..100}; do
    if test $i -eq 50; then
        break
    fi
done

# Continue to next iteration
for i in {1..10}; do
    if test $((i % 2)) -eq 0; then
        continue
    fi
    echo $i  # Only odd numbers
done
```

### Functions (via Scripts)

```bash
# Define in script
# !/usr/bin/env den

setup() {
    mkdir -p build
    cd build
}

build() {
    zig build
}

setup && build
```

## Configuration

### Config File

Den uses JSONC configuration at `~/.den/config.jsonc`:

```jsonc
{
  "prompt": {
    "format": "❯ ",
    "showGit": true,
    "showTime": false
  },
  "history": {
    "size": 1000,
    "file": "~/.den/history"
  },
  "completion": {
    "enabled": true,
    "fuzzy": true
  },
  "theme": {
    "name": "default",
    "colors": {
      "prompt": "blue",
      "error": "red",
      "success": "green"
    }
  }
}
```

### Aliases

```bash
# Define alias
alias ll="ls -la"
alias gst="git status"
alias gco="git checkout"

# List aliases
alias

# Remove alias
unalias ll
```

### Environment Setup

Common setup in `~/.denrc`:

```bash
# Environment variables
export EDITOR=vim
export PATH=$HOME/.local/bin:$PATH

# Aliases
alias l="ls -lah"
alias ..="cd .."

# Functions
mkcd() {
    mkdir -p "$1" && cd "$1"
}
```

## Plugin System

Den supports plugins for extending functionality:

### Available Plugins

- **Syntax Highlighting**: Colorize commands as you type
- **Auto Suggestions**: Fish-style suggestions from history
- **Git Integration**: Enhanced git completion and prompts
- **Custom Themes**: Personalize your prompt

### Plugin Configuration

```jsonc
{
  "plugins": {
    "enabled": [
      "syntax-highlight",
      "auto-suggest",
      "git-prompt"
    ],
    "syntax-highlight": {
      "commands": "green",
      "strings": "yellow",
      "errors": "red"
    }
  }
}
```

## Performance Features

### Startup Optimization

- **Instant startup**: ~5ms cold start time
- **Lazy loading**: Plugins load on-demand
- **Config caching**: Configuration parsed once

### Command Caching

Den caches command locations:

```bash
# Cache command path
hash ls

# View cached commands
hash

# Clear cache
hash -r
```

### Concurrent Execution

Den uses thread pooling for parallel operations:

- History indexing
- Completion generation
- Plugin operations

## Advanced Features

### Error Handling

```bash
# Exit on error
set -e

# Exit on undefined variable
set -u

# Pipeline failure detection
set -o pipefail

# Trap errors
trap 'echo "Error on line $LINENO"' ERR
```

### Debugging

```bash
# Enable debug mode
set -x

# Trace commands
# Each command will be printed before execution

# Disable debug mode
set +x
```

## Next Steps

- [Extended Features](./EXTENDED_FEATURES.md) - zsh compat, AI completions, distributed sessions, WebAssembly plugins
- [Advanced Usage](./ADVANCED.md) - Advanced features and techniques
- [API Reference](./API.md) - Complete API documentation
- [Builtins Reference](./BUILTINS.md) - All built-in commands
- [Contributing](./CONTRIBUTING.md) - Help improve Den
