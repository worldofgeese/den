;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

;; To install a package with Doom you must declare them here and run 'doom sync'
;; on the command line, then restart Emacs for the changes to take effect -- or
;; use 'M-x doom/reload'.

;; howm: personal wiki / note-taking (LLM-wiki substrate)
(package! howm)

;; git-auto-commit-mode was removed 2026-11-19 (ADR-0006 addendum): its
;; synchronous per-file commit was the source of the stale index.lock that
;; killed every sync layer for 18 days, and a second save-triggered
;; mechanism would race the serialised one. Save-triggered sync now runs
;; debounced and asynchronously through bin/howm-sync (howm-auto-sync-mode
;; in config.el).

;; denote: predictable file-naming + signatures for folgezettel
(package! denote)
(package! denote-sequence
  :recipe (:host github :repo "protesilaos/denote-sequence")
  :pin "841cf148a56a6c62fb483d5529a45c689b04049e")

;; emacs-reader: MuPDF-powered document reader (replaces nov.el + pdf-tools)
(package! reader
  :recipe (:host nil :type git
           :repo "https://codeberg.org/MonadicSheep/emacs-reader"
           :files (:defaults "render-core.so")))

;; ghostel: libghostty-vt terminal emulator (replaces vterm)
;; BLOCKED: zig dep fetch from deps.files.ghostty.org fails (HttpConnectionClosing)
;; Available as nixpkgs#emacsPackages.ghostel — enable when binary cache has it
;; (package! ghostel)

