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
7. [Customizing Keybindings with `bindkey`](#customizing-keybindings-with-bindkey)

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

### Delete Word Backward (Ctrl+W / Option+Delete)

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
| `Ctrl+Left` / `Option+Left` / `Alt+B` | Move left one word |
| `Ctrl+Right` / `Option+Right` / `Alt+F` | Move right one word |
| `Ctrl+A` / `Home` | Move to beginning of line |
| `Ctrl+E` / `End` | Move to end of line |

### Deletion Commands

| Key | Action |
|-----|--------|
| `Backspace` / `Ctrl+H` | Delete character before cursor |
| `Delete` | Delete character at cursor |
| `Ctrl+W` / `Option+Delete` | Delete word before cursor |
| `Alt+D` / `Ctrl+Delete` / `Option+Forward Delete` | Delete word after cursor |
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
| `Esc` | Cancel completion or reverse search |

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
  Ctrl+W/Option+Delete Delete word backward
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

## Customizing Keybindings with `bindkey`

Every default binding has a name, and `bindkey` rebinds it. The syntax is zsh's,
so lines copied out of a `.zshrc` work as written.

```sh
bindkey '^T' kill-whole-line        # rebind Ctrl+T
bindkey '\e[1;5C' forward-word      # Ctrl+Right
bindkey -s '^X^Z' 'fg\n'            # insert literal text and run it
bindkey -r '^A'                     # unbind
bindkey                             # list the current keymap
bindkey -L                          # list it as re-runnable bindkey commands
bindkey -l                          # list the keymap names
```

Put them in `~/.denrc`, or use the `keybindings.custom` section of `den.jsonc`
(see [Configuration](./config.md#keybindings)). Both take effect immediately when
run at the prompt.

### Options

| Option | Effect |
|--------|--------|
| *(none)* | List the bindings of the current keymap |
| `<seq>` | Show what one sequence is bound to; exit status 1 if it is unbound |
| `<seq> <widget>` | Bind a sequence to a widget |
| `-s <seq> <string>` | Bind a sequence to literal input, dispatched as if typed |
| `-r <seq>...` | Unbind. Succeeds quietly if the key was already free |
| `-l` | List keymap names |
| `-L` | List bindings as `bindkey` commands. The output re-runs exactly |
| `-e` / `-v` | Select the emacs or vi-insert keymap as `main` |
| `-a` | Operate on `vicmd` (same as `-M vicmd`) |
| `-M <keymap>` | Operate on a named keymap |
| `-d` | Restore the compiled-in defaults |

Keymaps are `emacs`, `viins`, `vicmd`, `vireplace` and `isearch`, plus `main`,
which follows whichever of `emacs`/`viins` is selected.

There is no `menuselect` keymap. While the completion menu is open it owns the
arrow keys, and any other key dismisses it and then does its usual job — except
Enter, Tab and Shift+Tab, Escape, Ctrl+C and Ctrl+D, which manage the menu
themselves.

`-A`, `-N`, `-D`, `-R`, `-p` and `-m` are recognised and rejected with the
reason, rather than silently doing nothing.

### Key notation

| Form | Meaning |
|------|---------|
| `^A` … `^Z`, `^@`, `^[`, `^?` | Control characters; `^?` is Delete |
| `\C-x` | Same as `^x` |
| `\M-x`, `\ex`, `\Ex` | Escape prefix followed by `x` |
| `\e[A` or `^[[A` | A full escape sequence, such as Up |
| `\a \b \f \n \r \t \v` | The usual control characters |
| `\\ \^ \" \'` | A literal backslash, caret, quote |
| `\0`, `\101` | Octal, up to three digits |
| `\x1b`, `\x7` | Hex, one or two digits |
| anything else | Itself |

Two things to know:

- **`\M-x` means the ESC prefix, not the high bit.** Den reads input as bytes
  with a dedicated escape path, and Terminal.app and iTerm2 both send ESC-prefix
  for Option by default, so `\M-b` and `\eb` are the same binding. This is why
  `bindkey -m` is rejected.
- **Sequences are at most 8 bytes.** That covers everything a terminal sends for
  a key, including `^[[1;5C` and bracketed paste. Longer specs are rejected
  outright rather than silently truncated into a binding that could never fire.

### Multi-key sequences

A binding may be several keys, and a sequence that is the prefix of a longer one
still works: with `^X(` bound, a lone `^X` waits briefly to see whether the rest
arrives. The wait is one terminal read timeout, roughly 100ms, the same pause
Escape has always had.

### Widget names

`bindkey -L` prints every widget currently bound, which is the authoritative
list. The common ones:

| Widget | Does |
|--------|------|
| `beginning-of-line`, `end-of-line` | Move to the start or end |
| `backward-char`, `forward-char` | Move one character |
| `backward-word`, `forward-word` | Move one word |
| `up-line-or-history`, `down-line-or-history` | History navigation |
| `history-incremental-search-backward` | Reverse search (Ctrl+R; `/` in vi normal mode) |
| `expand-or-complete`, `reverse-menu-complete` | Completion, forwards or back |
| `backward-delete-char`, `delete-char` | Delete one character |
| `kill-line`, `backward-kill-line`, `kill-whole-line` | Kill to end, to start, or all |
| `kill-word`, `backward-kill-word` | Kill a word |
| `yank` | Paste the last kill |
| `yank-pop` | Replace a yank with the kill before it (**M-y**) |
| `transpose-chars` | Swap the characters around the cursor |
| `undo` | Undo the last edit |
| `redo` | Step forward again (**Ctrl+R** in vi normal mode) |
| `clear-screen`, `redisplay` | Repaint |
| `accept-line` | Run the line |
| `send-break` | Abandon the line (Ctrl+C) |
| `quoted-insert` | Insert the next key literally |
| `start-kbd-macro`, `end-kbd-macro`, `call-last-kbd-macro` | Keyboard macros |
| `vi-cmd-mode`, `vi-insert` | Switch vi modes |
| `vi-delete`, `vi-change`, `vi-yank` | Vi operators: wait for a motion, then act on it |
| `vi-end-of-line` | Vi's `$`: the last character, not past it |
| `vi-find-next-char`, `vi-find-prev-char` | `f` and `F`: to the next/previous occurrence |
| `vi-find-next-char-skip`, `vi-find-prev-char-skip` | `t` and `T`: stop beside it |
| `vi-repeat-find`, `vi-rev-repeat-find` | `;` and `,` |
| `vi-set-mark`, `vi-goto-mark` | `m` and backtick: record a position, go back to it |
| `vi-repeat-change` | `.`: do the last change again |

Killed text goes on a ring of the last 16 kills. **Ctrl+Y** pastes the newest and
**M-y** straight after it swaps in the one before, repeatedly, wrapping round at
the end. It only works directly after a yank; anything else ends the run and M-y
beeps.

**Ctrl+R** redoes in vi normal mode, as in vim. In emacs mode `redo` has no key of
its own — bind one if you want it, e.g. `bindkey '^X^R' redo`. Editing after an
undo replaces what redo would have replayed, as in any editor.
| `digit-argument` | Accumulate a numeric prefix (vi `1`-`9`) |
| `vi-digit-or-beginning-of-line` | vi `0`: a count digit, or the start of the line |
| `undefined-key` | Beep |
| `ignore` | Do nothing |

zsh aliases are accepted where den has an equivalent, so `previous-history`,
`vi-backward-char`, `complete-word` and similar all resolve. Composite widgets
whose behaviour depends on context carry a `den-` prefix, such as
`den-forward-char-or-autosuggest`, which accepts an inline suggestion at the end
of the line and otherwise moves right.

Counts work in vi normal mode: `digit-argument` is bound to `1`-`9` and
`vi-digit-or-beginning-of-line` to `0`, and the movement and
single-character delete widgets consume the count, so `3h` and `2x` behave. Only
those widgets honour it; others ignore a pending count.

### Vi operators

`d`, `c` and `y` wait for a motion and act on the text between where the cursor
was and where the motion leaves it: `dw`, `d$`, `de`, `db`, `d0`, and the `c` and
`y` forms of each. Pressing the operator again takes the whole line, so `dd`,
`cc` and `yy` need no separate binding. `p` pastes what was taken.

Counts compose from either side — `d2w` and `2dw` both delete two words — and the
operator applies to whatever the motion key is *currently* bound to, so
rebinding `w` also changes what `dw` covers. A key that is not a motion abandons
the operator, as vi does.

Motions are exclusive except `e` and `$`, which take the character they land on:
`de` removes the last letter of the word, `dw` stops before the next one.

### Character searches

`f<char>` moves to the next occurrence of a character and `F<char>` to the
previous; `t` and `T` stop beside it rather than on it. `;` repeats the last
search and `,` does it the other way without replacing what `;` repeats.

They work as motions, so `df,` deletes through the next comma and `dt,` stops
short of it. Forward searches are inclusive, backward ones exclusive, which is
why `dF,` leaves the character under the cursor alone. A character that is not on
the line does nothing at all, and drops any pending operator rather than applying
it to something arbitrary.

The key after `f` is the character to look for, never a binding of its own, so
`fd` searches for a `d` rather than running `vi-delete`.

### Text objects

With an operator waiting, `i` selects the inside of something and `a` the whole
of it including its delimiters:

| Object | Covers |
|--------|--------|
| `iw` / `aw` | The word under the cursor; `aw` adds the whitespace after it, or before it at the end of a line |
| `i"` `i'` ``i` `` | What sits between the quotes; the `a` forms take the quotes too |
| `i(` `i[` `i{` `i<` | What sits between the brackets, counted outwards so this works from inside nesting. `ib` and `iB` are aliases for `(` and `{` |

So `diw` deletes a word wherever the cursor is in it, `ci"` replaces a quoted
string, and `da(` removes a parenthesised group with its parentheses. `i` and `a`
only mean this while an operator is pending — on their own they are still the
ways into insert mode.

An object the cursor is not inside does nothing and drops the operator.

One irregular pair, as in vi: `cw` on a word behaves as `ce`, changing the word
without swallowing the space after it. `dw` does take the space.

### Marks and repeating a change

`m<letter>` records where the cursor is, and a backtick followed by that letter
goes back to it; `'` does the same, there being only one line to go to. Marks hold positions in the
line being edited, so they last as long as it does, and only `a`-`z` are stored.
Going to a mark is a motion, so ``d`a`` covers the text between here and there.

`.` repeats the last change. It replays the keys that made it rather than the
effect, so the original count and any inserted text come with it: `3x` then `.`
takes three more characters, and `cwXX` then Escape then `w` then `.` changes the
next word to `XX` as well. Moving around does not count as a change, so `.` keeps
repeating the last edit rather than the last keystroke.

Names den does not have — `universal-argument`, `vi-repeat-change` — are reported
as unknown rather than bound to something that quietly does nothing.

### User-defined widgets

`zle -N my-widget my-function` is not implemented, so a widget cannot yet be a
shell function. `zle` is a recognised command that says so, and binding a name
that happens to be a shell function points this out rather than just reporting an
unknown widget.

## What's Next

Future line editing features planned:

- Multiple cursors
- `zle -N` user-defined widgets backed by shell functions
- `universal-argument`, and counts honoured by more widgets

Stay tuned!
