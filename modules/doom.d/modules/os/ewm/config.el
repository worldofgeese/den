;;; os/ewm/config.el -*- lexical-binding: t; -*-
;;; Commentary:
;; EWM (Emacs Wayland Manager) — Wayland compositor as Emacs dynamic module.
;; Built via Nix flake, installed to home-manager profile.

;; Add EWM from home-manager profile to load-path
(let ((ewm-site-lisp
       (expand-file-name "home-path/share/emacs/site-lisp"
                         (file-name-directory (directory-file-name
                           (file-truename "~/.local/state/nix/profiles/home-manager"))))))
  (when (file-directory-p ewm-site-lisp)
    (add-to-list 'load-path ewm-site-lisp)))

;; Doom daemon fix: fire server-after-make-frame-hook on first graphical frame
;; (EWM creates frames via make-frame, not emacsclient)
(when (daemonp)
  (add-hook 'after-make-frame-functions
            (defun +ewm-trigger-server-hooks-h (frame)
              (when (display-graphic-p frame)
                (remove-hook 'after-make-frame-functions #'+ewm-trigger-server-hooks-h)
                (with-selected-frame frame
                  (run-hooks 'server-after-make-frame-hook))))))

(use-package! ewm
  :bind (:map ewm-mode-map
         ("s-h" . ewm-focus-left)
         ("s-j" . ewm-focus-down)
         ("s-k" . ewm-focus-up)
         ("s-l" . ewm-focus-right)
         ("s-b" . consult-buffer)
         ("s-&" . async-shell-command))
  :custom
  (ewm-intercept-prefixes '("C-x" "C-u" "C-h" "M-x" "M-SPC"
                             ("<Print>" :fullscreen)
                             ("s-f" :fullscreen)
                             ("<MonBrightnessUp>" :fullscreen)
                             ("<MonBrightnessDown>" :fullscreen)
                             ("<AudioRaiseVolume>" :fullscreen)
                             ("<AudioLowerVolume>" :fullscreen)
                             ("<AudioMute>" :fullscreen)
                             ("<AudioMicMute>" :fullscreen)))
  :config
  ;; Doom leader via M-SPC in EWM managed buffers
  (define-key ewm-mode-map (kbd "M-SPC") doom-leader-map))
