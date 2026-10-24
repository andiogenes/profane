;;; (profane native) — raw bindings to the C core (core/embed/pf_buffer_ffi.h). Internal: use
;;; (profane buffer). Arguments are integer handles, sizes and bytevectors; never pointers.
;;;
;;; In the app the entry points live in the executable itself, found with
;;; (load-shared-object #f). The standalone `scheme` used by tests loads the pf_native dylib
;;; named by $PROFANE_NATIVE_LIB.

(library (profane native)
  (export %buf-new %buf-free %buf-chars %buf-bytes %buf-lines %buf-insert %buf-delete
          %buf-range-bytes %buf-copy %buf-char-at %buf-line-start %buf-line-of
          %buf-marker-new %buf-marker-free %buf-marker-pos %buf-marker-set
          %buf-undo-boundary %buf-set-undo %buf-undo %buf-redo %buf-modified %buf-mark-saved
          %frm-selected %frm-set-selected %frm-new-headless %frm-free-headless %frm-width
          %frm-height %frm-line-height %frm-cell-width %frm-strip-height %frm-set-tab-bar
          %frm-redisplay %frm-window-new %frm-window-delete %frm-place-window
          %frm-select-window %frm-set-text-scale
          %frm-set-window-native %frm-native-count %frm-native-field
          %win-selected %win-set-buffer %win-top-line %win-set-top-line %win-body-lines
          %win-set-option %win-option %win-set-edges %win-set-mode-line %win-mode-line-height
          %win-hscroll %win-set-min-hscroll %win-set-region %win-pos-rect %win-pos-at %frm-cursor-at
          %cvs-new %cvs-free %cvs-set-size %cvs-width %cvs-height %cvs-clear %cvs-fill-rect
          %cvs-fill-round-rect %cvs-stroke-round-rect %cvs-shadow %cvs-line %cvs-text %cvs-add-hit
          %cvs-hit-test %cvs-text-width %cvs-text-height %cvs-popup-show %cvs-popup-hide
          %cvs-popup-shown %cvs-frame-hit %cvs-hit-canvas %cvs-hit-cursor %cvs-overlay-redisplay
          %cvs-set-window %cvs-window-body %cvs-hit-x %cvs-hit-y
          %input-set-prefix-pending %input-set-press-and-hold
          %face-define %face-role-set %buf-put-prop %buf-get-prop %display-set-line-spacing)
  (import (chezscheme))

  (define loaded
    (begin
      (unless (foreign-entry? "pf_buf_new")
        (load-shared-object (getenv "PROFANE_NATIVE_LIB")))
      #t))

  (define-syntax define-native
    (syntax-rules ()
      [(_ name c-name (arg ...) result)
       (define name (foreign-procedure c-name (arg ...) result))]))

  (define-native %buf-new "pf_buf_new" (u8* size_t) unsigned-32)
  (define-native %buf-free "pf_buf_free" (unsigned-32) int)
  (define-native %buf-chars "pf_buf_chars" (unsigned-32) integer-64)
  (define-native %buf-bytes "pf_buf_bytes" (unsigned-32) integer-64)
  (define-native %buf-lines "pf_buf_lines" (unsigned-32) integer-64)
  (define-native %buf-insert "pf_buf_insert" (unsigned-32 size_t u8* size_t) int)
  (define-native %buf-delete "pf_buf_delete" (unsigned-32 size_t size_t) int)
  (define-native %buf-range-bytes "pf_buf_range_bytes" (unsigned-32 size_t size_t) integer-64)
  (define-native %buf-copy "pf_buf_copy" (unsigned-32 size_t size_t u8* size_t) integer-64)
  (define-native %buf-char-at "pf_buf_char_at" (unsigned-32 size_t) integer-64)
  (define-native %buf-line-start "pf_buf_line_start" (unsigned-32 size_t) integer-64)
  (define-native %buf-line-of "pf_buf_line_of" (unsigned-32 size_t) integer-64)
  (define-native %buf-marker-new "pf_buf_marker_new" (unsigned-32 size_t boolean) unsigned-32)
  (define-native %buf-marker-free "pf_buf_marker_free" (unsigned-32 unsigned-32) int)
  (define-native %buf-marker-pos "pf_buf_marker_pos" (unsigned-32 unsigned-32) integer-64)
  (define-native %buf-marker-set "pf_buf_marker_set" (unsigned-32 unsigned-32 size_t) int)
  (define-native %buf-undo-boundary "pf_buf_undo_boundary" (unsigned-32) int)
  (define-native %buf-set-undo "pf_buf_set_undo" (unsigned-32 boolean) int)
  (define-native %buf-undo "pf_buf_undo" (unsigned-32) integer-64)
  (define-native %buf-redo "pf_buf_redo" (unsigned-32) integer-64)
  (define-native %buf-modified "pf_buf_modified" (unsigned-32) int)
  (define-native %buf-mark-saved "pf_buf_mark_saved" (unsigned-32) int)
  (define-native %frm-selected "pf_frm_selected" () unsigned-32)
  (define-native %frm-set-selected "pf_frm_set_selected" (unsigned-32) void)
  (define-native %frm-new-headless "pf_frm_new_headless" (float float) unsigned-32)
  (define-native %frm-free-headless "pf_frm_free_headless" (unsigned-32) int)
  (define-native %frm-width "pf_frm_width" (unsigned-32) double)
  (define-native %frm-height "pf_frm_height" (unsigned-32) double)
  (define-native %frm-line-height "pf_frm_line_height" (unsigned-32 float) double)
  (define-native %frm-cell-width "pf_frm_cell_width" (unsigned-32 float) double)
  (define-native %frm-strip-height "pf_frm_strip_height" (unsigned-32 unsigned-32 boolean) double)
  (define-native %frm-set-tab-bar "pf_frm_set_tab_bar"
    (unsigned-32 u8* size_t u8* size_t unsigned-32 boolean) int)
  (define-native %frm-redisplay "pf_frm_redisplay" (unsigned-32) integer-64)
  (define-native %frm-window-new "pf_frm_window_new" (unsigned-32) unsigned-32)
  (define-native %frm-window-delete "pf_frm_window_delete" (unsigned-32 unsigned-32) int)
  (define-native %frm-place-window "pf_frm_place_window"
    (unsigned-32 unsigned-32 float float float float boolean) int)
  (define-native %frm-select-window "pf_frm_select_window" (unsigned-32 unsigned-32) int)
  (define-native %frm-set-text-scale "pf_frm_set_text_scale" (unsigned-32 unsigned-32 float) int)
  (define-native %frm-set-window-native "pf_frm_set_window_native" (unsigned-32 unsigned-32 unsigned-32) int)
  (define-native %frm-native-count "pf_frm_native_count" (unsigned-32) integer-64)
  (define-native %frm-native-field "pf_frm_native_field" (unsigned-32 size_t int) double)
  (define-native %win-selected "pf_win_selected" () unsigned-32)
  (define-native %win-set-buffer "pf_win_set_buffer" (unsigned-32 unsigned-32 unsigned-32) int)
  (define-native %win-top-line "pf_win_top_line" (unsigned-32) integer-64)
  (define-native %win-set-top-line "pf_win_set_top_line" (unsigned-32 size_t) int)
  (define-native %win-body-lines "pf_win_body_lines" (unsigned-32) integer-64)
  (define-native %win-set-option "pf_win_set_option" (unsigned-32 int int) int)
  (define-native %win-option "pf_win_option" (unsigned-32 int) int)
  (define-native %win-set-edges "pf_win_set_edges" (unsigned-32 float float float) int)
  (define-native %win-set-mode-line "pf_win_set_mode_line"
    (unsigned-32 u8* size_t u8* size_t unsigned-32 boolean) int)
  (define-native %win-mode-line-height "pf_win_mode_line_height" (unsigned-32) double)
  (define-native %win-pos-at "pf_win_pos_at" (unsigned-32 float float) integer-64)
  (define-native %frm-cursor-at "pf_frm_cursor_at" (unsigned-32 float float) int)
  (define-native %win-pos-rect "pf_win_pos_rect" (unsigned-32 size_t u8*) int)
  (define-native %win-set-region "pf_win_set_region" (unsigned-32 size_t size_t) int)
  (define-native %win-hscroll "pf_win_hscroll" (unsigned-32) double)
  (define-native %win-set-min-hscroll "pf_win_set_min_hscroll" (unsigned-32 float) int)
  (define-native %cvs-new "pf_cvs_new" (float float) unsigned-32)
  (define-native %cvs-free "pf_cvs_free" (unsigned-32) int)
  (define-native %cvs-set-size "pf_cvs_set_size" (unsigned-32 float float) int)
  (define-native %cvs-width "pf_cvs_width" (unsigned-32) double)
  (define-native %cvs-height "pf_cvs_height" (unsigned-32) double)
  (define-native %cvs-clear "pf_cvs_clear" (unsigned-32) int)
  (define-native %cvs-fill-rect "pf_cvs_fill_rect"
    (unsigned-32 float float float float unsigned-32) int)
  (define-native %cvs-fill-round-rect "pf_cvs_fill_round_rect"
    (unsigned-32 float float float float float unsigned-32) int)
  (define-native %cvs-stroke-round-rect "pf_cvs_stroke_round_rect"
    (unsigned-32 float float float float float float unsigned-32) int)
  (define-native %cvs-shadow "pf_cvs_shadow"
    (unsigned-32 float float float float float float unsigned-32) int)
  (define-native %cvs-line "pf_cvs_line"
    (unsigned-32 float float float float float unsigned-32) int)
  (define-native %cvs-text "pf_cvs_text"
    (unsigned-32 float float u8* size_t unsigned-32 unsigned-32) int)
  (define-native %cvs-add-hit "pf_cvs_add_hit"
    (unsigned-32 float float float float unsigned-32 int) int)
  (define-native %cvs-hit-test "pf_cvs_hit_test" (unsigned-32 float float) integer-64)
  (define-native %cvs-text-width "pf_cvs_text_width" (unsigned-32 u8* size_t unsigned-32) double)
  (define-native %cvs-text-height "pf_cvs_text_height" (unsigned-32 unsigned-32) double)
  (define-native %cvs-popup-show "pf_cvs_popup_show" (unsigned-32 unsigned-32 float float) int)
  (define-native %cvs-popup-hide "pf_cvs_popup_hide" (unsigned-32 unsigned-32) int)
  (define-native %cvs-popup-shown "pf_cvs_popup_shown" (unsigned-32 unsigned-32) int)
  (define-native %cvs-frame-hit "pf_cvs_frame_hit" (unsigned-32 float float) integer-64)
  (define-native %cvs-hit-canvas "pf_cvs_hit_canvas" () unsigned-32)
  (define-native %cvs-hit-cursor "pf_cvs_hit_cursor" () int)
  (define-native %cvs-overlay-redisplay "pf_cvs_overlay_redisplay" (unsigned-32) integer-64)
  (define-native %cvs-set-window "pf_cvs_set_window" (unsigned-32 unsigned-32 unsigned-32) int)
  (define-native %cvs-window-body "pf_cvs_window_body" (unsigned-32 int) double)
  (define-native %cvs-hit-x "pf_cvs_hit_x" () double)
  (define-native %cvs-hit-y "pf_cvs_hit_y" () double)
  (define-native %input-set-prefix-pending "pf_input_set_prefix_pending" (boolean) void)
  (define-native %input-set-press-and-hold "pf_input_set_press_and_hold" (u8* size_t) void)
  (define-native %face-define "pf_face_define"
    (unsigned-32 unsigned-32 unsigned-32 unsigned-32 unsigned-32 unsigned-32) void)
  (define-native %face-role-set "pf_face_role_set" (int unsigned-32) void)
  (define-native %buf-put-prop "pf_buf_put_prop" (unsigned-32 unsigned-32 size_t size_t unsigned-32) int)
  (define-native %buf-get-prop "pf_buf_get_prop" (unsigned-32 unsigned-32 size_t) integer-64)
  (define-native %display-set-line-spacing "pf_display_set_line_spacing" (float) void))
