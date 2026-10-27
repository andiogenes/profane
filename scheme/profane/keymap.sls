;;; (profane keymap) — keymaps and key sequences. Unstable API (plan §10).
;;;
;;; A key is a canonical description string as produced by the shell: modifiers in the order
;;; C- M- S- s- followed by a key name ("a", "C-x", "C-M-%", "<f5>", "RET"). A key sequence is
;;; a list of keys; (kbd "C-x C-f") parses one, canonicalizing modifier order ("M-C-x" is
;;; "C-M-x"). A keymap binds keys to command names (symbols), never procedures (plan §1), or to
;;; keymaps for prefix keys, and may inherit from a parent keymap.

(library (profane keymap)
  (export make-keymap keymap? keymap-parent set-keymap-parent! keymap-name
          kbd key-description canonical-key
          define-key! lookup-key keymap-bindings global-map)
  (import (chezscheme))

  (define-record-type (keymap %make-keymap keymap?)
    (fields table (mutable parent) name)
    (nongenerative profane-keymap))

  (define make-keymap
    (case-lambda
      [() (make-keymap #f #f)]
      [(parent) (make-keymap parent #f)]
      [(parent name) (%make-keymap (make-hashtable string-hash string=?) parent name)]))

  (define (set-keymap-parent! map parent) (keymap-parent-set! map parent))

  ;; ---- key syntax ----

  (define modifier-order '(#\C #\M #\S #\s))

  ;; Control characters that are also named keys, as in Emacs: C-m is RET, C-i is TAB, C-[ is ESC.
  (define control-aliases '(("m" . "RET") ("i" . "TAB") ("[" . "ESC")))

  ;; "M-C-x" -> "C-M-x"; leaves the key name alone. A modifier prefix "X-" is consumed only if
  ;; something follows it, so "C--" is Control-minus and "-" is minus.
  (define (canonical-key key)
    (let loop ([i 0] [mods '()])
      (if (and (> (string-length key) (+ i 2))
               (memv (string-ref key i) modifier-order)
               (char=? (string-ref key (+ i 1)) #\-))
          (loop (+ i 2) (cons (string-ref key i) mods))
          (let* ([raw (substring key i (string-length key))]
                 [alias (and (memv #\C mods) (assoc raw control-aliases))]
                 [name (if alias (cdr alias) raw)]
                 [mods (if alias (remv #\C mods) mods)])
            (apply string-append
                   (append (map (lambda (m) (string m #\-))
                                (filter (lambda (m) (memv m mods)) modifier-order))
                           (list name)))))))

  (define (split-spaces s)
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(= i (string-length s))
         (reverse (if (> i start) (cons (substring s start i) acc) acc))]
        [(char=? (string-ref s i) #\space)
         (loop (+ i 1) (+ i 1) (if (> i start) (cons (substring s start i) acc) acc))]
        [else (loop (+ i 1) start acc)])))

  (define (kbd s) (map canonical-key (split-spaces s)))

  (define (key-description keys) (apply string-append (join keys " ")))

  (define (join items sep)
    (if (null? items) '()
        (cons (car items) (apply append (map (lambda (x) (list sep x)) (cdr items))))))

  (define (as-keys keys) (if (string? keys) (kbd keys) (map canonical-key keys)))

  ;; ---- binding and lookup ----

  ;; BINDING: a command name (symbol), a keymap (prefix), or #f to unbind. Intermediate prefix
  ;; keymaps are created as needed.
  (define (define-key! map keys binding)
    (unless (or (symbol? binding) (keymap? binding) (not binding))
      (error 'define-key! "keys bind command names (symbols) or keymaps" binding))
    (let loop ([map map] [keys (as-keys keys)])
      (cond
        [(null? keys) (error 'define-key! "empty key sequence")]
        [(null? (cdr keys))
         (if binding
             (hashtable-set! (keymap-table map) (car keys) binding)
             (hashtable-delete! (keymap-table map) (car keys)))]
        [else
         (let ([next (hashtable-ref (keymap-table map) (car keys) #f)])
           (loop (if (keymap? next)
                     next
                     (let ([sub (make-keymap)])
                       (hashtable-set! (keymap-table map) (car keys) sub)
                       sub))
                 (cdr keys)))])))

  ;; KEYS in MAP's own bindings (not its parents): a command name, a keymap, or #f.
  (define (lookup-own map keys)
    (let loop ([map map] [keys keys])
      (cond
        [(null? keys) map]
        [else
         (let ([b (hashtable-ref (keymap-table map) (car keys) #f)])
           (cond
             [(null? (cdr keys)) b]
             [(keymap? b) (loop b (cdr keys))]
             [else #f]))])))

  ;; The binding of KEYS: a command name, a keymap if KEYS is a prefix, or #f. As in Emacs, the
  ;; whole sequence is looked up in MAP and, failing that, in its parent: a mode map can add
  ;; C-x bindings without hiding the global ones (C-x C-f still falls through to the parent).
  (define (lookup-key map keys)
    (let ([keys (as-keys keys)])
      (let loop ([map map])
        (and map (or (lookup-own map keys) (loop (keymap-parent map)))))))

  ;; Direct bindings of MAP (not its parents), as (key . binding) pairs.
  (define (keymap-bindings keymap)
    (let-values ([(keys vals) (hashtable-entries (keymap-table keymap))])
      (map cons (vector->list keys) (vector->list vals))))

  (define the-global-map (make-keymap #f 'global-map))
  (define (global-map) the-global-map))
