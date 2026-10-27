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
| Git | libgit2 for reads (vendored submodule `subprojects/libgit2`, v1.9.7, built by `cmake/Libgit2.cmake` as a static library with HTTPS/SSH off; GPLv2 with linking exception), `git` CLI for all mutations and the network (§8l) |
| Async | Events posted from reader threads and timers to one main-thread queue; Scheme promises and `await` (a command parks its engine); engines for preemption/`C-g`; FSEvents and GCD queues join with the items that need them (§8k) |
| Terminal | libvterm (neovim's fork, MIT) vendored as a submodule at `subprojects/libvterm` (v0.3.3), built by `cmake/Libvterm.cmake` (needs perl to generate two tables); drawn as a window kind from a cell grid, not as buffer text (§8k) |
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
- **isearch** (dogfooding, `(profane isearch)`): `C-s` / `C-r` as Emacs's incremental search. While searching,
  `isearch-mode-map` has `C-s C-r` (next/previous; on an empty string the last string again from `search-ring`; after a
  failure, wrap), `DEL` (undo the last step: a character, a repeat, a yank), `RET` (stop; the mark goes where the search
  started unless the region was active), `C-g` (take back the failing part, else go back and stop), `C-w` (rest of the
  word at point), `C-y` (last kill). Any other key stops the search and then runs. Case folds unless the string has
  capitals (`case-fold-search`). The search reads the keyboard through a new command-loop seam,
  `set-input-override!` (a procedure from `'key`/`'text` and the input to a command, or #f for the keymaps): unlike a
  key reader it leaves typed text to the input method, so Russian text is searched as typed, and a mode's plain-key
  bindings (dired's `n`) do not take typed characters. Matching is naive over a copy of the buffer text, kept while the
  buffer's edit count holds. Highlights use the `highlight` text property (§8g): the match in `isearch`, other matches
  in `lazy-highlight`, at most `lazy-highlight-max` (1000), as far as a window's height either side of the match. If
  point moves while searching (a mouse click), the next key stops the search quietly and runs as usual.
  *Verified:* `isearch-test.ss` (59 checks: growing in place both ways, repeats, DEL, failing and wrapping, C-g,
  C-s C-s, other keys, C-w, a mode binding `n`, point moved outside, faces kept under highlights); `test_layout.c`
  (highlight drawn over faces and removed); in the app over the REPL with keys posted to it (`C-s`, typed `bet` and
  `дел` as text, `C-s`, `RET` leaving the mark, `C-e` stopping and moving). *Not looked at on screen* (the colors).

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
- The kill ring shares the macOS pasteboard through `(profane macos)` (M3, §8k item 3).

## 8g. Faces and text properties (M2)

- **Text properties** (`core/text/pf_props`): per property id, sorted non-overlapping runs of 32-bit values, merged
  when equal and adjacent, moved by edits and undo/redo like Emacs text properties (plain insert inherits nothing).
  Arrays for now (O(runs) per edit); a tree can replace them behind the API once highlighting is dense (M5). Undo
  restores text but not its properties; re-highlighting covers that.
- **`highlight`** (property 2, `PF_PROP_HIGHLIGHT`, dogfooding with isearch): a face drawn over the `face` property
  where set, so transient highlights (search matches) come and go without saving or restoring the faces underneath.
  It replaces the face id for those characters (no merging of attributes, as Emacs overlays would). Properties belong
  to the buffer, so every window showing it shows them. Its backgrounds are drawn above the hl-line band, the region
  and bracket highlights (isearch's overlay priority in Emacs); a face's stay below them. Found in dogfooding: the
  current match is on point's line, and the hl-line band hid its yellow.
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
- **`modus-operandi` / `modus-vivendi-tinted`** (`(profane themes)`): the published palettes of Protesilaos Stavrou's
  modus-themes, copied under their names, with the modus face assignments (no bold or italic syntax; syntax colors
  from the semantic mappings). Not the default: `(load-theme 'modus-operandi)`, or set `theme-for-appearance`. Not
  looked at on screen. Two published values miss profane's contrast bar and are kept as published: operandi's
  `border` (2.7:1 on white) and vivendi-tinted's paren-match background (4.3:1 under white); the test relaxes
  those two. Line numbers carry the modus backgrounds too (`bg-dim` / `bg-active` behind the gutter, drawn by the window renderer
  for any theme whose line-number faces set a background). Left out: the headings and prose roles (no faces yet).
- **Typography**: code in `default-font-family` (JetBrains Mono), `variable-pitch` in `system-ui` (SF Pro);
  the mode line and tab bar use the code font (owner's choice, dogfooding); per-face OpenType `features` (e.g. ligatures off); `line-spacing`; text scale (`C-x C-=`/`C--`/`C-0`,
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
  (`core/display/pf_strip`) in `mode-line` / `mode-line-inactive` (code font), flat or raised per
  `ui-mode-line-style`; not text-scaled. Default: label, modified, buffer name, All/Top/Bot/NN%, (line,col), modes.
- **Echo area**: the minibuffer window under the tree shows an undo-disabled echo buffer (`buffer-disable-undo`,
  which drops the history: it would no longer match the text). It grows to fit multi-line messages (up to
  `max-mini-window-height`) and the next input clears it; keystroke echo (`C-x-`) is shown but not logged. The
  minibuffer reads input in this window (below).
- **Window extras** (M2). *Scrolling:* `C-v`/`M-v` (also `<next>`/`<prior>`) scroll a screen less `next-screen-context-lines` (2), or ARG lines
  with a prefix; point keeps its screen row; with the end (start) visible point goes there first and the next press
  complains. `C-l` (`recenter-top-bottom`) puts point's line in the middle, then top, then bottom; a numeric argument is a
  row (negative: from the bottom). The mouse wheel shares `scroll-window-lines!`. *Buffer history:* every window keeps
  the buffers it showed (`window-prev-buffers`, most recent first, 30) and the ones `previous-buffer` came back from
  (`window-next-buffers`); a switch by any other means drops the forward list; with no history the commands fall back
  to cycling the global list. Killed buffers drop out. *Header line:* `header-line-format` (buffer-local, `#f` by default
  so the minimal preset shows none; the mode-line format language) in the `header-line` face, drawn by a second
  `pf_strip` at the top of the window; text, cursor, fringes, `pf_window_body_rect`, `pf_window_pos_rect/at` and canvas
  windows all start below it (`top_inset`), the minimum window height counts it, and a click on it only selects the
  window. *electric-pair-mode* (on at startup): `( [ { "` insert their partner and leave point between, typing the
  partner over itself skips it, a region is wrapped (kept inside), DEL between an empty pair deletes both, an opener
  is not paired before a word character and a quote not next to one; no syntax table yet, so a quote typed inside a
  string after a space pairs (M5), and RET between a pair does not open an extra line (no indentation yet).
- **Engines: `C-g` interrupts a runaway command** (after M2). Every command, with its post-command work, runs in a Chez engine
  with `command-slice-ticks` procedure calls (500000, a few ms) per slice. Nearly every command finishes in its first
  slice and nothing changes. One that does not is *suspended* and `pf-key` returns: `pf_input_busy` goes up and Scheme asks
  the shell (`pf_app_schedule_resume`, a main-queue block) for the next slice (`pf-resume`), so the event loop runs between
  slices; the view is redrawn every 50 ms meanwhile. While suspended, `C-g` aborts the command, drops the typeahead and
  says "Quit"; any other key or text waits in a queue and runs, in order, after the command ends; mouse events are
  ignored. Engines suspend with their `dynamic-wind` exits run (a `with-current-buffer` is undone while the command waits and
  re-entered on resume, with the buffer saved at suspension re-selected), so aborting is just dropping the engine. Commands
  run by commands (M-x, avy, transient actions) share the outer slice. Verified: `command-test.ss` (slicing, typeahead, abort,
  buffer state), `test_scheme.c` (the busy flag and `pf-resume`), and the running app (REPL answers in 2 ms while a command
  spins at 98% CPU; a real `C-g` from `post_keys` ends it). Latency is unchanged: key-to-commit p95 2.05 ms with one window
  (was 2.0) and 3.54 ms with four windows on a 100k-line buffer (was 3.9). A command running an expensive but finite
  computation now spans several slices, which is harmless.
- **File names** (`(profane files)`, M2). `expand-file-name` (`~`, relative names from a directory, `.`/`..`, repeated slashes, trailing
  slash kept), `abbreviate-file-name`, `file-name-directory`/`-nondirectory`, `directory-entries`, the buffer-local
  `default-directory` (else the visited file's directory, else `~/`), and `read-file-name`: `completing-read` over the
  entries of the directory typed so far (new minibuffer options `raw`, `display`, `files`), shown by name, names
  starting with the typed text first, then directories before files, then alphabetical. vertico-directory behaviour: RET
  on a directory goes into it, RET on a file or on a path nothing matches finishes, DEL right after `/` deletes the
  whole component, M-DEL a component (or a word in other prompts), TAB takes the first candidate if none is selected, `//`
  or `/~` in the input starts over at the root or home. With the input empty or ending in `/` nothing is selected, so RET
  finishes with that directory; C-n then selects the first entry. Commands: `find-file` (`C-x C-f`; a directory is
  now opens dired, M3 item 6a), `save-buffer` (`C-x C-s`; asks where when the buffer has no file), `write-file`
  (`C-x C-w`; `set-visited-file-name!`). *Not yet:* partial-component completion (`~/Re/pr`), file annotations
  (size, dates), `find-file-other-window`, `insert-file`, `save-some-buffers` and a prompt when killing a modified
  buffer, auto-save and backups, file watching, remote paths, and symlink-aware names (`truename`).
- **Mouse** (`(profane mouse)`, M2). `ProfaneView` sends mouse events to Scheme as strings in frame coordinates (`pf-mouse`:
  `down|drag|up X Y CLICKS`, `scroll X Y DX DY PRECISE`; the first click that focuses the window also acts) and asks C
  only for the cursor shape (`pf_frame_cursor_at`, from a tracking area: a canvas region's cursor, the I-beam over
  text, else the arrow). `pf_window_pos_at` maps a window point to a buffer position (the inverse of `pf_window_pos_rect`).
  Behaviour: a click on a canvas region runs its handler (`canvas-click!`); a click in a text window selects it and
  moves point (deactivating the region); a drag selects from where the button went down (the active region) and
  scrolls a line per event above or below the window; double and triple click select the word and the line; dragging a
  mode line or the divider next to a neighbor resizes (`resize-window!`); the wheel or trackpad scrolls the window
  under the pointer, keeping fractions of a line, and moves point to the nearest visible line when it would leave the
  screen (as Emacs does); sideways scrolling sets the horizontal scroll. *Not yet:* the tab bar (clicks, drag to
  reorder), dragging text, middle-click paste, right-click menus, smooth/momentum scrolling (M4), a text cursor in the
  echo area only while the minibuffer is active, and double-click-drag extending by words. The NSEvent-to-string
  path in `ProfaneView` is untested by scripts (the Scheme side is covered by `mouse-test.ss` and by driving `pf-mouse`
  in the running app).
- **avy** (`(profane avy)`, M2). `avy-goto-word-1` (the owner's `C-x C-j`), `avy-goto-char`, `avy-goto-line`. The command
  reads a character, collects the matching positions in the visible text of every window of the frame (ordered by
  distance from point, the selected window first) and shows a label over each: a full-frame canvas pop-up on the overlay
  layer (`red` rounded tag, text in the `bg` color), made of the keys in `avy-keys` (`a s d f g h j k l`; same-length
  labels, longer when there are more candidates than keys). Typing a label jumps (selecting that window, mark left
  behind); a key that is no label, `C-g` or `ESC` cancels; one candidate is jumped to at once. New pieces: the command
  loop's `set-key-reader!` (the next key or typed character goes to a procedure; while set the shell sends plain keys as
  keys, so labels work under a non-Latin layout), `pf_window_pos_rect` (a character's cell on screen, from the last
  layout, -1 when not visible) with `window-pos-rect` and `window-visible-range` in Scheme. *Not yet:* avy's other
  commands and actions (`avy-goto-char-2`, `avy-goto-char-timer`, copy/kill/move actions), labels decorated for
  wrapped lines (there is no wrapping yet), and dimming the buffer behind the labels.
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
  output go to the echo area and *Messages*, an error shows its message. `load-file` (M3 item 4) reads a file name and
  evaluates the file. *Deferred:* `C-u C-x C-e`
  inserting the value, `eval-print-last-sexp`, `eval-defun` (`C-M-x`, needs defun motion), a REPL buffer (comint-style,
  with history and completion: with the REPL modes in M10). A looping evaluation can be interrupted with `C-g` (engines, above).
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
  (`M-g t` neotree and `C-x C-b` / `C-x 4 C-x C-b` buffer menu arrived with M3 item 6b; vertico's directory keys and electric-pair arrived earlier.)
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
  `completion-preselect 'nearest` (the `preselect` option is the seam).
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

**M2 items still open** (§9, M2 row): none that was planned; the rest is deferred below. The owner's port (`scheme/init.ss`) still lacks
`M-g i` (imenu), which needs modes and tree-sitter (M5); `M-g s` (ripgrep and find) arrived with M3 item 4;
(`M-g t` and the buffer menu keys arrived with M3 item 6b.)

**Deferred, by area:**

- Interruption covers commands (and their post-command hooks) only. Not yet sliced: socket REPL evaluations (a looping
  `profane-client --eval` still hangs the editor; kill the client), `pre-redisplay-hook` and other hooks run outside a
  command, timers and callbacks from C. Nothing can interrupt a single long foreign call. Aborting drops a suspended
  command without running its cleanup other than the `dynamic-wind` exits already run at suspension; user `guard`s cannot
  catch the abort.
- Evaluating: `eval-defun`/`C-M-x` (defun motion, M5), `C-u C-x C-e`
  inserting the value, a REPL buffer with history and completion (M10).
- Region: `delete-selection-mode`, `shift-select-mode`, a mark ring, `C-SPC C-SPC`, showing it in non-selected windows.
- isearch: regexp search (`C-M-s`, `C-u C-s`; there is no regex engine yet), `M-e` editing the string, `M-c` case
  toggle, `M-n`/`M-p` through the search ring, `query-replace`, the failing part shown in `isearch-fail` in the echo
  area (the face exists), lazy-count, isearch in the minibuffer (refused), stopping on a mouse click (it stops at the
  next key), "Overwrapped". Highlights replace faces instead of merging with them, and show in every window on the
  buffer (no overlays yet).
- Press-and-hold: held keys repeat; `press-and-hold-keys` re-enables the accent picker per key. The per-key switch
  assumes macOS re-reads the default on each key down, which is unverified.
- Canvas: paths and bezier curves, images, clip and transform (ops are not clipped to a canvas window), inline
  canvases (they need display-engine support for reserved space in a line), key and focus events.
- Native views: only the stub kind; web (M11) and PDF kinds, key/mouse routing into views, focus handoff.
- Mouse: the tab bar, dragging text, middle-click, right-click menus, momentum scrolling (see the Mouse entry in §8i).
- Windows: `scroll-other-window`, `C-M-l`, window-start/point saved per history entry; electric-pair rules need a
  syntax table (M5); RET between a pair does not open an extra line (needs indentation).
- Completion: `completion-preselect 'nearest` (the `preselect` option is the seam), corfu (popup completion).
- Undo restores text but not its text properties (fine once highlighting re-runs); undo history is unbounded.
- Text properties use arrays (O(runs) per edit); switch to a tree when tree-sitter makes runs dense (M5).
- show-paren counts brackets without syntax (strings and comments count) until M5.
- The kill ring shares the macOS pasteboard through `(profane macos)` (M3, §8k item 3).
- Lines are truncated unless `visual-line-mode` or `truncate-lines` #f (soft wrap, §8l); truncated windows scroll
  sideways to keep point visible. At most 4096 characters per line are shaped.
- No CI. `tests/macos/latency.sh` is the CI latency benchmark the plan asks for, once there is macOS CI.
- Unexplained latency outlier: single ≈900 ms commit samples appeared in 100k-line benchmark runs while the owner
  was using the machine, and not when it was idle (five clean runs, max < 6 ms). Hypothesis (unconfirmed): the
  window lost the front or was covered mid-run, which macOS throttles. Watch the `max` column.

**Owner checks done:** live macOS dark-mode toggle (2026-10-24: Dark at launch, then Light, then Dark; theme and face colors
followed, checked from Scheme state, not pixels). The CJK input-method check is dropped: the owner does not use those
languages.

## 8k. Async and tools (M3)

**Item 1: async foundation** (`core/async/pf_async.*`, `(profane async)`). Decisions:

- **A completion queue, not a worker pool.** Any thread calls `pf_async_post(token, kind, bytes)`; the main thread pops
  events and Scheme calls the handler registered for the token (`async-token-new`). The queue is in the portable core
  (pthreads), so Scheme tests run it without the shell; the shell only sets a wake hook (`pf_async_set_wake`) that
  dispatches `pf-async` on the main queue. Wakes are coalesced until the drain acknowledges, and a drain handles at most
  `async-dispatch-limit` (64) events before asking for another wake, so a flood cannot starve input or redisplay. The plan's
  "GCD queues" stay a platform choice for later items: processes, FSEvents and search post to this queue from their own
  dispatch sources or threads. A general worker pool is a seam: nothing needs it until git/search (add it then).
- **The queue is unbounded.** Producers that can outrun the editor (a process reader) must stop reading while their events
  are unpopped; that is the process layer's job (item 2).
- **Promises and `await`** replace the plan's "one-shot continuations". Capturing a continuation inside an engine and
  resuming it later fights the command loop's engines, so `await` inside a command *parks the engine*
  (`command-wait!`, via `engine-block`): the slice ends with no resume scheduled, the command stays "busy" (C-g aborts
  it, other input queues), and settling the promise (`command-wake!`) schedules the resume. Outside a command (REPL,
  tests) `await` pumps events and blocks the main thread. Handlers and promise callbacks are not sliced, like hooks.
- **Timers**: `async-after`, `async-cancel!`, `async-sleep` (a promise). Each timer is a detached thread sleeping until it
  fires, which is fine for a few; a timer heap belongs with the first user that needs many (run-with-timer, M4 motion).
- **Verified**: `c.async` (order, wake coalescing, timer thread, four producers x 1000 events), `async-test.ss`
  (dispatch, released tokens, raising handlers, batching, promises, parked `await` with typeahead, C-g abort), and the
  running app headless: a timer's event arrived through the wake hook (no polling) and a command parked in `await` resumed
  on its own. Not verified: behavior under ASan/TSan (not run), a flood against a real window.

**Item 2: processes and PTY** (`core/process/pf_process.*`, `(profane process)`). Decisions:

- **One reader thread per process, no kqueue.** The thread owns the descriptors: it `poll`s stdout/stderr, writes the
  queued stdin, notices the exit and reaps, then posts the exit event, always last. Plain POSIX, so the C test runs
  anywhere (kqueue/dispatch sources were the plan's idea; threads are simpler and a few dozen processes cost nothing).
  Output reaches Scheme as `pf_async` events (§8k item 1): stdout, stderr, exit (code or signal).
- **Backpressure**: the reader stops reading while 256 KiB of output are unacknowledged (`pf_proc_consumed`, sent by Scheme
  after each filter call), so a chatty child blocks in `write()` instead of filling the unbounded queue. Writes to the child
  are queued and flushed by the reader (never block the editor).
- **Exit does not wait for EOF**: a grandchild holding the pipe open (`sleep 3 &`) does not delay the exit event; what is
  already in the pipe is drained first. The child is reaped with `waitid(WNOWAIT)` then `waitpid` under the process lock, so
  a signal can never reach a reaped (reusable) pid.
- **Spawn** is `fork` + `execvp` with an error pipe (a missing program or directory is an error at `start-process`, not
  an exit). Pipes: own process group; pty: `posix_openpt`, new session, `TIOCSCTTY`; the window size is set from the *slave*
  in the child (macOS drops a size set on the master before the slave opens). Descriptors above 2 are closed in the child,
  signals unblocked and SIGPIPE restored; the editor ignores SIGPIPE (a write to a gone child is an error).
  `env` options replace or add entries of the inherited environment; a pty gets `TERM=xterm-256color` unless given.
- **Cleanup**: `atexit` hangs up (SIGHUP + SIGCONT to the group) every live child. Verified: a `sleep` child died on quit.
- **Scheme API**: `start-process name argv [options]` with filter / stderr-filter / sentinel / buffer; incremental UTF-8
  (a character split across reads is whole); default output goes to the buffer end, point follows only if it was there.
  `process-promise`, `run-process` (promise of `(code stdout stderr)`), `signal-process`, `process-send-string`/`-eof`,
  `process-resize!`. No process-mark, no process-level coding systems (UTF-8 only), no per-process plist: add with a user.
- **Known limits**: aborting an `await` with `C-g` leaves its process running (engines drop without unwinding, §8i); the
  caller keeps the process and can kill it. Filters and sentinels are not sliced (hooks rule).
- **Verified**: `c.process` (streams, exit codes, merged stderr, cwd/env, exec errors, stdin/EOF, 3 MB out and 2 MB in,
  SIGTERM, grandchild pipe, pty size/echo; also clean under ASan and TSan), `process-test.ss` (34 checks, incl. a 5 MB flood
  delivered whole and `await` parking a command), and the running app (a `run-process` result through the wake hook). Not
  verified: many simultaneous processes, interactive programs on the pty beyond `stty`/`read`.

**Item 3: `(profane macos)` and the pasteboard** (`platform/macos/PFMacOS.*`, `scheme/profane/macos.sls`). Decisions:

- **Kill ring and pasteboard** behave as Emacs with `select-enable-clipboard` (a variable, default on): a kill (and each
  appended kill) is written to the pasteboard; a yank, and reading `kill-ring`, first take in what another app copied since,
  once, decided by the pasteboard's change count (our own writes are recorded so they are not read back; an empty or
  identical string is ignored). The pasteboard sits behind a swappable backend (`set-pasteboard-backend!`), so the Scheme
  suite tests the logic with a fake and without the shell. `$PROFANE_PASTEBOARD` names a private pasteboard: the app test
  never touches the owner's clipboard. Only plain strings are exchanged (no rich text, images or file lists yet).
- **Text-returning foreign calls keep their result** (a "stash") that Scheme copies out with `pf_app_stash_copy`, so it can
  size its buffer without running a script twice. All of these are main-thread only.
- `open-url` / `open-file` use `NSWorkspace openURL:configuration:`; `activate?` #f keeps the app in the background.
- `run-applescript` runs `NSAppleScript` in process and **blocks the editor** until it ends (scripts to busy apps can hang
  it: use `with timeout`); errors raise with the script's message. Needs the `com.apple.security.automation.apple-events`
  entitlement and `NSAppleEventsUsageDescription` (both added; the first script to control another app asks the user, which
  was not exercised: the tests only run scripts that touch no app).
- `app-window-bounds` (by app name or pid) reads `CGWindowListCopyWindowInfo`: needs no permission, gives no titles
  (those need Screen Recording). Setting another app's windows is not offered (the Twitch layout moves to a web buffer, §2).
- **Verified**: `macos-test.ss` (23 checks, fake pasteboard: write, outside copy once, duplicates, empty, appends,
  switch off, `C-y`), `macos.sh` (real pasteboard on a private board with non-ASCII text, kill ring round trip, AppleScript
  result and error, bounds), and by hand: bounds for Finder and Safari by name and Finder by pid. **Not verified**:
  actually opening a URL or file (it would launch an app and take focus; only the refusal of non-URLs is tested) and the
  automation permission prompt.

**Item 4: ripgrep and find** (`scheme/profane/search.sls`; `executable-find` in `(profane process)`; `minibuffer-update!`).
Decisions:

- **Tools**: `rg` is required (a clear error if missing; no grep fallback); `consult-find` uses `fd` when installed, else the
  system `find` (`search-use-fd`). This differs from the owner's Emacs, where `consult-find` runs plain `find` and lists
  ignored and hidden files; fd skips what `.gitignore` skips and hidden files. The owner chose this (2026-10-24). Arguments
  are variables (`ripgrep-args` = consult's defaults plus `--column`, `fd-args`).
- **Programs are found in `exec-path`**, PATH plus `/opt/homebrew/bin` and `/usr/local/bin`: an app started from the Dock
  has a minimal PATH. Importing the login-shell PATH is a seam.
- **Live results**: the collection is a `raw` procedure over a source object. Each change of the query kills the running
  process and starts a new one after `search-debounce-ms` (150), not below `search-min-input` (3) characters; output
  lines are collected and the minibuffer is refreshed at most every 30 ms through the new `minibuffer-update!` (recompute
  candidates, keep the selected row). At most `search-max-results` (5000) are kept, then the process is stopped. Input is
  `query` or `#query#filter` (consult's split): the filter narrows locally, orderless, without searching again.
- **ripgrep**: results are `file:line:text` (`--null` separates the path, so a `:` in a name is safe; rg gets a `.` path
  and stdin closed, as it reads stdin when it is not a terminal). The preview shows the match in the window; `C-g` puts
  the window and its point back and kills the buffers opened for previews; `RET` leaves the mark at the old point and goes to
  the match (the rg column is in bytes: converted to characters). An rg failure (a bad regex) shows as one candidate.
- **Directory**: the project root (nearest `.git`, else the buffer's directory); a prefix argument asks for one.
- `M-g s` is the owner's transient (`r` ripgrep, `f` find), in `scheme/init.ss`. `load-file` (was waiting for file-name
  reading) evaluates a file chosen in the minibuffer.
- **Seams / not done**: find on a directory says dired is not there yet (item 6); no grouping of ripgrep results by file
  and no `consult-grep`/`git-grep`; no highlighting of the match in the preview; results are in arrival order (rg and fd
  are parallel), not sorted.
- **Verified**: `search-test.ss` (40 checks on a throwaway repo: results, non-ASCII names and text, `.gitignore`, `#filter`,
  RET position and mark, byte-to-character column, `C-g` restore, bad regex, debounce, fd and the find fallback, no process
  left behind), `eval-test.ss` (`load-file`), and the running app (a real window, the wake path: results, preview of a
  file, `C-g` back to `*scratch*`, `consult-find` opening a file). Not verified: a very large tree (the 5000 cap and the
  stop of a flooding process were not exercised), and the visual look of the candidates.

**Item 5: Keychain, `(profane secrets)`** (`PFMacOS.m`, `scheme/profane/secrets.sls`). Decisions:

- `secret-get` / `secret-set!` / `secret-delete!` on **generic passwords of the login keychain**, by service and account
  (strings; UTF-8 text only, no binary secrets yet). `secret-set!` adds or updates. A missing item is `#f`; any other
  failure raises with the system's message (`SecCopyErrorMessageString`). Nothing is cached or written by profane.
  Without the shell there is no keychain; `set-secrets-backend!` installs a fake (as `set-pasteboard-backend!`), which
  is how the tests of later users (git credentials, the agent's API key) will run.
- Uses the legacy file keychain (no data-protection keychain, so no keychain-access-groups entitlement is needed).
  **Caveat, not exercised**: items are tied to the creating app's signature; an ad-hoc build changes with every rebuild, so
  macOS may ask the user to allow access to items made by an earlier build. A stable signing identity
  (`PROFANE_CODESIGN_IDENTITY`) avoids it. In the checks below the same build wrote and read, so no prompt appeared.
- Not done: prompting for a secret in the minibuffer without echo (no password input yet), internet passwords, git
  credential helper (M4, "Keychain credentials"), the agent's API key UI (M9).
- **Verified**: `secrets-test.ss` (the API over a fake backend, the no-backend errors) and `macos.sh` against the real login
  keychain with a throwaway service deleted afterwards (missing, set with non-ASCII text, replace, wrong account, delete
  twice); the keychain held no leftovers afterwards.

**Item 6a: dired** (`core/fs/pf_fs.*`, `(profane fs)`, `(profane dired)`; read-only buffers in `(profane buffer)`). Decisions:

- **Buffers, not native views** (owner's choice, 2026-10-24): dired is a read-only text buffer in `dired-mode`; the sidebar
  (item 6b) will be a tree buffer in a side window; M7 rebuilds the sidebar on the widget toolkit. Two items (6a dired, 6b
  sidebar and buffer menu), one commit each.
- **File details come from a `stat` call in the C core** (`pf_fs_stat`, `readlink`, owner/group names, `copy`, `rename`,
  `mkdir`, `remove`; all return `-errno`), not from `ls`: profane formats its own columns and groups directories first
  (`dired-group-directories-first`, the thing macOS `ls` cannot do). Copies go through a temporary file renamed into place, keep
  permissions and mtime, and copy a link as a link. `(profane fs)` wraps them with real error messages and adds recursive
  copy/delete and a move that falls back to copy+delete across volumes (`EXDEV`; errno numbers are Darwin's).
- **Read-only buffers** (new): `buffer-read-only?`, `set-buffer-read-only!`, `with-inhibit-read-only`. Insert, delete and undo
  raise "buffer is read-only"; the mode line shows `%%` (or `%*` when modified). Dired edits its own text inside
  `with-inhibit-read-only`.
- **A mode can bind a plain character** (command-loop change): typed text of one character that an active keymap binds to a
  command runs the command instead of inserting. Before this only chords and named keys reached keymaps. It is what makes dired's
  `n`, `m`, `d` work. Consequence: plain keys follow the active layout (as typed text), so dired's letters do not work under a
  Russian layout (chords still do); Emacs has the same limit without a reverse input method.
- **The listing**: header line, then `* perms owner group size date name[ -> target]`, with `.` and `..`; mark column `*`
  or `D`; faces `dired-header`, `dired-directory`, `dired-symlink`, `dired-mark`, `dired-marked`, `dired-flagged` (themed).
  Entry data is kept in a buffer-local vector, so a line maps to its entry by index and nothing is parsed back from text.
  `g` rebuilds keeping marks (by name) and point's file; one dired buffer per directory (`dired` reuses it); `default-directory`
  follows, so `C-x C-f` starts there.
- **Commands**: `RET`/`f`, `o` (other window, splitting if needed), `^`, `n`/`p`/`SPC`, `m u U t d`, `x`, `D`, `R`, `C`,
  `+`, `g`, `s` (name, time, size), `w`, `W` (full path; the owner's `arx/dired-copy-full-filename-as-kill`; the directory on
  the header line), `q` (switch away, buffer stays), `C-x d`. `D`, `x`, an overwrite and any directory delete ask for `yes`;
  `R` and `C` read the destination with file-name completion (many files need a directory; into a directory keeps names).
  `find-file` on a directory and the search commands call `visit-directory`, which `(profane dired)` installs (the
  `files` library cannot import it). `delete-by-moving-to-trash` (default off, as Emacs) sends files to the Trash through
  `move-to-trash` in `(profane macos)`.
- **Not done**: `*` mark commands (by regexp or extension), `%` commands, `!` shell command on files, chmod/chown, subdirectory
  insertion (`i`), `dired-hide-details`, wdired, find-dired, `C-x C-j` dired-jump (the owner's key is avy), copying
  into another visible dired window by default, symbolic-link creation (`S`), an undo of operations.
- **Verified**: `c.fs` (stat/readlink/owner/copy/rename/mkdir/remove, a 2.5 MB copy, errors), `fs-test.ss`, `buffer-test.ss`
  (read-only), `command-test.ss` (a bound plain character; fails on the old code, checked), `dired-test.ss` (68 checks on a
  throwaway tree: order, motion, marks, open/up, find-file and `C-x d`, names, sorts, mkdir, copy/rename incl. overwrite
  prompts and into a directory, delete, flags, links, refresh, quit) and the running app (real key events `n n m RET`
  through `post_keys`). **Not verified**: the look of the listing and its faces on screen, `move-to-trash` (it would put a file in
  the owner's Trash), `o` in a real window, large directories (10k+ entries), non-UTF-8 file names.

**Item 6b: sidebar and buffer menu** (`(profane sidebar)`, `(profane buffer-menu)`; side and dedicated windows in
`(profane window)`). Decisions:

- **Sidebar = neotree** (`M-g t`, `sidebar-toggle`), a tree buffer in a **dedicated side window** on the left, 30 columns
  (`sidebar-width`). The root is the project root (nearest `.git`, else the buffer's directory); dotfiles and files git
  ignores are hidden (`sidebar-show-hidden`, `H`). Ignored files come from one `git ls-files --others --ignored
  --exclude-standard --directory -z` per open/refresh (so there is no `.gitignore` parser to get wrong; no git or no
  repository means only dotfiles are hidden). The command waits for git with `await`, so the editor stays alive. Keys: `RET`
  (file: open in the main window; directory: expand), `TAB`, `n`/`p`, `g`, `H`, `U` (parent as root), `C` (directory as
  root), `d` (dired there), `q`. Expanded directories are remembered per buffer, also across root changes. Not done:
  create/rename/delete in the tree, icons (the owner's `neo-theme 'nerd`; plain triangles for now, the widget toolkit (M7)
  rebuilds the sidebar), reveal-current-file, maximize, a mouse.
- **Window additions** (`(profane window)`): `add-side-window` (a full-height window along the left or right edge, whatever the
  layout), `window-dedicated?`/`set-window-dedicated!` (switch-to-buffer in a dedicated window selects another window and
  shows the buffer there), `display-buffer-in-other-window` (the most recently used other window, splitting if alone; dired's
  `o` now uses it) and the per-buffer `display-line-numbers` (the sidebar and the buffer list turn them off; a window reads
  it when it gets the buffer, which is why the sidebar buffer is prepared before its window exists).
- **Buffer menu**: `buffer-menu` in this window and `list-buffers` in another window, without selecting it. `C-x C-b` is
  `list-buffers` by default (as Emacs) and the owner's `init.ss` makes it `buffer-menu` and binds `C-x 4 C-x C-b` to
  `list-buffers`. Columns: mark, `.` the buffer we came from, `%` read-only, `*` modified, name, size (characters), mode, file.
  Keys: `RET f o`, `d k` (flag to kill), `s` (flag to save), `u`, `x`, `g`, `n p`, `q`. Killing a modified buffer asks first
  (`yes`). Not done: `m`/`%`-marks, sorting columns, `~`, `t` (toggle read-only), file-visiting filter.
- **Verified**: `window-test.ss` (side windows' geometry, left and right, with a split main window; dedicated; the other
  window; per-buffer line numbers), `sidebar-test.ss` (39 checks on a throwaway git repository: ignored and hidden files,
  expand/collapse, open in the main window, `H`, `g`, `C`/`U`, dired from the tree, hide/show, the key path where the
  command parks while git runs, no git), `buffer-menu-test.ss` (28 checks) and the running app (a real window: `M-g t`, `n
  RET`, `g`, `q` and `C-x C-b` through real key events; the tree was 252 points wide at 1x). **Not verified**: how any of it
  looks (the glyph `▸▾` in the code font, faces), the sidebar with several tabs (it lives in the current tab's layout),
  resizing it with the mouse, very large trees, git submodules.

**Item 7: vterm and shell-here** (`core/term/pf_term.*`, `pf_window_set_terminal`, `(profane vterm)`; libvterm submodule).
Decisions:

- **A terminal window kind, not buffer text and not a canvas.** The libvterm screen and a scrollback ring live in the C core
  (`pf_term`); a window with a terminal attached (`pf_window_set_terminal`, like a canvas window) draws the cell grid straight
  into display items: background runs, the cursor, one glyph per cell in the regular/bold/italic/bold-italic face's font
  (each cell is shaped alone through the layout cache, so wide and fallback glyphs never shift a neighbor), underline and
  strike rects. No renderer change was needed. Reasons: truecolor TUIs would need thousands of registered faces as text
  properties, and every screen update would go through the piece tree and the layout cache; canvases are an authoring API
  with retained ops and hit regions. The scrollback (default 5000 lines, compact 16-byte cells, trailing blanks dropped,
  none from the alternate screen) is in C; `S-<prior>`/`S-<next>` scroll it.
- **Copy mode** (`C-c C-t`) puts history and screen into the buffer as plain read-only text, so search, region and `M-w` work as
  anywhere, and returns to the live grid on the next `C-c C-t`. This is where the buffer approach's text operations come from.
- **Keyboard takeover** (two new buffer-local variables in the command loop, usable by any mode): `key-filter` (a procedure
  from the first key of a sequence to a command, or #f for the keymaps) and `text-input-command` (what unbound typed text
  runs); `last-input-key` tells the command which key. vterm sends every key to the program except
  `vterm-keymap-exceptions` (`C-c C-x C-g M-x M-o M-g C-y M-y M-:`; the owner's `M-o` and `M-g` prefix included; Emacs's vterm also keeps `C-u`, but in a shell it kills the line, so it goes to the program here, found by using it);
  typed text, input-method text included, goes to the program as UTF-8. Under `C-c`: `C-c C-c/C-d/C-z/C-g/C-l` send that
  control key; `C-q` sends the next key as it is. `C-y`/`M-y` paste (bracketed when the program asked).
- **Processes feed it raw bytes**: `start-process` gained `(binary . #t)` (filters get bytevectors, no decoding), so
  libvterm's own UTF-8 parser sees split characters. What the terminal says back (key encodings, answers to queries such as
  device attributes) is written to the program's pty after every feed and key.
- **Size**: before every redisplay (`pre-redisplay-hook`) each window shows its session's terminal (or text, in copy mode) and
  the terminal takes the size of the selected window showing it (else the first), telling the program (`TIOCSWINSZ`).
  Buffers killed behind a live terminal are cleaned up there too (the program is killed, the terminal freed).
- **Colors** come from the theme: `term-black` ... `term-bright-white` palette roles (added to both built-in themes; the six
  hues reuse the theme's own) plus `fg`/`bg`; they are pushed when a terminal is made and on every theme load.
- **Shell**: `explicit-shell-file-name` (default `$SHELL`, else `/bin/zsh`); the owner's `init.ss` sets it to
  `/opt/homebrew/bin/fish` (their Emacs sets it to zsh for comint and `vterm-shell` to fish; profane has one variable for
  both, as agreed). The program gets `TERM=xterm-256color`, `COLORTERM=truecolor`, `INSIDE_PROFANE=1`, runs in the buffer's
  `default-directory`. `vterm` (`*vterm*`, reused; a prefix argument opens another) and `shell-here` (`*shell*<dir/>`, one per
  directory, reused) switch to the terminal in the selected window (Emacs's `shell` also uses the same window, whatever its
  docstring says about a new one). When the program exits the buffer is killed (`vterm-kill-buffer-on-exit`; off: the exit
  is shown in the terminal).
- **Also fixed (affects earlier items)**: the macOS shell now redisplays after every async dispatch. Before, events from
  processes and timers (search results, `consult-ripgrep`'s live list) changed state but were drawn only at the next key.
- **Not done**: mouse (reporting to the program, selection, wheel scrolling, clicking links), focus events, the cursor blinking
  (`blink` is reported but ignored), reflow on resize (the program repaints on SIGWINCH), bold-as-bright, DEC double-width
  lines, sixel/images, OSC 52 clipboard, shell integration (directory tracking from the prompt), `vterm-send-next-key`
  echoing, a title in the mode line (kept, `vterm-title`), a cursor row when the window is scrolled sideways.
- **Verified**: `c.term` (output parsing, colors, 256/truecolor, reverse, wide characters, scrollback and the view, resize,
  text dump, every kind of key encoding incl. application cursor mode, device-attribute answer, bracketed paste, title, bell,
  mouse mode, alternate screen without history; clean under ASan/UBSan), `test_layout` (the terminal window's display list:
  positions, colors, background runs, box/hollow/none cursor, redisplay only on change), `command-test` (the keyboard
  takeover), `process-test` (binary output), `vterm-test.ss` (44 checks with real pty programs: a prompt, keys and text incl.
  non-ASCII, the excepted keys, yank, resizing with the window, copy mode, exit handling, killing the buffer kills the program,
  reuse and prefix argument, `shell-here` per directory, a 200-line history and scrolling) and the running app: real fish
  started by `M-x vterm`, its prompt (with the git branch) drawn into the terminal, `echo $fish_pid` typed with real key events.
  *Not verified when written* (see "On-screen check of M3" below for what was looked at afterwards): the Russian layout (plain
  keys go as typed text, so letters follow the layout) and fish's own key bindings beyond the shown prompt.

**Item 8: TLS sockets** (`platform/macos/PFNet.*`, `(profane net)`). Decisions:

- **Network.framework** (`nw_connection`), not raw sockets and SecureTransport: system trust, host-name checking, proxies,
  Happy Eyeballs and the TLS stack come with it. It is platform code (Objective-C in the app, like the pasteboard); the core
  stays portable. Client connections only: no listening sockets, no UDP/QUIC, no client certificates (add with a user).
- **Same event model as processes**: connecting is asynchronous and everything is posted to the async queue for the
  connection's token: open (the negotiated ALPN protocol), data, closed, error (the system's message and domain/code). The
  shell stops receiving while 256 KiB of data are unacknowledged (`pf_net_consumed`, sent after each filter call). A
  connection in the "waiting" state (no route, refused) is reported as an error instead of waiting for the network to return;
  the connection timeout is 20 s.
- **Scheme**: `open-network-stream host port [options]` returns a connection at once; `(await (connection-ready c))` waits for
  it (resolved with the connection, rejected with the system's message). Options: `tls` (verified against the system's trust and
  the host name), `insecure` (with tls: accept any certificate, for tests and self-signed servers; deliberately explicit),
  `alpn` (offered protocols; `connection-protocol` tells the chosen one), `filter` (bytevectors, never decoded) and `sentinel`
  (`"open\n"`, `"closed\n"`, `"failed: ...\n"`). `connection-send` (bytes or a string), `connection-close`, `connection-status`.
  The HTTPS/SSE client of M5 is built on this.
- **Verified**: `tests/macos/net.sh` against local servers, no outside network: `nc` for plain TCP (greeting, data both ways,
  closing, sentinel order, a 3 MB transfer through the pause/resume path), a refused port (message), bad arguments, the system
  `openssl s_server` with a self-signed certificate (verification fails with a message; `insecure` connects, negotiates ALPN `h2`
  when offered and none otherwise, and carries an HTTP request). By hand against the real internet: `example.com` over
  verified TLS (ALPN `http/1.1`, a real `200 OK` response) and `expired.badssl.com` (fails: "chain had an expired cert").
  **Not verified**: proxies, IPv6-only hosts, connections surviving sleep/network changes, TLS 1.3 session resumption, a
  `PF_NET_MAX_OUTSTANDING` stall under a slow consumer (the large transfer passed but its pause was not observed), and
  closing while a send is in flight.

**On-screen check of M3** (the owner asked for pixels and the terminal in practice; real window, captured by window id, window
brought to the front first). Looked at: dired, the sidebar beside a file, the buffer menu, and the terminal running fish,
`ls --color`, htop, vim (syntax colors, arrows, `C-f`, insert mode, `:q!`), a truecolor/256-color/attribute/wide-character/emoji
demo in the light and dark themes, box-drawing tables, scrollback, a split with dired, and the real window resized (htop
re-laid out: 38 x 154 cells). All of it drew correctly: cell alignment, colors, bold/italic/underline/strike/reverse, CJK and
emoji widths (emoji in color), the cursor (block, hollow in other windows), the alternate screen, the theme following light/dark.
Found and fixed:

- **`C-u` was an editor key in terminals** (as Emacs's vterm has it) and never reached fish, where it kills the line; removed
  from `vterm-keymap-exceptions`.
- **Buffer menu header** was not aligned with its columns.
- **Box-drawing and block characters left gaps** between cells and rows (the font's glyphs do not fill the cell). They are now
  drawn as rectangles that fill it (`core/display/pf_boxdraw.*`: all of U+2500-257F but the diagonals, light/heavy/double
  strokes generated from the Unicode names; U+2580-259F halves, eighths, quadrants, shades by alpha). Tables, lazygit-style
  UIs and bars now join.
- Dark theme: terminal color 0 (black) was nearly invisible on the dark background; lightened.

Measured: key to echo in the terminal 0-1 ms (key event, pty, fish, back to the grid); the editor's own key-to-frame latency
with typing into a terminal p95 0.8 ms submit, 0.9 ms commit (the 20 ms "present" is the display's refresh and compositing).
Flooding the terminal keeps the main thread responsive (REPL round trip median 8 ms, max 10 ms during a 400,000-line flood) but
throughput is about 30,000 lines/s (1,000,000 lines of `seq`: 32 s): libvterm moves its whole screen buffer for every scrolled
line (a 31 x 114 screen is about 150 KB per line). Fine for logs and builds, slow for `yes`; a ring-buffer screen would fix it
if it ever matters.

Still seen on screen and **not fixed** (decisions for the owner): the sidebar tree touches the window's left edge (no
padding), buffers named `*vterm*` show the editor's `All (1,0)` position in the mode line (the terminal's title is kept but
unused), SGR "dim" is not drawn dimmed (libvterm does not report it), a ZWJ emoji family is drawn as three emoji, powerline
glyphs need a patched font, and there is no mouse in terminals (no wheel scrolling, no selection). Not looked at: Russian layout,
a Retina display (the machine is 1x), vim's mouse, fish's completions menu, less, a flood of long lines.

**M3 is complete** (plan §9, M3 row): processes/PTY (item 2), ripgrep/find (4), dired and the sidebar (6), vterm and shell-here
(7), Keychain (5), `(profane macos)` (3) and TLS sockets (8), on the async foundation (1). One thing the row did not name
but the work needed: read-only buffers and the keyboard-takeover hooks of the command loop. Left for later on purpose: the
terminal's mouse and focus handling, listening sockets, a process-level coding system, worker pool and timer heap (no user yet).

## 8l. Editing surface and motion (M4)

M4 items, one branch each (`m4-<topic>`): 1 soft wrap, 2 fringe git marks, 3 motion system, 4 Git v1 (status, stage,
diff, commit, push/pull), 5 ediff. Items 1 to 5 are done (item 3's fold/unfold waits for a folding feature; item 4's askpass and item 5's three-way merge are seams).

**1. Soft wrap** (`m4-soft-wrap`).
- `pf_window` has a wrap option (`PF_WINDOW_WRAP`: truncate, break at the last character that fits, break after
  whitespace). A buffer line is laid out once (the layout cache is unchanged) and split into screen rows by caret x
  (`wrap_line`); each row draws the same layout shifted left by its first character's x and clipped to its
  character range. Whitespace may hang past the right edge in word mode. No hscroll while wrapping.
- The window still scrolls by buffer line (`window-start-line`); `keep_visible` counts screen rows, so point's row is
  always shown. A line taller than the window is not scrolled within (seam: a start offset in rows).
- Scheme: `truncate-lines` (default `#t`, so existing buffers, dired, vterm and the sidebar are unchanged),
  `word-wrap`, and `visual-line-mode` (buffer-local, word wrap and screen-row `C-n`, `C-p`, `C-a`, `C-e`). The goal
  column of a run of row moves is kept in points. `window-row-start/end/x`, `window-move-rows` are the queries.
- Mouse (`pos_at`), `pos_rect` (avy), the cursor, region, hl-line (all rows of the line) and show-paren follow rows.
- Not done: only the first 4096 characters of a line are shaped, so a longer line wraps only that far; `C-k` and
  other commands still act on logical lines (as in Emacs); no fringe arrows for continuation, a bar is drawn.
- Verified: C test `test_soft_wrap`, Scheme `wrap-test.ss`. Not verified on screen.

**2. Fringe git marks** (`m4-git-marks`).
- libgit2 joins the build (`cmake/Libgit2.cmake`; no HTTPS/SSH/auth backends, since the CLI does the network).
  `core/git/pf_git.c` is the first reader: `pf_git_line_marks` diffs a buffer's text against the file's blob in the
  index (`git_diff_blob_to_buffer`, no context) and returns added/modified/deleted hunks. Index, not HEAD: staged
  changes stop showing, as in diff-hl.
- Windows draw them (`pf_window_set_line_marks`, roles `diff-hl-insert/change/delete`): a bar at the left edge
  (the fringe's width, at least 2 pt, so the minimal preset's 1 pt fringe still shows it), a tick for a removal.
- `(profane git marks)`: global `diff-hl-mode` (on at startup), recomputed per window from a pre-redisplay hook
  when the buffer's undo-state version changes (`pf_text_version`, new). `diff-hl-max-size` (1,000,000 chars) bounds
  the main-thread cost; `M-x diff-hl-refresh` after staging outside profane.
- Seams: the diff runs on the main thread (a worker takes `pf_git_line_marks` as is); the index is not watched
  (FSEvents, §8k); marks are not drawn for untracked files or for a file whose repo is a worktree/submodule (untested).
- Verified: `test_git` (real repo in /tmp), `test_line_marks`, `git-marks-test.ss`, a clean build and `--self-test`.
  Not verified on screen, and not measured against the key-to-pixel target on a large file.

**3. Motion system** (`m4-motion`), part 1: the foundation and the animated cursor.
- `core/display/pf_anim.*`: critically damped springs in closed form (any step is stable, no overshoot) and the
  motion level: off / subtle / full from `ui-motion`, with macOS Reduce Motion (read in `ProfaneView`, re-read on
  `NSWorkspaceAccessibilityDisplayOptionsDidChange`) forcing off. The level is off in C until Scheme applies
  `ui-motion` at startup, so C tests see no animation unless they enable it.
- Clock and loop: `pf_frame_tick(f, now)` before each `pf_frame_redisplay`; while `pf_frame_animating`, the view
  queues one more redisplay about 1/120 s later as a plain main-queue block, so keys and the REPL run between
  frames. A tick more than 50 ms after the last (the main thread was busy) drops the animation: it arrives at once.
  Input is never delayed by animation; under load the animation is what is lost.
- Animated cursor (`animate-cursor`, default `#f`; needs `ui-motion` subtle or full): the box glides to a new row or a far cell (omega 45, about 100 ms). Typing and
  moves of up to two cells along a row snap, so the cursor never trails the text being edited; scrolling, resizing
  and hscroll snap too. The character under the box is redrawn in the background color only once it has arrived.
  The IME rect and `pf_window_cursor_rect` report the target. Hollow cursors do not animate.
- Verified: `test_anim`, `test_cursor_animation` (monotonic, no overshoot, snapping rules, late tick, Reduce Motion).
  Not verified on screen, nor for feel (omega, the 2-cell threshold) or latency with animation running.
- Part 2, the clip primitive and smooth scrolling. `pf_display_clip` / `pf_display_unclip` are display items (one
  clip at a time, no nesting; `pf_display_append` moves a clip with its window). The renderer stamps the current clip
  (whole device pixels) on every quad instance and the fragment shader discards outside it, so the single instanced
  draw call and the item order are unchanged. `PFQuadInstance` grew to 64 bytes.
- Smooth scroll (`animate-scroll`, default `#f`; same gates as the cursor): when a window's top line changes between
  two frames, the text starts where it was (a spring `scroll`, omega 30, about 150 ms) and glides to its place, clipped
  to the body, with the row above shown while it is lower. It snaps for edits (the snapshot changed, so typing at the
  bottom never trails), for jumps of more than a window, for resizes and new buffers, on a late tick and under Reduce
  Motion. A wrapped buffer glides by screen rows. While it glides the cursor is drawn with its row and does not
  animate; `pf_window_cursor_rect`, `pos_rect` and `pos_at` give final positions, so for about 150 ms a click can be
  off by the remaining offset. No clip is emitted when nothing glides, so ordinary frames are unchanged.
- Verified: `test_clip` (macos label: renders a list offscreen through the Metal renderer and reads the PNG: inside,
  each edge pixel, outside, and after the clip ends), `test_clip` in `test_display`, `test_smooth_scroll`. Not
  verified in the app window, nor the feel.
- Part 3, windows and pop-ups (`m4-motion-ui`). Each feature has its own switch, all off by default
  (`animate-cursor`, `animate-scroll`, `animate-windows`, `animate-popups`); a feature animates when its switch is on
  and `ui-motion` reaches its level: cursor and scroll need `subtle`, windows and pop-ups `full`. Reduce Motion
  still forces everything off.
- Windows: `pf_frame_place_window` retargets four springs per window (x, y, width, height; omega 30); a window keeps
  rendering at its placed size and is revealed through the sliding rect (clip + offset), so text relayout is not
  repeated per frame. A new window grows out of the one it was split from (stacked: from its top edge; side by side:
  from its left; otherwise from nothing). A deleted window disappears at once and its neighbor grows. At once, not
  animated: resizing the frame (the user is dragging it), re-showing a window (a tab switch), native-view windows,
  and the first window.
- Pop-ups: opacity spring (omega 35) and a 6 pt slide up into place. Drawn through `pf_display_append_faded` from a
  per-pop-up list rendered at the origin and cached while the feature is on; hiding keeps that list as a "ghost"
  that fades out, so the canvas can be freed right away. Hit-testing uses the final position. With the feature off
  the old direct path is used, so output is unchanged.
- Fold/unfold: not done, there is nothing to fold yet (outline/Org-lite, M10). The consumer would be a spring on a
  region's height with the clip primitive; nothing else is needed from the core.
- Verified: `test_motion` in `test_frame` (split, slide, no overshoot, late tick, frame resize, tab switch, Reduce
  Motion, pop-up fade in and out with the canvas freed mid-fade; the window tests fail with the animation disabled),
  feature thresholds in `test_anim`. Not verified in the app window or for feel.

## 8m. Git v1 (M4 item 4)

Decisions (owner, 2026-10-24): reads go through the git CLI, asynchronously, behind a backend registry so a libgit2
worker can replace them later by Scheme config (`git-read-backend`); the commit message is a buffer written with
`git commit -F` (no editor protocol until v2 rebase); staging covers files, hunks and the lines of a region.
`AGENTS.md`'s "libgit2 for reads" now means: libgit2 where it must run in-process (the fringe marks, §8l) and as the
planned worker backend; the CLI reads status and diffs until then.

Steps, one commit each, tested against throwaway repos with the real `git`:
- **4a** `(profane git)`: `run-git` (async via `run-process`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`,
  `GIT_EDITOR=true`, `LC_MESSAGES=C`, every command and its output in `*git-process*`), repo discovery, status
  (`--porcelain=v2 --branch -z`) and diff (unified, parsed into files and hunks) readers, the backend registry.
- **4b** `(profane section)`: a section tree rendered into a read-only buffer (heading, children, folded flag, `TAB`,
  `n p M-n M-p`); refresh re-renders from the model and restores point and folds by section identity.
  *Done.* Sections are records (kind, id, heading, body lines, children, folded, value); the buffer is erased and
  rebuilt from the tree on every change (no `invisible` property), and `section-refresh!` restores folds by id and
  point by the ids of the section at point and its ancestors plus its line and column (a vanished section falls back
  to its nearest surviving ancestor). `section-mode` binds `TAB`, `<backtab>`, `n p M-n M-p ^ g q`; `g` calls the
  buffer-local `section-refresh-function`. Seams: the section at point is not highlighted yet (needs an overlay or a
  line face); other windows showing the buffer lose their own point on a render; ids that disappear forget their fold.
- **4c** status buffer on `C-x g`: head/merge/push lines, untracked, unstaged, staged, unpushed/unpulled, hunks with
  diff faces.
  *Done.* `(profane git status)`: `magit-status` (`C-x g`, one buffer per repository, `magit: <dir>`), mode
  `git-status-mode` on `section-mode`. Sections: Head and Upstream lines, Untracked, Unmerged paths, Unstaged and
  Staged changes (files, then hunks with `git-diff-*` faces), Unpulled, Unmerged into upstream, Recent commits (10);
  `g` refreshes, `RET` visits the file (on a hunk line, at that line in the new version). Every section's value is a
  `git-item` (kind, area, path, change, diff file, hunk, commit) for the staging commands. `(profane git)` gained
  `git-log` (a third backend procedure) and `git-commit` records. Roots are separated by a blank line
  (`section-separate-roots`). When the changes have more than `git-status-diff-line-limit` (3000) diff lines their
  files start folded; folds the user made are remembered by id and win over that default.
  Reads are sequential (status, two diffs, up to four logs): about seven short processes per refresh, each awaited in
  turn; parallelizing them is a seam. A refresh happens on open and on `g`, not after external changes.
- **4d** staging: `s u k` on a file, a hunk or the region's lines (partial patches through `git apply --cached [-R]`),
  `S U` for all, confirmation before discarding.
  *Done.* In the status buffer `s` stages, `u` unstages, `k` discards (after a y/n prompt), `S` stages every tracked
  change, `U` unstages all. They act on the file, hunk or untracked file at point; on the Unstaged, Staged or
  Untracked heading (`s` / `u`); and with an active region on the lines it covers: the hunks it touches in part
  (`git-hunk-region-patch`: forward patches drop unselected additions and turn unselected removals into context;
  reversed ones do the opposite, as `git add -p` does) or, with no hunk in it, the files it covers. Hunks of a
  region are applied last first; every patch goes through `git apply --recount` from a temporary file ($TMPDIR, else
  /tmp). After each command the buffer is redrawn, errors are shown in the echo area (the first line of git's stderr)
  and the full output is in `*git-process*`. Discard: unstaged file `checkout`, untracked `clean -fd`, staged file
  `checkout HEAD` (a new file `rm -f`), hunks and lines by reverse patches (`-R`, `--index` for staged).
  Not done: discarding a staged rename (asks to unstage first), discarding a whole section, a region across a heading
  of two different areas. Patches are built from decoded text, so a hunk with invalid UTF-8 will not apply
  byte-exactly. After staging a file, point falls back to its section's heading (the file is gone from that area).
- **4e** commit transient and message buffer (`C-c C-c`, `C-c C-k`; amend prefills; staged diff shown beside);
  branch, push, pull and fetch transients. Credentials: git's own helper (osxkeychain) and ssh-agent; an askpass
  through `profane-client` is a seam.
  *Done.* `(profane git commands)`, bound in the status buffer: `c` commit menu (switches `-a --allow-empty
  --signoff --no-verify`; `c` commit, `e` extend, `a` amend, `w` reword), `b` branch (checkout including tracking a
  remote branch, create-and-checkout, create, rename, delete with a second question for unmerged ones), `P` push
  (to the upstream; a branch without one asks for a remote if there are several and sets the upstream; `e`
  elsewhere; `-f` is `--force-with-lease`), `F` pull (`-r`, `-f`), `f` fetch (upstream, elsewhere, all; `-p`).
  The message is written in `*git-commit*` (mode `git-commit-mode`, comment lines from the staged files, the diff
  in `*git-commit-diff*` beside it) and committed by `C-c C-c` with `git commit -F <tmp> --cleanup=strip`; an empty
  message is refused and keeps the buffer; `C-c C-k` closes both. Amend and reword prefill the last message. Each
  command redraws the status buffers of the repository and shows the last line git printed (or its complaint) in
  the echo area; the whole output is in `*git-process*`. Network commands wait without blocking the editor.
  `run-git` sets `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` (unless the user set one) so ssh fails instead of
  waiting for a password it cannot read. Not done: askpass/passphrase prompts, hooks that need a terminal, signing
  prompts, `commit --fixup`, merge/rebase/stash/tag, remote and upstream management beyond the first push, pushing
  tags. Tested end to end against a bare remote and a second clone.
- **4f** `d` diff, `RET` on a commit shows it, a plain `l` log list (the graph is v2).
  *Done.* `(profane git views)`: `d` diff menu (`d` what point is on, `u` unstaged, `s` staged, `w` work tree vs HEAD,
  `r` a range, `c` the commit at point or one you name; `-w`, `-U`), `l` log menu (`l` current branch, `o` another,
  `a` all; `-n`). A diff, a commit (header with author, date and message, then its changes; merges against the
  first parent) and the log are section buffers (`git-diff-mode`, `git-log-mode` on `section-mode`): folds, `n p`,
  `g` refresh, `RET` on a file or hunk visits the work-tree file at that line (for an old commit that is the
  current file, so the line can be off), `RET` on a commit shows it (also from the status buffer), `+` doubles the
  log. A view reads git before its buffer exists, so a bad revision leaves nothing behind. `git-diff-with` is a
  fifth backend procedure (any `git diff`/`git show` parsed into files and hunks). The items of a diff have area
  `diff`, so `s u k` refuse them. The log has no graph (v2).
- **4g** word-level diff refinement (first to cut).
  *Done.* `git-word-diff` (tokens: word runs, whitespace runs, single other characters; a longest common
  subsequence after trimming the common ends, skipped above 40,000 token pairs and when nothing is shared) and
  `git-refine-lines` (a run of removed lines followed by added lines: line by line when the counts are equal, else
  as one block; skipped for hunks over 800 lines) give the changed character ranges. Status and diff buffers draw
  them in `git-diff-added-refined` / `git-diff-removed-refined` (a background per theme, `bg-added-refined`,
  `bg-removed-refined`, plus bold); `git-diff-refine` (default on) turns it off. All hunks are refined, not only
  the one at point, which costs time on very large diffs (the limits above bound it); a per-hunk lazy refinement
  is the seam. Magit's refinement uses `git diff --word-diff`; this one is computed in Scheme so it works on any
  backend's hunks.
Step 4 (Git v1) is complete except ediff (item 5); credentials/askpass are a seam (§8m 4e).
Refresh is manual (`g`) and after every git command profane runs; FSEvents (§8k) would make it automatic.

## 8n. ediff (M4 item 5)

`(profane ediff)`: `M-x ediff-buffers`, `ediff-files`, and `e` in the status buffer (work tree against the index for an
unstaged file, the index against HEAD for a staged one; the index and HEAD versions are read-only temporary
buffers). The selected window is split: A left, B right, both showing *copies* of the buffers (`*ediff A: …*`) with
filler lines where one side has fewer lines, so every difference occupies the same rows and the two scroll together
(a `pre-redisplay-hook` copies start line and row between the windows). Changed rows are tinted, the current
difference stronger, and the words that changed inside it use `git-refine-lines`. The differences come from
`git diff --no-index -U0` on two temporary files, so git is the only diff engine (`-w` for ignoring whitespace).
Keys: `n SPC` / `p DEL` next and previous difference, `a` copy A's lines into B, `b` B's into A (the original buffer is
edited, with an undo boundary; a read-only target refuses), `#` toggle whitespace, `!` compare again, `q` quit (views
and temporary buffers are killed, the window layout is restored). Copying and `!` rebuild the views.
Decisions and limits: the views are copies, so the originals keep their own faces and nothing has to be removed on
quit, but typing in a view is not possible (edit the original and press `!`). Filler lines are `ediff-filler-width`
(300) spaces in a tinted face, because the renderer paints backgrounds only under characters; a window wider than
that shows the filler short. Line numbers are off in the views. A binary file is refused. Replacing the last line of a
buffer without a trailing newline adds one. Not done: three-way comparison and merge (the plan's "2/3-way": only 2-way
is here), directory comparison, ediff of regions, `ediff-revision` outside the status buffer, a control panel.
Verified by `ediff-test.ss` (49 checks): alignment and fillers, faces and refined words, navigation, the windows
following each other, both copy directions, undo, whitespace, quit, identical buffers, read-only targets, and `e` on
unstaged and staged files. Not verified on screen.

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
