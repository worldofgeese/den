;;; tools/agent-shell/config.el -*- lexical-binding: t; -*-

;;; --------------------------------------------------------------------------
;;; agent-shell + Claude Code / Oh My Pi
;;
;; claude-code-ide provides Emacs MCP tools server — xref, project
;; navigation, tree-sitter, diagnostics, imenu — so agents inside
;; agent-shell become Emacs-aware.

(use-package! agent-shell
  :defer t
  :commands (agent-shell
             agent-shell-anthropic-start-claude-code
             agent-shell-github-start-copilot
             agent-shell-omp-start)
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

  ;; --- Model gateway ---
  ;;
  ;; Both values are substituted from Nix at build time (see
  ;; modules/doom-emacs.nix); the placeholders below are never what ships.
  ;; The key is resolved when an agent process starts, not when this file
  ;; loads, so a locked keyring does not break Emacs startup -- and a missing
  ;; key raises here instead of arriving as a 400 mid-session.

  (defvar lego-gateway-base-url "@GATEWAY_BASE_URL@"
    "Base URL of the model gateway agent-shell talks to.")

  (defvar lego-gateway-key-command "@GATEWAY_KEY_COMMAND@"
    "Shell command printing the gateway API key on stdout.")

  ;; Model ids are substituted from modules/doom-emacs.nix so Claude Code
  ;; follows LEGO AI Model Gateway's current model generation.

  (defvar lego-gateway-opus-model "@GATEWAY_OPUS_MODEL@"
    "Gateway id for the model Claude Code treats as Opus.")

  (defvar lego-gateway-sonnet-model "@GATEWAY_SONNET_MODEL@"
    "Gateway id for the model Claude Code treats as Sonnet.")

  (defvar lego-gateway-haiku-model "@GATEWAY_HAIKU_MODEL@"
    "Gateway id for the model Claude Code treats as Haiku.")

  (defvar lego-gateway--key-cache nil
    "Resolved gateway key, cached for the Emacs session.")

  (defun lego-gateway-key (&optional refresh)
    "Return the gateway API key via `lego-gateway-key-command'.
With REFRESH non-nil, discard the cached value first.  Signals a
`user-error' when the command fails or prints nothing."
    (interactive "p")
    (when refresh (setq lego-gateway--key-cache nil))
    (or lego-gateway--key-cache
        (setq lego-gateway--key-cache
              (with-temp-buffer
                (let* ((status (call-process-shell-command
                                lego-gateway-key-command nil t))
                       (output (string-trim (buffer-string))))
                  (cond
                   ((not (eq status 0))
                    (user-error "Gateway key lookup failed (exit %s): %s: %s"
                                status lego-gateway-key-command output))
                   ((string-empty-p output)
                    (user-error "Gateway key lookup printed nothing: %s"
                                lego-gateway-key-command))
                   (t output)))))))

  (defun lego-gateway-claude-environment ()
    "Environment for the Claude client, with the gateway key resolved now."
    (agent-shell-make-environment-variables
     "ANTHROPIC_BASE_URL" lego-gateway-base-url
     "ANTHROPIC_AUTH_TOKEN" (lego-gateway-key)
     "ANTHROPIC_DEFAULT_OPUS_MODEL" lego-gateway-opus-model
     "ANTHROPIC_DEFAULT_SONNET_MODEL" lego-gateway-sonnet-model
     "ANTHROPIC_DEFAULT_HAIKU_MODEL" lego-gateway-haiku-model
     "ANTHROPIC_MODEL" lego-gateway-opus-model
     "ANTHROPIC_SMALL_FAST_MODEL" lego-gateway-haiku-model
     "CLAUDE_CODE_SUBAGENT_MODEL" lego-gateway-opus-model
     "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "1"
     "CLAUDE_CODE_EXECUTABLE" (executable-find "claude")))

  ;; agent-shell reads `agent-shell-anthropic-claude-environment' inside
  ;; `agent-shell-anthropic-make-claude-client', i.e. at process start -- so
  ;; refreshing it there covers every entry point (dwim, sidebar, manager)
  ;; without any of them resolving the key at load time.
  (defun lego-gateway-refresh-claude-environment (&rest _)
    (setq agent-shell-anthropic-claude-environment
          (lego-gateway-claude-environment)))
  (advice-add 'agent-shell-anthropic-make-claude-client :before
              #'lego-gateway-refresh-claude-environment)

  ;; --- Claude Code (primary agent) ---
  (setq agent-shell-anthropic-default-model-id lego-gateway-opus-model)
  (setq agent-shell-anthropic-authentication
        (agent-shell-anthropic-make-authentication :api-key "dummy"))
  (setq agent-shell-preferred-agent-config
        (agent-shell-anthropic-make-claude-code-config))

  ;; OMP remains user-installed; agent-shell launches its native ACP server.
  (defcustom agent-shell-omp-acp-command '("omp" "acp")
    "Command and parameters for the Oh My Pi ACP server."
    :type '(repeat string)
    :group 'agent-shell)

  (defun agent-shell-omp-make-client (buffer)
    "Create an Oh My Pi ACP client for BUFFER."
    (agent-shell--make-acp-client
     :command (car agent-shell-omp-acp-command)
     :command-params (cdr agent-shell-omp-acp-command)
     :context-buffer buffer))

  (defun agent-shell-omp-make-config ()
    "Create an Oh My Pi agent configuration."
    (agent-shell-make-agent-config
     :identifier 'omp
     :mode-line-name "OMP"
     :buffer-name "OMP"
     :shell-prompt "OMP> "
     :shell-prompt-regexp "OMP> "
     :client-maker #'agent-shell-omp-make-client
     :install-instructions "Install Oh My Pi and ensure `omp' is on PATH."))

  (defun agent-shell-omp-start ()
    "Start an interactive Oh My Pi agent shell."
    (interactive)
    (agent-shell--dwim :config (agent-shell-omp-make-config)
                       :new-shell t))

  ;; --- Shared agent-shell settings ---
  (setq agent-shell-session-strategy 'new)
  (setq agent-shell-show-welcome-message nil)
  (setq agent-shell-permission-responder-function
        #'agent-shell-permission-allow-always)

  ;; MCP servers: expose Emacs MCP tools to agents.
  (setq agent-shell-mcp-servers
        `(((name . "nixos")
           (command . ,(or (executable-find "mcp-nixos") "mcp-nixos"))
           (args . ())
           (env . ()))
          ,@(when (locate-library "claude-code-ide-emacs-tools")
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
                     (emcp-server-url (emcp-start emcp-default-profile))))))))

;;; --------------------------------------------------------------------------
;;; emcp (works independently of agent-shell backend)
;;; --------------------------------------------------------------------------

(use-package! emcp
  :config
  (setq emcp-default-profile 'full-control)
  (setq emcp-http-port 38913))


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
