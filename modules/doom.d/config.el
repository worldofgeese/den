
;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

(setq doom-theme 'doom-one)
(setq doom-font (font-spec :family "FiraCode Nerd Font" :size 14))
(setq display-line-numbers-type t)
(setq org-directory "~/org/")

;;; --------------------------------------------------------------------------
;;; howm — personal wiki / LLM-wiki substrate
;;; --------------------------------------------------------------------------

(use-package! howm
  :defer t
  :init
  (setq howm-follow-theme t)
  ;; Directory configuration (needed before load for keyword/history paths)
  (setq howm-home-directory "~/Downloads/projects/howm/")
  (setq howm-directory "~/Downloads/projects/howm/")
  (setq howm-keyword-file (expand-file-name ".howm-keys" howm-home-directory))
  (setq howm-history-file (expand-file-name ".howm-history" howm-home-directory))
  :config
  ;; Use ripgrep for searching (only .org files, exclude sources/)
  (setq howm-view-use-grep t)
  (setq howm-view-grep-command "rg")
  (setq howm-view-grep-option "-nH --no-heading --color never --glob *.org --glob !sources/")
  (setq howm-view-grep-extended-option nil)
  (setq howm-view-grep-fixed-option "-F")
  (setq howm-view-grep-expr-option nil)
  (setq howm-view-grep-file-stdin-option nil)

  ;; Sorting: recent by mtime, all by creation date
  (advice-add 'howm-list-recent :after #'howm-view-sort-by-mtime)
  (advice-add 'howm-list-all :after #'(lambda () (howm-view-sort-by-date t)))

  ;; Rename buffers to their title
  (add-hook 'howm-mode-hook #'howm-mode-set-buffer-name)
  (add-hook 'after-save-hook #'howm-mode-set-buffer-name)

  ;; Fix C-h binding conflict (howm overrides help)
  (define-key howm-menu-mode-map "\C-h" nil)
  (define-key riffle-summary-mode-map "\C-h" nil)
  (define-key howm-view-contents-mode-map "\C-h" nil)

  ;; Custom capture commands for LLM-wiki directory structure
  (defun howm-create-in-inbox ()
    "Create a new fleeting note in inbox/."
    (interactive)
    (let ((howm-file-name-format "inbox/%Y-%m-%d-%H%M%S.org"))
      (howm-create-file)))

  (defun howm-create-in-zettelkasten ()
    "Create a new permanent note in zettelkasten/."
    (interactive)
    (let ((howm-file-name-format "zettelkasten/%Y-%m-%d-%H%M%S.org"))
      (howm-create-file)))

  (defun howm-create-in-journal ()
    "Create or open today's journal entry in journal/."
    (interactive)
    (let* ((today-file (expand-file-name
                        (format-time-string "journal/%Y-%m-%d.org")
                        howm-directory)))
      (if (file-exists-p today-file)
          (find-file today-file)
        (find-file today-file)
        (insert (format-time-string "* Journal: %Y-%m-%d\n\n")))))

  (defun howm-create-in-references ()
    "Create a new reference note in references/ using Denote naming.
Prompts for source type: book (page table) or conversation (bullet list)."
    (interactive)
    (let* ((type (completing-read "Source type: " '("book" "conversation") nil t))
           (author (read-string "Author(s) (Last, F.): "))
           (denote-directory (expand-file-name "references/" howm-directory)))
      (pcase type
        ("book"
         (let* ((year (read-string "Year: "))
                (title (read-string "Title: "))
                (denote-title (format "%s %s %s" author year title)))
           (denote denote-title '("literature") 'org)
           (goto-char (point-max))
           (insert (format "\n* %s (%s). /%s/.\n\n" author year title))
           (insert "| Page | Note |\n")
           (insert "|------+------|\n")
           (insert "|      |      |\n")
           (org-table-align)
           (goto-char (point-max))
           (search-backward "|" nil t 2)
           (forward-char 2)))
        ("conversation"
         (let* ((date (read-string "Date (MM/DD/YY): "
                                   (format-time-string "%m/%d/%y")))
                (context (read-string "Context (where/what): "))
                (denote-title (format "%s %s conversation" author date)))
           (denote denote-title '("literature") 'org)
           (goto-char (point-max))
           (insert (format "\n* %s (%s). Conversation.\n\n" author date))
           (insert (format "%s. Topics discussed:\n\n- " context)))))))

  ;; Activate howm-mode on any .org file opened under howm-directory
  (add-hook 'find-file-hook #'howm-set-mode)

  ;; Evil-mode shadows action-lock's C-m binding; re-bind RET in normal state
  (evil-define-key 'normal howm-mode-map (kbd "RET") #'action-lock-magic-return)
  (evil-define-key 'normal howm-mode-map (kbd "TAB") #'action-lock-goto-next-link)
  (evil-define-key 'normal howm-mode-map (kbd "<backtab>") #'action-lock-goto-previous-link)
  (add-hook 'howm-mode-hook #'evil-normalize-keymaps)

  ;; Summary buffer (search results list)
  (add-hook 'howm-view-summary-mode-hook
            (lambda ()
              (evil-local-set-key 'normal (kbd "RET") #'action-lock-magic-return)
              (evil-local-set-key 'normal (kbd "SPC") #'riffle-pop-or-scroll-other-window)
              (evil-local-set-key 'normal (kbd "DEL") #'scroll-other-window-down)
              (evil-local-set-key 'normal (kbd "@") #'riffle-summary-to-contents)
              (evil-local-set-key 'normal (kbd "p") #'howm-view-summary-peek)
              (evil-local-set-key 'normal (kbd "s") #'howm-view-filter-by-contents)
              (evil-local-set-key 'normal (kbd "S") #'howm-view-sort)
              (evil-local-set-key 'normal (kbd "R") #'howm-view-sort-reverse)
              (evil-local-set-key 'normal (kbd "f") #'howm-view-filter)
              (evil-local-set-key 'normal (kbd "u") #'howm-view-filter-uniq)
              (evil-local-set-key 'normal (kbd "T") #'howm-list-title)
              (evil-local-set-key 'normal (kbd ".") #'howm-reminder-goto-today)
              (evil-local-set-key 'normal (kbd "q") #'howm-view-kill-buffer)))

  ;; Contents buffer (search results with previews)
  (add-hook 'howm-view-contents-mode-hook
            (lambda ()
              (evil-local-set-key 'normal (kbd "RET") #'howm-view-contents-open)
              (evil-local-set-key 'normal (kbd "TAB") #'riffle-contents-goto-next-item)
              (evil-local-set-key 'normal (kbd "<backtab>") #'riffle-contents-goto-previous-item)
              (evil-local-set-key 'normal (kbd "@") #'riffle-contents-to-summary)
              (evil-local-set-key 'normal (kbd "s") #'howm-view-filter-by-contents)
              (evil-local-set-key 'normal (kbd "S") #'howm-view-sort)
              (evil-local-set-key 'normal (kbd "R") #'howm-view-sort-reverse)
              (evil-local-set-key 'normal (kbd "f") #'howm-view-filter)
              (evil-local-set-key 'normal (kbd "q") #'howm-view-kill-buffer)))

  ;; Keybindings under howm prefix (C-c ;)
  (define-key global-map (concat howm-prefix "c") #'howm-create-in-inbox)
  (define-key global-map (concat howm-prefix "z") #'howm-create-in-zettelkasten)
  (define-key global-map (concat howm-prefix "j") #'howm-create-in-journal)
  (define-key global-map (concat howm-prefix "r") #'howm-create-in-references)
  (define-key global-map (concat howm-prefix "s") #'howm-keyword-search))

;; Load howm-org then howm eagerly after init (correct ordering guaranteed)
(add-hook! 'doom-after-init-hook
  (require 'howm-org)
  (require 'howm))

;;; --------------------------------------------------------------------------
;;; git-auto-commit-mode — auto-backup howm repo on save
;;; --------------------------------------------------------------------------

(use-package! git-auto-commit-mode
  :defer t
  :init
  (setq gac-automatically-push-p t)
  (setq gac-debounce-interval 10)
  (setq gac-default-message "auto-backup %f"))

;;; --------------------------------------------------------------------------
;;; denote — file-naming with signatures (folgezettel) alongside howm
;;; --------------------------------------------------------------------------

(use-package! denote
  :defer t
  :init
  (setq denote-directory "~/Downloads/projects/howm/zettelkasten/")
  (setq denote-known-keywords '("moc"))
  (setq denote-prompts '(title keywords signature))
  (setq denote-file-type 'org)
  :config
  ;; Howm integration: show just ==SIGNATURE in basename column for Denote files.
  ;; Regular howm files (no ==) pass through unchanged.
  (defun my/howm-basename-chop (str)
    "For Denote files (containing ==), show only the signature."
    (if (string-match "\\`[0-9T]+==\\([^-]+\\)" str)
        (concat "==" (match-string 1 str))
      str))
  (advice-add 'howm-view-item-basename :filter-return #'my/howm-basename-chop)

  ;; Strip #+title: prefix from howm summary lines (Denote uses #+title:, not *)
  (defun my/howm-cut-title (str)
    "Remove #+title: prefix from howm item summaries."
    (if (string-match "^#\\+title:[[:space:]]*" str)
        (substring str (match-end 0))
      str))
  (advice-add 'howm-view-item-summary :filter-return #'my/howm-cut-title))

(use-package! denote-sequence
  :after denote
  :init
  (setq denote-sequence-scheme 'alphanumeric)
  :config
  (defun my/denote-zettel-new-parent ()
    "Create a new top-level folgezettel note in zettelkasten/."
    (interactive)
    (let ((denote-directory "~/Downloads/projects/howm/zettelkasten/"))
      (call-interactively #'denote-sequence-new-parent)))

  (defun my/denote-zettel-new-child ()
    "Create a child (branch) folgezettel note responding to the current note."
    (interactive)
    (let ((denote-directory "~/Downloads/projects/howm/zettelkasten/"))
      (call-interactively #'denote-sequence-new-child)))

  (defun my/denote-zettel-new-sibling ()
    "Create a sibling folgezettel note at the same level as the current note."
    (interactive)
    (let ((denote-directory "~/Downloads/projects/howm/zettelkasten/"))
      (call-interactively #'denote-sequence-new-sibling))))

;;; --------------------------------------------------------------------------
;;; emacs-reader — MuPDF-powered all-in-one document reader (pdf, epub, mobi)
;;; --------------------------------------------------------------------------

(use-package! reader
  :mode (("\\.pdf\\'" . reader-mode)
         ("\\.epub\\'" . reader-mode)
         ("\\.mobi\\'" . reader-mode)
         ("\\.fb2\\'" . reader-mode)
         ("\\.xps\\'" . reader-mode)
         ("\\.cbz\\'" . reader-mode)))

;;; --------------------------------------------------------------------------
;;; vterm (ghostel blocked — deps.files.ghostty.org unreachable)
;;; --------------------------------------------------------------------------

(after! vterm
  (setq vterm-max-scrollback 10000)
  (setq vterm-buffer-name-string "vterm: %s"))

;;; --------------------------------------------------------------------------
;;; tramp-rpc (high-performance TRAMP backend)
;;; --------------------------------------------------------------------------

(use-package! tramp-rpc
  :after tramp
  :config
  (advice-add 'tramp-rpc-deploy--ensure-local-binary :filter-return #'file-truename))


;;; --------------------------------------------------------------------------
;;; org-crypt — auto-encrypt journal entries
;;; --------------------------------------------------------------------------

(after! org-crypt
  (setq org-crypt-key "58892604DFA04187"))

(defun +journal-auto-crypt-tag ()
  "Add :crypt: tag to top-level headings in journal files."
  (when (and buffer-file-name
             (string-match-p "/journal/" buffer-file-name))
    (org-map-entries
     (lambda ()
       (unless (member "crypt" (org-get-tags))
         (org-set-tags (cons "crypt" (org-get-tags)))))
     "LEVEL=1")))

(add-hook 'org-mode-hook
          (lambda ()
            (when (and buffer-file-name
                       (string-match-p "/journal/" buffer-file-name))
              (add-hook 'before-save-hook #'+journal-auto-crypt-tag nil t))))

