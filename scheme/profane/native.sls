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
          %buf-undo-boundary %buf-undo %buf-redo %buf-modified %buf-mark-saved
          %win-selected %win-set-buffer %win-top-line %win-body-lines
          %win-set-option %win-option
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
  (define-native %buf-undo "pf_buf_undo" (unsigned-32) integer-64)
  (define-native %buf-redo "pf_buf_redo" (unsigned-32) integer-64)
  (define-native %buf-modified "pf_buf_modified" (unsigned-32) int)
  (define-native %buf-mark-saved "pf_buf_mark_saved" (unsigned-32) int)
  (define-native %win-selected "pf_win_selected" () unsigned-32)
  (define-native %win-set-buffer "pf_win_set_buffer" (unsigned-32 unsigned-32 unsigned-32) int)
  (define-native %win-top-line "pf_win_top_line" (unsigned-32) integer-64)
  (define-native %win-body-lines "pf_win_body_lines" (unsigned-32) integer-64)
  (define-native %win-set-option "pf_win_set_option" (unsigned-32 int boolean) int)
  (define-native %win-option "pf_win_option" (unsigned-32 int) int)
  (define-native %face-define "pf_face_define"
    (unsigned-32 unsigned-32 unsigned-32 unsigned-32 unsigned-32 unsigned-32) void)
  (define-native %face-role-set "pf_face_role_set" (int unsigned-32) void)
  (define-native %buf-put-prop "pf_buf_put_prop" (unsigned-32 unsigned-32 size_t size_t unsigned-32) int)
  (define-native %buf-get-prop "pf_buf_get_prop" (unsigned-32 unsigned-32 size_t) integer-64)
  (define-native %display-set-line-spacing "pf_display_set_line_spacing" (float) void))
