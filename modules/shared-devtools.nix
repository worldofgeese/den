{den, ...}: {
  # Shared developer tooling aspect — packages and programs used on both
  # mahakala (Linux workstation) and M-02877 (macOS work machine).
  # Host-specific additions go in workstation.nix or dktaohan.nix.
  den.aspects.sharedDevtools = {
    includes = [den.aspects.devtools];
    homeManager = {
      pkgs,
      lib,
      ...
    }: {
      home.packages = with pkgs; [
        nodejs
        bun
        uv
        kubectl
        shellcheck
        yq-go
        glab
        just
        claude-code
        pi-coding-agent
        rtk
        decapod
        beads
      ];

      programs.github-copilot-cli.enable = true;
      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      programs.eza.enable = true;
      programs.bat.enable = true;
      programs.zoxide.enable = true;
      programs.jq.enable = true;

      programs.atuin = {
        enable = true;
        settings = {
          auto_sync = lib.mkDefault true;
          sync_frequency = "5m";
          search_mode = "fuzzy";
        };
      };

      programs.k9s.enable = true;

      # Pi extension: custom provider for Anthropic proxy with full
      # streaming implementation (supports reasoning/thinking blocks)
      home.file.".pi/agent/extensions/anthropic-proxy/index.js".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/index.js;
      home.file.".pi/agent/extensions/anthropic-proxy/package.json".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/package.json;
      home.file.".pi/agent/extensions/anthropic-proxy/models.json".text = builtins.toJSON [
        {
          id = "anthropic.claude-opus-4-6-v1";
          name = "Opus 4.6";
          reasoning = true;
          input = [ "text" "image" ];
          cost = { input = 15; output = 75; cacheRead = 1.5; cacheWrite = 18.75; };
          contextWindow = 200000;
          maxTokens = 128000;
        }
        {
          id = "anthropic.claude-sonnet-4-6";
          name = "Sonnet 4.6";
          reasoning = true;
          input = [ "text" "image" ];
          cost = { input = 3; output = 15; cacheRead = 0.3; cacheWrite = 3.75; };
          contextWindow = 200000;
          maxTokens = 128000;
        }
        {
          id = "anthropic.claude-haiku-4-5-20251001-v1:0";
          name = "Haiku 4.5";
          reasoning = false;
          input = [ "text" "image" ];
          cost = { input = 0.8; output = 4; cacheRead = 0.08; cacheWrite = 1; };
          contextWindow = 200000;
          maxTokens = 64000;
        }
      ];

      # Pi subagent model assignments: patch model: into agent frontmatter
      # Runs after activation so it survives `pi update` regenerating files.
      # Tiered: Opus for deep reasoning, Sonnet for general, Haiku for exploration.
      home.file.".pi/agent/subagent-models.sh" = {
        executable = true;
        text = ''
          #!/usr/bin/env bash
          # Patch model: frontmatter into pi-subagents agent definitions.
          # Idempotent — safe to re-run after pi update.
          set -euo pipefail

          AGENTS_DIR="$HOME/.pi/agent/agents"
          [[ -d "$AGENTS_DIR" ]] || exit 0

          OPUS="anthropic-proxy/anthropic.claude-opus-4-6-v1"
          SONNET="anthropic-proxy/anthropic.claude-sonnet-4-6"
          HAIKU="anthropic-proxy/anthropic.claude-haiku-4-5-20251001-v1:0"

          # Opus: adversarial/architectural/deep reasoning
          OPUS_AGENTS="ce-adversarial-reviewer ce-adversarial-document-reviewer ce-architecture-strategist ce-feasibility-reviewer ce-product-lens-reviewer artifact-reviewer slice-verifier codebase-analyzer"

          # Haiku: exploration/locating (fast, cheap)
          HAIKU_AGENTS="codebase-locator codebase-pattern-finder artifacts-locator scope-tracer integration-scanner test-case-locator"

          get_model() {
            local name="$1"
            for a in $OPUS_AGENTS; do [[ "$name" == "$a" ]] && echo "$OPUS" && return; done
            for a in $HAIKU_AGENTS; do [[ "$name" == "$a" ]] && echo "$HAIKU" && return; done
            echo "$SONNET"
          }

          for file in "$AGENTS_DIR"/*.md; do
            [[ -f "$file" ]] || continue
            name="$(basename "$file" .md)"
            model="$(get_model "$name")"

            if head -1 "$file" | grep -q '^---$'; then
              if grep -q '^model:' "$file"; then
                # Replace existing model line
                sed -i "s|^model:.*|model: $model|" "$file"
              else
                # Insert model: before closing ---
                sed -i "0,/^---$/! { /^---$/ i\model: $model
                }" "$file"
              fi
            fi
          done
        '';
      };

      home.activation.patchPiSubagentModels = ''
        run $HOME/.pi/agent/subagent-models.sh
      '';

      # Pi settings: default to the proxy provider with Opus
      home.file.".pi/agent/settings.json".text = builtins.toJSON {
        provider = "anthropic-proxy";
        model = "anthropic.claude-opus-4-6-v1";
        defaultThinkingLevel = "xhigh";
        packages = [
          "npm:context-mode"
          "npm:@juicesharp/rpiv-pi"
          "npm:@juicesharp/rpiv-todo"
          "npm:@juicesharp/rpiv-advisor"
          "npm:@juicesharp/rpiv-i18n"
          "npm:@juicesharp/rpiv-web-tools"
          "npm:@juicesharp/rpiv-args"
          "npm:@tintinweb/pi-subagents"
          "npm:@juicesharp/rpiv-ask-user-question"
          "npm:pi-rtk-optimizer"
          "npm:pi-beads-extension"
          "npm:@joemccann/pi-pdf"
          "npm:@feniix/pi-specdocs"
          "npm:@earendil-works/pi-ai"
          "npm:@earendil-works/pi-coding-agent"
        ];
      };
    };
  };
}
