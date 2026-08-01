;;; tools/agent-shell/config.el -*- lexical-binding: t; -*-

;;; --------------------------------------------------------------------------
;;; agent-shell + Pi coding agent (primary) + Claude (fallback)
;;; --------------------------------------------------------------------------
;;
;; Pi is the primary agent interface via pi-acp (ACP adapter).
;; Claude Code remains available as a secondary agent.
;; claude-code-ide provides Emacs MCP tools server — xref, project
;; navigation, tree-sitter, diagnostics, imenu — so agents inside
;; agent-shell become Emacs-aware.
;;
;; Requires: pi-acp (managed by Home Manager, see modules/pi.nix)

(use-package! agent-shell
  :defer t
  :commands (agent-shell
             agent-shell-pi-start-agent
             agent-shell-anthropic-start-claude-code
             agent-shell-caveman-start)
  :config
  ;; Evil keybindings: RET always submits, M-j inserts newline.
  ;; Must use a mode-hook with local-set-key to override all layers
  ;; (evil-collection, comint, shell-maker) that fight over RET.
  (add-hook 'agent-shell-mode-hook
            (lambda ()
              (evil-local-set-key 'insert (kbd "RET") #'shell-maker-submit)
              (evil-local-set-key 'insert (kbd "<return>") #'shell-maker-submit)
              (evil-local-set-key 'normal (kbd "RET") #'shell-maker-submit)
              (evil-local-set-key 'normal (kbd "<return>") #'shell-maker-submit)
              (evil-local-set-key 'insert (kbd "M-j") #'newline)))

  ;; WORKAROUND: Bootstrap finishes with shell-maker--busy stuck as t
  ;; (due to finish-output :success nil). Clear it before execution.
  (advice-add 'shell-maker--clear-input-for-execution :around
              (lambda (orig-fn &rest args)
                (setq shell-maker--busy nil)
                (apply orig-fn args)))

  ;; --- Claude Code (primary agent) ---
  (setq agent-shell-anthropic-default-model-id "anthropic.claude-opus-4-6-v1")
  (setq agent-shell-anthropic-claude-environment
        (agent-shell-make-environment-variables
         "ANTHROPIC_BASE_URL" "http://127.0.0.1:8787"
         "ANTHROPIC_AUTH_TOKEN" "***PURGED-ROTATED-CREDENTIAL***"
         "ANTHROPIC_DEFAULT_OPUS_MODEL" "anthropic.claude-opus-4-6-v1"
         "ANTHROPIC_DEFAULT_SONNET_MODEL" "anthropic.claude-sonnet-4-6"
         "ANTHROPIC_DEFAULT_HAIKU_MODEL" "anthropic.claude-haiku-4-5-20251001-v1:0"
         "ANTHROPIC_MODEL" "anthropic.claude-opus-4-6-v1"
         "ANTHROPIC_SMALL_FAST_MODEL" "anthropic.claude-haiku-4-5-20251001-v1:0"
         "CLAUDE_CODE_SUBAGENT_MODEL" "anthropic.claude-opus-4-6-v1"
         "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "1"
         "CLAUDE_CODE_EXECUTABLE" (executable-find "claude")))
  (setq agent-shell-anthropic-authentication
        (agent-shell-anthropic-make-authentication :api-key "dummy"))
  (setq agent-shell-preferred-agent-config
        (agent-shell-anthropic-make-claude-code-config))

  ;; --- Pi (disabled — out-of-turn ACP bug in Pi v0.79.8) ---
  ;; (setq agent-shell-preferred-agent-config
  ;;       (agent-shell-pi-make-agent-config))

  ;; --- Caveman Code (Pi fork, routes through Headroom proxy) ---
  (setq agent-shell-caveman-environment
        (agent-shell-make-environment-variables
         "PI_ACP_PI_COMMAND" "caveman-code"
         "PI_CODING_AGENT_DIR" (expand-file-name "~/.cave/agent")))

  (defun agent-shell-caveman-make-agent-config ()
    "Create a Caveman Code agent configuration via pi-acp."
    (agent-shell-make-agent-config
     :identifier 'caveman
     :mode-line-name "Cave"
     :buffer-name "Caveman"
     :shell-prompt "Cave> "
     :shell-prompt-regexp "Cave> "
     :welcome-function (lambda (_config) "Caveman Code (via Headroom proxy)")
     :client-maker (lambda (buffer)
                     (agent-shell--make-acp-client
                      :command "pi-acp"
                      :command-params nil
                      :environment-variables agent-shell-caveman-environment
                      :context-buffer buffer))
     :install-instructions "npm i -g @juliusbrussee/caveman-code"))

  (defun agent-shell-caveman-start ()
    "Start an interactive Caveman Code agent shell."
    (interactive)
    (agent-shell--dwim :config (agent-shell-caveman-make-agent-config)
                       :new-shell t))

  ;; --- Shared agent-shell settings ---
  (setq agent-shell-session-strategy 'new)
  (setq agent-shell-show-welcome-message nil)
  (setq agent-shell-permission-responder-function
        #'agent-shell-permission-allow-always)

  ;; MCP servers: expose Emacs MCP tools to agents.
  (setq agent-shell-mcp-servers
        `(,@(when (locate-library "claude-code-ide-emacs-tools")
              `(((name . "emacs")
                 (type . "http")
                 (headers . ())
                 (url . ,(lambda ()
                           (require 'claude-code-ide-emacs-tools)
                           (claude-code-ide-emacs-tools-setup)
                           (let* ((project-dir (agent-shell-cwd))
                                  (session-id (format "agent-shell-%s-%s"
                                                (file-name-nondirectory
                                                  (directory-file-name project-dir))
                                                (format-time-string "%Y%m%d-%H%M%S")))
                                  (port (claude-code-ide-mcp-server-ensure-server)))
                             (unless port
                               (error "claude-code-ide MCP server failed to start"))
                             (puthash session-id `(:project-dir ,project-dir)
                                      claude-code-ide-mcp-server--sessions)
                             (format "http://localhost:%d/mcp/%s" port session-id)))))))
          ((name . "emcp")
           (type . "http")
           (headers . ())
           (url . ,(lambda ()
                     (require 'emcp)
                     (let ((server (emcp-start emcp-default-profile)))
                       (emcp-server-url server)))))))
  )

;;; --------------------------------------------------------------------------
;;; emcp (works independently of agent-shell backend)
;;; --------------------------------------------------------------------------

(use-package! emcp
  :config
(setq emcp-http-port 38913)
(setq emcp-tools-eval-default-policy 'allow)
(setq emcp-tools-send-keys-default-policy 'allow))


;;; --------------------------------------------------------------------------
;;; agent-shell ecosystem packages
;;; --------------------------------------------------------------------------
;;
;; Build-time deps injected via emacsPackageOverrides in doom-emacs.nix.

;; agent-shell-manager: tabulated dashboard of all agent-shell buffers
(use-package! agent-shell-manager
  :after agent-shell
  :commands (agent-shell-manager-toggle)
  :config
  (setq agent-shell-manager-side 'left))

;; agent-shell-sidebar: persistent side panel for agent-shell
(use-package! agent-shell-sidebar
  :after agent-shell
  :commands (agent-shell-sidebar-toggle
             agent-shell-sidebar-toggle-focus
             agent-shell-sidebar-change-provider
             agent-shell-sidebar-reset)
  :config
  (setq agent-shell-sidebar-width "30%"
        agent-shell-sidebar-position 'right
        agent-shell-sidebar-default-config
        (agent-shell-anthropic-make-claude-code-config)))

;; agent-shell-bookmark: bookmark and org-link support for sessions
(use-package! agent-shell-bookmark
  :after agent-shell
  :demand t)

;; agent-review: AI-powered code review via a second agent
(use-package! agent-review
  :after agent-shell
  :commands (agent-review agent-review-region)
  :config
  (setq agent-review-git-executable "git"))

;; agent-shell-attention: mode-line indicator for pending agent activity
(use-package! agent-shell-attention
  :after agent-shell
  :config
  (agent-shell-attention-mode 1))

;; agent-shell-notifications: desktop notifications for agent events
(use-package! agent-shell-notifications
  :after agent-shell
  :hook (agent-shell-mode . agent-shell-notifications-mode)
  :config
  (setq agent-shell-notifications-idle-timeout 15))

;; agent-shell-org-transcript: save transcripts as org-mode files
(use-package! agent-shell-org-transcript
  :after agent-shell
  :demand t
  :config
  (setq agent-shell-org-transcript-directory "~/org/agent-shell/"))

;; ob-agent-shell: org-babel backend for agent-shell source blocks
(use-package! ob-agent-shell
  :after (org agent-shell)
  :config
  (add-to-list 'org-babel-load-languages '(agent-shell . t))
  (org-babel-do-load-languages 'org-babel-load-languages org-babel-load-languages))

;; agent-recall: search, browse, and resume conversation transcripts
(use-package! agent-recall
  :after agent-shell
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :commands (agent-recall-search
             agent-recall-search-live
             agent-recall-browse
             agent-recall-resume
             agent-recall-stats
             agent-recall-reindex
             agent-recall-backfill)
  :config
  (setq agent-recall-search-paths '("~/org/agent-shell")
        agent-recall-search-function 'consult-ripgrep
        agent-recall-browse-sort 'modified-desc
        agent-recall-extra-transcript-dirs
        '((:dir "~/org/agent-shell/"))))

;; meta-agent-shell: multi-agent coordination with inter-agent communication
(use-package! meta-agent-shell
  :after agent-shell
  :commands (meta-agent-shell-dispatch
             meta-agent-shell-status)
  :config
  (setq meta-agent-shell-directory "~/.claude-meta/"
        meta-agent-shell-log-directory "~/.meta-agent-shell/logs/"))

;; claude-code-ide: Emacs MCP tools server (independent of agent-shell)
(use-package! claude-code-ide
  :defer t)
