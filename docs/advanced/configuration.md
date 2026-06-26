# Advanced Configuration

This page covers patterns beyond the [Configuration reference](../config.md): layered config, project-local overrides, and sharing settings with other shells.

## Layered config (project-local overrides)

Den loads `den.jsonc` from the first location that exists, checked in order:

1. `./den.jsonc`
2. `./config/den.jsonc`
3. `./.config/den.jsonc`
4. `~/.config/den.jsonc`

That means a repository can ship its own `den.jsonc` (e.g. a project-specific prompt or alias set) that takes effect whenever you work inside it, falling back to your personal config elsewhere.

## Splitting `~/.denrc`

`~/.denrc` is plain shell sourced at startup. Keep it small and `source` focused files so the same environment works in Den *and* a fallback shell:

```bash
# ~/.denrc
source "$HOME/.dotfiles/env.sh"      # exports + PATH
source "$HOME/.dotfiles/aliases.sh"  # aliases
```

```bash
# ~/.zshrc (fallback) — single source of truth
source "$HOME/.dotfiles/env.sh"
source "$HOME/.dotfiles/aliases.sh"
```

> Keep shared files POSIX-compatible (no shell-specific syntax) so both shells agree.

## PATH on a fresh login

On macOS, GUI terminals start a login shell with a minimal `PATH`. Den builds the full system `PATH` from `/etc/paths` and `/etc/paths.d/*` automatically (like `path_helper`), then your `~/.denrc` exports layer on top. Prepend your own directories in `env.sh`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Conditional configuration

Because `~/.denrc` is a script, you can branch on environment:

```bash
[ -n "$SSH_CONNECTION" ] && export EDITOR=vim || export EDITOR="code --wait"
command -v eza >/dev/null && alias ls='eza'
```

## Skipping startup files

```bash
den --norc        # start without sourcing ~/.denrc
```

## See also

- [Configuration reference](../config.md) · [Themes](../THEMES.md) · [Shell Integration](./shell-integration.md)
