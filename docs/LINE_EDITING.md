# Line Editing in Den Shell

A comprehensive guide to Den's line editing capabilities, including word navigation, text manipulation, and history search.

## Overview

Den provides a powerful line editor with Emacs/Readline-style keybindings. All features work seamlessly together, making command-line editing fast and intuitive.

**Philosophy:** Learn once, use everywhere. Den follows the same keybindings as bash, zsh, and most Unix tools.

---

## Table of Contents

1. [Word Navigation](#word-navigation)
2. [Word Deletion](#word-deletion)
3. [Character Transposition](#character-transposition)
4. [Screen Management](#screen-management)
5. [History Search](#history-search)
6. [Complete Keybinding Reference](#complete-keybinding-reference)

---

## Word Navigation

### Overview

Jump between words instead of moving character-by-character. Dramatically speeds up editing long commands.

### Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+Left` | Jump backward one word |
| `Ctrl+Right` | Jump forward one word |
| `Alt+B` | Jump backward one word (Emacs style) |
| `Alt+F` | Jump forward one word (Emacs style) |

### How It Works

Den treats whitespace as word boundaries. Navigation jumps to the start of the previous/next word.

```bash
❯ git commit -m "Add new feature"
     ^   ^      ^  ^   ^   ^
     word boundaries
```

### Examples

#### Example 1: Navigate Backward

```bash
❯ git commit -m "fix authentication bug"
                                          ^cursor at end

# Press Ctrl+Left once
❯ git commit -m "fix authentication bug"
                               ^jumped to "bug"

# Press Ctrl+Left again
❯ git commit -m "fix authentication bug"
                       ^jumped to "authentication"

# Press Ctrl+Left again
❯ git commit -m "fix authentication bug"
                   ^jumped to "fix"
```

#### Example 2: Navigate Forward

```bash
❯ git commit -m "update dependencies"
     ^cursor at start

# Press Ctrl+Right once
❯ git commit -m "update dependencies"
         ^jumped to "commit"

# Press Ctrl+Right again
❯ git commit -m "update dependencies"
                ^jumped to "-m"
```

#### Example 3: Fix Mistakes Quickly

```bash
# Oops, wrong command in the middle
❯ git commit -m "fix bug in authentication"
                                             ^cursor here

# Jump back to "commit"
# Ctrl+Left, Ctrl+Left, Ctrl+Left, Ctrl+Left
❯ git commit -m "fix bug in authentication"
         ^

# Delete "commit" (Ctrl+W)
❯ git -m "fix bug in authentication"
         ^

# Type "push"
❯ git push -m "fix bug in authentication"
              ^
```

### Tips & Tricks

- **Combine with deletion:** Use Ctrl+W after navigating backward to delete specific words
- **Alt vs Ctrl:** Both work the same - use whichever is more comfortable
- **Works everywhere:** Same behavior as bash, zsh, emacs, readline

---

## Word Deletion

### Delete Word Backward (Ctrl+W)

Deletes from cursor position back to the start of the current/previous word.

```bash
❯ git commit --amend
                       ^cursor here

# Press Ctrl+W
❯ git commit
                ^deleted "--amend"

# Press Ctrl+W again
❯ git
         ^deleted "commit"
```

**Use case:** Remove the last word you typed without backspacing character-by-character.

### Delete Word Forward (Alt+D)

Deletes from cursor position forward to the end of the next word.

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

**Use case:** Remove words ahead of the cursor without selecting or cutting.

### Combining Forward and Backward Deletion

```bash
# Original command
❯ echo one two three four five six
              ^cursor on "two"

# Delete "two" (Alt+D)
❯ echo one  three four five six
              ^

# Delete "one " (Ctrl+W)
❯ echo  three four five six
          ^

# Result: Removed "one two" efficiently
```

### Delete vs Kill

Den implements true deletion:

- **Ctrl+W**/**Alt+D**: Delete text (no clipboard)
- **Ctrl+U**/**Ctrl+K**: Kill text (may support yank in future)

---

## Character Transposition

### Overview

Ctrl+T swaps the character before the cursor with the character at the cursor. Perfect for fixing common typing mistakes.

### Keybinding

| Key | Action |
|-----|--------|
| `Ctrl+T` | Transpose (swap) characters |

### Behavior

1. **In the middle of a line:** Swaps char before cursor with char at cursor, moves cursor forward
2. **At the end of a line:** Swaps the last two characters

### Examples

#### Example 1: Fix "teh" → "the"

```bash
❯ echo teh world
          ^h cursor after 'h'

# Press Ctrl+T
❯ echo the world
         ^e cursor moved forward
```

#### Example 2: Fix at End of Line

```bash
❯ echo hello wordl
                     ^cursor at end

# Press Ctrl+T (swaps 'd' and 'l')
❯ echo hello world
                     ^fixed!
```

#### Example 3: Multiple Transpositions

```bash
# Multiple typos
❯ echo hte owrld
          ^cursor after 't'

# Press Ctrl+T
❯ echo the owrld
         ^fixed "hte" → "the"

# Move to 'r' position
# Ctrl+Right, Ctrl+Right, Right, Right
❯ echo the owrld
              ^cursor after 'r'

# Press Ctrl+T
❯ echo the world
             ^fixed "owrld" → "world"
```

#### Example 4: Common Mistakes Fixed Instantly

| Before | After | Keystrokes |
|--------|-------|------------|
| `comit` | `commit` | Ctrl+T |
| `recieve` | `receive` | (navigate) Ctrl+T |
| `tset` | `test` | Ctrl+T Ctrl+T |

### Tips & Tricks

- **Fastest typo fix:** For transposed letters, Ctrl+T is faster than backspace+retype
- **Works on letters, numbers, symbols:** Any characters can be swapped
- **Combine with word navigation:** Jump to the typo, press Ctrl+T, done!

---

## Screen Management

### Clear Screen (Ctrl+L)

Clears the terminal screen and redraws the prompt with your current command intact.

### Keybinding

| Key | Action |
|-----|--------|
| `Ctrl+L` | Clear screen and redraw prompt |

### Behavior

1. Clears entire terminal screen (like `clear` command)
2. Moves cursor to top-left of terminal
3. Redraws the prompt
4. Restores your current input buffer
5. Maintains cursor position within the buffer

### Example

```bash
# After running many commands
❯ ls -la
total 128
drwxr-xr-x  15 user  staff   480 Nov  9 10:30 .
drwxr-xr-x  20 user  staff   640 Nov  8 15:22 ..
-rw-r--r--   1 user  staff  1234 Nov  9 09:15 file1.txt
[... 50 more lines of output ...]

❯ git status
On branch main
Your branch is up to date with 'origin/main'.
[... more output ...]

❯ git commit -m "work in progress"
                               ^typing this

# Press Ctrl+L - screen clears instantly

# New clean screen
❯ git commit -m "work in progress"
                               ^cursor position preserved
```

### Use Cases

- **Before important output:** Clear clutter before running a command with important output
- **During long sessions:** Keep terminal clean and readable
- **Presentation mode:** Clean screen for demos or pair programming
- **Privacy:** Clear sensitive information from view

### Tips & Tricks

- **History preserved:** Clearing screen doesn't clear command history
- **Command preserved:** Current typing is never lost
- **Fast refresh:** Much faster than typing `clear` + re-typing command
- **Works mid-edit:** Can clear screen while editing a long command

### Clear vs Ctrl+L

| Action | Command | Ctrl+L |
|--------|---------|--------|
| Clear screen | ✓ | ✓ |
| Preserve current input | ✗ | ✓ |
| History preserved | ✓ | ✓ |
| Cursor position preserved | ✗ | ✓ |
| Speed | Slow | Instant |

---

## History Search

### Reverse Incremental Search (Ctrl+R)

Search backwards through command history as you type. Just like bash/zsh.

### Keybinding

| Key | Action |
|-----|--------|
| `Ctrl+R` | Enter reverse search mode |
| `Ctrl+R` (in search) | Find next match |
| `Ctrl+C` | Cancel search |
| `Enter` | Accept and execute |
| `Backspace` | Edit search query |

### How It Works

1. Press `Ctrl+R` to enter search mode
2. Type search query - matches appear in real-time
3. Press `Ctrl+R` again to find next older match
4. Press `Enter` to use the command
5. Press `Ctrl+C` to cancel

### Example Session

```bash
# Press Ctrl+R
(reverse-i-search)`': _

# Type "dock"
(reverse-i-search)`dock': docker ps -a

# Press Ctrl+R to find next match
(reverse-i-search)`dock': docker build -t myapp .

# Press Ctrl+R again
(reverse-i-search)`dock': docker run -d --name web nginx

# Press Enter to use this command
❯ docker run -d --name web nginx
```

### Search Features

- **Substring matching:** Matches anywhere in command
- **Case-sensitive:** Search respects case
- **Real-time:** Updates as you type
- **Backwards search:** Starts from most recent
- **Multiple matches:** Cycle with repeated Ctrl+R

### Advanced Usage

#### Search by Arguments

```bash
# Find all commands with specific flag
(reverse-i-search)`--verbose': npm run build --verbose
```

#### Search by Command

```bash
# Find specific git command
(reverse-i-search)`git commit': git commit -m "feat: add feature"
```

#### Refine Search

```bash
# Start with broad search
(reverse-i-search)`docker': docker run nginx

# Add more characters to narrow down
(reverse-i-search)`docker run': docker run -d nginx

# Even more specific
(reverse-i-search)`docker run -d': docker run -d --name web nginx
```

### Tips & Tricks

- **Combine with history:** Ctrl+R for recent, Up arrow for sequential
- **Short queries:** Start with 2-3 characters, refine if needed
- **Common patterns:** Search for flags/options to find similar commands
- **Edit after accept:** Accepting a match puts it in the buffer for editing

---

## Complete Keybinding Reference

### Movement Commands

| Key | Action |
|-----|--------|
| `Left` | Move left one character |
| `Right` | Move right one character |
| `Ctrl+Left` / `Alt+B` | Move left one word |
| `Ctrl+Right` / `Alt+F` | Move right one word |
| `Ctrl+A` / `Home` | Move to beginning of line |
| `Ctrl+E` / `End` | Move to end of line |

### Deletion Commands

| Key | Action |
|-----|--------|
| `Backspace` / `Ctrl+H` | Delete character before cursor |
| `Delete` | Delete character at cursor |
| `Ctrl+W` | Delete word before cursor |
| `Alt+D` | Delete word after cursor |
| `Ctrl+U` | Delete from cursor to beginning of line |
| `Ctrl+K` | Delete from cursor to end of line |

### Editing Commands

| Key | Action |
|-----|--------|
| `Ctrl+T` | Transpose characters |
| `Ctrl+L` | Clear screen |
| `Ctrl+C` | Cancel current line |
| `Ctrl+D` | Exit shell (if line empty) |

### History Commands

| Key | Action |
|-----|--------|
| `Up` | Previous command |
| `Down` | Next command |
| `Ctrl+R` | Reverse incremental search |

### Completion Commands

| Key | Action |
|-----|--------|
| `Tab` | Complete / cycle suggestions |
| `Esc` | Cancel completion |

---

## Workflow Examples

### Workflow 1: Fix a Command Quickly

```bash
# You typed this (wrong command in middle)
❯ git status && git pull && git commit -m "test"
                                   ^oops, meant "push"

# Jump back to "commit"
# Ctrl+Left (3 times)
❯ git status && git pull && git commit -m "test"
                                   ^

# Delete "commit"
# Ctrl+W
❯ git status && git pull && git  -m "test"
                                   ^

# Type "push"
❯ git status && git pull && git push -m "test"
                                        ^
# Fixed in seconds
```

### Workflow 2: Clean Up a Messy Command

```bash
# Started with this
❯ docker run -d --name web --port 8080 nginx extra stuff here
                                                 ^delete this

# Jump to "extra"
# Ctrl+Left (3 times)
❯ docker run -d --name web --port 8080 nginx extra stuff here
                                                ^

# Delete to end of line
# Ctrl+K
❯ docker run -d --name web --port 8080 nginx
                                                ^
```

### Workflow 3: Transpose and Search

```bash
# Fix typo then search for similar command
❯ git comit -m "fix bug"
         ^typo here

# Navigate to typo: Ctrl+Left, Ctrl+Left, Right, Right, Right, Right
❯ git comit -m "fix bug"
            ^

# Fix it: Ctrl+T
❯ git commit -m "fix bug"
             ^

# Clear line and search for similar: Ctrl+U, Ctrl+R
(reverse-i-search)`fix': git commit -m "fix authentication"

# Found it! Use as template
```

### Workflow 4: Power User Command Building

```bash
# Start typing
❯ docker run

# Realize you need to check something - clear screen
# Ctrl+L

# Clean screen, command preserved
❯ docker run

# Continue building command with word navigation
❯ docker run -d --name myapp -p 8080:80
                   ^use Ctrl+Left/Right to navigate
                   ^use Alt+D to delete mistakes
                   ^use Ctrl+T to fix typos
```

---

## Comparison with Other Shells

### Bash Compatibility

| Feature | Bash | Den |
|---------|------|-----|
| Ctrl+A/E | ✓ | ✓ |
| Ctrl+U/K | ✓ | ✓ |
| Ctrl+W | ✓ | ✓ |
| Alt+D | ✓ | ✓ |
| Ctrl+T | ✓ | ✓ |
| Ctrl+L | ✓ | ✓ |
| Ctrl+R | ✓ | ✓ |
| Ctrl+Left/Right | ✓ | ✓ |
| Alt+B/F | ✓ | ✓ |

**Result:** 100% compatible with bash keybindings!

### Zsh Compatibility

| Feature | Zsh | Den |
|---------|-----|-----|
| Word navigation | ✓ | ✓ |
| Character transpose | ✓ | ✓ |
| Reverse search | ✓ | ✓ |
| Line editing | ✓ | ✓ |

**Result:** All standard zsh line editing features supported!

### Emacs Compatibility

Den follows Emacs keybindings:

- `Ctrl+B/F` - Character movement (coming soon)
- `Ctrl+P/N` - Line movement (coming soon)
- `Alt+B/F` - Word movement ✓
- `Alt+D` - Delete word forward ✓
- `Ctrl+T` - Transpose ✓

---

## Tips for Maximum Efficiency

### 1. Learn Word Navigation First

Most impactful feature. Start using Ctrl+Left/Right today.

### 2. Use Ctrl+T for Typos

Faster than backspace for transposed letters.

### 3. Combine Commands

- Navigate with Ctrl+Left/Right
- Delete with Ctrl+W or Alt+D
- Fix with Ctrl+T

### 4. Use Ctrl+R for History

Better than Up arrow for finding old commands.

### 5. Keep Screen Clean

Ctrl+L before important output keeps terminal readable.

### 6. Practice the Patterns

- Jump backward, delete word (Ctrl+Left, Ctrl+W)
- Jump forward, delete word (Ctrl+Right, Alt+D)
- Fix typo in place (Navigate, Ctrl+T)

---

## Common Patterns

### Pattern 1: Delete Middle Word

```
Ctrl+Left (to word) → Ctrl+W (delete it)
```

### Pattern 2: Replace Middle Word

```
Ctrl+Left (to word) → Ctrl+W (delete) → type new word
```

### Pattern 3: Fix Typo

```
Ctrl+Left/Right (to typo) → Ctrl+T (swap)
```

### Pattern 4: Clean and Search

```
Ctrl+L (clear) → Ctrl+R (search)
```

### Pattern 5: Delete Rest of Line

```
Ctrl+Left/Right (to position) → Ctrl+K (kill to end)
```

---

## Troubleshooting

### Ctrl+Left/Right Not Working

Some terminals send different escape sequences. Try:

- Use `Alt+B` / `Alt+F` instead
- Check terminal settings for "Option as Meta key"
- Verify terminal emulation is correct

### Alt+D Not Working

MacOS issue - Option key might not be set as Meta:

- iTerm2: Preferences → Profiles → Keys → Set Option as Meta
- Terminal.app: Preferences → Profiles → Keyboard → Use Option as Meta

### Ctrl+R Shows Nothing

History might be empty:

- Run some commands first
- Check history file exists
- Verify history is being saved

### Transpose Not Working as Expected

Cursor position matters:

- Must be after at least one character
- At end of line: swaps last two chars
- In middle: swaps char before and at cursor

---

## Quick Reference Card

```
Movement:
  Ctrl+A/Home       Beginning of line
  Ctrl+E/End        End of line
  Ctrl+Left/Alt+B   Previous word
  Ctrl+Right/Alt+F  Next word

Deletion:
  Ctrl+W            Delete word backward
  Alt+D             Delete word forward
  Ctrl+U            Delete to start
  Ctrl+K            Delete to end

Editing:
  Ctrl+T            Transpose chars
  Ctrl+L            Clear screen

History:
  Ctrl+R            Reverse search
  Up/Down           Navigate history

Completion:
  Tab               Complete/cycle
  Esc               Cancel
```

---

## What's Next

Future line editing features planned:

- Kill ring with Ctrl+Y (yank)
- Multiple cursors
- Visual selection mode
- Undo/redo (Ctrl+_)
- Macros

Stay tuned!
