{ den, ... }:
{
  # Shared developer tooling aspect — packages and programs used on both
  # mahakala (Linux workstation) and M-02877 (macOS work machine).
  # Host-specific additions go in workstation.nix or dktaohan.nix.
  den.aspects.sharedDevtools = {
    includes = [ den.aspects.devtools ];
    homeManager =
      {
        pkgs,
        lib,
        ...
      }:
      {
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
          pi
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
        home.file.".pi/agent/extensions/anthropic-proxy/message-conversion.js".text =
          builtins.readFile ../pi-extensions/anthropic-proxy/message-conversion.js;
        home.file.".pi/agent/extensions/anthropic-proxy/message-conversion.test.js".text =
          builtins.readFile ../pi-extensions/anthropic-proxy/message-conversion.test.js;
        home.file.".pi/agent/extensions/anthropic-proxy/package.json".text =
          builtins.readFile ../pi-extensions/anthropic-proxy/package.json;
        home.file.".pi/agent/extensions/anthropic-proxy/models.json".text = builtins.toJSON [
          {
            id = "anthropic.claude-opus-4-6-v1";
            name = "Opus 4.6";
            reasoning = true;
            input = [
              "text"
              "image"
            ];
            cost = {
              input = 15;
              output = 75;
              cacheRead = 1.5;
              cacheWrite = 18.75;
            };
            contextWindow = 200000;
            maxTokens = 128000;
          }
          {
            id = "anthropic.claude-sonnet-4-6";
            name = "Sonnet 4.6";
            reasoning = true;
            input = [
              "text"
              "image"
            ];
            cost = {
              input = 3;
              output = 15;
              cacheRead = 0.3;
              cacheWrite = 3.75;
            };
            contextWindow = 200000;
            maxTokens = 128000;
          }
          {
            id = "anthropic.claude-haiku-4-5-20251001-v1:0";
            name = "Haiku 4.5";
            reasoning = false;
            input = [
              "text"
              "image"
            ];
            cost = {
              input = 0.8;
              output = 4;
              cacheRead = 0.08;
              cacheWrite = 1;
            };
            contextWindow = 200000;
            maxTokens = 64000;
          }
        ];

        # Pi settings: parent session stays on the proxy provider with Opus.
        # Subagent model routing uses pi-subagents native agentOverrides.
        #   GLM-5.1          → planning, synthesis, careful review
        #   Kimi K2.6        → build/edit/resolution work
        #   MiMo V2.5 Pro    → adversarial and hard reasoning
        #   DeepSeek V4 Flash → scouting, locating, large-context mechanical passes
        home.file.".pi/agent/settings.json".text = builtins.toJSON {
          provider = "anthropic-proxy";
          model = "anthropic.claude-opus-4-6-v1";
          defaultThinkingLevel = "medium";
          packages = [
            "npm:context-mode"
            "npm:pi-opencode-bridge"
            "npm:pi-subagents"
            "npm:pi-intercom"
            "npm:pi-web-access"
            "npm:pi-caveman"
            "npm:pi-rtk-optimizer"
            "npm:pi-beads-extension"
            "npm:@feniix/pi-specdocs"
            "npm:pi-ask-user"
            "npm:@earendil-works/pi-ai"
            "npm:@earendil-works/pi-coding-agent"
          ];
          subagents = {
            agentOverrides =
              let
                glm = "oc-sdk-go/glm-5.1";
                kimi = "oc-sdk-go/kimi-k2.6";
                mimo = "oc-sdk-go/mimo-v2.5-pro";
                flash = "oc-sdk-go/deepseek-v4-flash";

                mkOverride = model: thinking: fallbackModels: {
                  inherit model thinking fallbackModels;
                };
                mkOverrides =
                  names: value: builtins.listToAttrs (builtins.map (name: { inherit name value; }) names);

                planOverride = mkOverride glm "high" [
                  mimo
                  kimi
                ];
                buildOverride = mkOverride kimi "high" [
                  glm
                  mimo
                ];
                deepOverride = mkOverride mimo "xhigh" [
                  glm
                  kimi
                ];
                scoutOverride = mkOverride flash "medium" [
                  glm
                  kimi
                ];
              in
              (mkOverrides [
                # Builtins: high-reasoning tasks (oracle = decision consistency).
                "oracle"
              ] deepOverride)
              // (mkOverrides [
                # Builtins: planning and review.
                "planner"
                "reviewer"
                "context-builder"
              ] planOverride)
              // (mkOverrides [
                # Builtins: implementation work.
                "worker"
                "delegate"
              ] buildOverride)
              // (mkOverrides [
                # Builtins: fast recon and research.
                "scout"
                "researcher"
              ] scoutOverride)
              // (mkOverrides [
                # MiMo: adversarial/security/hard reasoning, 1M context.
                "artifact-reviewer"
                "ce-adversarial-document-reviewer"
                "ce-adversarial-reviewer"
                "ce-agent-native-reviewer"
                "ce-correctness-reviewer"
                "ce-data-integrity-guardian"
                "ce-data-migrations-reviewer"
                "ce-julik-frontend-races-reviewer"
                "ce-performance-oracle"
                "ce-security-lens-reviewer"
                "ce-security-reviewer"
                "ce-security-sentinel"
                "claim-verifier"
                "codebase-analyzer"
                "slice-verifier"
              ] deepOverride)
              // (mkOverrides [
                # GLM: plans, careful review, synthesis.
                "artifact-code-reviewer"
                "artifact-coverage-reviewer"
                "ce-api-contract-reviewer"
                "ce-architecture-strategist"
                "ce-best-practices-researcher"
                "ce-code-simplicity-reviewer"
                "ce-coherence-reviewer"
                "ce-deployment-verification-agent"
                "ce-design-implementation-reviewer"
                "ce-design-lens-reviewer"
                "ce-dhh-rails-reviewer"
                "ce-feasibility-reviewer"
                "ce-framework-docs-researcher"
                "ce-kieran-python-reviewer"
                "ce-kieran-rails-reviewer"
                "ce-kieran-typescript-reviewer"
                "ce-maintainability-reviewer"
                "ce-performance-reviewer"
                "ce-product-lens-reviewer"
                "ce-project-standards-reviewer"
                "ce-reliability-reviewer"
                "ce-scope-guardian-reviewer"
                "ce-slack-researcher"
                "ce-spec-flow-analyzer"
                "ce-swift-ios-reviewer"
                "ce-testing-reviewer"
                "ce-web-researcher"
                "diff-auditor"
                "peer-comparator"
                "web-search-researcher"
              ] planOverride)
              // (mkOverrides [
                # Kimi: build/edit/write/fix loops.
                "ce-ankane-readme-writer"
                "ce-data-migration-expert"
                "ce-design-iterator"
                "ce-figma-design-sync"
                "ce-pr-comment-resolver"
              ] buildOverride)
              // (mkOverrides [
                # DeepSeek Flash: fast scouting, locating, summarizing context.
                "artifacts-analyzer"
                "artifacts-locator"
                "ce-git-history-analyzer"
                "ce-issue-intelligence-analyst"
                "ce-learnings-researcher"
                "ce-pattern-recognition-specialist"
                "ce-previous-comments-reviewer"
                "ce-repo-research-analyst"
                "ce-schema-drift-detector"
                "ce-session-historian"
                "codebase-locator"
                "codebase-pattern-finder"
                "integration-scanner"
                "precedent-locator"
                "scope-tracer"
                "test-case-locator"
              ] scoutOverride);
          };
        };

        # Override builtin agents with CE-enhanced versions.
        # User-scope agents with same name shadow builtins at lowest priority.
        home.file.".pi/agent/agents/worker.md".source = ../pi-extensions/agent-overrides/worker.md;
        home.file.".pi/agent/agents/planner.md".source = ../pi-extensions/agent-overrides/planner.md;
        home.file.".pi/agent/agents/oracle.md".source = ../pi-extensions/agent-overrides/oracle.md;
        home.file.".pi/agent/agents/reviewer.md".source = ../pi-extensions/agent-overrides/reviewer.md;
        home.file.".pi/agent/agents/scout.md".source = ../pi-extensions/agent-overrides/scout.md;
        home.file.".pi/agent/agents/researcher.md".source = ../pi-extensions/agent-overrides/researcher.md;
        home.file.".pi/agent/agents/workstream-compounder.md".source = ../pi-extensions/agent-overrides/workstream-compounder.md;
        home.file.".pi/agent/chains/ce-review.chain.md".source = ../pi-extensions/chains/ce-review.chain.md;
        home.file.".pi/agent/chains/scout-plan.chain.md".source = ../pi-extensions/chains/scout-plan.chain.md;
        home.file.".pi/agent/chains/plan-implement.chain.md".source = ../pi-extensions/chains/plan-implement.chain.md;
        home.file.".pi/agent/chains/review-fix.chain.md".source = ../pi-extensions/chains/review-fix.chain.md;

        # pi-subagents native `agentOverrides` only applies to builtin agents.
        # Our Compound Engineering agents live in ~/.pi/agent/agents (user scope),
        # so stale frontmatter model pins win during discovery. Mirror the same
        # overrides into those user-scope agent files to keep runtime routing on
        # OpenCode Go models until these agents move into a package/builtin scope.
        home.activation.syncPiUserAgentModelOverrides = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${pkgs.nodejs}/bin/node <<'NODE'
          const fs = require("fs");
          const path = require("path");

          const settingsPath = path.join(process.env.HOME, ".pi", "agent", "settings.json");
          const agentsDir = path.join(process.env.HOME, ".pi", "agent", "agents");
          if (!fs.existsSync(settingsPath) || !fs.existsSync(agentsDir)) process.exit(0);

          const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
          const overrides = (settings.subagents && settings.subagents.agentOverrides) || {};
          const fields = ["model", "thinking", "fallbackModels"];
          let updated = 0;

          for (const fileName of fs.readdirSync(agentsDir).filter((name) => name.endsWith(".md"))) {
            const filePath = path.join(agentsDir, fileName);
            const lines = fs.readFileSync(filePath, "utf8").split(/\n/);
            if (lines[0] !== "---") continue;

            const frontmatterEnd = lines.indexOf("---", 1);
            if (frontmatterEnd < 0) continue;

            let frontmatter = lines.slice(1, frontmatterEnd);
            let body = lines.slice(frontmatterEnd + 1);
            const nameLine = frontmatter.find((line) => line.startsWith("name: "));
            const agentName = nameLine ? nameLine.slice(6).trim() : path.basename(fileName, ".md");
            const override = overrides[agentName];
            if (!override || !override.model) continue;

            const values = {
              model: override.model,
              fallbackModels: Array.isArray(override.fallbackModels) ? override.fallbackModels.join(", ") : undefined,
              thinking: override.thinking,
            };

            frontmatter = frontmatter.filter((line) => !fields.some((field) => line.startsWith(field + ":")));
            body = body.filter((line) => !fields.some((field) => values[field] && line === field + ": " + values[field]));

            const inserted = [];
            if (values.model) inserted.push("model: " + values.model);
            if (values.fallbackModels) inserted.push("fallbackModels: " + values.fallbackModels);
            if (values.thinking) inserted.push("thinking: " + values.thinking);

            const descriptionIndex = frontmatter.findIndex((line) => line.startsWith("description: "));
            if (descriptionIndex >= 0) {
              frontmatter.splice(descriptionIndex + 1, 0, ...inserted);
            } else {
              frontmatter.push(...inserted);
            }

            const next = ["---", ...frontmatter, "---", ...body].join("\n");
            const previous = lines.join("\n");
            if (next !== previous) {
              fs.writeFileSync(filePath, next);
              updated += 1;
            }
          }

          console.log("synced Pi user agent model overrides: " + updated);
          NODE
        '';
      };
  };
}
