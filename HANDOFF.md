# Handoff: continuing M2

Written 2026-10-24 by Claude Code (Opus 5.5) for the next agent (OpenCode); updated the same day after M2
item 4 (windows). Read `AGENTS.md` first (rules,
commands, conventions), then this file, then the plan sections it points to. Delete or rewrite this file once
it is stale.

## 1. Where things stand

- **Done:** M0 and M1 (plan §9), on `main` and pushed to `origin` (`git@github.com:andiogenes/profane.git`).
- **M2 in progress:** items 1–4 of 8 are committed locally on a chain of branches, **not merged or pushed**.
  Continue from the newest one, on a new branch:

  | Branch | Commit | M2 item |
  |---|---|---|
  | `m2-registries` | `cfb2dfd` | 1. vars, hooks, keymaps, faces, modes, command loop (plan §8f) |
  | `m2-faces` | `d76a0f5` | 2. text properties + faces in the display engine (§8g) |
  | `m2-themes` | `2b703c6` | 3. themes, design tokens, typography, `ui-style` (§8h) |
  | `m2-windows` | `7b9db99` + follow-up | 4. windows, mode lines, echo area, tabs, ace-window, transpose-frame, horizontal scrolling (§8i) |

  Each branch was cut from the previous one, so `m2-windows` contains all four. The owner chose a fast-forward of
  `main` (no PRs) for M1; ask before merging or pushing M2.
- **Tests:** 23 registered, 20 run by default and all pass (`ctest --test-dir build`); the 3 opt-in screen tests
  pass too (§3). ASan+UBSan (`build-asan`) passes the C, Scheme, app and input tests.
- **Measured:** key-to-committed-frame latency p95 2.0 ms with one window, 2.4 ms with four windows on one buffer,
  3.9 ms with four windows on a 100k-line buffer (target < 8 ms); boot ≈ 80 ms.

Decisions and measurements for everything built so far are in `profane-plan.md` §8a–§8h. Read those before
changing the text core, renderer, faces or themes.

## 2. How the owner works with agents

- One M2 item per branch (`m2-<topic>`), branched from the previous item's branch.
- After finishing an item: summarize, then **ask before committing**. The owner usually answers "Yes". One
  commit per item; message style per `AGENTS.md` (area prefix, imperative, ≤72-char subject, body with the fixes
  found). Mention bugs fixed and their regression tests in the commit body.
- Every bug fix gets a regression test that fails on the old code. Verify that it fails, then restore the fix.
- Update `profane-plan.md` (§8x sections) with decisions and measurements in the same change.
- Be honest about what wasn't verified. The owner values corrections, e.g. the item-5 "fix" that was later found
  to be a measurement artifact and reverted.
- The owner's own Emacs config is `andiogenes/.emacs.d` (plan §2); M2 item 8 ports its keymaps.
- The owner's macOS keyboard layout is often **Russian**. Chords must work under any layout (see §4).

## 3. Build, test, run

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug && cmake --build build
ctest --test-dir build --output-on-failure            # 21 tests: labels c, scheme, macos
PROFANE_SCREEN_TESTS=1 ctest --test-dir build -L screen   # needs a GUI session + permissions
open build/platform/macos/profane.app
build/tools/profane-client/profane-client --eval '(buffer-string)'   # socket REPL into the running app
```

- Scheme suites run in the standalone Chez with `PROFANE_NATIVE_LIB` pointing at `libpf_native.dylib`. To run one
  by hand (boot files need **absolute** paths, or Chez reports "cannot find compatible boot file"):
  `B=$PWD/build/chez/tarm64osx/boot/tarm64osx; PROFANE_NATIVE_LIB=$PWD/build/core/libpf_native.dylib build/chez/tarm64osx/bin/tarm64osx/scheme -b $B/petite.boot -b $B/scheme.boot --libdirs scheme:tests/scheme/lib --script tests/scheme/window-test.ss`
  (it prints `name: N passed, M failed` and `FAIL` lines; ctest only shows pass/fail).
- Sanitizers: `-DPROFANE_SANITIZE=ON` in `build-asan` (UBSan reports are fatal there; the Scheme suites get the ASan
  runtime preloaded via `DYLD_INSERT_LIBRARIES`); TSan via `-DCMAKE_{C,OBJC,EXE_LINKER}_FLAGS=-fsanitize=thread` in
  `build-tsan`. Both trees exist locally. ASan fills new allocations with garbage: it found a struct field I had
  added without initializing (`pf_text_new` uses `malloc`, not `calloc`).
- Latency: `PROFANE_SCREEN_TESTS=1 tests/macos/latency.sh build/platform/macos/profane.app build/tools/profane-client/profane-client build/tests/post_keys`
  (`LATENCY_PREFILL_LINES=100000` for a big buffer, `LATENCY_WINDOWS=4` to show the buffer in four windows). At the
  REPL: `(latency-report)`. Run one configuration per command: zsh does not word-split `$var`, which broke a loop
  over configurations.
- `clang-format` is not installed on this machine; code is formatted by hand to `.clang-format`.

## 4. Traps already hit (read before writing code)

**Chez / Scheme**

- **A library body allows no expression before its last definition.** Registration calls such as
  `(define-variable 'x …)`, `(define-hook 'h)` or `(define-key! …)` mid-body fail with "invalid context for
  definition". Use the definition forms: `defvar`, `defhook`, `define-command`, `define-major-mode`,
  `define-minor-mode`. Otherwise wrap the call as `(define something (begin … #t))`.
- **Chez invokes a library lazily,** when one of its variables is first used. Libraries that only *register* things
  (commands, bindings, modes, themes) must be invoked explicitly: `boot.ss` and the tests do
  `(invoke-library '(profane simple))` etc. Add new registering libraries to that list in `scheme/boot.ss`.
- Macros may not `set!` a library variable in user code. Expand to a call into the library instead (see
  `with-current-buffer`).
- `defvar`'s default and options are expressions: quote list defaults and `'(local)`. `defhook` takes no doc string.
- **Record accessors take the field names**: a record `window` with field `label` defines `window-label` and
  `window-label-set!`. Don't also `define` a procedure of that name (it was done twice in item 4 and looped).
- Chez has no `string-search`; window-test.ss has a small `contains?`.
- Positions are 0-based (`point-min` is 0). Predicates end in `?`, `!` marks object setters (plan §8a).

**FFI / C**

- C calls Scheme only via `pf_scheme_call`, which goes through the guarded `pf-ffi-call` trampoline in `boot.ss`.
  An exception escaping into C kills the process. Scheme sees integer handles only (`pf_handles`).
- New C entry points for Scheme go in `PF_NATIVE_SOURCES` (`core/CMakeLists.txt`), must not use Chez, and need a
  `define-native` line in `scheme/profane/native.sls`. Executables embedding Chez link `pf_core_whole`.
- Platform-only entry points (fonts, beep, latency) are looked up with `(foreign-entry? "name")` first, so Scheme
  tests in the standalone Chez still work.

**macOS app, testing and screenshots**

- **Bring the window to the front before judging pixels.** Launched from a terminal, profane opens *behind* it
  (macOS 14+ won't let it steal activation), and macOS does not refresh a fully covered window, so captures are
  stale. That artifact was once mistaken for a rendering bug (plan §8b).
- Capture only profane's window, by id: `osascript -l JavaScript tests/macos/window_id.js $PID`, then
  `screencapture -x -o -l$WID out.png`. **Never capture the full screen**: it picks up the owner's private windows.
  The terminal has Screen Recording and Accessibility permission.
- Type into the app with `build/tests/post_keys $PID text:hello C-x C-f '<left>' sleep:50 …`. It posts to that
  process only. Never use System Events `keystroke`, which types into whatever app is frontmost.
- Key events and REPL requests reach the main thread by different routes: poll for expected state (see
  `tests/macos/input.sh`), don't read once.
- **Plain keys reach Scheme as text** (through the input method), chords and named keys as keys. Scheme tests that
  call `handle-key "u"` therefore miss bugs in how real keys arrive; `C-x u` inserted "u" in the app until item 4.
  Real-key checks belong in `tests/macos/input.sh`.
- Chords are named from the current **ASCII-capable** layout (`platform/macos/PFKeys.m`, `UCKeyTranslate`), so
  `C-f` works while typing Russian. Plain text keeps the active layout and IME. Option is Meta.
- Use short socket paths (`PROFANE_REPL_SOCKET=$(mktemp -d /tmp/pf.XXXX)/s`): Unix sockets are limited to 104 bytes.
- `--snapshot out.png` renders offscreen. It can't show on-screen presentation bugs; use the screen tests for that.

## 5. Map of what exists

| Area | Where |
|---|---|
| Text core: persistent piece tree, markers, undo tree, text properties | `core/text/pf_text.*`, `pf_props.*` (§8a, §8g) |
| Layout cache (font runs, tabs, carets) | `core/layout/pf_layout.*` (§8c) |
| Window rendering (faces, line numbers, hl-line, show-paren, preedit, cursors, fringes, divider, mode line) | `core/display/pf_window.*`, `pf_face.*` |
| Frames (place + compose windows, tab bar) and one-line strips (mode lines, tab bar) | `core/display/pf_frame.*`, `pf_strip.*` (§8i) |
| Display lists, renderer interface, fonts | `core/render/` |
| FFI veneers | `core/embed/pf_*_ffi.*`, `pf_handles.*`, `pf_scheme.*`, `pf_input.*` (prefix-pending flag) |
| Metal renderer, glyph atlas, view stack, keys/IME, fonts, shaper | `platform/macos/PF*.m`, `ProfaneView.m` (§8b, §8d, §8e) |
| Scheme libraries | `scheme/profane/*.sls`: buffer, window (frames, tree, mode lines, echo area), tab-bar, ace-window, transpose-frame, var, hook, keymap, face, command, mode, command-loop, simple, display, theme, themes, native, repl |
| Boot and C→Scheme entry points (`pf-key`, `pf-insert-text`, `pf-startup`, `pf-redisplay`, `pf-appearance-changed`, …) | `scheme/boot.ss` |

## 6. Next: M2 items 5–8

The order was agreed with the owner. Each item is a branch, cut from `m2-windows`.

4. **Done: windows** (`m2-windows`, plan §8i). Hooks left for the next items: the **minibuffer window** already
   exists at the bottom of every frame (`minibuffer-window`), showing the echo buffer; `set-transient-map` exists
   in the command loop; ace-window shows its labels in the mode line (`mode-line-window-label`); `tab-rename` is a
   procedure waiting for a command that reads a name.
5. **Done: minibuffer and completion** (`m2-minibuffer`, plan §8i). Callback-based `read-from-minibuffer` /
   `completing-read`, vertico-style candidates, `M-x`, `C-x b`, `C-x k`, `C-x t RET`; `post-command-hook`;
   `tests/scheme/minibuffer-test.ss`. Left: file-name reading with directory keys, consult-style sources (imenu,
   ripgrep, find, yank, xref) and `completion-preselect 'nearest` on top of `completing-read`; popup completion
   (corfu) waits for the canvas (item 6). `C-g` still cannot interrupt a busy Scheme loop (engines).
6. **Done: `(profane canvas)` on the overlay layer** (`m2-canvas`, plan §8i): canvases, pop-up surfaces, hit
   regions, rounded rect and shadow items, ace-window badges; `tests/c/test_canvas.c`, `tests/scheme/canvas-test.ss`.
   Left: the mouse reaching `canvas-click!` (no mouse routing in `ProfaneView` yet), paths/images/clip/transform,
   transients and avy jump labels (built on the canvas), and moving the minibuffer candidates and completion popups
   onto it (corfu). The overlay's first frame is an empty list (set by the frame's first resize).
7. **Done: native-view window kind** (`m2-native-view`, plan §8i): `set-window-native!`, placements to the shell,
   `PFNativeViews` with a stub view; tests in `test_frame.c` and `window-test.ss`. Left: real view kinds (web M8,
   PDF), key and mouse routing into native views and focus handoff. Canvas windows are done (`m2-canvas-window`);
   inline canvases and clipping are not. The placement was checked in the running app by a window-ID capture, which does not include
   the Metal layers while the window is covered; check it visually with the window in front.
8. **Done: default and ported keymaps** (`m2-keymaps`, plan §8i): `scheme/init.ss` (the owner's port) plus the user's
   init file loader in boot.ss; new commands `edge-of-buffer`, `consult-buffer`, `consult-yank-from-kill-ring`,
   `minibuffer-edge-of-candidates`; `tests/scheme/init-test.ss`. The port list says what waits for which feature.

M2 items 1-8 are done (item 6 also has canvas windows). Branches stack: `m2-windows` < `m2-minibuffer` < `m2-canvas` <
`m2-native-view` < `m2-canvas-window` < `m2-keymaps`; none is merged or pushed. Remaining M2 scope per plan §9: transients,
and the consult/corfu parts listed above; check §9 before choosing the next item.

## 7. Open items and known gaps

- **Press-and-hold** is off so held keys repeat; `press-and-hold-keys` turns the accent picker back on per key. Owner
  check: hold a key (it should repeat) and, after `(var-set! 'press-and-hold-keys '("e"))`, hold `e` (picker expected).
  Branch `m2-press-and-hold`, cut from `m2-keymaps`.

- **Owner checks pending:** (the CJK input method check is dropped: the owner does not use those languages.) A real macOS dark-mode toggle: verified only via `(appearance-changed! 'dark)`
  and `(load-theme 'profane-dark)`.
- **Unexplained latency outlier:** one 100k-line benchmark run in item 2 had a single 899 ms commit sample. In item 4
  it showed again (≈900 ms max, 178 of 200 samples) in three back-to-back runs that the owner backgrounded while
  using the machine; the same configurations rerun with nothing else going on stayed under 6 ms max (five runs).
  Unconfirmed hypothesis: the window lost the front or was covered mid-run, which macOS throttles. Watch the `max`
  column.
- **Windows, not yet:** mouse selection/resizing, `C-v`/`M-v`/recenter, header lines, per-window buffer history
  (`next-buffer` cycles the whole buffer list), `C-x b`/`C-x k` (need the minibuffer). Plan §8i.
- **Undo** restores text but not its text properties (fine once highlighting re-runs).
- **Text properties** use arrays (O(runs) per edit); switch to a tree when tree-sitter highlighting makes runs
  dense (M5).
- **show-paren** counts brackets without syntax (strings and comments count), until M5.
- **Kill ring** is profane-internal; the macOS pasteboard joins with `(profane macos)` (M3).
- **Undo history** is unbounded (no `undo-limit` yet).
- **No CI** exists. `tests/macos/latency.sh` is the CI latency benchmark the plan asks for, once there is macOS CI.
- **Lines are truncated, not wrapped**; windows scroll sideways to keep point visible (§8i). Soft wrap is planned
  for M4 (plan §9). At most 4096 characters per line are shaped.
