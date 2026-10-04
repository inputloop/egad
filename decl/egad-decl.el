;;; egad-decl.el --- the declarative layer: Org property drawers <-> JSON <-> plists  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Corwin Brust <corwin@bru.st>.  Authored with Claude (Cowork).
;; SPDX-License-Identifier: GPL-3.0-or-later.  WITHOUT ANY WARRANTY; see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The second reader of decl/egad-decl.py, written apart from it from the same prose spec (the subset is stated at
;; the top of the Python file and in MODEL.org).  It reads the same Org text line by line -- deliberately not
;; through org-element, so the two readers share no parser -- and writes JSON with json.el.  `egad-decl-to-plist'
;; gives the Emacs Lisp face of one node.
;;
;;   emacs --batch -Q -l decl/egad-decl.el --eval '(egad-decl-cli-to-json "FILE.org")'
;;   emacs --batch -Q -l decl/egad-decl.el --eval '(egad-decl-cli-to-org "FILE.json")'

;;; Code:

(require 'json)
(require 'subr-x)

(define-error 'egad-decl-refused "REFUSED")

(defconst egad-decl--key-re "\\`[a-z][a-z0-9-]*\\'")
(defconst egad-decl--int-re "\\`-?\\(?:0\\|[1-9][0-9]*\\)\\'")

(defun egad-decl--refuse (fmt &rest args)
  (signal 'egad-decl-refused (list (apply #'format fmt args))))

(defun egad-decl--read-value (raw)
  "RAW from a property line -> a Lisp value (string, integer, t, :json-false)."
  (cond ((string-prefix-p "\"" raw)
         (let ((v (condition-case nil (json-read-from-string raw) (error nil))))
           (unless (stringp v) (egad-decl--refuse "not a JSON string literal: %S" raw))
           v))
        ((string-match-p egad-decl--int-re raw) (string-to-number raw))
        ((string= raw "t") t)
        ((string= raw "nil") :json-false)
        (t raw)))

(defun egad-decl--write-value (v)
  (cond ((eq v t) "t")
        ((eq v :json-false) "nil")
        ((integerp v) (number-to-string v))
        ((stringp v)
         (when (string-match-p "[\n\r]" v) (egad-decl--refuse "a value is one line"))
         (if (or (string= v "") (string-match-p egad-decl--int-re v) (member v '("t" "nil"))
                 (not (string= v (string-trim v))) (string-prefix-p "\"" v))
             (json-encode-string v)
           v))
        (t (egad-decl--refuse "value outside the subset: %S" v))))

(defun egad-decl--node (title)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "title" title h)
    (puthash "props" (make-hash-table :test 'equal) h)
    (puthash "children" [] h)
    h))

(defun egad-decl--add-child (parent child)
  (puthash "children" (vconcat (gethash "children" parent) (vector child)) parent))

(defun egad-decl-parse (text)
  "Org TEXT -> a vector of node hash tables."
  ;; case-fold-search is t by default in Emacs: without this, ":Key:" passed the lower-case key rule.  The Python
  ;; reader refused it and this one did not -- found by the two-reader check on its first run (2026-10-04).
  (let ((case-fold-search nil) (lines (split-string text "\n")) (roots []) (stack nil) (n 0))
    (while lines
      (let ((line (pop lines)))
        (setq n (1+ n))
        (when (string-match "\\`\\(\\*+\\) \\(.*\\)\\'" line)
          (let* ((level (length (match-string 1 line)))
                 (node (egad-decl--node (string-trim-right (match-string 2 line))))
                 (props (gethash "props" node)) (lists (make-hash-table :test 'equal)))
            (when (and lines (string= (string-trim (car lines)) ":PROPERTIES:"))
              (pop lines) (setq n (1+ n))
              (while (and lines (not (string= (string-trim (car lines)) ":END:")))
                (let ((pl (pop lines)))
                  (setq n (1+ n))
                  (unless (string-match "\\`[ \t]*:\\([^: \t]+?\\)\\(\\+?\\):\\(?:[ \t]\\(.*\\)\\)?\\'" pl)
                    (egad-decl--refuse "line %d: not a property line: %S" n pl))
                  (let ((key (match-string 1 pl)) (plus (string= (match-string 2 pl) "+"))
                        (raw (string-trim-right (or (match-string 3 pl) "") "\r")))
                    (unless (string-match-p egad-decl--key-re key)
                      (egad-decl--refuse "line %d: key outside the subset: %S" n key))
                    (if plus
                        (progn
                          (when (and (gethash key props) (not (gethash key lists)))
                            (egad-decl--refuse "line %d: %s is both a scalar and a list" n key))
                          (puthash key t lists)
                          (puthash key (vconcat (gethash key props []) (vector (egad-decl--read-value raw))) props))
                      (when (gethash key props) (egad-decl--refuse "line %d: %s set twice" n key))
                      (puthash key (egad-decl--read-value raw) props)))))
              (unless lines (egad-decl--refuse "a property drawer has no :END:"))
              (pop lines) (setq n (1+ n)))
            (while (and stack (>= (caar stack) level)) (pop stack))
            (if stack
                (progn (unless (= level (1+ (caar stack)))
                         (egad-decl--refuse "headline %S skips a level" (gethash "title" node)))
                       (egad-decl--add-child (cdar stack) node))
              (unless (= level 1) (egad-decl--refuse "the first headline %S is not level 1" (gethash "title" node)))
              (setq roots (vconcat roots (vector node))))
            (push (cons level node) stack)))))
    roots))

(defun egad-decl-unparse (nodes &optional level)
  "A vector or list of nodes (hash tables or alists from json-read) -> Org text lines, as a list."
  (let ((case-fold-search nil) (level (or level 1)) (out nil))
    (seq-doseq (nd nodes)
      (let* ((get (lambda (k) (if (hash-table-p nd) (gethash k nd) (cdr (assoc k nd)))))
             (title (funcall get "title")) (props (funcall get "props")) (kids (funcall get "children")))
        (unless (and (stringp title) (> (length title) 0) (string= title (string-trim title))
                     (not (string-match-p "\n" title)))
          (egad-decl--refuse "a title is one non-empty line without edge spaces: %S" title))
        (push (concat (make-string level ?*) " " title) out)
        (let ((pairs (cond ((hash-table-p props) (let (ps) (maphash (lambda (k v) (push (cons k v) ps)) props) (nreverse ps)))
                           (t props))))
          (when pairs
            (push ":PROPERTIES:" out)
            (dolist (p pairs)
              (let ((k (if (symbolp (car p)) (symbol-name (car p)) (car p))) (v (cdr p)))
                (unless (string-match-p egad-decl--key-re k) (egad-decl--refuse "key outside the subset: %S" k))
                (if (vectorp v)
                    (progn (when (= (length v) 0) (egad-decl--refuse "%s: an empty list has no Org form" k))
                           (seq-doseq (x v) (push (format ":%s+: %s" k (egad-decl--write-value x)) out)))
                  (push (format ":%s: %s" k (egad-decl--write-value v)) out))))
            (push ":END:" out)))
        (setq out (append (reverse (egad-decl-unparse (or kids []) (1+ level))) out))))
    (nreverse out)))

(defun egad-decl-to-plist (node)
  "The Emacs Lisp face of NODE (a hash table): (:title T :key V ...), lists as lists, false as nil."
  (let ((pl (list :title (gethash "title" node))))
    (maphash (lambda (k v)
               (setq pl (append pl (list (intern (concat ":" k))
                                         (cond ((eq v :json-false) nil) ((vectorp v) (append v nil)) (t v))))))
             (gethash "props" node))
    pl))

(defun egad-decl--file (f) (with-temp-buffer (insert-file-contents f) (buffer-string)))

(defun egad-decl-cli-to-json (file)
  (condition-case e
      (let ((json-encoding-pretty-print nil))
        (princ (json-encode (egad-decl-parse (egad-decl--file file)))) (terpri))
    (egad-decl-refused (message "REFUSED: %s" (cadr e)) (kill-emacs 1))))

(defun egad-decl-cli-to-org (file)
  (condition-case e
      (let* ((json-object-type 'alist) (json-array-type 'vector) (json-key-type 'string) (json-false :json-false)
             (data (json-read-from-string (egad-decl--file file))))
        (princ (mapconcat #'identity (egad-decl-unparse data) "\n")) (terpri))
    (egad-decl-refused (message "REFUSED: %s" (cadr e)) (kill-emacs 1))))

(provide 'egad-decl)
;;; egad-decl.el ends here
