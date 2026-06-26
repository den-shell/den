# Installation

Den is a single, dependency-free native binary. Install a prebuilt release, use a package manager, or build from source.

## Homebrew (macOS / Linux)

```sh
brew install stacksjs/tap/den
```

## Install script

Downloads the latest release binary for your platform and installs it to `/usr/local/bin` (or `~/.local/bin` for a user-local install):

```sh
curl -fsSL https://raw.githubusercontent.com/stacksjs/den/main/scripts/install.sh | bash
```

Environment variables: `DEN_VERSION` (default `latest`), `INSTALL_DIR`, `FORCE=true`.

## Prebuilt binaries

Download the binary that matches your platform from the [GitHub releases](https://github.com/stacksjs/den/releases), then make it executable and put it on your `PATH`:

::: code-group

```sh [macOS (arm64)]
curl -L https://github.com/stacksjs/den/releases/latest/download/den-darwin-arm64.tar.gz | tar xz
chmod +x den && mv den /usr/local/bin/den
```

```sh [macOS (x64)]
curl -L https://github.com/stacksjs/den/releases/latest/download/den-darwin-x64.tar.gz | tar xz
chmod +x den && mv den /usr/local/bin/den
```

```sh [Linux (arm64)]
curl -L https://github.com/stacksjs/den/releases/latest/download/den-linux-arm64.tar.gz | tar xz
chmod +x den && mv den /usr/local/bin/den
```

```sh [Linux (x64)]
curl -L https://github.com/stacksjs/den/releases/latest/download/den-linux-x64.tar.gz | tar xz
chmod +x den && mv den /usr/local/bin/den
```

:::

## Distribution packages

Packaging definitions live in [`packaging/`](https://github.com/stacksjs/den/tree/main/packaging):

- **Debian/Ubuntu** — `.deb` (`packaging/build-deb.sh`)
- **Fedora/RHEL** — `.rpm` (`packaging/build-rpm.sh`, `den.spec`)
- **Arch** — `PKGBUILD`
- **Nix** — `flake.nix` / `default.nix`

## Build from source

**Requirements:** Zig 0.17-dev or later; macOS, Linux, or BSD.

```sh
git clone https://github.com/stacksjs/den
cd den
zig build -Doptimize=ReleaseFast
zig build install --prefix ~/.local   # installs to ~/.local/bin/den
```

See [Building from Source](https://github.com/stacksjs/den#building-from-source) and the [Architecture](./ARCHITECTURE.md) docs for more.

## Use Den as your login shell

1. Add Den to the list of allowed shells:

   ```sh
   echo "$(command -v den)" | sudo tee -a /etc/shells
   ```

2. Set it as your default shell:

   ```sh
   chsh -s "$(command -v den)"
   ```

3. Open a new terminal. Den will source `~/.denrc` on startup — see [Configuration](./config.md).

::: tip
Keep your previous shell available as a fallback (it stays in `/etc/shells`). To revert: `chsh -s /bin/zsh`.
:::

## Next steps

- [Introduction](./intro.md) — what Den is and why
- [Quick Start](./guide/quick-start.md) — your first session
- [Configuration](./config.md) — `~/.denrc` and `den.jsonc`
- [Quick Reference](./QUICK_REFERENCE.md) — cheat sheet
