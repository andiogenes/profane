# profane

A GPU-accelerated, Emacs-like editor for macOS, scripted in Chez Scheme, with Magit-like Git porcelain.

Status: M0 to M4 are built. M4 (soft wrap, git fringe marks, motion, the Git porcelain on `C-x g`, ediff) has not yet
been looked at on screen or dogfooded. The next milestone is M5 (languages). See [`profane-plan.md`](profane-plan.md)
for decisions, measurements, known gaps (§8j) and milestones.

| Milestone | Scope |
|---|---|
| M0, M1 | Embedding, rendering, text core |
| M2 | Core workflow: windows, tabs, minibuffer, completion, the port of the owner's Emacs keys |
| M3 | Async and tools: processes, ripgrep/find, dired, sidebar, vterm, TLS sockets, Keychain secrets |
| M4 | Soft wrap, git fringe marks (libgit2), animations (off by default), Git porcelain, ediff |
| M5 | Languages (tree-sitter, modes) — next |

## Layout

```
core/              C17 core: text, layout, git, treesit, search, embed (Chez embedding)
platform/macos/    Objective-C shell, Metal renderer, Core Text, WKWebView host
subprojects/       vendored dependencies (Chez Scheme, libvterm, libgit2)
scheme/profane/    Scheme standard library and built-in UI
packages/          optional Scheme packages (dashboard, irc, listing)
tools/             profane-client
packaging/         signing, notarization, Sparkle, Homebrew cask
tests/             C, SRFI-64, Metal golden images, Org round-trip corpus
```

## Requirements

macOS 14+ on Apple Silicon, Xcode (for the Metal compiler), CMake ≥ 3.28, Ninja.

```sh
git submodule update --init --recursive
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
open build/platform/macos/profane.app
build/tools/profane-client/profane-client --eval '(scheme-version)'
```

The app bundle holds a copy of `scheme/`, so rebuild after editing Scheme. Startup scripts: the shipped
`scheme/init.ss`, then `~/Library/Application Support/profane/init.ss`. Contributors and coding agents: see
[`AGENTS.md`](AGENTS.md).
