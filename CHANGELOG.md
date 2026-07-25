# Changelog

[Compare changes](https://github.com/den-shell/den/compare/v0.2.1...v0.2.2)

## 🚀 Features

- **release**: run the whole release on our own tooling ([4c48ea7](https://github.com/den-shell/den/commit/4c48ea7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: rank command completions by recent use ([1478344](https://github.com/den-shell/den/commit/1478344)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **deps**: declare the Zig toolchain where pantry reads it ([d7c2d93](https://github.com/den-shell/den/commit/d7c2d93)) _(by Chris <chrisbreuer93@gmail.com>)_
- **history**: honour history.ignore_space ([127d074](https://github.com/den-shell/den/commit/127d074)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: offer symlinked executables ([fbd10af](https://github.com/den-shell/den/commit/fbd10af)) _(by Chris <chrisbreuer93@gmail.com>)_
- **suggestions**: keep ghost text on one row and match case-insensitively ([bc82239](https://github.com/den-shell/den/commit/bc82239)) _(by Chris <chrisbreuer93@gmail.com>)_
- **history**: stop shells from overwriting each other's history ([9376cfe](https://github.com/den-shell/den/commit/9376cfe)) _(by Chris <chrisbreuer93@gmail.com>)_
- **history**: rank suggestions by most recent run ([a8329e7](https://github.com/den-shell/den/commit/a8329e7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: calibrate idle memory budgets ([2d42208](https://github.com/den-shell/den/commit/2d42208)) _(by Chris <chrisbreuer93@gmail.com>)_
- **prompt**: handle hostname EOF safely ([95e1458](https://github.com/den-shell/den/commit/95e1458)) _(by Chris <chrisbreuer93@gmail.com>)_
- **test**: link parser suite with libc ([b0bde95](https://github.com/den-shell/den/commit/b0bde95)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: stabilize equally ranked matches ([41a306e](https://github.com/den-shell/den/commit/41a306e)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: make performance probes portable ([9318565](https://github.com/den-shell/den/commit/9318565)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: align workflows with release toolchain ([6107332](https://github.com/den-shell/den/commit/6107332)) _(by Chris <chrisbreuer93@gmail.com>)_
- **test**: capture stdout in formatting cases ([75a0c00](https://github.com/den-shell/den/commit/75a0c00)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧪 Tests

- **terminal**: actually run the line editor's tests ([96cca46](https://github.com/den-shell/den/commit/96cca46)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🤖 Continuous Integration

- install Zig with our own pantry action ([c4fa021](https://github.com/den-shell/den/commit/c4fa021)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.2.2 ([279aa4e](https://github.com/den-shell/den/commit/279aa4e)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/den-shell/den/compare/v0.2.0...v0.2.1)

## 🚀 Features

- **cli**: add verified self-upgrades ([d081712](https://github.com/den-shell/den/commit/d081712)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **release**: derive binary version from manifest ([eb413cb](https://github.com/den-shell/den/commit/eb413cb)) _(by Chris <chrisbreuer93@gmail.com>)_
- **editor**: extend quoted completion prefixes ([0cc68b0](https://github.com/den-shell/den/commit/0cc68b0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **editor**: preserve shell-aware navigation state ([596d811](https://github.com/den-shell/den/commit/596d811)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: support escaped directory paths ([11f2229](https://github.com/den-shell/den/commit/11f2229)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: respect shell command context ([87e0824](https://github.com/den-shell/den/commit/87e0824)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: honor case sensitivity ([13a4110](https://github.com/den-shell/den/commit/13a4110)) _(by Chris <chrisbreuer93@gmail.com>)_
- **editor**: refine completion selection ([48b12e5](https://github.com/den-shell/den/commit/48b12e5)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: normalize nested directory candidates ([b1979ac](https://github.com/den-shell/den/commit/b1979ac)) _(by Chris <chrisbreuer93@gmail.com>)_
- **history**: stabilize prefix navigation ([0996687](https://github.com/den-shell/den/commit/0996687)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: replace assets when updating releases ([83bbd2a](https://github.com/den-shell/den/commit/83bbd2a)) _(by Chris <chrisbreuer93@gmail.com>)_
- **release**: use maintained scoped tooling ([8e161af](https://github.com/den-shell/den/commit/8e161af)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- **install**: document verified upgrades ([1b1a581](https://github.com/den-shell/den/commit/1b1a581)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.2.1 ([64bf262](https://github.com/den-shell/den/commit/64bf262)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/den-shell/den/compare/v0.1.0...v0.2.0)

## 🚀 Features

- **builtins**: finish native ls implementation ([e88c122](https://github.com/den-shell/den/commit/e88c122)) _(by Chris <chrisbreuer93@gmail.com>)_
- process substitution as redirection target (< <(cmd)) ([68e535a](https://github.com/den-shell/den/commit/68e535a)) _(by Chris <chrisbreuer93@gmail.com>)_
- $'\cX' control-character escapes in ANSI-C quoting ([a31d6be](https://github.com/den-shell/den/commit/a31d6be)) _(by Chris <chrisbreuer93@gmail.com>)_
- negative-subscript array element assignment (a[-1]=x) ([de8b4bf](https://github.com/den-shell/den/commit/de8b4bf)) _(by Chris <chrisbreuer93@gmail.com>)_
- array literals with explicit [subscript]=value elements ([0ffd184](https://github.com/den-shell/den/commit/0ffd184)) _(by Chris <chrisbreuer93@gmail.com>)_
- test -t FD checks whether a descriptor is a terminal ([b2db861](https://github.com/den-shell/den/commit/b2db861)) _(by Chris <chrisbreuer93@gmail.com>)_
- sparse indexed arrays matching bash semantics ([8140948](https://github.com/den-shell/den/commit/8140948)) _(by Chris <chrisbreuer93@gmail.com>)_
- multi-segment glob expansion for wildcard directory components ([1a5863e](https://github.com/den-shell/den/commit/1a5863e)) _(by Chris <chrisbreuer93@gmail.com>)_
- Shift+Tab cycles completions in reverse ([189dc9f](https://github.com/den-shell/den/commit/189dc9f)) _(by Chris <chrisbreuer93@gmail.com>)_
- for loop without in iterates positional params ([1f4bada](https://github.com/den-shell/den/commit/1f4bada)) _(by Chris <chrisbreuer93@gmail.com>)_
- pattern substitution on array expansions ([eaf4138](https://github.com/den-shell/den/commit/eaf4138)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: grid-aware arrow navigation in completion menu ([b7813a0](https://github.com/den-shell/den/commit/b7813a0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **prompt**: show home-relative path like ~/Code ([79e4c75](https://github.com/den-shell/den/commit/79e4c75)) _(by Chris <chrisbreuer93@gmail.com>)_
- **which**: report paths, aliases, functions and builtins ([6993ffd](https://github.com/den-shell/den/commit/6993ffd)) _(by Chris <chrisbreuer93@gmail.com>)_
- **shell**: build full macOS PATH from /etc/paths on startup ([dc47225](https://github.com/den-shell/den/commit/dc47225)) _(by Chris <chrisbreuer93@gmail.com>)_
- **prompt**: show Bun version via spawn.captureOutput ([2816735](https://github.com/den-shell/den/commit/2816735)) _(by Chris <chrisbreuer93@gmail.com>)_
- **prompt**: show working-tree git status via spawn.captureOutput ([3622f5e](https://github.com/den-shell/den/commit/3622f5e)) _(by Chris <chrisbreuer93@gmail.com>)_
- **shell**: gate startup/exit banner behind DEN_BANNER env var ([fae4e54](https://github.com/den-shell/den/commit/fae4e54)) _(by Chris <chrisbreuer93@gmail.com>)_
- **cli**: accept -l/--login/-i/--interactive flags for login-shell use ([f4565bf](https://github.com/den-shell/den/commit/f4565bf)) _(by Chris <chrisbreuer93@gmail.com>)_
- **history**: prefix-match command history on up/down arrows ([e759e30](https://github.com/den-shell/den/commit/e759e30)) _(by Chris <chrisbreuer93@gmail.com>)_
- **cd**: zsh-style manydots expansion (... -> ../..) for cd and auto-cd ([aeb994b](https://github.com/den-shell/den/commit/aeb994b)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: wrap-aware redraw for long and multi-row input ([b3db709](https://github.com/den-shell/den/commit/b3db709)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: wrap-aware redraw for long and multi-row input ([2ace566](https://github.com/den-shell/den/commit/2ace566)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: account for wide (CJK/emoji) character display width ([b75b999](https://github.com/den-shell/den/commit/b75b999)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: UTF-8-aware input, cursor movement, and deletion (#57) ([b3ce646](https://github.com/den-shell/den/commit/b3ce646)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#57](https://github.com/den-shell/den/issues/57), [#57](https://github.com/den-shell/den/issues/57))
- **line-editor**: support bracketed paste mode (#55) ([fb0eada](https://github.com/den-shell/den/commit/fb0eada)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#55](https://github.com/den-shell/den/issues/55), [#55](https://github.com/den-shell/den/issues/55))
- **line-editor**: add Ctrl+P / Ctrl+N history navigation (#53) ([5ec0ee9](https://github.com/den-shell/den/commit/5ec0ee9)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#53](https://github.com/den-shell/den/issues/53), [#53](https://github.com/den-shell/den/issues/53))
- **shell**: zsh compat, AI completions, distributed sessions, WASM plugins ([5141002](https://github.com/den-shell/den/commit/5141002)) _(by Chris <chrisbreuer93@gmail.com>)_
- show low battery warning in prompt when below 10% ([23e0380](https://github.com/den-shell/den/commit/23e0380)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- source ~/.denrc at startup for interactive shells ([45471a3](https://github.com/den-shell/den/commit/45471a3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- implement auto-cd (type directory name to cd into it) ([78a34b8](https://github.com/den-shell/den/commit/78a34b8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- use zsh-style ➜ arrow instead of ❯ for prompt symbol ([a905289](https://github.com/den-shell/den/commit/a905289)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- git branch tab completion by reading .git/refs directly ([f02d9c3](https://github.com/den-shell/den/commit/f02d9c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_

## 🐛 Bug Fixes

- **build**: restore cross-platform release binaries ([2765573](https://github.com/den-shell/den/commit/2765573)) _(by Chris <chrisbreuer93@gmail.com>)_
- **builtins**: correct mapfile/readarray to bash 4+ semantics ([fef07df](https://github.com/den-shell/den/commit/fef07df)) _(by Chris <chrisbreuer93@gmail.com>)_
- PIPESTATUS is set after every command, not just pipelines ([b85a36a](https://github.com/den-shell/den/commit/b85a36a)) _(by Chris <chrisbreuer93@gmail.com>)_
- case statement ;& and ;;& terminators in one-liners ([4b8e030](https://github.com/den-shell/den/commit/4b8e030)) _(by Chris <chrisbreuer93@gmail.com>)_
- ${#} expands to the positional-parameter count ([8afb4d8](https://github.com/den-shell/den/commit/8afb4d8)) _(by Chris <chrisbreuer93@gmail.com>)_
- printf integer precision (%.Nd minimum digits) ([0bac09c](https://github.com/den-shell/den/commit/0bac09c)) _(by Chris <chrisbreuer93@gmail.com>)_
- $'\\NNN' octal escapes in ANSI-C quoting ([1b6a7ea](https://github.com/den-shell/den/commit/1b6a7ea)) _(by Chris <chrisbreuer93@gmail.com>)_
- support **= power compound assignment in arithmetic ([61ffc9e](https://github.com/den-shell/den/commit/61ffc9e)) _(by Chris <chrisbreuer93@gmail.com>)_
- parameter expansion — non-colon operators, nested defaults, neg length ([3eaf601](https://github.com/den-shell/den/commit/3eaf601)) _(by Chris <chrisbreuer93@gmail.com>)_
- Ctrl+C redraws multi-line prompt without stair-stepping ([ff23c84](https://github.com/den-shell/den/commit/ff23c84)) _(by Chris <chrisbreuer93@gmail.com>)_
- make process.zig process-group helpers compile on pinned Zig ([f214249](https://github.com/den-shell/den/commit/f214249)) _(by Chris <chrisbreuer93@gmail.com>)_
- remove dead job-control wrappers, fix fd helpers in platform.zig ([a5f2b5d](https://github.com/den-shell/den/commit/a5f2b5d)) _(by Chris <chrisbreuer93@gmail.com>)_
- expand "$*" inside double quotes ([470f6a0](https://github.com/den-shell/den/commit/470f6a0)) _(by Chris <chrisbreuer93@gmail.com>)_
- ls only colorizes and columnizes for a terminal ([7c6719e](https://github.com/den-shell/den/commit/7c6719e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wildcards no longer match dotfiles by default ([12a7a4b](https://github.com/den-shell/den/commit/12a7a4b)) _(by Chris <chrisbreuer93@gmail.com>)_
- globs expand to relative paths, not absolute ([cba2a4a](https://github.com/den-shell/den/commit/cba2a4a)) _(by Chris <chrisbreuer93@gmail.com>)_
- ${var:?} sets non-zero exit and aborts the command ([a1966ad](https://github.com/den-shell/den/commit/a1966ad)) _(by Chris <chrisbreuer93@gmail.com>)_
- printf honors the + and space sign flags ([138e144](https://github.com/den-shell/den/commit/138e144)) _(by Chris <chrisbreuer93@gmail.com>)_
- sleep accepts fractional seconds in builtinSleep ([0e0ff4d](https://github.com/den-shell/den/commit/0e0ff4d)) _(by Chris <chrisbreuer93@gmail.com>)_
- keep spaced $((...)) as one word in assignment values ([12756c8](https://github.com/den-shell/den/commit/12756c8)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: preserve leading ./ and ../ in path completions ([38d8227](https://github.com/den-shell/den/commit/38d8227)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: don't duplicate multi-line prompt on resize ([8494db4](https://github.com/den-shell/den/commit/8494db4)) _(by Chris <chrisbreuer93@gmail.com>)_
- **completion**: complete ./path commands as files ([fd46d70](https://github.com/den-shell/den/commit/fd46d70)) _(by Chris <chrisbreuer93@gmail.com>)_
- **shell**: parse single-line function definitions with body semicolons ([a0cb666](https://github.com/den-shell/den/commit/a0cb666)) _(by Chris <chrisbreuer93@gmail.com>)_
- **shell**: run a bare assignment before && / || as its own chain segment ([ddccc2c](https://github.com/den-shell/den/commit/ddccc2c)) _(by Chris <chrisbreuer93@gmail.com>)_
- **shell**: expand command-chain segments lazily at execution time ([389124b](https://github.com/den-shell/den/commit/389124b)) _(by Chris <chrisbreuer93@gmail.com>)_
- **builtins**: base64 reads stdin, seq handles -s, and unknown flags ([e3f1da7](https://github.com/den-shell/den/commit/e3f1da7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **builtins**: defer coreutils builtins to real tools; fix find ([6710c2a](https://github.com/den-shell/den/commit/6710c2a)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: erase inline suggestion when submitting ([176ffa9](https://github.com/den-shell/den/commit/176ffa9)) _(by Chris <chrisbreuer93@gmail.com>)_
- **spawn**: avoid free-size mismatch when trimming captured output ([37a9362](https://github.com/den-shell/den/commit/37a9362)) _(by Chris <chrisbreuer93@gmail.com>)_
- **shell**: source builtin skips quotes inside comments ([36e7fa3](https://github.com/den-shell/den/commit/36e7fa3)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: render multi-line prompts correctly ([144d02e](https://github.com/den-shell/den/commit/144d02e)) _(by Chris <chrisbreuer93@gmail.com>)_
- **prompt**: honor configured format and prompt symbol from den.jsonc ([d18a73b](https://github.com/den-shell/den/commit/d18a73b)) _(by Chris <chrisbreuer93@gmail.com>)_
- **build**: replace nonexistent addPassthruArgs with b.args passthrough ([3c66955](https://github.com/den-shell/den/commit/3c66955)) _(by Chris <chrisbreuer93@gmail.com>)_
- **expansion**: expand tilde at each word start ([1af80a9](https://github.com/den-shell/den/commit/1af80a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- **brace**: exclude sign when zero-padding negative ranges ([1b5a038](https://github.com/den-shell/den/commit/1b5a038)) _(by Chris <chrisbreuer93@gmail.com>)_
- **calc**: handle unary +/- in arithmetic expressions ([1925a3f](https://github.com/den-shell/den/commit/1925a3f)) _(by Chris <chrisbreuer93@gmail.com>)_
- **prompt**: stop visibleWidth swallowing text after a truncated escape ([00606de](https://github.com/den-shell/den/commit/00606de)) _(by Chris <chrisbreuer93@gmail.com>)_
- **concurrency**: count active jobs atomically with dequeue ([98db720](https://github.com/den-shell/den/commit/98db720)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tokenizer**: free keyword token values to prevent leak ([5409567](https://github.com/den-shell/den/commit/5409567)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: remove leftover mangled helper block so main compiles ([343c258](https://github.com/den-shell/den/commit/343c258)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: remove duplicated wrap-redraw helpers that broke the build ([1da1fbf](https://github.com/den-shell/den/commit/1da1fbf)) _(by Chris <chrisbreuer93@gmail.com>)_
- **line-editor**: complete UTF-8 input/editing so main builds ([e727e7f](https://github.com/den-shell/den/commit/e727e7f)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#57](https://github.com/den-shell/den/issues/57))
- **line-editor**: Alt+D saves the killed word to the kill ring (#56) ([a0c5968](https://github.com/den-shell/den/commit/a0c5968)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#56](https://github.com/den-shell/den/issues/56), [#56](https://github.com/den-shell/den/issues/56))
- **line-editor**: Ctrl+K kills to end of line instead of clearing screen (#52) ([351869b](https://github.com/den-shell/den/commit/351869b)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#52](https://github.com/den-shell/den/issues/52), [#52](https://github.com/den-shell/den/issues/52))
- arrow-first prompt layout and skip terminal reset for builtins ([11d3bac](https://github.com/den-shell/den/commit/11d3bac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- terminal cleanup after child process exit ([996a14b](https://github.com/den-shell/den/commit/996a14b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- clean up terminal after external commands exit ([ee82e81](https://github.com/den-shell/den/commit/ee82e81)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- revert battery display to only show below 10% ([4069eb6](https://github.com/den-shell/den/commit/4069eb6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- Ctrl+C during tab completion clears screen and correct row count ([163fe2a](https://github.com/den-shell/den/commit/163fe2a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- single-line prompt and cursor flicker during tab completion ([132f25a](https://github.com/den-shell/den/commit/132f25a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- memory leaks in typo correction and Cmd+K prompt refresh ([f70168a](https://github.com/den-shell/den/commit/f70168a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- use -c flag for startup benchmark instead of piping exit ([f3a5704](https://github.com/den-shell/den/commit/f3a5704)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- quote glob character in calc integration test ([6e4fb11](https://github.com/den-shell/den/commit/6e4fb11)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- link libc on compat module for bench/test/example targets ([b3d263c](https://github.com/den-shell/den/commit/b3d263c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- read git info from .git/ files instead of spawning processes ([c948b5e](https://github.com/den-shell/den/commit/c948b5e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- resolve memory leaks in prompt context and git repo detection ([61961f2](https://github.com/den-shell/den/commit/61961f2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- comprehensive shell improvements (146→193 tests) ([424657b](https://github.com/den-shell/den/commit/424657b)) _(by Chris <chrisbreuer93@gmail.com>)_

## ⚡ Performance Improvements

- fast-path name=$((expr)) arithmetic assignment ([949012f](https://github.com/den-shell/den/commit/949012f)) _(by Chris <chrisbreuer93@gmail.com>)_
- fast-path integer test conditions in loops ([d63ef87](https://github.com/den-shell/den/commit/d63ef87)) _(by Chris <chrisbreuer93@gmail.com>)_
- use lightweight Init.Minimal entry point ([504f1f1](https://github.com/den-shell/den/commit/504f1f1)) _(by Chris <chrisbreuer93@gmail.com>)_
- libc allocator in release; static-musl Linux binaries ([73ab34e](https://github.com/den-shell/den/commit/73ab34e)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- link feature names in README tables; real ReleaseSmall numbers ([e5bb46f](https://github.com/den-shell/den/commit/e5bb46f)) _(by Chris <chrisbreuer93@gmail.com>)_
- replace fabricated benchmarks with real measured numbers ([2689354](https://github.com/den-shell/den/commit/2689354)) _(by Chris <chrisbreuer93@gmail.com>)_
- create focused feature & advanced pages, restore site structure ([54c44f0](https://github.com/den-shell/den/commit/54c44f0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **site**: complete the BunPress sidebar with every feature page ([49c8424](https://github.com/den-shell/den/commit/49c8424)) _(by Chris <chrisbreuer93@gmail.com>)_
- add Language Server page and modernize prompt/builtin count ([fd03467](https://github.com/den-shell/den/commit/fd03467)) _(by Chris <chrisbreuer93@gmail.com>)_
- replace wrong-product content with real Den docs ([0e6d609](https://github.com/den-shell/den/commit/0e6d609)) _(by Chris <chrisbreuer93@gmail.com>)_
- **readme**: rewrite README and link every feature to its docs page ([86ebc1f](https://github.com/den-shell/den/commit/86ebc1f)) _(by Chris <chrisbreuer93@gmail.com>)_
- **git**: note working-tree status counts are not yet computed ([0ac25dc](https://github.com/den-shell/den/commit/0ac25dc)) _(by Chris <chrisbreuer93@gmail.com>)_
- make plugin authoring a first-class, accurate workflow (#51) ([c9b6405](https://github.com/den-shell/den/commit/c9b6405)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#51](https://github.com/den-shell/den/issues/51), [#51](https://github.com/den-shell/den/issues/51))
- document extended features; mark ROADMAP complete; pin CI to Zig 0.17-dev ([05aa081](https://github.com/den-shell/den/commit/05aa081)) _(by Chris <chrisbreuer93@gmail.com>)_

## 💅 Styles

- zig fmt src (fix pre-existing lint-gate failures) ([ab1116a](https://github.com/den-shell/den/commit/ab1116a)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧪 Tests

- **builtins**: cover native ls behavior ([b242c30](https://github.com/den-shell/den/commit/b242c30)) _(by Chris <chrisbreuer93@gmail.com>)_
- scalar path assignment never clobbers PATH ([4268207](https://github.com/den-shell/den/commit/4268207)) _(by Chris <chrisbreuer93@gmail.com>)_
- cover PIPESTATUS for pipelines and single commands ([4fa7b13](https://github.com/den-shell/den/commit/4fa7b13)) _(by Chris <chrisbreuer93@gmail.com>)_
- cover recent shell features; fix **= in (( )) statement form ([fd74d1e](https://github.com/den-shell/den/commit/fd74d1e)) _(by Chris <chrisbreuer93@gmail.com>)_
- unit coverage for completion ./ prefix and spawn capture free ([068b8b0](https://github.com/den-shell/den/commit/068b8b0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **builtins**: cover which paths/builtins/aliases and coreutils fallbacks ([5536622](https://github.com/den-shell/den/commit/5536622)) _(by Chris <chrisbreuer93@gmail.com>)_
- **operators**: cover assignments and operators in AND-OR lists ([258fbd6](https://github.com/den-shell/den/commit/258fbd6)) _(by Chris <chrisbreuer93@gmail.com>)_
- **builtins**: cover find -type recursion into subdirectories ([7322f2b](https://github.com/den-shell/den/commit/7322f2b)) _(by Chris <chrisbreuer93@gmail.com>)_
- **scripting**: cover source comment-quote handling ([1775af0](https://github.com/den-shell/den/commit/1775af0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **fuzzing**: free temp paths returned by createFile/createDir ([f39b826](https://github.com/den-shell/den/commit/f39b826)) _(by Chris <chrisbreuer93@gmail.com>)_
- **expansion**: expect escaped $ to drop its backslash ([acdc1d8](https://github.com/den-shell/den/commit/acdc1d8)) _(by Chris <chrisbreuer93@gmail.com>)_
- migrate suites to Zig 0.17-dev and add src-rooted aggregators ([fd9feeb](https://github.com/den-shell/den/commit/fd9feeb)) _(by Chris <chrisbreuer93@gmail.com>)_
- **cpu_opt**: correct expected match index for FastStringMatcher ([da80ef6](https://github.com/den-shell/den/commit/da80ef6)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📦 Build System

- strip release builds; ship ReleaseSmall (~1.3MB) ([ea71129](https://github.com/den-shell/den/commit/ea71129)) _(by Chris <chrisbreuer93@gmail.com>)_
- support newer zig (0.17 dev) toolchain ([5f78ed7](https://github.com/den-shell/den/commit/5f78ed7)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🤖 Continuous Integration

- **release**: build only distributable binaries ([43e4d76](https://github.com/den-shell/den/commit/43e4d76)) _(by Chris <chrisbreuer93@gmail.com>)_
- **release**: publish every binary with Pantry ([5891ec4](https://github.com/den-shell/den/commit/5891ec4)) _(by Chris <chrisbreuer93@gmail.com>)_
- build release + benchmark artifacts as ReleaseSmall ([28ac314](https://github.com/den-shell/den/commit/28ac314)) _(by Chris <chrisbreuer93@gmail.com>)_
- call the renamed test-expansion build step ([b7d359c](https://github.com/den-shell/den/commit/b7d359c)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- **release**: add conventional release scripts ([d207d19](https://github.com/den-shell/den/commit/d207d19)) _(by Chris <chrisbreuer93@gmail.com>)_
- housekeeping ([90b8f36](https://github.com/den-shell/den/commit/90b8f36)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: declare bun ^1.3.14 in deps.yaml ([02b2722](https://github.com/den-shell/den/commit/02b2722)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([98e24e2](https://github.com/den-shell/den/commit/98e24e2)) _(by Chris <chrisbreuer93@gmail.com>)_
- ignore .claude/scheduled_tasks.lock ([bb61acd](https://github.com/den-shell/den/commit/bb61acd)) _(by Chris <chrisbreuer93@gmail.com>)_
- **compat**: migrate runtime sources to Zig 0.17-dev APIs ([8af15e0](https://github.com/den-shell/den/commit/8af15e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **docs**: move docs config to .config/docs.ts ([2e0a700](https://github.com/den-shell/den/commit/2e0a700)) _(by Chris <chrisbreuer93@gmail.com>)_
- **build**: migrate to Zig 0.17-dev toolchain ([eddbba0](https://github.com/den-shell/den/commit/eddbba0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: refresh bun.lock to pick up @stacksjs/logsmith 0.2.3 ([fc0f8e9](https://github.com/den-shell/den/commit/fc0f8e9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: refresh bun.lock to pick up buddy-bot 0.9.20 ([51b33e0](https://github.com/den-shell/den/commit/51b33e0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: bump better-dx to ^0.2.15 ([266a896](https://github.com/den-shell/den/commit/266a896)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **ci**: bump actions/checkout to v6, actions/cache to v5 ([b1ee459](https://github.com/den-shell/den/commit/b1ee459)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- refresh bun.lock to pick up bun-plugin-dtsx@0.9.18 ([76ee221](https://github.com/den-shell/den/commit/76ee221)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- migrate to Zig 0.17 ([dff607c](https://github.com/den-shell/den/commit/dff607c)) _(by glennmichael123 <gtorregosa@gmail.com>)_ ([#50](https://github.com/den-shell/den/issues/50))
- refresh bun.lock and apply pickier --fix ([109682b](https://github.com/den-shell/den/commit/109682b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- refresh bun.lock ([72157a8](https://github.com/den-shell/den/commit/72157a8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- lint:fix ([4320057](https://github.com/den-shell/den/commit/4320057)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- refresh bun.lock to pick up latest pickier ([6e7609d](https://github.com/den-shell/den/commit/6e7609d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fresh install to pick up dtsx 0.9.14 and bunfig 0.15.9 ([d23ecdc](https://github.com/den-shell/den/commit/d23ecdc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fresh install to pick up pickier 0.1.21 ([1518c76](https://github.com/den-shell/den/commit/1518c76)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- bump zig to 0.17.0-dev.56+a8226cd53 ([a20543c](https://github.com/den-shell/den/commit/a20543c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint errors ([6e5bab7](https://github.com/den-shell/den/commit/6e5bab7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8beed1f](https://github.com/den-shell/den/commit/8beed1f)) _(by Chris <chrisbreuer93@gmail.com>)_
- gitignore pantry directory ([ae0b211](https://github.com/den-shell/den/commit/ae0b211)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4d942d4](https://github.com/den-shell/den/commit/4d942d4)) _(by Chris <chrisbreuer93@gmail.com>)_
- auto-fix lint errors ([8b97f1f](https://github.com/den-shell/den/commit/8b97f1f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- include md in pickier lint extensions ([c49399e](https://github.com/den-shell/den/commit/c49399e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- minor updates ([1f5f028](https://github.com/den-shell/den/commit/1f5f028)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c525206](https://github.com/den-shell/den/commit/c525206)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- update vscode config ([6b7854e](https://github.com/den-shell/den/commit/6b7854e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- increase command execution budget from 5ms to 15ms ([c2c3735](https://github.com/den-shell/den/commit/c2c3735)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- remove stale ci.yml from TypeScript era ([ba72769](https://github.com/den-shell/den/commit/ba72769)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([eba5523](https://github.com/den-shell/den/commit/eba5523)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6b1a123](https://github.com/den-shell/den/commit/6b1a123)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- update zig APIs for 0.16.0-dev.2962 ([a4834ac](https://github.com/den-shell/den/commit/a4834ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- repo cleanup and modernization ([c977705](https://github.com/den-shell/den/commit/c977705)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([91cf3d4](https://github.com/den-shell/den/commit/91cf3d4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4b3e9d5](https://github.com/den-shell/den/commit/4b3e9d5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d54042e](https://github.com/den-shell/den/commit/d54042e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([778dc5d](https://github.com/den-shell/den/commit/778dc5d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1155f6a](https://github.com/den-shell/den/commit/1155f6a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9fad5f6](https://github.com/den-shell/den/commit/9fad5f6)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0a0be7f](https://github.com/den-shell/den/commit/0a0be7f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7b962e0](https://github.com/den-shell/den/commit/7b962e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b958816](https://github.com/den-shell/den/commit/b958816)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([17fa7cc](https://github.com/den-shell/den/commit/17fa7cc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([eaa763d](https://github.com/den-shell/den/commit/eaa763d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([189c31b](https://github.com/den-shell/den/commit/189c31b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([193fd8b](https://github.com/den-shell/den/commit/193fd8b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a6124da](https://github.com/den-shell/den/commit/a6124da)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5072cf2](https://github.com/den-shell/den/commit/5072cf2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9c91f98](https://github.com/den-shell/den/commit/9c91f98)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ad65f89](https://github.com/den-shell/den/commit/ad65f89)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([da1e947](https://github.com/den-shell/den/commit/da1e947)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([17dda79](https://github.com/den-shell/den/commit/17dda79)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([60261d4](https://github.com/den-shell/den/commit/60261d4)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([34f7ed0](https://github.com/den-shell/den/commit/34f7ed0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e2a594d](https://github.com/den-shell/den/commit/e2a594d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8b99880](https://github.com/den-shell/den/commit/8b99880)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7628268](https://github.com/den-shell/den/commit/7628268)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6740aa0](https://github.com/den-shell/den/commit/6740aa0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4188a74](https://github.com/den-shell/den/commit/4188a74)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4f2c0cf](https://github.com/den-shell/den/commit/4f2c0cf)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9e0eb50](https://github.com/den-shell/den/commit/9e0eb50)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1a20f3a](https://github.com/den-shell/den/commit/1a20f3a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e8dee83](https://github.com/den-shell/den/commit/e8dee83)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5faf560](https://github.com/den-shell/den/commit/5faf560)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1086a27](https://github.com/den-shell/den/commit/1086a27)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([37ee661](https://github.com/den-shell/den/commit/37ee661)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d5693f5](https://github.com/den-shell/den/commit/d5693f5)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1765167](https://github.com/den-shell/den/commit/1765167)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c9ed7cc](https://github.com/den-shell/den/commit/c9ed7cc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e62ddae](https://github.com/den-shell/den/commit/e62ddae)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4782362](https://github.com/den-shell/den/commit/4782362)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([16b5ab1](https://github.com/den-shell/den/commit/16b5ab1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([445c537](https://github.com/den-shell/den/commit/445c537)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([baec614](https://github.com/den-shell/den/commit/baec614)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5809eea](https://github.com/den-shell/den/commit/5809eea)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4638a13](https://github.com/den-shell/den/commit/4638a13)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([034b8af](https://github.com/den-shell/den/commit/034b8af)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d5148d3](https://github.com/den-shell/den/commit/d5148d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1179c0f](https://github.com/den-shell/den/commit/1179c0f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([21eb497](https://github.com/den-shell/den/commit/21eb497)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([96fc30c](https://github.com/den-shell/den/commit/96fc30c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([705979d](https://github.com/den-shell/den/commit/705979d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([82cb4fc](https://github.com/den-shell/den/commit/82cb4fc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([eab6037](https://github.com/den-shell/den/commit/eab6037)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a788219](https://github.com/den-shell/den/commit/a788219)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([036c61b](https://github.com/den-shell/den/commit/036c61b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9b840a4](https://github.com/den-shell/den/commit/9b840a4)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ca23b1e](https://github.com/den-shell/den/commit/ca23b1e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3c66536](https://github.com/den-shell/den/commit/3c66536)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([424e72b](https://github.com/den-shell/den/commit/424e72b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3da2f75](https://github.com/den-shell/den/commit/3da2f75)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a3a3179](https://github.com/den-shell/den/commit/a3a3179)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5f75803](https://github.com/den-shell/den/commit/5f75803)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bc3775e](https://github.com/den-shell/den/commit/bc3775e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([41b14d8](https://github.com/den-shell/den/commit/41b14d8)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0ee54c0](https://github.com/den-shell/den/commit/0ee54c0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0eba778](https://github.com/den-shell/den/commit/0eba778)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8e04cb9](https://github.com/den-shell/den/commit/8e04cb9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0a4d79f](https://github.com/den-shell/den/commit/0a4d79f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c1f588b](https://github.com/den-shell/den/commit/c1f588b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a08d06e](https://github.com/den-shell/den/commit/a08d06e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3d61411](https://github.com/den-shell/den/commit/3d61411)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2aad424](https://github.com/den-shell/den/commit/2aad424)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([fc09330](https://github.com/den-shell/den/commit/fc09330)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([256b724](https://github.com/den-shell/den/commit/256b724)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7168222](https://github.com/den-shell/den/commit/7168222)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([164164b](https://github.com/den-shell/den/commit/164164b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([fbc0c7c](https://github.com/den-shell/den/commit/fbc0c7c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a65e9](https://github.com/den-shell/den/commit/36a65e9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3a59feb](https://github.com/den-shell/den/commit/3a59feb)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e31298b](https://github.com/den-shell/den/commit/e31298b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0bb0256](https://github.com/den-shell/den/commit/0bb0256)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d58f0bb](https://github.com/den-shell/den/commit/d58f0bb)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([79c0270](https://github.com/den-shell/den/commit/79c0270)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee8a477](https://github.com/den-shell/den/commit/ee8a477)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b9c5601](https://github.com/den-shell/den/commit/b9c5601)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0e306e0](https://github.com/den-shell/den/commit/0e306e0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0440365](https://github.com/den-shell/den/commit/0440365)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([efcdc0b](https://github.com/den-shell/den/commit/efcdc0b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([722f2e1](https://github.com/den-shell/den/commit/722f2e1)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([048c8fe](https://github.com/den-shell/den/commit/048c8fe)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f0b0905](https://github.com/den-shell/den/commit/f0b0905)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([75f5d33](https://github.com/den-shell/den/commit/75f5d33)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([290a135](https://github.com/den-shell/den/commit/290a135)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([67fce62](https://github.com/den-shell/den/commit/67fce62)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([98c1798](https://github.com/den-shell/den/commit/98c1798)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cd088af](https://github.com/den-shell/den/commit/cd088af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b082d01](https://github.com/den-shell/den/commit/b082d01)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4ddcfc7](https://github.com/den-shell/den/commit/4ddcfc7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6079514](https://github.com/den-shell/den/commit/6079514)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([66052c1](https://github.com/den-shell/den/commit/66052c1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ca919d0](https://github.com/den-shell/den/commit/ca919d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cc33793](https://github.com/den-shell/den/commit/cc33793)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ec57094](https://github.com/den-shell/den/commit/ec57094)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b65ba6d](https://github.com/den-shell/den/commit/b65ba6d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b9f477c](https://github.com/den-shell/den/commit/b9f477c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6d7e65e](https://github.com/den-shell/den/commit/6d7e65e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([507710c](https://github.com/den-shell/den/commit/507710c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2028f15](https://github.com/den-shell/den/commit/2028f15)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([777d5f5](https://github.com/den-shell/den/commit/777d5f5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7f3253c](https://github.com/den-shell/den/commit/7f3253c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dba046a](https://github.com/den-shell/den/commit/dba046a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a1cb655](https://github.com/den-shell/den/commit/a1cb655)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dd2b7fd](https://github.com/den-shell/den/commit/dd2b7fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a36d1da](https://github.com/den-shell/den/commit/a36d1da)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([95bb572](https://github.com/den-shell/den/commit/95bb572)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d55e9cb](https://github.com/den-shell/den/commit/d55e9cb)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8f14f62](https://github.com/den-shell/den/commit/8f14f62)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9d27868](https://github.com/den-shell/den/commit/9d27868)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a4a068f](https://github.com/den-shell/den/commit/a4a068f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([fe3422e](https://github.com/den-shell/den/commit/fe3422e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2489b74](https://github.com/den-shell/den/commit/2489b74)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0a10919](https://github.com/den-shell/den/commit/0a10919)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e1bfb27](https://github.com/den-shell/den/commit/e1bfb27)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([53694c4](https://github.com/den-shell/den/commit/53694c4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e595c29](https://github.com/den-shell/den/commit/e595c29)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8a6c570](https://github.com/den-shell/den/commit/8a6c570)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ec28610](https://github.com/den-shell/den/commit/ec28610)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([26e12d7](https://github.com/den-shell/den/commit/26e12d7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0b5c7d8](https://github.com/den-shell/den/commit/0b5c7d8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([436876a](https://github.com/den-shell/den/commit/436876a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- docs ([36d88cf](https://github.com/den-shell/den/commit/36d88cf)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([402a921](https://github.com/den-shell/den/commit/402a921)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0d1a8c1](https://github.com/den-shell/den/commit/0d1a8c1)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([509c3aa](https://github.com/den-shell/den/commit/509c3aa)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([61e0351](https://github.com/den-shell/den/commit/61e0351)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e720e5f](https://github.com/den-shell/den/commit/e720e5f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7a0e701](https://github.com/den-shell/den/commit/7a0e701)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([25792b5](https://github.com/den-shell/den/commit/25792b5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([80f8c6b](https://github.com/den-shell/den/commit/80f8c6b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([759d0e3](https://github.com/den-shell/den/commit/759d0e3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1a69ca5](https://github.com/den-shell/den/commit/1a69ca5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([958624f](https://github.com/den-shell/den/commit/958624f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([83d900e](https://github.com/den-shell/den/commit/83d900e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4a7e5ca](https://github.com/den-shell/den/commit/4a7e5ca)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3283cd1](https://github.com/den-shell/den/commit/3283cd1)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([03fc58e](https://github.com/den-shell/den/commit/03fc58e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([762ab05](https://github.com/den-shell/den/commit/762ab05)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([fdb84d8](https://github.com/den-shell/den/commit/fdb84d8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e3c2f79](https://github.com/den-shell/den/commit/e3c2f79)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([516c6f7](https://github.com/den-shell/den/commit/516c6f7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([72bccd6](https://github.com/den-shell/den/commit/72bccd6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6fb8173](https://github.com/den-shell/den/commit/6fb8173)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ac33bf3](https://github.com/den-shell/den/commit/ac33bf3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([62fcba5](https://github.com/den-shell/den/commit/62fcba5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c664df5](https://github.com/den-shell/den/commit/c664df5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([81461b1](https://github.com/den-shell/den/commit/81461b1)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([786c081](https://github.com/den-shell/den/commit/786c081)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1e25e4c](https://github.com/den-shell/den/commit/1e25e4c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9d27798](https://github.com/den-shell/den/commit/9d27798)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d3abd33](https://github.com/den-shell/den/commit/d3abd33)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ca87125](https://github.com/den-shell/den/commit/ca87125)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3b1ad87](https://github.com/den-shell/den/commit/3b1ad87)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([239da4d](https://github.com/den-shell/den/commit/239da4d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8b6bc0b](https://github.com/den-shell/den/commit/8b6bc0b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4ea40c9](https://github.com/den-shell/den/commit/4ea40c9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f2ef0f8](https://github.com/den-shell/den/commit/f2ef0f8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0586b8c](https://github.com/den-shell/den/commit/0586b8c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5f719c9](https://github.com/den-shell/den/commit/5f719c9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([48e6c24](https://github.com/den-shell/den/commit/48e6c24)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([17556d7](https://github.com/den-shell/den/commit/17556d7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ffc56d1](https://github.com/den-shell/den/commit/ffc56d1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([61a1287](https://github.com/den-shell/den/commit/61a1287)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a983abc](https://github.com/den-shell/den/commit/a983abc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e6690e7](https://github.com/den-shell/den/commit/e6690e7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5149af5](https://github.com/den-shell/den/commit/5149af5)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([684471e](https://github.com/den-shell/den/commit/684471e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([670239a](https://github.com/den-shell/den/commit/670239a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f6ae81b](https://github.com/den-shell/den/commit/f6ae81b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([47308ef](https://github.com/den-shell/den/commit/47308ef)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0e8f5c0](https://github.com/den-shell/den/commit/0e8f5c0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1f61269](https://github.com/den-shell/den/commit/1f61269)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([be77433](https://github.com/den-shell/den/commit/be77433)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3acf057](https://github.com/den-shell/den/commit/3acf057)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([afca651](https://github.com/den-shell/den/commit/afca651)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([83cb592](https://github.com/den-shell/den/commit/83cb592)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([43568e3](https://github.com/den-shell/den/commit/43568e3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([71aad82](https://github.com/den-shell/den/commit/71aad82)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0a5fd8a](https://github.com/den-shell/den/commit/0a5fd8a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f41cc58](https://github.com/den-shell/den/commit/f41cc58)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cb0c6f4](https://github.com/den-shell/den/commit/cb0c6f4)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([248ac0e](https://github.com/den-shell/den/commit/248ac0e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4b25e64](https://github.com/den-shell/den/commit/4b25e64)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8eed820](https://github.com/den-shell/den/commit/8eed820)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c505cd8](https://github.com/den-shell/den/commit/c505cd8)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7bc8d1b](https://github.com/den-shell/den/commit/7bc8d1b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1361a88](https://github.com/den-shell/den/commit/1361a88)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ab9b4df](https://github.com/den-shell/den/commit/ab9b4df)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3986a47](https://github.com/den-shell/den/commit/3986a47)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8ccfd20](https://github.com/den-shell/den/commit/8ccfd20)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([54dd982](https://github.com/den-shell/den/commit/54dd982)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bcc2c30](https://github.com/den-shell/den/commit/bcc2c30)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1513674](https://github.com/den-shell/den/commit/1513674)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e883cf2](https://github.com/den-shell/den/commit/e883cf2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([033f999](https://github.com/den-shell/den/commit/033f999)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([faabe2e](https://github.com/den-shell/den/commit/faabe2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([941f2dd](https://github.com/den-shell/den/commit/941f2dd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6f8caf8](https://github.com/den-shell/den/commit/6f8caf8)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0bbde8c](https://github.com/den-shell/den/commit/0bbde8c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([35b9c71](https://github.com/den-shell/den/commit/35b9c71)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b8885a1](https://github.com/den-shell/den/commit/b8885a1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a20a769](https://github.com/den-shell/den/commit/a20a769)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0a98472](https://github.com/den-shell/den/commit/0a98472)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([92f3c6d](https://github.com/den-shell/den/commit/92f3c6d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1523bab](https://github.com/den-shell/den/commit/1523bab)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([01f9114](https://github.com/den-shell/den/commit/01f9114)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ded3a62](https://github.com/den-shell/den/commit/ded3a62)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b644157](https://github.com/den-shell/den/commit/b644157)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c509465](https://github.com/den-shell/den/commit/c509465)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([61fbaff](https://github.com/den-shell/den/commit/61fbaff)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8bc3409](https://github.com/den-shell/den/commit/8bc3409)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([adec8b1](https://github.com/den-shell/den/commit/adec8b1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bd821e0](https://github.com/den-shell/den/commit/bd821e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4223c86](https://github.com/den-shell/den/commit/4223c86)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c99bd2d](https://github.com/den-shell/den/commit/c99bd2d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([57cb9ea](https://github.com/den-shell/den/commit/57cb9ea)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9219a38](https://github.com/den-shell/den/commit/9219a38)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([15bb83d](https://github.com/den-shell/den/commit/15bb83d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3daba92](https://github.com/den-shell/den/commit/3daba92)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: update dependency bunfig to 0.15.0 (#46) ([283c754](https://github.com/den-shell/den/commit/283c754)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#46](https://github.com/den-shell/den/issues/46), [#46](https://github.com/den-shell/den/issues/46))
- **deps**: update dependency buddy-bot to 0.9.4 (#47) ([1153d10](https://github.com/den-shell/den/commit/1153d10)) _(by Chris <chrisbreuer93@gmail.com>)_ ([#47](https://github.com/den-shell/den/issues/47), [#47](https://github.com/den-shell/den/issues/47))
- wip ([a8110da](https://github.com/den-shell/den/commit/a8110da)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([58076ca](https://github.com/den-shell/den/commit/58076ca)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ec8abcf](https://github.com/den-shell/den/commit/ec8abcf)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8010986](https://github.com/den-shell/den/commit/8010986)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d18bd9c](https://github.com/den-shell/den/commit/d18bd9c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([005131e](https://github.com/den-shell/den/commit/005131e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3b20939](https://github.com/den-shell/den/commit/3b20939)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2a3b848](https://github.com/den-shell/den/commit/2a3b848)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d3c9cf1](https://github.com/den-shell/den/commit/d3c9cf1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4ed8747](https://github.com/den-shell/den/commit/4ed8747)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([46d8968](https://github.com/den-shell/den/commit/46d8968)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2595b58](https://github.com/den-shell/den/commit/2595b58)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7a5d42f](https://github.com/den-shell/den/commit/7a5d42f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([73a925e](https://github.com/den-shell/den/commit/73a925e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([69e9441](https://github.com/den-shell/den/commit/69e9441)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([982a92a](https://github.com/den-shell/den/commit/982a92a)) _(by Test User <test@example.com>)_
- wip ([55e75ea](https://github.com/den-shell/den/commit/55e75ea)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aeb3dfd](https://github.com/den-shell/den/commit/aeb3dfd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f8f5026](https://github.com/den-shell/den/commit/f8f5026)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2835add](https://github.com/den-shell/den/commit/2835add)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cbb10d4](https://github.com/den-shell/den/commit/cbb10d4)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4ff517a](https://github.com/den-shell/den/commit/4ff517a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([68fe525](https://github.com/den-shell/den/commit/68fe525)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2b3d741](https://github.com/den-shell/den/commit/2b3d741)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ca3aa5c](https://github.com/den-shell/den/commit/ca3aa5c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7bbf909](https://github.com/den-shell/den/commit/7bbf909)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b92fba2](https://github.com/den-shell/den/commit/b92fba2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4451c14](https://github.com/den-shell/den/commit/4451c14)) _(by Chris <chrisbreuer93@gmail.com>)_
- update tooling ([c5f086b](https://github.com/den-shell/den/commit/c5f086b)) _(by Adelino Ngomacha <adelinob335@gmail.com>)_
- wip ([12cd257](https://github.com/den-shell/den/commit/12cd257)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0643b38](https://github.com/den-shell/den/commit/0643b38)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([90e2849](https://github.com/den-shell/den/commit/90e2849)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([48c8843](https://github.com/den-shell/den/commit/48c8843)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0a45692](https://github.com/den-shell/den/commit/0a45692)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([038b225](https://github.com/den-shell/den/commit/038b225)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b52fc5c](https://github.com/den-shell/den/commit/b52fc5c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0c65b0](https://github.com/den-shell/den/commit/c0c65b0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ec1546a](https://github.com/den-shell/den/commit/ec1546a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([32de44f](https://github.com/den-shell/den/commit/32de44f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e5c0a22](https://github.com/den-shell/den/commit/e5c0a22)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0cb1a20](https://github.com/den-shell/den/commit/0cb1a20)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d739d1a](https://github.com/den-shell/den/commit/d739d1a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([afa24ff](https://github.com/den-shell/den/commit/afa24ff)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8f72bd7](https://github.com/den-shell/den/commit/8f72bd7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([acfc9eb](https://github.com/den-shell/den/commit/acfc9eb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([56c7fe0](https://github.com/den-shell/den/commit/56c7fe0)) _(by Chris <chrisbreuer93@gmail.com>)_

## ⏪ Reverts

- **line-editor**: roll back the corrupted wrap-redraw refactor ([484db86](https://github.com/den-shell/den/commit/484db86)) _(by Chris <chrisbreuer93@gmail.com>)_

## bench

- make 'bench.sh comparison' emit a real measured table ([6ecb97a](https://github.com/den-shell/den/commit/6ecb97a)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📄 Miscellaneous

- Update shell.zig ([20fd891](https://github.com/den-shell/den/commit/20fd891)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- Update TODO.md ([5dad897](https://github.com/den-shell/den/commit/5dad897)) _(by glennmichael123 <gtorregosa@gmail.com>)_

## Contributors

- _Adelino Ngomacha <adelinob335@gmail.com>_
- _Chris <chrisbreuer93@gmail.com>_
- _Test User <test@example.com>_
- _glennmichael123 <gtorregosa@gmail.com>_
