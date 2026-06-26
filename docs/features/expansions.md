# Expansions

Before a command runs, Den expands the words on the line. Expansions happen **per command, at execution time** — so a variable set or a directory changed by an earlier part of a chain is visible to a later part:

```bash
export DIR=/etc && cd "$DIR" && ls *.conf   # globs against /etc, not the old cwd
```

## Variable expansion

```bash
echo $HOME            # value of HOME
echo ${HOME}          # braces disambiguate: ${VAR}_suffix
echo ${UNSET:-default}  # use "default" if UNSET is empty/unset
echo ${#PATH}         # length of the value
echo ${FILE#*.}       # strip shortest leading match (prefix removal)
```

**Special variables:**

| Var | Meaning |
|---|---|
| `$?` | exit status of the last command |
| `$$` | PID of the shell |
| `$!` | PID of the last background job |
| `$_` | last argument of the previous command |
| `$0`–`$9` | positional parameters |
| `$@`, `$*` | all positional parameters |
| `$#` | number of positional parameters |

## Command substitution

Capture a command's output into the line:

```bash
echo "today is $(date +%Y-%m-%d)"
files=$(ls | wc -l)
```

Backticks (`` `…` ``) also work, but `$(…)` nests cleanly:

```bash
echo $(echo $(echo deep))
```

## Arithmetic expansion

```bash
echo $(( 2 + 3 * 4 ))     # 14
echo $(( 2 ** 10 ))       # 1024
echo $(( (a + b) % 7 ))   # uses shell variables a, b
```

Operators: `+ - * / % **`, parentheses, and comparisons.

## Brace expansion

```bash
echo {1..5}          # 1 2 3 4 5
echo {a..e}          # a b c d e
echo file.{txt,md}   # file.txt file.md
mkdir -p src/{lib,bin,test}
```

## Tilde expansion

```bash
echo ~              # your home directory
echo ~/projects     # path under home
echo ~user          # another user's home
```

## Glob expansion

```bash
ls *.zig            # all .zig files in the cwd
ls **/*.txt         # recursive match
```

Unmatched globs are left literal (no `nullglob` by default). Den also supports **zsh glob qualifiers** — see [zsh Compatibility](../ZSH_MIGRATION.md).

## Quoting

- **Double quotes** allow `$` expansion: `echo "$HOME"`.
- **Single quotes** are literal: `echo '$HOME'` prints `$HOME`.
- A backslash escapes the next character: `echo \$HOME`.

## See also

- [Scripting](../SCRIPTING.md) · [Features overview](../FEATURES.md)
