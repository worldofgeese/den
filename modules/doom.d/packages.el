;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

;; To install a package with Doom you must declare them here and run 'doom sync'
;; on the command line, then restart Emacs for the changes to take effect -- or
;; use 'M-x doom/reload'.

;; howm: personal wiki / note-taking (LLM-wiki substrate)
(package! howm)

;; git-auto-commit-mode: auto-commit on save for backup
(package! git-auto-commit-mode)

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

;; tramp-rpc: high-performance TRAMP backend via binary RPC
(package! msgpack)
(package! tramp-rpc
  :recipe (:host github :repo "ArthurHeymans/emacs-tramp-rpc" :files ("lisp/*.el")))
