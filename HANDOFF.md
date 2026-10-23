# Handoff: continuing M2

Written 2026-10-24 by Claude Code (Opus 5.5) for the next agent (OpenCode). Read `AGENTS.md` first (rules,
commands, conventions), then this file, then the plan sections it points to. Delete or rewrite this file once
it is stale.

## 1. Where things stand

- **Done:** M0 and M1 (plan §9), on `main` and pushed to `origin` (`git@github.com:andiogenes/profane.git`).
- **M2 in progress:** items 1–3 of 8 are committed locally on a chain of branches, **not merged or pushed**.
  Continue from the newest one, on a new branch:

  | Branch | Commit | M2 item |
  |---|---|---|
  | `m2-registries` | `cfb2dfd` | 1. vars, hooks, keymaps, faces, modes, command loop (plan §8f) |
  | `m2-faces` | `d76a0f5` | 2. text properties + faces in the display engine (§8g) |
  | `m2-themes` | `2b703c6` | 3. themes, design tokens, typography, `ui-style` (§8h) |

  Each branch was cut from the previous one, so `m2-themes` contains all three. The owner chose a fast-forward of
  `main` (no PRs) for M1; ask before merging or pushing M2.
- **Tests:** 21 pass (`ctest --test-dir build`); the 3 opt-in screen tests pass too (§3).
- **Measured:** key-to-committed-frame latency p95 ≈ 1.7–2.8 ms (target < 8 ms); boot ≈ 80 ms.

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
  by hand:
  `PROFANE_NATIVE_LIB=$PWD/build/core/libpf_native.dylib build/chez/tarm64osx/bin/tarm64osx/scheme -b build/chez/tarm64osx/boot/tarm64osx/petite.boot -b build/chez/tarm64osx/boot/tarm64osx/scheme.boot --libdirs scheme:tests/scheme/lib --script tests/scheme/theme-test.ss`
  (it prints `name: N passed, M failed`; ctest only shows pass/fail).
- Sanitizers: `-DPROFANE_SANITIZE=ON` in `build-asan`; TSan via `-DCMAKE_{C,OBJC,EXE_LINKER}_FLAGS=-fsanitize=thread`
  in `build-tsan`. Both trees exist locally.
- Latency: `PROFANE_SCREEN_TESTS=1 tests/macos/latency.sh build/platform/macos/profane.app build/tools/profane-client/profane-client build/tests/post_keys`
  (`LATENCY_PREFILL_LINES=100000` for a big buffer). At the REPL: `(latency-report)`.
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
- `defvar`'s default is an expression: quote list defaults.
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
- Chords are named from the current **ASCII-capable** layout (`platform/macos/PFKeys.m`, `UCKeyTranslate`), so
  `C-f` works while typing Russian. Plain text keeps the active layout and IME. Option is Meta.
- Use short socket paths (`PROFANE_REPL_SOCKET=$(mktemp -d /tmp/pf.XXXX)/s`): Unix sockets are limited to 104 bytes.
- `--snapshot out.png` renders offscreen. It can't show on-screen presentation bugs; use the screen tests for that.

## 5. Map of what exists

| Area | Where |
|---|---|
| Text core: persistent piece tree, markers, undo tree, text properties | `core/text/pf_text.*`, `pf_props.*` (§8a, §8g) |
| Layout cache (font runs, tabs, carets) | `core/layout/pf_layout.*` (§8c) |
| Window rendering (faces, line numbers, hl-line, show-paren, preedit, cursor) | `core/display/pf_window.*`, `pf_face.*` |
| Display lists, renderer interface, fonts | `core/render/` |
| FFI veneers | `core/embed/pf_*_ffi.*`, `pf_handles.*`, `pf_scheme.*` |
| Metal renderer, glyph atlas, view stack, keys/IME, fonts, shaper | `platform/macos/PF*.m`, `ProfaneView.m` (§8b, §8d, §8e) |
| Scheme libraries | `scheme/profane/*.sls`: buffer, window, var, hook, keymap, face, command, mode, command-loop, simple, display, theme, themes, native, repl |
| Boot and C→Scheme entry points (`pf-key`, `pf-insert-text`, `pf-startup`, `pf-appearance-changed`, …) | `scheme/boot.ss` |

## 6. Next: M2 items 4–8

The order was agreed with the owner. Each item is a branch.

4. **Windows** (`m2-windows`). A window tree in Scheme over multiple C `pf_window`s: splits, `C-x 2/3/0/1/o`,
   balancing, per-window point (Emacs `window-point`; today point is the buffer's marker). Also a per-window mode
   line drawn by the window renderer from a Scheme-built format, the echo area (wire `message`'s sink,
   `%set-message-sink!` in `(profane command)`, so prefix keys and "… is undefined" become visible), tab-bar
   (frame-level window configurations), ace-window (jump labels belong to item 6, so use a seam or simple digits
   first) and transpose-frame. Apply the display minor modes to every window (they currently target only the
   selected one, see `(profane window)`). Make text scale per buffer once windows carry their own default face.
   Consume `ui-fringe-width` and `ui-mode-line-style`.
5. **Minibuffer and completion.** Reading input needs a recursive command loop: plan §0 says Scheme `await` on
   one-shot continuations; engines for preemption/`C-g`. Then `completing-read` and vertico/marginalia/consult
   equivalents (`(profane complete)`, async sources, annotations, live preview, `completion-preselect 'nearest`),
   and `M-x`. Note `C-g` cannot interrupt a busy Scheme loop yet: engines are still to be built.
6. **`(profane canvas)` on the overlay layer** (plan §5.1): draw ops, hit regions, pop-up surfaces. Internal
   pop-ups, transients and avy jump labels are built on it. The overlay layer already exists (`PF_LAYER_OVERLAY`,
   transparent, ignores the mouse). Consume `ui-popup-shadow` and the theme's `elevation` and `radius` tokens.
7. **Native-view window kind (stub view):** a window whose body is left empty by the base layer, with an AppKit
   view in `ProfaneView.nativeHost` positioned from the display snapshot (plan §1, §4).
8. **Default and ported keymaps:** fetch the owner's `andiogenes/.emacs.d` and port its bindings, e.g. `M-[`/`M-]`
   and `C-M-v` edge-of-buffer (plan §2), into an `init.ss`-style default.

## 7. Open items and known gaps

- **Owner checks pending:** a real CJK input method (Japanese/Pinyin) in the window, i.e. composition underlined at
  point, commit on Return. Also a real macOS dark-mode toggle: verified only via `(appearance-changed! 'dark)`
  and `(load-theme 'profane-dark)`.
- **Unexplained latency outlier:** one 100k-line benchmark run had a single 899 ms commit sample; five reruns stayed
  under 7 ms max (plan §8g). Watch the `max` column.
- **Undo** restores text but not its text properties (fine once highlighting re-runs).
- **Text properties** use arrays (O(runs) per edit); switch to a tree when tree-sitter highlighting makes runs
  dense (M5).
- **show-paren** counts brackets without syntax (strings and comments count), until M5.
- **Kill ring** is profane-internal; the macOS pasteboard joins with `(profane macos)` (M3).
- **Undo history** is unbounded (no `undo-limit` yet).
- **No CI** exists. `tests/macos/latency.sh` is the CI latency benchmark the plan asks for, once there is macOS CI.
- **Lines are truncated, not wrapped.** At most 4096 characters per line are shaped.
