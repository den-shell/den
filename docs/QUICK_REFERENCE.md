# Den Shell Quick Reference

A quick reference guide for Den's interactive features and keyboard shortcuts.

## Tab Completion

### Basic Completion

```bash
# Complete commands
git st<TAB>      → git status

# Complete files
cat READ<TAB>    → cat README.md

# Complete directories (adds /)
cd Doc<TAB>      → cd Documents/
```

### Multiple Suggestions

```bash
cd /usr/l<TAB>
# Shows:  lib/  libexec/  local/

# Press TAB again to cycle through options
# Currently selected option is highlighted
```

### Mid-Word Path Expansion (zsh-style)

```bash
# Type abbreviations, get full paths
/u/l/b<TAB>           → /usr/local/bin/
~/D/P/d<TAB>          → ~/Documents/Projects/den/
./s/u/c<TAB>          → ./src/utils/completion.zig

# Works even with ambiguous segments
/u/l/s<TAB>           → /usr/local/share/
# (even though /usr/l matches lib, libexec, local)
```

### Git Command Completion

```bash
# Complete git subcommands
git st<TAB>           → git status
git che<TAB>          → Shows: checkout, cherry-pick

# Complete branch names
git checkout <TAB>    → Shows all branches (local and remote)
git merge main<TAB>   → git merge main

# Complete modified files
git add <TAB>         → Shows modified/untracked files
git diff src/<TAB>    → Shows modified files in src/

# Supported commands
# Branches: checkout, branch, merge, rebase, switch, cherry-pick
# Files: add, diff, restore, reset
```

For complete details, see [Git Completion Guide](GIT_COMPLETION.md).

## History Navigation

### Basic History

```bash
Up Arrow     # Previous command
Down Arrow   # Next command
```

### History Substring Search

```bash
# Type part of a command, then press Up/Down
# to filter history by substring

❯ git<Up>
# Shows only commands containing "git"
❯ git commit -m "fix bug"

❯ docker<Up>
# Shows only commands containing "docker"
❯ docker ps -a
```

**Features:**

- Matches substring anywhere in command (not just at start)
- Press Up/Down to navigate through matches
- Press Down past last match to return to search query
- Type any character to exit search mode

### Reverse Incremental Search (Ctrl+R)

```bash
# Press Ctrl+R to enter reverse search mode
❯
(reverse-i-search)`': _

# Type to search backwards through history
(reverse-i-search)`dock': docker ps -a

# Press Ctrl+R again to find next match
(reverse-i-search)`dock': docker build -t myapp .

# Press Enter to use the command
❯ docker build -t myapp .

# Or press Ctrl+C to cancel
```

**Features:**

- Real-time incremental search as you type
- Searches backwards from most recent
- Press Ctrl+R repeatedly to cycle through matches
- Shows matching command with search term highlighted
- Backspace to edit search query
- Just like bash/zsh!

## Keyboard Shortcuts

### Line Editing

| Key | Action |
|-----|--------|
| `Ctrl+A` | Move to beginning of line |
| `Ctrl+E` | Move to end of line |
| `Ctrl+U` | Clear line before cursor |
| `Ctrl+K` | Clear line after cursor |
| `Ctrl+W` | Delete word before cursor |
| `Alt+D` | Delete word after cursor |
| `Ctrl+T` | Transpose (swap) characters |
| `Ctrl+L` | Clear screen and redraw prompt |
| `Ctrl+C` | Cancel current line |
| `Ctrl+D` | Exit shell (if line is empty) |

### Cursor Movement

| Key | Action |
|-----|--------|
| `Left Arrow` | Move cursor left one character |
| `Right Arrow` | Move cursor right one character |
| `Ctrl+Left` / `Alt+B` | Move cursor left one word |
| `Ctrl+Right` / `Alt+F` | Move cursor right one word |
| `Home` / `Ctrl+A` | Move to beginning of line |
| `End` / `Ctrl+E` | Move to end of line |

### History

| Key | Action |
|-----|--------|
| `Up Arrow` | Previous history / Previous match (if searching) |
| `Down Arrow` | Next history / Next match (if searching) |
| `Ctrl+R` | Reverse incremental search |

### Completion

| Key | Action |
|-----|--------|
| `TAB` | Complete / Cycle through suggestions |
| `Esc` | Cancel completion |

## Advanced Line Editing

### Word Navigation

Navigate by words instead of characters for faster editing:

```bash
# Type a long command
❯ git commit -m "Add new feature to the authentication system"
                      ^cursor here

# Jump back one word (Ctrl+Left or Alt+B)
❯ git commit -m "Add new feature to the authentication system"
                  ^jumped to "new"

# Jump forward one word (Ctrl+Right or Alt+F)
❯ git commit -m "Add new feature to the authentication system"
                          ^jumped to "feature"
```

**Pro tip:** Use word navigation to quickly fix mistakes in the middle of long commands!

### Delete Word Forward (Alt+D)

Delete from cursor to end of next word:

```bash
❯ git commit -m "fix typo error in function"
              ^cursor here

# Press Alt+D
❯ git commit -m "fix  error in function"
              ^deleted "typo "

# Press Alt+D again
❯ git commit -m "fix  in function"
              ^deleted "error "
```

**Use case:** Quickly remove words without backspacing or selecting.

### Transpose Characters (Ctrl+T)

Fix common typos instantly by swapping characters:

```bash
# Oops, typed "teh" instead of "the"
❯ echo teh
          ^cursor here

# Press Ctrl+T
❯ echo the
         ^fixed! cursor moved forward
```

```bash
# Also works at end of line
❯ echo hello wordl
                     ^cursor at end

# Press Ctrl+T (swaps last two chars)
❯ echo hello world
                     ^fixed!
```

**Pro tip:** Ctrl+T is the fastest way to fix transposed letters. Much faster than backspace!

### Clear Screen (Ctrl+L)

Clear the terminal and get a fresh prompt without losing your current command:

```bash
# After lots of output
❯ ls -la
total 48
drwxr-xr-x  12 user  staff   384 Nov  9 10:30 .
drwxr-xr-x   8 user  staff   256 Nov  8 15:22 ..
[... many more lines ...]

❯ git status
# More output

# Press Ctrl+L - screen clears and you get fresh prompt
❯ _
```

**Use case:** Keep your terminal clean while working without losing your command history.

## Quick Tips

### Tip 1: Fast Directory Navigation

```bash
# Instead of
cd /usr/local/share/
# Type
cd /u/l/s<TAB>
```

### Tip 2: Find Commands in History

```bash
# Instead of pressing Up repeatedly, type part of the command
❯ docker<Up>
# Instantly shows matching docker commands
```

### Tip 3: Cycle Through Suggestions

```bash
# Don't memorize paths - cycle through options
cd Documents/<TAB><TAB><TAB>
# Cycles: Projects/ → Work/ → Personal/ →
```

### Tip 4: Complete Hidden Files

```bash
# Start with dot to show hidden files
ls .<TAB>
# Shows: .bashrc  .gitignore  .config/
```

### Tip 5: Search by Arguments

```bash
# Find commands by their flags
❯ --verbose<Up>
# Shows all commands you ran with --verbose
```

## Feature Comparison with Other Shells

### vs Bash

| Feature | Bash | Den |
|---------|------|-----|
| Tab completion | ✓ | ✓ |
| Multiple suggestions | ✓ | ✓ with cycling |
| Mid-word expansion | ✗ | ✓ |
| History substring search | ✗ | ✓ |
| Lookahead path resolution | ✗ | ✓ |

### vs Zsh

| Feature | Zsh | Den |
|---------|-----|-----|
| Tab completion | ✓ | ✓ |
| Mid-word expansion | ✓ | ✓ |
| History substring search | ✓ (plugin) | ✓ (built-in) |
| Lookahead path resolution | ✓ | ✓ |
| Fuzzy matching | ✓ | Coming soon |
| Menu selection | ✓ | Coming soon |

### vs Fish

| Feature | Fish | Den |
|---------|------|-----|
| Tab completion | ✓ | ✓ |
| Auto-suggestions | ✓ | Coming soon |
| Syntax highlighting | ✓ | Coming soon |
| History search | ✓ | ✓ |

## Common Workflows

### Workflow 1: Exploring a New Project

```bash
# Navigate quickly
cd /u/l/s/app/j<TAB>  → cd /usr/local/share/applications/java/

# List what's there
ls <TAB>
# Cycle through suggestions to explore

# Open files
vim sr<TAB>  → vim src/
```

### Workflow 2: Repeating Commands

```bash
# Find that complex docker command
❯ docker run<Up>
# Cycle through previous docker run commands

# Find by specific flag
❯ --name myapp<Up>
# Shows commands with --name myapp
```

### Workflow 3: File Operations

```bash
# Quick copy with completion
cp ~/D/P/d/R<TAB>  →  cp ~/Documents/Projects/den/README.md

# Move with abbreviation
mv /t/d/f<TAB> ./  →  mv /tmp/downloads/file.txt ./
```

## Environment

### Current Directory

```bash
pwd                  # Print working directory
cd -                # Go to previous directory
cd ~                # Go to home directory
cd                  # Go to home directory (same as cd ~)
```

### Path Completion Contexts

Den knows what to complete based on command:
```bash
cd <TAB>            # Only directories
ls <TAB>            # Files and directories
cat <TAB>           # Files and directories
mkdir <TAB>         # No completion (you're creating a new dir)
```

## Advanced Examples

### Example 1: Complex Path Navigation

```bash
# Navigate to deep directory in one step
cd /u/l/s/f/t/d/c<TAB>
# Expands to: /usr/local/share/fonts/truetype/dejavu/confavail/
```

### Example 2: Finding Old Commands

```bash
# You remember running a curl command with specific headers
❯ Content-Type<Up>
# Shows: curl -H "Content-Type: application/json"
```

### Example 3: Exploring Command Options

```bash
# What git commands have I used
git <TAB>
# Shows all git subcommands

# Cycle through to remind yourself
git <TAB><TAB><TAB>
# Cycles through: status → commit → push → pull →
```

## Customization (Coming Soon)

Future configuration options:
```bash
# ~/.den/config.json (planned)
{
  "completion": {
    "style": "cycle",           # or "menu"
    "columns": 4,               # columns in suggestion list
    "case_sensitive": false,    # case-insensitive completion
    "fuzzy_match": true,        # fuzzy path matching
    "show_hidden": false        # show hidden files by default
  },
  "history": {
    "substring_search": true,   # enable substring search
    "case_sensitive": false,    # case-insensitive search
    "max_entries": 10000        # history size
  }
}
```

## Troubleshooting

### Completion not working

1. Type more characters to narrow down options
2. Check file/directory permissions
3. Verify path exists: `ls /u/l/b`

### History search not finding commands

1. Check spelling (search is case-sensitive)
2. Make sure command is in history: `history | grep docker`
3. Verify substring exists in command

### Mid-word expansion not working

1. Path must be unique through all segments
2. Test with: `den complete "/u/l/b"`
3. Check directory permissions

## Learn More

- **[Line Editing](LINE_EDITING.md)** - Complete guide to word navigation, editing, and history search
- **[Tab Completion](TAB_COMPLETION.md)** - Complete guide to interactive completion
- **[Mid-Word Completion](MID_WORD_COMPLETION.md)** - Path abbreviation deep dive
- **[History Substring Search](HISTORY_SUBSTRING_SEARCH.md)** - History navigation guide
- **[Usage Guide](usage.md)** - General usage documentation

## Cheat Sheet Summary

**Most Useful Commands:**
```bash
# TAB completion
<text><TAB>              Complete current word
<TAB><TAB>...            Cycle through suggestions

# Path abbreviation
/u/l/b<TAB>              Expand to /usr/local/bin/

# History search
<text><Up>               Search history for text
Ctrl+R                   Reverse incremental search
<Down>                   Next match / Return to query

# Line editing
Ctrl+A / Ctrl+E          Start / End of line
Ctrl+U / Ctrl+K          Clear before / after cursor
Ctrl+W / Alt+D           Delete word backward / forward
Ctrl+T                   Transpose (swap) characters
Ctrl+L                   Clear screen
Ctrl+C                   Cancel line

# Word navigation
Ctrl+Left / Alt+B        Jump backward by word
Ctrl+Right / Alt+F       Jump forward by word

# Character navigation
Left / Right             Move one character
Up / Down                History navigation
```

**Remember:**

- TAB is your friend - use it everywhere!
- Type less, complete more
- Search history with Ctrl+R or substring search
- Path abbreviations save keystrokes
- Word navigation is faster than character movement
- Ctrl+T fixes typos instantly

---

**Pro Tip:** The fastest way to learn is to use Tab and Up Arrow constantly. You'll discover features naturally!
