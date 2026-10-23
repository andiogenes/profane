# profane

A GPU-accelerated, Emacs-like editor for macOS, scripted in Chez Scheme, with Magit-like Git porcelain.

Status: M0 (skeleton) in progress. See [`profane-plan.md`](profane-plan.md) for decisions, architecture and milestones.

## Layout

```
core/              C17 core: text, layout, git, treesit, search, embed (Chez embedding)
platform/macos/    Objective-C shell, Metal renderer, Core Text, WKWebView host
subprojects/       vendored dependencies (Chez Scheme, ...)
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
