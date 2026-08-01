;; -*- no-byte-compile: t; -*-
;;; tools/agent-shell/packages.el

;; agent-shell (ACP-powered LLM agents in Emacs)
(package! shell-maker)
(package! acp)
(package! agent-shell)
(package! emcp)

;; agent-shell ecosystem packages
;; Build-time deps injected via emacsPackageOverrides in doom-emacs.nix
(package! agent-shell-manager
  :recipe (:host github :repo "jethrokuan/agent-shell-manager")
  :pin "53b73f13ed1ac9d2de128465a8504a7265490ea7")
(package! agent-shell-sidebar
  :recipe (:host github :repo "cmacrae/agent-shell-sidebar")
  :pin "10fee0b1463cdf210b0908c23e940a44c8d4a8e2")
(package! agent-shell-bookmark
  :recipe (:host github :repo "dcluna/agent-shell-bookmark")
  :pin "c1eab34bff4f35bf929885ed5045c6100afcf496")
(package! agent-review
  :recipe (:host github :repo "nineluj/agent-review")
  :pin "df684c4558f0fd83bd81a58503235ab62fd37af5")
(package! agent-shell-attention
  :recipe (:host github :repo "ultronozm/agent-shell-attention.el")
  :pin "18e580806775b41a9c899e79c6765f4d937913e7")
(package! agent-shell-notifications
  :recipe (:host github :repo "zackattackz/agent-shell-notifications")
  :pin "fbf7a6b8c16326242d6e07430b7a8f5e84442466")
(package! agent-shell-org-transcript
  :recipe (:host github :repo "lllShamanlll/agent-shell-org-transcript")
  :pin "93a6daa466363aab53af5b013a083d79c88e1f09")
(package! ob-agent-shell
  :recipe (:host github :repo "eddof13/ob-agent-shell")
  :pin "27165d21b8975788f35e4b4b4a8aa2589ae615fe")
(package! agent-recall
  :recipe (:host github :repo "Marx-A00/agent-recall")
  :pin "cd1eb493ad911e1907588b559ea79cd899f2d6d1")
(package! meta-agent-shell
  :recipe (:host github :repo "ElleNajt/meta-agent-shell")
  :pin "d1f4622b0f99105d7be2dd38a714fe7b9b5f49f5")

;; claude-code-ide (Emacs MCP tools server — independent of agent-shell)
(package! claude-code-ide
  :recipe (:host github :repo "manzaltu/claude-code-ide.el")
  :pin "a9485f766ea69f6cb3a3f08dea20d44fd6596673")
