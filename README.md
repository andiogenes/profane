# profane

A GPU-accelerated, Emacs-like editor for macOS, scripted in Chez Scheme, with Magit-like Git porcelain.

Status: pre-M0 (scaffold). See [`profane-plan.md`](profane-plan.md) for decisions, architecture and milestones.

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

macOS 14+ on Apple Silicon, Xcode command-line tools, CMake, Ninja.
