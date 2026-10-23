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
  Scheme picks what a window shows via `(profane window)`; the shell owns the window (one per frame in M1).

## 9. Milestones

| # | Milestone | Exit criteria |
|---|---|---|
| M0 | Skeleton | `.app`, Metal clear, Chez boot files, signed build with `allow-jit` verified, socket REPL, Core Text hello |
| M1 | Text + render | Piece tree, undo, layout cache, atlas, `pf_renderer`, 3-layer view stack, IME; line numbers, hl-line, paren match; <8 ms key-to-pixel |
| M2 | Core workflow | Registries, native-view window kind (stub view), `(profane canvas)` low-level API (internal popups/transients/jump labels built on it), default + ported keymaps, windows, tab-bar, ace-window/avy/transpose, complete (vertico/marginalia/consult), transients, themes, design tokens, UI typography (SF Pro + code font), `ui-style` presets |
| M3 | Async + tools | Processes/PTY, ripgrep/find, dired + sidebar, vterm, shell-here, Keychain, `(profane macos)`, TLS sockets |
| M4 | Git v1 + ediff | Fringe git marks, motion system (smooth scroll, cursor, splits, pop-ups, Reduce Motion). **Dogfood**: daily editing, git and terminal in profane |
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
