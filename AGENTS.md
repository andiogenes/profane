# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, etc.) working in this repository.
Human-facing overview: `README.md`. Source of truth for scope and sequencing: `profane-plan.md`.

## Project

profane is a GPU-accelerated, Emacs-like editor for macOS (14+, Apple Silicon, GUI only), scripted in
Chez Scheme, with Magit-like Git porcelain. No Elisp compatibility: Emacs-familiar names, own Scheme API.

Layers (top to bottom):

| Layer | Language | Location |
|---|---|---|
| Userland: modes, keymaps, commands, themes, packages | Chez Scheme (R6RS libraries) | `scheme/profane/`, `packages/` |
| FFI | `foreign-procedure` / `foreign-callable` / ftypes | `core/embed/` + `scheme/profane/` |
| Core: piece tree, markers, undo, layout, git, tree-sitter, search | C17 | `core/` |
| Platform shell: AppKit, Metal, Core Text, WKWebView | Objective-C (no Swift) | `platform/macos/` |

## Current status

M0 (skeleton) on branch `m0-skeleton`: CMake build, vendored Chez, signed `.app` with hardened runtime +
`allow-jit` (verified), Metal clear + Core Text hello line, socket REPL + `profane-client`. Work proceeds
milestone by milestone (plan §9). Do not start work from a later milestone unless asked; when a task touches
a later milestone's area, leave a seam, not an implementation.

## Commands

Build system is CMake + Ninja. Chez Scheme is a submodule (`subprojects/chez`, pinned to a release tag) built
once per build tree by `cmake/Chez.cmake` (~90 s); after bumping it, delete `build/chez`.

```sh
git submodule update --init --recursive                 # first checkout
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug   # configure
cmake --build build                                     # build + sign build/platform/macos/profane.app
ctest --test-dir build --output-on-failure              # all tests
ctest --test-dir build -L '^c$'                         # by label (a regex): c | scheme | macos | screen
clang-format -i <files>                                 # format C / ObjC (brew install clang-format)
```

- Targets: `pf_core` (C core), `profane` (app bundle), `profane_signed` (codesign step), `profane-client`.
- `-DPROFANE_CODESIGN_IDENTITY=...` selects the signing identity (default `-`, ad-hoc).
- `-DPROFANE_SANITIZE=ON` (in a separate tree, e.g. `build-asan`) builds with ASan + UBSan.
- `profane --self-test` boots Scheme and checks JIT codegen under the hardened runtime; `--headless` runs
  Scheme + REPL without a window; `--snapshot out.png` waits for the first on-screen frame, renders it
  offscreen to PNG and quits (fails if AppKit never displayed the view).
- REPL socket: `~/Library/Application Support/profane/repl.sock` (override with `PROFANE_REPL_SOCKET`; paths
  are limited to 104 bytes). `profane-client --eval '(+ 1 2)'`, or pipe source into `profane-client`.

## Architecture rules (do not violate)

- **Threads**: main thread runs AppKit + the Chez command loop. The render thread only encodes immutable
  display snapshots and never touches the Scheme heap. Workers (GCD) post results back as C structs.
- **FFI**: Scheme sees integer handles only, never raw C pointers. Callbacks into Scheme are `lock-object`ed.
  Chez's GC moves objects — never hold a Scheme object's address in C across a call that can allocate.
  C calls Scheme only via `pf_scheme_call`, which goes through the guarded `pf-ffi-call` trampoline in
  `scheme/boot.ss` (an exception escaping into C terminates the process). Scheme calls C through
  `(profane native)`; new entry points go in `PF_NATIVE_SOURCES` (`core/CMakeLists.txt`), which must not use Chez
  so the `pf_native` dylib can serve Scheme tests. Link executables that embed Chez with `pf_core_whole`.
- **GC**: collections are deferred to post-frame/idle via `collect-request-handler`.
- **Live redefinition**: commands, keymaps, vars, hooks, faces, modes live in symbol-keyed registries; keys bind
  symbols, not procedures. Don't capture procedures where a symbol lookup is expected.
- **Rendering**: everything goes through the `pf_renderer` C interface. `ProfaneView` has three layers
  (base Metal, native views, overlay Metal); pop-ups always go on the overlay layer.
- **Git**: libgit2 for reads, `git` CLI for every mutation.
- **UI**: all styling comes from theme design tokens. `(ui-style 'minimal)` is the default and the visual
  regression baseline; new chrome must be off in the minimal preset unless the plan says otherwise.
- **Input latency**: input is always handled before animation ticks; under load animations are dropped,
  never delayed. Target <8 ms key-to-pixel.
- **Org-lite**: round trips must be lossless — anything not understood is preserved byte-for-byte.
- **Agents (Claude API)**: model IDs and request shape live in one provider module
  (`scheme/profane/agent/provider`). Default `claude-opus-5-5`; `claude-haiku-5-5` for fast tasks.
  Untrusted content (web, fetched files, MCP output) disables auto-approve.

## Conventions

- C: C17, `pf_` prefix for public symbols, `snake_case`, headers self-contained. Format with `.clang-format`.
- Objective-C: ARC, `PF` class prefix (e.g. `ProfaneView` is the one exception, by name in the plan).
- Scheme: R6RS libraries named `(profane <area>)`; procedures `kebab-case`, mutators end in `!`,
  predicates in `?`. Tests use SRFI-64.
- Keep new public Scheme APIs marked unstable until M13 (plan §10).
- No new third-party dependency without noting it in `profane-plan.md` §0 or the relevant section.

## Testing

- `tests/c/` — C unit tests for `core/` (portable, run anywhere).
- `tests/scheme/*-test.ss` — SRFI-64 suites for `scheme/profane/`, run by the built `scheme` binary with
  `PROFANE_NATIVE_LIB` pointing at `pf_native`. SRFI 64 is a minimal in-repo subset
  (`tests/scheme/lib/srfi/:64.sls`); extend it as suites need more.
- `tests/macos/` — app integration scripts (signing/JIT self-test, socket REPL, on-screen frame + snapshot),
  label `macos`; `macos.snapshot` opens a window, so it needs a GUI login session.
- `tests/macos/screen.sh` (label `screen`) — checks what the window server actually shows; skipped unless
  `PROFANE_SCREEN_TESTS=1` (needs Screen Recording permission). Run it after touching presentation/redisplay.
- `tests/golden/` — Metal golden images (macOS only).
- `tests/org-corpus/` — Org-lite lossless round-trip corpus.
- Every bug fix gets a regression test. Core and Scheme tests must not require a GPU or a window.

## Workflow

- Make focused changes; one milestone item per branch/PR where practical.
- Keep `profane-plan.md` in sync: if an implementation decision diverges from the plan, update the plan in the
  same change and say why.
- Commit messages: imperative subject ≤72 chars, prefixed by area (`core:`, `macos:`, `scheme:`, `git:`,
  `agent:`, `build:`, `docs:`).
- Don't commit build output, signing identities, API keys or notarization credentials.
