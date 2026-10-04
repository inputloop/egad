;;; egad-tokens-test.el --- the second witness: ERT checks of the tokens and themes  -*- lexical-binding: t; -*-

;; The gate (tokens/tokens_check.py) is Python and was written from WCAG 2.1.
;; This file is Emacs Lisp, written separately from the same WCAG text, and reads
;; the same tokens file.  Two implementations in two languages must agree that
;; every declared pair clears its floor; a disagreement means one of them is wrong.
;; It also checks that the GENERATED themes carry the token colours into faces.
;;
;;   emacs --batch -Q -l ert -l tests/egad-tokens-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)

(defvar egad-test-root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun egad-test--read-json (file)
  (let ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol))
    (json-read-file (expand-file-name file egad-test-root))))

(defun egad-test--channel (hex-pair)
  "WCAG 2.1 §1.4.3: sRGB channel 0..255 -> linear."
  (let ((c (/ (string-to-number hex-pair 16) 255.0)))
    (if (<= c 0.03928) (/ c 12.92) (expt (/ (+ c 0.055) 1.055) 2.4))))

(defun egad-test--luminance (hex)
  (let ((h (string-remove-prefix "#" hex)))
    (when (= (length h) 3)
      (setq h (apply #'concat (mapcar (lambda (c) (string c c)) h))))
    (+ (* 0.2126 (egad-test--channel (substring h 0 2)))
       (* 0.7152 (egad-test--channel (substring h 2 4)))
       (* 0.0722 (egad-test--channel (substring h 4 6))))))

(defun egad-test--contrast (a b)
  (let* ((la (egad-test--luminance a)) (lb (egad-test--luminance b))
         (hi (max la lb)) (lo (min la lb)))
    (/ (+ hi 0.05) (+ lo 0.05))))

(ert-deftest egad-contrast-formula-matches-known-values ()
  "Black on white is 21:1; #777 on white is 4.48:1 (the classic AA near-miss)."
  (should (< (abs (- (egad-test--contrast "#ffffff" "#000000") 21.0)) 0.01))
  (should (< (abs (- (egad-test--contrast "#777777" "#ffffff") 4.48)) 0.01))
  (should (= (egad-test--contrast "#123456" "#abcdef") (egad-test--contrast "#abcdef" "#123456"))))

(defun egad-test--tokens () (egad-test--read-json "tokens/egad-tokens.json"))

(defun egad-test--resolve (tokens name theme &optional depth)
  "Value of colour token NAME in THEME with {aliases} followed."
  (when (> (or depth 0) 16) (error "alias chain too deep at %s" name))
  (let* ((tok (seq-find (lambda (x) (equal (alist-get 'name x) name))
                        (alist-get 'tokens (alist-get 'color tokens))))
         (v (alist-get 'value tok))
         (themes (alist-get 'themes (alist-get 'color tokens)))
         (first (intern (alist-get 'id (car themes))))
         (s (if (stringp v) v (or (alist-get (intern theme) v) (alist-get first v)))))
    (unless tok (error "no colour token %s" name))
    (if (string-match "\\`{\\(.*\\)}\\'" s)
        (egad-test--resolve tokens (match-string 1 s) theme (1+ (or depth 0)))
      s)))

(ert-deftest egad-every-declared-pair-clears-its-floor-in-every-theme ()
  (let* ((tokens (egad-test--tokens))
         (floors '((text . 7.0) (text-aa . 4.5) (ui . 3.0)))
         (themes (mapcar (lambda (th) (alist-get 'id th)) (alist-get 'themes (alist-get 'color tokens))))
         (pairs (alist-get 'pairs (alist-get 'meta tokens)))
         (n 0))
    (should (> (length pairs) 0))
    (dolist (p pairs)
      (dolist (th themes)
        (let* ((fg (egad-test--resolve tokens (alist-get 'fg p) th))
               (bg (egad-test--resolve tokens (alist-get 'bg p) th))
               (floor (alist-get (intern (or (alist-get 'floor p) "text")) floors))
               (ratio (egad-test--contrast fg bg)))
          (cl-incf n)
          (should (>= ratio floor)))))
    (message "ERT: %d pair×theme checks passed" n)))

(ert-deftest egad-colour-token-names-are-unique ()
  (let ((names (mapcar (lambda (x) (alist-get 'name x)) (alist-get 'tokens (alist-get 'color (egad-test--tokens))))))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))))

(ert-deftest egad-generated-themes-carry-the-tokens ()
  "Each dist/elpa-src/egad-THEME-theme.el gives `default', `link' and `org-todo' the token colours."
  (let ((tokens (egad-test--tokens))
        (dir (expand-file-name "dist/elpa-src/" egad-test-root)))
    (skip-unless (file-directory-p dir))
    (require 'org)
    (add-to-list 'custom-theme-load-path dir)
    (dolist (th (mapcar (lambda (x) (alist-get 'id x)) (alist-get 'themes (alist-get 'color tokens))))
      (mapc #'disable-theme custom-enabled-themes)
      (load-theme (intern (concat "egad-" th)) t)
      (should (equal (face-attribute 'default :foreground) (egad-test--resolve tokens "text" th)))
      (should (equal (face-attribute 'default :background) (egad-test--resolve tokens "canvas" th)))
      (should (equal (face-attribute 'link :foreground) (egad-test--resolve tokens "link" th)))
      (should (equal (face-attribute 'org-todo :foreground) (egad-test--resolve tokens "todo" th)))
      (should (equal (face-attribute 'mode-line :background) (egad-test--resolve tokens "canvas-active" th))))))

(ert-deftest egad-generated-css-declares-every-colour-token ()
  (let ((css (expand-file-name "dist/css/egad-tokens.css" egad-test-root))
        (tokens (egad-test--tokens)))
    (skip-unless (file-exists-p css))
    (with-temp-buffer
      (insert-file-contents css)
      (dolist (tok (alist-get 'tokens (alist-get 'color tokens)))
        (goto-char (point-min))
        (should (search-forward (format "--egad-%s:" (alist-get 'name tok)) nil t))))))

(provide 'egad-tokens-test)
;;; egad-tokens-test.el ends here
