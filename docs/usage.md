# Usage

Den can be used interactively, as a script interpreter, or as your login shell.

## Interactive shell

```bash
den
```

You get a two-line prompt ending in `❯`, with inline autosuggestions, syntax highlighting, and tab completion as you type.

```text
~/projects
❯ echo "Hello from Den!"
Hello from Den!
```

## Run a single command

```bash
den -c 'echo "Today is $(date +%Y-%m-%d)"'
```

## Run a script

```bash
den script.sh        # run a script file
./script.sh          # if it starts with: #!/usr/bin/env den
```

```bash
#!/usr/bin/env den
export PROJECT="my-app"
for file in *.zig; do
  echo "compiling $(basename "$file")"
done
```

See the [Scripting guide](./SCRIPTING.md) for the full scripting language.

## As your login shell

Add Den to `/etc/shells` and set it with `chsh` — see the [Installation guide](./install.md#use-den-as-your-login-shell). On startup Den sources `~/.denrc`; configure the prompt, history, and aliases in `~/.config/den.jsonc` ([Configuration](./config.md)).

## Common flags

| Flag | Description |
|---|---|
| `-c <command>` | Run a command string and exit |
| `-l` / `--login` | Run as a login shell |
| `-i` / `--interactive` | Force interactive mode |
| `--norc` | Skip loading `~/.denrc` |
| `--serve` / `--connect` | [Distributed sessions](./EXTENDED_FEATURES.md) |
| `--lsp` | Run the [language server](./EXTENDED_FEATURES.md) |

## Next steps

- [Features](./FEATURES.md) — everything Den can do
- [Builtins](./BUILTINS.md) — the built-in command reference
- [Quick Reference](./QUICK_REFERENCE.md) — cheat sheet
