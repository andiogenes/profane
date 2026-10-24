# profane — Implementation Plan

A GPU-accelerated, Emacs-like editor for macOS, scripted in Chez Scheme, with Magit-like Git porcelain.
Scope is shaped by the owner's actual Emacs usage (andiogenes/.emacs.d).

## 0. Decisions

| Decision | Choice |
|---|---|
| Platform | macOS 14+, Apple Silicon only, GUI only (no terminal frontend) |
| Shell / input | AppKit, custom `NSView` implementing `NSTextInputClient` |
| GPU | Metal directly (`CAMetalLayer`, `CAMetalDisplayLink`) behind a thin `pf_renderer` C interface |
| Text | Core Text shaping/fallback/rasterization; grayscale + color-emoji atlas |
| Core language | C17 core, Objective-C platform shell, no Swift |
| Scripting | Chez Scheme 10.x (threaded, `tarm64osx`), R6RS libraries + R7RS shim; vendored as a submodule at `subprojects/chez` (v10.4.1), built via CMake ExternalProject |
| Elisp compatibility | None. Emacs-familiar names, own Scheme API; owner's config gets ported |
| Git | libgit2 for reads, `git` CLI for all mutations |
| Async | GCD + CFRunLoop, FSEvents, kqueue; Scheme `await` on one-shot continuations; engines for preemption/`C-g` |
| Org | "Org-lite": notes and outlines on unchanged `.org` files; no agenda/babel/export |
| UI style | Quiet by default: `(ui-style 'minimal)` default, opt-in `'rich` preset; one design-token system drives all UI |
| Widgets | Public low-level canvas API + mid-level retained widget toolkit in Scheme; host for arbitrary AppKit views |
| Agents | Both: host external agents via ACP (e.g. Claude Code) + profane as MCP server; and a native Scheme agent on the Claude Messages API (raw HTTPS/SSE, default `claude-opus-5-5`, `claude-haiku-5-5` for fast tasks) |
| Web | Web buffers + Emacs-style browsing on system `WKWebView`; not a full browser (no extensions, passkeys/autofill, DRM, sync) |
| Distribution | Developer ID, hardened runtime (`allow-jit`), notarized, Sparkle, Homebrew cask |

## 1. Architecture

```
Scheme userland     init.ss · modes · keymaps · commands · themes · git · lsp · org-lite
profane stdlib      (profane buffer|command|keymap|mode|var|async|process|ui|canvas|widget|agent|complete|face|treesit|advice|display|secrets|macos)
FFI                 foreign-procedure / foreign-callable / ftypes; integer handles only
C17 core            piece tree · markers · intervals · undo tree · layout cache · libgit2 · tree-sitter · regex · JSON · search · workers
ObjC shell          NSApplication · ProfaneView · Metal renderer · Core Text shaper/atlas · display link · FSEvents · menus · a11y · WKWebView host
```

`ProfaneView` layer stack (reserved from M1, so native views never need a retrofit):

```
overlay CAMetalLayer   pop-ups, completion, jump labels, child-frame UI
native views           WKWebViews / AppKit views positioned each frame from the display snapshot
base CAMetalLayer      text windows, mode lines, fringes
```

- Main thread: AppKit events + Chez command loop (driven from a run-loop observer).
- Render: display-link thread encodes immutable display snapshots; never touches the Scheme heap.
- Workers: GCD queues for git/treesit/search/IO, results posted back as C structs, resuming Scheme continuations.
- GC: `collect-request-handler` defers collections to post-frame/idle.
- Display engine supports a **native-view window kind**: the base layer leaves the window's body empty and the shell places the native view there.
- Live redefinition: commands/keymaps/vars/hooks/faces/modes live in mutable registries keyed by symbol; keys bind symbols.

## 2. Feature scope (mapped from current Emacs usage)

| Emacs today | profane |
|---|---|
| Stock keybindings, `M-[`/`M-]`, `C-M-v` edge-of-buffer | Default keymap + port in `init.ss` |
| modus-operandi / vivendi-tinted, JetBrains Mono 14 | Accessible high-contrast light/dark themes; built-in `after-load-theme-hook` |
| line numbers, hl-line, show-paren (0 delay), electric-pair, 1px fringe, maximized frame, display-time | Built-in global modes / variables |
| vertico (5 rows, directory keys), marginalia, consult (imenu, ripgrep, find, buffer, yank, xref) | `(profane complete)` with async sources, annotations, live preview, `completion-preselect 'nearest` |
| transient | Generic transient menus |
| corfu + popupinfo, `tab-always-indent 'complete` | Completion-at-point popup + doc side panel |
| ace-window, avy, transpose-frame, tab-bar, buffer-menu | Built-in commands, GPU-drawn jump labels |
| dired (+ copy full path), neotree | One file-tree/listing component: dired view + sidebar view |
| eglot + call/type hierarchy | LSP client, hierarchy as section trees |
| magit, ediff (side-by-side, plain) | `(profane git)`, in-frame 2/3-way diff |
| vterm (fish), shell-here | libvterm terminal on Metal, `shell-here` |
| Clojure+inf-clojure, Scala, Scheme+Geiser/Kawa, Lua, Swift (.cj), C/C++ + clang-format, JSON, Markdown, LLVM IR, MLIR | tree-sitter grammars, regex mode definer, generic REPL mode (nREPL/inferior Clojure, Chez, Kawa), `format-buffer` |
| org + org-modern (notes/outlines) | Org-lite (§3) |
| sensitive.el | `(profane secrets)` on Keychain |
| osascript, `open` | `(profane macos)`: `open-url`, in-process AppleScript, other-app window bounds |
| dashboard.el | Ported as a Scheme package |
| twitch.el (ERC + httpd OAuth + AppleScript browser layout) | IRC package; OAuth via in-app web buffer (redirect intercepted, no httpd); stream in a web buffer split next to chat, replacing the AppleScript layout |
| listing.el | HTML listing previewed in a web buffer beside the code |
| external browser for docs/previews | Web buffers (§4); Markdown/Org-lite live preview; rich LSP hover docs |

Optional, off in the minimal preset (see §6): command palette, which-key, minimap, vibrancy/Liquid Glass. Not planned: multiple cursors, customize UI.

## 3. Org-lite

Goal: open, edit and save existing `.org` notes **losslessly** — anything not understood is preserved byte-for-byte.

In scope:
- Headings: folding with `TAB` / `S-TAB` global cycling, startup visibility, navigation (`C-c C-n/p/f/b/u`), promote/demote and move subtrees (`M-←/→/↑/↓`, `M-S-…`), insert heading (`M-RET`)
- Plain lists (ordered/unordered), checkboxes with `C-c C-c` toggle and `[n/m]` / `[%]` cookies
- TODO/DONE keyword cycling (`C-c C-t`), tags displayed and searchable
- Links `[[target][desc]]`: follow file/URL/heading links, insert link
- Tables: `TAB`-driven auto-align, row/column move/insert/delete
- Emphasis, `#+TITLE` etc., source blocks with tree-sitter highlighting of the inner language (no execution), drawers folded
- org-modern-style rendering: real bullets, styled heading sizes, block frames, aligned tables, hidden emphasis markers (revealed at point)
- `consult-outline`/imenu over headings with nearest-heading preselect
- Simple `capture-note` into a configured inbox file

Out of scope: agenda, Babel execution, export, clocking, scheduling logic, property inheritance semantics.

Implementation: tree-sitter-org grammar for structure + Scheme commands operating on the buffer text; folding via `invisible` intervals; rendering via faces, overlays and GPU-drawn decorations.

## 4. Web buffers

Built on `WKWebView` (system WebKit, out-of-process). Scope: levels 1–2 only.

Web buffers:
- `browse-url` / `eww`-style `web-open` → a buffer of mode `web-mode` shown in a native-view window
- Back/forward/reload/stop, title + URL + load progress in mode line
- URL entry with completion over history and bookmarks; open-link-in-new-buffer; buffers double as tabs (`consult-buffer` lists them)
- Separate persistent website data store per profile (`WKWebsiteDataStore(forIdentifier:)`)

Emacs-style browsing:
- Keyboard-first: `C-n/C-p/C-v/M-v/M-</M->` scroll, `C-s/C-r` in-page search (WebKit find API), `M-w` copy selection, `w` copy URL
- Link hints (avy-style labels drawn on the overlay layer from JS-collected link rects)
- Bookmarks and history stored as Scheme data; `consult`-style sources for both
- Scheme↔JS bridge: `(await (web-eval buf "js"))`, `WKScriptMessageHandler` → Scheme callbacks, user scripts injected per site
- Navigation policy hook in Scheme (intercept redirects, e.g. OAuth tokens; route `mailto:`, files, etc.)
- Downloads (`WKDownload`) to `~/Downloads` with progress in a list buffer
- Content blocking via `WKContentRuleList` from a configurable rule file
- Reader view (readability pass in JS → rendered as a native profane text buffer)
- Web Inspector enabled (`isInspectable`) for debugging pages and the bridge

Keyboard & focus:
- `ProfaneView` intercepts key events first: global/prefix keys (`C-x`, `M-x`, `M-o`, `C-g`, …) always reach profane
- Typing into a focused page form switches to **web-insert** state (indicated in mode line); `C-g`/`Escape` returns to command state

Constraints accepted:
- A web buffer can be live in only one window; other windows showing it display a snapshot with a "shown in another window" note
- No profane smooth-scroll/animation inside pages; native views clip during window-resize animations
- Out of scope: extensions, passkeys/password autofill, Widevine DRM, sync

## 5. Widgets

Most of this machinery exists anyway for profane's own UI (transients, completion, corfu, jump labels, sections, log graph, dashboard); the work is exposing it publicly and adding a toolkit on top. Internal UI is rebuilt on the public API to dogfood it.

### 5.1 Low-level: `(profane canvas)` (M2)
- Draw ops from Scheme: rect, rounded rect, shadow, line, bezier, filled path, text runs, image, clip, transform
- Text measurement via Core Text: `(text-extent str face)`
- Hosts: **canvas window** (buffer as a drawing surface), **inline** (reserves space in a text line, like an image), **pop-up surface** on the overlay layer
- Input: hit regions, mouse/scroll/key/focus events, cursor shapes
- Retained display lists; redraw only when invalidated or animating

```scheme
(define-canvas (cpu-meter c w h)
  (fill-rounded-rect! c 0 0 w h 6 (face-bg 'mode-line))
  (fill-rect! c 0 0 (* w (cpu-load)) h (face-fg 'success))
  (draw-text! c 8 (/ h 2) (format "~a%" (round (* 100 (cpu-load)))) 'mode-line))
(on-click! cpu-meter (lambda (x y) (open-activity-monitor)))
```

### 5.2 Mid-level: `(profane widget)` (M7)
- Declarative widget tree with keyed diffing onto canvases
- Layout: vstack/hstack, grid, flex sizing, padding, alignment, scroll
- Widgets: label, button, checkbox, toggle, radio, slider, progress, virtualized list, table, tree, tabs, splitter, scroll view, image, popup menu
- **Text input = a real profane buffer** in a mini window: keymaps, completion and undo for free
- Keyboard-first: focus order, `TAB`/`S-TAB`, mnemonics, avy-style jump labels to any widget
- Styling from theme faces (follows light/dark); `NSAccessibility` exposure for VoiceOver
- Dogfood: sidebar, dashboard and transient menus rebuilt on the toolkit

```scheme
(define (todo-panel items)
  (vstack 'spacing: 6
    (hstack (label "Tasks" 'face 'bold) (spacer)
            (button "Add" (lambda () (add-item!))))
    (list-view items
      (lambda (it) (hstack (checkbox (item-done? it) (toggle! it))
                           (label (item-title it)))))))
(show-widget (todo-panel tasks) 'in: 'side-window)
```

### 5.3 Native AppKit views (M11, with web buffers)
- Same native-view layer as WKWebView: `(make-native-widget 'pdf "file.pdf")`
- Initial set: PDFKit, AVKit (video), QuickLook preview; MapKit/SwiftUI hosting as needed
- Same constraints as web buffers: live in one window at a time, explicit focus hand-off

## 6. Modern UI

Principle: **quiet by default**. "Modern" means polish and clarity, not more chrome. Two presets:
`(ui-style 'minimal)` (default; close to the owner's current Emacs look: no scrollbars, 1px fringes) and `(ui-style 'rich)`.

### 6.1 Design system (M2)
- Design tokens defined by themes: spacing scale, radii, elevation/shadows, type scale, semantic color roles
- Every surface (widgets, pop-ups, mode line, tab bar, Git UI) styles itself from tokens; switching themes restyles everything
- Built-in `after-load-theme-hook`; themes follow macOS appearance and accent color

### 6.2 Typography (M2)
- SF Pro for UI chrome (mode line, tabs, menus, widgets), JetBrains Mono for code
- Variable-pitch text in Org-lite/Markdown/doc buffers; mixed fonts per face
- Line-height control, per-mode OpenType feature toggles, pinch-to-zoom text scale

### 6.3 Window furniture (M7, on the widget toolkit)
- **Mode line**: compact segments with SF Symbols (mode, git branch/dirty, LSP status, diagnostics count, position)
- **Tab bar**: optionally unified into the titlebar; drag to reorder, pin, close; configurable separator
- **Header-line breadcrumbs**: path › type › function from tree-sitter/LSP (M8)

### 6.4 Editing surface
- Fringe git change marks (thin added/modified/deleted bars) — M4
- Inline diagnostics as virtual text with soft rounded backgrounds; LSP inlay hints — M5
- Indent guides, symbol-occurrence highlight, color swatches — M5
- **Overview scrollbar**: thin auto-hiding overlay strip with diagnostics, git changes, search hits, point — M8
- **Sticky scroll**: enclosing function/class header pinned at window top — M8
- Inline images in Org-lite/Markdown/LSP docs — M10

### 6.5 Motion (system in M4, applied everywhere)
- One spring-based animation system: smooth scrolling, subtle animated cursor, window split/resize, fold/unfold, pop-up fade/slide
- Honors macOS "Reduce Motion"; each element can be disabled; animation never delays input handling or exceeds the frame budget

### 6.6 Feedback (M8)
- Non-intrusive toasts ("Pushed to origin/main"), mode-line progress for LSP/git, `*messages*` history buffer

### 6.7 Mouse & trackpad
- Hover states, tooltips, context menus, drag tabs and window dividers, momentum scrolling; keyboard remains complete

### 6.8 Optional (off in minimal preset)
- Command palette, which-key hints, minimap, vibrancy / Liquid Glass (macOS 26)

## 7. Agents

The model call is the easy part; the work is reviewable edits, concurrency with the user's typing, permissions and safety. Existing pieces do most of it: JSON-RPC (LSP), sections, Git porcelain, piece-tree snapshots, markers, undo groups, command registry.

### 7.1 External agents (M6)
- **ACP client** (Agent Client Protocol, JSON-RPC over stdio) on the LSP JSON-RPC layer: run Claude Code (via its ACP adapter) or other ACP agents inside profane; the agent handles its own auth (e.g. Claude subscription)
- **profane as MCP server**: exposes open buffers, selection, diagnostics, project structure, symbols to external agents (incl. Claude Code running in a profane vterm)
- Agent edits/permission requests surface through the same review and approval UI as the native agent (§7.3)

### 7.2 Native agent (M9)
- `(profane agent)` in Scheme on the Claude Messages API; raw HTTPS + SSE via `NSURLSession` exposed to Scheme (no official C/Scheme SDK), JSON via yyjson
- Models: `claude-opus-5-5` default agent; `claude-haiku-5-5` for inline edits, summaries, commit messages; model + request shape isolated in one provider module
- API usage: streaming (with eager tool-input streaming + validation), adaptive thinking with explicit effort, prompt caching (stable tools + system prefix), compaction for long sessions, task budgets, refusal handling with fallbacks; respects Opus 5.5 constraints (no forced `tool_choice`, no prefill, thinking always on)
- Tools defined like commands, user-extensible:
  ```scheme
  (define-agent-tool (find-definition symbol)
    "Jump target for SYMBOL via LSP/tree-sitter."
    '((symbol . string))
    (lsp-definition symbol))
  ```
- Built-in tools: read buffer/region/files, structured edits, ripgrep, tree-sitter + LSP queries (definitions, diagnostics, hierarchies), shell in a vterm/process, git status/diff/log, fetch via web buffer, allowlisted editor commands
- **MCP client** (local stdio + remote servers) on the same JSON-RPC layer
- API key in Keychain via `(profane secrets)`; Bedrock/Vertex as optional providers later

### 7.3 UX
- **Agent chat buffer**: section-based transcript (collapsible tool calls, thinking summaries, diffs), buffer-backed input, Org-lite markup
- **Inline edit**: region → instruction → diff preview → accept/reject per hunk
- **Magit-style review**: every agent edit is a reviewable diff with the porcelain keys (`s`/`u`/`k` on hunks and lines)
- **Concurrent edits**: agent works on copy-on-write snapshots; edits are anchored with markers so they land correctly while the user types; one undo group per agent step; unplaceable edits become conflict hunks, never silent overwrites
- **Permissions**: minibuffer prompts (`y` / `n` / always), stored per tool and per project; shell, network and out-of-project writes ask by default
- **Checkpoints**: git stash/worktree checkpoint before each agent task; one-command rollback
- **Parallel agents** (M12): each task in its own git worktree as a background task; toasts on completion; results reviewed as branches in the git status buffer
- Tokens and cost in the mode line; `*agent-log*` buffer
- Optional later: ghost-text inline completions

### 7.4 Safety
- Web pages, fetched files and MCP output are marked untrusted; mutating or network tools always require approval; sessions that have read untrusted content lose auto-approve
- File tools confined to the project unless approved

## 8. Magit-like porcelain

Layers: libgit2 reader (workers, ftype structs) → git CLI runner (`GIT_EDITOR`/`GIT_SEQUENCE_EDITOR`/`SSH_ASKPASS` → `profane-client`, logged to `*git-process*`) → generic section framework → porcelain.

- v1: status, stage/unstage/discard file/hunk/line selection, diff with word refinement, commit transient + message buffer, branch/push/pull/fetch transients, Keychain credentials, ediff-style side-by-side
- v2: GPU log graph (virtualized), interactive rebase, blame, stash, cherry-pick/revert/reset/tag/worktree, 3-way conflict resolution
- Refresh: FSEvents → worker status → section-tree diff in a low-priority engine (preserves folds and point)

## 8a. Text core decisions (M1)

- **Piece tree** (`core/text/pf_text`): a *persistent* treap of pieces over append-only UTF-8 blocks. Edits path-copy
  O(log n) nodes; a snapshot is a refcounted root, readable from any thread without locks. This is what the render
  thread, workers and agent copy-on-write edits (§7.3) read. Pieces are ≤ 4 KiB so in-piece work stays cheap;
  consecutive typing extends the last piece instead of adding nodes.
- **Positions** are characters (UTF-8 units), as in Emacs; byte offsets are available for search/regex. Invalid
  bytes count as one character each, per piece, and are never rewritten (lossless saves). Measured at -O2 on a 64 MB
  file: load 37 ms, typing 0.55 µs/insert, random edit ~6 µs, line lookup ~0.5 µs.
- **Markers**: integer handles (slot + generation, stale handles rejected) with Emacs insertion types; adjusted
  linearly per edit — fine for point/mark/window starts; overlays/intervals get their own structure later.
- **Undo tree** in C: changes accumulate into a group until `pf_text_undo_boundary` (Scheme's command loop decides
  grouping); typing and backspace runs coalesce. Each change keeps the *removed subtree*, and undo/redo graft
  subtrees back in O(log n), so history costs about what it deleted (100k random edits: +16 MB of undo). Keeping a
  whole root per undo state was tried first and rejected: it pinned ~24 KB per state (141 MB for the same run).
  Editing after undo branches instead of discarding; "modified" is a per-state version compare.
- **Scheme buffer API** (`(profane buffer)`, unstable): Emacs-familiar names, but **positions are 0-based** like
  Scheme string indices (Emacs `point-min` is 1); predicates end in `?` (`bob?`, `eol?`), `!` marks object setters
  (`set-marker!`); editing primitives keep Emacs names (`insert`, `goto-char`). Point and mark are C markers, so
  undo and other edits move them. Raw invalid bytes read as U+FFFD in Scheme strings but stay intact in the buffer
  and on save.
- **FFI linking**: Scheme calls `pf_buf_*` (handle-based, `core/embed/pf_buffer_ffi.h`) via `foreign-procedure`.
  Executables embedding Chez link the core whole-archive and Scheme does `(load-shared-object #f)`; Scheme tests in
  the standalone `scheme` load the `pf_native` dylib (`$PROFANE_NATIVE_LIB`). No dylib ships in the bundle, so
  library validation under the hardened runtime is not involved.

## 8b. Rendering decisions (M1)

- **Display lists** (`core/render/pf_display`): immutable, refcounted lists of rects and positioned glyphs in points,
  built on the main thread and only read by the render thread — the "immutable display snapshot" of §1.
- **`pf_renderer`** (`core/render/pf_renderer.h`, Metal in `platform/macos/PFMetalRenderer`): `submit(layer, list)`,
  newest list per layer wins. A render thread driven by the view's `CADisplayLink` redraws only changed layers, is the
  only thread touching drawables/`drawableSize`, and pauses the link when idle (0% CPU at rest). One instanced draw
  per layer (rects, gray glyphs, color glyphs share a pipeline).
- **Glyph atlas**: rasterized on the render thread with Core Text on a miss — grayscale R8 page + BGRA color page
  (emoji), 4 horizontal subpixel bins, shelf packing; when full, wait for the GPU, reset, rebuild the frame.
- **Fonts** are integer ids (`pf_font`); fallback fonts chosen by Core Text during shaping are registered on the fly.
- **View stack**: `ProfaneView` = base Metal layer / native-view host / transparent overlay Metal layer (ignores the
  mouse). Shaping is still done ad hoc in the view until the layout cache (next M1 item) replaces it.
- **Present directly** from the command buffer on the render thread (lowest latency). An explicit-CA-transaction
  present (`presentsWithTransaction`) was adopted in item 5 for "frames lost early in a window's life" and then
  reverted in item 6: that symptom was a measurement artifact — macOS does not refresh a fully covered window, so
  captures of a window behind the terminal were stale. With the window in front, and after uncovering a window
  edited while covered, the direct path shows current content every time. On-screen tests bring the window front.
- **Frames are confirmed, not assumed**: a frame presented before the window is on screen is dropped with no error
  (and `presentedTime` reads 0 even for visible windowed frames, so it can't tell). A committed frame counts as shown
  only when its presented handler fires; otherwise it is re-presented every ~250 ms, up to 10 times. Found as an
  intermittent blank window (≈1 in 3 launches right after another instance quit).
- Verified: emoji/CJK fallback render, overlay composites over base on screen and in `--snapshot`, TSan-clean
  across startup, live resizes and snapshots.

## 8c. Layout and windows (M1)

- **Layout cache** (`core/layout`): lines shaped into glyphs + a caret x per character, cached by *content* (font +
  code points) in an LRU; an edit only misses for changed lines, identical lines share a layout, and nothing is
  keyed by line number. Entries used in the current frame are never evicted mid-frame. Tabs expand in the core;
  shaping (ligatures, fallback) is behind `pf_shaper`, Core Text on macOS, a fake monospace shaper in C tests.
- **Window display** (`core/display/pf_window`): renders a buffer into a display list, scrolls minimally to keep
  point visible, skips rendering when text snapshot, point, size and style are unchanged, and draws Emacs's filled
  box cursor. Lines are truncated (no soft wrap yet); at most 4096 characters per line are shaped.
- Redisplay runs after Scheme work from the main run loop's idle observer, so REPL edits show up immediately.
  Scheme picks what a window shows via `(profane window)`; the shell owns the window (one per frame in M1;
  M2 windows: §8i).

## 8d. Input and editing features (M1)

- **Keys** are Emacs-style descriptions built in `PFKeys` (`C-f`, `M-<`, `<left>`). Chords use the key's character in
  the current **ASCII-capable layout** (`UCKeyTranslate`), so bindings work while typing Russian or any non-Latin
  layout; plain typing keeps the active layout and input method. Option is Meta (GNU Emacs NS default), Command keeps
  the menus. Found when every chord was dead under the owner's Russian layout (`C-ф`).
- **IME** via `NSTextInputClient`: composition is drawn inline at point (underlined) without entering the buffer; the
  candidate window is placed at the last cursor rect.
- **Command loop** (`(profane command)`): symbol-keyed command registry, one global keymap (M2: registries, prefix
  maps, modes), undo boundary per command, typed characters amalgamated 20 at a time.
- **display-line-numbers / hl-line / show-paren** (on by default, per the owner's config) are per-window options of
  the portable window renderer, switched from Scheme; show-paren matches immediately (no delay), bounded to 100k
  characters, plain bracket counting until tree-sitter syntax (M5).

## 8e. Latency (M1)

Measured with `tests/macos/latency.sh` (opt-in `screen.latency`): 200 real key events posted to the app 30 ms apart;
the renderer tags the frame answering each event and records when it was submitted, committed and presented
(`pf_renderer_latency`, `(latency-report)` at the REPL). Milliseconds from the key event, p50 / p95, 60 Hz display:

| Stage | Before | After | 100k-line buffer |
|---|---|---|---|
| submit (input, command, redisplay) | 1.0 / 1.2 | 1.1 / 1.3 | 1.4 / 1.7 |
| **commit** (frame encoded and committed: the <8 ms target) | 5.5 / **10.5** | **1.4 / 1.7** | 2.0 / 2.5 |
| present (presented handler) | 25 / 30 | 15–16 / 21 | 17 / 22 |

- The fix: the render thread renders as soon as a frame is submitted instead of at the next display-link tick.
- **Present** is bounded below by the display: one 16.7 ms refresh plus WindowServer compositing. `displaySyncEnabled
  = NO` (~1 ms, within noise) and `maximumDrawableCount = 2` (worse p95) were measured and not adopted. The target is
  therefore defined on *commit* — the part profane controls — and present is tracked alongside it.
- §10 calls for a latency benchmark in CI: this script is it, to be wired up once macOS CI exists (none yet).

## 8f. Registries (M2)

- Libraries: `(profane var)` variables with defaults, buffer-local values (`local` = auto-local), `permanent`
  locals and change watchers; `(profane hook)` named hooks whose functions may be symbols, resolved each run;
  `(profane keymap)` keymaps of canonical key strings (`kbd`), prefix sub-keymaps and parents; `(profane face)` faces
  with inheritance down to `default` and change watchers; `(profane command)` the command registry, prefix argument
  and `message` (→ `*Messages*`); `(profane mode)` major modes (inheritance chain, mode maps, hooks) and minor modes;
  `(profane command-loop)` key sequences, `C-u`/digit arguments, `C-g` in a prefix; `(profane simple)` basic commands
  (motion, mark, kill ring, undo) and the default global bindings.
- Lookup follows Emacs: a key sequence is looked up whole in each active map (minor modes, most recent first; major
  mode; global) and a map falls back to its parent, so a mode can extend `C-x` without hiding global `C-x` keys.
- Everything is keyed by symbol; keys bind command names. Registering libraries must be invoked explicitly
  (`invoke-library`), since Chez only runs a library body when one of its variables is first used.
- The kill ring is profane-internal for now; the macOS pasteboard joins with `(profane macos)` (M3).

## 8g. Faces and text properties (M2)

- **Text properties** (`core/text/pf_props`): per property id, sorted non-overlapping runs of 32-bit values, merged
  when equal and adjacent, moved by edits and undo/redo like Emacs text properties (plain insert inherits nothing).
  Arrays for now (O(runs) per edit); a tree can replace them behind the API once highlighting is dense (M5). Undo
  restores text but not its properties; re-highlighting covers that.
- **Faces in C** (`core/display/pf_face`): id → fg/bg/underline/font; display roles (default, cursor, line numbers,
  hl-line, show-paren) map to face ids. `(profane display)` resolves every face (inheritance → `default`) and pushes
  them all on any change, so a theme change restyles everything; fonts for bold/italic/family/height are opened via
  `pf_font_open_styled`.
- **Rendering**: per character face ids → font runs for layout (each run shaped separately; ligatures don't cross a
  font change); colors per glyph cluster; face backgrounds and underlines as rects, then the hl-line band (overlay
  priority, as in Emacs), then paren highlights. The default face's background is the clear color.
- The light/dark palette is interim (in `(profane display)`), driven by the macOS appearance; themes replace it.

## 8h. Themes, tokens and typography (M2)

- **Themes** (`(profane theme)`): a palette of semantic roles (`fg`, `fg-dim`, `bg-region`, `red`, `accent` …, may
  reference each other or `system-accent`, the macOS accent color), design tokens (spacing scale, radii, elevation
  shadows, type scale, line height) and face specs written against the palette. `load-theme` owns colors, weight,
  slant and underline of the faces it lists — resetting them, so switches never leak — and leaves typography alone.
  `after-load-theme-hook`; `theme-for-appearance` + macOS light/dark mode switch themes automatically.
- **Built-in themes** `profane-light` / `profane-dark`: own palettes in the spirit of modus-operandi / vivendi-tinted
  (not copied). A test checks WCAG contrast: body text ≥ 7:1, dimmed/comment/accent text ≥ 4.5:1, text on
  highlight backgrounds ≥ 4.5:1, cursor ≥ 7:1.
- **Typography**: code in `default-font-family` (JetBrains Mono), UI chrome and `variable-pitch` in `system-ui`
  (SF Pro); per-face OpenType `features` (e.g. ligatures off); `line-spacing`; text scale (`C-x C-=`/`C--`/`C-0`,
  trackpad pinch) — per buffer since M2 windows (§8i).
- **`ui-style`** presets `minimal` (default) and `rich` set chrome variables (`ui-fringe-width`, `ui-scroll-bars`,
  `ui-popup-shadow`, `ui-motion`, `ui-mode-line-style`) that the chrome reads as it lands.

## 8i. Windows, mode lines, echo area, tabs (M2)

- **Window tree in Scheme** (`(profane window)`): leaves are windows, splits divide their area `below` or `right`
  among children by exact weights, so a frame resize keeps proportions. Splitting halves a window (a same-direction
  parent gains a sibling, otherwise a new split replaces the window); deleting gives the space to the previous
  sibling (the next if first) and collapses one-child splits, merging same-direction nesting. `balance-windows`
  weighs children by their window count along the split. Emacs names and keys: `C-x 2/3/0/1/o/+/^/{/}`,
  `C-x <left>/<right>`.
- **C frame** (`core/display/pf_frame`): the shell owns one frame per `ProfaneView`; Scheme creates its windows and
  places them (rects in points). Each window renders into its own list only when it changed; the frame appends
  the cached lists at their origins (`pf_display_append`) and draws the tab bar. Window styles follow the default
  face and each window's text scale. Headless frames (fixed-width shaper, no fonts) run the same code in Scheme
  tests.
- **Per-window point** as in Emacs: the selected window shows the buffer's point, others their own marker;
  selection saves the old point into its window's marker first (a bug where `C-x 1` and tab switches restored a
  stale point had regression tests added).
- **Mode lines**: `mode-line-format` (buffer-local) is a list of strings, segments (procedures of the window,
  `define-mode-line-segment`), variables, `(:face FACE ...)` and nested lists; Scheme formats them before each
  redisplay and pushes text + face runs only when they changed. Drawn by the C strip renderer
  (`core/display/pf_strip`) in `mode-line` / `mode-line-inactive` (SF Pro), flat or raised per
  `ui-mode-line-style`; not text-scaled. Default: label, modified, buffer name, All/Top/Bot/NN%, (line,col), modes.
- **Echo area**: the minibuffer window under the tree shows an undo-disabled echo buffer (`buffer-disable-undo`,
  which drops the history: it would no longer match the text). It grows to fit multi-line messages (up to
  `max-mini-window-height`) and the next input clears it; keystroke echo (`C-x-`) is shown but not logged. The
  minibuffer reads input in this window (below).
- **Transients** (`(profane transient)`, M2). `define-transient` registers a menu command from groups of items: `action` (runs a
  command, symbol or procedure, then closes unless `stay`), `switch` (toggle, flag green when on) and `option` (reads a
  string in the minibuffer; empty clears). Keys are `kbd` sequences (`"- a"` is two keys). Opening shows a panel (a pop-up
  canvas with the theme's popup surface, columns per group) above the echo area and installs a **persistent** transient
  keymap: `set-transient-map` gained a third argument, `exit-transient-map!` and `clear-transient-map!`; in a persistent
  map commands run without leaving it, unbound keys only complain, `C-g` mid-sequence cancels just the sequence, and `C-g`
  or `ESC` closes it. While an option is read the map is cleared so the minibuffer gets the keys, then restored. Commands
  see the values in `(transient-args)` (an alist; unset options are left out). Values start from the defaults on each
  opening. `(popup-margin)` in `(profane canvas)` gives the shadow margin a pop-up surface needs. *Not yet:* sub-menus and
  infix arguments with choices, saved values, a `which-key`-style listing of a plain prefix map, keys shown in the panel
  as the key description (they are the spec with spaces removed), re-layout when the frame resizes while open.
- **Active region** (fix after M2 item 8: marked regions were not highlighted). Emacs's transient-mark-mode: the buffer-local
  `mark-active` (defined in `(profane command-loop)`) is turned on by `C-SPC` and `C-x C-x`, off by `C-g`, copying
  (`M-w`) and by any change to the buffer in a command (a per-buffer edit count in `(profane buffer)`, compared around each
  command; so typing, `C-w` and undo deactivate it). `M-<` / `M->` set the mark without activating it. The selected window
  draws the region in the `region` face's background under the text (`pf_window_set_region`, role `PF_ROLE_REGION`;
  a newline inside it shows as one extra cell); other windows show none, as in Emacs by default.
- **Evaluating from the editor** (`(profane eval)`, after M2 item 8). `M-:` `eval-expression` (reads in the minibuffer, history
  `eval-expression`), `C-x C-e` `eval-last-sexp` (the expression before point, found by a small tokenizer that skips
  comments and knows strings, character literals and quote prefixes; inside a list it takes the inner form), `eval-region`
  and `eval-buffer` (by `M-x`). Code runs in the interaction environment, as for the socket REPL; results and printed
  output go to the echo area and *Messages*, an error shows its message. *Deferred:* `load-file` (needs file-name
  reading, M3), interrupting a looping evaluation with `C-g` (needs engines: it blocks the editor today), `C-u C-x C-e`
  inserting the value, `eval-print-last-sexp`, `eval-defun` (`C-M-x`, needs defun motion), a REPL buffer (comint-style,
  with history and completion: with the REPL modes in M10). Needed before the M4 dogfood milestone: interruption.
- **Press-and-hold** (fix after M2 item 8). macOS shows its accent picker for a held letter in any view that is an
  `NSTextInputClient`, so held keys did not repeat. The app now sets `ApplePressAndHoldEnabled` to NO at launch and,
  for each plain key sent through the input method, sets it for that key: on only if Scheme listed the key in
  `press-and-hold-keys` (key names as the key description spells them, e.g. `"e"`; a watcher pushes the list to
  `pf_input_set_press_and_hold`). The default lives in the app's own domain only. Chords never show the picker (they
  bypass the input method), so listing one has no effect. *Unverified:* that macOS re-reads the default on each key
  down, which the per-key switch relies on; if it does not, the list takes effect only at the next launch.
- **Default and ported keymaps** (M2 item 8). Stock Emacs bindings live in the libraries (`(profane simple)` and friends); the
  owner's port of their `init.el` is `scheme/init.ss`, shipped in the bundle and loaded by `pf-startup` (`pf-load-init-files`)
  before the user's own `~/Library/Application Support/profane/init.ss` (`PROFANE_INIT` overrides; an error in either goes
  to the echo area and *Messages*, startup continues). Ported: `M-[`/`M-]` previous/next buffer, `M-o` ace-window, `C-M-v`
  `edge-of-buffer` (end, or beginning with `C--`; the same key in the minibuffer selects the last/first candidate),
  `M-g b` `consult-buffer` (live preview, restored on quit), `M-g y` `consult-yank-from-kill-ring`, `vertico-count 5`.
  *Not ported yet, waiting for their features:* `M-g i` imenu and `M-g s` search (modes, tree-sitter, search core),
  `M-g t` neotree and `C-x C-b` buffer menu (listing/tree views), `C-x C-j` avy (jump labels on the canvas),
  vertico's directory keys (`RET`, `DEL`, `M-DEL` on file names; file-name reading), electric-pair, `C-x 4 C-x C-b`.
  transpose-frame and tabs are unbound in the config (used by command name); the stock `C-x t` tab keys exist.
- **Canvas windows** (M2, after item 7). `pf_window_set_canvas` (through `pf_frame_set_window_canvas`) makes a window draw a canvas
  in its body instead of text, on the base layer from the body's top-left, so it sits under native views and the
  overlay; no fringes or cursor, mode line kept. A canvas change redraws just that window. Hit testing looks at
  pop-ups first, then canvas windows (`pf_frame_hit_test_at` also returns canvas-local coordinates, which
  `canvas-click!` now uses). Scheme: `(set-window-canvas! w canvas)`, `(window-canvas w)`; the canvas is sized to
  the body before each frame (a `define-canvas` redraws on change); `delete-canvas!` detaches it. Ops are not
  clipped to the body yet, so draw inside w x h. Inline canvases stay deferred (they need display-engine and layout
  support for reserved space in a line).
- **Native-view windows** (M2 item 7). `pf_window_set_native(kind)` (through `pf_frame_set_window_native`) makes a window leave
  its body (everything but the mode line and divider) empty on the base layer: no text, fringes or cursor. The frame
  reports native windows to the shell as placements (`pf_frame_native_get`: window tag, kind, body rect in frame
  coordinates, shown) with a generation that moves when one appears, goes, moves, resizes or hides. `PFNativeViews`
  keeps one AppKit view per native window in `nativeHost` (flipped, so frame coordinates apply; it takes no events
  of its own) and syncs after each `pf-redisplay`. Kind numbers are the shell's view classes; Scheme names them with
  `register-native-view-kind!` (`stub` = 1 is a placeholder panel that takes no events). Scheme:
  `(set-window-native! w 'stub)`, `(window-native w)`; a native window keeps its buffer for the mode line, and
  hidden-tab windows hide their view. Keys still go to the editor: input routing into views (web, PDF) comes with them.
- **Canvas** (`(profane canvas)`, `core/display/pf_canvas`; M2 item 6). A canvas is a retained op list (rect, rounded rect
  filled or outlined, shadow, line, text) plus hit regions, shown as a **pop-up surface** on the overlay layer: the
  frame keeps the pop-up stack (`pf_frame_popup_show`), composes it into one transparent display list when a canvas
  version, position or the size changed (`pf_frame_redisplay_overlay`, submitted by `ProfaneView.redisplay`) and
  answers `pf_frame_hit_test` topmost-first. The display list gained `ROUND_RECT` (fill or inside outline) and
  `SHADOW` items, drawn by signed-distance functions in the quad shader (`PF_QUAD_ROUND_RECT/SHADOW`, parameters in
  the `uv` field). Scheme: `make-canvas`, `fill-rect!`/`fill-rounded-rect!`/`stroke-rounded-rect!`/`draw-shadow!`/
  `draw-line!`/`draw-text!`, `text-extent`, `add-hit-region!`, `on-click!`, `define-canvas` (redrawn from
  `pre-redisplay-hook` once `invalidate!`d), `show-popup!`/`hide-popup!`, `canvas-click!`, and
  `draw-popup-background!` (theme `bg`/`border`, `radius m`, and the `elevation` shadow when `ui-popup-shadow` is on).
  Ace-window's labels are now badge pop-ups centered on their windows (the default mode line no longer shows
  `mode-line-window-label`; the segment remains). *Left as seams:* paths/bezier, images, clip and transform (M7), canvas
  windows and inline hosts, diagonal lines, and the mouse: the shell does not route mouse events yet, so hit regions
  are reached through `canvas-click!` (item "mouse" in §7). Transients and avy labels build on this next.
- **Minibuffer and completion** (`(profane minibuffer)`, `(profane complete)`; M2 item 5). *Divergence from §0:* input is
  callback-based (`(read-from-minibuffer prompt k)`, `(completing-read prompt collection k opt val ...)`), not a
  blocking `await`: keys arrive one at a time from the shell, so a suspended command would need a continuation that
  survives returning to C. `await` can wrap it later. While open, the minibuffer window shows ` *Minibuf-1*` (prompt in
  `minibuffer-prompt`, solid cursor; the selected window's cursor goes hollow) and keys go to it through
  `set-input-buffer-function!`; messages are logged but not shown. Candidates are lines below the input (vertico:
  `vertico-count` 5, selected line in `highlight`, annotations in `shadow`), matched orderless-style (words in any
  order, smart case), prefix then shorter first. Options: `initial require-match annotate default preselect preview
  quit history`; collections may be procedures (dynamic/async sources). RET takes the selected candidate, M-RET the
  input as typed, TAB completes, C-n/C-p select, M-p/M-n history, C-g aborts. One minibuffer at a time. Commands: `M-x`,
  `C-x b`, `C-x k`, `C-x t RET`. New `post-command-hook`. Not yet: directory keys and file reading, consult sources,
  `completion-preselect 'nearest` (the `preselect` option is the seam), interrupting a busy loop with `C-g` (engines).
- **Chrome**: fringes of `ui-fringe-width` (fringe face); a 1 pt divider (`vertical-border`) on windows with a
  neighbor to the right; glyphs that would cross the right edge are not drawn (truncation). Without a mode line
  under it a window draws only whole rows, since a partial row would land in the window below.
- **Display modes** apply to every window; hl-line and show-paren follow the selected window, as in Emacs
  (`global-hl-line-sticky-flag`). Non-selected windows show a hollow cursor (`cursor-in-non-selected-windows`).
- **Text scale per buffer** (`text-scale-factor`, buffer-local): a window draws its buffer's faces in fonts scaled
  by the platform (`pf_font_scaled`), with its line height to match.
- **Tabs** (`(profane tab-bar)`): each tab keeps a window tree and selected window; hidden tabs' windows stay alive
  (points, scroll) and are just not placed. The tab bar strip shows with more than one tab (`tab-bar-show` 1, so
  the minimal preset shows none by default). `C-x t 2/0/1/o/O`; renaming by name waits for the minibuffer.
- **ace-window**: digit labels in the mode lines and a one-shot transient map (`set-transient-map`, new in the
  command loop); `C-u` swaps buffers, `C-u C-u` deletes. Labels drawn over the windows come with the canvas (item 6).
  Unbound by default: the owner's binding comes with the keymap port (item 8). **transpose-frame**: transpose,
  flip, flop, rotate (±90°, 180°) by rewriting the splits.
- **Fix (input)**: a plain key after a prefix reached Scheme as text through the input method and was inserted
  (`C-x u` typed "u", which the Scheme tests missed by calling `handle-key`). While a key sequence or transient map
  is pending, the command loop sets a C flag (`pf_input`) and the shell sends the next plain key as a key named
  from the ASCII-capable layout, so `C-x o` works under the Russian layout too; Scheme also treats such text as keys.
- **Measured** (`tests/macos/latency.sh`, commit p50 / p95 / max in ms): one window 1.7 / 2.0 / 4.9; four windows
  on the typed-in buffer (`LATENCY_WINDOWS=4`) 2.1 / 2.4 / 5.7; four windows on a 100k-line buffer 3.3 / 3.9 / 5.8.
  Unchanged windows cost a list copy, not a render.
- Sanitizers: ASan+UBSan clean (C, Scheme suites, app, real key input). UBSan is now fatal in that tree, and the
  Scheme suites run there with the ASan runtime preloaded (they used to abort); it flagged pointer arithmetic on an
  empty text-property run list (`pf_props.c`, item 2), fixed.
- **Horizontal scrolling** (item-4 follow-up): truncated lines need it, or point disappears past the right edge (and
  its cursor was drawn over the neighboring window). Emacs's `auto-hscroll-mode`: when point leaves the text area
  (with a margin), the window scrolls to center it; `scroll-left`/`scroll-right` (`C-x <`/`C-x >`) set a minimum.
  Fringe marks show lines continuing past either edge.
- Not yet: mouse selection/resizing of windows, scrolling commands (`C-v`/`M-v`, recenter), header lines,
  per-window buffer history (`next-buffer` cycles the buffer list), window configurations beyond tabs. Soft wrap: M4.

## 8j. Open M2 items and known gaps

State at the end of the M2 work so far (everything in §8i is on `main`). Deliberately deferred work, each with what it
waits for. Keep this list current: remove an entry when it is done, add one when something is left as a seam.

**M2 items still open** (§9, M2 row): avy (`avy-goto-word-1`, jump labels on the canvas; the owner's `C-x C-j` waits on it); file-name reading with
vertico's directory keys (`RET`, `DEL`, `M-DEL` on paths) and `find-file`; mouse routing into `ProfaneView`, which
also unblocks clickable canvases, cursor shapes, mouse selection and window resizing; window extras (`C-v`/`M-v`/
recenter, per-window buffer history, header lines); electric-pair. The owner's port (`scheme/init.ss`) still lacks
`M-g i` (imenu) and `M-g s` (search), which need modes, tree-sitter and the search core (M5, ripgrep/find M3);
`M-g t` (neotree) and `C-x C-b` (buffer menu), which need listing and tree views; `C-x 4 C-x C-b`.

**Deferred, by area:**

- `C-g` cannot interrupt a busy Scheme loop (a mistyped `(let loop () (loop))` in `M-:` hangs the editor): needs
  engines (plan §0). **Required before M4.**
- Evaluating: `load-file` (file-name reading, M3), `eval-defun`/`C-M-x` (defun motion, M5), `C-u C-x C-e`
  inserting the value, a REPL buffer with history and completion (M10).
- Region: `delete-selection-mode`, `shift-select-mode`, a mark ring, `C-SPC C-SPC`, showing it in non-selected windows.
- Press-and-hold: held keys repeat; `press-and-hold-keys` re-enables the accent picker per key. The per-key switch
  assumes macOS re-reads the default on each key down, which is unverified.
- Canvas: paths and bezier curves, images, clip and transform (ops are not clipped to a canvas window), inline
  canvases (they need display-engine support for reserved space in a line), key and focus events, cursor shapes.
- Native views: only the stub kind; web (M11) and PDF kinds, key/mouse routing into views, focus handoff.
- Windows: mouse selection and resizing, `C-v`/`M-v`/recenter, header lines, per-window buffer history
  (`next-buffer` cycles the whole buffer list).
- Completion: `completion-preselect 'nearest` (the `preselect` option is the seam), corfu (popup completion).
- Undo restores text but not its text properties (fine once highlighting re-runs); undo history is unbounded.
- Text properties use arrays (O(runs) per edit); switch to a tree when tree-sitter makes runs dense (M5).
- show-paren counts brackets without syntax (strings and comments count) until M5.
- The kill ring is profane-internal; the macOS pasteboard joins with `(profane macos)` (M3).
- Lines are truncated, not wrapped; windows scroll sideways to keep point visible. Soft wrap is M4. At most 4096
  characters per line are shaped.
- No CI. `tests/macos/latency.sh` is the CI latency benchmark the plan asks for, once there is macOS CI.
- Unexplained latency outlier: single ≈900 ms commit samples appeared in 100k-line benchmark runs while the owner
  was using the machine, and not when it was idle (five clean runs, max < 6 ms). Hypothesis (unconfirmed): the
  window lost the front or was covered mid-run, which macOS throttles. Watch the `max` column.

**Owner checks done:** live macOS dark-mode toggle (2026-10-24: Dark at launch, then Light, then Dark; theme and face colors
followed, checked from Scheme state, not pixels). The CJK input-method check is dropped: the owner does not use those
languages.

## 9. Milestones

| # | Milestone | Exit criteria |
|---|---|---|
| M0 | Skeleton | `.app`, Metal clear, Chez boot files, signed build with `allow-jit` verified, socket REPL, Core Text hello |
| M1 | Text + render | Piece tree, undo, layout cache, atlas, `pf_renderer`, 3-layer view stack, IME; line numbers, hl-line, paren match; <8 ms key-to-pixel |
| M2 | Core workflow | Registries, native-view window kind (stub view), `(profane canvas)` low-level API (internal popups/transients/jump labels built on it), default + ported keymaps, windows, tab-bar, ace-window/avy/transpose, complete (vertico/marginalia/consult), transients, themes, design tokens, UI typography (SF Pro + code font), `ui-style` presets |
| M3 | Async + tools | Processes/PTY, ripgrep/find, dired + sidebar, vterm, shell-here, Keychain, `(profane macos)`, TLS sockets |
| M4 | Git v1 + ediff | Soft wrap (`truncate-lines`, `word-wrap`, `visual-line-mode` with screen-line motion; needed for daily editing and later for Org-lite/Markdown), fringe git marks, motion system (smooth scroll, cursor, splits, pop-ups, Reduce Motion). **Dogfood**: daily editing, git and terminal in profane |
| M5 | Languages | tree-sitter (Clojure, Scala, Scheme, Lua, Swift, C/C++, JSON, Markdown, LLVM IR, MLIR), LSP + corfu + hierarchies, regex mode definer, formatters, HTTPS/SSE client for Scheme, inline diagnostics, inlay hints, indent guides, occurrence highlight |
| M6 | Agents I | ACP client (Claude Code etc.), profane as MCP server, agent diff review + permission prompts |
| M7 | Widget toolkit | `(profane widget)`: layout, standard widgets, buffer-backed text input, focus/keyboard nav, theming, accessibility; sidebar/dashboard/transients rebuilt on it; new mode line and tab bar |
| M8 | Modern UI polish | Overview scrollbar, sticky scroll, breadcrumbs, toasts + progress, unified titlebar tabs, mouse/trackpad affordances, `'rich` preset, optional palette/which-key/minimap/vibrancy |
| M9 | Agents II | Native agent loop, editor tools, MCP client, chat buffer, inline edit, checkpoints, Keychain API key, cost display |
| M10 | REPLs + notes | Clojure/Chez/Kawa REPLs, Markdown, Org-lite, variable-pitch + inline images |
| M11 | Web buffers + native views | WKWebView buffers, history/bookmarks, key interception + web-insert state, link hints, in-page search, JS bridge, navigation hooks, downloads, content blocking, reader view; Markdown/Org-lite preview; native AppKit view hosting (PDFKit, AVKit, QuickLook) |
| M12 | Git v2 | Log graph, rebase, blame, stash, conflicts; parallel agents in worktrees |
| M13 | Personal packages + release | Dashboard, IRC/Twitch (in-app OAuth + stream split), listing preview, notarized release, Sparkle, Homebrew cask |

Estimated: usable prototype (M4) ≈ 3 weeks of sessions; widgets ≈ +4–5 weeks; web buffers ≈ +3–4 weeks; modern UI polish ≈ +2–3 weeks; agents ≈ +5–7 weeks; M0–M13 ≈ 5–5.5 months with review.

## 10. Key risks

| Risk | Mitigation |
|---|---|
| Hardened runtime vs Chez runtime codegen | **Verified in M0**: Chez maps code with `MAP_JIT`; `com.apple.security.cs.allow-jit` alone suffices (main + worker threads). Without it codegen traps (SIGTRAP). `macos.signing` test guards it |
| Moving GC vs C pointers | Handles + ftypes only, `lock-object` for callbacks, GC stress builds |
| R6RS immutable exports vs live hacking | Symbol-keyed registries, interaction environment |
| Org files corrupted by partial support | Lossless round-trip tests over the owner's real notes |
| WKWebView focus/keys vs profane keymaps | Intercept in `ProfaneView` before WebKit; explicit web-insert state; tested on form-heavy sites |
| Public widget API freezing too early | Internal UI built on it first (M2/M7); API marked unstable until M13 |
| Animation hurting latency | Input always processed before animation ticks; animations dropped, not delayed, under load; latency benchmark in CI |
| UI clutter creeping in | Minimal preset is the default and the visual regression baseline |
| Prompt injection via web/files/MCP | Untrusted-content marking, approval for mutating/network tools, no auto-approve after untrusted reads |
| Agent edits clobbering user edits | Snapshots + marker-anchored edits, per-step undo groups, conflicts surfaced as hunks |
| API drift | Model IDs and request shape in one provider module |
| Pop-ups hidden behind web views | Overlay Metal layer above native views, reserved from M1 |
| Development container is Linux | Portable core/Scheme tests run locally; macOS CI runners for ObjC/Metal + golden images |

## 11. Repository layout

```
profane/
├── core/                 C17: text/ layout/ git/ treesit/ search/ embed/
├── platform/macos/       ObjC shell, WebHost (WKWebView), NativeViewHost, Shaders.metal, Info.plist, Profane.entitlements
├── subprojects/chez/
├── scheme/profane/       stdlib, ui/ (tokens, motion, modeline, tabs), themes/, canvas/, widget/, agent/ (acp, mcp, provider, tools), git/, complete/, org-lite/, lsp/, web/
├── packages/             dashboard, irc, listing
├── tools/profane-client/
├── packaging/
├── tests/                C, SRFI-64 (minimal in-repo shim), Metal golden images, org round-trip corpus, macOS app integration
├── cmake/                Chez.cmake (ExternalProject for subprojects/chez)
└── CMakeLists.txt
```
