;;; (profane face) — the face registry. Unstable API (plan §10).
;;;
;;; A face is a symbol with display attributes: foreground, background ("#rrggbb" strings),
;;; weight (normal bold), slant (normal italic), underline (#f, #t or a color), family (a font
;;; family name, or system-ui for the macOS UI font), height (a multiple of the default size),
;;; features (OpenType settings like "calt=0") and inherit (another face). Missing
;;; attributes come from the inherited face, then from `default`. Themes set attributes; change
;;; watchers push them to the display engine.

(library (profane face)
  (export define-face face-defined? face-names face-documentation
          face-attribute face-attributes set-face-attribute! add-face-watcher!
          face-attribute-names)
  (import (chezscheme))

  ;; features: OpenType feature settings, e.g. "calt=0,liga=0" (ligatures off).
  (define face-attribute-names
    '(foreground background weight slant underline family height features inherit))

  (define-record-type face
    (fields attrs (mutable doc)) ; attrs: eq-hashtable attr -> value
    (nongenerative profane-face))

  (define registry (make-eq-hashtable))
  (define watchers '())

  (define (check-attr who attr)
    (unless (memq attr face-attribute-names) (error who "unknown face attribute" attr)))

  ;; ATTRS is an alist of (attribute . value). Redefining keeps attributes already set (e.g. by
  ;; a theme) and only fills in missing ones, like Emacs defface.
  (define define-face
    (case-lambda
      [(name attrs) (define-face name attrs "")]
      [(name attrs doc)
       (let ([f (or (hashtable-ref registry name #f)
                    (let ([f (make-face (make-eq-hashtable) doc)])
                      (hashtable-set! registry name f)
                      f))])
         (face-doc-set! f doc)
         (for-each (lambda (a)
                     (check-attr 'define-face (car a))
                     (unless (hashtable-contains? (face-attrs f) (car a))
                       (hashtable-set! (face-attrs f) (car a) (cdr a))))
                   attrs)
         (notify name)
         name)]))

  (define (face-defined? name) (hashtable-contains? registry name))
  (define (face-names) (vector->list (hashtable-keys registry)))

  (define (lookup who name)
    (or (hashtable-ref registry name #f) (error who "undefined face" name)))

  (define (face-documentation name) (face-doc (lookup 'face-documentation name)))

  ;; ATTR of NAME, following inherit and finally `default`; #f if nobody sets it.
  (define face-attribute
    (case-lambda
      [(name attr) (face-attribute name attr #t)]
      [(name attr inherit?)
       (check-attr 'face-attribute attr)
       (let loop ([name name] [seen '()])
         (let* ([f (lookup 'face-attribute name)]
                [v (hashtable-ref (face-attrs f) attr #f)])
           (cond
             [(or v (not inherit?)) v]
             [(memq name seen) (error 'face-attribute "inherit cycle" seen)]
             [(hashtable-ref (face-attrs f) 'inherit #f)
              => (lambda (parent) (loop parent (cons name seen)))]
             [(and (not (eq? name 'default)) (face-defined? 'default))
              (loop 'default (cons name seen))]
             [else #f])))]))

  ;; All attributes of NAME, resolved, as an alist (attributes nobody sets are omitted).
  (define (face-attributes name)
    (filter cdr (map (lambda (a) (cons a (face-attribute name a)))
                     (remq 'inherit face-attribute-names))))

  (define (set-face-attribute! name attr value)
    (check-attr 'set-face-attribute! attr)
    (let ([f (lookup 'set-face-attribute! name)])
      (if value
          (hashtable-set! (face-attrs f) attr value)
          (hashtable-delete! (face-attrs f) attr))
      (notify name)))

  ;; PROC is called with a face name whenever that face (or a new one) changes.
  (define (add-face-watcher! proc)
    (unless (memq proc watchers) (set! watchers (append watchers (list proc)))))

  (define (notify name) (for-each (lambda (w) (w name)) watchers))

  (define-face 'default '() "Basic face: every other face falls back to it."))
