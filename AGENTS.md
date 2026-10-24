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

M0, M1 and most of M2 are on `main` (origin `git@github.com:andiogenes/profane.git`). Decisions and measurements
are in `profane-plan.md` §8a–§8j; read the section for an area before changing it. Work proceeds milestone by
milestone (plan §9). Do not start work from a later milestone unless asked; when a task touches a later
milestone's area, leave a seam, not an implementation.

**M2** is feature-complete as planned (the M2 row of plan §9); what was left out on purpose is listed in plan §8j. Its
owner-port gaps wait on other milestones: consult's imenu and xref (modes and tree-sitter, M5), ripgrep and find (M3),
neotree and the buffer menu (listing and tree views).

**Known gaps:** the full list, with what each waits for, is `profane-plan.md` §8j. Two things every agent must know:
commands run in engines, so `C-g` interrupts a runaway command (see the Engines entry in §8i), but socket REPL
evaluations and hooks outside commands are not sliced, so don't evaluate an unbounded loop over `profane-client`; and
held keys repeat because press-and-hold is off (`press-and-hold-keys` turns it on per key). macOS capture rules are
under "Traps" below.

## Commands

Build system is CMake + Ninja. Chez Scheme is a submodule (`subprojects/chez`, pinned to a release tag) built
once per build tree by `cmake/Chez.cmake` (~90 s); after bumping it, delete `build/chez`. libvterm is a
submodule too (`subprojects/libvterm`, v0.3.3), built as a static library by `cmake/Libvterm.cmake` (perl
generates two tables).

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
- Startup scripts: the shipped `scheme/init.ss` (the owner's port of their Emacs keys), then
  `~/Library/Application Support/profane/init.ss` (`PROFANE_INIT` overrides the path).
- REPL socket: `~/Library/Application Support/profane/repl.sock` (override with `PROFANE_REPL_SOCKET`; paths
  are limited to 104 bytes, so use e.g. `PROFANE_REPL_SOCKET=$(mktemp -d /tmp/pf.XXXX)/s`).
  `profane-client --eval '(+ 1 2)'`, or pipe source into `profane-client`
  (`build/tools/profane-client/profane-client`). The app bundle holds a **copy** of `scheme/`: rebuild before
  running the app after editing Scheme, or it runs the old code.

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
- Run one Scheme suite by hand (boot files need **absolute** paths, or Chez reports "cannot find compatible boot
  file"): `B=$PWD/build/chez/tarm64osx/boot/tarm64osx; PROFANE_NATIVE_LIB=$PWD/build/core/libpf_native.dylib build/chez/tarm64osx/bin/tarm64osx/scheme -b $B/petite.boot -b $B/scheme.boot --libdirs scheme:tests/scheme/lib --script tests/scheme/window-test.ss`.
  It prints `name: N passed, M failed` and `FAIL` lines; `ctest -V` shows them, plain `ctest` only pass/fail.
  **End every suite with `(test-exit)`**, or failures leave the exit status 0 and ctest reports a pass.
- Sanitizers: `-DPROFANE_SANITIZE=ON` in `build-asan` (UBSan reports are fatal there; the Scheme suites get the ASan
  runtime preloaded via `DYLD_INSERT_LIBRARIES`); TSan via `-DCMAKE_{C,OBJC,EXE_LINKER}_FLAGS=-fsanitize=thread` in
  `build-tsan`. ASan fills new allocations with garbage: it found a struct field added without initializing
  (`pf_text_new` uses `malloc`, not `calloc`).
- Latency: `PROFANE_SCREEN_TESTS=1 tests/macos/latency.sh build/platform/macos/profane.app build/tools/profane-client/profane-client build/tests/post_keys`
  (`LATENCY_PREFILL_LINES=100000` for a big buffer, `LATENCY_WINDOWS=4` to show it in four windows). At the REPL:
  `(latency-report)`. Run one configuration per command (zsh does not word-split `$var`). Measured so far: key-to-
  committed-frame p95 2.0 ms with one window, 3.9 ms with four windows on a 100k-line buffer (target < 8 ms).
- `clang-format` may not be installed; then format by hand to `.clang-format`.
- Every bug fix gets a regression test that fails on the old code: verify that it fails, then restore the fix. Core and Scheme tests must not require a GPU or a window.

## Workflow

- Make focused changes; one milestone item per branch/PR where practical.
- Keep `profane-plan.md` in sync: if an implementation decision diverges from the plan, update the plan in the
  same change and say why. Record decisions, measurements and what was left as a seam in its §8x sections.
- Commit messages: imperative subject ≤72 chars, prefixed by area (`core:`, `macos:`, `scheme:`, `git:`,
  `agent:`, `build:`, `docs:`).
- Don't commit build output, signing identities, API keys or notarization credentials.

## Working with the owner

- One M2-style item per branch (`m2-<topic>`), cut from the previous item's branch; `main` has taken the whole
  stack as a fast-forward (no PRs). **Ask before merging or pushing.** After an item: summarize what was and was not
  verified, with the commit made as one commit per item (area prefix, imperative, body listing the bugs fixed and
  their regression tests).
- Be honest about what wasn't verified. The owner values corrections, e.g. a "fix" later found to be a measurement
  artifact and reverted, or an unverified assumption (press-and-hold's per-key switch) flagged as such.
- The owner's own Emacs config is `~/.emacs.d` (repo `andiogenes/.emacs.d`, plan §2); `scheme/init.ss` is the port
  of its keybindings.
- The owner's macOS keyboard layout is often **Russian**: chords must work under any layout (`platform/macos/PFKeys.m`).
  They don't use CJK input methods.
- The owner often has other windows in front. **Don't steal focus** and don't take over the machine: see the macOS
  traps below.

## Traps already hit (read before writing code)

**Chez / Scheme**

- **A library body allows no expression before its last definition.** Registration calls such as
  `(define-variable 'x …)`, `(define-hook 'h)` or `(define-key! …)` mid-body fail with "invalid context for
  definition". Use the definition forms: `defvar`, `defhook`, `define-command`, `define-major-mode`,
  `define-minor-mode`. Otherwise wrap the call as `(define something (begin … #t))`.
- **Chez invokes a library lazily,** when one of its variables is first used. Libraries that only *register* things
  (commands, bindings, modes, themes, hooks) must be invoked explicitly: `scheme/boot.ss` and each test do
  `(invoke-library '(profane simple))` etc. Add new registering libraries to that list in `boot.ss` and import
  and invoke them in any test that needs their commands (M-x in a test needs `(profane complete)`).
- **Commands run in engines** (`(profane command-loop)`): a command may be suspended between slices and its
  `with-current-buffer` is undone while it waits. Don't keep other global state that must stay set across a command
  without restoring it on resume; abort drops a command without unwinding anything but `dynamic-wind` exits already run.
- **Chez evaluates procedure arguments in any order.** `(string-append (feed!) (finish!))` ran the second first;
  sequence side effects with `let*`.
- **`float` foreign arguments must be flonums.** Scheme wrappers coerce with `inexact` (see `(profane canvas)`);
  integers raise "invalid foreign-procedure argument". Colors are `unsigned-32` integers.
- Macros may not `set!` a library variable in user code: expand to a call into the library instead (see
  `with-current-buffer`).
- `defvar`'s default and options are expressions: quote list defaults and `'(local)`. `defhook` takes no doc string.
- **Record accessors take the field names**: a record `window` with field `label` defines `window-label` and
  `window-label-set!`. Don't also `define` a procedure of that name (it looped once).
- Chez has no `string-search`; tests define a small `contains?`. Positions are 0-based (`point-min` is 0).
  Predicates end in `?`, `!` marks object setters (plan §8a).
- Count parentheses when editing nested forms with scripts: one extra `)` closed a library early and surfaced as
  an unrelated "unbound identifier" error.

**FFI / C**

- C calls Scheme only via `pf_scheme_call`, which goes through the guarded `pf-ffi-call` trampoline in `boot.ss`.
  An exception escaping into C kills the process. Scheme sees integer handles only (`pf_handles`).
- New C entry points for Scheme go in `PF_NATIVE_SOURCES` (`core/CMakeLists.txt`), must not use Chez, and need a
  `define-native` line in `scheme/profane/native.sls`. Executables embedding Chez link `pf_core_whole`.
- Platform-only entry points (fonts, beep, latency) are looked up with `(foreign-entry? "name")` first, so Scheme
  tests in the standalone Chez still work.
- Display items are plain data (`pf_display_item`): new item kinds need the renderer (`PFMetalRenderer.m`,
  `Shaders.metal`) and the display-list builders updated together.

**macOS app, testing and screenshots**

- **Never capture the full screen, and never `screencapture -R` a region**: either picks up whatever is in front,
  including the owner's private windows (it happened twice). Capture profane's window by id:
  `osascript -l JavaScript tests/macos/window_id.js $PID`, then `screencapture -x -o -l$WID out.png`. A capture by
  id does **not** include the Metal layers while the window is covered, so it shows native views and the title bar
  but not text or popups. Delete a capture that shows anything else.
- **Judging pixels needs the window in front**, and profane launched from a terminal opens *behind* it (macOS 14+
  won't let it steal activation); macOS does not refresh a fully covered window, so captures are stale. That
  artifact was once mistaken for a rendering bug (plan §8b). Without the owner's say-so, prefer checks that don't
  need focus: Scheme state over the REPL, `--snapshot`, unit tests. The screen tests (`PROFANE_SCREEN_TESTS=1`)
  need an uncovered window and failed once when something else was in front.
- Start the app for REPL checks by running the binary with the environment, not `open` (which does not pass it):
  `PROFANE_REPL_SOCKET=/tmp/x.sock build/platform/macos/profane.app/Contents/MacOS/profane &`, and `pkill -x profane`
  afterwards. Rebuild first (the bundle holds a copy of `scheme/`).
- Type into the app with `build/tests/post_keys $PID text:hello C-x C-f '<left>' sleep:50 …`. It posts to that
  process only. Never use System Events `keystroke`, which types into whatever app is frontmost.
- Key events and REPL requests reach the main thread by different routes: poll for expected state (see
  `tests/macos/input.sh`), don't read once.
- **Plain keys reach Scheme as text** (through the input method), chords and named keys as keys. Scheme tests that
  call `handle-key "u"` miss bugs in how real keys arrive; `C-x u` inserted "u" in the app until item 4. In tests,
  type text with `handle-text` and chords with `handle-key`. Real-key checks belong in `tests/macos/input.sh`.
- Chords are named from the current **ASCII-capable** layout (`PFKeys.m`, `UCKeyTranslate`), so `C-f` works while
  typing Russian. Plain text keeps the active layout and IME. Option is Meta.
- macOS shows an accent picker for a held key in an `NSTextInputClient`; profane turns that off (see
  `press-and-hold-keys`).
- `--snapshot out.png` renders offscreen. It can't show on-screen presentation bugs; use the screen tests for that.

## Where things are

| Area | Where |
|---|---|
| Text core: persistent piece tree, markers, undo tree, text properties | `core/text/pf_text.*`, `pf_props.*` (§8a, §8g) |
| Layout cache (font runs, tabs, carets) | `core/layout/pf_layout.*` (§8c) |
| Window rendering (faces, line numbers, hl-line, show-paren, region, preedit, cursors, fringes, divider, mode line; canvas and native-view kinds) | `core/display/pf_window.*`, `pf_face.*` |
| Frames (place and compose windows, tab bar, pop-up stack, native placements) and strips | `core/display/pf_frame.*`, `pf_strip.*` (§8i) |
| Canvases (draw ops, hit regions) | `core/display/pf_canvas.*` |
| Display lists, renderer interface, fonts | `core/render/` |
| FFI veneers | `core/embed/pf_*_ffi.*`, `pf_handles.*`, `pf_scheme.*`, `pf_input.*` |
| Metal renderer, glyph atlas, view stack, native views, keys/IME, fonts, shaper | `platform/macos/PF*.m`, `ProfaneView.m`, `Shaders.metal` (§8b, §8d, §8e) |
| Async queue (events posted from other threads, timers) | `core/async/pf_async.*`, `(profane async)` (§8k) |
| macOS services: pasteboard, open URL/file, AppleScript, other apps' window bounds | `platform/macos/PFMacOS.*`, `(profane macos)` (§8k) |
| Project search (consult-ripgrep, consult-find) | `scheme/profane/search.sls` (§8k) |
| Keychain secrets | `PFMacOS.m`, `(profane secrets)` (§8k) |
| File system calls, dired | `core/fs/pf_fs.*`, `(profane fs)`, `(profane dired)` (§8k) |
| Sidebar file tree, buffer menu | `(profane sidebar)`, `(profane buffer-menu)` (§8k) |
| Terminal emulator (libvterm), vterm, shell-here | `core/term/pf_term.*`, `pf_window_set_terminal`, `(profane vterm)` (§8k) |
| TCP and TLS connections | `platform/macos/PFNet.*`, `(profane net)` (§8k) |
| Child processes and ptys | `core/process/pf_process.*`, `(profane process)` (§8k) |
| Scheme libraries | `scheme/profane/*.sls`: async, buffer, window, tab-bar, ace-window, transpose-frame, var, hook, keymap, face, command, mode, command-loop, simple, minibuffer, complete, canvas, eval, display, theme, themes, native, repl |
| Boot, C→Scheme entry points (`pf-key`, `pf-insert-text`, `pf-startup`, `pf-redisplay`, …), init files | `scheme/boot.ss`, `scheme/init.ss` |
