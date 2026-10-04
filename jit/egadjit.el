;;; egadjit.el --- browse and fetch egadjit tool forms from a trusted node  -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, convenience
;; URL: https://egad.bru.st/

;;; Commentary:

;; A trusted egad node (role = trusted, reachable over your WireGuard) serves
;; /jit/jit-index.json and the tool forms that jit/unpack.py tangled from
;; literate Org files.  This is the Emacs side of that exchange:
;;
;;   M-x egadjit-list-forms   a table of every form on the node: path, language,
;;                            size, the headline it came from.  RET opens one.
;;   M-x egadjit-open-form    fetch one form into a read-only buffer in the right
;;                            major mode; the header line shows the guidance
;;                            paragraph and whether the SHA-256 matched the index.
;;
;; Nothing is evaluated or installed.  Fetched text is shown; what you do with it
;; is a separate, deliberate step (yank it, tangle it, M-x package-install-file).
;; Set `egadjit-node' to your node, e.g. "https://egadjit.example:8443".

;;; Code:

(require 'url)
(require 'json)
(require 'tabulated-list)

(defgroup egadjit nil "Fetch egadjit tool forms from a trusted node." :group 'tools)

(defcustom egadjit-node "https://egadjit.example:8443"
  "Base URL of the trusted egad node (no trailing slash)."
  :type 'string)

(defcustom egadjit-mode-alist
  '(("css" . css-mode) ("js" . js-mode) ("json" . js-mode) ("sh" . sh-mode)
    ("bash" . sh-mode) ("python" . python-mode) ("perl" . perl-mode)
    ("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode))
  "Major mode to use for a form, by the language its source block declared."
  :type '(alist :key-type string :value-type symbol))

(defvar egadjit--index nil "The last jit-index.json fetched, parsed.")

(defun egadjit--fetch (path)
  "Return the body of PATH on `egadjit-node' as a unibyte string, or signal."
  (let ((url-proxy-services nil))
    (with-current-buffer (url-retrieve-synchronously (concat egadjit-node "/jit/" path) t t 15)
      (goto-char (point-min))
      (unless (re-search-forward "^HTTP/[0-9.]+ 200" (line-end-position) t)
        (error "egadjit: %s: %s" path (buffer-substring (point-min) (line-end-position))))
      (re-search-forward "\n\n" nil t)
      (prog1 (buffer-substring-no-properties (point) (point-max))
        (kill-buffer)))))

(defun egadjit-refresh-index ()
  "Fetch jit-index.json from `egadjit-node'."
  (interactive)
  (let ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol))
    (setq egadjit--index (json-read-from-string (decode-coding-string (egadjit--fetch "jit-index.json") 'utf-8)))
    (message "egadjit: %d forms on %s" (length (alist-get 'forms egadjit--index)) egadjit-node)
    egadjit--index))

(defun egadjit--form-entry (path)
  (seq-find (lambda (f) (equal (alist-get 'path f) path)) (alist-get 'forms egadjit--index)))

;;;###autoload
(defun egadjit-open-form (path)
  "Fetch form PATH into a read-only buffer; verify its SHA-256 against the index."
  (interactive (list (completing-read "Form: " (mapcar (lambda (f) (alist-get 'path f))
                                                        (alist-get 'forms (or egadjit--index (egadjit-refresh-index)))))))
  (unless egadjit--index (egadjit-refresh-index))
  (let* ((entry (egadjit--form-entry path))
         (raw (egadjit--fetch path))
         (sha (secure-hash 'sha256 raw))
         (ok (equal sha (alist-get 'sha256 entry)))
         (buf (get-buffer-create (format "*egadjit: %s*" path))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (decode-coding-string raw 'utf-8))
        (goto-char (point-min)))
      (funcall (or (alist-get (alist-get 'lang entry) egadjit-mode-alist nil nil #'equal) #'fundamental-mode))
      (setq header-line-format
            (format " %s  [%s]  %s" (if ok "sha256 OK" "sha256 MISMATCH -- do not use")
                    (alist-get 'headline entry "") (alist-get 'guidance entry "")))
      (read-only-mode 1))
    (pop-to-buffer buf)
    (unless ok (warn "egadjit: %s does not match the index's sha256" path))))

(define-derived-mode egadjit-list-mode tabulated-list-mode "egadjit"
  "List the tool forms on a trusted egad node."
  (setq tabulated-list-format [("Form" 32 t) ("Lang" 8 t) ("Bytes" 7 t :right-align t) ("From" 40 t)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun egadjit-list--entries ()
  (mapcar (lambda (f)
            (let ((p (alist-get 'path f)))
              (list p (vector p (alist-get 'lang f "") (number-to-string (alist-get 'bytes f 0))
                              (alist-get 'headline f "")))))
          (alist-get 'forms egadjit--index)))

(defun egadjit-list-open ()
  "Open the form at point."
  (interactive)
  (egadjit-open-form (tabulated-list-get-id)))

(define-key egadjit-list-mode-map (kbd "RET") #'egadjit-list-open)
(define-key egadjit-list-mode-map (kbd "g") #'egadjit-list-forms)

;;;###autoload
(defun egadjit-list-forms ()
  "Show every tool form the trusted node offers."
  (interactive)
  (egadjit-refresh-index)
  (with-current-buffer (get-buffer-create "*egadjit forms*")
    (egadjit-list-mode)
    (setq tabulated-list-entries #'egadjit-list--entries)
    (tabulated-list-print t)
    (pop-to-buffer (current-buffer))))

(provide 'egadjit)

;;; egadjit.el ends here
