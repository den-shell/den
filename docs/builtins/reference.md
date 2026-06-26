# Built-in Commands Reference

Den includes 58 built-in commands. This is the complete reference.

## Core Commands

### exit

Exit the shell with an optional status code.

```bash
exit        # Exit with status 0
exit 1      # Exit with status 1
```

### help

Display help information about built-in commands.

```bash
help        # List all builtins
help cd     # Help for specific command
```

### true

Return success (exit status 0).

```bash
true && echo "Success"
```

### false

Return failure (exit status 1).

```bash
false || echo "Failed"
```

## File System Commands

### cd

Change the current directory.

```bash
cd /path/to/dir     # Go to directory
cd                  # Go to home
cd -                # Go to previous directory
cd ..               # Go up one level
```

### pwd

Print the current working directory.

```bash
pwd                 # Print current directory
```

### pushd

Push directory onto the stack and change to it.

```bash
pushd /tmp          # Push /tmp and cd to it
pushd               # Swap top two directories
```

### popd

Pop directory from stack and change to it.

```bash
popd                # Pop and cd to popped directory
```

### dirs

Display the directory stack.

```bash
dirs                # Show directory stack
dirs -c             # Clear the stack
```

### realpath

Print the resolved absolute path.

```bash
realpath ./file     # Print absolute path
realpath -e file    # Error if doesn't exist
```

## Environment Commands

### env

Display or modify environment variables.

```bash
env                 # List all variables
env VAR=val cmd     # Run with modified env
```

### export

Set environment variables.

```bash
export VAR=value    # Set and export
export VAR          # Export existing variable
export -n VAR       # Remove export
```

### set

Set or display shell options and parameters.

```bash
set                 # List all variables
set -x              # Enable debug mode
set +x              # Disable debug mode
```

### unset

Remove variables or functions.

```bash
unset VAR           # Remove variable
unset -v VAR        # Remove variable (explicit)
```

## Introspection Commands

### alias

Define or display aliases.

```bash
alias               # List all aliases
alias name='cmd'    # Create alias
alias name          # Show specific alias
```

### unalias

Remove aliases.

```bash
unalias name        # Remove alias
unalias -a          # Remove all aliases
```

### type

Display command type information.

```bash
type ls             # Show what 'ls' is
type -a ls          # Show all matches
type -t ls          # Show type only
```

### which

Locate a command.

```bash
which git           # Show git path
which -a python     # Show all matches
```

## Job Control Commands

### jobs

List active jobs.

```bash
jobs                # List all jobs
jobs -l             # List with PIDs
```

### fg

Bring job to foreground.

```bash
fg                  # Foreground last job
fg %1               # Foreground job 1
fg %+               # Foreground current job
```

### bg

Resume job in background.

```bash
bg                  # Background last job
bg %1               # Background job 1
```

## History Commands

### history

Display or manipulate command history.

```bash
history             # Show all history
history 10          # Show last 10
history -c          # Clear history
```

### complete

Specify completion behavior.

```bash
complete -f cmd     # File completion for cmd
complete -d cmd     # Directory completion
```

## Scripting Commands

### source /

Execute commands from a file in the current shell.

```bash
source ~/.denrc     # Load config
. ~/.denrc          # Same as source
```

### read

Read a line of input.

```bash
read VAR            # Read into VAR
read -p "Name: " N  # Read with prompt
read A B C          # Read into multiple vars
```

### test / [

Evaluate conditional expressions.

```bash
test -f file        # Check if file exists
test -d dir         # Check if directory
test "$A" = "$B"    # Compare strings
test $X -gt 5       # Compare numbers
[ -f file ]         # Alternative syntax
```

### eval

Execute arguments as a command.

```bash
eval echo \$HOME    # Evaluate and run
CMD="ls -la"
eval $CMD           # Run stored command
```

### shift

Shift positional parameters.

```bash
shift               # Shift by 1
shift 2             # Shift by 2
```

### command

Run command bypassing functions and aliases.

```bash
command ls          # Run real ls
command -v git      # Check if git exists
```

## Path Utility Commands

### basename

Strip directory from filename.

```bash
basename /a/b/c.txt     # c.txt
basename file.txt .txt  # file
```

### dirname

Strip filename from path.

```bash
dirname /a/b/c.txt      # /a/b
dirname ./file.txt      # .
```

## Output Commands

### echo

Display a line of text.

```bash
echo "Hello"        # Print with newline
echo -n "Hello"     # Print without newline
echo -e "A\tB"      # Interpret escapes
```

### printf

Format and print data.

```bash
printf "Hello\n"            # Print with newline
printf "%s: %d\n" A 42      # Formatted output
printf "%.2f\n" 3.14159     # Float formatting
```

## System Commands

### time

Time command execution.

```bash
time sleep 1        # Time the sleep command
time ls -la         # Time ls command
```

### sleep

Pause for specified duration.

```bash
sleep 1             # Sleep 1 second
sleep 0.5           # Sleep 0.5 seconds
sleep 1m            # Sleep 1 minute
```

### umask

Set file creation mask.

```bash
umask               # Show current mask
umask 022           # Set mask
umask -S            # Show symbolic
```

### hash

Manage command hash table.

```bash
hash                # Show hash table
hash -r             # Clear hash table
hash -d name        # Remove entry
```

## Info Commands

### clear

Clear the terminal screen.

```bash
clear               # Clear screen
```

### uname

Print system information.

```bash
uname               # OS name
uname -a            # All information
uname -r            # Kernel release
uname -m            # Machine type
```

### whoami

Print current username.

```bash
whoami              # Print username
```

## Script Control Commands

### return

Return from a function or sourced script.

```bash
return              # Return with 0
return 1            # Return with status 1
```

### break

Exit from a loop.

```bash
while true; do
    break           # Exit loop
done
```

### continue

Skip to next iteration of a loop.

```bash
for i in {1..5}; do
    test $i -eq 3 && continue
    echo $i
done
```

### local

Declare local variables in functions.

```bash
# Inside a function
local VAR=value
```

### declare

Declare variables with attributes.

```bash
declare VAR=value   # Declare variable
declare -r VAR      # Read-only
declare -x VAR      # Export
declare -i VAR      # Integer
```

### readonly

Mark variables as read-only.

```bash
readonly VAR=value  # Create read-only
readonly VAR        # Make existing read-only
```

## Job Management Commands

### kill

Send signals to processes.

```bash
kill PID            # Send SIGTERM
kill -9 PID         # Send SIGKILL
kill -l             # List signals
kill %1             # Kill job 1
```

### wait

Wait for processes to complete.

```bash
wait                # Wait for all
wait PID            # Wait for specific
wait %1             # Wait for job 1
```

### disown

Remove jobs from job table.

```bash
disown              # Disown current job
disown %1           # Disown job 1
disown -a           # Disown all
```

## Advanced Execution Commands

### exec

Replace shell with command.

```bash
exec ls             # Replace shell with ls
exec > log.txt      # Redirect all output
```

### builtin

Run a builtin command explicitly.

```bash
builtin cd /tmp     # Use builtin cd
```

### trap

Set signal handlers.

```bash
trap 'echo Exit' EXIT
trap 'cleanup' SIGINT
trap '' SIGINT      # Ignore signal
trap - SIGINT       # Reset handler
```

### getopts

Parse command options.

```bash
while getopts "ab:c" opt; do
    case $opt in
        a) echo "Option a";;
        b) echo "Option b: $OPTARG";;
        c) echo "Option c";;
    esac
done
```

### times

Display process times.

```bash
times               # Show user/system times
```

## Quick Reference Table

| Command | Purpose | Example |
|---------|---------|---------|
| `cd` | Change directory | `cd /tmp` |
| `pwd` | Print directory | `pwd` |
| `echo` | Print text | `echo "Hello"` |
| `export` | Set env var | `export VAR=val` |
| `alias` | Create alias | `alias ll='ls -l'` |
| `test` | Conditional | `test -f file` |
| `read` | Read input | `read NAME` |
| `source` | Run script | `source ~/.denrc` |
| `jobs` | List jobs | `jobs` |
| `fg` | Foreground | `fg %1` |
| `bg` | Background | `bg %1` |
| `kill` | Send signal | `kill PID` |
| `exit` | Exit shell | `exit 0` |
