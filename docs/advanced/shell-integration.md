# Shell Integration

How to make Den your daily driver and wire it into the rest of your toolchain.

## Use Den as your login shell

```bash
echo "$(command -v den)" | sudo tee -a /etc/shells   # allow it
chsh -s "$(command -v den)"                            # set it
```

Open a new terminal; Den sources `~/.denrc` on startup. Keep your previous shell in `/etc/shells` as a fallback (`chsh -s /bin/zsh` to revert). Full steps: [Installation](../install.md#use-den-as-your-login-shell).

## Share config with another shell

Keep environment, `$PATH`, and aliases in POSIX-compatible files and `source` them from both `~/.denrc` and your fallback `~/.zshrc`/`~/.bashrc`, so there's a single source of truth. See [Advanced Configuration](./configuration.md).

## Terminal setup

Set your terminal's "shell to run" to Den's path (e.g. `~/.local/bin/den`), or rely on the login shell set via `chsh`. Den emits a two-line prompt with a `❯` symbol by default; customize it in [Themes](../THEMES.md).

Set `DEN_SHELL_INTEGRATION=1` in the terminal's environment to enable [OSC 133 prompt and command markers](https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration). Interactive terminal sessions report when the prompt is ready, when a command starts, and its exit status. Den sends the current directory as an OSC 7 file URI before each prompt and before a command if the interactive shell has changed directories since the last report. For example, in `cd project && make`, the terminal receives the project directory before the build output. The directory marker stays on the terminal and is also disabled for scripts and `TERM=dumb`.

## Editor / LSP integration

Den ships a Language Server for shell scripts:

```bash
den --lsp        # stdio LSP: diagnostics, hover, completion
```

Point your editor's LSP client for `shellscript` at `den --lsp`. See [Extended Features](../EXTENDED_FEATURES.md).

## Remote / distributed sessions

Attach to a Den session over the network (loopback-only by default):

```bash
den --serve                    # host (binds 127.0.0.1:7878)
den --connect 127.0.0.1:7878   # client
```

> The server is an unauthenticated remote shell. It refuses non-loopback addresses unless `DEN_ALLOW_REMOTE=1`; tunnel over SSH for real remote use. See [Extended Features](../EXTENDED_FEATURES.md).

## Scripting in CI

Den runs scripts and one-liners non-interactively, which is handy in CI:

```bash
den -c 'for f in src/*.zig; do echo "$f"; done'
den build.den
```

## See also

- [Installation](../install.md) · [Advanced Configuration](./configuration.md) · [Extended Features](../EXTENDED_FEATURES.md) · [Themes](../THEMES.md)
